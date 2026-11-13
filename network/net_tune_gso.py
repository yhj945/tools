"""Managed GSO startup service and its per-boot, reversible link adjustment."""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time

from net_tune_system import LinuxHost, TuneError, checked, command


def trusted_content(path, check_parents=True):
    for parent in path.parents if check_parents else ():
        if parent.exists():
            meta = parent.lstat()
            if not stat.S_ISDIR(meta.st_mode) or meta.st_uid not in {0, os.geteuid()} or meta.st_mode & 0o022:
                # /tmp is only used by isolated local fixtures, never installed paths.
                if parent == Path("/tmp") and meta.st_mode & stat.S_ISVTX:
                    continue
                raise TuneError(f"启动文件的父目录不可信: {parent}")
    try:
        meta = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(meta.st_mode) or meta.st_uid not in {0, os.geteuid()} or meta.st_mode & 0o022:
        raise TuneError(f"需要管理员拥有且不可由其他用户写入的普通文件: {path}")
    return path.read_text(encoding="utf-8")


def service_backend(host):
    if (host.proc / "1/comm").read_text().strip() == "systemd":
        return "systemd"
    if shutil.which("rc-update") and shutil.which("rc-service"):
        return "openrc"
    raise TuneError("GSO 持久化需要 systemd 或 OpenRC")


def valid_identity(interface, address):
    return (isinstance(interface, str) and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}", interface)
            and isinstance(address, str) and re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", address))


class GSOPersistence:
    def __init__(self, host):
        self.host = host
        self.root = host.etc.parent if host is not None else Path("/")

    def backend(self):
        return service_backend(self.host)

    @staticmethod
    def name(step):
        return "net-tune-gso-" + step["interface"]

    def files(self, step):
        name, interface, address = self.name(step), step["interface"], step["address"]
        helper = "/usr/local/lib/net-tune/net_tune_gso.py"
        executable = str(Path(sys.executable).resolve())
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", executable):
            raise TuneError("Python 安装路径不能用于启动服务")
        start, stop = f"{executable} -B {helper} start {interface} {address}", f"{executable} -B {helper} stop {interface} {address}"
        if "target_max_segs" in step:
            start += " " + str(step["target_max_segs"])
            stop += " " + str(step["target_max_segs"])
        if step["backend"] == "systemd":
            service_path = f"/etc/systemd/system/{name}.service"
            service = ("# Managed by net_tune.\n[Unit]\nDescription=net_tune GSO limit\n"
                       "Wants=network-online.target\nAfter=network-online.target\n\n[Service]\n"
                       f"Type=oneshot\nRemainAfterExit=yes\nExecStart={start}\nExecStopPost={stop}\n"
                       "TimeoutStartSec=75\nTimeoutStopSec=15\n\n[Install]\nWantedBy=multi-user.target\n")
        else:
            service_path = f"/etc/init.d/{name}"
            service = ("#!/sbin/openrc-run\n# Managed by net_tune.\n"
                       "description=\"net_tune GSO limit\"\ndepend() { need net; }\n"
                       f"start() {{ {start} || {{ {stop}; return 1; }}; }}\nstop() {{ {stop}; }}\n")
        source = Path(__file__).resolve().parent
        def content(name):
            embedded = getattr(sys.modules.get(name), "__net_tune_source__", None)
            return embedded if embedded is not None else (source / (name + ".py")).read_text()
        return {helper: content("net_tune_gso"),
                "/usr/local/lib/net-tune/net_tune_system.py": content("net_tune_system"),
                service_path: service}

    def state(self, step):
        name = self.name(step)
        if step["backend"] == "systemd":
            enabled = command(["systemctl", "is-enabled", name + ".service"])
            active = command(["systemctl", "is-active", name + ".service"])
            if enabled.stdout.strip() not in {"enabled", "disabled", "not-found"}:
                raise TuneError(f"{name} 的启动状态需要先处理: {enabled.stdout.strip()}")
            if active.stdout.strip() not in {"active", "inactive", "failed", "unknown"}:
                raise TuneError(f"{name} 的运行状态不稳定，请稍后重试")
            return {"enabled": enabled.stdout.strip() == "enabled", "active": active.stdout.strip() == "active"}
        enabled = checked(["rc-update", "show", "default"])
        status = command(["rc-service", name, "status"])
        return {"enabled": any(line.split("|")[0].strip() == name for line in enabled.splitlines()),
                "active": status.returncode == 0}

    def snapshot(self, step):
        return {"files": {path: trusted_content(self.root / path.lstrip("/")) for path in self.files(step)},
                **self.state(step)}

    def plan(self, interface, link, target=1):
        if not self.host.in_init_netns():
            raise TuneError("GSO 持久化需要在系统初始网络命名空间运行")
        if not valid_identity(interface, link["address"]):
            raise TuneError("GSO 持久化需要稳定的网卡名和 MAC 地址")
        step = {"backend": self.backend(), "interface": interface, **link}
        if target != 1:
            step["target_max_segs"] = target
        before = self.snapshot(step)
        after = {"files": self.files(step), "enabled": True, "active": True}
        return {**step, "before": before, "after": after} if before != after else None

    def validate(self, step):
        if (set(step) - {"target_max_segs"} != {"backend", "interface", "address", "ifindex", "max_segs", "before", "after"}
                or type(step.get("target_max_segs", 1)) is not int or not 1 <= step.get("target_max_segs", 1) <= 65535
                or not valid_identity(step["interface"], step["address"]) or step["backend"] not in {"systemd", "openrc"}
                or type(step["ifindex"]) is not int or step["ifindex"] < 1
                or type(step["max_segs"]) is not int or not 1 <= step["max_segs"] <= 65535
                or step["after"] != {"files": self.files(step), "enabled": True, "active": True}
                or set(step["before"]) != {"files", "enabled", "active"}
                or set(step["before"]["files"]) != set(step["after"]["files"])
                or any(value is not None and not isinstance(value, str) for value in step["before"]["files"].values())
                or any(type(step["before"][key]) is not bool for key in ("enabled", "active"))):
            raise ValueError

    def check(self, step, runtime_applied=False):
        current = self.host.gso_state(step["interface"])
        if (self.backend() != step["backend"] or not self.host.in_init_netns()
                or any(current[key] != step[key] for key in ("ifindex", "address"))
                or current["max_segs"] != (step.get("target_max_segs", 1) if runtime_applied else step["max_segs"])
                or self.snapshot(step) != step["before"]):
            raise TuneError("GSO 启动配置、服务或网卡身份已变化，请重新生成计划")

    def control(self, step, action):
        name = self.name(step)
        if step["backend"] == "systemd":
            return checked(["systemctl", action, name + ".service"], timeout=90)
        if action in {"enable", "disable"}:
            return checked(["rc-update", "add" if action == "enable" else "del", name, "default"])
        return checked(["rc-service", name, action], timeout=90)

    def reload(self, step):
        if step["backend"] == "systemd":
            checked(["systemctl", "daemon-reload"])

    def write_files(self, files, replace):
        for path, content in files.items():
            target = self.root / path.lstrip("/")
            trusted_content(target)
            if content is not None:
                target.parent.mkdir(parents=True, exist_ok=True)
            if target.parent.exists():
                replace(target, content, 0o755 if path.startswith("/etc/init.d/") else 0o644)

    @staticmethod
    def service_target(step, files):
        service = next((text for path, text in files.items() if path.startswith("/etc/")), None)
        match = re.search(r"net_tune_gso\.py start " + re.escape(step["interface"] + " " + step["address"])
                          + r"(?: ([0-9]+))?(?:\n| \|\|)", service or "")
        if not match:
            raise TuneError("无法确认原 GSO 启动服务的目标值")
        return int(match[1]) if match[1] else 1

    def apply(self, step, replace):
        if step["before"]["active"]:
            # The runtime step may already have changed the limit. Return to the
            # old service's owned value before asking its stop helper to restore.
            previous = self.service_target(step, step["before"]["files"])
            self.host.set_gso_max_segs(step["interface"], previous)
            self.control(step, "stop")
        self.write_files(step["after"]["files"], replace)
        self.reload(step)
        self.control(step, "enable")
        self.control(step, "start")
        if self.snapshot(step) != step["after"] or self.host.gso_state(step["interface"])["max_segs"] != step.get("target_max_segs", 1):
            raise TuneError("GSO 启动服务或分段上限读回不匹配")

    def restore(self, step, replace, restore_runtime=False):
        # Accept a partially written bundle, but never overwrite a foreign edit.
        for path, after in step["after"]["files"].items():
            if trusted_content(self.root / path.lstrip("/")) not in (step["before"]["files"][path], after):
                raise TuneError(f"GSO 启动文件存在第三方变更: {path}")
        current = self.snapshot(step)
        if current == step["before"]:
            if restore_runtime:
                link = self.host.gso_state(step["interface"])
                allowed = {step["max_segs"], step.get("target_max_segs", 1)}
                if step["before"]["active"]:
                    allowed.add(self.service_target(step, step["before"]["files"]))
                if link["max_segs"] not in allowed or any(link[k] != step[k] for k in ("ifindex", "address")):
                    raise TuneError("GSO 运行值存在第三方变更")
                self.host.set_gso_max_segs(step["interface"], step["max_segs"])
                if self.host.gso_state(step["interface"])["max_segs"] != step["max_segs"]:
                    raise TuneError("GSO 运行值恢复读回不匹配")
            return
        service_path = next(path for path in step["after"]["files"] if path.startswith("/etc/"))
        if current["files"][service_path] is not None:
            # stop also invokes ExecStopPost for a failed systemd start.
            self.control(step, "stop")
            if current["enabled"] and not step["before"]["enabled"]:
                self.control(step, "disable")
        self.write_files(step["before"]["files"], replace)
        self.reload(step)
        if step["before"]["enabled"]:
            self.control(step, "enable")
        if step["before"]["active"]:
            self.control(step, "start")
        if restore_runtime:
            self.host.set_gso_max_segs(step["interface"], step["max_segs"])
            if self.host.gso_state(step["interface"])["max_segs"] != step["max_segs"]:
                raise TuneError("GSO 运行值恢复读回不匹配")
        if self.snapshot(step) != step["before"]:
            raise TuneError("GSO 启动配置回滚读回不匹配")


@contextmanager
def boot_lock(directory, interface):
    directory.mkdir(mode=0o700, exist_ok=True)
    meta = directory.lstat()
    if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.geteuid() or meta.st_mode & 0o077:
        raise TuneError("GSO 启动状态目录权限不可信")
    descriptor = os.open(directory / (interface + ".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def boot_adjust(host, action, interface, address, directory=Path("/run/net-tune-gso"), wait=60, target=1):
    if not valid_identity(interface, address) or not host.in_init_netns() or type(target) is not int or not 1 <= target <= 65535:
        raise TuneError("GSO 启动参数或网络命名空间不合法")
    with boot_lock(directory, interface):
        path = directory / (interface + ".json")
        text = trusted_content(path, check_parents=False)
        saved = json.loads(text) if text is not None else None
        if action == "stop" and saved is None:
            return
        deadline = time.monotonic() + wait
        while True:
            try:
                current = host.gso_state(interface)
                break
            except TuneError:
                if action == "stop" or time.monotonic() >= deadline:
                    raise
                time.sleep(1)
        scope = host.scope()
        if current["address"] != address:
            raise TuneError("GSO 网卡 MAC 地址已变化，保留当前配置")
        if saved and (saved["scope"] != scope or saved["link"]["ifindex"] != current["ifindex"]
                      or saved["link"]["address"] != address):
            raise TuneError("GSO 启动恢复记录与当前网卡不匹配")
        if action == "start":
            if saved is None:
                saved = {"scope": scope, "link": current, "target": target}
                descriptor, temporary = tempfile.mkstemp(prefix=".gso-", dir=directory)
                try:
                    with os.fdopen(descriptor, "w") as handle:
                        json.dump(saved, handle)
                        handle.flush()
                        os.fsync(handle.fileno())
                    os.replace(temporary, path)
                finally:
                    Path(temporary).unlink(missing_ok=True)
            elif saved.get("target", 1) != target or current["max_segs"] not in (target, saved["link"]["max_segs"]):
                raise TuneError("GSO 上限存在第三方变更，保留当前配置")
            try:
                host.set_gso_max_segs(interface, target)
                if host.gso_state(interface) != {**current, "max_segs": target}:
                    raise TuneError("GSO 启动读回不匹配")
            except BaseException:
                observed, original = host.gso_state(interface), saved["link"]
                if observed not in (original, {**original, "max_segs": target}):
                    raise TuneError("GSO 启动失败且存在第三方变更，保留恢复记录")
                host.set_gso_max_segs(interface, original["max_segs"])
                if host.gso_state(interface) != original:
                    raise TuneError("GSO 启动失败且未能恢复，保留恢复记录")
                path.unlink()
                raise
        elif action == "stop" and saved:
            original = saved["link"]
            if current not in (original, {**original, "max_segs": saved.get("target", 1)}):
                raise TuneError("GSO 上限存在第三方变更，保留当前配置")
            host.set_gso_max_segs(interface, original["max_segs"])
            if host.gso_state(interface) != original:
                raise TuneError("GSO 停止恢复读回不匹配")
            path.unlink()


if __name__ == "__main__":
    try:
        if os.geteuid() or len(sys.argv) not in (4, 5) or sys.argv[1] not in {"start", "stop"}:
            raise TuneError("启动助手需要 root 和 start/stop、网卡、MAC 参数")
        boot_adjust(LinuxHost(), *sys.argv[1:4], target=int(sys.argv[4]) if len(sys.argv) == 5 else 1)
    except (TuneError, OSError, ValueError, KeyError) as exc:
        print(f"net_tune: {exc}", file=sys.stderr)
        sys.exit(1)
