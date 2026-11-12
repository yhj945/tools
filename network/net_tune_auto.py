"""Choose a tuning plan from bounded benchmarks or paired results."""

from __future__ import annotations

import math
import os
from statistics import median

from net_tune_bench import bench, number
from net_tune_changes import build_plan, valid_cc
from net_tune_system import (AVAILABLE_CC, BASE_MSS, CC, DEFAULT_QDISC, MTU_PROBING,
                             PROBE_MSS_RANGE, RCV, ROUTE_MTU_RANGE, SND, TuneError,
                             inspect, ip_address, load_object)

RESULTS_FORMAT = "net-tune-results-v1"
BASELINE_KEYS = (CC, RCV, SND, DEFAULT_QDISC, BASE_MSS, MTU_PROBING,
                 "net.ipv4.tcp_slow_start_after_idle", "net.ipv4.tcp_rto_min_us")
REGRESSION_TOLERANCE = .05


def check_results_baseline(host, data):
    baseline = data["baseline"]
    interface = data["interface"]
    peer = str(ip_address(data["peer"]))
    if data["scope"] != host.scope():
        raise TuneError("实测记录对应的主机、启动周期或网络命名空间已变化")
    if host.route(peer)["dev"] != interface:
        raise TuneError("实测对端的出口已变化，请重新测速")
    current = {
        "sysctl": {key: host.sysctl(key) for key in BASELINE_KEYS},
        "queue": host.queue_state(interface),
        "gso": host.gso_state(interface),
    }
    if "route" in baseline:
        current["route"] = host.default_ipv4_route()
    if current != baseline:
        raise TuneError("当前配置与实测基线不同，请重新测速或回滚后再选型")
    return interface, peer


def read_sample(sample, size):
    complete = sample["complete"]
    elapsed = number(sample["seconds"])
    received = sample["bytes"]
    edge = sample["edge"]
    retrans = sample.get("retransmitted_bytes")
    if (type(complete) is not bool or not elapsed or elapsed <= 0
            or type(received) is not int or not 0 <= received <= size
            or complete and (received != size or not isinstance(edge, str) or not edge)
            or retrans is not None and (type(retrans) is not int or retrans < 0)):
        raise ValueError
    return complete, elapsed, edge, retrans


def evaluate_workload(workload):
    size = workload["bytes"]
    pairs = workload["pairs"]
    if type(size) is not int or size <= 0 or not isinstance(pairs, list) or not pairs:
        raise ValueError
    before_count = after_count = 0
    rates, ratios, retrans, edges = [], [], [], set()
    for pair in pairs:
        a, b = (read_sample(pair[key], size) for key in ("before", "after"))
        before_count += a[0]
        after_count += b[0]
        edges.update(row[2] for row in (a, b) if row[0])
        if b[0]:
            rates.append(size * 8 / b[1] / 1_000_000)
        if a[0] and b[0] and a[2] == b[2]:
            ratios.append(a[1] / b[1])
            if a[3] is not None and b[3] is not None:
                retrans.append((a[3], b[3]))
    gain = median(ratios) if ratios else None
    loss_before = sum(a for a, _ in retrans)
    loss_after = sum(b for _, b in retrans)
    loss_delta = loss_after - loss_before if retrans else None
    eligible = (
        len(pairs) >= 2 and len(edges) == 1 and after_count >= before_count
        and (after_count > before_count or len(ratios) >= 2)
        and (gain is None or gain >= 1 - REGRESSION_TOLERANCE)
        and (len(retrans) < 2 or loss_delta <= loss_before * REGRESSION_TOLERANCE)
    )
    return {"bytes": size, "rounds": len(pairs), "before_completed": before_count,
            "after_completed": after_count, "paired_goodput_ratio": gain,
            "candidate_median_mbps": median(rates) if rates else None,
            "retransmission_pairs": len(retrans), "retransmitted_delta_bytes": loss_delta,
            "eligible": eligible}


def candidate_settings(values):
    ranges = {"initcwnd": (1, 65535), "route_mtu": ROUTE_MTU_RANGE, "mtu_probe_mss": PROBE_MSS_RANGE}
    boolean = ("gso_single_segment", "enable_fq_pacing")
    if not isinstance(values, dict) or not values or set(values) - {"cc", "profile", *ranges, *boolean}:
        raise ValueError
    for key, value in values.items():
        if key in ranges and (type(value) is not int or not ranges[key][0] <= value <= ranges[key][1]):
            raise ValueError
        if key in boolean and type(value) is not bool:
            raise ValueError
        if key == "cc" and not valid_cc(value):
            raise ValueError
        if key == "profile" and value != "vless":
            raise ValueError
    return values


def choose_results(host, store, data, parse):
    if data.get("format") != RESULTS_FORMAT:
        raise TuneError("需要 net_tune 的配对实测记录")
    try:
        interface, peer = check_results_baseline(host, data)
        candidates, ranked, names = [], [], set()
        workloads = None
        for item in data["candidates"]:
            name = item["name"]
            settings = candidate_settings(item["settings"])
            cases = [evaluate_workload(case) for case in item["workloads"]]
            matrix = {case["bytes"]: case["rounds"] for case in cases}
            if (not isinstance(name, str) or not name or name in names or not matrix
                    or len(matrix) != len(cases) or workloads is not None and matrix != workloads):
                raise ValueError
            workloads = matrix
            names.add(name)
            completion_gain = sum(c["after_completed"] - c["before_completed"] for c in cases)
            ratio = median(c["paired_goodput_ratio"] or 1 for c in cases)
            retrans_gain = -sum(c["retransmitted_delta_bytes"] or 0 for c in cases)
            eligible = all(c["eligible"] for c in cases) and (completion_gain > 0 or ratio > 1 or retrans_gain > 0)
            candidate = {"name": name, "workloads": cases, "eligible": eligible}
            candidates.append(candidate)
            if not eligible:
                continue
            if {"initcwnd", "route_mtu"} & settings.keys() and "route" not in data["baseline"]:
                raise ValueError
            design = parse(["plan", "--interface", interface])
            vars(design).update(settings)
            try:
                plan = build_plan(host, store, design)
                store.check_current(plan)
            except TuneError as exc:
                candidate.update(eligible=False, reason=str(exc))
                continue
            # When the control times out, absolute candidate goodput breaks the tie.
            completed = sum(c["after_completed"] for c in cases)
            speed = median(math.log(c["candidate_median_mbps"]) for c in cases)
            ranked.append(((completed, completion_gain, ratio, speed, retrans_gain), name, plan))
        if not candidates:
            raise ValueError
        selected = max(ranked, key=lambda row: row[0]) if ranked else None
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError) as exc:
        raise TuneError("配对实测记录内容不完整，或候选的测试矩阵不同") from exc
    return peer, interface, (selected[2] if selected else None), {
        "method": "paired_results", "selected": selected[1] if selected else None,
        "candidates": candidates, "reason": "按完成率、吞吐和重传比较同路径配对样本" if selected
        else "当前实测记录没有通过筛选的候选",
    }


def auto_plan(host, store, args, parse):
    plan = benchmark = peer = interface = None
    selection = {"method": "local", "selected": None, "reason": "已识别本机配置，需要同路径测速才能优选"}
    if args.from_results:
        peer, interface, plan, selection = choose_results(host, store, load_object(args.from_results), parse)
    elif args.peer or args.from_bench:
        if args.from_bench:
            benchmark = load_object(args.from_bench)
        else:
            available = (host.sysctl(AVAILABLE_CC) or "").split()
            if os.geteuid():
                allowed = (host.sysctl("net.ipv4.tcp_allowed_congestion_control") or "").split()
                available = [cc for cc in available if cc in allowed]
            current = host.sysctl(CC)
            alternatives = [cc for cc in ("bbr", "cubic", "reno") if cc in available and cc != current][:1]
            measure = parse(["bench", "--peer", args.peer, "--port", str(args.port),
                             "--budget-mib", str(args.budget_mib), "--rates-mbps", str(args.rate_mbps),
                             "--cc", ",".join(["default", *alternatives]), "--direction", "up",
                             "--streams", "1", "--rounds", "3"] + (["--dry-run"] if args.dry_run else []))
            benchmark = bench(host, measure)
        if benchmark.get("complete"):
            design = parse(["plan", "--cc", "auto"])
            plan = build_plan(host, store, design, benchmark)
            store.check_current(plan)
            peer, interface = benchmark["peer"], benchmark["route"]["dev"]
            selection = {"method": "iperf3", "selected": "bench", "reason": "已按测速报告生成调优计划"}
        elif benchmark.get("dry_run"):
            selection["reason"] = "测速预览"
        else:
            selection["reason"] = benchmark.get("stop_reason") or "测速样本不足，无法优选"
    report = inspect(host, peer, interface)
    if not interface:
        for family in ("4", "6"):
            devices = {row["dev"] for row in report["routes"].get(family, []) if row.get("dev")}
            if len(devices) == 1:
                interface = next(iter(devices))
                break
    return {"system": {"os": report["os"], "kernel": report["kernel"], "cpu_count": report["cpu_count"],
                       "memory_bytes": report["memory"]["effective_limit_bytes"], "interface": interface,
                       "cc": report["sysctl"].get(CC), "available_cc": report["sysctl"].get(AVAILABLE_CC),
                       "qdiscs": [row["kind"] for row in report["qdiscs"].get(interface, [])]},
            "selection": selection, "plan": plan, "benchmark": benchmark}
