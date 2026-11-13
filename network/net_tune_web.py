"""Bounded HTTP workload measurements, including parallel and idle connections."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import selectors
import threading
import socket
import ssl
import struct
from statistics import median
import subprocess
import tempfile
import time
from urllib.parse import urlsplit, urlunsplit

from net_tune_bench import MIB, quantile, utc_now
from net_tune_modes import MATRICES, MODES, evaluate_cases
from net_tune_system import TuneError, command

WEB_FORMAT = "net-tune-web-v1"
MARGIN = 512 * 1024
FIELDS = ("http_code", "size_download", "time_namelookup", "time_connect", "time_appconnect",
          "time_starttransfer", "time_total", "num_connects", "remote_ip")
WRITE_OUT = "\n" + json.dumps({key: "%{" + key + "}" for key in FIELDS}, separators=(",", ":")) + "\n"


def error_kind(complete, status, reason=None, exitcode=None):
    if complete:
        return None
    if reason and "上限" in reason or exitcode == 63:
        return "size_limit"
    if 300 <= status < 400:
        return "http_redirect"
    if status >= 400:
        return "http_response"
    return "transport"


def safe_url(url):
    parts = urlsplit(url)
    if parts.scheme not in {"http", "https", "socks5", "socks5h"} or not parts.hostname:
        raise TuneError("需要有效的 HTTP(S) URL 或 SOCKS5 代理地址")
    host = parts.hostname
    if ":" in host:
        host = "[" + host + "]"
    return urlunsplit((parts.scheme, host + (":" + str(parts.port) if parts.port else ""), parts.path, "", ""))


def request_group(url, size, count, args, directory, token, deadline):
    if count == 2:
        return idle_requests(url, size, args, deadline)
    target = url.replace("{bytes}", str(size))
    header = directory / (token + ".headers")
    cmd = ["curl", "-sS", "--noproxy", "", "--connect-timeout", str(min(5,args.timeout)),
           "--max-time", str(args.timeout), "--max-filesize", str(size),
           "--range", f"0-{size-1}", "--dump-header", str(header), "--write-out", WRITE_OUT,
           "--proxy", args.proxy or ""]
    if args.interface:
        cmd += ["--interface",args.interface]
    for resolve in args.resolve:
        cmd += ["--resolve",resolve]
    cmd += ["--url",target]
    started=time.monotonic(); wall_start=time.time(); until=min(deadline,started+args.timeout+1)
    process=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    tail=b"";errors=b"";received_output=0;reason=None
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ,"body")
            selector.register(process.stderr,selectors.EVENT_READ,"error")
            while selector.get_map():
                if time.monotonic()>=until:
                    reason="请求超时或总时限";process.kill()
                for key,_ in selector.select(.05):
                    chunk=os.read(key.fileobj.fileno(),4096)
                    if not chunk:
                        selector.unregister(key.fileobj);continue
                    if key.data=="body":
                        received_output+=len(chunk);tail=(tail+chunk)[-4096:]
                        if received_output>size+4096:
                            reason="响应超过单请求上限";process.kill()
                    else:
                        errors=(errors+chunk)[-2048:]
            process.wait(timeout=3)
    except BaseException:
        process.kill();process.wait()
        raise
    finally:
        process.stdout.close();process.stderr.close()
    data={}
    for line in tail.decode(errors="replace").splitlines():
        try:
            value=json.loads(line)
            if isinstance(value,dict) and set(value)==set(FIELDS):data=value
        except ValueError:
            pass
    status=int(data.get("http_code") or 0)
    received=int(float(data.get("size_download") or 0))
    complete=bool(data and process.returncode==0 and 200<=status<300 and not reason and received<=size)
    headers=header.read_text(errors="replace") if header.exists() else ""
    rays=re.findall(r"(?im)^cf-ray:[^\r\n]*-([A-Z]+)\s*$",headers)
    return [{"complete":complete,"start":wall_start,"end":time.time(),
             "seconds":max(float(data.get("time_total") or time.monotonic()-started),.000001),
             "bytes":min(received,size),"ttfb_seconds":float(data.get("time_starttransfer") or 0) if status else None,
             "dns_seconds":None if args.proxy else float(data.get("time_namelookup") or 0),
             "connect_seconds":float(data.get("time_connect") or 0),
             "tls_seconds":float(data.get("time_appconnect") or 0),"connections_created":int(data.get("num_connects") or 0),
             "http_code":status,"curl_exit":process.returncode,"edge":rays[-1] if rays else data.get("remote_ip") or "unverified",
             "error_kind":error_kind(complete,status,reason,process.returncode),
             "error":reason or (f"HTTP {status}" if status>=300 else errors.decode(errors="replace")[-250:]) if not complete else ""}]


def receive_exact(sock, size):
    value = b""
    while len(value) < size:
        part = sock.recv(size-len(value))
        if not part:
            raise TuneError("代理握手提前关闭")
        value += part
    return value


def idle_requests(url, size, args, deadline):
    """Keep one HTTP/1.1 connection open during a real idle period; no new curl required."""
    target = urlsplit(url.replace("{bytes}", str(size)))
    proxy = urlsplit(args.proxy) if args.proxy else None
    port = target.port or (443 if target.scheme == "https" else 80)
    connect_host = target.hostname
    for resolve in args.resolve:
        fields = resolve.split(":", 2)
        if len(fields) != 3:
            raise TuneError("--resolve 需要 HOST:PORT:ADDRESS")
        if fields[:2] == [target.hostname, str(port)]:
            connect_host = fields[2].split(",")[0].strip("[]")
    connection = http.client.HTTPConnection(target.hostname, port, timeout=args.timeout)
    connects = 0
    timings = {}
    peer = "unverified"
    active_socket = None
    def connect():
        nonlocal connects, peer, active_socket
        started = time.monotonic()
        address = (proxy.hostname, proxy.port or (1080 if proxy.scheme.startswith("socks") else 80)) if proxy else (connect_host, port)
        sock = socket.socket(socket.AF_INET6 if ":" in address[0] else socket.AF_INET, socket.SOCK_STREAM)
        active_socket = sock
        try:
            sock.settimeout(max(.1, min(args.timeout, deadline-time.monotonic())))
            if args.interface:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, args.interface.encode()+b"\0")
            sock.connect(address)
            timings["connect_seconds"] = time.monotonic()-started
            peer = sock.getpeername()[0]
            if proxy and proxy.scheme.startswith("socks5"):
                if proxy.username or proxy.password:
                    raise TuneError("空闲连接测试使用无认证 SOCKS5 或 HTTP CONNECT 代理")
                sock.sendall(b"\x05\x01\x00")
                if receive_exact(sock,2) != b"\x05\x00":
                    raise TuneError("SOCKS5 握手未接受无认证方式")
                destination = connect_host
                if proxy.scheme == "socks5" and connect_host == target.hostname:
                    destination = socket.getaddrinfo(connect_host,port,type=socket.SOCK_STREAM)[0][4][0]
                try:
                    packed = socket.inet_pton(socket.AF_INET,destination); address_bytes=b"\x01"+packed
                except OSError:
                    try:
                        packed=socket.inet_pton(socket.AF_INET6,destination);address_bytes=b"\x04"+packed
                    except OSError:
                        packed=destination.encode("idna")
                        if len(packed)>255: raise TuneError("SOCKS5 目标名过长")
                        address_bytes=b"\x03"+bytes([len(packed)])+packed
                sock.sendall(b"\x05\x01\x00"+address_bytes+struct.pack("!H",port))
                reply=receive_exact(sock,4)
                if reply[:2] != b"\x05\x00":raise TuneError("SOCKS5 CONNECT 失败")
                length={1:4,4:16}.get(reply[3])
                if reply[3]==3:length=receive_exact(sock,1)[0]
                if length is None:raise TuneError("SOCKS5 地址类型无效")
                receive_exact(sock,length+2)
            elif proxy:
                if proxy.scheme != "http" or proxy.username or proxy.password:
                    raise TuneError("空闲测试支持无认证 HTTP CONNECT / SOCKS5 代理")
                if target.scheme == "https":
                    host=f"[{connect_host}]" if ":" in connect_host else connect_host
                    authority=f"{host}:{port}"
                    sock.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
                    header=b""
                    while not header.endswith(b"\r\n\r\n") and len(header)<65536:
                        header+=receive_exact(sock,1)
                    if header.split(b"\r\n",1)[0].split()[1:2] != [b"200"]:
                        raise TuneError("HTTP CONNECT 失败")
            if target.scheme == "https":
                sock=ssl.create_default_context().wrap_socket(sock,server_hostname=target.hostname)
                active_socket=sock
                timings["tls_seconds"]=time.monotonic()-started
            connection.sock=sock
            connects+=1
        except BaseException:
            sock.close()
            raise
    connection.connect=connect
    results=[]
    try:
        for index in range(2):
            if index:
                until=min(deadline,time.monotonic()+args.idle_seconds)
                while time.monotonic()<until:
                    time.sleep(min(.2,until-time.monotonic()))
            start=time.monotonic();wall_start=time.time();previous=connects;received=0;first=0.;status=0;edge=peer;error=""
            timings.clear()
            def expire():
                sock=connection.sock or active_socket
                if sock:
                    try:sock.shutdown(socket.SHUT_RDWR)
                    except OSError:pass
                    sock.close()
            watchdog=threading.Timer(max(.01,min(args.timeout,deadline-start)),expire)
            watchdog.daemon=True;watchdog.start()
            try:
                if start>=deadline:raise TuneError("总时限")
                connection.timeout=max(.1,min(args.timeout,deadline-start))
                if connection.sock:connection.sock.settimeout(connection.timeout)
                path=(target.path or "/")+("?"+target.query if target.query else "")
                if proxy and proxy.scheme=="http" and target.scheme=="http":
                    path=urlunsplit(target)
                connection.request("GET",path,headers={"Range":f"bytes=0-{size-1}","User-Agent":"net_tune/1.0.0"})
                response=connection.getresponse();status=response.status;first=time.monotonic()-start
                ray=response.getheader("CF-Ray","");edge=ray.rsplit("-",1)[-1] if ray else peer
                length=response.getheader("Content-Length")
                if length is not None and int(length)>size:raise TuneError("响应超过单请求上限")
                while True:
                    if time.monotonic()-start>=args.timeout or time.monotonic()>=deadline:
                        raise TuneError("请求超时")
                    chunk=response.read(min(65536,size-received+1))
                    if not chunk:break
                    received+=len(chunk)
                    if received>size:raise TuneError("响应超过单请求上限")
                if not 200<=status<300:raise TuneError(f"HTTP {status}")
                complete=True
            except (OSError,ValueError,http.client.HTTPException,TuneError) as exc:
                error=str(exc);complete=False;connection.close()
            finally:
                watchdog.cancel();watchdog.join()
            results.append({"complete":complete,"start":wall_start,"end":time.time(),
                            "seconds":max(time.monotonic()-start,.000001),
                            "bytes":min(received,size),"ttfb_seconds":first if status else None,"dns_seconds":None,
                            "connect_seconds":timings.get("connect_seconds",0.),"tls_seconds":timings.get("tls_seconds",0.),
                            "connections_created":connects-previous,"http_code":status,"curl_exit":None,
                            "edge":edge,"error":error,"error_kind":error_kind(complete,status,error),
                            "http_protocol":"HTTP/1.1"})
    finally:
        connection.close()
    return results


def web_bench(host, args):
    if len(args.url) > 8 or args.rounds > 20:
        raise TuneError("一次最多 8 个 URL、20 轮")
    urls = list(dict.fromkeys(args.url))
    for url in urls:
        if urlsplit(url).scheme not in {"http", "https"}:
            raise TuneError("业务 URL 仅支持 HTTP(S)")
        safe_url(url)
    if args.proxy:
        safe_url(args.proxy)
    interval = args.idle_seconds if args.idle_seconds is not None else (60 if args.mode == "stability" else 20)
    if interval < 1:
        raise TuneError("空闲测试间隔至少 1 秒")
    args.idle_seconds = interval
    matrix = [{"kind": kind, "max_bytes": size, "concurrency": streams,
               "idle_seconds": interval if kind == "idle" else 0,
               "target": hashlib.sha256(url.encode()).hexdigest()[:16], "url": safe_url(url), "raw_url": url}
              for url in urls for kind, size, streams in MATRICES[args.mode]]
    def reserve(case):
        count = 2 if case["kind"] == "idle" else case["concurrency"]
        return count * (2 * case["max_bytes"] + MARGIN)
    public_matrix = [{k:v for k,v in c.items() if k != "raw_url"} for c in matrix]
    budget = args.budget_mib * MIB
    # Even the first DNS/connection/failed request is reserved before invoking curl.
    if reserve(matrix[0]) > budget:
        raise TuneError("预算不足以预留首轮请求")
    planned = sum(reserve(c) for c in matrix) * args.rounds
    report = {"format": WEB_FORMAT, "created": utc_now(), "mode": args.mode,
              "observer_scope": host.scope(), "matrix": public_matrix, "budget_bytes": budget,
              "planned_reserved_bytes": planned, "charged_bytes": 0, "attempts": [],
              "complete": False, "stop_reason": None, "dry_run": args.dry_run,
              "path": {"proxy": safe_url(args.proxy) if args.proxy else None, "interface": args.interface,
                       "resolve": sorted(args.resolve), "targets": sorted(c["target"] for c in matrix)},
              "limitations": ["HTTP 请求测试不执行 JavaScript，不代表完整浏览器首屏", "不凭 SYN 探测推断业务重传",
                              "没有重传数据时保持 null，不将缺失值当作零", "预算为保守预留，不等于运营商账单"]}
    if args.dry_run:
        return report
    if not shutil.which("curl"):
        raise TuneError("缺少 curl，请通过 net_tune.sh --install-deps 补齐依赖")
    text = command(["curl", "--version"]).stdout
    version = re.search(r"curl (\d+)\.(\d+)\.(\d+)", text)
    if not version or tuple(map(int, version.groups())) < (7, 29, 0):
        raise TuneError("业务测试需要 curl 7.29+；请通过系统软件包管理器补齐")
    deadline = time.monotonic() + args.deadline
    try:
        with tempfile.TemporaryDirectory(prefix="net-tune-web-") as temporary:
            directory = Path(temporary)
            for round_no in range(1, args.rounds+1):
                for index, case in enumerate(matrix):
                    charge = reserve(case)
                    if report["charged_bytes"] + charge > budget or time.monotonic() >= deadline:
                        report["stop_reason"] = "流量预算不足" if report["charged_bytes"]+charge > budget else "总时限"
                        return report
                    report["charged_bytes"] += charge
                    attempt = {"round": round_no, "case": index, "reserved_bytes": charge,
                               "sample": None, "requests": []}
                    report["attempts"].append(attempt)
                    start = time.monotonic()
                    attempt["start"] = time.time()
                    if case["kind"] == "concurrent":
                        with ThreadPoolExecutor(max_workers=case["concurrency"]) as pool:
                            futures = [pool.submit(request_group, case["raw_url"], case["max_bytes"], 1, args,
                                                   directory, f"{round_no}-{index}-{j}", deadline)
                                       for j in range(case["concurrency"])]
                            requests = [f.result()[0] for f in futures]
                    else:
                        requests = request_group(case["raw_url"], case["max_bytes"],
                                                 2 if case["kind"] == "idle" else 1,
                                                 args, directory, f"{round_no}-{index}", deadline)
                    attempt["requests"] = requests
                    attempt["end"] = time.time()
                    if case["kind"] == "idle":
                        sample = dict(requests[-1])
                        sample["complete"] = all(r["complete"] for r in requests)
                        sample["idle_connection_reused"] = requests[-1]["connections_created"] == 0 and sample["complete"]
                        if not sample["complete"]:
                            sample["seconds"] = max(r["seconds"] for r in requests)
                    elif case["kind"] == "concurrent":
                        edges = {r["edge"] for r in requests}
                        sample = {"complete": all(r["complete"] for r in requests),
                                  "seconds": max(time.monotonic()-start, .000001),
                                  "bytes": sum(r["bytes"] for r in requests),
                                  "ttfb_seconds": max((r["ttfb_seconds"] for r in requests if r["ttfb_seconds"] is not None), default=None),
                                  "edge": next(iter(edges)) if len(edges)==1 else "mixed:"+",".join(sorted(edges))}
                    else:
                        sample = dict(requests[0])
                    sample["retransmitted_bytes"] = None
                    attempt["sample"] = sample
            report["complete"] = True
    except KeyboardInterrupt:
        report.update(interrupted=True, stop_reason="中断")
    except (OSError, TuneError, subprocess.SubprocessError) as exc:
        report["stop_reason"] = f"业务测试执行失败: {exc}"
    finally:
        report["summary"] = web_summary(report)
    return report


def web_summary(report):
    rows = []
    for index, case in enumerate(report["matrix"]):
        attempts = [a for a in report["attempts"] if a["case"] == index]
        samples = [a["sample"] for a in attempts if a["sample"]]
        completed = [s for s in samples if s["complete"]]
        requests = [r for a in attempts for r in a["requests"]]
        rows.append({"kind": case["kind"], "target": case["target"], "samples": len(attempts),
                     "completed": len(completed), "failed": len(attempts)-len(completed),
                     "requests": len(requests), "failed_requests": sum(not r["complete"] for r in requests),
                     "http_response_failures": sum(r.get("error_kind") == "http_response" for r in requests),
                     "http_redirects": sum(r.get("error_kind") == "http_redirect" for r in requests),
                     "size_limit_failures": sum(r.get("error_kind") == "size_limit" for r in requests),
                     "transport_failures": sum(r.get("error_kind") == "transport" for r in requests),
                     "median_seconds": median(s["seconds"] for s in completed) if completed else None,
                     "p95_seconds": quantile([s["seconds"] for s in samples], .95),
                     "median_ttfb_seconds": median(s["ttfb_seconds"] for s in completed) if completed else None,
                     "tail_sample_count": len(samples)})
    return rows


def paired_web(before, after):
    if before.get("format") != WEB_FORMAT or after.get("format") != WEB_FORMAT:
        raise TuneError("需要 web 生成的两份业务报告")
    if (not before.get("complete") or not after.get("complete") or before["observer_scope"] != after["observer_scope"]
            or before["path"] != after["path"] or before["matrix"] != after["matrix"]):
        raise TuneError("业务报告未完成，或观察机、路径、URL、负载矩阵不同")
    workloads = []
    for index, case in enumerate(before["matrix"]):
        before_rows = [r for r in before["attempts"] if r["case"]==index]
        after_rows = [r for r in after["attempts"] if r["case"]==index]
        a = {r["round"]:r["sample"] for r in before_rows}
        b = {r["round"]:r["sample"] for r in after_rows}
        if (len(a)!=len(before_rows) or len(b)!=len(after_rows) or a.keys()!=b.keys()
                or any(x is None for x in [*a.values(), *b.values()])):
            raise TuneError("业务报告轮数不同或样本不完整")
        workloads.append({"kind":case["kind"],"bytes":case["max_bytes"]*case["concurrency"],
                          "concurrency":case["concurrency"],"target":case["target"],
                          "pairs":[{"before":a[k],"after":b[k]} for k in sorted(a)]})
    return workloads


def compare_web(before, after, mode):
    try:
        return evaluate_cases(paired_web(before, after), mode)
    except (KeyError, TypeError, ValueError) as exc:
        raise TuneError("业务报告结构或样本无效") from exc
