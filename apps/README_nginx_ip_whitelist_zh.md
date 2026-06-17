# Nginx IP 白名单管理脚本

`nginx_ip_whitelist.sh` 用于为 Nginx 站点配置添加、移除和启用 IP 白名单。脚本会维护一个独立的白名单片段文件，并把 `include` 插入到指定站点的 `location` 块中。

适用场景：

- Docker 中运行的 Nginx。
- systemd 安装并运行的宿主机 Nginx。
- 手动指定 `nginx.conf` 目录的本地配置或测试目录。

> 说明：脚本不会把白名单直接写进站点配置，而是生成 `ip-whitelist.conf` 片段，再在站点配置中插入 `include`。启用、禁用站点白名单前会自动备份原配置。

## 功能特性

- 自动从 Docker/systemd/nginx 二进制推导正在使用的 `nginx.conf`。
- 支持显式指定 `NGINX_IPWL_ROOT` 管理某个本地配置目录。
- 支持 Docker Nginx bind mount 路径识别。
- 支持 `file` 模式下关联 Docker 容器；如果指定目录就是容器挂载源，`check/reload` 会使用 Docker 容器执行。
- 支持添加、移除多个 IPv4、IPv6、CIDR 白名单条目。
- 支持同一 `.conf` 文件里多个 `server` 块，按 `server_name`、`listen` 和行号区分。
- 支持同一站点多个 `location` 块，自动跳过 ACME challenge。
- 启用/禁用前自动备份站点配置。
- 修改后自动执行 `nginx -t`；检查失败会回滚。
- 可选显示类似 `git diff` 的变更预览，确认后才应用。
- 修改配置时尽量保留原文件权限、属主和属组。
- 无 Nginx 环境时仍可打开菜单，并显示诊断信息。

## 文件位置

源码文件：

```text
apps/nginx_ip_whitelist.sh
```

默认白名单片段路径：

```text
conf.d/snippets/ip-whitelist.conf
```

例如 Docker Nginx 配置挂载为：

```text
宿主机：/home/docker/nginx/conf/conf.d
容器内：/etc/nginx/conf.d
```

脚本会在宿主机创建：

```text
/home/docker/nginx/conf/conf.d/snippets/ip-whitelist.conf
```

写入站点配置的 include 通常是容器内路径：

```nginx
include /etc/nginx/conf.d/snippets/ip-whitelist.conf; # managed by nginx_ip_whitelist.sh
```

如果是纯 `file` 模式且没有关联 Docker 容器，include 会使用宿主机路径。

## 命令参考

| 命令 | 说明 |
|------|------|
| 无参数 | 打开交互式菜单 |
| `menu` | 打开交互式菜单 |
| `status` | 查看脚本配置、Nginx 环境、白名单和站点配置 |
| `add <IP/CIDR...>` | 添加一个或多个白名单 IP/CIDR |
| `remove <IP/CIDR...>` | 移除一个或多个白名单 IP/CIDR；菜单中也可按编号移除 |
| `enable` | 为选中的 `server` 块内 `location` 插入白名单 include |
| `disable` | 移除选中的 `server` 块内脚本插入的 include |
| `check` | 执行 Nginx 配置检查 |
| `reload` | reload Nginx |
| `help` | 显示帮助信息 |

## 快速开始

### 交互式菜单

推荐直接运行脚本：

```bash
sudo ./apps/nginx_ip_whitelist.sh
```

脚本会显示：

- 脚本运行模式。
- 本机 nginx 命令状态。
- systemd nginx 状态。
- Docker Nginx 状态。
- Docker 配置挂载。
- 白名单文件和 include 路径。
- 站点配置及每个 `server` 块的 `server_name`、`listen` 和启用状态。

### 添加白名单

```bash
sudo ./apps/nginx_ip_whitelist.sh add 1.2.3.4 1.2.3.0/24 2001:db8::1/128
```

或在菜单中选择：

```text
2) 添加白名单 IP/CIDR
```

### 启用白名单

```bash
sudo ./apps/nginx_ip_whitelist.sh enable
```

如果只有一个站点配置和一个 `server` 块，脚本会自动选择；如果有多个，会进入选择菜单。

启用时会把 include 插入到普通 `location` 块中，例如：

```nginx
location / {
    include /etc/nginx/conf.d/snippets/ip-whitelist.conf; # managed by nginx_ip_whitelist.sh
    proxy_pass http://backend;
}
```

脚本会跳过 ACME challenge：

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/letsencrypt;
}
```

### 禁用白名单

```bash
sudo ./apps/nginx_ip_whitelist.sh disable
```

只会移除带有脚本标记的 include：

```nginx
# managed by nginx_ip_whitelist.sh
```

### 查看状态

```bash
sudo ./apps/nginx_ip_whitelist.sh status
```

示例输出：

```text
脚本配置
  脚本运行模式：docker
  Nginx 根目录：/home/docker/nginx/conf
  nginx.conf：/home/docker/nginx/conf/nginx.conf
  conf.d 目录：/home/docker/nginx/conf/conf.d
  配置内 conf.d：/etc/nginx/conf.d

Nginx 环境
  本机 nginx 命令：未安装
  systemd nginx：未运行
  Docker Nginx：运行中（容器：nginx）
  Docker 配置挂载：/etc/nginx/conf.d -> /home/docker/nginx/conf/conf.d
  Docker 容器：nginx

白名单
  白名单文件：/home/docker/nginx/conf/conf.d/snippets/ip-whitelist.conf
  include 路径：/etc/nginx/conf.d/snippets/ip-whitelist.conf
  条目数：1
```

## 运行模式

### docker

脚本自动识别 Docker 中运行的 Nginx，并把容器内 `/etc/nginx` 或 `/etc/nginx/conf.d` 映射到宿主机 bind mount。

检查配置：

```bash
docker exec nginx nginx -t
```

reload：

```bash
docker exec nginx nginx -s reload
```

如果容器名不是 `nginx`，可以指定：

```bash
sudo NGINX_IPWL_CONTAINER_NAME=proxy ./apps/nginx_ip_whitelist.sh
```

### systemd

脚本会从以下来源推导宿主机 Nginx 配置：

- 运行中的 `nginx: master process` 的 `-c` 参数。
- `systemd` 的 `ExecStart -c`。
- `nginx -V --conf-path`。

检查配置：

```bash
nginx -t -c "$NGINX_CONF_FILE"
```

reload：

```bash
systemctl reload nginx
```

### file

当你显式指定 `NGINX_IPWL_ROOT`，或脚本从当前目录附近发现 `nginx.conf`，会进入 `file` 模式。

示例：

```bash
sudo NGINX_IPWL_ROOT=/home/projects/tools/apps/temp \
  ./apps/nginx_ip_whitelist.sh
```

如果这个目录是 Docker Nginx 的 bind mount 源，脚本会显示：

```text
关联 Docker 容器：nginx
```

此时 `check/reload` 会使用 Docker 容器执行。

如果没有关联 Docker 容器，`check` 需要本机安装 `nginx` 命令，`reload` 不会自动重载真实服务，避免误操作。

## 环境变量

| 环境变量 | 说明 |
|----------|------|
| `NGINX_IPWL_ROOT` | `nginx.conf` 所在目录 |
| `NGINX_IPWL_CONF_D` | 宿主机 `conf.d` 目录 |
| `NGINX_IPWL_CONTAINER_CONF_D` | Nginx 配置中使用的 `conf.d` 路径，默认从 `nginx.conf` 的 include 推导 |
| `NGINX_IPWL_INCLUDE_PATH` | 强制指定写入站点配置的 include 路径 |
| `NGINX_IPWL_RELATIVE_PATH` | 白名单片段相对路径，默认 `snippets/ip-whitelist.conf` |
| `NGINX_IPWL_SITE_CONF` | 指定站点配置文件名或绝对路径 |
| `NGINX_IPWL_SERVER_NAME` | 指定要管理的 `server_name` |
| `NGINX_IPWL_CONTAINER_NAME` | Docker 容器名，默认 `nginx` |
| `NGINX_IPWL_REVIEW_DIFF` | 是否在应用前预览 diff：`ask`、`1`、`0` |

### 指定测试目录

```bash
sudo NGINX_IPWL_ROOT=/home/projects/tools/apps/temp \
  ./apps/nginx_ip_whitelist.sh
```

### 指定 conf.d

```bash
sudo NGINX_IPWL_ROOT=/data/nginx \
  NGINX_IPWL_CONF_D=/data/nginx/conf.d \
  ./apps/nginx_ip_whitelist.sh
```

### 强制 include 路径

```bash
sudo NGINX_IPWL_INCLUDE_PATH=/etc/nginx/conf.d/snippets/ip-whitelist.conf \
  ./apps/nginx_ip_whitelist.sh enable
```

### 强制 diff review

```bash
sudo NGINX_IPWL_REVIEW_DIFF=1 ./apps/nginx_ip_whitelist.sh enable
```

关闭 diff review：

```bash
sudo NGINX_IPWL_REVIEW_DIFF=0 ./apps/nginx_ip_whitelist.sh enable
```

## 备份与回滚

启用或禁用白名单前，脚本会备份被修改的站点配置：

```text
原文件.bak.YYYYMMDDHHMMSS
```

例如：

```text
komari.lumiai.dpdns.org.conf.bak.20260617143746
```

修改后会自动执行 `nginx -t`。如果检查失败：

1. 脚本会用备份文件回滚配置。
2. 返回失败退出码。
3. 不会 reload Nginx。

脚本写回配置时会尽量保留原文件权限、属主和属组。

## 路径说明

状态页中有几个容易混淆的路径：

```text
conf.d 目录
配置内 conf.d
白名单文件
include 路径
```

含义如下：

- `conf.d 目录`：脚本在宿主机上修改的目录。
- `配置内 conf.d`：从 `nginx.conf` 的 `include` 推导出的路径，通常是容器内路径。
- `白名单文件`：脚本实际创建或修改的文件。
- `include 路径`：写进站点配置的路径。

Docker 场景中，宿主机文件可能是：

```text
/home/docker/nginx/conf/conf.d/snippets/ip-whitelist.conf
```

但站点配置中写入：

```nginx
include /etc/nginx/conf.d/snippets/ip-whitelist.conf;
```

这是因为 Nginx 在容器内运行，需要看到容器内路径。

纯 `file` 模式且未关联 Docker 时，include 路径会使用宿主机路径。

## 注意事项

- 白名单为空时不能启用。
- ACME challenge 路径会自动跳过，避免影响证书续签。
- 单行 `location / { ... }` 不会被自动修改，脚本会提示先改成多行结构。
- 多个 `server` 块都叫 `localhost` 时，状态和选择菜单会显示 `listen` 端口辅助区分。
- Docker 场景需要 Nginx 配置通过 bind mount 映射到宿主机；如果只在容器内部，脚本无法安全持久修改。
- 在 `/etc/nginx` 等系统目录操作通常需要 `sudo`。

