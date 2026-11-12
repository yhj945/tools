"""Linux state and the small set of kernel operations managed by net_tune."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
from typing import Optional

CC = "net.ipv4.tcp_congestion_control"
AVAILABLE_CC = "net.ipv4.tcp_available_congestion_control"
RCV = "net.ipv4.tcp_rmem"
SND = "net.ipv4.tcp_wmem"
AUTOTUNE = "net.ipv4.tcp_moderate_rcvbuf"
DEFAULT_QDISC = "net.core.default_qdisc"
BASE_MSS = "net.ipv4.tcp_base_mss"
MTU_PROBING = "net.ipv4.tcp_mtu_probing"
PROBE_MSS_RANGE = (536, 1448)
ROUTE_MTU_RANGE = (576, 65535)
WRITABLE_KEYS = (CC, RCV, SND, BASE_MSS, MTU_PROBING)
INSPECT_KEYS = (CC, RCV, SND, AVAILABLE_CC, AUTOTUNE, DEFAULT_QDISC,
                "net.core.rmem_max", "net.core.wmem_max", "net.ipv4.tcp_mem",
                "net.ipv4.tcp_ecn", MTU_PROBING, BASE_MSS, "net.ipv4.tcp_recovery",
                "net.ipv4.tcp_reordering", "net.ipv4.tcp_rto_min_us",
                "net.core.netdev_max_backlog", "net.core.somaxconn")
QDISC_HANDLE = "75a1:"


class TuneError(Exception):
    """An input, measurement, or system operation needs the operator's attention."""


def read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None


def load_object(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise TuneError(f"无法读取 JSON {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise TuneError(f"JSON 顶层必须是对象: {path}")
    return data


def command(args: list[str], timeout: float = 5) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(args, capture_output=True, encoding="utf-8",
                              errors="replace", timeout=timeout,
                              env={**os.environ, "LC_ALL": "C"}, check=False)
    except subprocess.TimeoutExpired as exc:
        raise TuneError(f"{args[0]} 超时（{timeout:g} 秒）") from exc
    except OSError as exc:
        raise TuneError(f"无法执行 {args[0]}: {exc}") from exc


def checked(args: list[str], timeout: float = 5) -> str:
    result = command(args, timeout)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or str(result.returncode)
        raise TuneError(f"{' '.join(args)}: {detail}")
    return result.stdout


def ip_address(value: str):
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise TuneError(f"需要字面 IP 地址: {value}") from exc
    if getattr(address, "scope_id", None) or address.is_link_local:
        raise TuneError("此命令需要可直接路由的地址")
    return address


class LinuxHost:
    def __init__(self, proc=Path("/proc"), sys=Path("/sys"), etc=Path("/etc")):
        self.proc, self.sys, self.etc = proc, sys, etc

    def scope(self) -> dict:
        machine = read_text(self.etc / "machine-id") or platform.node()
        boot = read_text(self.proc / "sys/kernel/random/boot_id")
        try:
            namespace = (self.proc / "self/ns/net").stat().st_ino
        except OSError as exc:
            raise TuneError(f"无法识别网络命名空间: {exc}") from exc
        if not boot:
            raise TuneError("无法读取内核 boot ID")
        return {"machine": hashlib.sha256(machine.encode()).hexdigest(),
                "boot": boot, "netns": namespace}

    def in_init_netns(self) -> bool:
        try:
            return (self.proc / "1/ns/net").stat().st_ino == self.scope()["netns"]
        except OSError:
            return False

    def sysctl_path(self, key: str) -> Path:
        return self.proc / "sys" / key.replace(".", "/")

    def sysctl(self, key: str) -> Optional[str]:
        value = read_text(self.sysctl_path(key))
        return " ".join(value.split()) if value is not None else None

    def can_write(self, key: str) -> bool:
        return os.access(self.sysctl_path(key), os.W_OK)

    def write_sysctl(self, key: str, value: str) -> None:
        try:
            self.sysctl_path(key).write_text(value + "\n", encoding="ascii")
        except OSError as exc:
            raise TuneError(f"写入 {key} 失败: {exc}") from exc
        if self.sysctl(key) != value:
            raise TuneError(f"{key} 的运行值读回不匹配")

    def supports_cc(self, value: str) -> bool:
        if value in (self.sysctl(AVAILABLE_CC) or "").split():
            return True
        if shutil.which("modinfo"):
            return command(["modinfo", "-F", "filename", f"tcp_{value}"]).returncode == 0
        return False

    def os_release(self) -> str:
        data = read_text(self.etc / "os-release") or ""
        for line in data.splitlines():
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip("'\"")
        return "Linux"

    def memory(self) -> dict:
        data = read_text(self.proc / "meminfo") or ""
        memory = {}
        for key in ("MemTotal", "MemAvailable", "SwapTotal"):
            match = re.search(rf"^{key}:\s+(\d+)\s+kB", data, re.M)
            memory[key] = int(match[1]) * 1024 if match else None
        limits = [memory["MemTotal"]] if memory["MemTotal"] else []
        cgroups = read_text(self.proc / "self/cgroup") or ""
        for line in cgroups.splitlines():
            _, controllers, path = line.split(":", 2)
            if controllers and "memory" not in controllers.split(","):
                continue
            base = self.sys / "fs/cgroup"
            filename = "memory.max"
            if controllers:
                base, filename = base / "memory", "memory.limit_in_bytes"
            relative = Path(path.lstrip("/"))
            if ".." in relative.parts:
                continue
            for parent in (relative, *relative.parents):
                limit = read_text(base / parent / filename)
                if limit and limit.isdecimal() and int(limit) > 0:
                    limits.append(int(limit))
        memory["effective_limit_bytes"] = min(limits) if limits else None
        return memory

    def backend(self) -> Optional[str]:
        init = read_text(self.proc / "1/comm")
        if init == "systemd":
            return "systemd"
        if shutil.which("rc-update") and shutil.which("sysctl"):
            services = command(["rc-update", "show", "-v"])
            help_text = command(["sysctl", "--help"])
            if (services.returncode == 0
                    and re.search(r"^\s*sysctl\s*\|\s*\S", services.stdout, re.M)
                    and "--system" in help_text.stdout + help_text.stderr):
                return "openrc"
        return None

    def ip_json(self, *args: str) -> list:
        return self._command_json(["ip", "-j", *args])

    def tc_json(self, *args: str) -> list:
        return self._command_json(["tc", "-j", *args])

    @staticmethod
    def _command_json(args: list[str]) -> list:
        try:
            data = json.loads(checked(args))
        except ValueError as exc:
            raise TuneError(f"{args[0]} 返回了无效的 JSON") from exc
        if not isinstance(data, list):
            raise TuneError(f"{args[0]} 返回了意外的 JSON 结构")
        return data

    def route(self, destination: str, source=None, port=None, protocol="tcp") -> dict:
        ip = ip_address(destination)
        args = [f"-{ip.version}", "route", "get", str(ip)]
        if source:
            src = ip_address(source)
            if ip.version != src.version:
                raise TuneError("源地址和对端地址的协议族不同")
            args += ["from", str(src)]
        if port:
            args += ["ipproto", protocol, "dport", str(port)]
        routes = self.ip_json(*args)
        if len(routes) != 1 or not routes[0].get("dev"):
            raise TuneError(f"无法确定到 {destination} 的出口")
        return routes[0]

    def default_ipv4_route(self, *, include_mtu: bool = False) -> dict:
        lines = checked(["ip", "-4", "-o", "route", "show", "table", "main", "default"]).splitlines()
        tokens = lines[0].split() if len(lines) == 1 else []
        if (not tokens or tokens[0] != "default" or tokens.count("dev") != 1
                or any(token in tokens for token in ("nexthop", "nhid", "expires", "linkdown"))):
            raise TuneError("路由调整需要一条可精确恢复的 IPv4 主表默认路由")
        device = tokens.index("dev")
        if device + 1 >= len(tokens):
            raise TuneError("默认路由缺少出口网卡")
        interface = tokens[device + 1]
        metrics = {"initcwnd": None}
        if include_mtu:
            metrics["mtu"] = None
        for key in metrics:
            if key not in tokens:
                continue
            position = tokens.index(key)
            if (tokens.count(key) != 1 or position + 1 >= len(tokens)
                    or not tokens[position + 1].isdecimal()):
                raise TuneError(f"默认路由的 {key} 被锁定或无法读取")
            metrics[key] = int(tokens[position + 1])
            del tokens[position:position + 2]
        return {"tokens": tokens, "interface": interface, **metrics}

    def check_route_mtu(self, interface: str, value: int) -> None:
        link_mtu = self.link(interface).get("mtu")
        if type(link_mtu) is not int or value > link_mtu:
            raise TuneError(f"{interface} 的接口 MTU 无法承载默认路由 MTU {value}")

    def set_default_ipv4_route(self, state: dict) -> None:
        args = ["ip", "-4", "route", "replace", *state["tokens"], "table", "main"]
        for key in ("initcwnd", "mtu"):
            if state.get(key) is not None:
                args += [key, str(state[key])]
        checked(args)
        if self.default_ipv4_route(include_mtu="mtu" in state) != state:
            raise TuneError("IPv4 默认路由读回不匹配")

    def link(self, interface: str, detailed=False) -> dict:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", interface) or interface.startswith("-"):
            raise TuneError(f"无效的网卡名: {interface!r}")
        options = ("-d",) if detailed else ()
        links = self.ip_json(*options, "link", "show", "dev", interface)
        if len(links) != 1 or not isinstance(links[0].get("ifindex"), int):
            raise TuneError(f"无法识别网卡 {interface}")
        return links[0]

    def gso_state(self, interface: str) -> dict:
        link = self.link(interface, detailed=True)
        flags = link.get("flags", [])
        if "UP" not in flags or "LOOPBACK" in flags:
            raise TuneError(f"{interface} 需要是已启用的非回环网卡")
        segments = link.get("gso_max_segs")
        if type(segments) is not int or not 1 <= segments <= 65535:
            raise TuneError(f"无法读取 {interface} 的 GSO 分段上限")
        return {"ifindex": link["ifindex"], "address": link.get("address"), "max_segs": segments}

    def set_gso_max_segs(self, interface: str, segments: int) -> None:
        checked(["ip", "link", "set", "dev", interface, "gso_max_segs", str(segments)])

    def queue_state(self, interface: str) -> dict:
        link = self.link(interface)
        if "UP" not in link.get("flags", []) or "LOOPBACK" in link.get("flags", []):
            raise TuneError(f"{interface} 需要是已启用的非回环网卡")
        queues = self.tc_json("-d", "qdisc", "show", "dev", interface)
        filters = self.tc_json("filter", "show", "dev", interface, "root")
        fields = ("kind", "handle", "root", "parent", "options", "ingress_block", "egress_block")
        return {"device": {"ifindex": link["ifindex"], "address": link.get("address")},
                "queues": [{key: queue[key] for key in fields if key in queue}
                           for queue in queues],
                "root_filters": filters}

    def can_attach(self, interface: str, state: dict) -> None:
        queues = state["queues"]
        if len(queues) != 1:
            raise TuneError(f"{interface} 存在多队列或额外的队列，无法保证精确恢复")
        root = queues[0]
        default = self.sysctl(DEFAULT_QDISC)
        if (not root.get("root") or root.get("handle") != "0:"
                or root.get("kind") not in {"noqueue", "pfifo_fast", "fq", "fq_codel"}
                or root.get("kind") not in {"noqueue", "pfifo_fast", default}
                or "ingress_block" in root or "egress_block" in root
                or self.tc_json("class", "show", "dev", interface)
                or state["root_filters"]):
            raise TuneError(f"{interface} 已有非默认队列或策略，拒绝接管")

    def set_fq_pacing(self, interface: str, handle: str, enabled: bool) -> None:
        checked(["tc", "qdisc", "change", "dev", interface, "root", "handle", handle, "fq",
                 "pacing" if enabled else "nopacing"])

    def add_shaper(self, interface: str, kind: str, rate: int) -> None:
        args = ["tc", "qdisc", "add", "dev", interface, "root", "handle", QDISC_HANDLE, kind]
        if kind == "cake":
            args += ["bandwidth", f"{rate}mbit", "besteffort"]
        else:
            burst = max(32768, rate * 1000)  # At least 8 ms of bytes.
            args += ["rate", f"{rate}mbit", "burst", str(burst), "latency", "30ms"]
        checked(args)

    def remove_shaper(self, interface: str) -> None:
        checked(["tc", "qdisc", "del", "dev", interface, "root", "handle", QDISC_HANDLE])


def counters(host: LinuxHost) -> dict:
    values = {}
    for name in ("snmp", "netstat"):
        data = read_text(host.proc / "net" / name) or ""
        lines = data.splitlines()
        for header, counts in zip(lines[::2], lines[1::2]):
            keys, numbers = header.split(), counts.split()
            if keys and numbers and keys[0] == numbers[0] and keys[0] in {"Tcp:", "TcpExt:", "Udp:"}:
                values[keys[0][:-1]] = {
                    key: int(value) for key, value in zip(keys[1:], numbers[1:])
                    if value.lstrip("-").isdigit()
                }
    softnet = read_text(host.proc / "net/softnet_stat")
    if softnet:
        totals = [0, 0, 0]
        for line in softnet.splitlines():
            for index, value in enumerate(line.split()[:3]):
                totals[index] += int(value, 16)
        values["softnet"] = dict(zip(("processed", "dropped", "time_squeeze"), totals))
    return values


def inspect(host: LinuxHost, peer=None, interface=None) -> dict:
    warnings, routes, links, queues = [], {}, [], {}
    if shutil.which("ip"):
        for family in (4, 6):
            try:
                routes[str(family)] = host.ip_json(f"-{family}", "route", "show", "default")
            except TuneError as exc:
                warnings.append(str(exc))
        if peer:
            ip_address(peer)
            try:
                route = host.route(peer)
                routes["peer"] = route
                interface = interface or route["dev"]
            except TuneError as exc:
                warnings.append(str(exc))
        device = ("dev", interface) if interface else ()
        try:
            links = host.ip_json("-s", "link", "show", *device)
        except TuneError as exc:
            warnings.append(str(exc))
        for link in links:
            rate = read_text(host.sys / "class/net" / link["ifname"] / "speed")
            if rate and rate.isdecimal() and int(rate) > 0:
                link["speed_mbps"] = int(rate)
        if shutil.which("tc"):
            for link in links:
                name = link["ifname"]
                try:
                    queues[name] = host.tc_json("-s", "-d", "qdisc", "show", "dev", name)
                except TuneError as exc:
                    warnings.append(str(exc))
    else:
        warnings.append("缺少 iproute2 的 ip，路由与网卡详情不可用")
    memory = host.memory()
    return {
        "os": host.os_release(), "kernel": platform.release(), "arch": platform.machine(),
        "page_size_bytes": os.sysconf("SC_PAGESIZE"), "cpu_count": len(os.sched_getaffinity(0)),
        "memory": memory, "persistence_backend": host.backend(),
        "sysctl": {key: host.sysctl(key) for key in INSPECT_KEYS},
        "routes": routes, "links": links, "qdiscs": queues, "counters": counters(host),
        "tools": {name: bool(shutil.which(name)) for name in ("ip", "tc", "iperf3", "ping")},
        "warnings": warnings,
    }
