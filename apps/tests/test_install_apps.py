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

APP_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = APP_ROOT.parent
ROOT = REPO_ROOT
SERVICES = APP_ROOT / "install_apps.sh"
SERVICES_README = APP_ROOT / "README_install_apps_zh.md"


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


class InstallAppsTests(ScriptTestCase):
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
        for name in ["hugo", "wordpress", "halo", "typecho", "komari", "3x-ui"]:
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
        for name in ["hugo", "wordpress", "halo", "typecho", "komari", "3x-ui"]:
            self.assertIn(name, result.stdout)

    def test_services_readme_documents_remote_run_examples(self):
        readme = SERVICES_README.read_text(encoding="utf-8")
        self.assertIn("install_apps.sh", readme)
        self.assertIn("交互式菜单", readme)
        self.assertIn("bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh)", readme)
        self.assertIn("bash -s --", readme)

    def test_services_readme_documents_domain_nginx_certificate_usage(self):
        readme = SERVICES_README.read_text(encoding="utf-8")
        for expected in [
            "proxy <service> <domain>",
            "deploy <service> [domain]",
            "Nginx",
            "acme.sh",
            "Cloudflare DNS-01",
            "Let's Encrypt standalone",
            "APPS_CERT_MODE=standalone",
            "CF_Token",
            "CF_Zone_ID",
            "/etc/nginx/ssl/<domain>/fullchain.cer",
            "crontab",
        ]:
            self.assertIn(expected, readme)
        self.assertNotIn("把 CF_Token 写入", readme)

    def test_services_dry_run_generates_wordpress_compose(self):
        result = self.run_script(SERVICES, "deploy", "wordpress", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wordpress:", result.stdout)
        self.assertIn("mariadb:", result.stdout)
        self.assertIn("WORDPRESS_DB_PASSWORD", result.stdout)

    def test_services_dry_run_generates_halo_compose(self):
        result = self.run_script(SERVICES, "deploy", "halo", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("halo:", result.stdout)
        self.assertIn("postgres:", result.stdout)
        self.assertIn("SPRING_R2DBC_PASSWORD", result.stdout)

    def test_services_dry_run_generates_typecho_compose(self):
        result = self.run_script(SERVICES, "deploy", "typecho", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("typecho:", result.stdout)
        self.assertIn("mariadb:", result.stdout)
        self.assertIn("TYPECHO_DB_PASSWORD", result.stdout)

    def test_services_dry_run_generates_hugo_compose(self):
        result = self.run_script(SERVICES, "deploy", "hugo", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nginx:", result.stdout)
        self.assertIn("hugo-site", result.stdout)

    def test_services_dry_run_generates_komari_compose(self):
        result = self.run_script(SERVICES, "deploy", "komari", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ghcr.io/komari-monitor/komari:latest", result.stdout)
        self.assertIn("ADMIN_USERNAME: admin", result.stdout)
        self.assertIn("ADMIN_PASSWORD:", result.stdout)
        self.assertIn("./data:/app/data", result.stdout)

    def test_services_dry_run_generates_3x_ui_compose(self):
        result = self.run_script(SERVICES, "deploy", "3x-ui", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ghcr.io/mhsanaei/3x-ui:latest", result.stdout)
        self.assertIn('"127.0.0.1:2053:2053"', result.stdout)
        self.assertIn('XUI_PORT: "2053"', result.stdout)
        self.assertIn('XUI_INIT_WEB_BASE_PATH: "/"', result.stdout)
        self.assertIn("NET_ADMIN", result.stdout)
        self.assertIn("./db:/etc/x-ui", result.stdout)
        self.assertIn("./cert:/root/cert", result.stdout)

    def test_services_dry_run_binds_http_ports_to_loopback(self):
        cases = {
            "hugo": "127.0.0.1:8080:80",
            "wordpress": "127.0.0.1:8081:80",
            "halo": "127.0.0.1:8082:8090",
            "typecho": "127.0.0.1:8083:80",
            "komari": "127.0.0.1:25774:25774",
        }
        for service, mapping in cases.items():
            with self.subTest(service=service):
                result = self.run_script(SERVICES, "deploy", service, APPS_DRY_RUN="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'"{mapping}"', result.stdout)

    def test_services_dry_run_3x_ui_uses_custom_port_and_web_base_path(self):
        result = self.run_script(
            SERVICES,
            "deploy",
            "3x-ui",
            APPS_DRY_RUN="1",
            APPS_PORT="12053",
            APPS_WEB_BASE_PATH="/panel",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"127.0.0.1:12053:12053"', result.stdout)
        self.assertIn('XUI_PORT: "12053"', result.stdout)
        self.assertIn('XUI_INIT_WEB_BASE_PATH: "/panel"', result.stdout)

    def test_services_dry_run_halo_domain_sets_external_url(self):
        result = self.run_script(SERVICES, "deploy", "halo", "halo.example.com", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HALO_EXTERNAL_URL: https://halo.example.com/", result.stdout)
        self.assertNotIn("HALO_EXTERNAL_URL: http://localhost:8082/", result.stdout)

    def test_services_help_lists_verify_command(self):
        result = self.run_script(SERVICES, "help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verify <服务>", result.stdout)
        self.assertIn("update <服务>", result.stdout)
        self.assertIn("backup <服务|all>", result.stdout)
        self.assertIn("backup-cron <服务|all>", result.stdout)

    def test_services_help_lists_proxy_domain_usage(self):
        result = self.run_script(SERVICES, "help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deploy <服务> [域名]", result.stdout)
        self.assertIn("proxy <服务> <域名>", result.stdout)

    def test_services_menu_can_proxy_with_standalone_certificate_mode_without_args(self):
        result = self.run_script_with_input(
            SERVICES,
            "5\n2\nblog.example.com\n2\n0\n",
            APPS_DRY_RUN="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("应用安装工具", result.stdout)
        self.assertIn("证书模式", result.stdout)
        self.assertIn("--standalone -d blog.example.com", result.stdout)
        self.assertNotIn("--dns dns_cf", result.stdout)

    def test_services_menu_can_select_custom_deploy_directory(self):
        result = self.run_script_with_input(
            SERVICES,
            "3\n/tmp/my-apps\n1\n\n\n\n0\n",
            APPS_DRY_RUN="1",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("部署目录：/tmp/my-apps", result.stdout)
        self.assertIn("[DRY-RUN] 将在 /tmp/my-apps/hugo 部署 hugo", result.stdout)

    def test_services_menu_can_select_custom_port_domain_and_komari_credentials(self):
        result = self.run_script_with_input(
            SERVICES,
            "3\n/tmp/my-apps\n5\n12577\nmonitor.example.com\nops\nsecret\n1\n\n0\n",
            APPS_DRY_RUN="1",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"127.0.0.1:12577:25774"', result.stdout)
        self.assertIn("ADMIN_USERNAME: ops", result.stdout)
        self.assertIn("ADMIN_PASSWORD: secret", result.stdout)
        self.assertIn("server_name monitor.example.com;", result.stdout)
        self.assertIn("server 127.0.0.1:12577;", result.stdout)

    def test_services_menu_can_configure_backup_cron(self):
        result = self.run_script_with_input(
            SERVICES,
            "6\n/tmp/my-apps\n1\n\n30\n1,3,5\n03:00\nbackup@example.com:/srv/apps\nonedrive:apps-backups\n\n0\n",
            APPS_DRY_RUN="1",
            APPS_BACKUP_SCRIPT="/opt/install_apps.sh",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("配置自动备份：all", result.stdout)
        self.assertIn("[DRY-RUN] 将写入 crontab", result.stdout)
        self.assertIn('APPS_HOME="/tmp/my-apps"', result.stdout)
        self.assertIn('APPS_BACKUP_KEEP_DAYS="30"', result.stdout)
        self.assertIn('APPS_BACKUP_REMOTE="backup@example.com:/srv/apps"', result.stdout)
        self.assertIn('APPS_BACKUP_RCLONE_REMOTE="onedrive:apps-backups"', result.stdout)
        self.assertIn('0 3 * * 1,3,5 APPS_HOME="/tmp/my-apps"', result.stdout)

    def test_services_dry_run_deploy_with_domain_generates_nginx_reverse_proxy(self):
        result = self.run_script(SERVICES, "deploy", "wordpress", "blog.example.com", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wordpress:", result.stdout)
        self.assertIn("mariadb:", result.stdout)
        self.assertIn("WORDPRESS_DB_PASSWORD", result.stdout)
        upstream = next(line.split()[1] for line in result.stdout.splitlines() if line.startswith("upstream app_wordpress_"))
        self.assertTrue(upstream.startswith("app_wordpress_blog_example_com_"))
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
        first = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", APPS_DRY_RUN="1")
        second = self.run_script(SERVICES, "proxy", "wordpress", "www.example.com", APPS_DRY_RUN="1")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        first_upstream = next(line.split()[1] for line in first.stdout.splitlines() if line.startswith("upstream app_wordpress_"))
        second_upstream = next(line.split()[1] for line in second.stdout.splitlines() if line.startswith("upstream app_wordpress_"))
        self.assertTrue(first_upstream.startswith("app_wordpress_blog_example_com_"))
        self.assertTrue(second_upstream.startswith("app_wordpress_www_example_com_"))
        self.assertNotEqual(first_upstream, second_upstream)
        self.assertIn(f"map $http_upgrade ${first_upstream}_connection_upgrade", first.stdout)
        self.assertIn(f"proxy_pass http://{first_upstream};", first.stdout)
        self.assertIn(f"proxy_set_header Connection ${first_upstream}_connection_upgrade;", first.stdout)
        self.assertIn(f"map $http_upgrade ${second_upstream}_connection_upgrade", second.stdout)
        self.assertIn(f"proxy_pass http://{second_upstream};", second.stdout)
        self.assertIn(f"proxy_set_header Connection ${second_upstream}_connection_upgrade;", second.stdout)
        self.assertNotIn("upstream app_wordpress_backend", first.stdout + second.stdout)

    def test_services_dry_run_proxy_avoids_sanitized_domain_name_collisions(self):
        first = self.run_script(SERVICES, "proxy", "wordpress", "a-b.example.com", APPS_DRY_RUN="1")
        second = self.run_script(SERVICES, "proxy", "wordpress", "a.b.example.com", APPS_DRY_RUN="1")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("upstream app_wordpress_a_b_example_com_", first.stdout)
        self.assertIn("upstream app_wordpress_a_b_example_com_", second.stdout)
        self.assertNotEqual(
            next(line for line in first.stdout.splitlines() if line.startswith("upstream app_wordpress_")),
            next(line for line in second.stdout.splitlines() if line.startswith("upstream app_wordpress_")),
        )

    def test_services_dry_run_proxy_uses_service_specific_backend_port(self):
        cases = {
            "hugo": "127.0.0.1:8080",
            "wordpress": "127.0.0.1:8081",
            "halo": "127.0.0.1:8082",
            "typecho": "127.0.0.1:8083",
            "komari": "127.0.0.1:25774",
            "3x-ui": "127.0.0.1:2053",
        }
        for service, backend in cases.items():
            with self.subTest(service=service):
                result = self.run_script(
                    SERVICES,
                    "proxy",
                    service,
                    f"{service}.example.com",
                    APPS_DRY_RUN="1",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"server_name {service}.example.com;", result.stdout)
                self.assertIn(f"server {backend};", result.stdout)

    def test_services_dry_run_proxy_uses_acme_cloudflare_dns01_letsencrypt(self):
        result = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", APPS_DRY_RUN="1")
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
            APPS_DRY_RUN="1",
            APPS_CERT_MODE="standalone",
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
            APPS_DRY_RUN="1",
            APPS_CERT_MODE="bad-mode",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知证书模式", result.stderr)
        self.assertNotIn("--issue", result.stdout)
        self.assertNotIn("server_name blog.example.com", result.stdout)

    def test_services_dry_run_proxy_installs_certificate_to_nginx_ssl_path(self):
        result = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", APPS_DRY_RUN="1")
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
            APPS_DRY_RUN="1",
            APPS_ACME_SH="/usr/local/bin/acme.sh",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"/usr/local/bin/acme.sh" --renew -d blog.example.com', result.stdout)

    def test_services_dry_run_proxy_adds_idempotent_acme_renew_cron(self):
        result = self.run_script(SERVICES, "proxy", "wordpress", "blog.example.com", APPS_DRY_RUN="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in [
            "crontab -l",
            "APPS_RENEW:blog.example.com:cloudflare",
            "grep -v 'APPS_RENEW:blog\\.example\\.com:'",
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
            APPS_DRY_RUN="1",
            APPS_CERT_MODE="standalone",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/etc/nginx/ssl/blog.example.com/renew-standalone.sh", result.stdout)
        self.assertIn("timeout 20m", result.stdout)
        self.assertNotIn("10 3 * * * systemctl stop nginx", result.stdout)
        self.assertNotIn("systemctl stop nginx >/dev/null 2>&1;", result.stdout)

    def test_services_verify_rejects_unknown_service(self):
        result = self.run_script(SERVICES, "verify", "unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知服务", result.stderr)

    def test_services_verify_reports_healthy_deployed_service(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            service_dir = Path(temp_dir) / "services" / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yaml").write_text("services: {}\n", encoding="utf-8")
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
                APPS_HOME=str(Path(temp_dir) / "services"),
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("wordpress", result.stdout)
        self.assertIn("验证通过", result.stdout)

    def test_services_verify_rejects_unhealthy_service(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            service_dir = Path(temp_dir) / "services" / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yaml").write_text("services: {}\n", encoding="utf-8")
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
                APPS_HOME=str(Path(temp_dir) / "services"),
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("服务不健康", result.stderr)
        self.assertNotIn("验证通过", result.stdout)


class InstallAppsSecurityRegressionTests(ScriptTestCase):
    def test_services_proxy_rejects_invalid_domain(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com\nserver_name attacker.example.com",
            APPS_DRY_RUN="1",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("域名无效", result.stderr)
        self.assertNotIn("server_name attacker.example.com", result.stdout)
        self.assertNotIn("acme.sh --issue", result.stdout)

    def test_services_proxy_requires_cloudflare_dns_credentials_without_echoing_values(self):
        result = self.run_script(
            SERVICES,
            "proxy",
            "wordpress",
            "blog.example.com",
            APPS_HOME="/tmp/apps-test",
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                APPS_CERT_MODE="standalone",
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
            APPS_DRY_RUN="1",
            APPS_ACME_HOME="/tmp/acme;touch/tmp/pwned",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("代理相关路径不安全", result.stderr)
        self.assertNotIn("touch/tmp/pwned", result.stdout)

    def test_services_deploy_dry_run_with_domain_rejects_proxy_path_injection(self):
        result = self.run_script(
            SERVICES,
            "deploy",
            "wordpress",
            "blog.example.com",
            APPS_DRY_RUN="1",
            APPS_ACME_HOME="/tmp/acme;touch/tmp/pwned",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("代理相关路径不安全", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_services_deploy_with_domain_validates_proxy_paths_before_writing_state(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            services_home = Path(temp_dir) / "services"
            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                "blog.example.com",
                APPS_HOME=str(services_home),
                APPS_ACME_HOME="/tmp/acme;touch/tmp/pwned",
            )
            service_dir_exists = (services_home / "wordpress").exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("代理相关路径不安全", result.stderr)
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("acme.sh 权限不安全", result.stderr)
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("acme.sh home 不安全", result.stderr)
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("acme.sh 父目录不安全", result.stderr)
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                CF_Token="token-value",
                CF_Zone_ID="zone-value",
            )
            marker_exists = marker.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("acme.sh 路径不安全", result.stderr)
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                APPS_CERT_MODE="standalone",
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
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
            ("non-root-owned", "1000", 0o755, False, "acme.sh 所有者不安全"),
            ("group-writable", "0", 0o775, False, "acme.sh 权限不安全"),
            ("symlink", "0", 0o755, True, "acme.sh 路径不安全"),
            ("non-executable", "0", 0o644, False, "acme.sh 路径不安全"),
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
                    APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                    APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                    APPS_ACME_HOME=str(acme_home),
                    APPS_ACME_SH=str(acme_sh),
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
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
                APPS_CERT_MODE="standalone",
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
            compose_file = service_dir / "docker-compose.yaml"
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
                APPS_HOME=str(root / "services"),
                APPS_NGINX_CONF_DIR=str(nginx_conf_dir),
                APPS_NGINX_SSL_DIR=str(nginx_ssl_dir),
                APPS_ACME_HOME=str(acme_home),
                APPS_ACME_SH=str(acme_sh),
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
                APPS_DRY_RUN="1",
                APPS_HOME=temp_dir,
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
        result = self.run_script(SERVICES, "deploy", "unknown", APPS_DRY_RUN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知服务", result.stderr)

    def test_services_dry_run_rejects_path_traversal_service(self):
        result = self.run_script(SERVICES, "deploy", "../../etc", APPS_DRY_RUN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知服务", result.stderr)

    def test_services_reuses_existing_env_password_in_dry_run(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            service_dir = Path(temp_dir) / "wordpress"
            service_dir.mkdir()
            (service_dir / ".env").write_text("APP_PASSWORD=stable-secret\n", encoding="utf-8")

            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                APPS_DRY_RUN="1",
                APPS_HOME=temp_dir,
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
                    APPS_HOME=str(home_dir),
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )

        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertNotIn("Deployed hugo", result.stdout)

    def test_services_existing_env_without_password_gets_password_persisted(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            env_file = service_dir / ".env"
            env_file.write_text("APP_NAME=wordpress\n", encoding="utf-8")
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
                    APPS_HOME=str(home_dir),
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
            env_text = env_file.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("APP_PASSWORD=", env_text)
        self.assertIn("APP_INSTALLER_VERSION=", env_text)

    def test_services_hugo_does_not_persist_unused_password(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "hugo"
            bin_dir.mkdir()
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "deploy",
                "hugo",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APPS_HOME=str(home_dir),
                APPS_PASSWORD="unused-secret",
            )
            env_text = (service_dir / ".env").read_text(encoding="utf-8")
            compose_text = (service_dir / "docker-compose.yaml").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("APP_PASSWORD=\n", env_text)
        self.assertNotIn("unused-secret", env_text + compose_text)

    def test_services_reuses_legacy_oracle_service_password(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            env_file = service_dir / ".env"
            env_file.write_text("ORACLE_SERVICE_PASSWORD=legacy-secret\n", encoding="utf-8")
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APPS_HOME=str(home_dir),
            )
            env_text = env_file.read_text(encoding="utf-8")
            compose_text = (service_dir / "docker-compose.yaml").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("APP_PASSWORD=legacy-secret", env_text)
        self.assertIn("WORDPRESS_DB_PASSWORD: legacy-secret", compose_text)

    def test_services_redeploy_backs_up_existing_project_files(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / ".env").write_text("APP_PASSWORD=stable-secret\n", encoding="utf-8")
            (service_dir / "docker-compose.yaml").write_text("old-compose\n", encoding="utf-8")
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "deploy",
                "wordpress",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APPS_HOME=str(home_dir),
            )
            backup_envs = sorted((service_dir / ".backups").rglob(".env"))
            backup_composes = sorted((service_dir / ".backups").rglob("docker-compose.yaml"))
            backup_env_text = backup_envs[-1].read_text(encoding="utf-8") if backup_envs else ""
            backup_compose_text = backup_composes[-1].read_text(encoding="utf-8") if backup_composes else ""
            env_text = (service_dir / ".env").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(backup_envs)
        self.assertTrue(backup_composes)
        self.assertEqual(backup_env_text, "APP_PASSWORD=stable-secret\n")
        self.assertEqual(backup_compose_text, "old-compose\n")
        self.assertIn("APP_INSTALLER_VERSION=", env_text)
        self.assertIn("已备份现有配置", result.stdout)

    def test_services_update_pulls_images_and_recreates_containers(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            docker_log = Path(temp_dir) / "docker.log"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yaml").write_text("services: {}\n", encoding="utf-8")
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$*\" >> {shlex.quote(str(docker_log))}\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = pull ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ] && [ \"$3\" = -d ]; then exit 0; fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "update",
                "wordpress",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APPS_HOME=str(home_dir),
            )
            docker_text = docker_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("compose pull", docker_text)
        self.assertIn("compose up -d", docker_text)

    def test_services_backup_creates_local_archive(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yaml").write_text("services: {}\n", encoding="utf-8")
            (service_dir / ".env").write_text("APP_PASSWORD=stable-secret\n", encoding="utf-8")
            (service_dir / "data").mkdir()
            (service_dir / "data" / "content.txt").write_text("keep me\n", encoding="utf-8")
            (service_dir / ".backups").mkdir()
            (service_dir / ".backups" / "old.txt").write_text("skip me\n", encoding="utf-8")

            result = self.run_script(
                SERVICES,
                "backup",
                "wordpress",
                APPS_HOME=str(home_dir),
            )
            archives = sorted((home_dir / ".backups").glob("wordpress-*.tar.gz"))
            listing = subprocess.run(
                ["tar", "-tzf", str(archives[-1])],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(archives)
        self.assertEqual(listing.returncode, 0, listing.stderr)
        self.assertIn("wordpress/docker-compose.yaml", listing.stdout)
        self.assertIn("wordpress/data/content.txt", listing.stdout)
        self.assertNotIn("wordpress/.backups/old.txt", listing.stdout)

    def test_services_backup_syncs_to_vps_and_rclone_remote(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "hugo"
            sync_log = Path(temp_dir) / "sync.log"
            bin_dir.mkdir()
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yaml").write_text("services: {}\n", encoding="utf-8")
            (bin_dir / "rsync").write_text(
                "#!/bin/sh\n"
                f"printf 'rsync %s\\n' \"$*\" >> {shlex.quote(str(sync_log))}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            (bin_dir / "rclone").write_text(
                "#!/bin/sh\n"
                f"printf 'rclone %s\\n' \"$*\" >> {shlex.quote(str(sync_log))}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            for script in [bin_dir / "rsync", bin_dir / "rclone"]:
                script.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "backup",
                "hugo",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APPS_HOME=str(home_dir),
                APPS_BACKUP_REMOTE="backup@example.com:/srv/apps",
                APPS_BACKUP_RCLONE_REMOTE="onedrive:apps-backups",
            )
            sync_text = sync_log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rsync -a --", sync_text)
        self.assertIn("backup@example.com:/srv/apps/", sync_text)
        self.assertIn("rclone copy --", sync_text)
        self.assertIn("onedrive:apps-backups", sync_text)

    def test_services_backup_rejects_unsafe_remote_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "wordpress"
            service_dir.mkdir(parents=True)
            (service_dir / "docker-compose.yaml").write_text("services: {}\n", encoding="utf-8")

            result = self.run_script(
                SERVICES,
                "backup",
                "wordpress",
                APPS_HOME=str(home_dir),
                APPS_BACKUP_REMOTE="backup@example.com:/srv/apps;touch/tmp/pwned",
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("APPS_BACKUP_REMOTE 不安全", result.stderr)

    def test_services_backup_cron_dry_run_prints_cron_line(self):
        result = self.run_script(
            SERVICES,
            "backup-cron",
            "all",
            APPS_DRY_RUN="1",
            APPS_HOME="/opt/apps",
            APPS_BACKUP_DIR="/opt/apps/.backups",
            APPS_BACKUP_KEEP_DAYS="30",
            APPS_BACKUP_REMOTE="backup@example.com:/srv/apps",
            APPS_BACKUP_RCLONE_REMOTE="onedrive:apps-backups",
            APPS_BACKUP_SCRIPT="/opt/install_apps.sh",
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[DRY-RUN] 将写入 crontab", result.stdout)
        self.assertIn('bash "/opt/install_apps.sh" backup "all"', result.stdout)
        self.assertIn('APPS_BACKUP_REMOTE="backup@example.com:/srv/apps"', result.stdout)

    def test_services_persists_custom_project_configuration(self):
        self.skip_if_running_as_root()
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir) / "bin"
            home_dir = Path(temp_dir) / "services"
            service_dir = home_dir / "komari"
            bin_dir.mkdir()
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = version ]; then exit 0; fi\n"
                "if [ \"$1\" = compose ] && [ \"$2\" = up ]; then exit 0; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)

            result = self.run_script(
                SERVICES,
                "deploy",
                "komari",
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                APPS_HOME=str(home_dir),
                APPS_PORT="12577",
                APPS_USERNAME="ops",
                APPS_PASSWORD="secret-value",
            )
            env_text = (service_dir / ".env").read_text(encoding="utf-8")
            compose_text = (service_dir / "docker-compose.yaml").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for expected in [
            "APP_NAME=komari",
            "APP_PORT=12577",
            "APP_DOMAIN=",
            "APP_USERNAME=ops",
            "APP_PASSWORD=secret-value",
        ]:
            self.assertIn(expected, env_text)
        self.assertIn('"127.0.0.1:12577:25774"', compose_text)
        self.assertIn("ADMIN_USERNAME: ops", compose_text)
        self.assertIn("ADMIN_PASSWORD: secret-value", compose_text)

    def test_services_proxy_reads_custom_port_from_project_env(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            service_dir = Path(temp_dir) / "wordpress"
            service_dir.mkdir()
            (service_dir / ".env").write_text(
                "APP_NAME=wordpress\n"
                "APP_PORT=18081\n"
                "APP_DOMAIN=blog.example.com\n"
                "APP_PASSWORD=stable-secret\n",
                encoding="utf-8",
            )

            result = self.run_script(
                SERVICES,
                "proxy",
                "wordpress",
                "blog.example.com",
                APPS_DRY_RUN="1",
                APPS_HOME=temp_dir,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("server 127.0.0.1:18081;", result.stdout)
