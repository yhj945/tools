# 应用安装脚本

`install_apps.sh` 用于在 Linux 服务器上快速部署一些常见轻量应用，并为每个应用生成独立的 Docker Compose 项目目录。

当前支持：

- Hugo 静态博客
- WordPress
- Halo
- Typecho
- Komari
- 3X-UI

> 说明：脚本会生成 Docker Compose 项目。真实部署需要服务器已安装 Docker 和 Docker Compose 插件，或先使用脚本的 `install-docker` 命令安装。

## 功能特性

- 一键列出支持的服务。
- 可辅助安装 Docker 和 Docker Compose 插件。
- 为每个服务生成独立 Docker Compose 项目目录。
- 安装过程中可自定义 Web 端口和域名。
- 按服务需要自动生成并持久化数据库密码或应用初始化凭据；Hugo、3X-UI 不生成无用密码。
- 重复部署时复用 `.env` 中的 `APP_PORT`、`APP_DOMAIN`、`APP_USERNAME`、`APP_PASSWORD` 和 `APP_WEB_BASE_PATH`。
- 重复部署前自动备份已有 `.env` 和 `docker-compose.yaml` 到 `.backups/`。
- 支持 `update <service>` 拉取新镜像并重建容器。
- 支持 `backup <service|all>` 备份已部署应用数据，并可同步到异地 VPS 或 rclone remote（OneDrive、Google Drive、S3 等）。
- 支持 `backup-cron <service|all>` 写入自动备份定时任务。
- 服务名使用白名单，仅允许 `hugo`、`wordpress`、`halo`、`typecho`、`komari`、`3x-ui`。
- 支持 `verify <service>` 检查已部署 Docker Compose 服务是否运行健康。
- 交互式菜单：无参数运行脚本即可选择安装 Docker、部署服务、配置域名、查看状态和验证健康。
- 支持为服务配置域名、Nginx 反向代理、Let's Encrypt 证书和自动续期。
- 证书方式可选：Cloudflare DNS-01（推荐）或 Let's Encrypt standalone。
- 支持 dry-run 预览 Compose、Nginx、证书签发和续期配置。

## 文件位置

源码文件：

```text
apps/install_apps.sh
```

默认部署目录：

```text
/opt/apps/
├── hugo/
│   ├── .env
│   ├── docker-compose.yaml
│   └── public/
├── wordpress/
│   ├── .env
│   ├── docker-compose.yaml
│   └── data/
├── halo/
│   ├── .env
│   ├── docker-compose.yaml
│   └── data/
├── typecho/
│   ├── .env
│   ├── docker-compose.yaml
│   └── data/
├── komari/
│   ├── .env
│   ├── docker-compose.yaml
│   └── data/
└── 3x-ui/
    ├── .env
    ├── docker-compose.yaml
    ├── db/
    └── cert/
```

可通过环境变量修改部署目录；交互式部署时也会询问部署目录，默认使用 `/opt/apps`：

```bash
APPS_HOME=/data/apps bash install_apps.sh deploy wordpress
```

每个服务目录下的 `.env` 会保存本次部署配置：

```text
APP_INSTALLER_VERSION=1.0.0
APP_NAME=wordpress
APP_PORT=8081
APP_DOMAIN=blog.example.com
APP_USERNAME=
APP_PASSWORD=...
APP_WEB_BASE_PATH=
```

不同服务只会使用自己需要的字段。例如 WordPress、Halo、Typecho 使用 `APP_PASSWORD` 作为数据库密码；Komari 使用 `APP_USERNAME` 和 `APP_PASSWORD` 初始化管理员；Hugo 不需要账号密码；3X-UI 只使用 `APP_WEB_BASE_PATH`。

## 命令参考

| 命令 | 说明 |
|------|------|
| 无参数 | 打开交互式菜单 |
| `list` | 列出支持的服务 |
| `install-docker` | 尝试安装 Docker 和 Docker Compose 插件 |
| `deploy <service> [domain]` | 部署指定服务；传入域名时同时配置 HTTPS 反向代理 |
| `proxy <service> <domain>` | 为已部署服务配置 Nginx、Let's Encrypt 证书和自动续期 |
| `status <service>` | 查看 Docker Compose 服务状态 |
| `logs <service>` | 跟随 Docker Compose 日志 |
| `update <service>` | 拉取镜像并重建指定服务 |
| `backup <service\|all>` | 备份指定服务或全部已部署服务 |
| `backup-cron <service\|all>` | 写入自动备份 crontab |
| `stop <service>` | 停止指定服务 |
| `uninstall <service>` | 停止并删除指定服务项目目录 |
| `verify <service>` | 验证指定服务是否已部署且 Docker Compose 状态健康 |
| `check` | 检查脚本可运行 |
| `help` | 显示帮助信息 |

## 快速开始

### 远程运行

```bash
# 打开交互式菜单
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh)

# 自动化兼容：仍可直接指定命令
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh) help
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh) list
APPS_DRY_RUN=1 bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh) deploy hugo
```

如果当前 shell 不支持进程替换，可使用管道方式：

```bash
curl -sL https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh | bash -s -- list
```

安装 Docker 或部署服务通常需要 root 权限。技术上可以一键远程执行，但更建议先下载、审阅脚本，再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/yhj945/tools/main/apps/install_apps.sh
less install_apps.sh
sudo bash install_apps.sh install-docker
sudo bash install_apps.sh deploy hugo
```

### 交互式菜单

推荐直接运行脚本进入交互式菜单：

```bash
bash install_apps.sh
```

菜单中可以选择检查环境、列出服务、部署服务、管理已部署服务、配置 HTTPS 反向代理、配置自动备份、安装 Docker 和检查脚本。部署服务时会依次询问部署目录、服务、Web 端口和域名；直接回车使用默认值。Komari 会继续询问管理员用户名和密码，3X-UI 会询问面板访问路径。需要配置域名时，菜单会继续询问证书方式。配置自动备份时会依次询问备份范围、备份目录、保留天数、备份星期、备份时间、远程服务器备份位置和云盘备份位置。

命令行自动化可使用这些环境变量：

```bash
APPS_HOME=/data/apps \
APPS_PORT=18081 \
APPS_DOMAIN=blog.example.com \
APPS_DRY_RUN=1 \
bash install_apps.sh deploy wordpress

APPS_USERNAME=ops APPS_PASSWORD='change-me-now' \
APPS_PORT=12577 \
bash install_apps.sh deploy komari monitor.example.com

APPS_PORT=12053 APPS_WEB_BASE_PATH=/panel \
bash install_apps.sh deploy 3x-ui panel.example.com
```

### 查看支持的服务

```bash
bash install_apps.sh list
```

### 安装 Docker

```bash
sudo bash install_apps.sh install-docker
```

支持的包管理器：

- `apt-get`
- `dnf`
- `yum`

如果当前系统不支持自动安装，请按系统发行版文档手动安装 Docker。

### 部署 Hugo 静态博客

```bash
sudo bash install_apps.sh deploy hugo
```

默认访问端口：

```text
http://127.0.0.1:8080/
```

脚本会创建一个默认静态页面：

```text
/opt/apps/hugo/public/index.html
```

你可以将 Hugo 生成的 `public/` 目录内容替换到该路径。

### 部署 WordPress

```bash
sudo bash install_apps.sh deploy wordpress
```

默认访问端口：

```text
http://127.0.0.1:8081/
```

组件：

- `wordpress:6-apache`
- `mariadb:11`

数据目录：

```text
/opt/apps/wordpress/data/
```

### 部署 Halo

```bash
sudo bash install_apps.sh deploy halo
```

默认访问端口：

```text
http://127.0.0.1:8082/
```

组件：

- `halohub/halo:2`
- `postgres:16-alpine`

数据目录：

```text
/opt/apps/halo/data/
```

### 部署 Typecho

```bash
sudo bash install_apps.sh deploy typecho
```

默认访问端口：

```text
http://127.0.0.1:8083/
```

组件：

- `joyqi/typecho:nightly-php8.2-apache`
- `mariadb:11`

数据目录：

```text
/opt/apps/typecho/data/
```

### 部署 Komari 监控面板

```bash
sudo bash install_apps.sh deploy komari
```

默认访问端口：

```text
http://127.0.0.1:25774/
```

组件：

- `ghcr.io/komari-monitor/komari:latest`

数据目录：

```text
/opt/apps/komari/data/
```

脚本会把 `APP_USERNAME` 和 `APP_PASSWORD` 写入 Compose 环境变量，用于 Komari 初始化管理员。交互式安装时可自定义：

- 默认用户名：`admin`
- 密码：保存在 `/opt/apps/komari/.env` 的 `APP_PASSWORD`

### 部署 3X-UI 面板

```bash
sudo bash install_apps.sh deploy 3x-ui
```

默认访问端口：

```text
http://127.0.0.1:2053/
```

组件：

- `ghcr.io/mhsanaei/3x-ui:latest`

数据目录：

```text
/opt/apps/3x-ui/db/
/opt/apps/3x-ui/cert/
```

3X-UI 使用官方支持的 `XUI_PORT` 和 `XUI_INIT_WEB_BASE_PATH` 配置面板端口和访问路径，并默认只把面板端口绑定到 `127.0.0.1`，建议配合脚本的 HTTPS 反向代理使用。

本脚本采用 Docker Compose 部署 `ghcr.io/mhsanaei/3x-ui:latest`，不会把 3X-UI 登录凭据写入 `.env`。3X-UI Docker 镜像默认账号和密码均为 `admin`；首次登录后请立即在面板中修改。

## 服务端口

| 服务 | 默认端口 | 说明 |
|------|----------|------|
| Hugo | `127.0.0.1:8080` | nginx 静态站点 |
| WordPress | `127.0.0.1:8081` | WordPress Web |
| Halo | `127.0.0.1:8082` | Halo Web，容器内端口 `8090` |
| Typecho | `127.0.0.1:8083` | Typecho Web |
| Komari | `127.0.0.1:25774` | Komari Web |
| 3X-UI | `127.0.0.1:2053` | 3X-UI Web；Xray 入站端口由面板配置 |

默认 HTTP 端口只绑定本机回环地址，避免绕过 Nginx/HTTPS 直接暴露到公网。配置域名后，对外访问入口由 Nginx 的 80/443 端口提供。3X-UI 的代理入站端口由面板配置；如需开放代理入站端口，请自行调整 Docker Compose 端口映射和防火墙策略。

如果端口冲突，推荐重新运行交互式部署并输入新的 Web 端口，或通过 `APPS_PORT=<端口>` 重新部署。

## 域名、Nginx 和 HTTPS 证书

脚本支持两种方式配置外网访问域名。配置 `proxy` 前请先安装 acme.sh，默认路径为 `/root/.acme.sh/acme.sh`，或通过 `APPS_ACME_HOME` / `APPS_ACME_SH` 指定已有安装路径。自定义 acme.sh 路径必须是安全绝对路径，且目录链和可执行文件应由 root 拥有、不可被普通用户写入；脚本会在执行前规范化并校验这些路径。推荐通过交互式菜单选择：

```bash
sudo bash install_apps.sh
```

也可以继续使用命令参数，适合自动化脚本：

```bash
# 方式一：Let's Encrypt + acme.sh + Cloudflare Token（推荐，默认）
sudo CF_Token="你的 Cloudflare API Token" CF_Zone_ID="你的 Zone ID" \
  bash install_apps.sh deploy wordpress blog.example.com

sudo CF_Token="你的 Cloudflare API Token" CF_Zone_ID="你的 Zone ID" \
  bash install_apps.sh proxy wordpress blog.example.com

# 方式二：Let's Encrypt standalone（无 Cloudflare Token 时使用）
sudo APPS_CERT_MODE=standalone \
  bash install_apps.sh proxy wordpress blog.example.com
```

命令格式：

```text
deploy <service> [domain]
proxy <service> <domain>
```

`proxy` 会自动处理：

- 生成 Nginx 反向代理配置，默认写入 `/etc/nginx/conf.d/app-<service>-<domain>.conf`。
- 将域名转发到对应本机端口：Hugo `8080`、WordPress `8081`、Halo `8082`、Typecho `8083`、Komari `25774`、3X-UI `2053`。
- 使用 acme.sh + Let's Encrypt 签发证书；默认走 Cloudflare DNS-01，也可通过 `APPS_CERT_MODE=standalone` 使用 standalone。
- 安装证书到 `/etc/nginx/ssl/<domain>/fullchain.cer` 和 `/etc/nginx/ssl/<domain>/private.key`。
- 执行 `nginx -t` 并 reload Nginx。
- 写入 root `crontab` 续期任务，续期日志位于 `/etc/nginx/ssl/<domain>/acme-renew.log`。

生成的 Nginx 配置包含长连接/流式响应友好的配置：

```nginx
proxy_connect_timeout 60s;
proxy_send_timeout 600s;
proxy_read_timeout 3600s;
proxy_buffering off;
```

### 证书方式

默认方式是 `APPS_CERT_MODE=cloudflare`，也就是 Let's Encrypt + acme.sh + Cloudflare DNS-01。这个方式不需要停止 Nginx，也不依赖 80 端口完成验证，推荐优先使用。

没有 Cloudflare Token 时，可以使用 `APPS_CERT_MODE=standalone`。standalone 会临时停止 Nginx，让 acme.sh 监听 80 端口完成验证，然后再启动并 reload Nginx。使用前请确认域名 A/AAAA 记录已经解析到当前实例，且云防火墙/系统防火墙允许 80 端口入站。

### Cloudflare DNS-01 凭据

使用 Cloudflare DNS-01 时，请在 Cloudflare 创建只授予目标 zone 的 Token：

```text
DNS & Zones / DNS  / Edit
DNS & Zones / Zone / Read
```

执行命令前临时传入：

```bash
export CF_Token="你的 Cloudflare API Token"
export CF_Zone_ID="你的 Zone ID"
sudo -E bash install_apps.sh proxy wordpress blog.example.com
```

建议只在执行签发命令时临时传入 Cloudflare Token，不要长期写入 `/etc/profile` 或 `~/.bashrc`。首次签发成功后，acme.sh 会把 DNS API 凭据保存到 root 的 acme.sh 账户配置中，应保持 root-only 权限。

### dry-run 预览域名配置

```bash
APPS_DRY_RUN=1 bash install_apps.sh deploy wordpress blog.example.com
APPS_DRY_RUN=1 bash install_apps.sh proxy wordpress blog.example.com
APPS_DRY_RUN=1 APPS_CERT_MODE=standalone \
  bash install_apps.sh proxy wordpress blog.example.com
```

`dry-run` 会输出将生成的 Compose、Nginx、acme.sh 签发/安装命令和续期 crontab，不会写入系统目录，也不会输出 `CF_Token` 的值。

### DNS 配置提示

请先在 DNS 服务商处把域名解析到当前 Linux 服务器公网 IP。若域名托管在 Cloudflare：

- 普通博客访问可以使用橙云代理。
- 如果后续有长耗时接口或大文件直连需求，可参考灰云 / DNS only 模式，避免被 Cloudflare 代理层超时限制影响。

## 管理服务

以 WordPress 为例：

```bash
sudo bash install_apps.sh status wordpress
sudo bash install_apps.sh verify wordpress
sudo bash install_apps.sh logs wordpress
sudo bash install_apps.sh update wordpress
sudo bash install_apps.sh backup wordpress
sudo bash install_apps.sh stop wordpress
sudo bash install_apps.sh uninstall wordpress
```

默认部署目录位于 `/opt/apps`，且 `docker-compose.yaml` 权限为 `600`，通常需要 root 权限读取和管理。如果你使用自有 `APPS_HOME` 且当前用户具备 Docker 权限，可以不加 `sudo`。

`verify` 会读取服务目录中的 `docker-compose.yaml`，执行 `docker compose ps`，并在输出包含 `exited`、`dead`、`unhealthy` 或 `restarting` 时返回失败。

`update` 会在服务目录中执行 `docker compose pull` 和 `docker compose up -d`，用于拉取镜像更新并重建容器。更新前建议先备份数据目录。

`backup` 会把服务目录打包为 `tar.gz`，包含 `.env`、`docker-compose.yaml` 和数据目录；归档文件默认写入 `/opt/apps/.backups/`。

`uninstall` 会执行 `docker compose down`，然后删除该服务项目目录。删除前请确认已经备份需要保留的数据。

## 自动备份

### 本地备份

备份单个服务：

```bash
sudo bash install_apps.sh backup wordpress
```

备份全部已部署服务：

```bash
sudo bash install_apps.sh backup all
```

默认备份目录为 `/opt/apps/.backups/`，文件名格式为 `<服务>-<时间戳>.tar.gz`。可通过环境变量修改：

```bash
sudo APPS_BACKUP_DIR=/data/app-backups \
  bash install_apps.sh backup wordpress
```

设置本地备份保留天数：

```bash
sudo APPS_BACKUP_KEEP_DAYS=30 \
  bash install_apps.sh backup all
```

### 远程服务器备份

远程服务器备份适合把归档同步到另一台 VPS、NAS 或备份机。推荐提前配置 SSH key，并确保目标目录存在：

```bash
sudo APPS_BACKUP_REMOTE=backup@example.com:/data/app-backups \
  bash install_apps.sh backup all
```

脚本会优先使用 `rsync`，没有 `rsync` 时回退到 `scp`。交互式菜单中的“远程服务器备份位置”对应 `APPS_BACKUP_REMOTE`。

### 云盘备份（rclone）

OneDrive、Google Drive、S3、WebDAV 等建议通过 `rclone` 配置 remote 后同步：

```bash
# 示例：rclone 中已配置 remote 名称为 onedrive
sudo APPS_BACKUP_RCLONE_REMOTE=onedrive:apps-backups \
  bash install_apps.sh backup all
```

`APPS_BACKUP_RCLONE_REMOTE` 可以是任意 rclone 支持的 remote，例如 `gdrive:apps-backups`、`s3:bucket/apps`、`webdav:apps-backups`。交互式菜单中的“云盘备份位置（rclone）”对应该配置。

### 定时自动备份

推荐直接通过交互式菜单配置：

```bash
sudo bash install_apps.sh
```

选择 `6) 配置自动备份` 后，按提示输入：

- 备份范围：`all` 或指定服务。
- 备份目录：默认 `/opt/apps/.backups/`。
- 保留天数：`0` 表示不自动清理旧备份。
- 自动备份星期：直接回车表示每天，也可输入 `1,3,5` 或 `1-5`；`1` 到 `7` 分别表示周一到周日。
- 备份时间：默认 `03:30`，可输入 `03:00`、`02:15` 等 `HH:MM` 格式。
- 远程服务器备份位置：例如 `backup@example.com:/data/app-backups`，可留空。
- 云盘备份位置（rclone）：例如 `onedrive:apps-backups`，可留空。

写入每天 03:30 自动备份全部服务：

```bash
sudo APPS_BACKUP_REMOTE=backup@example.com:/data/app-backups \
  APPS_BACKUP_RCLONE_REMOTE=onedrive:apps-backups \
  APPS_BACKUP_KEEP_DAYS=30 \
  bash install_apps.sh backup-cron all
```

自定义 cron 时间：

```bash
sudo APPS_BACKUP_CRON="15 2 * * *" \
  bash install_apps.sh backup-cron wordpress
```

命令行自动化仍可直接传入标准 cron 表达式。交互式菜单会根据选择的星期和时间自动生成 cron 表达式。

如果脚本不是以本地文件运行（例如通过 `bash <(curl ...)` 远程运行），写入 cron 时需要先下载脚本，或通过 `APPS_BACKUP_SCRIPT=/path/to/install_apps.sh` 指定本地脚本绝对路径。

备份归档包含 `.env` 和应用数据，可能包含数据库密码、应用初始化凭据、证书或用户数据。请确保本地备份目录、远程服务器目录和 rclone 配置只允许可信用户访问。

## dry-run

预览部署文件，不写入目录、不启动容器：

```bash
APPS_DRY_RUN=1 bash install_apps.sh deploy hugo
APPS_DRY_RUN=1 bash install_apps.sh deploy wordpress
APPS_DRY_RUN=1 bash install_apps.sh deploy halo
APPS_DRY_RUN=1 bash install_apps.sh deploy typecho
APPS_DRY_RUN=1 bash install_apps.sh deploy komari
APPS_DRY_RUN=1 bash install_apps.sh deploy 3x-ui
```

注意：如果服务需要密码且目录下已经存在 `.env`，dry-run 会复用其中的 `APP_PASSWORD` 语义，但输出 Compose 预览时会用 `<redacted-existing-password>` 代替真实密码。没有现有 `.env` 时，dry-run 中生成的密码只用于预览，不会持久化。Hugo、3X-UI 不生成无用密码。

## 密码与数据

脚本会在每个服务目录下创建 `.env`：

```bash
APP_INSTALLER_VERSION=1.0.0
APP_NAME=wordpress
APP_PORT=8081
APP_DOMAIN=
APP_USERNAME=
APP_PASSWORD=<generated-password>
APP_WEB_BASE_PATH=
```

说明：

- WordPress、Halo、Typecho 会生成并使用数据库密码；后台账号密码需要你在首次访问 Web 页面时设置。
- Komari 会使用 `APP_USERNAME` 和 `APP_PASSWORD` 初始化管理员，交互式安装时可以自定义；默认用户名为 `admin`。
- Hugo 是静态站点，不需要密码；即使传入 `APPS_PASSWORD`，脚本也不会把它用于 Hugo。
- 3X-UI 使用 Docker Compose 部署，脚本只配置 Web 端口和访问路径。Docker 镜像默认账号和密码均为 `admin`，首次登录后请立即修改登录凭据。
- 重复部署会复用需要的已有密码，避免数据库已有数据无法登录。
- 如果需要密码的服务 `.env` 已存在但缺少 `APP_PASSWORD`，脚本会补写该字段。
- 重复部署前，已有 `.env` 和 `docker-compose.yaml` 会备份到服务目录下的 `.backups/<时间戳>/`。

## 安全提示

- 部署服务会开放本机端口，请确认云防火墙、安全组和系统防火墙配置。
- 未传入域名时只开放默认 HTTP 端口；传入域名或执行 `proxy <service> <domain>` 时会配置 Nginx HTTPS 反向代理。
- Cloudflare Token 建议只在执行命令时临时通过环境变量传入。
- 默认镜像来自公开 Docker Registry，请根据实际安全要求固定版本、配置备份和更新策略。
- 备份归档包含敏感配置和持久化数据；同步到远程服务器或云盘前，请确认远端权限和加密策略。
- `uninstall` 会删除服务目录，请先备份数据。

## 故障排查

### Docker Compose 不存在

先安装 Docker：

```bash
sudo bash install_apps.sh install-docker
```

或手动安装 Docker Compose 插件。

### 端口被占用

查看占用：

```bash
sudo ss -lntp
```

修改对应服务目录下 `docker-compose.yaml` 的 `ports` 映射后重新部署：

```bash
cd /opt/apps/wordpress
sudo docker compose up -d
```

### 查看容器日志

```bash
bash install_apps.sh logs halo
```

## 开源协议

MIT License
