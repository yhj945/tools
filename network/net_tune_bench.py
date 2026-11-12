"""Budgeted path measurements and like-for-like report comparisons."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from itertools import product
import json
import math
import os
import platform
import re
import select
import shutil
import socket
from statistics import median
import subprocess
import sys
import time

from net_tune_system import CC, RCV, SND, LinuxHost, TuneError, command, ip_address

MIB = 1024 ** 2
PROBE_BYTES = 4096
PROBE_TIMEOUT = 5
METRICS = ("goodput_mbps", "load_rtt_p95_ms", "retransmits_per_mib",
           "udp_loss_pct", "udp_jitter_ms", "local_cpu_pct", "remote_cpu_pct")
RETRANS_BYTES_PER_MIB = "retransmitted_bytes_per_mib"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@dataclass(frozen=True)
class Trial:
    round: int
    direction: str
    streams: int
    rate_mbps: int
    cc: str
    protocol: str
    seconds: int

    @property
    def rate_per_stream(self) -> int:
        return self.rate_mbps * 1_000_000 // self.streams

    @property
    def block(self) -> int:
        return 32768 if self.protocol == "tcp" else 1200

    @property
    def timeout(self) -> int:
        return self.seconds + 5

    @property
    def margin(self) -> int:
        return 128 * 1024 + 2 * self.streams * self.block

    @property
    def reserve(self) -> int:
        # A reverse sender can continue until iperf3's server timer after a disconnect.
        seconds = self.seconds + 40 if self.direction == "down" else self.timeout
        return math.ceil(self.rate_per_stream * self.streams * seconds / 8) + self.margin

    def args(self, peer: str, port: int, source: str) -> list[str]:
        family = ip_address(peer).version
        args = ["iperf3", "-J", f"-{family}", "-c", peer, "-p", str(port),
                "-t", str(self.seconds), "-P", str(self.streams), "-i", "0.5",
                "-b", str(self.rate_per_stream), "-l", str(self.block),
                "--connect-timeout", "2000", "--get-server-output"]
        if source:
            args += ["-B", source]
        if self.direction == "down":
            args.append("-R")
        if self.protocol == "udp":
            args.append("-u")
        elif self.cc != "default":
            args += ["-C", self.cc]
        return args


def trials_for(args) -> list[Trial]:
    directions = ("up", "down") if args.direction == "both" else (args.direction,)
    count = args.rounds * len(directions) * len(args.streams) * len(args.rates_mbps) * len(args.cc)
    if count > 120:
        raise TuneError("一次最多安排 120 个测速样本，请缩小测试矩阵")
    trials = []
    for round_no in range(1, args.rounds + 1):
        algorithms = args.cc if round_no % 2 else args.cc[::-1]
        combinations = product(directions, args.streams, args.rates_mbps, algorithms)
        trials.extend(Trial(round_no, direction, streams, rate, cc, args.protocol, args.seconds)
                      for direction, streams, rate, cc in combinations)
    return trials


def resolve_peer(peer: str, port: int, family, source) -> str:
    if source:
        version = ip_address(source).version
        if family and family != version:
            raise TuneError("源地址和指定的协议族不同")
        family = version
    try:
        addresses = socket.getaddrinfo(
            peer, port, {None: socket.AF_UNSPEC, 4: socket.AF_INET, 6: socket.AF_INET6}[family],
            socket.SOCK_STREAM,
        )
    except socket.gaierror as exc:
        raise TuneError(f"解析对端 {peer} 失败: {exc}") from exc
    address = ip_address(addresses[0][4][0])
    if address.is_unspecified or address.is_multicast:
        raise TuneError("需要单播测速对端")
    return str(address)


def idle_rtt(peer: str, source: str) -> list[float]:
    if not shutil.which("ping"):
        return []
    args = ["ping", f"-{ip_address(peer).version}", "-n", "-c", "3", "-W", "1"]
    if source:
        args += ["-I", source]
    try:
        output = command([*args, peer], PROBE_TIMEOUT).stdout
    except TuneError:
        return []
    return [float(value) for value in re.findall(r"\btime[=<]([\d.]+)\s*ms", output)]


def number(value):
    if type(value) in (int, float) and math.isfinite(value) and value >= 0:
        return value
    return None


def quantile(values: list[float], percentile: float):
    if values:
        return sorted(values)[math.ceil(percentile * len(values)) - 1]
    return None


def receiver_intervals(report: dict) -> dict:
    # Older UDP summaries publish sender bytes. Read the receiver's intervals.
    rows = [interval.get("sum", {}) for interval in report.get("intervals", [])]
    rows = [row for row in rows if row.get("sender") is False and not row.get("omitted")]
    if not rows:
        return {}
    received = sum(row.get("bytes", 0) for row in rows)
    seconds = rows[-1]["end"] - rows[0]["start"]
    if seconds <= 0:
        return {}
    return {**report["end"].get("sum", {}), "bytes": received,
            "bits_per_second": received * 8 / seconds}


def parse_iperf(report: dict, trial: Trial) -> dict:
    if report.get("error"):
        raise TuneError(str(report["error"]))
    end = report.get("end", {})
    server = report.get("server_output_json") or {}
    sender = end.get("sum_sent")
    receiver = end.get("sum_received")
    if trial.protocol == "udp" and not receiver:
        sender = end.get("sum")
        receiver = receiver_intervals(report if trial.direction == "down" else server)
    sender, receiver = sender or {}, receiver or {}
    sent = number(sender.get("bytes"))
    received = number(receiver.get("bytes"))
    goodput = number(receiver.get("bits_per_second"))
    if not sent or received is None or goodput is None:
        raise TuneError("测速缺少发送量或接收端吞吐汇总（旧版 UDP 需要对端以 -J 启动）")
    cc = end.get("sender_tcp_congestion")
    if trial.cc != "default" and trial.cc != cc:
        raise TuneError(f"发送端拥塞控制读回为 {cc or '未知'}，预期 {trial.cc}")
    source = report if trial.direction == "up" else server
    samples = [
        float(stream["rtt"]) / 1000
        for interval in source.get("intervals", [])
        for stream in interval.get("streams", [])
        if stream.get("sender") is True and not stream.get("omitted")
        and number(stream.get("rtt"))
    ]
    retransmits = number(sender.get("retransmits"))
    cpu = end.get("cpu_utilization_percent", {})
    return {
        "goodput_mbps": goodput / 1_000_000,
        "sent_bytes": int(sent), "received_bytes": int(received),
        "retransmits": retransmits,
        "retransmits_per_mib": retransmits * MIB / sent if retransmits is not None else None,
        "load_rtt_ms": samples, "load_rtt_p95_ms": quantile(samples, 0.95),
        "udp_loss_pct": number(receiver.get("lost_percent")) if trial.protocol == "udp" else None,
        "udp_jitter_ms": number(receiver.get("jitter_ms")) if trial.protocol == "udp" else None,
        "local_cpu_pct": number(cpu.get("host_total")), "remote_cpu_pct": number(cpu.get("remote_total")),
        "sender_cc": cc, "iperf_version": report.get("start", {}).get("version"),
    }


def closed_socket_retransmitted_bytes(events, connected, streams: int, deadline: float):
    ports = {str(row["local_port"]).encode() for row in connected
             if isinstance(row, dict) and type(row.get("local_port")) is int}
    if len(ports) != streams:
        return None
    poll = select.poll()
    poll.register(events, select.POLLIN)
    remaining, pending, total = ports, b"", 0
    while remaining:
        seconds = deadline - time.monotonic()
        if seconds <= 0 or not poll.poll(math.ceil(seconds * 1000)):
            return None
        chunk = os.read(events.fileno(), 65536)
        if not chunk:
            return None
        *lines, pending = (pending + chunk).split(b"\n")
        for line in lines:
            fields = line.split(None, 5)
            if len(fields) != 6:
                continue
            local_port = fields[3].rsplit(b":", 1)[-1]
            if local_port not in remaining:
                continue
            details = fields[5]
            count = re.search(rb"\bbytes_retrans:(\d+)\b", details)
            if count:
                total += int(count[1])
            elif b"bytes_sent:" not in details or re.search(rb"\bretrans:\d+/[1-9]", details):
                return None
            remaining.remove(local_port)
    return total


def trial_report(result) -> dict:
    try:
        report = json.loads(result.stdout)
    except ValueError as exc:
        detail = result.stderr.strip() or "iperf3 未返回 JSON"
        raise TuneError(detail) from exc
    if not isinstance(report, dict):
        raise TuneError("iperf3 返回了意外的 JSON")
    if result.returncode:
        raise TuneError(str(report.get("error") or result.stderr.strip() or result.returncode))
    return report


def run_trial(trial: Trial, peer: str, port: int, source: str) -> dict:
    deadline = time.monotonic() + trial.timeout
    trace = None
    local_tcp = trial.protocol == "tcp" and trial.direction == "up"
    if local_tcp and shutil.which("ss") and shutil.which("stdbuf"):
        try:
            trace = subprocess.Popen(["stdbuf", "-oL", "ss", "-H", "-E", "-O", "-n", "-t", "-i",
                                      f"( dst {peer} and dport = :{port} )"], stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env={**os.environ, "LC_ALL": "C"})
        except OSError:
            pass
    try:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TuneError("测速启动时限已用完")
        result = command(trial.args(peer, port, source), remaining)
        report = trial_report(result)
        metrics = parse_iperf(report, trial)
        if local_tcp:
            amount = None
            connected = report.get("start", {}).get("connected")
            if trace and isinstance(connected, list):
                try:
                    amount = closed_socket_retransmitted_bytes(
                        trace.stdout, connected, trial.streams, min(deadline, time.monotonic() + .6)
                    )
                except OSError:
                    pass
            if amount == 0 and metrics["retransmits"]:
                amount = None
            received = metrics["received_bytes"]
            metrics["retransmitted_bytes"] = amount
            metrics[RETRANS_BYTES_PER_MIB] = amount * MIB / received if amount is not None and received else None
        return metrics
    except (TypeError, KeyError, AttributeError, OverflowError) as exc:
        raise TuneError("iperf3 JSON 汇总不完整") from exc
    finally:
        if trace:
            trace.terminate()
            try:
                trace.wait(timeout=.2)
            except subprocess.TimeoutExpired:
                trace.kill()
                trace.wait()
            trace.stdout.close()


def bench(host: LinuxHost, args) -> dict:
    if args.protocol == "udp" and args.cc != ["default"]:
        raise TuneError("拥塞控制对照需要 TCP")
    trials = trials_for(args)
    budget = args.budget_mib * MIB
    peak = max(trial.reserve for trial in trials) + PROBE_BYTES
    report = {
        "format": "net-tune-bench-v1", "created": utc_now(), "budget_bytes": budget,
        "max_trial_reservation_bytes": peak - PROBE_BYTES,
        "worst_case_bytes": PROBE_BYTES + sum(trial.reserve for trial in trials) * (1 + args.retries),
        "nominal_payload_bytes": sum(trial.rate_per_stream * trial.streams * trial.seconds // 8
                                     for trial in trials),
        "planned_samples": len(trials), "trial_plan": [asdict(trial) for trial in trials],
    }
    source = str(ip_address(args.source)) if args.source else None
    if args.dry_run:
        report.update({"dry_run": True, "budget_fits_largest_trial": budget >= peak})
        return report
    if peak > budget:
        raise TuneError(f"首轮前预算检查失败，最大单轮至少需要 {math.ceil(peak / MIB)} MiB")
    if args.deadline < PROBE_TIMEOUT + max(trial.timeout for trial in trials):
        raise TuneError("总时限不足以覆盖一轮测速和 RTT 探测")
    if not shutil.which("iperf3"):
        raise TuneError("测速需要 iperf3")
    expires = time.monotonic() + args.deadline
    peer = resolve_peer(args.peer, args.port, args.family, source)
    route = host.route(peer, source, args.port, args.protocol)
    source = source or route.get("prefsrc") or route.get("from")
    if source:
        route = host.route(peer, source, args.port, args.protocol)
    if time.monotonic() + PROBE_TIMEOUT + trials[0].timeout > expires:
        raise TuneError("剩余时限不足以开始测速")
    charged = PROBE_BYTES
    sysctls = {key: host.sysctl(key) for key in (CC, RCV, SND)}
    report.update({
        "scope": host.scope(), "kernel": platform.release(),
        "peer": peer, "port": args.port, "source": source, "route": route,
        "local_cc": sysctls[CC], "sysctl": sysctls, "idle_rtt_ms": [], "attempts": [],
    })
    try:
        report["idle_rtt_ms"] = idle_rtt(peer, source)
    except KeyboardInterrupt:
        report.update({"interrupted": True, "charged_bytes": charged, "complete": False,
                       "stop_reason": "RTT 探测已中断", "summary": []})
        return report
    stop_reason = None
    for trial in trials:
        for attempt in range(1, args.retries + 2):
            if charged + trial.reserve > budget:
                stop_reason = "剩余流量预算不足以预留下一轮"
                break
            if time.monotonic() + trial.timeout > expires:
                stop_reason = "剩余时限不足以运行下一轮"
                break
            charged += trial.reserve
            record = {**asdict(trial), "attempt": attempt, "reserved_bytes": trial.reserve,
                      "charged_bytes": trial.reserve}
            report["attempts"].append(record)
            print(f"第 {trial.round} 轮 {trial.direction} {trial.streams} 流 "
                  f"{trial.rate_mbps} Mbps {trial.cc}，预留 {trial.reserve / MIB:.2f} MiB",
                  file=sys.stderr)
            try:
                metrics = run_trial(trial, peer, args.port, source)
            except KeyboardInterrupt:
                report["interrupted"] = True
                record["error"] = stop_reason = "测速已中断"
                break
            except TuneError as exc:
                record["error"] = str(exc)
                continue
            accounted = max(metrics["sent_bytes"], metrics["received_bytes"]) + trial.margin
            record.update({"metrics": metrics, "charged_bytes": accounted})
            charged += accounted - trial.reserve
            if accounted > trial.reserve:
                stop_reason = "对端报告的传输量超过本轮预留，已停止"
            break
        if stop_reason:
            break
    complete = sum("metrics" in item for item in report["attempts"]) == len(trials)
    report.update({
        "charged_bytes": charged, "stop_reason": stop_reason,
        "complete": complete and stop_reason is None,
        "summary": summaries(report["attempts"]),
    })
    return report


def sample_key(item: dict) -> tuple:
    return tuple(item[key] for key in ("protocol", "direction", "streams", "rate_mbps", "cc", "seconds"))


def summaries(attempts: list[dict]) -> list[dict]:
    groups = defaultdict(list)
    for item in attempts:
        if isinstance(item.get("metrics"), dict):
            groups[sample_key(item)].append(item["metrics"])
    result = []
    for key, items in groups.items():
        row = dict(zip(("protocol", "direction", "streams", "rate_mbps", "cc", "seconds"), key))
        row["samples"] = len(items)
        for metric in METRICS:
            values = [item[metric] for item in items if number(item.get(metric)) is not None]
            row[metric] = median(values) if values else None
        if any(RETRANS_BYTES_PER_MIB in item for item in items):
            values = [number(item.get(RETRANS_BYTES_PER_MIB)) for item in items]
            row[RETRANS_BYTES_PER_MIB] = median(values) if all(value is not None for value in values) else None
        rates = [item["goodput_mbps"] for item in items]
        row["goodput_range_mbps"] = [min(rates), max(rates)]
        rtt = [value for item in items for value in item.get("load_rtt_ms", [])]
        row["load_rtt_p95_ms"] = quantile(rtt, 0.95)
        result.append(row)
    return result


def trial_key(item: dict) -> tuple:
    return (item["round"], *sample_key(item))


def validated_report(report: dict) -> dict:
    if report.get("format") != "net-tune-bench-v1" or report.get("complete") is not True:
        raise TuneError("需要完整的 bench JSON 报告")
    try:
        if (not report["summary"] or not report["attempts"] or not report["route"]["dev"]
                or not isinstance(report["scope"], dict)
                or type(report["port"]) is not int or not 1 <= report["port"] <= 65535):
            raise ValueError
        ip_address(report["peer"])
        planned = [trial_key(row) for row in report["trial_plan"]]
        measured = [trial_key(row) for row in report["attempts"] if "metrics" in row]
        summary = summaries(report["attempts"])
        if (planned != measured or len(set(planned)) != len(planned)
                or len(planned) != report["planned_samples"] or summary != report["summary"]):
            raise ValueError
        if any(type(row["samples"]) is not int or number(row["goodput_mbps"]) is None
               for row in summary):
            raise ValueError
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError) as exc:
        raise TuneError("bench 报告内容不完整或样本与汇总不一致") from exc
    return report


def compare(before: dict, after: dict) -> list[dict]:
    before, after = validated_report(before), validated_report(after)
    for field in ("peer", "port", "source", "scope"):
        if before[field] != after[field]:
            raise TuneError(f"两个报告的 {field} 不同")
    for field in ("dev", "gateway", "table"):
        if before["route"].get(field) != after["route"].get(field):
            raise TuneError(f"两个报告的出口路由 {field} 不同")
    original = {sample_key(row): row for row in before["summary"]}
    candidate = {sample_key(row): row for row in after["summary"]}
    if original.keys() != candidate.keys():
        raise TuneError("两个报告的测试矩阵不同")
    rows = []
    for key, baseline in original.items():
        current = candidate[key]
        changes = {}
        metrics = METRICS
        if RETRANS_BYTES_PER_MIB in baseline or RETRANS_BYTES_PER_MIB in current:
            metrics += (RETRANS_BYTES_PER_MIB,)
        for metric in metrics:
            left, right = baseline.get(metric), current.get(metric)
            changes[metric] = {"before": left, "after": right,
                               "delta": right - left if left is not None and right is not None else None}
        a, b = baseline["goodput_range_mbps"], current["goodput_range_mbps"]
        rows.append({"case": baseline, "after_samples": current["samples"], "metrics": changes,
                     "goodput_ranges_overlap": max(a[0], b[0]) <= min(a[1], b[1])})
    return rows
