import http.server
import os
import shlex
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEEPALIVE = ROOT / "oracle_keepalive.sh"
SERVICES = ROOT / "oracle_app_services.sh"
KEEPALIVE_README = ROOT / "README_oracle_keepalive_zh.md"
SERVICES_README = ROOT / "README_oracle_app_services_zh.md"


class ScriptTestCase(unittest.TestCase):
    maxDiff = None

    def script_env(self, **env_overrides: str) -> dict[str, str]:
        env = {
            key: value
            for key, value in os.environ.items()
            if key in {"HOME", "PATH", "TMPDIR", "TMP", "TEMP"}
        }
        env.setdefault("PATH", os.defpath)
        env.update(env_overrides)
        return env

    def run_script(
        self,
        script: Path,
        *args: str,
        timeout: int = 15,
        **env_overrides: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(script), *args],
            cwd=ROOT,
            env=self.script_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )

    def run_script_with_input(
        self,
        script: Path,
        input_text: str,
        *args: str,
        timeout: int = 5,
        **env_overrides: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(script), *args],
            cwd=ROOT,
            env=self.script_env(**env_overrides),
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )

    def run_script_in_new_session(
        self,
        script: Path,
        *args: str,
        timeout: int = 15,
        **env_overrides: str,
    ) -> subprocess.CompletedProcess[str]:
        command = ["bash", str(script), *args]
        proc = subprocess.Popen(
            command,
            cwd=ROOT,
            env=self.script_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.terminate_process_group(proc, signal.SIGKILL)
            stdout, stderr = proc.communicate(timeout=5)
            self.fail(f"script timed out after {timeout}s\n{stdout}{stderr}")
        return subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)

    def skip_if_running_as_root(self) -> None:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            self.skipTest("fake system-command tests are disabled under root")

    def start_http_server(
        self,
        handler_class: type[http.server.BaseHTTPRequestHandler],
    ) -> tuple[http.server.ThreadingHTTPServer, threading.Thread, str]:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_class)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        return server, thread, f"http://127.0.0.1:{port}/large"

    def stop_http_server(
        self,
        server: http.server.ThreadingHTTPServer,
        thread: threading.Thread,
    ) -> None:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    def terminate_process_group(self, proc: subprocess.Popen, sig: int = signal.SIGTERM) -> None:
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return

    def process_exists(self, pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def process_descendants(self, pid: int) -> set[int]:
        return set(self.process_descendant_commands(pid))

    def process_descendant_commands(self, pid: int) -> dict[int, str]:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,command="],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        children_by_parent: dict[int, list[tuple[int, str]]] = {}
        for line in result.stdout.splitlines():
            parts = line.split(maxsplit=2)
            if len(parts) < 2:
                continue
            child_pid, parent_pid = int(parts[0]), int(parts[1])
            command = parts[2] if len(parts) == 3 else ""
            children_by_parent.setdefault(parent_pid, []).append((child_pid, command))

        descendants: dict[int, str] = {}
        pending = [pid]
        while pending:
            current = pending.pop()
            for child_pid, command in children_by_parent.get(current, []):
                if child_pid in descendants:
                    continue
                descendants[child_pid] = command
                pending.append(child_pid)
        return descendants

    def write_fake_root_stat(self, bin_dir: Path, owner_uid: str = "0") -> None:
        stat = bin_dir / "stat"
        stat.write_text(
            "#!/bin/sh\n"
            f"owner_uid={shlex.quote(owner_uid)}\n"
            "print_mode() {\n"
            "  python3 - \"$1\" <<'PY'\n"
            "import os\n"
            "import sys\n"
            "path = sys.argv[1]\n"
            "if os.path.isdir(path) and not os.path.exists(os.path.join(path, '.unsafe-mode')):\n"
            "    print('755')\n"
            "else:\n"
            "    print(format(os.lstat(path).st_mode & 0o777, 'o'))\n"
            "PY\n"
            "}\n"
            "print_owner() {\n"
            "  if [ -d \"$1\" ]; then echo 0; else echo \"$owner_uid\"; fi\n"
            "}\n"
            "if [ \"$1\" = -f ]; then\n"
            "  if [ \"$2\" = %u ]; then print_owner \"$3\"; exit 0; fi\n"
            "  if [ \"$2\" = %Lp ]; then print_mode \"$3\"; exit 0; fi\n"
            "fi\n"
            "if [ \"$1\" = -c ]; then\n"
            "  if [ \"$2\" = %u ]; then print_owner \"$3\"; exit 0; fi\n"
            "  if [ \"$2\" = %a ]; then print_mode \"$3\"; exit 0; fi\n"
            "fi\n"
            "echo 'unexpected stat args' >&2\n"
            "exit 127\n",
            encoding="utf-8",
        )
        stat.chmod(0o755)

    def write_fake_proxy_commands(self, bin_dir: Path, owner_uid: str = "0", systemctl_body: str = "exit 0\n") -> None:
        (bin_dir / "id").write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
            "echo 'unexpected id args' >&2\n"
            "exit 127\n",
            encoding="utf-8",
        )
        (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (bin_dir / "systemctl").write_text(f"#!/bin/sh\n{systemctl_body}", encoding="utf-8")
        (bin_dir / "crontab").write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = -l ]; then exit 0; fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        self.write_fake_root_stat(bin_dir, owner_uid=owner_uid)
        for script in [bin_dir / "id", bin_dir / "nginx", bin_dir / "systemctl", bin_dir / "crontab"]:
            script.chmod(0o755)


class OracleKeepaliveTests(ScriptTestCase):
    def test_keepalive_script_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(KEEPALIVE)],
            env=self.script_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_keepalive_check_prints_ok(self):
        result = self.run_script(KEEPALIVE, "check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("oracle_keepalive.sh OK", result.stdout)

    def test_keepalive_help_lists_systemd_commands(self):
        result = self.run_script(KEEPALIVE, "help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("install", result.stdout)
        self.assertIn("uninstall", result.stdout)
        self.assertIn("logs", result.stdout)
        self.assertIn("verify", result.stdout)

    def test_script_env_filters_unrelated_environment_variables(self):
        env = self.script_env(BASH_ENV="/tmp/should-not-survive", LD_PRELOAD="/tmp/libbad.so")

        self.assertNotIn("ENV", env)
        self.assertEqual(env["BASH_ENV"], "/tmp/should-not-survive")
        self.assertEqual(env["LD_PRELOAD"], "/tmp/libbad.so")

    def test_run_script_does_not_source_bash_env_from_host(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = Path(temp_dir) / "sourced"
            bash_env = Path(temp_dir) / "bash_env"
            bash_env.write_text(f"touch {shlex.quote(str(marker))}\n", encoding="utf-8")
            original = os.environ.get("BASH_ENV")
            os.environ["BASH_ENV"] = str(bash_env)
            try:
                result = self.run_script(KEEPALIVE, "check")
            finally:
                if original is None:
                    os.environ.pop("BASH_ENV", None)
                else:
                    os.environ["BASH_ENV"] = original
            marker_exists = marker.exists()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker_exists, "run_script must not inherit host BASH_ENV")

    def test_keepalive_menu_can_run_check_without_args(self):
        result = self.run_script_with_input(KEEPALIVE, "6\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Oracle Keepalive Menu", result.stdout)
        self.assertIn("oracle_keepalive.sh OK", result.stdout)

    def test_keepalive_supports_stdin_remote_execution_for_check(self):
        result = subprocess.run(
            ["bash", "-s", "--", "check"],
            input=KEEPALIVE.read_text(encoding="utf-8"),
            cwd=ROOT,
            env=self.script_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("oracle_keepalive.sh OK", result.stdout)

    def test_keepalive_readme_documents_remote_run_examples(self):
        readme = KEEPALIVE_README.read_text(encoding="utf-8")
        self.assertIn("交互式菜单", readme)
        self.assertIn("bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh)", readme)
        self.assertIn("bash -s --", readme)
        self.assertNotIn("oracle_useful_services.sh", readme)
        self.assertNotIn("KEEPALIVE_SERVICE_", readme)

    def test_keepalive_dry_run_install_prints_unit_and_config(self):
        result = self.run_script(KEEPALIVE, "install", ORACLE_KEEPALIVE_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DRY-RUN] Would write config", result.stdout)
        self.assertIn("KEEPALIVE_CPU_TARGET_PERCENT=25", result.stdout)
        self.assertIn("ExecStart=/usr/local/bin/oracle_keepalive.sh run", result.stdout)
        self.assertIn("Nice=19", result.stdout)
        self.assertIn("CPUWeight=1", result.stdout)
        self.assertIn("OOMScoreAdjust=500", result.stdout)

    def test_keepalive_dry_run_config_exposes_strategy_selection_flags(self):
        result = self.run_script(KEEPALIVE, "install", ORACLE_KEEPALIVE_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in [
            "KEEPALIVE_CPU_ENABLED=1",
            "KEEPALIVE_MEMORY_ENABLED=1",
            "KEEPALIVE_NETWORK_ENABLED=1",
        ]:
            self.assertIn(line, result.stdout)
        for removed_key in [
            "KEEPALIVE_SERVICE_ENABLED",
            "KEEPALIVE_SERVICE_NAME",
            "KEEPALIVE_SERVICE_SCRIPT",
        ]:
            self.assertNotIn(removed_key, result.stdout)

    def test_keepalive_systemd_cpu_quota_matches_whole_machine_target(self):
        cores = os.cpu_count() or 1
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            KEEPALIVE_CPU_TARGET_PERCENT="25",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"CPUQuota={cores * 25}%", result.stdout)

    def test_keepalive_dry_run_install_preserves_selected_keepalive_methods(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            KEEPALIVE_CPU_ENABLED="0",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="1",
            KEEPALIVE_SERVICE_ENABLED="1",
            KEEPALIVE_SERVICE_NAME="wordpress",
            KEEPALIVE_SERVICE_SCRIPT="/opt/oracle_app_services.sh",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for line in [
            "KEEPALIVE_CPU_ENABLED=0",
            "KEEPALIVE_MEMORY_ENABLED=0",
            "KEEPALIVE_NETWORK_ENABLED=1",
        ]:
            self.assertIn(line, result.stdout)
        self.assertNotIn("KEEPALIVE_SERVICE_ENABLED", result.stdout)
        self.assertNotIn("KEEPALIVE_SERVICE_NAME", result.stdout)
        self.assertNotIn("KEEPALIVE_SERVICE_SCRIPT", result.stdout)

    def test_keepalive_dry_run_install_unit_exposes_safe_path(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            PATH="/tmp/unsafe-bin:/usr/bin:/bin",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin", result.stdout)
        self.assertNotIn("/tmp/unsafe-bin", result.stdout)

    def test_keepalive_check_accepts_safe_network_rate_limits(self):
        for rate_limit in ["512k", "1M", "1048576"]:
            with self.subTest(rate_limit=rate_limit):
                result = self.run_script(
                    KEEPALIVE,
                    "check",
                    KEEPALIVE_CPU_ENABLED="0",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="1",
                    KEEPALIVE_NETWORK_RATE_LIMIT=rate_limit,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("oracle_keepalive.sh OK", result.stdout)

    def test_keepalive_check_rejects_network_rate_limit_control_chars(self):
        for rate_limit in ["512k\nINJECTED=1", "512k\rINJECTED=1", "512k\x1f", "512k\x7f"]:
            with self.subTest(rate_limit=repr(rate_limit)):
                result = self.run_script(
                    KEEPALIVE,
                    "check",
                    KEEPALIVE_CPU_ENABLED="0",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="1",
                    KEEPALIVE_NETWORK_RATE_LIMIT=rate_limit,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsafe network rate limit", result.stderr)
                self.assertNotIn("oracle_keepalive.sh OK", result.stdout)
                self.assertNotIn("INJECTED=1", result.stdout + result.stderr)

    def test_keepalive_install_dry_run_rejects_network_rate_limit_environmentfile_injection(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            KEEPALIVE_NETWORK_RATE_LIMIT="512k\nINJECTED=1",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe network rate limit", result.stderr)
        self.assertNotIn("INJECTED=1", result.stdout + result.stderr)
        self.assertNotIn("[DRY-RUN] Would write config", result.stdout)

    def test_keepalive_install_dry_run_rejects_network_urls_environmentfile_injection(self):
        for network_enabled in ["0", "1"]:
            with self.subTest(network_enabled=network_enabled):
                result = self.run_script(
                    KEEPALIVE,
                    "install",
                    ORACLE_KEEPALIVE_DRY_RUN="1",
                    KEEPALIVE_NETWORK_ENABLED=network_enabled,
                    KEEPALIVE_NETWORK_URLS="https://example.com\nINJECTED=1",
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsafe network URL", result.stderr)
                self.assertNotIn("INJECTED=1", result.stdout + result.stderr)
                self.assertNotIn("[DRY-RUN] Would write config", result.stdout)

    def test_keepalive_install_rejects_systemd_environmentfile_glob_path(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            ORACLE_KEEPALIVE_CONFIG="/tmp/oracle-keepalive-*.conf",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe path", result.stderr)
        self.assertNotIn("EnvironmentFile=-/tmp/oracle-keepalive-*.conf", result.stdout)

    def test_keepalive_install_rejects_systemd_percent_specifier_path(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            ORACLE_KEEPALIVE_CONFIG="/tmp/%n.conf",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe path", result.stderr)
        self.assertNotIn("EnvironmentFile=-/tmp/%n.conf", result.stdout)

    def test_keepalive_check_loads_config_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "oracle-keepalive.conf"
            config_file.write_text(
                "KEEPALIVE_CPU_ENABLED=0\n"
                "KEEPALIVE_MEMORY_ENABLED=0\n"
                "KEEPALIVE_NETWORK_ENABLED=0\n",
                encoding="utf-8",
            )
            result = self.run_script(KEEPALIVE, "check", ORACLE_KEEPALIVE_CONFIG=str(config_file))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("At least one keepalive method must be enabled", result.stderr)

    def test_keepalive_config_parser_does_not_execute_shell(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "oracle-keepalive.conf"
            marker = Path(temp_dir) / "executed"
            config_file.write_text(
                "KEEPALIVE_CPU_ENABLED=1\n"
                "KEEPALIVE_MEMORY_ENABLED=0\n"
                "KEEPALIVE_NETWORK_ENABLED=0\n"
                f"$(touch {marker})\n",
                encoding="utf-8",
            )
            result = self.run_script(KEEPALIVE, "check", ORACLE_KEEPALIVE_CONFIG=str(config_file))
            self.assertFalse(marker.exists(), "config parsing must not execute shell commands")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_keepalive_install_rejects_systemd_path_injection(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            ORACLE_KEEPALIVE_INSTALL_PATH="/tmp/oracle_keepalive.sh\nExecStart=/bin/sh",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe path", result.stderr)

    def test_keepalive_verify_cpu_samples_without_env_override(self):
        result = self.run_script(
            KEEPALIVE,
            "verify",
            KEEPALIVE_CPU_ENABLED="1",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="0",
            KEEPALIVE_CPU_TARGET_PERCENT="80",
            KEEPALIVE_VERIFY_CPU_SAMPLE_SECONDS="1",
        )
        self.assertIn("CPU:", result.stdout)
        self.assertNotIn("current=unknown", result.stdout)

    def test_keepalive_check_rejects_all_methods_disabled(self):
        result = self.run_script(
            KEEPALIVE,
            "check",
            KEEPALIVE_CPU_ENABLED="0",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="0",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("At least one keepalive method must be enabled", result.stderr)
        self.assertNotIn("oracle_keepalive.sh OK", result.stdout)

    def test_keepalive_check_accepts_single_enabled_method(self):
        result = self.run_script(
            KEEPALIVE,
            "check",
            KEEPALIVE_CPU_ENABLED="1",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("oracle_keepalive.sh OK", result.stdout)

    def test_keepalive_verify_reports_cpu_target_met_from_env_override(self):
        result = self.run_script(
            KEEPALIVE,
            "verify",
            KEEPALIVE_CPU_ENABLED="1",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="0",
            KEEPALIVE_CPU_TARGET_PERCENT="20",
            KEEPALIVE_VERIFY_CPU_PERCENT="25",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CPU: PASS", result.stdout)

    def test_keepalive_verify_fails_when_enabled_cpu_below_target(self):
        result = self.run_script(
            KEEPALIVE,
            "verify",
            KEEPALIVE_CPU_ENABLED="1",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="0",
            KEEPALIVE_CPU_TARGET_PERCENT="20",
            KEEPALIVE_VERIFY_CPU_PERCENT="10",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CPU: FAIL", result.stdout)

    def test_keepalive_verify_reports_memory_target_met_from_env_override(self):
        result = self.run_script(
            KEEPALIVE,
            "verify",
            KEEPALIVE_CPU_ENABLED="0",
            KEEPALIVE_MEMORY_ENABLED="1",
            KEEPALIVE_NETWORK_ENABLED="0",
            KEEPALIVE_MEMORY_TARGET_PERCENT="20",
            KEEPALIVE_VERIFY_MEMORY_PERCENT="25",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Memory: PASS", result.stdout)

    def test_keepalive_verify_network_only_uses_selected_strategy(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            requests = 0

            def do_GET(self) -> None:
                type(self).requests += 1
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, format: str, *args: object) -> None:
                return

        server, thread, url = self.start_http_server(Handler)
        try:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                KEEPALIVE_CPU_ENABLED="0",
                KEEPALIVE_MEMORY_ENABLED="0",
                KEEPALIVE_NETWORK_ENABLED="1",
                KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                KEEPALIVE_NETWORK_URLS=url,
            )
        finally:
            self.stop_http_server(server, thread)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.requests, 1)
        self.assertIn("CPU: SKIP", result.stdout)
        self.assertIn("Memory: SKIP", result.stdout)
        self.assertIn("Network: PASS", result.stdout)

    def test_keepalive_verify_network_handles_leading_zero_minute(self):
        self.skip_if_running_as_root()

        class Handler(http.server.BaseHTTPRequestHandler):
            requests = 0

            def do_GET(self) -> None:
                type(self).requests += 1
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, format: str, *args: object) -> None:
                return

        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            bin_dir.mkdir()
            (bin_dir / "date").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = +%M ]; then echo 08; exit 0; fi\n"
                "exec /bin/date \"$@\"\n",
                encoding="utf-8",
            )
            (bin_dir / "date").chmod(0o755)
            server, thread, url = self.start_http_server(Handler)
            try:
                result = self.run_script(
                    KEEPALIVE,
                    "verify",
                    KEEPALIVE_CPU_ENABLED="0",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="1",
                    KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                    KEEPALIVE_NETWORK_URLS=f"{url} https://127.0.0.1:9/unreachable",
                    PATH=f"{bin_dir}:{os.environ['PATH']}",
                )
            finally:
                self.stop_http_server(server, thread)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Handler.requests, 1)
        self.assertIn("Network: PASS", result.stdout)

    def test_keepalive_ignores_removed_app_service_strategy(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = Path(temp_dir) / "called"
            service_script = Path(temp_dir) / "oracle_app_services.sh"
            service_script.write_text(
                "#!/usr/bin/env bash\n"
                f"touch {marker}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            result = self.run_script(
                KEEPALIVE,
                "verify",
                KEEPALIVE_CPU_ENABLED="0",
                KEEPALIVE_MEMORY_ENABLED="0",
                KEEPALIVE_NETWORK_ENABLED="0",
                KEEPALIVE_SERVICE_ENABLED="1",
                KEEPALIVE_SERVICE_NAME="wordpress",
                KEEPALIVE_SERVICE_SCRIPT=str(service_script),
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker_exists, "keepalive must not call app service scripts")
        self.assertNotIn("Service:", result.stdout)
        self.assertIn("At least one keepalive method must be enabled", result.stderr)

    def test_keepalive_verify_network_passes_on_partial_nonzero_download_before_timeout(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            sent_bytes = 0

            def do_GET(self) -> None:
                self.send_response(200)
                self.send_header("Content-Length", "1048576")
                self.end_headers()
                try:
                    self.wfile.write(b"x" * 1024)
                    self.wfile.flush()
                    type(self).sent_bytes += 1024
                    time.sleep(2)
                except (BrokenPipeError, ConnectionResetError):
                    return

            def log_message(self, format: str, *args: object) -> None:
                return

        server, thread, url = self.start_http_server(Handler)
        try:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                timeout=5,
                KEEPALIVE_CPU_ENABLED="0",
                KEEPALIVE_MEMORY_ENABLED="0",
                KEEPALIVE_NETWORK_ENABLED="1",
                KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                KEEPALIVE_NETWORK_RATE_LIMIT="512k",
                KEEPALIVE_NETWORK_URLS=url,
            )
        finally:
            self.stop_http_server(server, thread)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater(Handler.sent_bytes, 0)
        self.assertIn("Network: PASS", result.stdout)
        self.assertNotIn("Network: FAIL", result.stdout)

    def test_keepalive_verify_network_fails_when_timeout_downloads_zero_bytes(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            requests = 0

            def do_GET(self) -> None:
                type(self).requests += 1
                self.send_response(200)
                self.send_header("Content-Length", "1048576")
                self.end_headers()
                time.sleep(2)

            def log_message(self, format: str, *args: object) -> None:
                return

        server, thread, url = self.start_http_server(Handler)
        try:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                timeout=5,
                KEEPALIVE_CPU_ENABLED="0",
                KEEPALIVE_MEMORY_ENABLED="0",
                KEEPALIVE_NETWORK_ENABLED="1",
                KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                KEEPALIVE_NETWORK_RATE_LIMIT="512k",
                KEEPALIVE_NETWORK_URLS=url,
            )
        finally:
            self.stop_http_server(server, thread)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(Handler.requests, 1)
        self.assertIn("Network: FAIL", result.stdout)


class OracleUsefulServicesTests(ScriptTestCase):
    def test_services_script_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(SERVICES)],
            env=self.script_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_services_list_includes_all_blog_options(self):
        result = self.run_script(SERVICES, "list")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ["hugo", "wordpress", "halo", "typecho"]:
            self.assertIn(name, result.stdout)

    def test_services_supports_stdin_remote_execution_for_list(self):
        result = subprocess.run(
            ["bash", "-s", "--", "list"],
            input=SERVICES.read_text(encoding="utf-8"),
            cwd=ROOT,
            env=self.script_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ["hugo", "wordpress", "halo", "typecho"]:
            self.assertIn(name, result.stdout)

    def test_services_readme_documents_remote_run_examples(self):
        readme = SERVICES_README.read_text(encoding="utf-8")
        self.assertIn("oracle_app_services.sh", readme)
        self.assertIn("交互式菜单", readme)
        self.assertIn("bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh)", readme)
        self.assertIn("bash -s --", readme)
        self.assertNotIn("oracle_useful_services.sh", readme)

    def test_services_readme_documents_domain_nginx_certificate_usage(self):
        readme = SERVICES_README.read_text(encoding="utf-8")
        for expected in [
            "proxy <service> <domain>",
            "deploy <service> [domain]",
            "Nginx",
            "acme.sh",
            "Cloudflare DNS-01",
            "Let's Encrypt standalone",
            "ORACLE_SERVICES_CERT_MODE=standalone",
            "CF_Token",
            "CF_Zone_ID",
            "/etc/nginx/ssl/<domain>/fullchain.cer",
            "crontab",
        ]:
            self.assertIn(expected, readme)
        self.assertNotIn("把 CF_Token 写入", readme)

    def test_services_dry_run_generates_wordpress_compose(self):
        result = self.run_script(SERVICES, "deploy", "wordpress", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wordpress:", result.stdout)
        self.assertIn("mariadb:", result.stdout)
        self.assertIn("WORDPRESS_DB_PASSWORD", result.stdout)

    def test_services_dry_run_generates_halo_compose(self):
        result = self.run_script(SERVICES, "deploy", "halo", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("halo:", result.stdout)
        self.assertIn("postgres:", result.stdout)
        self.assertIn("SPRING_R2DBC_PASSWORD", result.stdout)

    def test_services_dry_run_generates_typecho_compose(self):
        result = self.run_script(SERVICES, "deploy", "typecho", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("typecho:", result.stdout)
        self.assertIn("mariadb:", result.stdout)
        self.assertIn("TYPECHO_DB_PASSWORD", result.stdout)

    def test_services_dry_run_generates_hugo_compose(self):
        result = self.run_script(SERVICES, "deploy", "hugo", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nginx:", result.stdout)
        self.assertIn("hugo-site", result.stdout)

    def test_services_dry_run_binds_http_ports_to_loopback(self):
        cases = {
            "hugo": "127.0.0.1:8080:80",
            "wordpress": "127.0.0.1:8081:80",
            "halo": "127.0.0.1:8082:8090",
            "typecho": "127.0.0.1:8083:80",
        }
        for service, mapping in cases.items():
            with self.subTest(service=service):
                result = self.run_script(SERVICES, "deploy", service, ORACLE_SERVICES_DRY_RUN="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'"{mapping}"', result.stdout)

    def test_services_dry_run_halo_domain_sets_external_url(self):
        result = self.run_script(SERVICES, "deploy", "halo", "halo.example.com", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HALO_EXTERNAL_URL: https://halo.example.com/", result.stdout)
        self.assertNotIn("HALO_EXTERNAL_URL: http://localhost:8082/", result.stdout)

    def test_services_help_lists_verify_command(self):
        result = self.run_script(SERVICES, "help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verify <service>", result.stdout)

    def test_services_help_lists_proxy_domain_usage(self):
        result = self.run_script(SERVICES, "help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deploy <service> [domain]", result.stdout)
        self.assertIn("proxy <service> <domain>", result.stdout)

    def test_services_menu_can_proxy_with_standalone_certificate_mode_without_args(self):
        result = self.run_script_with_input(
            SERVICES,
            "4\nwordpress\nblog.example.com\n2\n0\n",
            ORACLE_SERVICES_DRY_RUN="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Oracle App Services Menu", result.stdout)
        self.assertIn("Certificate mode", result.stdout)
        self.assertIn("--standalone -d blog.example.com", result.stdout)
        self.assertNotIn("--dns dns_cf", result.stdout)

    def test_services_dry_run_deploy_with_domain_generates_nginx_reverse_proxy(self):
        result = self.run_script(SERVICES, "deploy", "wordpress", "blog.example.com", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wordpress:", result.stdout)
        self.assertIn("mariadb:", result.stdout)
        self.assertIn("WORDPRESS_DB_PASSWORD", result.stdout)
        upstream = next(line.split()[1] for line in result.stdout.splitlines() if line.startswith("upstream oracle_wordpress_"))
        self.assertTrue(upstream.startswith("oracle_wordpress_blog_example_com_"))
        for expected in [
            "server_name blog.example.com;",
            "listen 80;",
            "listen 443 ssl;",
            "return 301 https://blog.example.com$request_uri;",
            f"proxy_pass http://{upstream};",
            "proxy_set_header Host blog.example.com;",
            "proxy_set_header X-Real-IP $remote_addr;",
            "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "proxy_set_header X-Forwarded-Proto $scheme;",
            "proxy_set_header X-Original-URI $request_uri;",
            "proxy_connect_timeout 60s;",
            "proxy_send_timeout 600s;",
            "proxy_read_timeout 3600s;",
            "proxy_buffering off;",
            "/etc/nginx/ssl/blog.example.com/fullchain.cer",
            "/etc/nginx/ssl/blog.example.com/private.key",
        ]:
            self.assertIn(expected, result.stdout)

    def test_services_dry_run_proxy_uses_unique_backend_name_per_domain(self):
        first = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", ORACLE_SERVICES_DRY_RUN="1")
        second = self.run_script(SERVICES, "proxy", "wordpress", "www.example.com", ORACLE_SERVICES_DRY_RUN="1")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        first_upstream = next(line.split()[1] for line in first.stdout.splitlines() if line.startswith("upstream oracle_wordpress_"))
        second_upstream = next(line.split()[1] for line in second.stdout.splitlines() if line.startswith("upstream oracle_wordpress_"))
        self.assertTrue(first_upstream.startswith("oracle_wordpress_blog_example_com_"))
        self.assertTrue(second_upstream.startswith("oracle_wordpress_www_example_com_"))
        self.assertNotEqual(first_upstream, second_upstream)
        self.assertIn(f"map $http_upgrade ${first_upstream}_connection_upgrade", first.stdout)
        self.assertIn(f"proxy_pass http://{first_upstream};", first.stdout)
        self.assertIn(f"proxy_set_header Connection ${first_upstream}_connection_upgrade;", first.stdout)
        self.assertIn(f"map $http_upgrade ${second_upstream}_connection_upgrade", second.stdout)
        self.assertIn(f"proxy_pass http://{second_upstream};", second.stdout)
        self.assertIn(f"proxy_set_header Connection ${second_upstream}_connection_upgrade;", second.stdout)
        self.assertNotIn("upstream oracle_wordpress_backend", first.stdout + second.stdout)

    def test_services_dry_run_proxy_avoids_sanitized_domain_name_collisions(self):
        first = self.run_script(SERVICES, "proxy", "wordpress", "a-b.example.com", ORACLE_SERVICES_DRY_RUN="1")
        second = self.run_script(SERVICES, "proxy", "wordpress", "a.b.example.com", ORACLE_SERVICES_DRY_RUN="1")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("upstream oracle_wordpress_a_b_example_com_", first.stdout)
        self.assertIn("upstream oracle_wordpress_a_b_example_com_", second.stdout)
        self.assertNotEqual(
            next(line for line in first.stdout.splitlines() if line.startswith("upstream oracle_wordpress_")),
            next(line for line in second.stdout.splitlines() if line.startswith("upstream oracle_wordpress_")),
        )

    def test_services_dry_run_proxy_uses_service_specific_backend_port(self):
        cases = {
            "hugo": "127.0.0.1:8080",
            "wordpress": "127.0.0.1:8081",
            "halo": "127.0.0.1:8082",
            "typecho": "127.0.0.1:8083",
        }
        for service, backend in cases.items():
            with self.subTest(service=service):
                result = self.run_script(
                    SERVICES,
                    "proxy",
                    service,
                    f"{service}.example.com",
                    ORACLE_SERVICES_DRY_RUN="1",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"server_name {service}.example.com;", result.stdout)
                self.assertIn(f"server {backend};", result.stdout)

    def test_services_dry_run_proxy_uses_acme_cloudflare_dns01_letsencrypt(self):
        result = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--set-default-ca --server letsencrypt", result.stdout)
        self.assertIn("--issue --server letsencrypt --dns dns_cf -d blog.example.com --keylength ec-256 --home /root/.acme.sh", result.stdout)
        self.assertNotIn("--standalone", result.stdout)
        self.assertNotIn("zerossl", result.stdout.lower())

    def test_services_dry_run_proxy_uses_standalone_letsencrypt_when_selected(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
            ORACLE_SERVICES_CERT_MODE="standalone",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--set-default-ca --server letsencrypt", result.stdout)
        self.assertIn("--issue --server letsencrypt --standalone -d blog.example.com --keylength ec-256 --home /root/.acme.sh", result.stdout)
        self.assertIn("--install-cert -d blog.example.com --ecc --home /root/.acme.sh", result.stdout)
        self.assertNotIn("--dns dns_cf", result.stdout)
        self.assertNotIn("CF_Token", result.stdout)
        self.assertNotIn("CF_Zone_ID", result.stdout)

    def test_services_proxy_rejects_unknown_certificate_mode(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
            ORACLE_SERVICES_CERT_MODE="bad-mode",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown certificate mode", result.stderr)
        self.assertNotIn("--issue", result.stdout)
        self.assertNotIn("server_name blog.example.com", result.stdout)

    def test_services_dry_run_proxy_installs_certificate_to_nginx_ssl_path(self):
        result = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in [
            "mkdir -p /etc/nginx/ssl/blog.example.com",
            "chmod 700 /etc/nginx/ssl/blog.example.com",
            "--install-cert -d blog.example.com --ecc --home /root/.acme.sh",
            "--fullchain-file /etc/nginx/ssl/blog.example.com/fullchain.cer",
            "--key-file /etc/nginx/ssl/blog.example.com/private.key",
            "chmod 600 /etc/nginx/ssl/blog.example.com/private.key",
            "chmod 644 /etc/nginx/ssl/blog.example.com/fullchain.cer",
            "--reloadcmd \"systemctl reload nginx\"",
        ]:
            self.assertIn(expected, result.stdout)

    def test_services_dry_run_proxy_uses_custom_acme_sh_for_renewal(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
            ORACLE_SERVICES_ACME_SH="/usr/local/bin/acme.sh",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"/usr/local/bin/acme.sh" --renew -d blog.example.com', result.stdout)

    def test_services_dry_run_proxy_adds_idempotent_acme_renew_cron(self):
        result = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", ORACLE_SERVICES_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in [
            "crontab -l",
            "ORACLE_APP_SERVICE_RENEW:blog.example.com:cloudflare",
            "grep -v 'ORACLE_APP_SERVICE_RENEW:blog\\.example\\.com:'",
            "--renew -d blog.example.com --ecc --home \"/root/.acme.sh\"",
            ">> /etc/nginx/ssl/blog.example.com/acme-renew.log 2>&1",
        ]:
            self.assertIn(expected, result.stdout)

    def test_services_standalone_dry_run_cron_uses_wrapper_instead_of_inline_nginx_stop_start(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
            ORACLE_SERVICES_CERT_MODE="standalone",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/etc/nginx/ssl/blog.example.com/renew-standalone.sh", result.stdout)
        self.assertIn("timeout 20m", result.stdout)
        self.assertNotIn("10 3 * * * systemctl stop nginx", result.stdout)
        self.assertNotIn("systemctl stop nginx >/dev/null 2>&1;", result.stdout)

    def test_services_verify_rejects_unknown_service(self):
        result = self.run_script(SERVICES, "verify", "unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown service", result.stderr)

    def test_services_verify_reports_healthy_deployed_service(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            service_dir = Path(temp_dir) / "services" / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = ps ]; then\n"
                "  echo 'wordpress running healthy'\n"
                "  exit 0\n"
                "fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = self.run_script(
                SERVICES,
                "verify",
                "wordpress",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_HOME=str(Path(temp_dir) / "services"),
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("wordpress", result.stdout)
        self.assertIn("verify OK", result.stdout)

    def test_services_verify_rejects_unhealthy_service(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            service_dir = Path(temp_dir) / "services" / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = ps ]; then\n"
                "  echo 'wordpress exited unhealthy'\n"
                "  exit 0\n"
                "fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = self.run_script(
                SERVICES,
                "verify",
                "wordpress",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_HOME=str(Path(temp_dir) / "services"),
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not healthy", result.stderr)
        self.assertNotIn("verify OK", result.stdout)


class OracleReviewRegressionTests(ScriptTestCase):
    def test_services_proxy_rejects_invalid_domain(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com\nserver_name attacker.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid domain", result.stderr)
        self.assertNotIn("server_name attacker.example.com", result.stdout)
        self.assertNotIn("acme.sh --issue", result.stdout)

    def test_services_proxy_requires_cloudflare_dns_credentials_without_echoing_values(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_HOME="/tmp/oracle-services-test",
            CF_Token="sensitive-token-value",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CF_Zone_ID", result.stderr)
        self.assertNotIn("sensitive-token-value", result.stdout + result.stderr)

    def test_services_proxy_standalone_does_not_require_cloudflare_credentials(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            acme_home = root / "acme"
            acme_sh = acme_home / "acme.sh"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            acme_home.mkdir()
            (bin_dir / "id").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "systemctl").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "crontab").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -l ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            self.write_fake_root_stat(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                "while [ $# -gt 0 ]; do\n"
                "  case \"$1\" in\n"
                "    --fullchain-file) fullchain=\"$2\"; shift 2 ;;\n"
                "    --key-file) key=\"$2\"; shift 2 ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                "[ -n \"${fullchain:-}\" ] && { mkdir -p \"$(dirname \"$fullchain\")\"; : > \"$fullchain\"; }\n"
                "[ -n \"${key:-}\" ] && { mkdir -p \"$(dirname \"$key\")\"; : > \"$key\"; }\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "id", bin_dir / "nginx", bin_dir / "systemctl", bin_dir / "crontab", acme_sh]:
                script.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                ORACLE_SERVICES_CERT_MODE="standalone",
            )
            wrapper = nginx_ssl_dir / "blog.example.com" / "renew-standalone.sh"
            wrapper_exists = wrapper.exists()
            wrapper_mode = wrapper.stat().st_mode & 0o777
            wrapper_text = wrapper.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("CF_Token", result.stderr)
        self.assertNotIn("CF_Zone_ID", result.stderr)
        self.assertTrue(wrapper_exists)
        self.assertEqual(wrapper_mode, 0o700)
        self.assertTrue(wrapper_text.startswith("#!/bin/bash\n"))
        self.assertIn("PATH=/usr/sbin:/usr/bin:/sbin:/bin", wrapper_text)
        self.assertIn("restore_nginx", wrapper_text)
        self.assertIn("systemctl start nginx", wrapper_text)

    def test_services_proxy_rejects_cron_path_injection(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
            ORACLE_SERVICES_ACME_HOME="/tmp/acme;touch/tmp/pwned",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe proxy path", result.stderr)
        self.assertNotIn("touch/tmp/pwned", result.stdout)

    def test_services_deploy_dry_run_with_domain_rejects_proxy_path_injection(self):
        result = self.run_script(
            SERVICES,
            "deploy",
            "wordpress",
            "blog.example.com",
            ORACLE_SERVICES_DRY_RUN="1",
            ORACLE_SERVICES_ACME_HOME="/tmp/acme;touch/tmp/pwned",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe proxy path", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_services_deploy_with_domain_validates_proxy_paths_before_writing_state(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            services_home = Path(temp_dir) / "services"
            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                "blog.example.com",
                ORACLE_SERVICES_HOME=str(services_home),
                ORACLE_SERVICES_ACME_HOME="/tmp/acme;touch/tmp/pwned",
            )
            service_dir_exists = (services_home / "wordpress").exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe proxy path", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(service_dir_exists)

    def test_services_proxy_rejects_world_writable_acme_sh_for_root_execution(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            acme_home = root / "acme"
            acme_sh = acme_home / "acme.sh"
            marker = root / "executed"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            acme_home.mkdir()
            (bin_dir / "id").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            self.write_fake_root_stat(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                f"touch {marker}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "id", bin_dir / "nginx", acme_sh]:
                script.chmod(0o755)
            acme_sh.chmod(0o777)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe acme.sh permissions", result.stderr)
        self.assertFalse(marker_exists, "unsafe acme.sh must not be executed")

    def test_services_proxy_rejects_world_writable_acme_home_for_root_execution(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            acme_home = root / "acme"
            acme_bin = root / "acme-bin"
            acme_sh = acme_bin / "acme.sh"
            marker = root / "executed"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            acme_home.mkdir()
            acme_bin.mkdir()
            (acme_home / ".unsafe-mode").write_text("1\n", encoding="utf-8")
            (bin_dir / "id").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            self.write_fake_root_stat(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                f"touch {marker}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "id", bin_dir / "nginx", acme_sh]:
                script.chmod(0o755)
            acme_home.chmod(0o777)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe acme.sh home", result.stderr)
        self.assertFalse(marker_exists, "unsafe acme home must not be used")

    def test_services_proxy_rejects_symlink_ancestor_in_acme_home_for_root_execution(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            unsafe_parent = root / "unsafe-parent"
            safe_target = root / "safe-target"
            symlink_parent = unsafe_parent / "link"
            acme_home = symlink_parent / "acme"
            acme_sh = acme_home / "acme.sh"
            marker = root / "executed"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            unsafe_parent.mkdir()
            safe_target.mkdir()
            (unsafe_parent / ".unsafe-mode").write_text("1\n", encoding="utf-8")
            unsafe_parent.chmod(0o777)
            symlink_parent.symlink_to(safe_target, target_is_directory=True)
            acme_home.mkdir()
            self.write_fake_proxy_commands(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                f"touch {marker}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            acme_sh.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe acme.sh parent directory", result.stderr)
        self.assertFalse(marker_exists, "acme home with symlink ancestor must not be used")

    def test_services_proxy_rejects_unsafe_canonical_acme_path_for_root_execution(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            link_parent = root / "safe-link"
            unsafe_target = root / "unsafe$(touch-pwned)"
            acme_home = link_parent / "acme"
            acme_sh = acme_home / "acme.sh"
            marker = root / "executed"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            unsafe_target.mkdir()
            link_parent.symlink_to(unsafe_target, target_is_directory=True)
            acme_home.mkdir()
            self.write_fake_proxy_commands(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                f"touch {marker}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            acme_sh.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe acme.sh path", result.stderr)
        self.assertFalse(marker_exists, "unsafe canonical acme path must not be executed")

    def test_services_proxy_uses_canonical_acme_paths_after_safe_symlink(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            safe_target = root / "safe-target"
            link_parent = root / "safe-link"
            acme_home = link_parent / "acme"
            acme_sh = acme_home / "acme.sh"
            acme_log = root / "acme.log"
            crontab_log = root / "crontab.log"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            safe_target.mkdir()
            link_parent.symlink_to(safe_target, target_is_directory=True)
            acme_home.mkdir()
            (bin_dir / "id").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "systemctl").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "crontab").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -l ]; then exit 0; fi\n"
                f"cat \"$1\" > {shlex.quote(str(crontab_log))}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            self.write_fake_root_stat(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$0 $*\" >> {shlex.quote(str(acme_log))}\n"
                "while [ $# -gt 0 ]; do\n"
                "  case \"$1\" in\n"
                "    --fullchain-file) fullchain=\"$2\"; shift 2 ;;\n"
                "    --key-file) key=\"$2\"; shift 2 ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                "[ -n \"${fullchain:-}\" ] && { mkdir -p \"$(dirname \"$fullchain\")\"; : > \"$fullchain\"; }\n"
                "[ -n \"${key:-}\" ] && { mkdir -p \"$(dirname \"$key\")\"; : > \"$key\"; }\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "id", bin_dir / "nginx", bin_dir / "systemctl", bin_dir / "crontab", acme_sh]:
                script.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                ORACLE_SERVICES_CERT_MODE="standalone",
            )
            canonical_home = str(acme_home.resolve())
            canonical_acme_sh = str(acme_sh.resolve())
            original_home = str(acme_home)
            original_acme_sh = str(acme_sh)
            acme_log_text = acme_log.read_text(encoding="utf-8")
            wrapper_text = (nginx_ssl_dir / "blog.example.com" / "renew-standalone.sh").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for text in [acme_log_text, wrapper_text]:
            self.assertIn(canonical_home, text)
            self.assertIn(canonical_acme_sh, text)
            self.assertNotIn(original_home, text)
            self.assertNotIn(original_acme_sh, text)

    def test_services_proxy_uses_canonical_acme_paths_in_cloudflare_renew_cron(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            safe_target = root / "safe-target"
            link_parent = root / "safe-link"
            acme_home = link_parent / "acme"
            acme_sh = acme_home / "acme.sh"
            acme_log = root / "acme.log"
            crontab_log = root / "crontab.log"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            safe_target.mkdir()
            link_parent.symlink_to(safe_target, target_is_directory=True)
            acme_home.mkdir()
            (bin_dir / "id").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "systemctl").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "crontab").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -l ]; then exit 0; fi\n"
                f"cat \"$1\" > {shlex.quote(str(crontab_log))}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            self.write_fake_root_stat(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$0 $*\" >> {shlex.quote(str(acme_log))}\n"
                "while [ $# -gt 0 ]; do\n"
                "  case \"$1\" in\n"
                "    --fullchain-file) fullchain=\"$2\"; shift 2 ;;\n"
                "    --key-file) key=\"$2\"; shift 2 ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                "[ -n \"${fullchain:-}\" ] && { mkdir -p \"$(dirname \"$fullchain\")\"; : > \"$fullchain\"; }\n"
                "[ -n \"${key:-}\" ] && { mkdir -p \"$(dirname \"$key\")\"; : > \"$key\"; }\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "id", bin_dir / "nginx", bin_dir / "systemctl", bin_dir / "crontab", acme_sh]:
                script.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            canonical_home = str(acme_home.resolve())
            canonical_acme_sh = str(acme_sh.resolve())
            original_home = str(acme_home)
            original_acme_sh = str(acme_sh)
            acme_log_text = acme_log.read_text(encoding="utf-8")
            crontab_text = crontab_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for text in [acme_log_text, crontab_text]:
            self.assertIn(canonical_home, text)
            self.assertIn(canonical_acme_sh, text)
            self.assertNotIn(original_home, text)
            self.assertNotIn(original_acme_sh, text)

    def test_services_proxy_rejects_unsafe_acme_sh_for_root_execution(self):
        self.skip_if_running_as_root()
        cases = [
            ("non-root-owned", "1000", 0o755, False, "Unsafe acme.sh owner"),
            ("group-writable", "0", 0o775, False, "Unsafe acme.sh permissions"),
            ("symlink", "0", 0o755, True, "Unsafe acme.sh path"),
            ("non-executable", "0", 0o644, False, "Unsafe acme.sh path"),
        ]
        for name, owner_uid, mode, use_symlink, expected_error in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                bin_dir = root / "bin"
                nginx_conf_dir = root / "nginx"
                nginx_ssl_dir = root / "ssl"
                acme_home = root / "acme"
                acme_bin = root / "acme-bin"
                acme_sh = acme_bin / "acme.sh"
                target = acme_bin / "target-acme.sh"
                marker = root / "executed"
                bin_dir.mkdir()
                nginx_conf_dir.mkdir()
                nginx_ssl_dir.mkdir()
                acme_home.mkdir()
                acme_bin.mkdir()
                (bin_dir / "id").write_text(
                    "#!/bin/sh\n"
                    "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                    "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                    encoding="utf-8",
                )
                (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                self.write_fake_root_stat(bin_dir, owner_uid=owner_uid)
                target.write_text(
                    "#!/bin/sh\n"
                    f"touch {marker}\n"
                    "exit 0\n",
                    encoding="utf-8",
                )
                target.chmod(0o755)
                if use_symlink:
                    acme_sh.symlink_to(target)
                else:
                    acme_sh.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
                    acme_sh.chmod(mode)
                for script in [bin_dir / "id", bin_dir / "nginx"]:
                    script.chmod(0o755)

                result = self.run_script(
                    SERVICES,
                    "proxy",
                    "wordpress",
                    "blog.example.com",
                    PATH=f"{bin_dir}:{os.environ['PATH']}",
                    ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                    ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                    ORACLE_SERVICES_ACME_HOME=str(acme_home),
                    ORACLE_SERVICES_ACME_SH=str(acme_sh),
                    CF_Token="token-value",
                    CF_Zone_ID="zone-value",
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(marker.exists(), "unsafe acme.sh must not be executed")

    def test_services_proxy_standalone_first_issue_failure_restores_nginx(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            acme_home = root / "acme"
            acme_sh = acme_home / "acme.sh"
            systemctl_log = root / "systemctl.log"
            bin_dir.mkdir()
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            acme_home.mkdir()
            self.write_fake_proxy_commands(
                bin_dir,
                systemctl_body=f"printf '%s\\n' \"$*\" >> {shlex.quote(str(systemctl_log))}\nexit 0\n",
            )
            acme_sh.write_text(
                "#!/bin/sh\n"
                "case \" $* \" in\n"
                "  *\" --set-default-ca \"*) exit 0 ;;\n"
                "  *\" --issue \"*) exit 42 ;;\n"
                "esac\n"
                "exit 0\n",
                encoding="utf-8",
            )
            acme_sh.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                ORACLE_SERVICES_CERT_MODE="standalone",
            )
            systemctl_text = systemctl_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn("stop nginx", systemctl_text)
        self.assertIn("start nginx", systemctl_text)
        self.assertNotIn("Configured HTTPS proxy", result.stdout)

    def test_services_proxy_updates_existing_halo_external_url(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            service_dir = root / "services" / "halo"
            nginx_conf_dir = root / "nginx"
            nginx_ssl_dir = root / "ssl"
            acme_home = root / "acme"
            acme_sh = acme_home / "acme.sh"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            nginx_conf_dir.mkdir()
            nginx_ssl_dir.mkdir()
            acme_home.mkdir()
            compose_file = service_dir / "docker-compose.yml"
            compose_file.write_text(
                "services:\n"
                "  halo:\n"
                "    environment:\n"
                "      HALO_EXTERNAL_URL: http://localhost:8082/\n",
                encoding="utf-8",
            )
            (bin_dir / "id").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -u ]; then echo 0; exit 0; fi\n"
                "echo 'unexpected id args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "systemctl").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (bin_dir / "crontab").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -l ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            (bin_dir / "docker").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            self.write_fake_root_stat(bin_dir)
            acme_sh.write_text(
                "#!/bin/sh\n"
                "while [ $# -gt 0 ]; do\n"
                "  case \"$1\" in\n"
                "    --fullchain-file) fullchain=\"$2\"; shift 2 ;;\n"
                "    --key-file) key=\"$2\"; shift 2 ;;\n"
                "    *) shift ;;\n"
                "  esac\n"
                "done\n"
                "[ -n \"${fullchain:-}\" ] && { mkdir -p \"$(dirname \"$fullchain\")\"; : > \"$fullchain\"; }\n"
                "[ -n \"${key:-}\" ] && { mkdir -p \"$(dirname \"$key\")\"; : > \"$key\"; }\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "id", bin_dir / "nginx", bin_dir / "systemctl", bin_dir / "crontab", bin_dir / "docker", acme_sh]:
                script.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "proxy",
                "halo",
                "halo.example.com",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_SERVICES_HOME=str(root / "services"),
                ORACLE_SERVICES_NGINX_CONF_DIR=str(nginx_conf_dir),
                ORACLE_SERVICES_NGINX_SSL_DIR=str(nginx_ssl_dir),
                ORACLE_SERVICES_ACME_HOME=str(acme_home),
                ORACLE_SERVICES_ACME_SH=str(acme_sh),
                CF_Token="sensitive-token-value",
                CF_Zone_ID="zone-id-value",
            )
            compose_text = compose_file.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("HALO_EXTERNAL_URL: https://halo.example.com/", compose_text)
        self.assertNotIn("sensitive-token-value", result.stdout + result.stderr + compose_text)

    def test_services_proxy_does_not_persist_cloudflare_token_in_project_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                "blog.example.com",
                ORACLE_SERVICES_DRY_RUN="1",
                ORACLE_SERVICES_HOME=temp_dir,
                CF_Token="sensitive-token-value",
                CF_Zone_ID="zone-id-value",
            )
            file_text = ""
            for path in Path(temp_dir).rglob("*"):
                if path.is_file():
                    file_text += path.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("sensitive-token-value", file_text)
        self.assertNotIn("sensitive-token-value", result.stdout + result.stderr)

    def test_services_dry_run_rejects_unknown_service(self):
        result = self.run_script(SERVICES, "deploy", "unknown", ORACLE_SERVICES_DRY_RUN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown service", result.stderr)

    def test_services_dry_run_rejects_path_traversal_service(self):
        result = self.run_script(SERVICES, "deploy", "../../etc", ORACLE_SERVICES_DRY_RUN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown service", result.stderr)

    def test_services_reuses_existing_env_password_in_dry_run(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            service_dir = Path(temp_dir) / "wordpress"
            service_dir.mkdir()
            (service_dir / ".env").write_text("ORACLE_SERVICE_PASSWORD=stable-secret\n", encoding="utf-8")

            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                ORACLE_SERVICES_DRY_RUN="1",
                ORACLE_SERVICES_HOME=temp_dir,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WORDPRESS_DB_PASSWORD: <redacted-existing-password>", result.stdout)
        self.assertNotIn("stable-secret", result.stdout)

    def test_services_fake_compose_failure_propagates(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            bin_dir.mkdir()
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ]; then exit 42; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SERVICES), "deploy", "hugo"],
                cwd=ROOT,
                env=self.script_env(
                    PATH=f"{bin_dir}:{os.environ['PATH']}",
                    ORACLE_SERVICES_HOME=str(home_dir),
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )

        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertNotIn("Deployed hugo", result.stdout)

    def test_keepalive_run_cleans_nested_memory_worker_on_term(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            lock_dir = root / "lock"
            memory_marker = root / "memory-worker.pids"
            bin_dir.mkdir()
            (bin_dir / "awk").write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  *MemTotal*) echo 1048576; exit 0 ;;\n"
                "  *MemAvailable*) echo 1048575; exit 0 ;;\n"
                "esac\n"
                "echo 'unexpected awk args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "python3").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = - ] && [ \"$2\" = 1 ]; then\n"
                f"  marker={shlex.quote(str(memory_marker))}\n"
                "  child_pid=\n"
                "  cleanup() {\n"
                "    [ -n \"$child_pid\" ] && kill \"$child_pid\" 2>/dev/null || true\n"
                "    [ -n \"$child_pid\" ] && wait \"$child_pid\" 2>/dev/null || true\n"
                "    exit 0\n"
                "  }\n"
                "  trap cleanup INT TERM\n"
                "  while :; do\n"
                "    sleep 100 &\n"
                "    child_pid=$!\n"
                "    tmp_marker=\"$marker.tmp.$$\"\n"
                "    printf '%s\\n%s\\n' \"$$\" \"$child_pid\" > \"$tmp_marker\"\n"
                "    mv \"$tmp_marker\" \"$marker\"\n"
                "    wait \"$child_pid\"\n"
                "  done\n"
                "fi\n"
                "echo 'unexpected python3 args' >&2\n"
                "exit 127\n",
                encoding="utf-8",
            )
            (bin_dir / "awk").chmod(0o755)
            (bin_dir / "python3").chmod(0o755)
            env = self.script_env(
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                ORACLE_KEEPALIVE_LOCK_DIR=str(lock_dir),
                KEEPALIVE_CPU_ENABLED="0",
                KEEPALIVE_MEMORY_ENABLED="1",
                KEEPALIVE_MEMORY_TARGET_PERCENT="80",
                KEEPALIVE_MEMORY_MAX_MB="1",
                KEEPALIVE_MEMORY_HOLD_SECONDS="30",
                KEEPALIVE_MEMORY_REST_SECONDS="1",
                KEEPALIVE_NETWORK_ENABLED="0",
            )
            proc = subprocess.Popen(
                ["bash", str(KEEPALIVE), "run"],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            stdout = ""
            stderr = ""
            memory_pids: set[int] = set()
            try:
                deadline = time.time() + 5
                while time.time() < deadline and not (lock_dir / "pid").exists() and proc.poll() is None:
                    time.sleep(0.05)
                self.assertTrue((lock_dir / "pid").exists(), "keepalive daemon did not create its lock file")

                deadline = time.time() + 5
                while time.time() < deadline and len(memory_pids) < 2 and proc.poll() is None:
                    if memory_marker.exists():
                        try:
                            memory_pids = {
                                int(line)
                                for line in memory_marker.read_text(encoding="utf-8").splitlines()
                                if line.strip()
                            }
                        except ValueError:
                            memory_pids = set()
                    time.sleep(0.05)
                self.assertGreaterEqual(len(memory_pids), 2, "keepalive daemon did not start the nested memory worker")
                descendants = self.process_descendants(proc.pid)
                for child_pid in memory_pids:
                    self.assertIn(child_pid, descendants)

                proc.terminate()
                stdout, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self.terminate_process_group(proc, signal.SIGKILL)
                stdout, stderr = proc.communicate(timeout=5)
            finally:
                if proc.poll() is None:
                    self.terminate_process_group(proc, signal.SIGKILL)
                    stdout, stderr = proc.communicate(timeout=5)

        self.assertEqual(proc.returncode, 0, stdout + stderr)
        leaked_memory_pids = {pid for pid in memory_pids if self.process_exists(pid)}
        if leaked_memory_pids:
            self.terminate_process_group(proc, signal.SIGKILL)
            time.sleep(0.2)
        self.assertFalse(leaked_memory_pids, f"memory worker leaked: {sorted(leaked_memory_pids)}")

    def test_keepalive_cleanup_preserves_unexpected_lock_dir_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            lock_dir = Path(temp_dir) / "lock"
            lock_dir.mkdir()
            (lock_dir / "pid").write_text("999999\n", encoding="utf-8")
            sentinel = lock_dir / "sentinel.txt"
            sentinel.write_text("keep me\n", encoding="utf-8")

            result = self.run_script_in_new_session(
                KEEPALIVE,
                "run",
                timeout=2,
                ORACLE_KEEPALIVE_LOCK_DIR=str(lock_dir),
                KEEPALIVE_NETWORK_ENABLED="0",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing recursive removal", result.stdout)
            self.assertTrue(sentinel.exists(), "cleanup must not recursively delete arbitrary lock directory contents")
            self.assertFalse((lock_dir / "pid").exists())

    def test_keepalive_rejects_symlink_lock_dir(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            victim_dir = root / "victim"
            lock_link = root / "lock-link"
            victim_dir.mkdir()
            sentinel = victim_dir / "sentinel.txt"
            sentinel.write_text("keep me\n", encoding="utf-8")
            lock_link.symlink_to(victim_dir, target_is_directory=True)

            result = self.run_script_in_new_session(
                KEEPALIVE,
                "run",
                timeout=2,
                ORACLE_KEEPALIVE_LOCK_DIR=str(lock_link),
                KEEPALIVE_NETWORK_ENABLED="0",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(sentinel.exists())
            self.assertFalse((victim_dir / "pid").exists(), "lock symlink must not be followed to create pid")

    def test_keepalive_rejects_symlink_pid_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            lock_dir = root / "lock"
            victim_file = root / "victim-pid"
            lock_dir.mkdir()
            victim_file.write_text("keep me\n", encoding="utf-8")
            (lock_dir / "pid").symlink_to(victim_file)

            result = self.run_script_in_new_session(
                KEEPALIVE,
                "run",
                timeout=2,
                ORACLE_KEEPALIVE_LOCK_DIR=str(lock_dir),
                KEEPALIVE_NETWORK_ENABLED="0",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(victim_file.read_text(encoding="utf-8"), "keep me\n")

    def test_keepalive_check_rejects_network_url_option_injection(self):
        result = self.run_script(
            KEEPALIVE,
            "check",
            KEEPALIVE_CPU_ENABLED="0",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="1",
            KEEPALIVE_NETWORK_URLS="--config=/tmp/pwned",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe network URL", result.stderr)

    def test_keepalive_check_rejects_network_url_unsupported_scheme(self):
        for url in ["file:///etc/passwd", "ftp://example.com/file", "gopher://example.com/"]:
            with self.subTest(url=url):
                result = self.run_script(
                    KEEPALIVE,
                    "check",
                    KEEPALIVE_CPU_ENABLED="0",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="1",
                    KEEPALIVE_NETWORK_URLS=url,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsafe network URL", result.stderr)

    def test_keepalive_check_rejects_mixed_network_urls_when_one_is_unsafe(self):
        result = self.run_script(
            KEEPALIVE,
            "check",
            KEEPALIVE_CPU_ENABLED="0",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="1",
            KEEPALIVE_NETWORK_URLS="https://example.com file:///etc/passwd",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe network URL", result.stderr)

    def test_services_existing_env_without_password_gets_password_persisted(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            env_file = service_dir / ".env"
            env_file.write_text("ORACLE_SERVICE=wordpress\n", encoding="utf-8")
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SERVICES), "deploy", "wordpress"],
                cwd=ROOT,
                env=self.script_env(
                    PATH=f"{bin_dir}:{os.environ['PATH']}",
                    ORACLE_SERVICES_HOME=str(home_dir),
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
            env_text = env_file.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ORACLE_SERVICE_PASSWORD=", env_text)
