#!/bin/bash
set -u

DEFAULT_BASE_DIR="/opt/apps"
BASE_DIR="${APPS_HOME:-$DEFAULT_BASE_DIR}"
DRY_RUN="${APPS_DRY_RUN:-0}"
NGINX_CONF_DIR="${APPS_NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_SSL_DIR="${APPS_NGINX_SSL_DIR:-/etc/nginx/ssl}"
ACME_HOME="${APPS_ACME_HOME:-/root/.acme.sh}"
ACME_SH="${APPS_ACME_SH:-$ACME_HOME/acme.sh}"
CERT_MODE="${APPS_CERT_MODE:-cloudflare}"
SAFE_ROOT_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
PROJECT_URL="https://github.com/yhj945/tools"
TOOL_VERSION="v1.0.0"

if [[ "${EUID:-1}" == "0" ]]; then
    PATH="$SAFE_ROOT_PATH"
    export PATH
fi

RED=''
GREEN=''
YELLOW=''
CYAN=''
BOLD=''
NC=''

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
fi

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

need_root_for_base_dir() {
    if [[ "$BASE_DIR" == /opt/* && "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
        printf '请使用 root 运行此命令。\n' >&2
        exit 1
    fi
}

need_root() {
    if [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
        printf '请使用 root 运行此命令。\n' >&2
        exit 1
    fi
}

validate_service() {
    case "${1:-}" in
        hugo|wordpress|halo|typecho|komari|3x-ui) return 0 ;;
        *) printf '未知服务：%s\n' "${1:-}" >&2; return 1 ;;
    esac
}

is_safe_absolute_path() {
    local path="$1"

    [[ -n "$path" ]] || return 1
    [[ "$path" == /* ]] || return 1
    [[ "$path" != "/" ]] || return 1
    [[ ! "$path" =~ [[:space:]] ]] || return 1
    [[ "$path" != *..* ]] || return 1
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    return 0
}

validate_base_dir() {
    if ! is_safe_absolute_path "$BASE_DIR"; then
        printf 'APPS_HOME 路径不安全：%s\n' "$BASE_DIR" >&2
        return 1
    fi
    return 0
}

set_base_dir() {
    local path="$1"

    if ! is_safe_absolute_path "$path"; then
        printf '部署目录不安全：%s\n' "$path" >&2
        return 1
    fi
    BASE_DIR="$path"
}

validate_domain() {
    local domain="$1"

    if [[ -z "$domain" || ${#domain} -gt 253 || "$domain" =~ [^A-Za-z0-9.-] ]]; then
        printf '域名无效：%s\n' "$domain" >&2
        return 1
    fi
    if [[ "$domain" == .* || "$domain" == *. || "$domain" == *..* || "$domain" != *.* ]]; then
        printf '域名无效：%s\n' "$domain" >&2
        return 1
    fi
    if [[ "$domain" =~ (^|\.)- || "$domain" =~ -(\.|$) ]]; then
        printf '域名无效：%s\n' "$domain" >&2
        return 1
    fi
    return 0
}

service_default_port() {
    case "$1" in
        hugo) printf '8080\n' ;;
        wordpress) printf '8081\n' ;;
        halo) printf '8082\n' ;;
        typecho) printf '8083\n' ;;
        komari) printf '25774\n' ;;
        3x-ui) printf '2053\n' ;;
        *) validate_service "$1" || return $? ;;
    esac
}

is_valid_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_port() {
    if ! is_valid_port "${1:-}"; then
        printf '端口无效：%s\n' "${1:-}" >&2
        return 1
    fi
    return 0
}

env_value() {
    local env_file="$1"
    local key="$2"

    if [[ -f "$env_file" ]]; then
        awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$env_file"
    fi
}

service_port() {
    local service="$1"
    local dir env_port default_port

    validate_service "$service" || return $?
    default_port="$(service_default_port "$service")" || return $?
    if [[ -n "${SELECTED_PORT:-}" ]]; then
        printf '%s\n' "$SELECTED_PORT"
        return 0
    fi
    if [[ -n "${APPS_PORT:-}" ]]; then
        validate_port "$APPS_PORT" || return $?
        printf '%s\n' "$APPS_PORT"
        return 0
    fi
    dir="$(service_dir "$service")" || return $?
    env_port="$(env_value "$dir/.env" APP_PORT)"
    if [[ -n "$env_port" ]]; then
        validate_port "$env_port" || return $?
        printf '%s\n' "$env_port"
    else
        printf '%s\n' "$default_port"
    fi
}

service_access() {
    local service="$1"
    local port

    port="$(service_port "$service" 2>/dev/null || service_default_port "$service")"
    printf '127.0.0.1:%s\n' "$port"
}

service_upstream_name() {
    local service="$1"
    local domain="$2"
    local safe_service safe_domain hash

    safe_service="${service//-/_}"
    safe_domain="${domain//./_}"
    safe_domain="${safe_domain//-/_}"
    hash="$(printf '%s' "$service:$domain" | cksum)"
    hash="${hash%% *}"
    printf 'app_%s_%s_%s_backend\n' "$safe_service" "$safe_domain" "$hash" | tr '[:upper:]' '[:lower:]'
}

escape_domain_for_grep() {
    printf '%s\n' "$1" | sed 's/\./\\./g'
}

renew_marker() {
    printf 'APPS_RENEW:%s:%s\n' "$1" "$CERT_MODE"
}

standalone_renew_script_path() {
    local domain="$1"
    local ssl_dir

    ssl_dir="$(nginx_ssl_domain_dir "$domain")"
    printf '%s/renew-standalone.sh\n' "$ssl_dir"
}

renew_cron_line() {
    local domain="$1"
    local ssl_dir marker script_path

    validate_certificate_mode || return $?
    ssl_dir="$(nginx_ssl_domain_dir "$domain")"
    marker="$(renew_marker "$domain")"
    if [[ "$CERT_MODE" == "standalone" ]]; then
        script_path="$(standalone_renew_script_path "$domain")"
        printf '10 3 * * * PATH=%s timeout 20m "%s" >> %s/acme-renew.log 2>&1 # %s\n' "$SAFE_ROOT_PATH" "$script_path" "$ssl_dir" "$marker"
    else
        printf '10 3 * * * PATH=%s "%s" --renew -d %s --ecc --home "%s" >> %s/acme-renew.log 2>&1 # %s\n' "$SAFE_ROOT_PATH" "$ACME_SH" "$domain" "$ACME_HOME" "$ssl_dir" "$marker"
    fi
}

render_standalone_renew_script() {
    local domain="$1"

    cat <<EOF
#!/bin/bash
set -u
PATH=$SAFE_ROOT_PATH
export PATH
rc=0
was_active=0
restore_nginx() {
    if [[ \$was_active -eq 1 ]]; then
        systemctl start nginx >/dev/null 2>&1 || true
    fi
}
trap 'restore_nginx' INT TERM EXIT
if systemctl is-active --quiet nginx; then
    was_active=1
fi
systemctl stop nginx >/dev/null 2>&1 || true
"$ACME_SH" --renew -d $domain --ecc --home "$ACME_HOME"
rc=\$?
restore_nginx
trap - INT TERM EXIT
if [[ \$rc -eq 0 ]]; then
    systemctl reload nginx >/dev/null 2>&1 || true
fi
exit \$rc
EOF
}

write_standalone_renew_script() {
    local domain="$1"
    local script_path

    script_path="$(standalone_renew_script_path "$domain")"
    render_standalone_renew_script "$domain" > "$script_path" || return $?
    chmod 700 "$script_path"
}

service_dir() {
    local service="$1"
    validate_service "$service" || return $?
    validate_base_dir || return $?
    printf '%s/%s\n' "${BASE_DIR%/}" "$service"
}

compose_cmd() {
    if command -v docker >/dev/null 2>&1 && docker compose version </dev/null >/dev/null 2>&1; then
        printf '%s\n' "docker compose"
        return 0
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        printf '%s\n' "docker-compose"
        return 0
    fi
    return 1
}

random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    elif [[ -r /dev/urandom ]]; then
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32
        printf '\n'
    else
        printf '没有可用的安全随机数来源。\n' >&2
        return 1
    fi
}

service_default_username() {
    case "$1" in
        komari) printf 'admin\n' ;;
        *) printf '\n' ;;
    esac
}

service_default_web_base_path() {
    case "$1" in
        3x-ui) printf '/\n' ;;
        *) printf '\n' ;;
    esac
}

is_valid_username() {
    local username="$1"

    [[ -n "$username" ]] || return 1
    [[ ${#username} -le 64 ]] || return 1
    [[ "$username" =~ ^[A-Za-z0-9._@-]+$ ]]
}

validate_username() {
    if ! is_valid_username "${1:-}"; then
        printf '用户名无效：%s\n' "${1:-}" >&2
        return 1
    fi
    return 0
}

is_valid_web_base_path() {
    local path="$1"

    [[ -n "$path" ]] || return 1
    [[ "$path" == /* ]] || return 1
    [[ "$path" != *".."* ]] || return 1
    [[ "$path" != *[[:space:]]* ]] || return 1
    [[ "$path" =~ ^/[A-Za-z0-9._~/-]*$ ]] || return 1
    return 0
}

validate_web_base_path() {
    if ! is_valid_web_base_path "${1:-}"; then
        printf '访问路径无效：%s\n' "${1:-}" >&2
        return 1
    fi
    return 0
}

load_project_config() {
    local service="$1"
    local dir="$2"
    local env_file="$dir/.env"
    local default_port default_username default_web_base_path

    default_port="$(service_default_port "$service")" || return $?
    default_username="$(service_default_username "$service")"
    default_web_base_path="$(service_default_web_base_path "$service")"

    APP_PORT_VALUE="${SELECTED_PORT:-${APPS_PORT:-$(env_value "$env_file" APP_PORT)}}"
    APP_DOMAIN_VALUE="${SELECTED_DOMAIN:-${APPS_DOMAIN:-$(env_value "$env_file" APP_DOMAIN)}}"
    APP_USERNAME_VALUE="${SELECTED_USERNAME:-${APPS_USERNAME:-$(env_value "$env_file" APP_USERNAME)}}"
    APP_PASSWORD_VALUE="${SELECTED_PASSWORD:-${APPS_PASSWORD:-$(env_value "$env_file" APP_PASSWORD)}}"
    APP_WEB_BASE_PATH_VALUE="${SELECTED_WEB_BASE_PATH:-${APPS_WEB_BASE_PATH:-$(env_value "$env_file" APP_WEB_BASE_PATH)}}"

    [[ -n "$APP_PORT_VALUE" ]] || APP_PORT_VALUE="$default_port"
    [[ -n "$APP_USERNAME_VALUE" ]] || APP_USERNAME_VALUE="$default_username"
    [[ -n "$APP_WEB_BASE_PATH_VALUE" ]] || APP_WEB_BASE_PATH_VALUE="$default_web_base_path"
    if [[ -z "$APP_PASSWORD_VALUE" ]]; then
        APP_PASSWORD_VALUE="$(random_password)" || return $?
    fi

    validate_port "$APP_PORT_VALUE" || return $?
    if [[ -n "$APP_DOMAIN_VALUE" ]]; then
        validate_domain "$APP_DOMAIN_VALUE" || return $?
    fi
    if [[ -n "$APP_USERNAME_VALUE" ]]; then
        validate_username "$APP_USERNAME_VALUE" || return $?
    fi
    if [[ -n "$APP_WEB_BASE_PATH_VALUE" ]]; then
        validate_web_base_path "$APP_WEB_BASE_PATH_VALUE" || return $?
    fi

    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p "$dir" || return $?
        {
            printf 'APP_NAME=%s\n' "$service"
            printf 'APP_PORT=%s\n' "$APP_PORT_VALUE"
            printf 'APP_DOMAIN=%s\n' "$APP_DOMAIN_VALUE"
            printf 'APP_USERNAME=%s\n' "$APP_USERNAME_VALUE"
            printf 'APP_PASSWORD=%s\n' "$APP_PASSWORD_VALUE"
            printf 'APP_WEB_BASE_PATH=%s\n' "$APP_WEB_BASE_PATH_VALUE"
        } > "$env_file" || return $?
        chmod 600 "$env_file" || return $?
    fi
}

list_services() {
    printf '支持的服务：\n\n'
    printf '  1) %-10s %-18s %-24s %-16s %s\n' \
        "hugo" "静态博客/页面" "nginx:alpine" "$(service_access hugo)" "$(service_deploy_state hugo)"
    printf '  2) %-10s %-18s %-24s %-16s %s\n' \
        "wordpress" "WordPress 站点" "WordPress + MariaDB" "$(service_access wordpress)" "$(service_deploy_state wordpress)"
    printf '  3) %-10s %-18s %-24s %-16s %s\n' \
        "halo" "Halo 博客" "Halo + PostgreSQL" "$(service_access halo)" "$(service_deploy_state halo)"
    printf '  4) %-10s %-18s %-24s %-16s %s\n' \
        "typecho" "Typecho 博客" "Typecho + MariaDB" "$(service_access typecho)" "$(service_deploy_state typecho)"
    printf '  5) %-10s %-18s %-24s %-16s %s\n' \
        "komari" "服务器监控面板" "Komari" "$(service_access komari)" "$(service_deploy_state komari)"
    printf '  6) %-10s %-18s %-24s %-16s %s\n' \
        "3x-ui" "Xray 管理面板" "3X-UI" "$(service_access 3x-ui)" "$(service_deploy_state 3x-ui)"
    printf '\n'
    printf '默认部署目录：%s\n' "$BASE_DIR"
    printf '可通过 APPS_HOME 修改部署目录。\n'
}

service_display_name() {
    case "$1" in
        hugo) printf 'Hugo 静态博客\n' ;;
        wordpress) printf 'WordPress\n' ;;
        halo) printf 'Halo\n' ;;
        typecho) printf 'Typecho\n' ;;
        komari) printf 'Komari 监控面板\n' ;;
        3x-ui) printf '3X-UI 面板\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

service_deploy_state() {
    local service="$1"
    local dir="${BASE_DIR%/}/$service"

    validate_service "$service" >/dev/null 2>&1 || {
        printf '未知\n'
        return 1
    }
    if [[ -f "$dir/docker-compose.yml" ]]; then
        printf '已部署\n'
    else
        printf '未部署\n'
    fi
}

show_header() {
    printf '\n'
    printf '%b' "$CYAN"
    cat <<'EOF'
 ___           _        _ _      _
|_ _|_ __  ___| |_ __ _| | |    / \   _ __  _ __  ___
 | || '_ \/ __| __/ _` | | |   / _ \ | '_ \| '_ \/ __|
 | || | | \__ \ || (_| | | |  / ___ \| |_) | |_) \__ \
|___|_| |_|___/\__\__,_|_|_| /_/   \_\ .__/| .__/|___/
                                     |_|   |_|
EOF
    printf '%b' "$NC"
    printf '%b\n' "${GREEN}Docker Compose 应用安装、反向代理与证书配置工具${NC}"
    printf 'GitHub: %s  Version: %s  Script: apps/install_apps.sh\n' "$PROJECT_URL" "$TOOL_VERSION"
    printf '%b\n' "${BOLD}------------------------------------------------------------${NC}"
    printf '%b\n' "${BOLD}[ 应用安装工具 控制台 ]${NC}"
    printf '%b\n\n' "${BOLD}------------------------------------------------------------${NC}"
}

show_section() {
    printf '\n'
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}$1${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
}

show_menu_status() {
    local compose_status docker_status service state
    local services=(hugo wordpress halo typecho komari 3x-ui)

    if command -v docker >/dev/null 2>&1; then
        docker_status="${GREEN}✓${NC} Docker 已安装"
    else
        docker_status="${YELLOW}!${NC} Docker 未安装"
    fi
    if compose_cmd >/dev/null 2>&1; then
        compose_status="${GREEN}✓${NC} Docker Compose 可用"
    else
        compose_status="${YELLOW}!${NC} Docker Compose 不可用"
    fi

    printf '%b\n' "$docker_status"
    printf '%b\n' "$compose_status"
    if validate_base_dir >/dev/null 2>&1; then
        printf '  部署目录：%s\n' "$BASE_DIR"
    else
        printf '  部署目录不安全：%s\n' "$BASE_DIR"
    fi
    printf '  默认证书模式：%s\n' "$CERT_MODE"
    printf '\n服务部署状态：\n'
    for service in "${services[@]}"; do
        state="$(service_deploy_state "$service")"
        if [[ "$state" == "已部署" ]]; then
            printf '  %b %-10s %s\n' "${GREEN}✓${NC}" "$service" "$state"
        else
            printf '  %b %-10s %s\n' "${YELLOW}!${NC}" "$service" "$state"
        fi
    done
}

render_hugo_compose() {
    local port="$1"

    cat <<EOF
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: app-hugo-site
    restart: unless-stopped
    ports:
      - "127.0.0.1:$port:80"
    volumes:
      - ./public:/usr/share/nginx/html:ro
EOF
}

render_wordpress_compose() {
    local password="$1"
    local port="$2"

    cat <<EOF
services:
  mariadb:
    image: mariadb:11
    container_name: app-wordpress-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wordpress
      MARIADB_PASSWORD: $password
      MARIADB_ROOT_PASSWORD: $password
    volumes:
      - ./data/mariadb:/var/lib/mysql
  wordpress:
    image: wordpress:6-apache
    container_name: app-wordpress
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - "127.0.0.1:$port:80"
    environment:
      WORDPRESS_DB_HOST: mariadb:3306
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: $password
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - ./data/wordpress:/var/www/html
EOF
}

render_halo_compose() {
    local password="$1"
    local port="$2"
    local domain="${3:-}"
    local external_url="http://localhost:$port/"

    if [[ -n "$domain" ]]; then
        external_url="https://$domain/"
    fi

    cat <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: app-halo-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: halo
      POSTGRES_USER: halo
      POSTGRES_PASSWORD: $password
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
  halo:
    image: halohub/halo:2
    container_name: app-halo
    restart: unless-stopped
    depends_on:
      - postgres
    ports:
      - "127.0.0.1:$port:8090"
    environment:
      SPRING_R2DBC_URL: r2dbc:pool:postgresql://postgres:5432/halo
      SPRING_R2DBC_USERNAME: halo
      SPRING_R2DBC_PASSWORD: $password
      SPRING_SQL_INIT_PLATFORM: postgresql
      HALO_EXTERNAL_URL: $external_url
    volumes:
      - ./data/halo:/root/.halo2
EOF
}

render_typecho_compose() {
    local password="$1"
    local port="$2"

    cat <<EOF
services:
  mariadb:
    image: mariadb:11
    container_name: app-typecho-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: typecho
      MARIADB_USER: typecho
      MARIADB_PASSWORD: $password
      MARIADB_ROOT_PASSWORD: $password
    volumes:
      - ./data/mariadb:/var/lib/mysql
  typecho:
    image: joyqi/typecho:nightly-php8.2-apache
    container_name: app-typecho
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - "127.0.0.1:$port:80"
    environment:
      TYPECHO_DB_ADAPTER: Pdo_Mysql
      TYPECHO_DB_HOST: mariadb
      TYPECHO_DB_PORT: 3306
      TYPECHO_DB_USER: typecho
      TYPECHO_DB_PASSWORD: $password
      TYPECHO_DB_DATABASE: typecho
    volumes:
      - ./data/typecho:/app/usr
EOF
}

render_komari_compose() {
    local password="$1"
    local port="$2"
    local username="$3"

    cat <<EOF
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: app-komari
    restart: unless-stopped
    ports:
      - "127.0.0.1:$port:25774"
    environment:
      ADMIN_USERNAME: $username
      ADMIN_PASSWORD: $password
    volumes:
      - ./data:/app/data
EOF
}

render_3x_ui_compose() {
    local port="$1"
    local web_base_path="$2"

    cat <<EOF
services:
  3xui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: app-3x-ui
    restart: unless-stopped
    tty: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "127.0.0.1:$port:$port"
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      XUI_ENABLE_FAIL2BAN: "true"
      XUI_PORT: "$port"
      XUI_INIT_WEB_BASE_PATH: "$web_base_path"
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert
EOF
}

render_compose() {
    local service="$1"
    local password="${2:-change-me}"
    local domain="${3:-}"
    local port="${4:-}"
    local username="${5:-}"
    local web_base_path="${6:-}"

    validate_service "$service" || return $?
    [[ -n "$port" ]] || port="$(service_default_port "$service")"
    case "$service" in
        hugo) render_hugo_compose "$port" ;;
        wordpress) render_wordpress_compose "$password" "$port" ;;
        halo) render_halo_compose "$password" "$port" "$domain" ;;
        typecho) render_typecho_compose "$password" "$port" ;;
        komari) render_komari_compose "$password" "$port" "${username:-admin}" ;;
        3x-ui) render_3x_ui_compose "$port" "${web_base_path:-/}" ;;
    esac
}

nginx_conf_path() {
    local service="$1"
    local domain="$2"

    printf '%s/app-%s-%s.conf\n' "${NGINX_CONF_DIR%/}" "$service" "$domain"
}

nginx_ssl_domain_dir() {
    local domain="$1"

    printf '%s/%s\n' "${NGINX_SSL_DIR%/}" "$domain"
}

validate_proxy_paths() {
    local path

    for path in "$NGINX_CONF_DIR" "$NGINX_SSL_DIR" "$ACME_HOME" "$ACME_SH"; do
        if ! is_safe_absolute_path "$path"; then
            printf '代理相关路径不安全：%s\n' "$path" >&2
            return 1
        fi
    done
    return 0
}

validate_certificate_mode() {
    case "$CERT_MODE" in
        cloudflare|standalone) return 0 ;;
        *) printf '未知证书模式：%s\n' "$CERT_MODE" >&2; return 1 ;;
    esac
}

render_nginx_config() {
    local service="$1"
    local domain="$2"
    local port upstream ssl_dir map_var

    port="$(service_port "$service")" || return $?
    upstream="$(service_upstream_name "$service" "$domain")"
    ssl_dir="$(nginx_ssl_domain_dir "$domain")"
    map_var="${upstream}_connection_upgrade"

    cat <<EOF
# 应用服务反向代理：$service
upstream $upstream {
    server 127.0.0.1:$port;
    keepalive 32;
}

map \$http_upgrade \$$map_var {
    default upgrade;
    '' close;
}

server {
    server_name $domain;
    server_tokens off;

    client_max_body_size 256m;
    send_timeout 600s;

    listen [::]:443 ssl;
    listen 443 ssl;

    ssl_certificate $ssl_dir/fullchain.cer;
    ssl_certificate_key $ssl_dir/private.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://$upstream;
        proxy_redirect off;
        proxy_set_header Host $domain;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Original-URI \$request_uri;

        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 3600s;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$$map_var;

        proxy_buffering off;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    server_tokens off;

    return 301 https://$domain\$request_uri;
}
EOF
}

render_proxy_dry_run() {
    local service="$1"
    local domain="$2"
    local conf_path ssl_dir escaped_domain issue_command renew_line script_path

    validate_certificate_mode || return $?
    conf_path="$(nginx_conf_path "$service" "$domain")"
    ssl_dir="$(nginx_ssl_domain_dir "$domain")"
    escaped_domain="$(escape_domain_for_grep "$domain")"
    renew_line="$(renew_cron_line "$domain")" || return $?
    if [[ "$CERT_MODE" == "standalone" ]]; then
        issue_command="$ACME_SH --issue --server letsencrypt --standalone -d $domain --keylength ec-256 --home $ACME_HOME"
        script_path="$(standalone_renew_script_path "$domain")"
    else
        issue_command="$ACME_SH --issue --server letsencrypt --dns dns_cf -d $domain --keylength ec-256 --home $ACME_HOME"
    fi

    printf '[DRY-RUN] 将写入 Nginx 配置：%s\n' "$conf_path"
    render_nginx_config "$service" "$domain" || return $?
    cat <<EOF
[DRY-RUN] 证书模式：$CERT_MODE
[DRY-RUN] 将使用 acme.sh 签发并安装证书：
$ACME_SH --set-default-ca --server letsencrypt --home $ACME_HOME
mkdir -p $ssl_dir
chmod 700 $ssl_dir
EOF
    if [[ "$CERT_MODE" == "standalone" ]]; then
        printf 'systemctl stop nginx\n'
    fi
    cat <<EOF
$issue_command
EOF
    if [[ "$CERT_MODE" == "standalone" ]]; then
        printf 'systemctl start nginx\n'
        printf '[DRY-RUN] 将写入 standalone 续期脚本：%s\n' "$script_path"
        render_standalone_renew_script "$domain"
    fi
    cat <<EOF
$ACME_SH --install-cert -d $domain --ecc --home $ACME_HOME \\
  --fullchain-file $ssl_dir/fullchain.cer \\
  --key-file $ssl_dir/private.key \\
  --reloadcmd "systemctl reload nginx"
chmod 600 $ssl_dir/private.key
chmod 644 $ssl_dir/fullchain.cer
[DRY-RUN] 将添加幂等的 root crontab 续期任务：
(crontab -l 2>/dev/null || true) > /tmp/apps.cron
cp -a /tmp/apps.cron /tmp/apps.cron.new
grep -v 'APPS_RENEW:$escaped_domain:' /tmp/apps.cron.new > /tmp/apps.cron.filtered
mv /tmp/apps.cron.filtered /tmp/apps.cron.new
cat >> /tmp/apps.cron.new <<'CRON_EOF'
$renew_line
CRON_EOF
crontab /tmp/apps.cron.new
nginx -t
systemctl reload nginx
EOF
}

require_cloudflare_credentials() {
    local missing=""

    if [[ -z "${CF_Token:-}" ]]; then
        missing="CF_Token"
    fi
    if [[ -z "${CF_Zone_ID:-}" ]]; then
        if [[ -n "$missing" ]]; then
            missing="$missing CF_Zone_ID"
        else
            missing="CF_Zone_ID"
        fi
    fi
    if [[ -n "$missing" ]]; then
        printf '缺少 Cloudflare DNS-01 凭据环境变量：%s\n' "$missing" >&2
        return 1
    fi
    return 0
}

ensure_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update || return $?
        apt-get install -y nginx || return $?
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx || return $?
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx || return $?
    else
        printf '未找到 Nginx，请先手动安装 Nginx。\n' >&2
        return 1
    fi
}

path_mode() {
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

path_owner_uid() {
    if stat -f '%u' "$1" >/dev/null 2>&1; then
        stat -f '%u' "$1"
    else
        stat -c '%u' "$1"
    fi
}

is_group_or_other_writable() {
    local mode

    mode="$(path_mode "$1")" || return 1
    [[ $((8#$mode & 022)) -ne 0 ]]
}

is_root_owned() {
    [[ "$(path_owner_uid "$1")" == "0" ]]
}

validate_root_owned_path_chain() {
    local path="$1"
    local dir component current parent resolved_dir

    dir="$(dirname "$path")"
    [[ "$dir" == /* ]] || return 1
    current=""
    IFS='/' read -r -a components <<< "${dir#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        parent="${current:-/}"
        current="${current}/${component}"
        if [[ -L "$current" ]]; then
            if ! is_root_owned "$parent" || is_group_or_other_writable "$parent"; then
                printf 'acme.sh 父目录不安全：%s\n' "$current" >&2
                return 1
            fi
            continue
        fi
        if [[ ! -d "$current" ]]; then
            printf 'acme.sh 父目录不安全：%s\n' "$current" >&2
            return 1
        fi
        if ! is_root_owned "$current" || is_group_or_other_writable "$current"; then
            printf 'acme.sh 父目录不安全：%s\n' "$current" >&2
            return 1
        fi
    done

    resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
    while [[ -n "$resolved_dir" && "$resolved_dir" != "/" ]]; do
        if ! is_root_owned "$resolved_dir" || is_group_or_other_writable "$resolved_dir"; then
            printf 'acme.sh 父目录不安全：%s\n' "$resolved_dir" >&2
            return 1
        fi
        resolved_dir="$(dirname "$resolved_dir")"
    done
    return 0
}

validate_root_executable_path() {
    local path="$1"

    if [[ ! -f "$path" || ! -x "$path" || -L "$path" ]]; then
        printf 'acme.sh 路径不安全：%s\n' "$path" >&2
        return 1
    fi
    if ! is_root_owned "$path"; then
        printf 'acme.sh 所有者不安全：%s\n' "$path" >&2
        return 1
    fi
    if is_group_or_other_writable "$path"; then
        printf 'acme.sh 权限不安全：%s\n' "$path" >&2
        return 1
    fi
    validate_root_owned_path_chain "$path" || return $?
    return 0
}

validate_acme_home_path() {
    if [[ ! -d "$ACME_HOME" || -L "$ACME_HOME" ]]; then
        printf 'acme.sh home 不安全：%s\n' "$ACME_HOME" >&2
        return 1
    fi
    if ! is_root_owned "$ACME_HOME" || is_group_or_other_writable "$ACME_HOME"; then
        printf 'acme.sh home 不安全：%s\n' "$ACME_HOME" >&2
        return 1
    fi
    validate_root_owned_path_chain "$ACME_HOME" || return $?
    return 0
}

canonicalize_acme_paths() {
    local home_dir script_dir script_name

    home_dir="$(cd "$ACME_HOME" 2>/dev/null && pwd -P)" || return 1
    script_dir="$(cd "$(dirname "$ACME_SH")" 2>/dev/null && pwd -P)" || return 1
    script_name="$(basename "$ACME_SH")"
    ACME_HOME="$home_dir"
    ACME_SH="$script_dir/$script_name"
    if ! is_safe_absolute_path "$ACME_HOME" || ! is_safe_absolute_path "$ACME_SH"; then
        printf 'acme.sh 路径不安全。\n' >&2
        return 1
    fi
    validate_acme_home_path || return $?
    validate_root_executable_path "$ACME_SH"
}

ensure_acme_sh() {
    if [[ -e "$ACME_SH" ]]; then
        validate_acme_home_path || return $?
        validate_root_executable_path "$ACME_SH" || return $?
        canonicalize_acme_paths
        return $?
    fi

    printf '未找到 acme.sh：%s\n' "$ACME_SH" >&2
    printf '请先安装 acme.sh，然后重新执行此命令。\n' >&2
    return 1
}

update_halo_external_url() {
    local domain="$1"
    local dir compose_file cmd

    dir="$(service_dir halo)" || return $?
    compose_file="$dir/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        return 0
    fi

    python3 - "$compose_file" "$domain" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
domain = sys.argv[2]
text = path.read_text(encoding="utf-8")
new_line = f"      HALO_EXTERNAL_URL: https://{domain}/"
lines = text.splitlines()
updated = []
replaced = False
for line in lines:
    if "HALO_EXTERNAL_URL:" in line:
        updated.append(new_line)
        replaced = True
    else:
        updated.append(line)
if not replaced:
    updated.append(new_line)
path.write_text("\n".join(updated) + "\n", encoding="utf-8")
PY
    cmd="$(compose_cmd)" || return 0
    (cd "$dir" && $cmd up -d)
}

add_renew_cron() {
    local domain="$1"
    local escaped_domain cron_file new_cron filtered_cron renew_line

    validate_certificate_mode || return $?
    escaped_domain="$(escape_domain_for_grep "$domain")"
    renew_line="$(renew_cron_line "$domain")" || return $?
    cron_file="$(mktemp)" || return $?
    new_cron="$(mktemp)" || {
        rm -f "$cron_file"
        return 1
    }
    filtered_cron="$(mktemp)" || {
        rm -f "$cron_file" "$new_cron"
        return 1
    }

    (crontab -l 2>/dev/null || true) > "$cron_file" || {
        rm -f "$cron_file" "$new_cron" "$filtered_cron"
        return 1
    }
    cp -a "$cron_file" "$new_cron" || {
        rm -f "$cron_file" "$new_cron" "$filtered_cron"
        return 1
    }
    grep -v "APPS_RENEW:$escaped_domain:" "$new_cron" > "$filtered_cron" || true
    mv "$filtered_cron" "$new_cron" || {
        rm -f "$cron_file" "$new_cron" "$filtered_cron"
        return 1
    }
    printf '%s\n' "$renew_line" >> "$new_cron" || {
        rm -f "$cron_file" "$new_cron"
        return 1
    }
    crontab "$new_cron"
    local rc=$?
    rm -f "$cron_file" "$new_cron"
    return $rc
}

configure_proxy() {
    local service="${1:-}"
    local domain="${2:-}"
    local conf_path ssl_dir rc

    validate_service "$service" || exit $?
    validate_domain "$domain" || exit $?
    validate_proxy_paths || exit $?
    validate_certificate_mode || exit $?

    if [[ "$DRY_RUN" == "1" ]]; then
        render_proxy_dry_run "$service" "$domain"
        return $?
    fi

    if [[ "$CERT_MODE" == "cloudflare" ]]; then
        require_cloudflare_credentials || exit $?
    fi
    need_root
    ensure_nginx || return $?
    ensure_acme_sh || return $?

    conf_path="$(nginx_conf_path "$service" "$domain")"
    ssl_dir="$(nginx_ssl_domain_dir "$domain")"
    mkdir -p "$NGINX_CONF_DIR" "$ssl_dir" || return $?
    chmod 700 "$ssl_dir" || return $?

    "$ACME_SH" --set-default-ca --server letsencrypt --home "$ACME_HOME" || return $?
    if [[ "$CERT_MODE" == "standalone" ]]; then
        local was_active=0
        restore_standalone_issue_nginx() {
            if [[ $was_active -eq 1 ]]; then
                systemctl start nginx 2>/dev/null || true
            fi
        }
        if systemctl is-active --quiet nginx; then
            was_active=1
        fi
        trap 'restore_standalone_issue_nginx' EXIT
        trap 'restore_standalone_issue_nginx; trap - INT TERM EXIT; exit 130' INT
        trap 'restore_standalone_issue_nginx; trap - INT TERM EXIT; exit 143' TERM
        systemctl stop nginx 2>/dev/null || true
        "$ACME_SH" --issue --server letsencrypt --standalone -d "$domain" --keylength ec-256 --home "$ACME_HOME"
        rc=$?
        restore_standalone_issue_nginx
        trap - INT TERM EXIT
        [[ $rc -eq 0 ]] || return $rc
    else
        "$ACME_SH" --issue --server letsencrypt --dns dns_cf -d "$domain" --keylength ec-256 --home "$ACME_HOME" || return $?
        unset CF_Token CF_Zone_ID
    fi
    "$ACME_SH" --install-cert -d "$domain" --ecc --home "$ACME_HOME" \
        --fullchain-file "$ssl_dir/fullchain.cer" \
        --key-file "$ssl_dir/private.key" \
        --reloadcmd "systemctl reload nginx" || return $?
    chmod 600 "$ssl_dir/private.key" || return $?
    chmod 644 "$ssl_dir/fullchain.cer" || return $?
    if [[ "$CERT_MODE" == "standalone" ]]; then
        write_standalone_renew_script "$domain" || return $?
    fi

    render_nginx_config "$service" "$domain" > "$conf_path" || return $?
    chmod 644 "$conf_path" || return $?
    nginx -t || return $?
    systemctl enable --now nginx 2>/dev/null || true
    systemctl reload nginx || return $?
    add_renew_cron "$domain" || return $?
    if [[ "$service" == "halo" ]]; then
        update_halo_external_url "$domain" || return $?
    fi
    log "已为 $service 配置 HTTPS 反向代理：https://$domain/"
}

ensure_hugo_public() {
    local dir="$1"

    mkdir -p "$dir/public" || return $?
    if [[ ! -f "$dir/public/index.html" ]]; then
        cat > "$dir/public/index.html" <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hugo 站点</title>
</head>
<body>
  <main>
    <h1>Hugo 站点</h1>
    <p>请将 Hugo 生成的 public 目录内容替换到这里。</p>
  </main>
</body>
</html>
EOF
    fi
}

deploy_service() {
    local service="${1:-}"
    local domain="${2:-}"
    local dir compose_password cmd

    validate_service "$service" || exit $?
    if [[ -n "${APPS_PORT:-}" ]]; then
        validate_port "$APPS_PORT" || exit $?
    fi
    if [[ -z "$domain" && -n "${APPS_DOMAIN:-}" ]]; then
        domain="$APPS_DOMAIN"
    fi
    if [[ -n "$domain" ]]; then
        validate_domain "$domain" || exit $?
        validate_proxy_paths || exit $?
        validate_certificate_mode || exit $?
        if [[ "$DRY_RUN" != "1" && "$CERT_MODE" == "cloudflare" ]]; then
            require_cloudflare_credentials || exit $?
        fi
    fi
    dir="$(service_dir "$service")" || exit $?
    SELECTED_DOMAIN="$domain"
    load_project_config "$service" "$dir" || exit $?
    SELECTED_PORT="$APP_PORT_VALUE"

    if [[ "$DRY_RUN" == "1" ]]; then
        compose_password="$APP_PASSWORD_VALUE"
        if [[ -f "$dir/.env" ]] && grep -q '^APP_PASSWORD=' "$dir/.env"; then
            compose_password="<redacted-existing-password>"
        fi
        printf '[DRY-RUN] 将在 %s 部署 %s\n' "$dir" "$service"
        render_compose "$service" "$compose_password" "$APP_DOMAIN_VALUE" "$APP_PORT_VALUE" "$APP_USERNAME_VALUE" "$APP_WEB_BASE_PATH_VALUE" || return $?
        if [[ -n "$domain" ]]; then
            validate_proxy_paths || return $?
            render_proxy_dry_run "$service" "$domain" || return $?
        fi
        return 0
    fi

    need_root_for_base_dir
    mkdir -p "$dir" || return $?
    if [[ "$service" == "hugo" ]]; then
        ensure_hugo_public "$dir" || return $?
    fi
    render_compose "$service" "$APP_PASSWORD_VALUE" "$APP_DOMAIN_VALUE" "$APP_PORT_VALUE" "$APP_USERNAME_VALUE" "$APP_WEB_BASE_PATH_VALUE" > "$dir/docker-compose.yml" || return $?
    chmod 600 "$dir/docker-compose.yml" || return $?

    cmd="$(compose_cmd)" || {
        printf '未找到 Docker Compose，请先运行 install-docker。\n' >&2
        exit 1
    }
    (cd "$dir" && $cmd up -d)
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        return $rc
    fi
    log "已部署 $service 到 $dir"
    if [[ -n "$domain" ]]; then
        configure_proxy "$service" "$domain" || return $?
    fi
}

install_docker() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '[DRY-RUN] 将使用检测到的包管理器安装 Docker\n'
        return 0
    fi

    need_root
    if command -v docker >/dev/null 2>&1 && compose_cmd >/dev/null 2>&1; then
        log "Docker 和 Docker Compose 已安装"
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update || return $?
        apt-get install -y docker.io docker-compose-plugin || return $?
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker docker-compose-plugin || return $?
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker docker-compose-plugin || return $?
    else
        printf '不支持当前包管理器，请手动安装 Docker。\n' >&2
        exit 1
    fi
    systemctl enable --now docker 2>/dev/null || true
}

service_action() {
    local action="$1"
    local service="${2:-}"
    local dir cmd rc

    validate_service "$service" || exit $?
    dir="$(service_dir "$service")" || exit $?
    if [[ ! -d "$dir" ]]; then
        printf '服务尚未部署：%s\n' "$service" >&2
        exit 1
    fi

    cmd="$(compose_cmd)" || {
        printf '未找到 Docker Compose。\n' >&2
        exit 1
    }

    case "$action" in
        status) (cd "$dir" && $cmd ps) ;;
        logs) (cd "$dir" && $cmd logs -f) ;;
        stop) (cd "$dir" && $cmd stop) ;;
        uninstall)
            need_root_for_base_dir
            (cd "$dir" && $cmd down)
            rc=$?
            [[ $rc -eq 0 ]] || return $rc
            rm -rf "$dir"
            ;;
    esac
}

verify_service() {
    local service="${1:-}"
    local dir cmd output

    validate_service "$service" || exit $?
    dir="$(service_dir "$service")" || exit $?
    if [[ ! -d "$dir" || ! -f "$dir/docker-compose.yml" ]]; then
        printf '服务尚未部署：%s\n' "$service" >&2
        exit 1
    fi

    cmd="$(compose_cmd)" || {
        printf '未找到 Docker Compose。\n' >&2
        exit 1
    }
    output="$(cd "$dir" && $cmd ps 2>&1)" || {
        printf '%s\n' "$output" >&2
        printf '服务不健康：%s\n' "$service" >&2
        exit 1
    }

    if printf '%s\n' "$output" | grep -Eiq '(^|[[:space:]])(exited|dead|unhealthy|restarting)([[:space:]]|$)'; then
        printf '%s\n' "$output"
        printf '服务不健康：%s\n' "$service" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -Eiq '(running|up|healthy)'; then
        printf '%s\n' "$output"
        printf '服务不健康：%s\n' "$service" >&2
        exit 1
    fi

    printf '%s\n' "$output"
    printf '%s 验证通过\n' "$service"
}

check_script() {
    validate_certificate_mode || return $?
    printf '%s\n' "install_apps.sh 检查通过"
}

check_environment() {
    local rc=0

    printf '环境检查：\n'
    if command -v docker >/dev/null 2>&1; then
        printf '  Docker：可用\n'
    else
        printf '  Docker：不可用，请选择“安装 Docker”。\n'
        rc=1
    fi
    if compose_cmd >/dev/null 2>&1; then
        printf '  Docker Compose：可用\n'
    else
        printf '  Docker Compose：不可用，请先安装 Docker Compose 插件。\n'
        rc=1
    fi
    if command -v nginx >/dev/null 2>&1; then
        printf '  Nginx：可用\n'
    else
        printf '  Nginx：未安装；只有配置 HTTPS 反向代理时才需要。\n'
    fi
    if [[ -x "$ACME_SH" ]]; then
        printf '  acme.sh：可用（%s）\n' "$ACME_SH"
    else
        printf '  acme.sh：未检测到；只有配置 HTTPS 证书时才需要。\n'
    fi
    validate_base_dir || rc=1
    validate_certificate_mode || rc=1
    return $rc
}

MENU_VALUE=""
MENU_CANCELLED=0
MENU_RETURNED=0
SELECTED_PORT=""
SELECTED_DOMAIN=""
SELECTED_USERNAME=""
SELECTED_PASSWORD=""
SELECTED_WEB_BASE_PATH=""
APP_PORT_VALUE=""
APP_DOMAIN_VALUE=""
APP_USERNAME_VALUE=""
APP_PASSWORD_VALUE=""
APP_WEB_BASE_PATH_VALUE=""

pause_menu() {
    printf '\n按回车键继续...'
    IFS= read -r _ || true
    printf '\n'
}

prompt_service_name() {
    local choice state

    MENU_VALUE=""
    MENU_CANCELLED=0
    MENU_RETURNED=0
    while true; do
        printf '请选择服务：\n'
        state="$(service_deploy_state hugo)"
        printf '  1) hugo       - Hugo 静态博客（%s）\n' "$state"
        state="$(service_deploy_state wordpress)"
        printf '  2) wordpress  - WordPress 站点（%s）\n' "$state"
        state="$(service_deploy_state halo)"
        printf '  3) halo       - Halo 博客（%s）\n' "$state"
        state="$(service_deploy_state typecho)"
        printf '  4) typecho    - Typecho 博客（%s）\n' "$state"
        state="$(service_deploy_state komari)"
        printf '  5) komari     - Komari 监控面板（%s）\n' "$state"
        state="$(service_deploy_state 3x-ui)"
        printf '  6) 3x-ui      - 3X-UI 面板（%s）\n' "$state"
        printf '  0) 返回\n'
        printf '请输入选项 [1-6]：'
        IFS= read -r choice || return 1
        case "$choice" in
            1) MENU_VALUE="hugo"; return 0 ;;
            2) MENU_VALUE="wordpress"; return 0 ;;
            3) MENU_VALUE="halo"; return 0 ;;
            4) MENU_VALUE="typecho"; return 0 ;;
            5) MENU_VALUE="komari"; return 0 ;;
            6) MENU_VALUE="3x-ui"; return 0 ;;
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                continue
                ;;
            *)
                printf '服务选项无效：%s\n' "$choice" >&2
                ;;
        esac
    done
}

prompt_required_domain() {
    MENU_VALUE=""
    MENU_CANCELLED=0
    MENU_RETURNED=0
    while true; do
        printf '域名（example.com，输入 0 返回）：'
        IFS= read -r MENU_VALUE || return 1
        case "$MENU_VALUE" in
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                printf '域名不能为空。\n' >&2
                ;;
            *)
                validate_domain "$MENU_VALUE" && return 0
                ;;
        esac
    done
}

prompt_optional_domain() {
    MENU_VALUE=""
    MENU_CANCELLED=0
    MENU_RETURNED=0
    while true; do
        printf '域名（可选，直接回车跳过 HTTPS，输入 0 返回）：'
        IFS= read -r MENU_VALUE || return 1
        case "$MENU_VALUE" in
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                return 0
                ;;
            *)
                validate_domain "$MENU_VALUE" && return 0
                ;;
        esac
    done
}

prompt_service_port() {
    local service="$1"
    local default_port input_value

    MENU_VALUE=""
    MENU_CANCELLED=0
    MENU_RETURNED=0
    default_port="$(service_port "$service" 2>/dev/null || service_default_port "$service")"
    while true; do
        printf 'Web 访问端口 [默认: %s，输入 0 返回]：' "$default_port"
        IFS= read -r input_value || return 1
        case "$input_value" in
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                MENU_VALUE="$default_port"
                return 0
                ;;
            *)
                if validate_port "$input_value"; then
                    MENU_VALUE="$input_value"
                    return 0
                fi
                ;;
        esac
    done
}

prompt_komari_credentials() {
    local default_username input_value password_value

    MENU_CANCELLED=0
    MENU_RETURNED=0
    default_username="${APPS_USERNAME:-admin}"
    while true; do
        printf 'Komari 管理员用户名 [默认: %s，输入 0 返回]：' "$default_username"
        IFS= read -r input_value || return 1
        case "$input_value" in
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                SELECTED_USERNAME="$default_username"
                break
                ;;
            *)
                if validate_username "$input_value"; then
                    SELECTED_USERNAME="$input_value"
                    break
                fi
                ;;
        esac
    done

    printf 'Komari 管理员密码 [默认: 自动生成，输入 0 返回]：'
    IFS= read -r password_value || return 1
    case "$password_value" in
        0|q|quit|exit)
            MENU_CANCELLED=1
            MENU_RETURNED=1
            return 1
            ;;
        '')
            SELECTED_PASSWORD=""
            ;;
        *)
            SELECTED_PASSWORD="$password_value"
            ;;
    esac
}

prompt_3x_ui_web_base_path() {
    local default_path input_value

    MENU_CANCELLED=0
    MENU_RETURNED=0
    default_path="${APPS_WEB_BASE_PATH:-/}"
    while true; do
        printf '3X-UI 面板访问路径 [默认: %s，输入 0 返回]：' "$default_path"
        IFS= read -r input_value || return 1
        case "$input_value" in
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                SELECTED_WEB_BASE_PATH="$default_path"
                return 0
                ;;
            *)
                if validate_web_base_path "$input_value"; then
                    SELECTED_WEB_BASE_PATH="$input_value"
                    return 0
                fi
                ;;
        esac
    done
}

prompt_base_dir() {
    local input_value

    MENU_CANCELLED=0
    MENU_RETURNED=0
    while true; do
        printf '部署目录 [默认: %s，输入 0 返回]：' "$BASE_DIR"
        IFS= read -r input_value || return 1
        case "$input_value" in
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            '')
                validate_base_dir && return 0
                ;;
            *)
                set_base_dir "$input_value" && return 0
                ;;
        esac
    done
}

prompt_certificate_mode() {
    local choice

    MENU_CANCELLED=0
    MENU_RETURNED=0
    while true; do
        cat <<'EOF'
证书模式：
  1) Let's Encrypt + acme.sh + Cloudflare Token（推荐）
  2) Let's Encrypt standalone
  0) 返回
EOF
        printf '请选择证书模式 [1]：'
        IFS= read -r choice || return 1
        case "$choice" in
            ''|1) CERT_MODE="cloudflare"; return 0 ;;
            2) CERT_MODE="standalone"; return 0 ;;
            0|q|quit|exit)
                MENU_CANCELLED=1
                MENU_RETURNED=1
                return 1
                ;;
            *)
                printf '证书模式选项无效：%s\n' "$choice" >&2
                ;;
        esac
    done
}

service_action_from_menu_choice() {
    case "$1" in
        1) printf 'status\n' ;;
        2) printf 'logs\n' ;;
        3) printf 'verify\n' ;;
        4) printf 'stop\n' ;;
        5) printf 'uninstall\n' ;;
        *) return 1 ;;
    esac
}

service_action_label() {
    case "$1" in
        status) printf '查看状态\n' ;;
        logs) printf '跟随日志\n' ;;
        verify) printf '验证健康\n' ;;
        stop) printf '停止服务\n' ;;
        uninstall) printf '卸载服务\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

manage_service_menu() {
    local service action choice rc

    prompt_service_name || return 0
    service="$MENU_VALUE"
    if [[ "$(service_deploy_state "$service")" != "已部署" ]]; then
        printf '服务尚未部署：%s。请先选择 [3] 部署/更新服务。\n' "$service"
        pause_menu
        return 0
    fi

    while true; do
        printf '\n管理服务：%s（%s）\n' "$(service_display_name "$service")" "$(service_deploy_state "$service")"
        cat <<'EOF'
  1) 查看状态
  2) 跟随日志
  3) 验证健康
  4) 停止服务
  5) 卸载服务
  0) 返回主菜单
EOF
        printf '请输入选项：'
        IFS= read -r choice || return 0
        case "$choice" in
            0|q|quit|exit)
                printf '%b\n' "${GREEN}感谢使用，再见！${NC}"
                return 0
                ;;
            '')
                continue
                ;;
            1|2|3|4|5)
                action="$(service_action_from_menu_choice "$choice")" || return 1
                show_section "$(service_display_name "$service") - $(service_action_label "$action")"
                if [[ "$action" == "verify" ]]; then
                    ( verify_service "$service" )
                else
                    ( service_action "$action" "$service" )
                fi
                rc=$?
                if (( rc != 0 )); then
                    printf '操作失败，退出码：%s\n' "$rc" >&2
                fi
                if (( rc == 0 )) && [[ "$action" == "logs" ]]; then
                    continue
                fi
                pause_menu
                ;;
            *)
                printf '菜单选项无效：%s\n' "$choice" >&2
                ;;
        esac
    done
}

run_menu_action() {
    local choice="$1"
    local service domain

    MENU_RETURNED=0
    SELECTED_PORT=""
    SELECTED_DOMAIN=""
    SELECTED_USERNAME=""
    SELECTED_PASSWORD=""
    SELECTED_WEB_BASE_PATH=""
    case "$choice" in
        1) show_section "检查运行环境"; ( check_environment ) ;;
        2) show_section "支持的服务"; list_services ;;
        3)
            prompt_base_dir || return 0
            prompt_service_name || return 0
            service="$MENU_VALUE"
            prompt_service_port "$service" || return 0
            SELECTED_PORT="$MENU_VALUE"
            prompt_optional_domain || return 0
            domain="$MENU_VALUE"
            SELECTED_DOMAIN="$domain"
            if [[ "$service" == "komari" ]]; then
                prompt_komari_credentials || return 0
            elif [[ "$service" == "3x-ui" ]]; then
                prompt_3x_ui_web_base_path || return 0
                printf '3X-UI Docker 镜像会在首次启动时生成用户名和密码；请启动后通过容器日志或 x-ui 菜单查看/修改。\n'
            fi
            if [[ -n "$domain" ]]; then
                prompt_certificate_mode || return 0
            fi
            show_section "部署/更新服务：$service"
            ( deploy_service "$service" "$domain" )
            ;;
        4)
            manage_service_menu
            ;;
        5)
            prompt_service_name || return 0
            service="$MENU_VALUE"
            prompt_required_domain || return 0
            domain="$MENU_VALUE"
            prompt_certificate_mode || return 0
            show_section "配置 HTTPS 反向代理：$service -> $domain"
            ( configure_proxy "$service" "$domain" )
            ;;
        6) show_section "安装 Docker"; ( install_docker ) ;;
        7) show_section "检查脚本"; ( check_script ) ;;
        h|help) show_section "帮助"; usage ;;
        *) printf '菜单选项无效：%s\n' "$choice" >&2; return 1 ;;
    esac
}

interactive_menu() {
    local choice rc

    while true; do
        show_header
        show_menu_status
        printf '\n'
        cat <<'EOF'
请选择操作：
  1) 检查运行环境
  2) 列出支持的服务
  3) 部署/更新服务
  4) 管理已部署服务
  5) 配置 HTTPS 反向代理
  6) 安装 Docker
  7) 检查脚本
  h) 帮助

  0) 退出
EOF
        printf '\n========================================\n'
        printf '请输入选项：'
        if ! IFS= read -r choice; then
            printf '%b\n' "${GREEN}感谢使用，再见！${NC}"
            return 0
        fi
        case "$choice" in
            0|q|quit|exit)
                printf '%b\n' "${GREEN}感谢使用，再见！${NC}"
                return 0
                ;;
            '')
                continue
                ;;
            *)
                run_menu_action "$choice"
                rc=$?
                if (( rc != 0 )); then
                    printf '操作失败，退出码：%s\n' "$rc" >&2
                fi
                if (( MENU_RETURNED == 1 )); then
                    continue
                fi
                if [[ "$choice" != "4" ]]; then
                    pause_menu
                fi
                ;;
        esac
    done
}

usage() {
    cat <<'EOF'
用法：install_apps.sh [命令] [服务] [域名]

不带参数运行会打开交互式菜单。

命令：
  list                    列出支持的服务
  install-docker          安装 Docker 和 Docker Compose 插件
  deploy <服务> [域名]    部署 hugo、wordpress、halo、typecho、komari 或 3x-ui；可选配置 HTTPS 反向代理
  proxy <服务> <域名>     配置 Nginx 反向代理、Let's Encrypt 证书和续期
  status <服务>           查看 Docker Compose 状态
  logs <服务>             跟随查看 Docker Compose 日志
  stop <服务>             停止服务
  uninstall <服务>        停止并删除服务项目
  verify <服务>           验证 Docker Compose 服务健康状态
  check                   检查脚本
  env                     检查运行环境
  help                    显示帮助

证书模式：
  APPS_CERT_MODE=cloudflare   Let's Encrypt + acme.sh + Cloudflare Token（推荐）
  APPS_CERT_MODE=standalone   Let's Encrypt standalone
EOF
}

case "${1:-menu}" in
    menu) interactive_menu ;;
    list) list_services ;;
    install-docker) install_docker ;;
    deploy) deploy_service "${2:-}" "${3:-}" ;;
    proxy) configure_proxy "${2:-}" "${3:-}" ;;
    status|logs|stop|uninstall) service_action "$1" "${2:-}" ;;
    verify) verify_service "${2:-}" ;;
    check) check_script ;;
    env) check_environment ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
