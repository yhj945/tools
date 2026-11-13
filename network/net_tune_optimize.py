"""Previewed, budgeted candidate trials with independent validation and recovery."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import threading
import time
import uuid

from net_tune_bench import MIB
from net_tune_modes import evaluate_cases
from net_tune_observe import attach_downloads
from net_tune_system import LinuxHost, TuneError
from net_tune_trial import LEASE_SECONDS, rpc, save
from net_tune_web import paired_web, web_bench

DEFAULT_URL = "https://speed.cloudflare.com/__down?bytes={bytes}"
CONTROL_RESERVE = 32 * MIB

# Preview loads the same modules into memory on the SSH target. It creates no
# remote files and neither installs dependencies nor applies tuning settings.
MEMORY_BOOTSTRAP = '''import importlib.abc,importlib.util,json,sys
p=json.load(sys.stdin)
class Source(importlib.abc.MetaPathFinder,importlib.abc.Loader):
 def find_spec(self,name,path=None,target=None):
  return importlib.util.spec_from_loader(name,self) if name in p['sources'] else None
 def create_module(self,spec):return None
 def exec_module(self,module):
  module.__file__='/net-tune-preview/'+module.__name__+'.py'
  module.__net_tune_source__=p['sources'][module.__name__]
  exec(compile(p['sources'][module.__name__],module.__file__,'exec'),module.__dict__)
sys.dont_write_bytecode=True
sys.meta_path.insert(0,Source())
from net_tune_trial import rpc
try:print(json.dumps({'result':rpc(p['request'])},ensure_ascii=False))
except Exception as e:print(json.dumps({'error':str(e)},ensure_ascii=False));sys.exit(1)
'''


class Backend:
    def __init__(self, target=None, config=None):
        self.target, self.directory = target, None
        self.source = Path(__file__).resolve().parent
        self.sources = {p.stem:p.read_text() for p in self.source.glob("net_tune*.py")}
        self.ssh = ["ssh", "-oBatchMode=yes", "-oConnectTimeout=10", "-oServerAliveInterval=10", "-oServerAliveCountMax=2"]
        if config:
            self.ssh += ["-F", str(Path(config).expanduser())]
        if target:
            if target.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_.@:\[\]%-]+", target):
                raise TuneError("SSH 目标应为主机别名或 user@host")
            self.ssh += ["--", target]

    def execute(self, code, payload, timeout=35):
        try:
            result = subprocess.run(self.ssh + ["python3 -B -c " + shlex.quote(code)],
                                    input=json.dumps(payload), text=True, capture_output=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise TuneError("SSH 控制连接失败: " + str(exc)) from exc
        try:
            value = json.loads(result.stdout)
        except ValueError as exc:
            raise TuneError("SSH 未返回有效结果: " + result.stderr.strip()[-500:]) from exc
        if result.returncode or "error" in value:
            raise TuneError(value.get("error", "SSH 操作失败"))
        return value["result"]

    def prepare(self):
        if not self.target:
            return
        self.directory = self.execute('''import hashlib,json,os,pathlib,re,tempfile,sys
p=json.load(sys.stdin);d=pathlib.Path(tempfile.mkdtemp(prefix='net-tune-run-',dir='/var/tmp'))
for name,source in p.items():
 if not re.fullmatch(r'net_tune(?:_[a-z]+)?',name):raise ValueError('invalid module')
 f=d/(name+'.py');f.write_text(source);f.chmod(0o600)
print(json.dumps({'result':str(d)}))
''', self.sources)
        if not re.fullmatch(r"/var/tmp/net-tune-run-[A-Za-z0-9_]+", self.directory):
            raise TuneError("远程工具目录无效")

    def call(self, request):
        if not self.target:
            return rpc(request)
        if not self.directory:
            return self.execute(MEMORY_BOOTSTRAP, {"sources": self.sources, "request": request})
        code = ("import json,sys;sys.path.insert(0," + repr(self.directory) + ");"
                "from net_tune_trial import rpc\n"
                "try:print(json.dumps({'result':rpc(json.load(sys.stdin))},ensure_ascii=False))\n"
                "except Exception as e:print(json.dumps({'error':str(e)},ensure_ascii=False));sys.exit(1)")
        return self.execute(code, request, timeout=120 if request["op"] == "persist" else 35)

    def close(self):
        if self.directory:
            self.execute("import json,shutil,sys;shutil.rmtree(json.load(sys.stdin));print(json.dumps({'result':True}))", self.directory)
            self.directory = None


class Heartbeat:
    def __init__(self, backend, identifier):
        self.backend, self.identifier = backend, identifier
        self.stop = threading.Event()
        self.failed = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.wait(10):
            try:
                self.backend.call({"op": "touch", "id": self.identifier})
            except Exception as exc:
                self.error = str(exc); self.failed.set(); return

    def start(self):
        self.thread.start()

    def close(self):
        self.stop.set(); self.thread.join(timeout=40)


def web_args(args, *, dry_run=False, health=False):
    from net_tune import parser
    command = ["web", "--mode", args.mode, "--rounds", "1" if health else str(args.rounds),
               "--budget-mib", str(args.budget_mib), "--timeout", str(args.timeout),
               "--deadline", "600"]
    for url in args.url:
        command += ["--url", url]
    if args.proxy:
        command += ["--proxy", args.proxy]
    if args.client_interface:
        command += ["--interface", args.client_interface]
    for value in args.resolve:
        command += ["--resolve", value]
    if health or args.idle_seconds is not None:
        command += ["--idle-seconds", "1" if health else str(args.idle_seconds)]
    if dry_run:
        command += ["--dry-run"]
    return parser().parse_args(command)


def evaluate_pair(before, after, mode, require_sender=False, expected_cc=None):
    rows = paired_web(before, after)
    result = evaluate_cases(rows, mode)
    evidence = []
    if require_sender:
        for row in rows:
            if row["kind"] != "download":
                continue
            pairs = [p for p in row["pairs"] if all(p[k]["complete"] and p[k].get("retransmitted_bytes") is not None for k in ("before", "after"))]
            if len(pairs) < 3:
                evidence.append("下载发送端重传配对不足 3 对")
    if expected_cc:
        samples = [p["after"] for row in rows if row["kind"] == "download" for p in row["pairs"] if p["after"]["complete"]]
        if not samples or any(s.get("sender_cc") != expected_cc for s in samples):
            evidence.append("未确认业务发送连接实际使用候选拥塞控制算法")
    if evidence:
        result.update(eligible=False, verdict="insufficient_evidence", evidence_errors=evidence,
                      reason="；".join(evidence))
    return result


def markdown_report(result):
    states = {"verified_improvement_retained": "已保留通过两次对照的候选",
              "no_confirmed_improvement": "未确认稳定收益，已恢复试验前配置",
              "failed": "试验失败，恢复状态见下方", "interrupted": "试验中断，恢复状态见下方",
              "recovery_pending": "尚未确认恢复完成，需要检查目标主机"}
    kinds = {"short": "小请求", "download": "下载", "concurrent": "并发", "idle": "空闲后请求"}
    lines = ["# 网络调优对照报告", "", states.get(result["state"], result["state"]), "",
             f"版本：1.0.0；模式：{result['mode']}；RTO 下限保持不变。",
             f"共享预算：{result['budget_bytes']/MIB:.2f} MiB；累计预留：{result['charged_bytes']/MIB:.2f} MiB（含失败、中断及控制预留）。", "",
             "A 为试验前当前配置，B 为候选配置。先 A1/B1 初筛，再 B2/A2 独立复核；两个对照均通过才保留。",
             "`--compare-initial` 的 B 仅重建事务日志中有记录的介入前参数，不代表整机出厂状态。", ""]
    for entry in result["evaluations"]:
        lines += ["## " + entry["name"], ""]
        for key, title in (("screen", "初筛 A1/B1"), ("confirmation", "复核 A2/B2")):
            assessment = entry.get(key)
            if not assessment:
                continue
            lines += [f"### {title}", "", ("通过：" if assessment["eligible"] else "未通过：") + assessment["reason"], "",
                      "| 负载 | A/B 完成数 | A/B 中位秒 | A/B p95 秒 | A/B 重传字节（配对数） | 判断 |",
                      "| --- | --- | --- | --- | --- | --- |"]
            for row in assessment["workloads"]:
                loss = (f"{row['before_retransmitted_bytes']}/{row['after_retransmitted_bytes']}（{row['retransmission_pairs']}）"
                        if row["retransmission_pairs"] else "未知")
                lines.append(f"| {kinds[row['kind']]} | {row['before_completed']}/{row['after_completed']}（各 {row['rounds']}） | "
                             f"{row['before_median_seconds']:.3f}/{row['after_median_seconds']:.3f} | "
                             f"{row['before_p95_seconds']:.3f}/{row['after_p95_seconds']:.3f} | {loss} | "
                             + ("保护指标通过" if row["eligible"] else "；".join(row["reasons"])) + " |")
            lines += [""]
        if entry.get("current_against_initial"):
            conclusions = ["达到收益门槛" if item["eligible"] else "未达到收益门槛" for item in entry["current_against_initial"]]
            lines += ["反向评估当前配置相对介入前配置：" + "；".join(conclusions) + "。", ""]
    lines += ["## 恢复与原始记录", ""]
    for trial in result.get("trials", []):
        lines.append(f"- 试验 `{trial['id']}`：{trial.get('result', '状态待确认')}。")
    for error in result["errors"]:
        lines.append("- " + error)
    for reason in result.get("skipped", []):
        lines.append("- 未试验：" + reason)
    lines += ["", "完整配置、预算台账和判定依据见 [report.json](report.json)。每阶段的 JSON 保存请求结果及发送端连接匹配记录。", "",
              "缺失或有歧义的重传数据为未知，不按零重传处理。3 轮样本的 p95 是最慢样本；本报告只能说明本次路径和时段的表现，不能证明长期最优。",
              "测试包含小请求、下载、并发和空闲后请求，不执行网页 JavaScript，也不等于浏览器完整首屏。", ""]
    return "\n".join(lines)


def optimize(args, backend=None, measure=None, progress=print):
    """No mutation occurs before preview and confirmation, including SSH deployment."""
    backend = backend or Backend(args.ssh, args.ssh_config)
    measure = measure or web_bench
    if args.proxy and (not args.ssh or not args.service_port):
        raise TuneError("代理优选需指定 --ssh VPS 和 --service-port VPS代理监听端口，避免误调客户端")
    if args.ssh and not args.proxy:
        raise TuneError("SSH 优选需要客户端已有代理的 --proxy 地址")
    if args.proxy and args.proxy.startswith("socks5h:") and args.resolve:
        raise TuneError("固定对端请使用 socks5:// 代理，让 --resolve 的地址用于 SOCKS 连接")
    if args.yes and not args.apply:
        raise TuneError("--yes 需要 --apply")
    preview = backend.call({"op": "preview", "interface": args.interface, "compare_initial": args.compare_initial, "persist": args.persist})
    host = LinuxHost()
    matrix = measure(host, web_args(args, dry_run=True))
    phase_bytes = matrix["planned_reserved_bytes"]
    candidates = preview["candidates"]
    minimum = CONTROL_RESERVE + 4*phase_bytes + measure(host, web_args(args, dry_run=True, health=True))["planned_reserved_bytes"]
    interval = args.idle_seconds if args.idle_seconds is not None else (60 if args.mode == "stability" else 20)
    minimum_idle = (4*args.rounds*interval + 1)*len(args.url)
    result = {"format": "net-tune-optimize-v1", "version": "1.0.0", "mode": args.mode,
              "preview": preview, "matrix": matrix["matrix"], "budget_bytes": args.budget_mib*MIB,
              "charged_bytes": 0, "ledger": [], "phases": [], "evaluations": [], "selected": None,
              "state": "preview", "rto_policy": "preserve_200ms", "errors": []}
    result.update(minimum_full_trial_bytes=minimum, minimum_idle_seconds=minimum_idle)
    if args.json:
        if args.apply:
            raise TuneError("--json 仅用于只读预览；实测报告由 --output 保存")
        return result
    progress(f"目标：{args.ssh or '本机'}；模式：{args.mode}；候选 {len(candidates)} 个；RTO 不变")
    progress(f"每阶段 {args.rounds} 轮，预留 {phase_bytes/MIB:.2f} MiB；总预算 {args.budget_mib} MiB，含控制预留 32 MiB")
    progress(f"每阶段计划空闲等待 {args.rounds*interval} 秒；通过初筛的候选还需独立反向顺序复测；总时限 {args.deadline} 秒")
    progress(f"一个候选完成两次对照及健康检查，至少需预留 {math.ceil(minimum/MIB)} MiB，空闲等待共 {minimum_idle} 秒（另加请求耗时）")
    from net_tune import show_plan
    for candidate in candidates:
        progress("候选：" + candidate["name"])
        show_plan(candidate["plan"], reasons=True)
        if candidate.get("persist_preview"):
            progress("通过独立复核后才写入以下持久化计划：")
            show_plan(candidate["persist_preview"], reasons=True)
    for reason in preview["skipped"]:
        progress("跳过：" + reason)
    if not args.apply or args.dry_run or not candidates:
        progress("仅预览；加 --apply 后确认才会临时修改配置。")
        return result
    if not args.ssh and os.geteuid():
        raise TuneError("在 VPS 本机应用需要 sudo/root")
    if minimum > result["budget_bytes"]:
        raise TuneError(f"预算至少需要 {math.ceil(minimum/MIB)} MiB 才能完成一个候选的初筛、复核及最终健康检查")
    if args.deadline <= minimum_idle:
        raise TuneError(f"总时限不足以覆盖至少 {minimum_idle} 秒的空闲等待，请增加 --deadline 并留出请求时间")
    if not args.yes:
        try:
            answer = input("将临时试用上述候选，通过独立复测才保留，否则恢复。输入 y 开始：")
        except EOFError:
            answer = ""
        if answer.strip().lower() != "y":
            result["state"] = "cancelled"; return result
    directory = Path(args.output or ("net-tune-results-" + time.strftime("%Y%m%dT%H%M%S"))).resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    result["report_directory"] = str(directory)
    deadline = time.monotonic() + args.deadline
    active = heartbeat = None
    def checkpoint():
        save(directory / "report.json", result)
    def charge(label, amount):
        if result["charged_bytes"] + amount > result["budget_bytes"]:
            raise TuneError("总流量预算不足，保留当前配置；失败和中止预留不退款")
        if time.monotonic() >= deadline:
            raise TuneError("已到总时限，恢复试验前配置")
        result["charged_bytes"] += amount
        result["ledger"].append({"label": label, "reserved_bytes": amount, "epoch": time.time()})
        checkpoint()
    def begin(candidate):
        nonlocal active, heartbeat
        active = uuid.uuid4().hex
        result.setdefault("trials", []).append({"id": active, "name": candidate["name"]})
        checkpoint()
        trial = backend.call({"op": "begin", "id": active, "baseline": preview["baseline"], "settings": candidate["settings"]})
        if trial["id"] != active:
            raise TuneError("目标主机返回了不同的试验编号")
        heartbeat = Heartbeat(backend, active); heartbeat.start()
    def end(keep=False):
        nonlocal active, heartbeat
        if heartbeat:
            heartbeat.close(); heartbeat = None
        if active:
            state = backend.call({"op": "finish", "id": active, "keep": keep})
            result["trials"][-1]["result"] = state["state"]
            if state["state"] == "recovery_required":
                raise TuneError("回滚存在冲突: " + "; ".join(state["errors"]))
            active = None
            checkpoint()
    def phase(label, health=False):
        parameters = web_args(args, health=health)
        amount = measure(host, web_args(args, dry_run=True, health=health))["planned_reserved_bytes"]
        charge(label, amount)
        remaining = deadline - time.monotonic()
        if remaining < 10:
            raise TuneError("剩余时限不足，停止试验")
        parameters.deadline = min(3590, int(remaining))
        parameters.cancel_event = heartbeat.failed if heartbeat else None
        if active:
            backend.call({"op": "touch", "id": active})
        elif backend.call({"op": "snapshot", "interface": preview["baseline"]["interface"]}) != preview["baseline"]:
            raise TuneError("对照阶段配置已变化，停止比较")
        progress(f"开始 {label}；累计预留 {result['charged_bytes']/MIB:.2f}/{args.budget_mib} MiB")
        observation = None
        start = time.time()
        observer = backend.call({"op": "observe_start", "port": args.service_port or 0, "seconds": parameters.deadline + 10})
        offset = observer["epoch"] - (start + time.time())/2
        try:
            if args.proxy and not observer.get("ready"):
                raise TuneError("发送端连接观察不可用，停止代理优选: " + observer.get("error", "观察进程未就绪"))
            report = measure(host, parameters)
        finally:
            time.sleep(.5)
            observation = backend.call({"op": "observe_stop", "id": observer["id"]})
        attach_downloads(report, observation, offset)
        save(directory / (label + ".json"), report)
        result["phases"].append({"label": label, "file": label + ".json", "complete": report["complete"], "summary": report["summary"]})
        checkpoint()
        if heartbeat and heartbeat.failed.is_set():
            raise TuneError("回滚租约续期失败: " + str(heartbeat.error))
        if not report["complete"]:
            raise TuneError("业务矩阵未完成: " + str(report["stop_reason"]))
        if not active and backend.call({"op": "snapshot", "interface": preview["baseline"]["interface"]}) != preview["baseline"]:
            raise TuneError("对照阶段出现配置漂移，停止比较")
        return report
    try:
        charge("控制、源码部署、观察记录回传预留（含预览）", CONTROL_RESERVE)
        backend.prepare()
        result["state"] = "running"; checkpoint()
        ranked = []
        for index, candidate in enumerate(candidates):
            # Reserve room for a full independent confirmation, not just screening.
            if result["charged_bytes"] + 4*phase_bytes + (minimum-CONTROL_RESERVE-4*phase_bytes) > result["budget_bytes"]:
                result.setdefault("skipped", []).extend(c["name"] + ": 剩余预算不足以完成复核" for c in candidates[index:])
                break
            before = phase(f"candidate{index}-A1")
            begin(candidate)
            try:
                after = phase(f"candidate{index}-B1")
            finally:
                end()
            expected_cc = candidate["settings"].get("cc") or ("bbr" if candidate["settings"].get("profile") else None)
            assessment = evaluate_pair(before, after, args.mode, bool(args.proxy), expected_cc)
            entry = {"name": candidate["name"], "screen": assessment}
            result["evaluations"].append(entry); checkpoint()
            progress(candidate["name"] + "：" + assessment["reason"])
            if assessment["eligible"] or args.compare_initial:
                ranked.append((assessment["rank"], index, candidate, entry, before, after))
        if ranked:
            _, index, winner, entry, a1, b1 = max(ranked, key=lambda x:x[0])
            # Independent B-A order checks whether the initial A-B result survives time drift.
            begin(winner)
            try:
                b2 = phase(f"candidate{index}-B2")
            finally:
                end()
            a2 = phase(f"candidate{index}-A2")
            expected_cc = winner["settings"].get("cc") or ("bbr" if winner["settings"].get("profile") else None)
            entry["confirmation"] = evaluate_pair(a2, b2, args.mode, bool(args.proxy), expected_cc)
            if args.compare_initial:
                entry["current_against_initial"] = [evaluate_pair(b1, a1, args.mode, bool(args.proxy)), evaluate_pair(b2, a2, args.mode, bool(args.proxy))]
            if entry["screen"]["eligible"] and entry["confirmation"]["eligible"]:
                begin(winner)
                health = phase("final-health", health=True)
                if not all(a.get("sample", {}).get("complete") for a in health["attempts"]):
                    raise TuneError("候选最终健康检查失败")
                if args.persist:
                    backend.call({"op": "persist", "id": active})
                end(keep=True)
                result["selected"] = winner["name"]
                result["state"] = "verified_improvement_retained"
            else:
                result["state"] = "no_confirmed_improvement"
        else:
            result["state"] = "no_confirmed_improvement"
    except (Exception, KeyboardInterrupt) as exc:
        result["state"] = "interrupted" if isinstance(exc, KeyboardInterrupt) else "failed"
        result["errors"].append(str(exc) or "操作中断")
    finally:
        try:
            end()
            result["final_snapshot"] = backend.call({"op": "snapshot", "interface": preview["baseline"]["interface"]})
            if not result["selected"] and result["final_snapshot"] != preview["baseline"]:
                raise TuneError("最终配置未恢复为试验前快照")
        except Exception as exc:
            result["state"] = "recovery_pending"
            result["errors"].append(str(exc))
            progress(f"恢复未确认；未提交保留的试验由目标主机在最后续期 {LEASE_SECONDS} 秒后尝试回滚，请检查报告中的试验编号。")
        try:
            backend.close()
        except Exception as exc:
            result["errors"].append("临时源码清理失败: " + str(exc))
        checkpoint()
        (directory / "REPORT.md").write_text(markdown_report(result), encoding="utf-8")
    progress("结果：" + ("已保留通过独立复测的候选 " + result["selected"] if result["selected"] else result["state"]))
    progress("报告：" + str(directory / "REPORT.md"))
    return result
