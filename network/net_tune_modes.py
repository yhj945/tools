"""Workload objectives; a mode changes evidence and acceptance, not kernel presets."""

from __future__ import annotations

import math
from statistics import median

from net_tune_bench import MIB, number, quantile
from net_tune_system import TuneError

MODES = {"balanced": "均衡", "download": "下载", "daily": "日常使用",
         "stability": "稳定性", "concurrency": "并发"}
KINDS = {"short", "download", "concurrent", "idle"}
MATRICES = {
    "balanced": (("short", 32768, 1), ("download", 4*MIB, 1), ("concurrent", 65536, 4), ("idle", 32768, 1)),
    "download": (("short", 65536, 1), ("download", 8*MIB, 1), ("concurrent", 524288, 4), ("idle", 32768, 1)),
    "daily": (("short", 16384, 1), ("download", MIB, 1), ("concurrent", 32768, 4), ("idle", 16384, 1)),
    "stability": (("short", 32768, 1), ("download", 4*MIB, 1), ("concurrent", 65536, 4), ("idle", 32768, 1)),
    "concurrency": (("short", 32768, 1), ("download", 4*MIB, 1), ("concurrent", 262144, 8), ("idle", 32768, 1)),
}


def sample_value(sample, size):
    complete, seconds, received = sample["complete"], sample["seconds"], sample["bytes"]
    first = sample.get("ttfb_seconds")
    retrans = sample.get("retransmitted_bytes")
    if (type(complete) is not bool or number(seconds) is None or seconds <= 0
            or type(received) is not int or not 0 <= received <= size
            or first is not None and (number(first) is None or first > seconds)
            or retrans is not None and (type(retrans) is not int or retrans < 0)
            or not isinstance(sample["edge"], str) or not sample["edge"]):
        raise ValueError
    return complete, seconds, received, first, retrans


def evaluate_cases(workloads, mode):
    """Require complete workload coverage before making a mode-specific decision."""
    if mode not in MODES:
        raise TuneError("无法识别优化模式")
    rows, seen = [], set()
    for case in workloads:
        kind, size, streams, pairs = (case[k] for k in ("kind", "bytes", "concurrency", "pairs"))
        key = (kind, size, streams, case["target"])
        if (kind not in KINDS or type(size) is not int or size < 1
                or type(streams) is not int or not 1 <= streams <= 16
                or kind != "concurrent" and streams != 1 or not isinstance(case["target"], str)
                or key in seen or not isinstance(pairs, list) or len(pairs) < 3):
            raise ValueError
        seen.add(key)
        left, right, edges, latency, firsts, loss = [], [], set(), [], [], []
        for pair in pairs:
            a, b = sample_value(pair["before"], size), sample_value(pair["after"], size)
            left.append(a); right.append(b)
            edges.update(s["edge"] for s in (pair["before"], pair["after"]) if s["complete"])
            if a[0] and b[0]:
                latency.append(a[1] / b[1])
                if a[3] and b[3]:
                    firsts.append(a[3] / b[3])
                if a[4] is not None and b[4] is not None:
                    loss.append((a[4], b[4]))
        before_ok, after_ok = sum(x[0] for x in left), sum(x[0] for x in right)
        before_median, after_median = (median(x[1] for x in group) for group in (left, right))
        med_gain = before_median / after_median
        paired_gain = median(latency) if latency else None
        rates = [[x[2] / x[1] for x in group if x[0] and x[2]] for group in (left, right)]
        speed_gain = median(rates[1]) / median(rates[0]) if all(rates) else None
        first_values = [[x[3] for x in group if x[0] and x[3]] for group in (left, right)]
        ttfb_gain = median(first_values[0]) / median(first_values[1]) if all(first_values) else None
        # Failed samples retain their timeout duration in the tail, rather than disappearing.
        tail_before, tail_after = (quantile([x[1] for x in group], .95) for group in (left, right))
        loss_before, loss_after = (sum(x[i] for x in loss) for i in (0, 1))
        reasons = []
        if len(edges) != 1:
            reasons.append("对端或边缘节点不同")
        elif next(iter(edges)) == "unverified" or next(iter(edges)).startswith("mixed:"):
            reasons.append("无法确认一致的对端")
        if after_ok < before_ok or not after_ok:
            reasons.append("完成率下降或没有完成样本")
        if after_ok == before_ok and len(latency) < 3:
            reasons.append("有效配对不足 3 对")
        if kind == "download":
            if any(x[0] and x[2] < min(size, MIB) for x in [*left, *right]):
                reasons.append("下载负载不足，需使用至少 1 MiB 的固定对象")
            if any(a[0] and b[0] and a[2] != b[2] for a,b in zip(left,right)):
                reasons.append("下载对照的实际数据量不同")
        tolerance = .10 if mode == "stability" else .05
        if med_gain is not None and med_gain < 1 / (1 + tolerance):
            reasons.append("中位完成耗时回退超出门槛")
        if paired_gain is not None and paired_gain < 1 / (1 + tolerance):
            reasons.append("配对完成耗时回退超出门槛")
        if speed_gain is not None and speed_gain < 1 - tolerance:
            reasons.append("吞吐回退超出门槛")
        if tail_after > tail_before * 1.10:
            reasons.append("p95 耗时回退超过 10%")
        if len(loss) >= 3 and loss_after > loss_before * 1.05:
            reasons.append("重传字节增加超过 5%")
        if kind in {"short", "idle"} and mode in {"daily", "balanced"}:
            if len(firsts) < 3:
                reasons.append("缺少首字节配对数据")
            elif ttfb_gain < 1 / 1.05:
                reasons.append("首字节耗时回退超过 5%")
        rows.append({"kind": kind, "target": case["target"], "bytes": size, "concurrency": streams,
                     "rounds": len(pairs), "before_completed": before_ok, "after_completed": after_ok,
                     "median_latency_gain": med_gain, "median_goodput_gain": speed_gain,
                     "paired_latency_gain": paired_gain,
                     "before_median_seconds": before_median, "after_median_seconds": after_median,
                     "median_ttfb_gain": ttfb_gain, "before_p95_seconds": tail_before,
                     "after_p95_seconds": tail_after, "retransmission_pairs": len(loss),
                     "before_retransmitted_bytes": loss_before if loss else None,
                     "after_retransmitted_bytes": loss_after if loss else None,
                     "eligible": not reasons, "reasons": reasons})
    kinds = {r["kind"] for r in rows}
    if kinds != KINDS:
        return {"mode": mode, "eligible": False, "reason": "需要小请求、下载、并发和空闲后请求四类配对证据",
                "workloads": rows, "rank": None}
    completion_gain = sum(r["after_completed"] - r["before_completed"] for r in rows)
    def geometric(values):
        values = [x for x in values if x is not None and x > 0]
        return math.exp(sum(math.log(x) for x in values) / len(values)) if values else 1.
    latency_gain = geometric(r["median_latency_gain"] for r in rows)
    tail_gain = geometric(r["before_p95_seconds"] / r["after_p95_seconds"] for r in rows)
    if mode == "daily":
        objective = geometric([
            geometric(r["median_ttfb_gain"] for r in rows if r["kind"] in {"short", "idle"}),
            geometric(r["median_latency_gain"] for r in rows if r["kind"] in {"short", "idle", "concurrent"}),
            geometric(r["before_p95_seconds"] / r["after_p95_seconds"] for r in rows if r["kind"] in {"short", "idle", "concurrent"}),
        ])
    elif mode in {"download", "concurrency"}:
        kind = "download" if mode == "download" else "concurrent"
        objective = geometric(r["median_goodput_gain"] for r in rows if r["kind"] == kind)
    elif mode == "stability":
        objective = tail_gain
    else:
        objective = geometric([latency_gain, tail_gain,
                               geometric(r["median_goodput_gain"] for r in rows if r["kind"] in {"download", "concurrent"})])
    # Sparse observations are diagnostic only, never sufficient to declare a win.
    loss_before = sum(r["before_retransmitted_bytes"] or 0 for r in rows if r["retransmission_pairs"] >= 3)
    loss_after = sum(r["after_retransmitted_bytes"] or 0 for r in rows if r["retransmission_pairs"] >= 3)
    retrans_improved = loss_before > 0 and loss_after <= loss_before * .75
    improved = completion_gain > 0 or objective >= 1.05 or mode == "stability" and retrans_improved
    eligible = all(r["eligible"] for r in rows) and improved
    return {"mode": mode, "eligible": eligible, "objective_gain": objective,
            "verdict": "improved" if eligible else "regression_or_insufficient_evidence" if not all(r["eligible"] for r in rows) else "no_material_gain",
            "completion_gain": completion_gain, "tail_gain": tail_gain,
            "reason": "完成率和保护指标通过，目标指标改善达标" if eligible else
            "保护指标未通过或目标改善不足 5%", "workloads": rows,
            "rank": [completion_gain, objective, tail_gain, latency_gain, loss_before-loss_after]}
