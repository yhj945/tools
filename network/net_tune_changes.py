"""Build and apply small, reversible Linux network configuration plans."""

from __future__ import annotations

from contextlib import contextmanager
from copy import deepcopy
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
from statistics import median
import tempfile
import uuid

from net_tune_bench import RETRANS_BYTES_PER_MIB, number, utc_now, validated_report
from net_tune_system import (AUTOTUNE, BASE_MSS, CC, MTU_PROBING, PROBE_MSS_RANGE, QDISC_HANDLE, ROUTE_MTU_RANGE, RCV, SND,
                             WRITABLE_KEYS, TuneError, load_object)

PLAN = "net-tune-plan-v1"
PLAN_V2 = "net-tune-plan-v2"
PLAN_V3 = "net-tune-plan-v3"
PLAN_V4 = "net-tune-plan-v4"
HEADER = "# Managed by net_tune. Edit with a new plan.\n"
CONFIG = "90-net-tune.conf"
CC_PATTERN = r"[a-z0-9_]{1,15}"
STATE_FORMAT = "net-tune-transaction-v1"
STATE_FORMAT_V2 = "net-tune-transaction-v2"
STATE_FORMAT_V3 = "net-tune-transaction-v3"
STATE_FORMATS = {
    PLAN: STATE_FORMAT, PLAN_V2: STATE_FORMAT_V2, PLAN_V3: STATE_FORMAT_V3, PLAN_V4: "net-tune-transaction-v4",
}


def valid_cc(value) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(CC_PATTERN, value))


def valid_value(key, value) -> bool:
    if key == CC:
        return valid_cc(value)
    if key == MTU_PROBING:
        return value in ("0", "1", "2")
    if key == BASE_MSS:
        return isinstance(value, str) and bool(re.fullmatch(r"[1-9][0-9]{0,4}", value)) and int(value) <= 65535
    if key not in (RCV, SND) or not isinstance(value, str):
        return False
    parts = value.split(" ")
    return (len(parts) == 3 and all(re.fullmatch(r"[1-9][0-9]{0,9}", part) for part in parts)
            and 0 < int(parts[0]) <= int(parts[1]) <= int(parts[2]) <= 2**31 - 1)


def config_values(content: str) -> dict:
    if not content.startswith(HEADER):
        raise TuneError(f"{CONFIG} 已存在且缺少管理标记")
    values = {}
    for line in content[len(HEADER):].splitlines():
        key, separator, value = line.partition(" = ")
        if not separator or key in values or not valid_value(key, value):
            raise TuneError(f"{CONFIG} 包含非预期内容")
        values[key] = value
    return values


def render_config(values: dict) -> str:
    return HEADER + "".join(f"{key} = {values[key]}\n" for key in WRITABLE_KEYS if key in values)


def build_config(before, changes: list[dict]) -> str:
    values = config_values(before) if before is not None else {}
    values.update({change["key"]: change["after"] for change in changes})
    return render_config(values)


def cc_candidate(report: dict, current: str):
    if report.get("local_cc") != current:
        return None

    def single_upload(row):
        return row["protocol"] == "tcp" and row["direction"] == "up" and row["streams"] == 1

    settings = [(row["rate_mbps"], row["seconds"]) for row in report["trial_plan"] if single_upload(row)]
    if not settings:
        return None
    rate, seconds = max(settings)
    samples = {}
    for row in report["attempts"]:
        if not single_upload(row) or (row["rate_mbps"], row["seconds"]) != (rate, seconds):
            continue
        metrics = row.get("metrics")
        name = current if row["cc"] == "default" else row["cc"]
        if not metrics or not valid_cc(name) or metrics.get("sender_cc") != name:
            continue
        goodput, rtt, retrans = (
            number(metrics.get(key)) for key in ("goodput_mbps", "load_rtt_p95_ms", "retransmits_per_mib")
        )
        if goodput and rtt and retrans is not None:
            rounds = samples.setdefault(name, {})
            if row["cc"] != "default" or row["round"] not in rounds:
                rounds[row["round"]] = (goodput, rtt, retrans, number(metrics.get(RETRANS_BYTES_PER_MIB)))

    baseline = samples.pop(current, {})
    candidates = []
    for name, contender in samples.items():
        rounds = baseline.keys() & contender.keys()
        if len(rounds) < 3:
            continue
        paired = [(baseline[round_no], contender[round_no]) for round_no in rounds]
        have_bytes = all(a[3] is not None and b[3] is not None for a, b in paired)
        retrans_index, retrans_floor = (3, 1024) if have_bytes else (2, 1)
        pairs = [(a[:2] + (a[retrans_index],), b[:2] + (b[retrans_index],)) for a, b in paired]
        if any(b[0] < a[0] * .95 or b[1] > a[1] * 1.10
               or b[2] > max(a[2] * 1.10, a[2] + retrans_floor) for a, b in pairs):
            continue
        needed = math.ceil(.75 * len(pairs))
        # Tests which hit the offered rate still carry delay and retransmission evidence.
        faster = sum(a[0] < .90 * rate and b[0] >= a[0] * 1.05 for a, b in pairs)
        lower_delay = sum(b[1] <= a[1] * .80 for a, b in pairs)
        fewer_retransmits = sum(a[2] - b[2] >= max(retrans_floor, a[2] * .25) for a, b in pairs)
        if max(faster, lower_delay, fewer_retransmits) >= needed:
            candidates.append((
                median(b[0] / a[0] if a[0] < .90 * rate else 1 for a, b in pairs),
                -median(b[1] / a[1] for a, b in pairs),
                -median((b[2] - a[2]) / max(a[2], retrans_floor) for a, b in pairs),
                name,
            ))
    return max(candidates)[-1] if candidates else None


def shaping_hint(report: dict):
    rows = [row for row in report["summary"]
            if row["direction"] == "up" and row["streams"] == 1 and row["samples"] >= 3
            and row["cc"] in ("default", report.get("local_cc"))]
    rows.sort(key=lambda row: row["rate_mbps"])
    for low, high in zip(rows, rows[1:]):
        if low["cc"] != high["cc"] or low["rate_mbps"] >= high["rate_mbps"]:
            continue
        udp = low["protocol"] == "udp"
        metric = "udp_loss_pct" if udp else "retransmits_per_mib"
        a, b = low[metric], high[metric]
        if (a is not None and b is not None and a <= (0.5 if udp else 1)
                and b >= max(5 * a, 2 if udp else 3)
                and low["goodput_mbps"] >= low["rate_mbps"] * 0.90
                and high["goodput_mbps"] <= low["goodput_mbps"] * 1.05):
            rate = max(1, int(low["rate_mbps"] * 0.95))
            return (f"本路径在 {low['rate_mbps']}–{high['rate_mbps']} Mbps 档位出现平台和丢包/"
                    f"重传上升，可试验 {rate} Mbps 出向整形，并复测负载 RTT 与吞吐")
    return None


def build_plan(host, store, args, report=None) -> dict:
    scope = host.scope()
    changes, notes = [], []
    if report is not None:
        validated_report(report)
        if scope != report["scope"]:
            raise TuneError("测速报告来自不同主机、启动周期或网络命名空间")
        route = host.route(report["peer"], report.get("source"), report["port"],
                           report["summary"][0]["protocol"])
        if any(route.get(key) != report["route"].get(key) for key in ("dev", "gateway", "table")):
            raise TuneError("测速对端的出口路由已变化，请重新测速")
        hint = shaping_hint(report)
        if hint:
            notes.append(hint)
    cc, probe_mss = args.cc, args.mtu_probe_mss
    pacing, single_gso = args.enable_fq_pacing, args.gso_single_segment
    if args.profile == "vless":
        if args.shape_mbps or cc not in (None, "bbr") or probe_mss not in (None, 1290):
            raise TuneError("VLESS 预设使用 BBR、fq pacing 和 1290 字节起始 MSS，请移除冲突参数")
        cc, probe_mss, pacing, single_gso = "bbr", 1290, True, True
    current_cc = host.sysctl(CC)
    if cc == "auto":
        cc = cc_candidate(report, current_cc) if report is not None else None
        if cc is None:
            notes.append("当前报告缺少达到门槛的上行单流配对改善，需要至少 3 对有效吞吐、负载 RTT 和重传")
    if cc:
        if not host.supports_cc(cc) or not valid_value(CC, current_cc):
            raise TuneError(f"当前内核无法为 {cc} 生成可回滚的拥塞控制变更")
        if current_cc != cc or args.persist:
            changes.append({"key": CC, "before": current_cc, "after": cc,
                            "reason": "同档位逐轮配对，吞吐、负载 RTT 和重传通过比较门槛" if args.cc == "auto" else "显式选择"})

    evidence = report or {}
    idle = [value for value in evidence.get("idle_rtt_ms", []) if number(value)]
    rtt = args.rtt_ms or (median(idle) if idle else None)
    rates = {}
    for direction, key in (("up", SND), ("down", RCV)):
        rows = [row["goodput_mbps"] for row in evidence.get("summary", [])
                if row["protocol"] == "tcp" and row["direction"] == direction and row["streams"] == 1]
        rate = args.bandwidth_mbps or (max(rows) if rows else None)
        if rate:
            rates[key] = rate
    if args.bandwidth_mbps and not rtt:
        raise TuneError("指定带宽时需要 --rtt-ms 或包含空载 RTT 的报告")
    if rates and rtt:
        memory = host.memory()["effective_limit_bytes"]
        for key, rate in rates.items():
            before = host.sysctl(key)
            if not memory or not valid_value(key, before):
                notes.append(f"{key} 缺少内存或运行值，无法建议缓冲区上限")
                continue
            if key == RCV and host.sysctl(AUTOTUNE) != "1":
                notes.append("内核 TCP 接收自动调节已关闭，接收缓冲区上限无自动建议")
                continue
            low, default, high = map(int, before.split())
            bdp = math.ceil(rate * 1_000_000 / 8 * rtt / 1000)
            ceiling = min(64 * 1024**2, memory // 64, 2 * bdp)
            if ceiling > high:
                changes.append({"key": key, "before": before, "after": f"{low} {default} {ceiling}",
                                "reason": f"{rate:.2f} Mbps × {rtt:g} ms，BDP {bdp} B，受内存预算限制"})
    elif rates:
        notes.append("缺少空载 RTT，可按真实业务路径提供 --rtt-ms 后重新生成缓冲区建议")
    if args.rtt_ms and not rates:
        notes.append("缺少单流 TCP 吞吐或 --bandwidth-mbps，暂未推导缓冲区")
    if report and not args.rtt_ms and rtt:
        notes.append("缓冲区建议使用本报告对端的空载 RTT，跨地区业务可用 --rtt-ms 指定实测值")

    if probe_mss is not None:
        for key, after in ((BASE_MSS, str(probe_mss)), (MTU_PROBING, "2")):
            before = host.sysctl(key)
            if not valid_value(key, before):
                raise TuneError(f"无法读取 {key} 的可回滚运行值")
            if before != after or args.persist:
                changes.append({"key": key, "before": before, "after": after,
                                "reason": "从指定的 MSS 开始执行 TCP 路径 MTU 探测"})

    shape = gso = None
    queue_requested = args.shape_mbps or pacing
    route_requested = args.initcwnd is not None or args.route_mtu is not None
    if queue_requested or single_gso:
        interface = args.interface or (report["route"]["dev"] if report else None)
        if not interface:
            raise TuneError("网卡调整需要 --interface 或同一台主机的测速报告")
        path = None
        if report is not None and not args.interface:
            path = {"peer": report["peer"], "source": report.get("source"), "port": report["port"],
                    "protocol": report["summary"][0]["protocol"],
                    "route": {key: route.get(key) for key in ("dev", "gateway", "table")}}
    elif args.interface and not route_requested:
        raise TuneError("plan --interface 需要同时指定网卡、队列或默认路由调整")
    if queue_requested:
        before = host.queue_state(interface)
        queues = before["queues"]
        uses_default_fq_codel = (
            args.profile == "vless" and not args.enable_fq_pacing and len(queues) == 1
            and queues[0].get("root") and queues[0].get("kind") == "fq_codel"
            and queues[0].get("handle") == "0:" and not before["root_filters"]
        )
        if uses_default_fq_codel:
            notes.append(f"{interface} 使用现有 fq_codel 根队列")
        elif pacing:
            options = fq_root(before, require_handle=False)["options"]
            if options.get("pacing", True):
                notes.append(f"{interface} 的 fq pacing 已启用")
            else:
                if "maxrate" in options:
                    raise TuneError(f"{interface} 的 fq 已配置 maxrate，启用 pacing 会激活该上限")
                fq_root(before)
                shape = {"interface": interface, "kind": "fq", "before": before, "path": path}
        else:
            host.can_attach(interface, before)
            shape = {"interface": interface, "kind": args.shaper, "rate_mbps": args.shape_mbps,
                     "before": before, "path": path}
    if single_gso:
        before = host.gso_state(interface)
        if before["max_segs"] == 1:
            notes.append(f"{interface} 的 GSO 分段上限已为 1")
        else:
            gso = {"interface": interface, "before": before, "after": {**before, "max_segs": 1}, "path": path}
    default_route = None
    if route_requested:
        before = host.default_ipv4_route(include_mtu=args.route_mtu is not None)
        expected_interface = args.interface or (report["route"]["dev"] if report else None)
        if expected_interface and expected_interface != before["interface"]:
            raise TuneError("计划网卡与 IPv4 主表默认路由的出口不同")
        after = dict(before)
        if args.initcwnd is not None:
            after["initcwnd"] = args.initcwnd
        if args.route_mtu is not None:
            host.check_route_mtu(before["interface"], args.route_mtu)
            after["mtu"] = args.route_mtu
        if before != after:
            default_route = {"before": before, "after": after}
        else:
            notes.append(f"{before['interface']} 的 IPv4 默认路由参数已是计划值")
    config = None
    if args.persist and changes:
        backend = host.backend()
        if not backend:
            raise TuneError("未识别启用的 sysctl 启动加载器，可生成运行时计划")
        before = store.config_content()
        after = build_config(before, changes)
        store.check_boot_config(backend, config_values(after))
        if before != after:
            config = {"before": before, "after": after, "backend": backend}
    if not any(change["before"] != change["after"] for change in changes) and not (shape or gso or default_route or config):
        notes.append("当前证据没有产生参数变更")
    plan_format = plan_version(default_route, gso)
    plan = {"format": plan_format, "created": utc_now(), "scope": scope, "sysctl": changes,
            "shape": shape, "config": config, "notes": notes}
    if gso:
        plan["gso"] = gso
    if default_route:
        plan["default_route"] = default_route
    return plan


def valid_path(path, interface: str) -> bool:
    return path is None or (
        isinstance(path["peer"], str) and type(path["port"]) is int
        and 1 <= path["port"] <= 65535 and path["protocol"] in ("tcp", "udp")
        and (path["source"] is None or isinstance(path["source"], str))
        and path["route"]["dev"] == interface and set(path["route"]) == {"dev", "gateway", "table"}
    )


def plan_version(default_route, gso) -> str:
    if default_route is not None:
        return PLAN_V4 if "mtu" in default_route["before"] else PLAN_V3
    return PLAN_V2 if gso is not None else PLAN


def validate_default_route(change: dict) -> None:
    before, after = change["before"], change["after"]
    tokens = before["tokens"]
    ranges = {"initcwnd": (1, 65535)}
    if "mtu" in before:
        ranges["mtu"] = ROUTE_MTU_RANGE
    if (not isinstance(tokens, list) or tokens[:1] != ["default"] or tokens.count("dev") != 1
            or not all(isinstance(token, str) and token for token in tokens)
            or not isinstance(before["interface"], str)
            or tokens[tokens.index("dev") + 1:tokens.index("dev") + 2] != [before["interface"]]
            or any(key in tokens for key in ranges)):
        raise ValueError
    targets = {}
    for key, (low, high) in ranges.items():
        original, target = before[key], after[key]
        if original is not None and (type(original) is not int or not 0 <= original <= 2**32 - 1):
            raise ValueError
        if target is not None and type(target) is not int:
            raise ValueError
        if target != original and (target is None or not low <= target <= high):
            raise ValueError
        targets[key] = target
    if after == before or after != {**before, **targets}:
        raise ValueError


def validate_plan(plan: dict) -> None:
    try:
        gso = plan.get("gso")
        default_route = plan.get("default_route")
        expected_format = plan_version(default_route, gso)
        if plan["format"] != expected_format or not isinstance(plan["scope"], dict):
            raise ValueError
        seen = set()
        for change in plan["sysctl"]:
            key, before, after = (change[k] for k in ("key", "before", "after"))
            if key in seen or not valid_value(key, before) or not valid_value(key, after):
                raise ValueError
            if key == BASE_MSS and not PROBE_MSS_RANGE[0] <= int(after) <= PROBE_MSS_RANGE[1]:
                raise ValueError
            if key == MTU_PROBING and after != "2":
                raise ValueError
            if key in (RCV, SND):
                left, right = before.split(), after.split()
                if left[:2] != right[:2] or not int(left[2]) <= int(right[2]) <= max(int(left[2]), 64 * 1024**2):
                    raise ValueError
            seen.add(key)
        shape = plan["shape"]
        if shape is not None:
            if not isinstance(shape["interface"], str) or not isinstance(shape["before"], dict):
                raise ValueError
            if shape["kind"] == "fq":
                options = fq_root(shape["before"])["options"]
                if options.get("pacing") is not False or "maxrate" in options or "rate_mbps" in shape:
                    raise ValueError
            elif (shape["kind"] not in ("cake", "tbf") or type(shape["rate_mbps"]) is not int
                    or not 1 <= shape["rate_mbps"] <= 100_000):
                raise ValueError
            if not valid_path(shape["path"], shape["interface"]):
                raise ValueError
        if gso is not None:
            before, after = gso["before"], gso["after"]
            if (not isinstance(gso["interface"], str) or set(before) != {"ifindex", "address", "max_segs"}
                    or type(before["ifindex"]) is not int or before["ifindex"] < 1
                    or not (before["address"] is None or isinstance(before["address"], str))
                    or type(before["max_segs"]) is not int or not 2 <= before["max_segs"] <= 65535
                    or type(after["max_segs"]) is not int or after != {**before, "max_segs": 1}
                    or not valid_path(gso["path"], gso["interface"])):
                raise ValueError
        if default_route is not None:
            validate_default_route(default_route)
        config = plan["config"]
        if config is not None:
            if (not plan["sysctl"] or config["backend"] not in ("systemd", "openrc")
                    or build_config(config["before"], plan["sysctl"]) != config["after"]):
                raise ValueError
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise TuneError("计划结构或参数值不合法，请重新生成") from exc


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def replace_file(path: Path, content, mode: int) -> None:
    if content is None:
        path.unlink(missing_ok=True)
        sync_directory(path.parent)
        return
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


class Transactions:
    def __init__(self, host, state_dir=Path("/var/lib/net-tune"), config_dirs=None):
        self.host = host
        self.state_dir = state_dir
        self.config_dirs = config_dirs or (
            host.etc / "sysctl.d", Path("/run/sysctl.d"), Path("/usr/local/lib/sysctl.d"),
            Path("/usr/lib/sysctl.d"), Path("/lib/sysctl.d"),
        )
        self.config_path = self.config_dirs[0] / CONFIG

    def config_content(self):
        try:
            meta = self.config_path.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid not in {0, os.geteuid()}:
            raise TuneError(f"{self.config_path} 需要是可信的普通文件")
        if meta.st_mode & 0o022:
            raise TuneError(f"{self.config_path} 的写权限过宽")
        return self.config_path.read_text(encoding="utf-8")

    def check_boot_config(self, backend: str, values: dict) -> None:
        selected = {}
        for directory in self.config_dirs:
            if directory.exists():
                for path in directory.iterdir():
                    if path.name.endswith(".conf"):
                        selected.setdefault(path.name, path)
        later = [selected[name] for name in sorted(selected) if name > CONFIG]
        if backend == "openrc":
            classic = self.host.etc / "sysctl.conf"
            if classic.exists():
                later.append(classic)
        overrides = {}
        for path in later:
            if not path.exists():  # A missing symlink masks the lower-priority name.
                continue
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                key, sep, value = line.partition("=")
                if not sep or key.lstrip().startswith(("#", ";")):
                    continue
                key = key.strip().lstrip("-").replace("/", ".")
                if key in values:
                    overrides[key] = (path, " ".join(value.split()))
        for key, (path, value) in overrides.items():
            if value != values[key]:
                raise TuneError(f"持久化冲突: {path} 会重新设置 {key}")

    def records(self) -> list[dict]:
        if not self.state_dir.exists():
            return []
        # iterdir reports an unreadable journal directory instead of showing empty history.
        paths = sorted((path for path in self.state_dir.iterdir() if path.suffix == ".json"),
                       reverse=True)
        records = []
        for path in paths:
            item = load_object(str(path))
            if item.get("format") not in STATE_FORMATS.values() or item.get("id") != path.stem:
                raise TuneError(f"无法识别事务日志 {path}")
            records.append(item)
        return records

    @contextmanager
    def lock(self):
        self.state_dir.mkdir(mode=0o700, exist_ok=True)
        meta = self.state_dir.lstat()
        if (not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.geteuid()
                or meta.st_mode & 0o077):
            raise TuneError(f"{self.state_dir} 需要是当前管理员独占的普通目录")
        descriptor = os.open(self.state_dir / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise TuneError("另一项网络配置事务正在执行") from exc
            yield
        finally:
            os.close(descriptor)

    def save(self, journal: dict) -> None:
        content = json.dumps(journal, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        replace_file(self.state_dir / (journal["id"] + ".json"), content, 0o600)

    def check_current(self, plan: dict) -> None:
        validate_plan(plan)
        if self.host.scope() != plan["scope"]:
            raise TuneError("计划对应的主机、启动周期或网络命名空间已变化")
        memory = None
        for change in plan["sysctl"]:
            key, before, after = change["key"], change["before"], change["after"]
            if self.host.sysctl(key) != before:
                raise TuneError(f"{key} 的运行值已变化，请重新生成计划")
            if key == CC and not self.host.supports_cc(after):
                raise TuneError(f"当前内核无法使用 {after}")
            if key in (RCV, SND) and before != after:
                if memory is None:
                    memory = self.host.memory()["effective_limit_bytes"] or 0
                if int(after.split()[-1]) > memory // 64:
                    raise TuneError(f"{key} 超出当前内存预算，请重新生成计划")
                if key == RCV and self.host.sysctl(AUTOTUNE) != "1":
                    raise TuneError("TCP 接收自动调节状态已变化，请重新生成计划")
        shape, gso = plan["shape"], plan.get("gso")
        for adjustment in (shape, gso):
            path = adjustment["path"] if adjustment else None
            if path:
                route = self.host.route(path["peer"], path["source"], path["port"], path["protocol"])
                if any(route.get(key) != value for key, value in path["route"].items()):
                    raise TuneError("测速对端的出口路由已变化，请重新生成计划")
        if shape:
            interface = shape["interface"]
            current = self.host.queue_state(interface)
            if current != shape["before"]:
                raise TuneError(f"{interface} 的队列已变化，请重新生成计划")
            if shape["kind"] != "fq":
                self.host.can_attach(interface, current)
        if gso and self.host.gso_state(gso["interface"]) != gso["before"]:
            raise TuneError(f"{gso['interface']} 的 GSO 上限或网卡身份已变化，请重新生成计划")
        default_route = plan.get("default_route")
        if default_route:
            self.check_default_route(default_route)
        config = plan["config"]
        if config:
            if not self.config_path.parent.is_dir():
                raise TuneError(f"启动配置目录不可用: {self.config_path.parent}")
            if self.config_content() != config["before"]:
                raise TuneError(f"{CONFIG} 已变化，请重新生成计划")
            if self.host.backend() != config["backend"]:
                raise TuneError("启动加载器已变化，请重新生成计划")
            self.check_boot_config(config["backend"], config_values(config["after"]))

    def same_scope(self, journal: dict) -> bool:
        current, original = self.host.scope(), journal["scope"]
        if current["machine"] != original["machine"]:
            return False
        if current["boot"] == original["boot"]:
            return current["netns"] == original["netns"]
        return (journal["initial_netns"] and self.host.in_init_netns()
                and any(step["type"] == "config"
                        for step in journal["steps"][:journal["attempted"]]))

    def pending(self, records: list[dict]):
        return next((row for row in records if row["state"] in {"applying", "reverting"}
                     and self.same_scope(row)), None)

    def apply(self, plan: dict):
        self.check_current(plan)
        steps = [{"type": "sysctl", **change} for change in plan["sysctl"]
                 if change["before"] != change["after"]]
        shape, gso, config = plan["shape"], plan.get("gso"), plan["config"]
        if shape:
            steps.append({"type": "qdisc", **shape})
        if gso:
            steps.append({"type": "gso", **gso})
        default_route = plan.get("default_route")
        if default_route:
            steps.append({"type": "default_route", **default_route})
        if config:
            steps.append({"type": "config", **config})
        if not steps:
            return None
        with self.lock():
            records = self.records()
            pending = self.pending(records)
            if pending:
                raise TuneError(f"事务 {pending['id']} 待恢复，请先执行 rollback")
            self.check_current(plan)
            for step in steps:
                if step["type"] == "sysctl" and not self.host.can_write(step["key"]):
                    raise TuneError(f"当前命名空间无法写入 {step['key']}")
            if config:
                if not self.host.in_init_netns():
                    raise TuneError("持久化需要在系统初始网络命名空间运行")
                owner = next((step for record in records if record["state"] == "applied"
                              and self.same_scope(record)
                              for step in record["steps"] if step["type"] == "config"), None)
                if (owner["after"] if owner else None) != config["before"]:
                    raise TuneError(f"{CONFIG} 缺少匹配的管理记录，请保留原文件")
            sequence = int(records[0]["id"].split("-", 1)[0]) + 1 if records else 1
            journal = {
                "format": STATE_FORMATS[plan["format"]],
                "id": f"{sequence:020d}-{uuid.uuid4().hex[:8]}",
                "created": utc_now(), "scope": plan["scope"],
                "initial_netns": self.host.in_init_netns(), "steps": steps,
                "attempted": 0, "state": "applying",
            }
            self.save(journal)
            try:
                for index, step in enumerate(steps):
                    self.check_step(step)
                    journal["attempted"] = index + 1
                    self.save(journal)
                    self.write_step(step)
                journal["state"] = "applied"
                self.save(journal)
            except BaseException as exc:
                errors = self.restore(journal)
                detail = "已恢复本次变更" if not errors else "待恢复: " + " | ".join(errors)
                reason = str(exc) or "操作被中断"
                raise TuneError(f"事务 {journal['id']} 应用失败（{reason}），{detail}") from exc
        return journal["id"]

    def check_default_route(self, change: dict) -> None:
        before, after = change["before"], change["after"]
        if self.host.default_ipv4_route(include_mtu="mtu" in before) != before:
            raise TuneError("IPv4 默认路由已变化，请重新生成计划")
        if after.get("mtu") is not None and after["mtu"] != before.get("mtu"):
            self.host.check_route_mtu(after["interface"], after["mtu"])

    def check_step(self, step: dict) -> None:
        kind = step["type"]
        if kind == "sysctl" and self.host.sysctl(step["key"]) != step["before"]:
            raise TuneError(f"{step['key']} 的运行值在应用期间发生变化")
        if kind == "qdisc":
            current = self.host.queue_state(step["interface"])
            if current != step["before"]:
                raise TuneError("应用期间队列发生变化")
            if step["kind"] != "fq":
                self.host.can_attach(step["interface"], current)
        if kind == "gso" and self.host.gso_state(step["interface"]) != step["before"]:
            raise TuneError(f"{step['interface']} 的 GSO 上限或网卡身份在应用期间发生变化")
        if kind == "default_route":
            self.check_default_route(step)
        if kind == "config":
            if self.config_content() != step["before"]:
                raise TuneError(f"{CONFIG} 在应用期间发生变化")
            self.check_boot_config(step["backend"], config_values(step["after"]))

    def write_step(self, step: dict) -> None:
        kind = step["type"]
        if kind == "sysctl":
            self.host.write_sysctl(step["key"], step["after"])
        elif kind == "qdisc":
            interface = step["interface"]
            if step["kind"] == "fq":
                before = step["before"]
                self.host.set_fq_pacing(interface, fq_root(before)["handle"], True)
                if not pacing_matches(before, self.host.queue_state(interface)):
                    raise TuneError(f"{interface} 的 fq pacing 读回不匹配")
                return
            self.host.add_shaper(interface, step["kind"], step["rate_mbps"])
            current = self.host.queue_state(interface)
            root = owned_root(step, current)
            if root:
                step["installed"] = current
            if not root or not queue_rate_matches(step, root):
                raise TuneError("整形速率读回不匹配")
        elif kind == "gso":
            interface = step["interface"]
            self.host.set_gso_max_segs(interface, 1)
            if self.host.gso_state(interface) != step["after"]:
                raise TuneError(f"{interface} 的 GSO 上限读回不匹配")
        elif kind == "default_route":
            self.host.set_default_ipv4_route(step["after"])
        else:
            replace_file(self.config_path, step["after"], 0o644)
            if self.config_content() != step["after"]:
                raise TuneError(f"{CONFIG} 落盘读回不匹配")

    def latest(self):
        records = self.records()
        pending = self.pending(records)
        if pending:
            return pending
        return next((row for row in records if row["state"] == "applied"
                     and self.same_scope(row)), None)

    def rollback(self, identifier: str) -> None:
        with self.lock():
            journal = self.latest()
            if not journal or journal["id"] != identifier:
                raise TuneError("当前可回滚的事务已变化，请重新预览")
            errors = self.restore(journal)
            if errors:
                raise TuneError(f"事务 {identifier} 待恢复: " + " | ".join(errors))

    def restore(self, journal: dict) -> list[str]:
        # Let the first signal enter recovery and finish it even if another arrives.
        signals = (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)
        handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in signals}
        try:
            errors = []
            journal["state"] = "reverting"
            try:
                self.save(journal)
            except OSError:
                pass  # The earlier durable applying/applied record is enough to retry.
            attempted = journal["steps"][:journal["attempted"]]
            same_boot = self.host.scope()["boot"] == journal["scope"]["boot"]
            persisted = any(step["type"] == "config" for step in attempted)
            for step in reversed(attempted):
                kind = step["type"]
                if not same_boot and (kind in ("qdisc", "gso", "default_route") or kind == "sysctl" and not persisted):
                    continue
                try:
                    self.restore_step(step)
                except (TuneError, OSError) as exc:
                    errors.append(str(exc))
            journal["state"] = "reverting" if errors else "rolled_back"
            journal["recovery_errors"] = errors
            try:
                self.save(journal)
            except OSError as exc:
                errors.append(f"无法更新事务日志: {exc}")
            return errors
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)

    def restore_step(self, step: dict) -> None:
        kind = step["type"]
        if kind == "sysctl":
            key = step["key"]
            current = self.host.sysctl(key)
            if current == step["before"]:
                return
            if current != step["after"]:
                raise TuneError(f"{key} 存在第三方变更，需处理冲突")
            self.host.write_sysctl(key, step["before"])
        elif kind == "gso":
            interface = step["interface"]
            current = self.host.gso_state(interface)
            if current == step["before"]:
                return
            if current != step["after"]:
                raise TuneError(f"{interface} 的 GSO 上限或网卡身份已变化，需处理冲突")
            self.host.set_gso_max_segs(interface, step["before"]["max_segs"])
            if self.host.gso_state(interface) != step["before"]:
                raise TuneError(f"{interface} 的 GSO 上限回滚读回不匹配")
        elif kind == "default_route":
            current = self.host.default_ipv4_route(include_mtu="mtu" in step["before"])
            if current == step["before"]:
                return
            if current != step["after"]:
                raise TuneError("IPv4 默认路由存在第三方变更，需处理冲突")
            self.host.set_default_ipv4_route(step["before"])
        elif kind == "config":
            current = self.config_content()
            if current == step["before"]:
                return
            if current != step["after"]:
                raise TuneError(f"{CONFIG} 存在第三方变更，需处理冲突")
            replace_file(self.config_path, step["before"], 0o644)
            if self.config_content() != step["before"]:
                raise TuneError(f"{CONFIG} 回滚读回不匹配")
        else:
            interface = step["interface"]
            current = self.host.queue_state(interface)
            if current == step["before"]:
                return
            if step["kind"] == "fq":
                if not pacing_matches(step["before"], current):
                    raise TuneError(f"{interface} 的 fq 队列已变化，需处理冲突")
                self.host.set_fq_pacing(interface, fq_root(step["before"])["handle"], False)
            else:
                root = owned_root(step, current)
                installed = step.get("installed")
                if not root or (installed != current if installed else not queue_rate_matches(step, root)):
                    raise TuneError(f"{interface} 的网卡身份或队列已变化，需处理冲突")
                self.host.remove_shaper(interface)
            if self.host.queue_state(interface) != step["before"]:
                raise TuneError(f"{interface} 的原始队列读回不匹配")


def fq_root(state: dict, *, require_handle: bool = True) -> dict:
    roots = [queue for queue in state["queues"] if queue.get("root")]
    if len(roots) != 1 or roots[0].get("kind") != "fq":
        kinds = "、".join(str(root.get("kind", "未知")) for root in roots) or "无"
        raise TuneError(f"fq pacing 需要单个 fq 根队列，当前根队列为 {kinds}")
    root = roots[0]
    if not isinstance(root.get("options"), dict):
        raise TuneError("无法读取 fq 根队列参数")
    handle = root.get("handle", "")
    if require_handle and (not isinstance(handle, str) or not re.fullmatch(r"[0-9a-f]{1,4}:", handle)
                           or int(handle[:-1], 16) == 0):
        raise TuneError("修改 fq pacing 需要具有显式非零句柄的 fq 根队列")
    return root


def pacing_matches(before: dict, current: dict) -> bool:
    expected, observed = deepcopy(before), deepcopy(current)
    options = fq_root(observed)["options"]
    if options.get("pacing", True) is not True:
        return False
    # iproute2 commonly omits the pacing attribute when it is enabled.
    options.pop("pacing", None)
    fq_root(expected)["options"].pop("pacing", None)
    return observed == expected


def owned_root(step: dict, current: dict):
    queues = current["queues"]
    if (current["device"] == step["before"]["device"] and len(queues) == 1
            and not current.get("root_filters")):
        root = queues[0]
        if root.get("root") and root.get("handle") == QDISC_HANDLE and root.get("kind") == step["kind"]:
            return root
    return None


def queue_rate_matches(step: dict, root: dict) -> bool:
    field = "bandwidth" if step["kind"] == "cake" else "rate"
    rate_bytes = root.get("options", {}).get(field)
    expected = step["rate_mbps"] * 125_000
    return number(rate_bytes) is not None and abs(rate_bytes - expected) <= expected * 0.01
