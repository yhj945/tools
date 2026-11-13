"""Bounded sender TCP socket observations, without collecting application data."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time


def socket_row(line, now, available_cc=None):
    fields = line.split(None, 5)
    if len(fields) != 6:
        return None
    state, _, _, local, peer, details = fields
    values = {k: int(v) for k, v in re.findall(r"\b(bytes_sent|bytes_acked|bytes_retrans|bytes_received|data_segs_out):(\d+)", details)}
    if "bytes_sent" not in values or "bytes_acked" not in values:
        return None
    retrans = values.get("bytes_retrans")
    if retrans is None and not re.search(r"\bretrans:\d+/[1-9]", details):
        retrans = 0
    cookie = re.search(r"\bsk:([0-9a-f]+)\b", details)
    cc = re.search(r"(?:^|\s)([a-z][a-z0-9_]*)\s+(?:wscale:|rto:)", details)
    algorithms = available_cc if available_cc is not None else {"reno", "cubic", "bbr", "bbr2", "bbr3"}
    algorithm = cc[1] if cc and cc[1] in algorithms else None
    return {"time": now, "local": local, "peer": peer, "state": state,
            "id": hashlib.sha256((local + " " + peer + " " + (cookie[1] if cookie else str(now))).encode()).hexdigest()[:20],
            "cc": algorithm, "retransmitted_bytes": retrans, **values}


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, allow_nan=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def collect(directory, port, seconds):
    """Close events contain final counters, including retransmits after the last poll."""
    directory = Path(directory)
    rows, errors, pending, stopping = [], [], b"", False
    def stop(*_):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    args = ["stdbuf", "-oL", "ss", "-H", "-O", "-E", "-n", "-t", "-i", "-e"]
    if port:
        args.append(f"( sport = :{port} )")
    process = None
    complete = True
    known_cc, cc_errors = {}, []
    try:
        available_cc = set(Path("/proc/sys/net/ipv4/tcp_available_congestion_control").read_text().split())
    except OSError:
        available_cc = set()
    try:
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={**os.environ, "LC_ALL": "C"})
        time.sleep(.15)
        if process.poll() is not None:
            raise RuntimeError(process.stderr.read().decode(errors="replace")[:500] or "ss 关闭事件不可用")
        write_json(directory / "ready.json", {"ready": True, "epoch": time.time()})
        deadline = time.monotonic() + seconds
        next_poll = 0.
        while not stopping and time.monotonic() < deadline:
            # Some kernels omit congestion control from destruction events.
            # Match a live observation by socket cookie; never infer it from
            # the host default or mistake TCP option flags for an algorithm.
            if port and time.monotonic() >= next_poll:
                try:
                    live = subprocess.run([a for a in args if a not in {"stdbuf", "-oL", "-E"}],
                                          capture_output=True, text=True, timeout=1, env={**os.environ, "LC_ALL":"C"})
                    if live.returncode == 0 and len(live.stdout) <= 4*1024*1024:
                        for line in live.stdout.splitlines()[:4096]:
                            row = socket_row(line, time.time(), available_cc)
                            if row and row["cc"]:
                                known_cc[row["id"]] = row["cc"]
                        while len(known_cc) > 4096:
                            del known_cc[next(iter(known_cc))]
                    elif not cc_errors:
                        cc_errors.append("无法完成活动连接算法观察")
                except (OSError, subprocess.TimeoutExpired) as exc:
                    if not cc_errors:
                        cc_errors.append(str(exc))
                next_poll = time.monotonic() + .5
            readable, _, _ = select.select([process.stdout, process.stderr], [], [], .1)
            for stream in readable:
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    if not stopping:
                        complete = False
                        errors.append("发送端观察进程提前退出")
                    stopping = True
                    continue
                if stream == process.stderr:
                    errors.append(chunk.decode(errors="replace")[:500]); complete = False
                    continue
                *lines, pending = (pending + chunk).split(b"\n")
                for line in lines:
                    row = socket_row(line.decode(errors="replace"), time.time(), available_cc)
                    if row:
                        row["cc"] = row["cc"] or known_cc.get(row["id"])
                        rows.append(row)
                if len(rows) > 4096 or len(pending) > 65536:
                    complete = False; stopping = True
                    errors.append("连接观察达到容量上限，重传证据不用于选优")
        if not stopping:
            complete = False
            errors.append("连接观察达到时限")
    except (OSError, RuntimeError) as exc:
        complete = False; errors.append(str(exc))
        write_json(directory / "ready.json", {"ready": False, "error": str(exc)})
    finally:
        if process:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            process.stdout.close(); process.stderr.close()
        write_json(directory / "result.json", {"complete": complete, "events": rows[:4096], "errors": errors,
                                               "cc_errors": cc_errors, "method": "sender_tcp_info_close", "service_port": port})


def attach_downloads(report, observation, clock_offset=0.):
    """Only one-to-one, full-payload sender matches count as retransmission evidence."""
    targets = [a for a in report["attempts"] if report["matrix"][a["case"]]["kind"] == "download" and a.get("sample")]
    events = observation.get("events", []) if observation.get("complete") else []
    choices = []
    for attempt in targets:
        sample = attempt["sample"]
        start, end = attempt["start"] + clock_offset, attempt["end"] + clock_offset
        size = sample["bytes"]
        choices.append([e for e in events if sample["complete"] and size > 0
                        and start <= e["time"] <= end + 3
                        and size <= e["bytes_acked"] <= size * 1.20 + 65536
                        and e["retransmitted_bytes"] is not None])
    solutions = []
    def solve(index, used, selected):
        if len(solutions) > 1:
            return
        if index == len(choices):
            solutions.append(selected); return
        if not choices[index]:
            solve(index + 1, used, selected + [None]); return
        for event in choices[index]:
            if event["id"] not in used:
                solve(index + 1, used | {event["id"]}, selected + [event])
    solve(0, set(), [])
    matches = []
    for index, attempt in enumerate(targets):
        event = solutions[0][index] if len(solutions) == 1 else None
        attempt["sample"]["retransmitted_bytes"] = event["retransmitted_bytes"] if event else None
        attempt["sample"]["sender_cc"] = event["cc"] if event else None
        matches.append({"round": attempt["round"], "case": attempt["case"], "matched": event is not None,
                        "candidates": len(choices[index]), "socket": event})
    report["tcp_observation"] = {"method": observation.get("method"), "complete": observation.get("complete", False),
                                 "errors": observation.get("errors", []), "matches": matches,
                                 "cc_errors": observation.get("cc_errors", []),
                                 "limitation": "仅统计完整下载唯一对应的发送端连接；缺失、失败和有歧义的连接保持未知"}
    return report


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    collect(sys.argv[1], int(sys.argv[2]), float(sys.argv[3]))
