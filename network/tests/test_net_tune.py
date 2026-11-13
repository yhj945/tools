import copy
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

NETWORK = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(NETWORK))

from net_tune import parser
from net_tune_auto import BASELINE_KEYS, RESULTS_FORMAT, choose_results
from net_tune_bench import (MIB, PROBE_BYTES, RETRANS_BYTES_PER_MIB, Trial, bench,
                            closed_socket_retransmitted_bytes, compare, validated_report)
from net_tune_changes import CONFIG, Transactions, build_plan
from net_tune_system import AUTOTUNE, BASE_MSS, CC, DEFAULT_QDISC, MTU_PROBING, RCV, SND, TuneError


class FakeHost:
    def __init__(self, root):
        self.etc = root / "etc"
        self.scope_data = {"machine": "host", "boot": "first", "netns": 7}
        self.values = {CC: "cubic", RCV: "4096 131072 4194304", SND: "4096 16384 4194304",
                       AUTOTUNE: "1", DEFAULT_QDISC: "fq_codel"}
        self.queue = {"device": {"ifindex": 7, "address": "02:00:00:00:00:01"},
                      "queues": [{"root": True, "kind": "noqueue", "handle": "0:", "options": {}}],
                      "root_filters": []}
        self.baseline = copy.deepcopy(self.queue)
        self.writes = []
        self.boot_loader = "systemd"
        self.memory_limit = 1024 * MIB

    def scope(self):
        return self.scope_data.copy()

    def in_init_netns(self):
        return True

    def sysctl(self, key):
        return self.values.get(key)

    def write_sysctl(self, key, value):
        self.writes.append((key, value))
        self.values[key] = value

    def can_write(self, _key):
        return True

    def supports_cc(self, value):
        return value in {"cubic", "reno", "bbr"}

    def memory(self):
        return {"effective_limit_bytes": self.memory_limit}

    def route(self, peer, source=None, port=None, protocol="tcp"):
        return {"dst": peer, "dev": "eth0", "gateway": "192.0.2.254", "prefsrc": "192.0.2.2"}

    def backend(self):
        return self.boot_loader

    def queue_state(self, _interface):
        return copy.deepcopy(self.queue)

    def can_attach(self, _interface, state):
        if state != self.baseline:
            raise TuneError("third-party queue")

    def set_fq_pacing(self, _interface, handle, enabled):
        root = self.queue["queues"][0]
        assert root["handle"] == handle
        if enabled:
            root["options"].pop("pacing")
        else:
            root["options"]["pacing"] = False

    def add_shaper(self, _interface, kind, rate):
        option = "bandwidth" if kind == "cake" else "rate"
        self.queue["queues"] = [{"root": True, "kind": kind, "handle": "75a1:",
                                 "options": {option: rate * 125000}}]

    def remove_shaper(self, _interface):
        self.queue = copy.deepcopy(self.baseline)


class LocalFixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.host = FakeHost(self.root)
        self.system_config = self.host.etc / "sysctl.d"
        self.system_config.mkdir(parents=True)
        self.vendor = self.root / "vendor"
        self.vendor.mkdir()
        self.store = Transactions(self.host, self.root / "state", (self.system_config, self.vendor))

    def plan(self, *args):
        return build_plan(self.host, self.store, parser().parse_args(["plan", *args]))


class AutoTests(LocalFixture):
    def results(self, *candidates):
        self.host.gso_state = lambda interface: {**self.host.queue["device"], "max_segs": 65535}
        return {"format": RESULTS_FORMAT, "scope": self.host.scope(),
                "peer": "192.0.2.20", "interface": "eth0",
                "baseline": {"sysctl": {k: self.host.sysctl(k) for k in BASELINE_KEYS},
                             "queue": self.host.queue_state("eth0"),
                             "gso": self.host.gso_state("eth0")},
                "candidates": list(candidates)}

    def candidate(self, name, algorithm, seconds, edge="SJC"):
        def sample(duration, where, loss):
            return {"complete": True, "seconds": duration, "bytes": MIB,
                    "edge": where, "retransmitted_bytes": loss}

        pair = {"before": sample(4, "SJC", 2000), "after": sample(seconds, edge, 1000)}
        return {"name": name, "settings": {"cc": algorithm, "initcwnd": 32},
                "workloads": [{"bytes": MIB, "pairs": [pair, copy.deepcopy(pair)]}]}

    def test_auto_compares_paired_evidence_and_rejects_drift_before_apply(self):
        good = self.candidate("faster", "bbr", 2)
        slow = self.candidate("slower", "reno", 6)
        changed_edge = self.candidate("other edge", "reno", 1, "LAX")
        route = {"tokens": ["default", "dev", "eth0"], "interface": "eth0", "initcwnd": 32}
        self.host.default_ipv4_route = lambda **kwargs: copy.deepcopy(route)
        data = self.results(slow, changed_edge, good)
        data["baseline"]["route"] = route
        _, _, plan, choice = choose_results(self.host, self.store, data, parser().parse_args)
        self.assertEqual(choice["selected"], "faster")
        self.assertEqual(plan["sysctl"][0]["after"], "bbr")
        self.assertEqual(self.host.writes, [])
        self.host.values[CC] = "reno"
        with self.assertRaisesRegex(TuneError, "当前配置与实测基线不同"):
            choose_results(self.host, self.store, data, parser().parse_args)
        self.assertEqual(self.host.writes, [])


class CliTests(unittest.TestCase):
    def test_default_and_bench_preview_do_not_create_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for source in NETWORK.glob("net_tune*.py"):
                shutil.copy2(source, root)
            before = {path.name: path.read_bytes() for path in root.iterdir()}
            for args in ([], ["auto"], ["auto", "--persist", "--dry-run"], ["auto", "--peer", "unused.invalid", "--dry-run"],
                         ["bench", "--peer", "unused.invalid", "--rates-mbps", "5", "--dry-run"]):
                result = subprocess.run([sys.executable, str(root / "net_tune.py"), *args],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({path.name: path.read_bytes() for path in root.iterdir()}, before)


class BenchTests(LocalFixture):
    def args(self, *extra):
        return parser().parse_args(["bench", "--peer", "192.0.2.3", "--direction", "up",
                                    "--rates-mbps", "5", "--seconds", "1", "--streams", "1", *extra])

    def measure(self, args, results):
        with patch("net_tune_bench.shutil.which", return_value="/usr/bin/iperf3"), \
             patch("net_tune_bench.idle_rtt", return_value=[20, 21, 22]), \
             patch("net_tune_bench.run_trial", side_effect=results) as probe, \
             patch("net_tune_bench.print"):
            report = bench(self.host, args)
        return report, probe.call_count

    @staticmethod
    def metrics(rate=4.8, *, cc="cubic", rtt=30, retrans=0):
        return {"sent_bytes": 640000, "received_bytes": 625000, "goodput_mbps": rate,
                "load_rtt_ms": [rtt, rtt], "load_rtt_p95_ms": rtt,
                "sender_cc": cc, "retransmits_per_mib": retrans}

    def test_parallel_target_is_divided_and_reverse_is_reserved(self):
        up = Trial(1, "up", 4, 50, "default", "tcp", 3)
        down = Trial(1, "down", 4, 50, "default", "tcp", 3)
        argv = up.args("192.0.2.3", 5201, "192.0.2.2")
        self.assertEqual(int(argv[argv.index("-b") + 1]) * up.streams, 50_000_000)
        self.assertGreater(down.reserve, up.reserve * 5)

    def test_insufficient_budget_fails_before_first_peer_lookup(self):
        with patch("net_tune_bench.resolve_peer") as resolve:
            with self.assertRaisesRegex(TuneError, "首轮前"):
                bench(self.host, self.args("--budget-mib", "1"))
        resolve.assert_not_called()

    def test_failed_attempt_uses_full_reservation_and_blocks_retry(self):
        report, count = self.measure(self.args("--budget-mib", "6", "--retries", "1"),
                                     [TuneError("timeout")])
        self.assertEqual(count, 1)
        self.assertFalse(report["complete"])
        self.assertIn("预算", report["stop_reason"])
        self.assertEqual(report["charged_bytes"], report["attempts"][0]["reserved_bytes"] + PROBE_BYTES)

    def test_success_refunds_unused_reservation_after_charged_failure(self):
        args = self.args("--budget-mib", "10", "--retries", "1")
        report, count = self.measure(args, [TuneError("busy"), self.metrics()])
        self.assertTrue(report["complete"])
        self.assertEqual(count, 2)
        failed, success = report["attempts"]
        self.assertEqual(failed["charged_bytes"], failed["reserved_bytes"])
        self.assertLess(success["charged_bytes"], success["reserved_bytes"])
        self.assertEqual(report["charged_bytes"], PROBE_BYTES + failed["charged_bytes"] + success["charged_bytes"])
        validated_report(report)

    def test_interrupt_preserves_budget_report(self):
        report, count = self.measure(self.args("--retries", "1"), [KeyboardInterrupt()])
        self.assertEqual(count, 1)
        self.assertTrue(report["interrupted"])
        self.assertFalse(report["complete"])
        self.assertEqual(report["attempts"][0]["reserved_bytes"], report["attempts"][0]["charged_bytes"])

    def test_transfer_above_reservation_stops_following_trials(self):
        metrics = {**self.metrics(), "sent_bytes": 5_000_000}
        report, count = self.measure(self.args("--rounds", "2"), [metrics])
        self.assertEqual(count, 1)
        self.assertFalse(report["complete"])
        self.assertIn("超过本轮预留", report["stop_reason"])

    def test_retransmitted_bytes_include_only_matched_streams(self):
        events = (
            b"UNCONN 0 0 [::1]:49999 [::1]:5201 bytes_sent:1000 bytes_retrans:999 retrans:0/4\n"
            b"UNCONN 0 0 [::1]:50000 [::1]:5201 bytes_sent:2000 bytes_retrans:125 retrans:0/1\n"
            b"UNCONN 0 0 [::1]:50001 [::1]:5201 bytes_sent:1000\n"
            b"UNCONN 0 0 [::1]:50002 [::1]:5201 bytes_sent:1000 retrans:0/1\n"
        )
        with tempfile.TemporaryFile() as trace:
            trace.write(events)
            trace.seek(0)
            connected = [{"local_port": 50000}, {"local_port": 50001}]
            self.assertEqual(closed_socket_retransmitted_bytes(trace, connected, 2, time.monotonic() + 1), 125)
            trace.seek(0)
            connected[1]["local_port"] = 50002
            self.assertIsNone(closed_socket_retransmitted_bytes(trace, connected, 2, time.monotonic() + 1))

    def test_compare_accepts_reports_without_retransmitted_bytes(self):
        args = self.args()
        old, _ = self.measure(args, [self.metrics()])
        new, _ = self.measure(args, [{**self.metrics(), RETRANS_BYTES_PER_MIB: 1024}])
        metric = compare(old, new)[0]["metrics"][RETRANS_BYTES_PER_MIB]
        self.assertEqual(metric, {"before": None, "after": 1024, "delta": None})

    def test_auto_cc_requires_repeated_comparable_improvement(self):
        args = self.args("--cc", "cubic,reno", "--rounds", "3")
        base, candidate = self.metrics(4.0), self.metrics(4.8, cc="reno")
        report, _ = self.measure(args, [base, candidate, candidate, base, base, candidate])
        plan_args = parser().parse_args(["plan", "--cc", "auto"])
        plan = build_plan(self.host, self.store, plan_args, report)
        self.assertEqual([(row["key"], row["after"]) for row in plan["sysctl"]], [(CC, "reno")])
        report, _ = self.measure(self.args("--cc", "cubic,reno"), [base, candidate])
        plan = build_plan(self.host, self.store, plan_args, report)
        self.assertEqual(plan["sysctl"], [])

    def auto_choice(self, pairs):
        args = self.args("--cc", "cubic,reno", "--rounds", str(len(pairs)))
        results = [sample for index, pair in enumerate(pairs)
                   for sample in (pair[::-1] if index % 2 else pair)]
        report, _ = self.measure(args, results)
        plan = build_plan(self.host, self.store, parser().parse_args(["plan", "--cc", "auto"]), report)
        return [row["after"] for row in plan["sysctl"] if row["key"] == CC]

    def test_auto_cc_rejects_faster_but_more_lossy_candidate(self):
        base = self.metrics(4.0)
        candidate = self.metrics(4.8, cc="reno", retrans=6)
        self.assertEqual(self.auto_choice([(base, candidate)] * 3), [])

    def test_auto_cc_distinguishes_rate_cap_and_real_retransmission_improvement(self):
        base = self.metrics(4.6, retrans=8)
        capped = self.metrics(4.9, cc="reno", retrans=8)
        cleaner = self.metrics(4.6, cc="reno", retrans=2)
        self.assertEqual(self.auto_choice([(base, capped)] * 3), [])
        self.assertEqual(self.auto_choice([(base, cleaner)] * 3), ["reno"])

    def test_auto_cc_uses_paired_retransmitted_bytes_when_available(self):
        base = {**self.metrics(4.6, retrans=8), RETRANS_BYTES_PER_MIB: 12000}
        cleaner = {**self.metrics(4.6, cc="reno", retrans=10), RETRANS_BYTES_PER_MIB: 8000}
        worse = {**self.metrics(4.6, cc="reno", retrans=4), RETRANS_BYTES_PER_MIB: 15000}
        self.assertEqual(self.auto_choice([(base, cleaner)] * 3), ["reno"])
        self.assertEqual(self.auto_choice([(base, worse)] * 3), [])
        missing = self.metrics(4.6, cc="reno", retrans=3)
        self.assertEqual(self.auto_choice([(base, missing)] * 3), ["reno"])

    def test_auto_cc_rejects_pairwise_throughput_regression(self):
        base = self.metrics(4.7)
        quicker = self.metrics(4.8, cc="reno", rtt=20)
        slower = self.metrics(3.9, cc="reno", rtt=20)
        self.assertEqual(self.auto_choice([(base, quicker)] * 5 + [(base, slower)]), [])

    def test_auto_cc_ranks_rate_limited_candidates_by_delay(self):
        args = self.args("--cc", "cubic,reno,bbr", "--rounds", "3")
        samples = [self.metrics(4.6), self.metrics(4.9, cc="reno", rtt=24),
                   self.metrics(4.7, cc="bbr", rtt=18)]
        report, _ = self.measure(args, samples + samples[::-1] + samples)
        plan = build_plan(self.host, self.store, parser().parse_args(["plan", "--cc", "auto"]), report)
        self.assertEqual([row["after"] for row in plan["sysctl"]], ["bbr"])

    def test_report_based_shape_is_bound_to_current_route(self):
        report, _ = self.measure(self.args(), [self.metrics()])
        args = parser().parse_args(["plan", "--shape-mbps", "10"])
        plan = build_plan(self.host, self.store, args, report)
        self.assertEqual(plan["shape"]["interface"], "eth0")
        with patch.object(self.host, "route", return_value={"dev": "eth1"}):
            with self.assertRaisesRegex(TuneError, "出口路由已变化"):
                self.store.check_current(plan)

    def test_comparison_requires_same_route_and_planned_samples(self):
        before, _ = self.measure(self.args(), [self.metrics(4)])
        after, _ = self.measure(self.args(), [self.metrics(5)])
        self.assertEqual(compare(before, after)[0]["metrics"]["goodput_mbps"]["delta"], 1)
        after["route"]["dev"] = "eth1"
        with self.assertRaisesRegex(TuneError, "出口"):
            compare(before, after)
        before["trial_plan"].append(before["trial_plan"][0].copy())
        with self.assertRaises(TuneError):
            validated_report(before)


class TransactionTests(LocalFixture):
    def test_buffer_plan_uses_memory_cap_and_preserves_other_fields(self):
        plan = self.plan("--bandwidth-mbps", "1000", "--rtt-ms", "150")
        self.assertEqual({change["key"] for change in plan["sysctl"]}, {RCV, SND})
        for change in plan["sysctl"]:
            self.assertEqual(change["before"].split()[:2], change["after"].split()[:2])
            self.assertEqual(int(change["after"].split()[2]), 16 * MIB)
        self.assertFalse(self.store.state_dir.exists())
        self.host.memory_limit //= 2
        with self.assertRaisesRegex(TuneError, "内存预算"):
            self.store.apply(plan)

    def test_noop_plan_needs_no_state(self):
        self.assertIsNone(self.store.apply(self.plan()))
        self.assertFalse(self.store.state_dir.exists())

    def test_failed_second_write_restores_first_and_written_second(self):
        original = self.host.values.copy()
        write = self.host.write_sysctl

        def fail_second(key, value):
            write(key, value)
            if key == SND and value != original[SND]:
                raise TuneError("injected readback failure")

        plan = self.plan("--bandwidth-mbps", "1000", "--rtt-ms", "150")
        with patch.object(self.host, "write_sysctl", side_effect=fail_second):
            with self.assertRaisesRegex(TuneError, "已恢复"):
                self.store.apply(plan)
        self.assertEqual(self.host.values, original)
        self.assertEqual(self.store.records()[0]["state"], "rolled_back")

    def test_interrupt_after_shaper_is_added_restores_both(self):
        original = self.host.values.copy()
        add = self.host.add_shaper

        def interrupt(*args):
            add(*args)
            raise KeyboardInterrupt

        plan = self.plan("--cc", "reno", "--shape-mbps", "20", "--interface", "eth0")
        with patch.object(self.host, "add_shaper", side_effect=interrupt):
            with self.assertRaisesRegex(TuneError, "已恢复"):
                self.store.apply(plan)
        self.assertEqual(self.host.values, original)
        self.assertEqual(self.host.queue, self.host.baseline)

    def test_preflight_rejects_stale_plan_and_active_lock(self):
        plan = self.plan("--cc", "reno")
        self.host.values[CC] = "bbr"
        with self.assertRaisesRegex(TuneError, "已变化"):
            self.store.apply(plan)
        self.assertFalse(self.store.state_dir.exists())
        self.host.values[CC] = "cubic"
        with self.store.lock():
            with self.assertRaisesRegex(TuneError, "正在执行"):
                self.store.apply(plan)
        self.assertEqual(self.host.writes, [])

    def test_rollback_reports_drift_without_overwriting_it(self):
        txn = self.store.apply(self.plan("--cc", "reno"))
        self.host.values[CC] = "bbr"
        with self.assertRaisesRegex(TuneError, "第三方变更"):
            self.store.rollback(txn)
        self.assertEqual(self.host.values[CC], "bbr")
        self.assertEqual(self.store.latest()["state"], "reverting")
        self.host.values[CC] = "reno"
        self.store.rollback(txn)
        self.assertEqual(self.host.values[CC], "cubic")

    def test_rollback_checks_queue_ownership_and_filters(self):
        txn = self.store.apply(self.plan("--shape-mbps", "20", "--interface", "eth0"))
        self.host.queue["root_filters"] = [{"kind": "bpf"}]
        with self.assertRaisesRegex(TuneError, "队列已变化"):
            self.store.rollback(txn)
        self.assertEqual(self.host.queue["queues"][0]["kind"], "cake")
        self.host.queue["root_filters"] = []
        self.store.rollback(txn)
        self.assertEqual(self.host.queue, self.host.baseline)

    def fq(self):
        self.host.queue["queues"] = [{"root": True, "kind": "fq", "handle": "1:",
                                      "options": {"pacing": False, "quantum": 3010}}]
        return copy.deepcopy(self.host.queue)

    def test_fq_pacing_changes_only_pacing_and_restores_it(self):
        baseline = self.fq()
        plan = self.plan("--enable-fq-pacing", "--interface", "eth0", "--cc", "bbr")
        self.assertEqual(self.host.queue, baseline)
        transaction = self.store.apply(plan)
        self.assertEqual(self.host.queue["queues"][0]["options"], {"quantum": 3010})
        self.assertEqual(self.host.values[CC], "bbr")
        self.store.rollback(transaction)
        self.assertEqual(self.host.queue, baseline)
        self.assertEqual(self.host.values[CC], "cubic")

    def test_vless_profile_uses_the_same_settings_as_explicit_flags(self):
        baseline = self.fq()
        self.host.values.update({"net.ipv4.tcp_base_mss": "1024", "net.ipv4.tcp_mtu_probing": "1"})
        device = {"ifindex": 7, "address": "02:00:00:00:00:01", "max_segs": 65535}
        with patch.object(self.host, "gso_state", return_value=device, create=True):
            profile = self.plan("--profile", "vless", "--interface", "eth0")
            explicit = self.plan("--interface", "eth0", "--cc", "bbr", "--enable-fq-pacing",
                                 "--gso-single-segment", "--mtu-probe-mss", "1290")
        for key in ("format", "sysctl", "shape", "gso", "config"):
            self.assertEqual(profile[key], explicit[key])
        self.assertEqual(self.host.queue, baseline)
        self.assertEqual(self.host.writes, [])
        for args in (("--cc", "cubic"), ("--mtu-probe-mss", "1300"), ("--shape-mbps", "10")):
            with self.subTest(args=args), self.assertRaisesRegex(TuneError, "冲突参数"):
                self.plan("--profile", "vless", "--interface", "eth0", *args)

    def test_vless_profile_accepts_already_paced_default_fq(self):
        self.fq()
        queue = self.host.queue["queues"][0]
        queue["handle"] = "0:"
        queue["options"].pop("pacing")
        self.host.values.update({"net.ipv4.tcp_base_mss": "1024", "net.ipv4.tcp_mtu_probing": "0"})
        device = {"ifindex": 7, "address": "02:00:00:00:00:01", "max_segs": 65535}
        with patch.object(self.host, "gso_state", return_value=device, create=True):
            plan = self.plan("--profile", "vless", "--interface", "eth0")
        self.assertIsNone(plan["shape"])
        self.assertEqual(plan["gso"]["after"]["max_segs"], 1)
        self.assertEqual(self.host.writes, [])
        self.assertIn("eth0 的 fq pacing 已启用", plan["notes"])
        queue["options"]["pacing"] = False
        with self.assertRaisesRegex(TuneError, "显式非零句柄"):
            self.plan("--enable-fq-pacing", "--interface", "eth0")

    def test_vless_profile_uses_default_fq_codel_with_mss_and_single_gso(self):
        queue = self.host.queue["queues"][0]
        queue["kind"] = "fq_codel"
        self.host.values.update({DEFAULT_QDISC: "fq", BASE_MSS: "1024", MTU_PROBING: "1"})
        device = {**self.host.queue["device"], "max_segs": 65535}
        baseline = copy.deepcopy(self.host.queue)
        with patch.object(self.host, "gso_state", return_value=device, create=True):
            profile = self.plan("--profile", "vless", "--interface", "eth0")
            explicit = self.plan("--cc", "bbr", "--interface", "eth0",
                                 "--gso-single-segment", "--mtu-probe-mss", "1290")
            for key in ("format", "sysctl", "shape", "gso", "config"):
                self.assertEqual(profile[key], explicit[key])
            self.assertEqual(self.host.queue, baseline)
            self.assertEqual(self.host.writes, [])
            with self.assertRaisesRegex(TuneError, "当前根队列为 fq_codel"):
                self.plan("--profile", "vless", "--enable-fq-pacing", "--interface", "eth0")
            queue["handle"] = "1:"
            with self.assertRaisesRegex(TuneError, "当前根队列为 fq_codel"):
                self.plan("--profile", "vless", "--interface", "eth0")

    def test_fq_pacing_refuses_existing_maxrate(self):
        self.fq()
        self.host.queue["queues"][0]["options"]["maxrate"] = 1_000_000
        with self.assertRaisesRegex(TuneError, "maxrate"):
            self.plan("--enable-fq-pacing", "--interface", "eth0")
        self.assertFalse(self.store.state_dir.exists())

    def test_fq_pacing_rolls_back_after_command_applied_then_failed(self):
        baseline = self.fq()
        set_pacing = self.host.set_fq_pacing

        def fail_after(*args):
            set_pacing(*args)
            if args[-1]:
                raise TuneError("injected failure")

        plan = self.plan("--enable-fq-pacing", "--interface", "eth0", "--cc", "bbr")
        with patch.object(self.host, "set_fq_pacing", side_effect=fail_after):
            with self.assertRaisesRegex(TuneError, "已恢复"):
                self.store.apply(plan)
        self.assertEqual(self.host.queue, baseline)
        self.assertEqual(self.host.values[CC], "cubic")

    def test_persistent_transaction_stack_survives_a_reboot(self):
        original = self.host.values.copy()
        first = self.store.apply(self.plan("--cc", "reno", "--persist"))
        config = (self.system_config / CONFIG).read_bytes()
        second = self.store.apply(self.plan("--cc", "bbr", "--persist"))
        self.host.scope_data.update({"boot": "second", "netns": 100})
        self.assertEqual(self.store.latest()["id"], second)
        self.store.rollback(second)
        self.assertEqual((self.system_config / CONFIG).read_bytes(), config)
        self.assertEqual(self.host.values[CC], "reno")
        self.store.rollback(first)
        self.assertFalse((self.system_config / CONFIG).exists())
        self.assertEqual(self.host.values, original)

    def test_foreign_persistent_file_is_not_taken_over(self):
        (self.system_config / CONFIG).write_text("# Managed by net_tune. Edit with a new plan.\n"
                                                f"{CC} = cubic\n")
        plan = self.plan("--cc", "reno", "--persist")
        with self.assertRaisesRegex(TuneError, "管理记录"):
            self.store.apply(plan)
        self.assertEqual(self.host.writes, [])

    def test_boot_override_and_openrc_legacy_override_are_detected(self):
        (self.vendor / "99-vendor.conf").write_text(f"{CC} = cubic\n")
        with self.assertRaisesRegex(TuneError, "99-vendor"):
            self.plan("--cc", "reno", "--persist")
        (self.system_config / "99-vendor.conf").write_text(f"{CC} = reno\n")
        self.assertIsNotNone(self.plan("--cc", "reno", "--persist")["config"])
        self.host.boot_loader = "openrc"
        (self.host.etc / "sysctl.conf").write_text(f"{CC} = cubic\n")
        with self.assertRaisesRegex(TuneError, "sysctl.conf"):
            self.plan("--cc", "reno", "--persist")

    def test_config_write_failure_restores_runtime_value(self):
        from net_tune_changes import replace_file

        def fail_after_file(path, content, mode):
            replace_file(path, content, mode)
            if path == self.store.config_path and content is not None:
                raise OSError("injected persistence error")

        plan = self.plan("--cc", "reno", "--persist")
        with patch("net_tune_changes.replace_file", side_effect=fail_after_file):
            with self.assertRaisesRegex(TuneError, "已恢复"):
                self.store.apply(plan)
        self.assertEqual(self.host.values[CC], "cubic")
        self.assertFalse((self.system_config / CONFIG).exists())

    def test_pending_transaction_is_resumable_and_blocks_new_writes(self):
        identifier = self.store.apply(self.plan("--cc", "reno"))
        journal = self.store.latest()
        journal["state"] = "applying"
        self.store.save(journal)
        with self.assertRaisesRegex(TuneError, "待恢复"):
            self.store.apply(self.plan("--cc", "bbr"))
        self.store.rollback(identifier)
        self.assertEqual(self.host.values[CC], "cubic")

    def test_runtime_transaction_expires_after_reboot(self):
        self.store.apply(self.plan("--cc", "reno"))
        self.host.scope_data.update({"boot": "second", "netns": 100})
        self.assertIsNone(self.store.latest())


@unittest.skipUnless(os.environ.get("NET_TUNE_NETNS_TEST") == "1", "set NET_TUNE_NETNS_TEST=1")
class LinuxNamespaceTests(unittest.TestCase):
    def isolated(self, script, timeout=45):
        result = subprocess.run(
            ["unshare", "-Urnmpf", "--mount-proc", "sh", "-ec", script, "test", str(NETWORK)],
            text=True, capture_output=True, timeout=timeout,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_real_default_route_initial_window_and_failure_rollback(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
ip -4 route add default dev test0 proto static metric 47 initrwnd 32
old=$(ip -4 -o route show default)
rto=$(cat /proc/sys/net/ipv4/tcp_rto_min_us 2>/dev/null || true)
./net_tune.py plan --initcwnd 48 --interface test0 --json > /var/lib/route.json
./net_tune.py apply /var/lib/route.json --dry-run
test "$(ip -4 -o route show default)" = "$old"
test ! -e /var/lib/net-tune
./net_tune.py apply /var/lib/route.json --yes
ip -4 -o route show default | rg -q 'metric 47.*initcwnd 48 initrwnd 32'
./net_tune.py rollback --yes
test "$(ip -4 -o route show default)" = "$old"
mkdir /var/lib/test-bin
real_ip=$(command -v ip)
cat > /var/lib/test-bin/ip <<'WRAP'
#!/bin/sh
if test "$1 $2 $3" = '-4 route replace'; then
    case " $* " in
        *" initcwnd 48 "*)
            "$NET_TUNE_TEST_IP" "$@" || exit "$?"
            exit 43
            ;;
    esac
fi
exec "$NET_TUNE_TEST_IP" "$@"
WRAP
chmod 755 /var/lib/test-bin/ip
if NET_TUNE_TEST_IP="$real_ip" PATH="/var/lib/test-bin:$PATH" ./net_tune.py apply /var/lib/route.json --yes; then exit 2; fi
test "$(ip -4 -o route show default)" = "$old"
test "$(cat /proc/sys/net/ipv4/tcp_rto_min_us 2>/dev/null || true)" = "$rto"
./net_tune.py status --json | rg -q '"state": "rolled_back"'
''')

    def test_real_default_route_mtu_restores_existing_metric_and_recovers_from_failure(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
ip -4 route add default dev test0 proto static metric 47 mtu 1400 initcwnd 32 initrwnd 32
before=$(ip -4 -o route show default)
rto=$(cat /proc/sys/net/ipv4/tcp_rto_min_us 2>/dev/null || true)
gso() {
    ip -d -j link show dev test0 | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["gso_max_segs"])'
}
old_gso=$(gso)
./net_tune.py plan --interface test0 --route-mtu 1342 --initcwnd 48 --gso-single-segment --json > /var/lib/mtu.json
./net_tune.py apply /var/lib/mtu.json --dry-run
test "$(ip -4 -o route show default)" = "$before"
test "$(gso)" = "$old_gso"
test ! -e /var/lib/net-tune
if ./net_tune.py plan --interface test0 --route-mtu 1501; then exit 2; fi
./net_tune.py apply /var/lib/mtu.json --yes
ip -4 -o route show default | rg -q 'metric 47.*mtu 1342 initcwnd 48 initrwnd 32'
ip -o link show dev test0 | rg -q 'mtu 1500'
test "$(gso)" = 1
./net_tune.py rollback --yes
test "$(ip -4 -o route show default)" = "$before"
test "$(gso)" = "$old_gso"
ip -4 route replace default dev test0 proto static metric 47 initcwnd 32 initrwnd 32
before=$(ip -4 -o route show default)
./net_tune.py plan --interface test0 --route-mtu 1342 --initcwnd 48 --gso-single-segment --json > /var/lib/mtu.json
mkdir /var/lib/test-bin
real_ip=$(command -v ip)
cat > /var/lib/test-bin/ip <<'WRAP'
#!/bin/sh
if test "$1 $2 $3" = '-4 route replace'; then
    case " $* " in
        *" mtu 1342 "*)
            "$NET_TUNE_TEST_IP" "$@" || exit "$?"
            exit 43
            ;;
    esac
fi
exec "$NET_TUNE_TEST_IP" "$@"
WRAP
chmod 755 /var/lib/test-bin/ip
if NET_TUNE_TEST_IP="$real_ip" PATH="/var/lib/test-bin:$PATH" ./net_tune.py apply /var/lib/mtu.json --yes; then exit 2; fi
test "$(ip -4 -o route show default)" = "$before"
test "$(gso)" = "$old_gso"
test "$(cat /proc/sys/net/ipv4/tcp_rto_min_us 2>/dev/null || true)" = "$rto"
./net_tune.py status --json | rg -q '"state": "rolled_back"'
''')

    def test_real_tbf_and_tcp_sysctl_apply_and_restore(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
old=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
case "$old" in reno) new=cubic ;; *) new=reno ;; esac
./net_tune.py plan --cc "$new" --shape-mbps 20 --shaper tbf --interface test0 --json > /var/lib/plan.json
./net_tune.py apply /var/lib/plan.json --dry-run
test ! -e /var/lib/net-tune
./net_tune.py apply /var/lib/plan.json --yes
test "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = "$new"
tc qdisc show dev test0 | rg -q 'tbf 75a1: root'
./net_tune.py rollback --yes
test "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = "$old"
tc qdisc show dev test0 | rg -q 'noqueue 0: root'
tc qdisc add dev test0 root handle 2: fq
if ./net_tune.py plan --shape-mbps 10 --interface test0; then exit 2; fi
tc qdisc show dev test0 | rg -q 'fq 2: root'
''')

    def test_real_fq_pacing_keeps_handle_and_options(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
tc qdisc add dev test0 root handle 1: fq nopacing quantum 3010
./net_tune.py plan --interface test0 --enable-fq-pacing --json > /var/lib/plan.json
./net_tune.py apply /var/lib/plan.json --dry-run
test ! -e /var/lib/net-tune
./net_tune.py apply /var/lib/plan.json --yes
tc -d qdisc show dev test0 | rg 'fq 1: root' | rg -q 'quantum 3010b'
if tc -d qdisc show dev test0 | rg -q nopacing; then exit 2; fi
./net_tune.py rollback --yes
tc -d qdisc show dev test0 | rg 'fq 1: root' | rg nopacing | rg -q 'quantum 3010b'
''')

    def test_real_gso_plan_applies_and_restores_after_partial_failure(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
tc qdisc add dev test0 root handle 1: fq nopacing
segments() {
    ip -j -d link show dev test0 | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["gso_max_segs"])'
}
old=$(segments)
mss_before=$(sysctl -n net.ipv4.tcp_base_mss net.ipv4.tcp_mtu_probing)
rto_before=$(cat /proc/sys/net/ipv4/tcp_rto_min_us 2>/dev/null || true)
./net_tune.py plan --interface test0 --enable-fq-pacing --gso-single-segment --mtu-probe-mss 1290 --json > /var/lib/plan.json
./net_tune.py apply /var/lib/plan.json --dry-run
test ! -e /var/lib/net-tune
test "$(segments)" = "$old"
test "$(sysctl -n net.ipv4.tcp_base_mss net.ipv4.tcp_mtu_probing)" = "$mss_before"
./net_tune.py apply /var/lib/plan.json --yes
test "$(segments)" = 1
test "$(sysctl -n net.ipv4.tcp_base_mss)" = 1290
test "$(sysctl -n net.ipv4.tcp_mtu_probing)" = 2
./net_tune.py rollback --yes
test "$(segments)" = "$old"
test "$(sysctl -n net.ipv4.tcp_base_mss net.ipv4.tcp_mtu_probing)" = "$mss_before"
mkdir /var/lib/test-bin
real_ip=$(command -v ip)
cat > /var/lib/test-bin/ip <<'WRAP'
#!/bin/sh
if test "$1 $2 $5 $6" = 'link set gso_max_segs 1'; then
    "$NET_TUNE_TEST_IP" "$@" || exit "$?"
    exit 43
fi
exec "$NET_TUNE_TEST_IP" "$@"
WRAP
chmod 755 /var/lib/test-bin/ip
if NET_TUNE_TEST_IP="$real_ip" PATH="/var/lib/test-bin:$PATH" ./net_tune.py apply /var/lib/plan.json --yes; then exit 2; fi
test "$(segments)" = "$old"
test "$(sysctl -n net.ipv4.tcp_base_mss net.ipv4.tcp_mtu_probing)" = "$mss_before"
test "$(cat /proc/sys/net/ipv4/tcp_rto_min_us 2>/dev/null || true)" = "$rto_before"
tc -d qdisc show dev test0 | rg -q 'fq 1: root.*nopacing'
./net_tune.py status --json | rg -q '"state": "rolled_back"'
''')

    def test_real_failure_after_qdisc_mutation_rolls_back(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
old=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
case "$old" in reno) new=cubic ;; *) new=reno ;; esac
./net_tune.py plan --cc "$new" --shape-mbps 20 --shaper tbf --interface test0 --json > /var/lib/plan.json
mkdir /var/lib/test-bin
real_tc=$(command -v tc)
cat > /var/lib/test-bin/tc <<'WRAP'
#!/bin/sh
if test "$1" = qdisc && test "$2" = add; then
    "$NET_TUNE_TEST_TC" "$@" || exit "$?"
    exit 42
fi
exec "$NET_TUNE_TEST_TC" "$@"
WRAP
chmod 755 /var/lib/test-bin/tc
if NET_TUNE_TEST_TC="$real_tc" PATH="/var/lib/test-bin:$PATH" ./net_tune.py apply /var/lib/plan.json --yes; then
    exit 2
fi
test "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = "$old"
tc qdisc show dev test0 | rg -q 'noqueue 0: root'
./net_tune.py status --json | rg -q '"state": "rolled_back"'
''')

    @unittest.skipUnless(shutil.which("iperf3"), "iperf3 is needed for a real loopback test")
    def test_real_tcp_and_udp_both_directions(self):
        self.isolated(r'''
cd "$1"
mount -t tmpfs none /var/lib
ip link set lo up
iperf3 -s -J -B ::1 > /var/lib/server.log 2>&1 &
peer_pid=$!
trap 'kill "$peer_pid" 2>/dev/null || true' EXIT
for attempt in 1 2 3 4 5; do
    if ss -ltn 'sport = :5201' | rg -q LISTEN; then break; fi
    sleep .2
done
./net_tune.py bench --peer ::1 -6 --rates-mbps 4 --seconds 1 --streams 1,2 > /var/lib/tcp.json
./net_tune.py bench --peer ::1 -6 --rates-mbps 4 --seconds 1 --streams 1 --protocol udp > /var/lib/udp.json
./net_tune.py compare /var/lib/tcp.json /var/lib/tcp.json --json > /var/lib/compare.json
./net_tune.py plan --from-bench /var/lib/tcp.json
python3 - /var/lib/tcp.json /var/lib/udp.json <<'CHECK'
import json
import sys

for name, expected in zip(sys.argv[1:], (4, 2)):
    with open(name) as handle:
        report = json.load(handle)
    assert report["complete"]
    assert len(report["summary"]) == expected
    assert {row["direction"] for row in report["summary"]} == {"up", "down"}
    assert report["charged_bytes"] <= report["budget_bytes"]
    assert all(row["goodput_mbps"] > 0 for row in report["summary"])
    if "udp" in name:
        assert all(row["udp_loss_pct"] is not None for row in report["summary"])
CHECK
''')


if __name__ == "__main__":
    unittest.main()
