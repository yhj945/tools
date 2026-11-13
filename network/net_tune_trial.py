"""Host-side trial transactions and an independent, renewable rollback lease."""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

from net_tune_auto import BASELINE_KEYS, candidate_settings
from net_tune_changes import Transactions, build_plan, replace_file
from net_tune_system import AVAILABLE_CC, BASE_MSS, CC, MTU_PROBING, LinuxHost, TuneError

LEASE_SECONDS = 90


def save(path, data):
    replace_file(path, json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2) + "\n", 0o600)


def snapshot(host, store, interface=None):
    route = host.default_ipv4_route()
    interface = interface or route["interface"]
    if interface != route["interface"]:
        raise TuneError("自动试验仅支持已确认的 IPv4 默认出口")
    paths = [host.etc / "sysctl.d/90-net-tune.conf",
             host.etc / f"systemd/system/net-tune-gso-{interface}.service",
             host.etc / f"init.d/net-tune-gso-{interface}"]
    return {"scope": host.scope(), "interface": interface, "route": route,
            "sysctl": {k: host.sysctl(k) for k in BASELINE_KEYS},
            "queue": host.queue_state(interface), "gso": host.gso_state(interface),
            "persistent_hashes": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None for p in paths}}


def initial_settings(store, current):
    """Recover only recorded, still-applied changes; never guess factory defaults."""
    keys = {CC: "cc", BASE_MSS: "mtu_probe_mss", MTU_PROBING: "mtu_probing"}
    settings, unsupported = {}, []
    for record in reversed(store.records()):
        if record["state"] != "applied" or record["scope"]["machine"] != current["scope"]["machine"]:
            continue
        if record["scope"]["boot"] == current["scope"]["boot"]:
            if record["scope"]["netns"] != current["scope"]["netns"]:
                continue
        elif not (record.get("initial_netns") and store.host.in_init_netns()):
            continue
        for step in record["steps"][:record["attempted"]]:
            kind = step["type"]
            if kind == "sysctl" and step["key"] in keys:
                key = keys[step["key"]]
                settings.setdefault(key, step["before"] if key == "cc" else int(step["before"]))
            elif kind == "gso" and step["interface"] == current["interface"]:
                if step["before"]["address"] != current["gso"]["address"]:
                    raise TuneError("历史 GSO 记录对应的网卡身份不同")
                settings.setdefault("gso_max_segs", step["before"]["max_segs"])
            elif kind in {"sysctl", "qdisc", "default_route"}:
                unsupported.append(kind + ":" + step.get("key", ""))
    if unsupported:
        raise TuneError("无法完整重建介入前配置，存在未支持的历史变更: " + ", ".join(sorted(set(unsupported))))
    return settings


def design(host, store, interface, settings, persist=False):
    from net_tune import parser
    candidate_settings(settings)
    args = parser().parse_args(["plan"])
    if any(settings.get(k) for k in ("profile", "gso_single_segment", "gso_max_segs", "enable_fq_pacing", "initcwnd", "route_mtu")):
        args.interface = interface
    vars(args).update(settings, persist=persist)
    plan = build_plan(host, store, args)
    store.check_current(plan)
    return plan


def has_changes(plan):
    return (any(x["before"] != x["after"] for x in plan["sysctl"])
            or any(plan.get(k) for k in ("gso", "shape", "default_route", "config", "gso_persistence")))


def proposals(host, store, current, compare_initial=False, persist=False):
    choices, skipped = [], []
    try:
        initial = initial_settings(store, current)
    except (TuneError, PermissionError) as exc:
        if compare_initial:
            raise TuneError(str(exc)) from exc
        initial = {}; skipped.append(str(exc))
    if compare_initial:
        if not initial:
            raise TuneError("没有可核验的介入前记录，不猜测出厂配置")
        raw = [("介入前已记录配置", initial)]
    else:
        raw = []
        if current["gso"]["max_segs"] != 1:
            raw.append(("减少发送批次", {"gso_max_segs": 1}))
        if current["sysctl"][MTU_PROBING] != "1":
            raw.append(("按需 MTU 探测", {"mtu_probing": 1}))
        raw.append(("代理传输组合", {"profile": "vless"}))
        if initial:
            raw.append(("介入前已记录配置", initial))
        if current["route"]["initcwnd"] != 16:
            raw.append(("初始窗口 16", {"initcwnd": 16}))
        alternative = next((cc for cc in ("bbr", "cubic") if cc != current["sysctl"][CC]
                            and cc in (host.sysctl(AVAILABLE_CC) or "").split()), None)
        if alternative:
            raw.append(("拥塞控制 " + alternative, {"cc": alternative}))
    signatures = set()
    for name, settings in raw:
        try:
            plan = design(host, store, current["interface"], settings)
            signature = json.dumps({k:v for k,v in plan.items() if k not in {"created", "notes"}}, sort_keys=True)
            if has_changes(plan) and signature not in signatures:
                candidate = {"name": name, "settings": settings, "plan": plan}
                if persist:
                    candidate["persist_preview"] = design(host, store, current["interface"], settings, True)
                choices.append(candidate)
                signatures.add(signature)
        except TuneError as exc:
            skipped.append(name + ": " + str(exc))
        if len(choices) >= 3:
            break
    return choices, skipped


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077:
        raise TuneError("试验状态目录必须由当前管理员独占")


@contextmanager
def lease_lock(path):
    fd = os.open(path / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def recover(host, store, path, state):
    errors = []
    for identifier in reversed(state["transactions"]):
        record = next((r for r in store.records() if r["id"] == identifier), None)
        if record is None or record["state"] == "rolled_back":
            continue
        try:
            store.rollback(identifier)
        except (TuneError, OSError) as exc:
            errors.append(str(exc)); break
    try:
        current = snapshot(host, store, state["baseline"]["interface"])
        if current != state["baseline"]:
            errors.append("恢复后配置与试验前快照不一致，保留冲突现场")
    except (TuneError, OSError) as exc:
        errors.append(str(exc))
    state.update(state="recovery_required" if errors else "rolled_back", errors=errors)
    save(path / "state.json", state)
    return state


def watch(path):
    path = Path(path)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    host, store = LinuxHost(), Transactions(LinuxHost())
    save(path / "ready.json", {"ready": True})
    while True:
        with lease_lock(path):
            state = json.loads((path / "state.json").read_text())
            if state["state"] != "active":
                return
            if time.monotonic() >= state["expires"]:
                recover(host, store, path, state)
                return
        time.sleep(.2)


def trial_path(store, identifier, category="experiments"):
    if not re.fullmatch(r"[0-9a-f]{32}", identifier):
        raise TuneError("无效试验编号")
    path = store.state_dir / category / identifier
    if not path.is_dir() or path.is_symlink() or path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077:
        raise TuneError("试验目录缺失或权限不可信")
    return path


def reserve_lease(host, store, expected, settings, identifier):
    if not re.fullmatch(r"[0-9a-f]{32}", identifier):
        raise TuneError("无效试验编号")
    parent = store.state_dir / "experiments"
    private_directory(store.state_dir); private_directory(parent)
    with lease_lock(parent):
        for old in parent.glob("*/state.json"):
            with lease_lock(old.parent):
                previous = json.loads(old.read_text())
                if previous.get("state") in {"active", "recovery_required"}:
                    if previous["state"] == "recovery_required" or time.monotonic() >= previous["expires"]:
                        previous = recover(host, store, old.parent, previous)
                    if previous["state"] != "rolled_back":
                        raise TuneError("已有试验或恢复冲突待处理: " + str(old))
        if snapshot(host, store, expected["interface"]) != expected:
            raise TuneError("恢复旧试验后配置已变化，请重新预览")
        path = parent / identifier
        if path.exists():
            raise TuneError("试验编号已使用")
        private_directory(path)
        state = {"state": "active", "baseline": expected, "transactions": [],
                 "expires": time.monotonic() + LEASE_SECONDS, "settings": settings, "expected": expected}
        save(path / "state.json", state)
    return path, state


def rpc(request, host=None, store=None):
    host = host or LinuxHost()
    store = store or Transactions(host)
    op = request["op"]
    if op == "preview":
        current = snapshot(host, store, request.get("interface"))
        if current["sysctl"]["net.ipv4.tcp_rto_min_us"] not in (None, "200000"):
            raise TuneError("当前 RTO 下限不是 200 ms；自动试验不会修改它")
        candidates, skipped = proposals(host, store, current, request.get("compare_initial", False), request.get("persist", False))
        return {"baseline": current, "candidates": candidates, "skipped": skipped,
                "os": host.os_release(), "available_cc": host.sysctl(AVAILABLE_CC), "epoch": time.time()}
    if os.geteuid():
        raise TuneError("候选试验和发送端观察需要目标主机 root 权限")
    if op == "begin":
        expected = request["baseline"]
        if snapshot(host, store, expected["interface"]) != expected:
            raise TuneError("配置已偏离预览，请重新生成预览")
        identifier = request.get("id", uuid.uuid4().hex)
        path, state = reserve_lease(host, store, expected, request["settings"], identifier)
        code = path / "code"; private_directory(code)
        for source in Path(__file__).resolve().parent.glob("net_tune*.py"):
            shutil.copyfile(source, code / source.name)
        with open(path / "guard.log", "w") as log:
            subprocess.Popen([sys.executable, "-B", str(code / "net_tune_trial.py"), "watch", str(path)],
                             stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                             env={"PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), "LC_ALL": "C"})
        until = time.monotonic() + 5
        while not (path / "ready.json").exists() and time.monotonic() < until:
            time.sleep(.05)
        if not (path / "ready.json").exists():
            state["state"] = "rolled_back"; save(path / "state.json", state)
            raise TuneError("独立回滚进程未就绪，未应用配置")
        with lease_lock(path):
            try:
                def remember(transaction):
                    state["transactions"].append(transaction); save(path / "state.json", state)
                plan = design(host, store, expected["interface"], request["settings"])
                store.apply(plan, journal_hook=remember)
                state["expected"] = snapshot(host, store, expected["interface"])
                save(path / "state.json", state)
            except BaseException:
                recover(host, store, path, state)
                raise
        return {"id": identifier, "state": state}
    if op in {"touch", "finish", "persist"}:
        if op == "finish" and not request.get("keep") and re.fullmatch(r"[0-9a-f]{32}", request["id"]):
            if not (store.state_dir / "experiments" / request["id"]).exists():
                return {"state": "not_started"}
        path = trial_path(store, request["id"])
        with lease_lock(path):
            state = json.loads((path / "state.json").read_text())
            if op == "finish" and not request.get("keep"):
                return recover(host, store, path, state)
            if state["state"] != "active" or time.monotonic() >= state["expires"]:
                raise TuneError("试验租约已到期或正在恢复，不接受保留配置")
            if snapshot(host, store, state["baseline"]["interface"]) != state["expected"]:
                raise TuneError("试验期间出现配置漂移，不接受保留配置")
            if op == "touch":
                state["expires"] = time.monotonic() + LEASE_SECONDS
            elif op == "persist":
                def remember(transaction):
                    state["transactions"].append(transaction); save(path / "state.json", state)
                plan = design(host, store, state["baseline"]["interface"], state["settings"], True)
                store.apply(plan, journal_hook=remember)
                state["expected"] = snapshot(host, store, state["baseline"]["interface"])
            else:
                state["state"] = "kept"
            save(path / "state.json", state)
            return state
    if op == "observe_start":
        port, duration = int(request.get("port", 0)), float(request["seconds"])
        if not 0 <= port <= 65535 or not 1 <= duration <= 3600:
            raise TuneError("连接观察参数越界")
        identifier = uuid.uuid4().hex
        parent = store.state_dir / "observations"
        private_directory(store.state_dir); private_directory(parent)
        path = parent / identifier; private_directory(path)
        with open(path / "observer.log", "w") as log:
            child = subprocess.Popen([sys.executable, "-B", str(Path(__file__).with_name("net_tune_observe.py")), str(path), str(port), str(duration)],
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        save(path / "process.json", {"pid": child.pid, "start": Path(f"/proc/{child.pid}/stat").read_text().split()[21]})
        until = time.monotonic() + 5
        while not (path / "ready.json").exists() and time.monotonic() < until:
            time.sleep(.05)
        ready = json.loads((path / "ready.json").read_text()) if (path / "ready.json").exists() else {"ready": False}
        return {"id": identifier, **ready, "epoch": time.time()}
    if op == "observe_stop":
        path = trial_path(store, request["id"], "observations")
        process = json.loads((path / "process.json").read_text())
        stat = Path(f"/proc/{process['pid']}/stat")
        if stat.exists() and stat.read_text().split()[21] == process["start"]:
            os.kill(process["pid"], signal.SIGTERM)
        until = time.monotonic() + 5
        while not (path / "result.json").exists() and time.monotonic() < until:
            time.sleep(.05)
        if not (path / "result.json").exists():
            return {"complete": False, "events": [], "errors": ["连接观察未正常结束"]}
        return json.loads((path / "result.json").read_text())
    if op == "snapshot":
        return snapshot(host, store, request.get("interface"))
    raise TuneError("未知试验操作")


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    if len(sys.argv) == 3 and sys.argv[1] == "watch":
        watch(sys.argv[2])
    else:
        try:
            print(json.dumps({"result": rpc(json.load(sys.stdin))}, ensure_ascii=False, allow_nan=False))
        except (TuneError, OSError, ValueError, KeyError) as exc:
            print(json.dumps({"error": str(exc)}, ensure_ascii=False))
            sys.exit(1)
