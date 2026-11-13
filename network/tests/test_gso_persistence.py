import copy
import json
from pathlib import Path
import os
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_net_tune import LocalFixture
from net_tune import parser
from net_tune_auto import BASELINE_KEYS, RESULTS_FORMAT, choose_results
from net_tune_changes import replace_file, validate_plan
from net_tune_gso import boot_adjust
from net_tune_system import TuneError


class GSOPersistenceTests(LocalFixture):
    def setUp(self):
        super().setUp()
        self.link = {"ifindex": 7, "address": "02:00:00:00:00:01", "max_segs": 65535}
        self.host.gso_state = lambda interface: copy.deepcopy(self.link)
        self.host.set_gso_max_segs = lambda interface, value: self.link.update(max_segs=value)
        self.service = {"enabled": False, "active": False}
        self.manager = self.store.gso_persistence
        self.manager.backend = lambda: self.host.boot_loader
        self.manager.state = lambda step: self.service.copy()
        self.manager.reload = lambda step: None
        self.run = self.root / "run"
        self.manager.control = self.control

    def control(self, step, action):
        if action in {"enable", "disable"}:
            self.service["enabled"] = action == "enable"
        else:
            files = self.manager.snapshot(step)["files"]
            target = self.manager.service_target(step, files)
            boot_adjust(self.host, action, step["interface"], step["address"], self.run, wait=0,
                        target=target)
            self.service["active"] = action == "start"

    def persistent_plan(self):
        return self.plan("--interface", "eth0", "--gso-single-segment", "--persist")

    def test_preview_is_readonly_and_apply_rollback_restore_bundle(self):
        before = set(self.root.rglob("*"))
        plan = self.persistent_plan()
        validate_plan(plan)
        self.assertEqual(before, set(self.root.rglob("*")))
        self.assertEqual(plan["format"], "net-tune-plan-v5")
        identifier = self.store.apply(plan)
        self.assertEqual(self.link["max_segs"], 1)
        self.assertTrue(all(self.service.values()))
        self.store.rollback(identifier)
        self.assertEqual(self.link["max_segs"], 65535)
        self.assertFalse(any(self.service.values()))
        for path in plan["gso_persistence"]["after"]["files"]:
            self.assertFalse((self.root / path.lstrip("/")).exists())

    def test_already_one_still_adds_startup_and_repeated_plan_is_empty(self):
        self.link["max_segs"] = 1
        plan = self.persistent_plan()
        self.assertNotIn("gso", plan)
        identifier = self.store.apply(plan)
        self.assertNotIn("gso_persistence", self.persistent_plan())
        self.store.rollback(identifier)
        self.assertEqual(self.link["max_segs"], 1)

    def test_change_existing_persisted_limit_and_restore_previous_service(self):
        first = self.store.apply(self.persistent_plan())
        original = self.manager.snapshot({"interface":"eth0", "address":self.link["address"], "backend":"systemd"})
        plan = self.plan("--interface", "eth0", "--gso-max-segs", "65535", "--persist")
        validate_plan(plan)
        second = self.store.apply(plan)
        self.assertEqual(self.link["max_segs"], 65535)
        boot_adjust(self.host, "start", "eth0", self.link["address"], self.run, wait=0, target=65535)
        self.store.rollback(second)
        self.assertEqual(self.link["max_segs"], 1)
        self.assertEqual(self.manager.snapshot(plan["gso_persistence"]), original)
        self.store.rollback(first)
        self.assertEqual(self.link["max_segs"], 65535)

    def test_failed_service_start_rolls_back_runtime_files_and_service(self):
        def failure(step, action):
            self.control(step, action)
            if action == "start":
                raise TuneError("injected start failure")
        self.manager.control = failure
        plan = self.persistent_plan()
        with self.assertRaisesRegex(TuneError, "已恢复"):
            self.store.apply(plan)
        self.assertEqual(self.link["max_segs"], 65535)
        self.assertEqual(self.store.records()[0]["state"], "rolled_back")
        self.assertFalse(any(self.service.values()))

    def test_changed_runtime_value_invalidates_persist_only_plan(self):
        self.link["max_segs"] = 1
        plan = self.persistent_plan()
        self.link["max_segs"] = 12
        with self.assertRaises(TuneError):
            self.store.apply(plan)
        self.assertEqual(self.link["max_segs"], 12)
        self.assertFalse(self.run.exists())

    def test_partial_file_write_failure_recovers(self):
        failed = False
        def failure(path, content, mode):
            nonlocal failed
            if path.name == "net_tune_system.py" and content is not None and not failed:
                failed = True
                raise OSError("injected file failure")
            replace_file(path, content, mode)
        with patch("net_tune_changes.replace_file", side_effect=failure):
            with self.assertRaisesRegex(TuneError, "已恢复"):
                self.store.apply(self.persistent_plan())
        self.assertEqual(self.link["max_segs"], 65535)
        self.assertTrue(failed)
        self.assertFalse(any(self.service.values()))

    def test_rollback_after_reboot_restores_new_boot_baseline(self):
        identifier = self.store.apply(self.persistent_plan())
        (self.run / "eth0.json").unlink()
        self.host.scope_data.update(boot="second", netns=9)
        self.link["max_segs"] = 4096
        boot_adjust(self.host, "start", "eth0", self.link["address"], self.run, wait=0)
        self.assertEqual(self.link["max_segs"], 1)
        self.store.rollback(identifier)
        self.assertEqual(self.link["max_segs"], 4096)
        self.assertEqual(self.store.records()[0]["state"], "rolled_back")

    def test_foreign_files_and_plan_code_are_rejected(self):
        plan = self.persistent_plan()
        key = next(iter(plan["gso_persistence"]["after"]["files"]))
        altered = copy.deepcopy(plan)
        altered["gso_persistence"]["after"]["files"][key] += "\nprint('foreign')\n"
        with self.assertRaises(TuneError):
            validate_plan(altered)
        target = self.root / key.lstrip("/")
        target.parent.mkdir(parents=True)
        target.write_text("foreign")
        with self.assertRaises(TuneError):
            self.store.apply(self.persistent_plan())
        self.assertEqual(target.read_text(), "foreign")
        self.assertEqual(self.link["max_segs"], 65535)

    def test_foreign_edit_blocks_rollback_without_overwriting_file(self):
        plan = self.persistent_plan()
        identifier = self.store.apply(plan)
        path = next(iter(plan["gso_persistence"]["after"]["files"]))
        target = self.root / path.lstrip("/")
        target.write_text("foreign")
        with self.assertRaisesRegex(TuneError, "第三方"):
            self.store.rollback(identifier)
        self.assertEqual(target.read_text(), "foreign")
        self.assertEqual(self.store.records()[0]["state"], "reverting")

    def test_openrc_service_is_rendered_and_reversible(self):
        self.host.boot_loader = "openrc"
        plan = self.persistent_plan()
        files = plan["gso_persistence"]["after"]["files"]
        self.assertIn("/etc/init.d/net-tune-gso-eth0", files)
        self.assertIn("need net", files["/etc/init.d/net-tune-gso-eth0"])
        identifier = self.store.apply(plan)
        self.store.rollback(identifier)
        self.assertEqual(self.link["max_segs"], 65535)

    def test_auto_can_persist_selected_gso_candidate(self):
        pair = {"before": {"complete": True, "seconds": 4, "bytes": 1048576, "edge": "LAX", "retransmitted_bytes": 2000},
                "after": {"complete": True, "seconds": 2, "bytes": 1048576, "edge": "LAX", "retransmitted_bytes": 1000}}
        data = {"format": RESULTS_FORMAT, "scope": self.host.scope(), "peer": "192.0.2.20", "interface": "eth0",
                "baseline": {"sysctl": {key: self.host.sysctl(key) for key in BASELINE_KEYS},
                             "queue": self.host.queue_state("eth0"), "gso": self.host.gso_state("eth0")},
                "candidates": [{"name": "gso", "settings": {"gso_single_segment": True},
                                "workloads": [{"bytes": 1048576, "pairs": [pair, copy.deepcopy(pair)]}]}]}
        _, _, plan, selection = choose_results(self.host, self.store, data, parser().parse_args, persist=True)
        self.assertEqual(selection["selected"], "gso")
        self.assertIn("gso_persistence", plan)
        self.assertFalse(self.run.exists())

    def test_boot_start_is_idempotent_and_stop_keeps_foreign_gso(self):
        for _ in range(2):
            boot_adjust(self.host, "start", "eth0", self.link["address"], self.run, wait=0)
        saved = json.loads((self.run / "eth0.json").read_text())
        self.assertEqual(saved["link"]["max_segs"], 65535)
        self.link["max_segs"] = 12
        with self.assertRaisesRegex(TuneError, "第三方"):
            boot_adjust(self.host, "stop", "eth0", self.link["address"], self.run, wait=0)
        self.assertEqual(self.link["max_segs"], 12)
        self.assertTrue((self.run / "eth0.json").exists())

    def test_boot_start_failure_restores_link_and_rejects_changed_mac(self):
        def fail_once(interface, value):
            self.link["max_segs"] = value
            if value == 1:
                raise TuneError("injected write failure")
        self.host.set_gso_max_segs = fail_once
        with self.assertRaisesRegex(TuneError, "injected"):
            boot_adjust(self.host, "start", "eth0", self.link["address"], self.run, wait=0)
        self.assertEqual(self.link["max_segs"], 65535)
        self.assertFalse((self.run / "eth0.json").exists())
        with self.assertRaisesRegex(TuneError, "MAC"):
            boot_adjust(self.host, "start", "eth0", "02:00:00:00:00:02", self.run, wait=0)
        boot_adjust(self.host, "stop", "eth0", "02:00:00:00:00:02", self.run, wait=0)


@unittest.skipUnless(os.environ.get("NET_TUNE_NETNS_TEST") == "1", "set NET_TUNE_NETNS_TEST=1")
class GSOBootNamespaceTests(unittest.TestCase):
    def test_real_link_start_stop_and_failed_write(self):
        network = Path(__file__).resolve().parents[1]
        code = '''
import sys, tempfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from net_tune_gso import boot_adjust
from net_tune_system import LinuxHost, TuneError, checked
checked(['ip', 'link', 'add', 'test0', 'type', 'veth', 'peer', 'name', 'test1'])
checked(['ip', 'link', 'set', 'test0', 'up'])
host = LinuxHost()
original = host.gso_state('test0')
with tempfile.TemporaryDirectory() as temp:
    run = Path(temp) / 'run'
    for _ in range(2):
        boot_adjust(host, 'start', 'test0', original['address'], run, wait=0)
    assert host.gso_state('test0')['max_segs'] == 1
    boot_adjust(host, 'stop', 'test0', original['address'], run, wait=0)
    assert host.gso_state('test0') == original
    write = host.set_gso_max_segs
    def fail(interface, value):
        write(interface, value)
        if value == 1:
            raise TuneError('injected write failure')
    host.set_gso_max_segs = fail
    try:
        boot_adjust(host, 'start', 'test0', original['address'], run, wait=0)
        raise AssertionError('failure missing')
    except TuneError:
        pass
    assert host.gso_state('test0') == original
'''
        result = subprocess.run(["unshare", "-Urnmpf", "--mount-proc", sys.executable, "-B", "-c", code, str(network)],
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
