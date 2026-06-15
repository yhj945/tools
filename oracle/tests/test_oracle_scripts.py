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

ORACLE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ORACLE_ROOT.parent
ROOT = ORACLE_ROOT
KEEPALIVE = ORACLE_ROOT / "oracle_keepalive.sh"
KEEPALIVE_README = ORACLE_ROOT / "README_oracle_keepalive_zh.md"


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
        try:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_class)
        except PermissionError as exc:
            self.skipTest(f"local socket tests are disabled in this environment: {exc}")
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

    def keepalive_running_env(self, temp_dir: str, **env_overrides: str) -> dict[str, str]:
        lock_dir = Path(temp_dir) / "keepalive.lock"
        lock_dir.mkdir()
        (lock_dir / "pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
        env_overrides["ORACLE_KEEPALIVE_LOCK_DIR"] = str(lock_dir)
        return env_overrides

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
        self.assertIn("oracle_keepalive.sh 检查通过", result.stdout)

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
        result = self.run_script_with_input(KEEPALIVE, "8\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Oracle Always Free 保活工具", result.stdout)
        self.assertIn("oracle_keepalive.sh 检查通过", result.stdout)

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
        self.assertIn("oracle_keepalive.sh 检查通过", result.stdout)

    def test_keepalive_readme_documents_remote_run_examples(self):
        readme = KEEPALIVE_README.read_text(encoding="utf-8")
        self.assertIn("交互式菜单", readme)
        self.assertIn("bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh)", readme)
        self.assertIn("bash -s --", readme)
        self.assertNotIn("KEEPALIVE_SERVICE_", readme)

    def test_keepalive_dry_run_install_prints_unit_and_config(self):
        result = self.run_script(KEEPALIVE, "install", ORACLE_KEEPALIVE_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DRY-RUN] 将写入配置", result.stdout)
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
            KEEPALIVE_SERVICE_SCRIPT="/opt/oracle_service.sh",
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
                self.assertIn("oracle_keepalive.sh 检查通过", result.stdout)

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
                self.assertIn("网络限速参数不安全", result.stderr)
                self.assertNotIn("oracle_keepalive.sh 检查通过", result.stdout)
                self.assertNotIn("INJECTED=1", result.stdout + result.stderr)

    def test_keepalive_install_dry_run_rejects_network_rate_limit_environmentfile_injection(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            KEEPALIVE_NETWORK_RATE_LIMIT="512k\nINJECTED=1",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("网络限速参数不安全", result.stderr)
        self.assertNotIn("INJECTED=1", result.stdout + result.stderr)
        self.assertNotIn("[DRY-RUN] 将写入配置", result.stdout)

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
                self.assertIn("网络 URL 不安全", result.stderr)
                self.assertNotIn("INJECTED=1", result.stdout + result.stderr)
                self.assertNotIn("[DRY-RUN] 将写入配置", result.stdout)

    def test_keepalive_install_rejects_systemd_environmentfile_glob_path(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            ORACLE_KEEPALIVE_CONFIG="/tmp/app-keepalive-*.conf",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("路径不安全", result.stderr)
        self.assertNotIn("EnvironmentFile=-/tmp/app-keepalive-*.conf", result.stdout)

    def test_keepalive_install_rejects_systemd_percent_specifier_path(self):
        result = self.run_script(
            KEEPALIVE,
            "install",
            ORACLE_KEEPALIVE_DRY_RUN="1",
            ORACLE_KEEPALIVE_CONFIG="/tmp/%n.conf",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("路径不安全", result.stderr)
        self.assertNotIn("EnvironmentFile=-/tmp/%n.conf", result.stdout)

    def test_keepalive_check_loads_config_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "app-keepalive.conf"
            config_file.write_text(
                "KEEPALIVE_CPU_ENABLED=0\n"
                "KEEPALIVE_MEMORY_ENABLED=0\n"
                "KEEPALIVE_NETWORK_ENABLED=0\n",
                encoding="utf-8",
            )
            result = self.run_script(KEEPALIVE, "check", ORACLE_KEEPALIVE_CONFIG=str(config_file))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("至少需要启用一种保活方式", result.stderr)

    def test_keepalive_config_parser_does_not_execute_shell(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_file = Path(temp_dir) / "app-keepalive.conf"
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
        self.assertIn("路径不安全", result.stderr)

    def test_keepalive_verify_cpu_samples_without_env_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                **self.keepalive_running_env(
                    temp_dir,
                    KEEPALIVE_CPU_ENABLED="1",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="0",
                    KEEPALIVE_CPU_TARGET_PERCENT="80",
                    KEEPALIVE_VERIFY_CPU_SAMPLE_SECONDS="1",
                ),
            )
        self.assertIn("CPU：", result.stdout)
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
        self.assertIn("至少需要启用一种保活方式", result.stderr)
        self.assertNotIn("oracle_keepalive.sh 检查通过", result.stdout)

    def test_keepalive_check_accepts_single_enabled_method(self):
        result = self.run_script(
            KEEPALIVE,
            "check",
            KEEPALIVE_CPU_ENABLED="1",
            KEEPALIVE_MEMORY_ENABLED="0",
            KEEPALIVE_NETWORK_ENABLED="0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("oracle_keepalive.sh 检查通过", result.stdout)

    def test_keepalive_verify_reports_cpu_target_met_from_env_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                **self.keepalive_running_env(
                    temp_dir,
                    KEEPALIVE_CPU_ENABLED="1",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="0",
                    KEEPALIVE_CPU_TARGET_PERCENT="20",
                    KEEPALIVE_VERIFY_CPU_PERCENT="25",
                ),
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CPU：通过", result.stdout)

    def test_keepalive_verify_fails_when_enabled_cpu_below_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                **self.keepalive_running_env(
                    temp_dir,
                    KEEPALIVE_CPU_ENABLED="1",
                    KEEPALIVE_MEMORY_ENABLED="0",
                    KEEPALIVE_NETWORK_ENABLED="0",
                    KEEPALIVE_CPU_TARGET_PERCENT="20",
                    KEEPALIVE_VERIFY_CPU_PERCENT="10",
                ),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CPU：失败", result.stdout)

    def test_keepalive_verify_reports_memory_target_met_from_env_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script(
                KEEPALIVE,
                "verify",
                **self.keepalive_running_env(
                    temp_dir,
                    KEEPALIVE_CPU_ENABLED="0",
                    KEEPALIVE_MEMORY_ENABLED="1",
                    KEEPALIVE_NETWORK_ENABLED="0",
                    KEEPALIVE_MEMORY_TARGET_PERCENT="20",
                    KEEPALIVE_VERIFY_MEMORY_PERCENT="25",
                ),
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("内存：通过", result.stdout)

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
            with tempfile.TemporaryDirectory() as temp_dir:
                result = self.run_script(
                    KEEPALIVE,
                    "verify",
                    **self.keepalive_running_env(
                        temp_dir,
                        KEEPALIVE_CPU_ENABLED="0",
                        KEEPALIVE_MEMORY_ENABLED="0",
                        KEEPALIVE_NETWORK_ENABLED="1",
                        KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                        KEEPALIVE_NETWORK_URLS=url,
                    ),
                )
        finally:
            self.stop_http_server(server, thread)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.requests, 1)
        self.assertIn("CPU：跳过", result.stdout)
        self.assertIn("内存：跳过", result.stdout)
        self.assertIn("网络：通过", result.stdout)

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
                    **self.keepalive_running_env(
                        temp_dir,
                        KEEPALIVE_CPU_ENABLED="0",
                        KEEPALIVE_MEMORY_ENABLED="0",
                        KEEPALIVE_NETWORK_ENABLED="1",
                        KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                        KEEPALIVE_NETWORK_URLS=f"{url} https://127.0.0.1:9/unreachable",
                        PATH=f"{bin_dir}:{os.environ['PATH']}",
                    ),
                )
            finally:
                self.stop_http_server(server, thread)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Handler.requests, 1)
        self.assertIn("网络：通过", result.stdout)

    def test_keepalive_ignores_removed_app_service_strategy(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = Path(temp_dir) / "called"
            service_script = Path(temp_dir) / "removed_service_strategy.sh"
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
        self.assertIn("至少需要启用一种保活方式", result.stderr)

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
            with tempfile.TemporaryDirectory() as temp_dir:
                result = self.run_script(
                    KEEPALIVE,
                    "verify",
                    timeout=5,
                    **self.keepalive_running_env(
                        temp_dir,
                        KEEPALIVE_CPU_ENABLED="0",
                        KEEPALIVE_MEMORY_ENABLED="0",
                        KEEPALIVE_NETWORK_ENABLED="1",
                        KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                        KEEPALIVE_NETWORK_RATE_LIMIT="512k",
                        KEEPALIVE_NETWORK_URLS=url,
                    ),
                )
        finally:
            self.stop_http_server(server, thread)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater(Handler.sent_bytes, 0)
        self.assertIn("网络：通过", result.stdout)
        self.assertNotIn("网络：失败", result.stdout)

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
            with tempfile.TemporaryDirectory() as temp_dir:
                result = self.run_script(
                    KEEPALIVE,
                    "verify",
                    timeout=5,
                    **self.keepalive_running_env(
                        temp_dir,
                        KEEPALIVE_CPU_ENABLED="0",
                        KEEPALIVE_MEMORY_ENABLED="0",
                        KEEPALIVE_NETWORK_ENABLED="1",
                        KEEPALIVE_NETWORK_DURATION_SECONDS="1",
                        KEEPALIVE_NETWORK_RATE_LIMIT="512k",
                        KEEPALIVE_NETWORK_URLS=url,
                    ),
                )
        finally:
            self.stop_http_server(server, thread)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(Handler.requests, 1)
        self.assertIn("网络：失败", result.stdout)


class OracleReviewRegressionTests(ScriptTestCase):
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
            self.assertIn("拒绝递归删除", result.stdout)
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
        self.assertIn("网络 URL 不安全", result.stderr)

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
                self.assertIn("网络 URL 不安全", result.stderr)

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
        self.assertIn("网络 URL 不安全", result.stderr)
