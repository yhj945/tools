# Oracle 实用服务部署脚本

`oracle_app_services.sh` 用于在 Oracle 实例上快速部署一些真实可用的轻量服务，让实例产生更有意义的资源使用，而不是单纯空转。

当前支持：

- Hugo 静态博客
- WordPress
- Halo
- Typecho

> 说明：脚本会生成 Docker Compose 项目。真实部署需要服务器已安装 Docker 和 Docker Compose 插件，或先使用脚本的 `install-docker` 命令安装。

## 功能特性

- 一键列出支持的服务。
- 可辅助安装 Docker 和 Docker Compose 插件。
- 为每个服务生成独立 Docker Compose 项目目录。
- 自动生成并持久化数据库密码。
- 重复部署时复用 `.env` 中的 `ORACLE_SERVICE_PASSWORD`，避免数据库密码轮换导致应用无法连接。
- 服务名使用白名单，仅允许 `hugo`、`wordpress`、`halo`、`typecho`。
- 支持 `verify <service>` 检查已部署 Docker Compose 服务是否运行健康。
- 交互式菜单：无参数运行脚本即可选择安装 Docker、部署服务、配置域名、查看状态和验证健康。
- 支持为服务配置域名、Nginx 反向代理、Let's Encrypt 证书和自动续期。
- 证书方式可选：Cloudflare DNS-01（推荐）或 Let's Encrypt standalone。
- 支持 dry-run 预览 Compose、Nginx、证书签发和续期配置。

## 文件位置

源码文件：

```text
oracle/oracle_app_services.sh
```

默认部署目录：

```text
/opt/oracle-services/
├── hugo/
│   ├── .env
│   ├── docker-compose.yml
│   └── public/
├── wordpress/
│   ├── .env
│   ├── docker-compose.yml
│   └── data/
├── halo/
│   ├── .env
│   ├── docker-compose.yml
│   └── data/
└── typecho/
    ├── .env
    ├── docker-compose.yml
    └── data/
```

可通过环境变量修改部署目录：

```bash
ORACLE_SERVICES_HOME=/data/oracle-services bash oracle_app_services.sh deploy wordpress
```

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
| `stop <service>` | 停止指定服务 |
| `uninstall <service>` | 停止并删除指定服务项目目录 |
| `verify <service>` | 验证指定服务是否已部署且 Docker Compose 状态健康 |
| `check` | 检查脚本可运行 |
| `help` | 显示帮助信息 |

## 快速开始

### 远程运行

```bash
# 打开交互式菜单
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh)

# 自动化兼容：仍可直接指定命令
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh) help
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh) list
ORACLE_SERVICES_DRY_RUN=1 bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh) deploy hugo
```

如果当前 shell 不支持进程替换，可使用管道方式：

```bash
curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh | bash -s -- list
```

安装 Docker 或部署服务通常需要 root 权限。技术上可以一键远程执行，但更建议先下载、审阅脚本，再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_app_services.sh
less oracle_app_services.sh
sudo bash oracle_app_services.sh install-docker
sudo bash oracle_app_services.sh deploy hugo
```

### 交互式菜单

推荐直接运行脚本进入交互式菜单：

```bash
bash oracle_app_services.sh
```

菜单中可以选择列出服务、安装 Docker、部署服务、配置 HTTPS 反向代理、查看状态、查看日志、停止、卸载和验证服务。需要配置域名时，菜单会继续询问服务名、域名和证书方式。

### 查看支持的服务

```bash
bash oracle_app_services.sh list
```

### 安装 Docker

```bash
sudo bash oracle_app_services.sh install-docker
```

支持的包管理器：

- `apt-get`
- `dnf`
- `yum`

如果当前系统不支持自动安装，请按系统发行版文档手动安装 Docker。

### 部署 Hugo 静态博客

```bash
sudo bash oracle_app_services.sh deploy hugo
```

默认访问端口：

```text
http://127.0.0.1:8080/
```

脚本会创建一个默认静态页面：

```text
/opt/oracle-services/hugo/public/index.html
```

你可以将 Hugo 生成的 `public/` 目录内容替换到该路径。

### 部署 WordPress

```bash
sudo bash oracle_app_services.sh deploy wordpress
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
/opt/oracle-services/wordpress/data/
```

### 部署 Halo

```bash
sudo bash oracle_app_services.sh deploy halo
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
/opt/oracle-services/halo/data/
```

### 部署 Typecho

```bash
sudo bash oracle_app_services.sh deploy typecho
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
/opt/oracle-services/typecho/data/
```

## 服务端口

| 服务 | 默认端口 | 说明 |
|------|----------|------|
| Hugo | `127.0.0.1:8080` | nginx 静态站点 |
| WordPress | `127.0.0.1:8081` | WordPress Web |
| Halo | `127.0.0.1:8082` | Halo Web，容器内端口 `8090` |
| Typecho | `127.0.0.1:8083` | Typecho Web |

默认 HTTP 端口只绑定本机回环地址，避免绕过 Nginx/HTTPS 直接暴露到公网。配置域名后，对外访问入口由 Nginx 的 80/443 端口提供。

如果端口冲突，可编辑对应目录下的 `docker-compose.yml` 后重启服务。

## 域名、Nginx 和 HTTPS 证书

脚本支持两种方式配置外网访问域名。配置 `proxy` 前请先安装 acme.sh，默认路径为 `/root/.acme.sh/acme.sh`，或通过 `ORACLE_SERVICES_ACME_HOME` / `ORACLE_SERVICES_ACME_SH` 指定已有安装路径。自定义 acme.sh 路径必须是安全绝对路径，且目录链和可执行文件应由 root 拥有、不可被普通用户写入；脚本会在执行前规范化并校验这些路径。推荐通过交互式菜单选择：

```bash
sudo bash oracle_app_services.sh
```

也可以继续使用命令参数，适合自动化脚本：

```bash
# 方式一：Let's Encrypt + acme.sh + Cloudflare Token（推荐，默认）
sudo CF_Token="你的 Cloudflare API Token" CF_Zone_ID="你的 Zone ID" \
  bash oracle_app_services.sh deploy wordpress blog.example.com

sudo CF_Token="你的 Cloudflare API Token" CF_Zone_ID="你的 Zone ID" \
  bash oracle_app_services.sh proxy wordpress blog.example.com

# 方式二：Let's Encrypt standalone（无 Cloudflare Token 时使用）
sudo ORACLE_SERVICES_CERT_MODE=standalone \
  bash oracle_app_services.sh proxy wordpress blog.example.com
```

命令格式：

```text
deploy <service> [domain]
proxy <service> <domain>
```

`proxy` 会自动处理：

- 生成 Nginx 反向代理配置，默认写入 `/etc/nginx/conf.d/oracle-<service>-<domain>.conf`。
- 将域名转发到对应本机端口：Hugo `8080`、WordPress `8081`、Halo `8082`、Typecho `8083`。
- 使用 acme.sh + Let's Encrypt 签发证书；默认走 Cloudflare DNS-01，也可通过 `ORACLE_SERVICES_CERT_MODE=standalone` 使用 standalone。
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

默认方式是 `ORACLE_SERVICES_CERT_MODE=cloudflare`，也就是 Let's Encrypt + acme.sh + Cloudflare DNS-01。这个方式不需要停止 Nginx，也不依赖 80 端口完成验证，推荐优先使用。

没有 Cloudflare Token 时，可以使用 `ORACLE_SERVICES_CERT_MODE=standalone`。standalone 会临时停止 Nginx，让 acme.sh 监听 80 端口完成验证，然后再启动并 reload Nginx。使用前请确认域名 A/AAAA 记录已经解析到当前实例，且云防火墙/系统防火墙允许 80 端口入站。

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
sudo -E bash oracle_app_services.sh proxy wordpress blog.example.com
```

不要把 Cloudflare Token 写入项目文件、公开文档、`/etc/profile` 或 `~/.bashrc`。首次签发成功后，acme.sh 会把 DNS API 凭据保存到 root 的 acme.sh 账户配置中，应保持 root-only 权限。

### dry-run 预览域名配置

```bash
ORACLE_SERVICES_DRY_RUN=1 bash oracle_app_services.sh deploy wordpress blog.example.com
ORACLE_SERVICES_DRY_RUN=1 bash oracle_app_services.sh proxy wordpress blog.example.com
ORACLE_SERVICES_DRY_RUN=1 ORACLE_SERVICES_CERT_MODE=standalone \
  bash oracle_app_services.sh proxy wordpress blog.example.com
```

`dry-run` 会输出将生成的 Compose、Nginx、acme.sh 签发/安装命令和续期 crontab，不会写入系统目录，也不会输出 `CF_Token` 的值。

### DNS 配置提示

请先在 DNS 服务商处把域名解析到当前 Oracle 实例公网 IP。若域名托管在 Cloudflare：

- 普通博客访问可以使用橙云代理。
- 如果后续有长耗时接口或大文件直连需求，可参考灰云 / DNS only 模式，避免被 Cloudflare 代理层超时限制影响。

## 管理服务

以 WordPress 为例：

```bash
sudo bash oracle_app_services.sh status wordpress
sudo bash oracle_app_services.sh verify wordpress
sudo bash oracle_app_services.sh logs wordpress
sudo bash oracle_app_services.sh stop wordpress
sudo bash oracle_app_services.sh uninstall wordpress
```

默认部署目录位于 `/opt/oracle-services`，且 `docker-compose.yml` 权限为 `600`，通常需要 root 权限读取和管理。如果你使用自有 `ORACLE_SERVICES_HOME` 且当前用户具备 Docker 权限，可以不加 `sudo`。

`verify` 会读取服务目录中的 `docker-compose.yml`，执行 `docker compose ps`，并在输出包含 `exited`、`dead`、`unhealthy` 或 `restarting` 时返回失败。

`uninstall` 会执行 `docker compose down`，然后删除该服务项目目录。删除前请确认已经备份需要保留的数据。

## dry-run

预览部署文件，不写入目录、不启动容器：

```bash
ORACLE_SERVICES_DRY_RUN=1 bash oracle_app_services.sh deploy hugo
ORACLE_SERVICES_DRY_RUN=1 bash oracle_app_services.sh deploy wordpress
ORACLE_SERVICES_DRY_RUN=1 bash oracle_app_services.sh deploy halo
ORACLE_SERVICES_DRY_RUN=1 bash oracle_app_services.sh deploy typecho
```

注意：如果服务目录下已经存在 `.env`，dry-run 会复用其中的 `ORACLE_SERVICE_PASSWORD` 语义，但输出 Compose 预览时会用 `<redacted-existing-password>` 代替真实密码。没有现有 `.env` 时，dry-run 中生成的密码只用于预览，不会持久化。仍建议不要把完整 dry-run 输出直接粘贴到公开日志或 Issue。

## 密码与数据

脚本会在每个服务目录下创建 `.env`：

```bash
ORACLE_SERVICE=wordpress
ORACLE_SERVICE_PASSWORD=<generated-password>
```

说明：

- 首次部署会生成随机密码。
- WordPress、Halo、Typecho 会在 Compose 环境变量中使用该密码。
- Hugo 当前也会生成 `.env`，但默认 Hugo Compose 不使用该密码；保留它是为了统一服务目录结构。
- 重复部署会复用已有密码，避免数据库已有数据无法登录。
- 如果 `.env` 已存在但缺少 `ORACLE_SERVICE_PASSWORD`，脚本会补写该字段。
- `.env` 和 `data/` 目录可能包含敏感信息或持久化数据，不应提交到 Git。

## 安全提示

- 部署服务会开放本机端口，请确认云防火墙、安全组和系统防火墙配置。
- 未传入域名时只开放默认 HTTP 端口；传入域名或执行 `proxy <service> <domain>` 时会配置 Nginx HTTPS 反向代理。
- Cloudflare Token 只应临时通过环境变量传入，不要写入项目文件或公开日志。
- 默认镜像来自公开 Docker Registry，请根据实际安全要求固定版本、配置备份和更新策略。
- `uninstall` 会删除服务目录，请先备份数据。

## 故障排查

### Docker Compose 不存在

先安装 Docker：

```bash
sudo bash oracle_app_services.sh install-docker
```

或手动安装 Docker Compose 插件。

### 端口被占用

查看占用：

```bash
sudo ss -lntp
```

修改对应服务目录下 `docker-compose.yml` 的 `ports` 映射后重新部署：

```bash
cd /opt/oracle-services/wordpress
sudo docker compose up -d
```

### 查看容器日志

```bash
bash oracle_app_services.sh logs halo
```

### 备份服务数据

示例：

```bash
sudo tar -czf wordpress-backup.tar.gz /opt/oracle-services/wordpress
```

## 开源协议

MIT License
