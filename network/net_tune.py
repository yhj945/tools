#!/usr/bin/env python3
"""Inspect, measure, and tune Linux VPS networking."""

from __future__ import annotations

import argparse
from difflib import unified_diff
import json
import math
import os
import platform
import signal
import sys

# A read-only invocation must not create bytecode beside this script.
sys.dont_write_bytecode = True

from net_tune_auto import auto_plan
from net_tune_modes import MODES
from net_tune_web import WEB_FORMAT, compare_web, web_bench
from net_tune_bench import MIB, bench, compare
from net_tune_changes import CONFIG, Transactions, build_plan, valid_cc
from net_tune_system import CC, DEFAULT_QDISC, PROBE_MSS_RANGE, ROUTE_MTU_RANGE, RCV, SND, LinuxHost, TuneError, inspect, load_object

VERSION = "1.0.0"


def between(low, high, convert=int):
    def parse(value):
        try:
            converted = convert(value)
            if math.isfinite(converted) and low <= converted <= high:
                return converted
        except (ValueError, OverflowError):
            pass
        raise argparse.ArgumentTypeError(f"需要 {low}–{high} 之间的数值")
    return parse


def series(parse):
    def parse_series(value):
        items = [parse(item) for item in value.split(",")]
        if len(items) != len(set(items)):
            raise argparse.ArgumentTypeError("列表中有重复项")
        return items
    return parse_series


def algorithm(value):
    if not valid_cc(value):
        raise argparse.ArgumentTypeError("无效的拥塞控制算法名")
    return value


def json_option(parser):
    parser.add_argument("--json", action="store_true", help="输出 JSON")


def write_options(parser):
    parser.add_argument("--dry-run", action="store_true", help="只预览并检查")
    parser.add_argument("--yes", action="store_true", help="显示预览后直接执行")


def parser():
    root = argparse.ArgumentParser(description="Linux VPS 网络诊断、测速和可回滚调优")
    root.add_argument("--version", action="version", version=VERSION)
    sub = root.add_subparsers(dest="operation", required=True)

    check = sub.add_parser("inspect", help="离线诊断，默认命令")
    check.add_argument("--peer", help="可选字面 IP，只查询本机路由")
    check.add_argument("--interface", help="只显示指定网卡")
    json_option(check)

    automatic = sub.add_parser("auto", help="自动识别配置，按实测选择并预览调优方案")
    evidence = automatic.add_mutually_exclusive_group()
    evidence.add_argument("--peer", help="自有或已获授权的 iperf3 测速机")
    evidence.add_argument("--from-bench", metavar="FILE", help="同一主机的完整 bench 报告")
    evidence.add_argument("--from-results", metavar="FILE", help="同一主机和基线的配对实测记录")
    evidence.add_argument("--web-url", action="append", help="业务 HTTP(S) 测试地址，可重复；仅采集基线")
    automatic.add_argument("--mode", choices=MODES, default="balanced", help="优化重点，默认 balanced（均衡）")
    automatic.add_argument("--proxy", help="业务测试的 HTTP/SOCKS5 代理")
    automatic.add_argument("--resolve", action="append", default=[], help="HOST:PORT:ADDRESS，可重复")
    automatic.add_argument("--port", type=between(1, 65535), default=5201)
    automatic.add_argument("--rate-mbps", type=between(1, 100_000), default=20, help="测速目标速率，默认 20 Mbps")
    automatic.add_argument("--budget-mib", type=between(1, 1_048_576), default=128, help="测速总预算，默认 128 MiB")
    mode = automatic.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="预览后确认应用")
    mode.add_argument("--dry-run", action="store_true", help="仅预览，省略主动测速")
    automatic.add_argument("--yes", action="store_true", help="搭配 --apply，用于已确认的批处理")
    automatic.add_argument("--persist", action="store_true", help="将优选的 TCP 和 GSO 参数加入开机加载计划")
    json_option(automatic)

    optimize = sub.add_parser("optimize", help="预览候选；确认后自动试验、采集重传、独立复核并保留或回滚")
    optimize.add_argument("--mode", choices=MODES, default="balanced")
    optimize.add_argument("--url", action="append", help="固定 HTTP(S) 测试对象，默认 Cloudflare 指定大小对象")
    optimize.add_argument("--proxy", help="客户端现有 SOCKS5/HTTP 代理端口")
    optimize.add_argument("--ssh", help="要调优的 VPS，使用现有 SSH 别名或 root@host")
    optimize.add_argument("--ssh-config", help="可选 SSH 配置文件")
    optimize.add_argument("--service-port", type=between(1,65535), help="VPS 代理监听端口，用于匹配发送端重传")
    optimize.add_argument("--interface", help="VPS 目标网卡，默认识别 IPv4 默认出口")
    optimize.add_argument("--client-interface", help="HTTP 客户端出口；代理外网出口由已有代理控制")
    optimize.add_argument("--resolve", action="append", default=[], help="固定对端 HOST:PORT:ADDRESS")
    optimize.add_argument("--compare-initial", action="store_true", help="仅对比工具首次记录的介入前参数与当前配置")
    optimize.add_argument("--rounds", type=between(3,10), default=3)
    optimize.add_argument("--idle-seconds", type=between(1,300), help="空闲恢复等待，默认 20 秒；稳定性为 60 秒")
    optimize.add_argument("--timeout", type=between(2,60), default=15)
    optimize.add_argument("--deadline", type=between(30,7200), default=1800, help="整个试验的时限，默认 1800 秒")
    optimize.add_argument("--budget-mib", type=between(1,1_048_576), default=512, help="所有候选和复核共享的总预算")
    optimize.add_argument("--output", help="完整报告目录；确认执行后才创建，必须尚不存在")
    optimize.add_argument("--persist", action="store_true", help="仅将通过独立复核的 TCP/GSO 方案持久化")
    optimize_mode = optimize.add_mutually_exclusive_group()
    optimize_mode.add_argument("--apply", action="store_true", help="预览后确认开始受控试验")
    optimize_mode.add_argument("--dry-run", action="store_true", help="只读预览，默认行为")
    optimize.add_argument("--yes", action="store_true", help="已确认的批处理，仍显示预览")
    json_option(optimize)

    measure = sub.add_parser("bench", help="使用显式对端和总流量预算测速")
    measure.add_argument("--peer", required=True, help="自有 iperf3 对端 IP 或域名")
    measure.add_argument("--port", type=between(1, 65535), default=5201)
    family = measure.add_mutually_exclusive_group()
    family.add_argument("-4", dest="family", action="store_const", const=4)
    family.add_argument("-6", dest="family", action="store_const", const=6)
    measure.add_argument("--source", help="绑定本机字面 IP")
    measure.add_argument("--protocol", choices=("tcp", "udp"), default="tcp")
    measure.add_argument("--direction", choices=("up", "down", "both"), default="both")
    measure.add_argument("--rates-mbps", type=series(between(1, 100_000)), required=True,
                         help="单个速率或逗号分隔的测速档位，各档位为并发流合计 Mbps")
    measure.add_argument("--streams", type=series(between(1, 16)), default=[1, 4],
                         help="并发流数列表，默认 1,4")
    measure.add_argument("--cc", type=series(algorithm), default=["default"],
                         help="可选 TCP 算法列表，例如 cubic,bbr")
    measure.add_argument("--seconds", type=between(1, 60), default=3, help="每轮目标持续秒数")
    measure.add_argument("--rounds", type=between(1, 10), default=1, help="测试矩阵重复次数")
    measure.add_argument("--retries", type=between(0, 2), default=0, help="每个失败样本的最大重试次数")
    measure.add_argument("--budget-mib", type=between(1, 1_048_576), default=256, help="总预算 MiB")
    measure.add_argument("--deadline", type=between(6, 3600), default=120, help="测速总时限秒数")
    measure.add_argument("--dry-run", action="store_true", help="离线估算流量并显示测速矩阵")

    comparison = sub.add_parser("compare", help="对比同路径、同测试矩阵的报告")
    comparison.add_argument("before")
    comparison.add_argument("after")
    comparison.add_argument("--mode", choices=MODES, default="balanced", help="HTTP 业务报告的比较重点")
    json_option(comparison)

    web = sub.add_parser("web", help="按预算测小请求、下载、并发和空闲后恢复；不修改配置")
    web.add_argument("--url", action="append", required=True, help="HTTP(S) 地址；可用 {bytes} 代入负载大小")
    web.add_argument("--mode", choices=MODES, default="balanced")
    web.add_argument("--proxy", help="HTTP/SOCKS5 代理，例如 socks5h://127.0.0.1:7890")
    web.add_argument("--resolve", action="append", default=[], help="HOST:PORT:ADDRESS，可重复")
    web.add_argument("--interface", help="HTTP 连接出口；回环代理应在代理程序中绑定出口")
    web.add_argument("--rounds", type=between(1,20), default=3)
    web.add_argument("--budget-mib", type=between(1,1_048_576), default=128)
    web.add_argument("--timeout", type=between(2,60), default=15)
    web.add_argument("--deadline", type=between(10,3600), default=600)
    web.add_argument("--idle-seconds", type=between(1,300), help="两次请求的启动间隔；默认 20 秒，稳定性模式 60 秒")
    web.add_argument("--dry-run", action="store_true", help="只展示矩阵和预算，不访问网络")

    design = sub.add_parser("plan", help="离线生成调优计划")
    design.add_argument("--profile", choices=("vless",), help="生成 VLESS 下载调优计划")
    design.add_argument("--from-bench", metavar="FILE", help="完整的 bench JSON 报告")
    design.add_argument("--cc", type=algorithm, help="显式算法，或 auto 根据 A/B 建议")
    design.add_argument("--bandwidth-mbps", type=between(0.01, 100_000, float), help="业务单流带宽估算")
    design.add_argument("--rtt-ms", type=between(0.001, 10_000, float), help="业务路径实测空载 RTT")
    design.add_argument("--mtu-probe-mss", type=between(*PROBE_MSS_RANGE), help="启用 TCP MTU 探测并设置起始 MSS（字节）")
    design.add_argument("--mtu-probing", type=between(0,2), help="MTU 探测：0 关闭、1 按需、2 始终；指定 MSS 时默认 2")
    design.add_argument("--initcwnd", type=between(1, 65535), help="IPv4 主表默认路由的初始拥塞窗口（报文段）")
    design.add_argument("--route-mtu", type=between(*ROUTE_MTU_RANGE), help="IPv4 主表默认路由的 MTU（字节）")
    design.add_argument("--persist", action="store_true", help="同时生成 TCP 参数和 GSO 的开机加载计划")
    design.add_argument("--interface", help="目标网卡，默认使用报告的出口")
    queue = design.add_mutually_exclusive_group()
    queue.add_argument("--shape-mbps", type=between(1, 100_000), help="显式出向整形速率")
    queue.add_argument("--enable-fq-pacing", action="store_true", help="原位启用现有 fq 的 pacing")
    design.add_argument("--gso-single-segment", action="store_true", help="将出向 GSO 上限设为每批一个分段")
    design.add_argument("--gso-max-segs", type=between(1,65535), help="显式 GSO 分段上限，用于受控对照和恢复")
    design.add_argument("--shaper", choices=("cake", "tbf"), default="cake")
    json_option(design)

    apply = sub.add_parser("apply", help="检查、预览并应用 JSON 计划")
    apply.add_argument("plan", metavar="FILE")
    write_options(apply)

    undo = sub.add_parser("rollback", help="撤销最近一笔有效事务或恢复中断事务")
    undo.add_argument("transaction", nargs="?", help="限定预期事务编号")
    write_options(undo)

    status = sub.add_parser("status", help="查看当前配置、持久化状态和事务历史")
    json_option(status)
    return root


def output_json(data):
    print(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False))


def show_auto(result):
    system = result["system"]
    memory = f"{system['memory_bytes'] / MIB:.0f} MiB" if system["memory_bytes"] else "未知内存"
    print(f"{system['os']} | Linux {system['kernel']} | {system['cpu_count']} CPU | {memory}")
    queues = "、".join(system["qdiscs"]) or "未知"
    print(f"出口 {system['interface'] or '待测速确认'} | 拥塞控制 {system['cc'] or '未知'} | 队列 {queues}")
    decision = result["selection"]
    print(f"优化重点 {MODES[result.get('mode','balanced')]}")
    print(decision["reason"])
    if decision["method"] in {"paired_results", "iperf3"}:
        print("当前为传输/下载证据，尚未验证日常访问和空闲后恢复。")
    if decision["method"] in {"paired_results", "paired_business"}:
        for row in decision["candidates"]:
            print(f"  {row['name']}  {'通过' if row['eligible'] else '未通过'}")
        if decision["selected"]:
            print(f"选中 {decision['selected']}")
    report = result["benchmark"]
    if report and report.get("format") == WEB_FORMAT:
        print(f"HTTP 业务请求预算 {report['budget_bytes']/MIB:.0f} MiB，"
              f"完整矩阵预留 {report['planned_reserved_bytes']/MIB:.2f} MiB，已计入 {report['charged_bytes']/MIB:.2f} MiB")
        for row in report.get("summary", []):
            latency = f"{row['p95_seconds']:.3f} 秒" if row['p95_seconds'] is not None else "无样本"
            print(f"  {row['kind']} 完成 {row['completed']}/{row['samples']}，p95 {latency}")
            if row["failed"]:
                print(f"    HTTP 拒绝 {row['http_response_failures']}，重定向 {row['http_redirects']}，"
                      f"体积上限 {row['size_limit_failures']}，连接/传输错误 {row['transport_failures']}")
    elif report and report.get("dry_run"):
        print(f"计划 {report['planned_samples']} 轮，预算 {report['budget_bytes'] / MIB:.0f} MiB，"
              f"失败上界 {report['worst_case_bytes'] / MIB:.1f} MiB")
    elif report and "charged_bytes" in report:
        print(f"已计入测速预算 {report['charged_bytes'] / MIB:.2f} MiB")
    if result["plan"] is None and report is None and decision["method"] == "local":
        if result.get("mode") in {"daily", "stability", "concurrency"}:
            print(f"业务基线：net_tune auto --mode {result['mode']} --web-url HTTP(S)地址；同路径配对后再优选。")
        else:
            print("有测速机时运行 net_tune auto --peer 测速机地址。确认方案后可加 --apply。")


def show_inspect(report):
    print(f"{report['os']} | Linux {report['kernel']} | {report['arch']} | "
          f"{report['cpu_count']} CPU | {report['page_size_bytes']} B 页")
    limit = report["memory"]["effective_limit_bytes"]
    if limit:
        print(f"可见内存上限 {limit / MIB:.0f} MiB")
    for key, value in report["sysctl"].items():
        if value is not None:
            print(f"{key} = {value}")
    for family, routes in report["routes"].items():
        if family == "peer":
            routes = [routes]
        for route in routes:
            print(f"路由 {family} {route.get('dst', 'default')} "
                  f"dev {route.get('dev', '?')} via {route.get('gateway', '直连')}")
    for link in report["links"]:
        name = link["ifname"]
        queues = report["qdiscs"].get(name, [])
        kinds = ", ".join(sorted({
            "fq (nopacing)" if queue["kind"] == "fq" and (queue.get("options") or {}).get("pacing") is False
            else queue["kind"] for queue in queues
        }))
        rate = f" | {link['speed_mbps']} Mbps" if link.get("speed_mbps") else ""
        print(f"网卡 {name} | MTU {link.get('mtu', '?')} | {link.get('operstate', '?')} | "
              f"{kinds or '未知队列'}{rate}")
    tools = ", ".join(name for name, available in report["tools"].items() if available)
    print(f"本机工具 {tools or '无'}")
    if "softnet" in report["counters"]:
        stats = report["counters"]["softnet"]
        print(f"softnet 累计丢包 {stats['dropped']}，预算耗尽 {stats['time_squeeze']}")
    for warning in report["warnings"]:
        print(f"提示 {warning}")


def show_route_change(before: dict, after: dict) -> None:
    for key, label in (("initcwnd", "initcwnd"), ("mtu", "MTU")):
        if before.get(key) == after.get(key):
            continue
        original = "默认" if before.get(key) is None else before[key]
        target = "默认" if after.get(key) is None else after[key]
        print(f"  {before['interface']}  IPv4 默认路由 {label} {original}  ->  {target}（运行时）")


def show_plan(plan, reasons=False):
    print("应用预览")
    changed = False
    for row in plan["sysctl"]:
        if row["before"] != row["after"]:
            print(f"  {row['key']}  {row['before']}  ->  {row['after']}")
            changed = True
            if reasons:
                print(f"    {row['reason']}")
    shape = plan["shape"]
    if shape:
        if shape["kind"] == "fq":
            print(f"  {shape['interface']}  fq nopacing  ->  fq pacing（运行时）")
        else:
            before = shape["before"]["queues"][0]["kind"]
            print(f"  {shape['interface']}  {before}  ->  {shape['kind']} {shape['rate_mbps']} Mbps（运行时）")
        changed = True
    gso = plan.get("gso")
    if gso:
        print(f"  {gso['interface']}  GSO 分段上限 {gso['before']['max_segs']}  ->  {gso['after']['max_segs']}（运行时）")
        changed = True
    persistence = plan.get("gso_persistence")
    if persistence:
        print(f"  {persistence['interface']}  GSO 分段上限 {persistence.get('target_max_segs', 1)}（{persistence['backend']} 开机加载，绑定 MAC {persistence['address']}）")
        for path in persistence["after"]["files"]:
            print(f"    {path}")
        changed = True
    default_route = plan.get("default_route")
    if default_route:
        show_route_change(default_route["before"], default_route["after"])
        changed = True
    config = plan["config"]
    if config:
        print(f"  /etc/sysctl.d/{CONFIG}（{config['backend']} 启动加载）")
        before = (config["before"] or "").splitlines()[1:]
        after = config["after"].splitlines()[1:]
        for line in list(unified_diff(before, after, lineterm=""))[2:]:
            print(f"    {line}")
        changed = True
    if not changed:
        print("  当前计划没有写入项")
    if reasons:
        for note in plan["notes"]:
            print(f"  {note}")
    return changed


def show_rollback(journal, scope):
    print(f"回滚预览 {journal['id']}")
    attempted = journal["steps"][:journal["attempted"]]
    for step in reversed(attempted):
        kind = step["type"]
        if kind == "sysctl":
            print(f"  {step['key']}  {step['after']}  ->  {step['before']}")
        elif kind == "qdisc":
            if step["kind"] == "fq":
                print(f"  {step['interface']}  fq pacing  ->  fq nopacing")
            else:
                print(f"  {step['interface']}  {step['kind']}  ->  {step['before']['queues'][0]['kind']}")
        elif kind == "gso":
            print(f"  {step['interface']}  GSO 分段上限 1  ->  {step['before']['max_segs']}")
        elif kind == "default_route":
            show_route_change(step["after"], step["before"])
        elif kind == "gso_persistence":
            print(f"  {step['interface']}  恢复 GSO 启动文件和服务状态；恢复本次启动记录的 GSO 上限")
        else:
            action = "恢复原文件内容" if step["before"] is not None else "移除脚本生成的文件"
            print(f"  /etc/sysctl.d/{CONFIG}  {action}")
    if scope["boot"] != journal["scope"]["boot"]:
        print("  当前已重启，先前启动周期的临时变更将跳过")


def confirm(args):
    sys.stdout.flush()
    if args.yes:
        return True
    if not sys.stdin.isatty():
        raise TuneError("批处理请先查看预览，再显式使用 --yes")
    return input("执行以上变更？[y/N] ").strip().lower() in {"y", "yes"}


def root_required():
    if os.geteuid() != 0:
        raise TuneError("应用和回滚需要 root 权限")


def show_compare(rows):
    labels = {"goodput_mbps": "接收吞吐 Mbps", "load_rtt_p95_ms": "负载 RTT p95 ms",
              "retransmits_per_mib": "重传 / MiB", "udp_loss_pct": "UDP 丢包 %",
              "retransmitted_bytes_per_mib": "重传字节 / 接收 MiB",
              "udp_jitter_ms": "UDP 抖动 ms", "local_cpu_pct": "本端 iperf CPU %",
              "remote_cpu_pct": "对端 iperf CPU %"}
    for row in rows:
        case = row["case"]
        print(f"{case['protocol']} {case['direction']} {case['streams']} 流 "
              f"{case['rate_mbps']} Mbps {case['cc']} | 样本 {case['samples']} / {row['after_samples']}")
        for metric, values in row["metrics"].items():
            if values["delta"] is not None:
                print(f"  {labels[metric]}  {values['before']:.3f}  ->  "
                      f"{values['after']:.3f}（{values['delta']:+.3f}）")
        if row["goodput_ranges_overlap"]:
            print("  两组吞吐波动范围重叠")


def status_data(host, transactions):
    unreadable = False
    try:
        records = transactions.records()
    except PermissionError:
        records, unreadable = [], True
    return {"sysctl": {key: host.sysctl(key) for key in (CC, RCV, SND, DEFAULT_QDISC)},
            "boot_backend": host.backend(), "managed_config": transactions.config_content(),
            "gso_startup": [{"interface": step["interface"], "backend": step["backend"],
                             **transactions.gso_persistence.state(step)}
                            for row in records if row["state"] == "applied" and transactions.same_scope(row)
                            for step in row["steps"] if step["type"] == "gso_persistence"],
            "history_needs_root": unreadable,
            "transactions": [{"id": row["id"], "created": row["created"], "state": row["state"],
                              "attempted": row["attempted"], "errors": row.get("recovery_errors", [])}
                             for row in records]}


def interrupted(signum, _frame):
    raise KeyboardInterrupt(signal.Signals(signum).name)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cli = parser()
    args = cli.parse_args(argv or ["inspect"])
    if platform.system() != "Linux":
        print("错误 此工具需要 Linux", file=sys.stderr)
        return 1
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    host = LinuxHost()
    transactions = Transactions(host)
    try:
        op = args.operation
        if op == "inspect":
            report = inspect(host, args.peer, args.interface)
            (output_json if args.json else show_inspect)(report)
        elif op == "optimize":
            from net_tune_optimize import DEFAULT_URL, optimize
            args.url = args.url or [DEFAULT_URL]
            report = optimize(args)
            if args.json:
                output_json(report)
            return 3 if report["state"] == "recovery_pending" else 2 if report["state"] in {"failed", "interrupted"} else 0
        elif op == "auto":
            if args.yes and not args.apply:
                raise TuneError("--yes 需搭配 --apply")
            if args.apply and args.json:
                raise TuneError("应用模式使用文字预览，JSON 模式只查看方案")
            if args.apply:
                root_required()
            result = auto_plan(host, transactions, args, cli.parse_args)
            if args.json:
                output_json(result)
            else:
                show_auto(result)
                plan = result["plan"]
                if plan and show_plan(plan, reasons=True) and args.apply and confirm(args):
                    identifier = transactions.apply(plan)
                    print(f"已应用 {identifier}")
            benchmark = result["benchmark"]
            if benchmark and benchmark.get("interrupted"):
                return 130
            if benchmark and not (benchmark.get("complete") or benchmark.get("dry_run")):
                return 2
        elif op == "bench":
            report = bench(host, args)
            output_json(report)
            if report.get("interrupted"):
                return 130
            return 0 if args.dry_run or report["complete"] else 2
        elif op == "compare":
            before, after = load_object(args.before), load_object(args.after)
            if before.get("format") == WEB_FORMAT:
                result = compare_web(before, after, args.mode)
                if args.json:
                    output_json(result)
                else:
                    print(f"优化重点 {MODES[args.mode]}：{result['reason']}")
                    for row in result["workloads"]:
                        print(f"  {row['kind']} p95 {row['before_p95_seconds']:.3f} → {row['after_p95_seconds']:.3f} 秒；"
                              f"完成 {row['before_completed']} → {row['after_completed']} / {row['rounds']}")
                        for reason in row["reasons"]:
                            print(f"    {reason}")
            else:
                rows = compare(before, after)
                (output_json if args.json else show_compare)(rows)
        elif op == "web":
            report = web_bench(host, args)
            output_json(report)
            if report.get("interrupted"):
                return 130
            return 0 if args.dry_run or report["complete"] else 2
        elif op == "plan":
            report = load_object(args.from_bench) if args.from_bench else None
            plan = build_plan(host, transactions, args, report)
            if args.json:
                output_json(plan)
            else:
                show_plan(plan, reasons=True)
        elif op == "apply":
            plan = load_object(args.plan)
            transactions.check_current(plan)
            changed = show_plan(plan)
            if changed and not args.dry_run:
                root_required()
                if confirm(args):
                    identifier = transactions.apply(plan)
                    print(f"已应用 {identifier}")
        elif op == "rollback":
            journal = transactions.latest()
            if not journal:
                raise TuneError("没有可回滚的事务")
            if args.transaction and args.transaction != journal["id"]:
                raise TuneError("指定编号与当前可回滚事务不同")
            show_rollback(journal, host.scope())
            if not args.dry_run:
                root_required()
                if confirm(args):
                    transactions.rollback(journal["id"])
                    print(f"已回滚 {journal['id']}")
        else:
            data = status_data(host, transactions)
            if args.json:
                output_json(data)
            else:
                for key, value in data["sysctl"].items():
                    print(f"{key} = {value or '不可用'}")
                if data["managed_config"]:
                    print(data["managed_config"], end="")
                for row in data["gso_startup"]:
                    print(f"GSO 开机加载 {row['interface']} ({row['backend']}): "
                          f"{'已启用' if row['enabled'] else '未启用'}，{'运行中' if row['active'] else '未运行'}")
                for row in data["transactions"]:
                    print(f"{row['id']}  {row['created']}  {row['state']}")
                    for error in row["errors"]:
                        print(f"  {error}")
                if data["history_needs_root"]:
                    print("读取事务历史需要 root 权限")
    except KeyboardInterrupt:
        print("操作已中断", file=sys.stderr)
        return 130
    except (TuneError, OSError, UnicodeError) as exc:
        print(f"错误 {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
