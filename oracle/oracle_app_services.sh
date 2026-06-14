#!/bin/bash
set -u

BASE_DIR="${ORACLE_SERVICES_HOME:-/opt/oracle-useful-services}"
DRY_RUN="${ORACLE_SERVICES_DRY_RUN:-0}"
NGINX_CONF_DIR="${ORACLE_SERVICES_NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_SSL_DIR="${ORACLE_SERVICES_NGINX_SSL_DIR:-/etc/nginx/ssl}"
ACME_HOME="${ORACLE_SERVICES_ACME_HOME:-/root/.acme.sh}"
ACME_SH="${ORACLE_SERVICES_ACME_SH:-$ACME_HOME/acme.sh}"
CERT_MODE="${ORACLE_SERVICES_CERT_MODE:-cloudflare}"
SAFE_ROOT_PATH="/usr/sbin:/usr/bin:/sbin:/bin"

if [[ "${EUID:-1}" == "0" ]]; then
    PATH="$SAFE_ROOT_PATH"
    export PATH
fi

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

need_root_for_base_dir() {
    if [[ "$BASE_DIR" == /opt/* && "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
        printf '请使用 root 运行此命令 / Please run this command as root\n' >&2
        exit 1
    fi
}

need_root() {
    if [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
        printf '请使用 root 运行此命令 / Please run this command as root\n' >&2
        exit 1
    fi
}

validate_service() {
    case "${1:-}" in
        hugo|wordpress|halo|typecho) return 0 ;;
        *) printf 'Unknown service: %s\n' "${1:-}" >&2; return 1 ;;
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
        printf 'Unsafe ORACLE_SERVICES_HOME: %s\n' "$BASE_DIR" >&2
        return 1
    fi
    return 0
}

validate_domain() {
    local domain="$1"

    if [[ -z "$domain" || ${#domain} -gt 253 || "$domain" =~ [^A-Za-z0-9.-] ]]; then
        printf 'Invalid domain: %s\n' "$domain" >&2
        return 1
    fi
    if [[ "$domain" == .* || "$domain" == *. || "$domain" == *..* || "$domain" != *.* ]]; then
        printf 'Invalid domain: %s\n' "$domain" >&2
        return 1
    fi
    if [[ "$domain" =~ (^|\.)- || "$domain" =~ -(\.|$) ]]; then
        printf 'Invalid domain: %s\n' "$domain" >&2
        return 1
    fi
    return 0
}

service_port() {
    case "$1" in
        hugo) printf '8080\n' ;;
        wordpress) printf '8081\n' ;;
        halo) printf '8082\n' ;;
        typecho) printf '8083\n' ;;
        *) validate_service "$1" || return $? ;;
    esac
}

service_upstream_name() {
    local service="$1"
    local domain="$2"
    local safe_domain hash

    safe_domain="${domain//./_}"
    safe_domain="${safe_domain//-/_}"
    hash="$(printf '%s' "$service:$domain" | cksum)"
    hash="${hash%% *}"
    printf 'oracle_%s_%s_%s_backend\n' "$service" "$safe_domain" "$hash" | tr '[:upper:]' '[:lower:]'
}

escape_domain_for_grep() {
    printf '%s\n' "$1" | sed 's/\./\\./g'
}

renew_marker() {
    printf 'ORACLE_APP_SERVICE_RENEW:%s:%s\n' "$1" "$CERT_MODE"
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
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
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
        printf 'No secure random source available.\n' >&2
        return 1
    fi
}

load_or_create_password() {
    local service="$1"
    local dir="$2"
    local env_file="$dir/.env"
    local password=""

    if [[ -f "$env_file" ]]; then
        password="$(awk -F= '/^ORACLE_SERVICE_PASSWORD=/{print substr($0, index($0, "=") + 1); exit}' "$env_file")"
    fi
    if [[ -z "$password" ]]; then
        password="$(random_password)"
    fi

    if [[ "$DRY_RUN" != "1" ]]; then
        mkdir -p "$dir" || return $?
        if [[ ! -f "$env_file" ]]; then
            printf 'ORACLE_SERVICE=%s\nORACLE_SERVICE_PASSWORD=%s\n' "$service" "$password" > "$env_file" || return $?
            chmod 600 "$env_file" || return $?
        elif ! grep -q '^ORACLE_SERVICE_PASSWORD=' "$env_file"; then
            printf 'ORACLE_SERVICE_PASSWORD=%s\n' "$password" >> "$env_file" || return $?
            chmod 600 "$env_file" || return $?
        fi
    fi

    printf '%s\n' "$password"
}

list_services() {
    cat <<'EOF'
Available services:
  hugo       Static Hugo site served by nginx
  wordpress WordPress with MariaDB
  halo       Halo blog with PostgreSQL
  typecho    Typecho with MariaDB
EOF
}

render_hugo_compose() {
    cat <<'EOF'
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: oracle-hugo-site
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"
    volumes:
      - ./public:/usr/share/nginx/html:ro
EOF
}

render_wordpress_compose() {
    local password="$1"

    cat <<EOF
services:
  mariadb:
    image: mariadb:11
    container_name: oracle-wordpress-db
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
    container_name: oracle-wordpress
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - "127.0.0.1:8081:80"
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
    local domain="${2:-}"
    local external_url="http://localhost:8082/"

    if [[ -n "$domain" ]]; then
        external_url="https://$domain/"
    fi

    cat <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: oracle-halo-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: halo
      POSTGRES_USER: halo
      POSTGRES_PASSWORD: $password
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
  halo:
    image: halohub/halo:2
    container_name: oracle-halo
    restart: unless-stopped
    depends_on:
      - postgres
    ports:
      - "127.0.0.1:8082:8090"
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

    cat <<EOF
services:
  mariadb:
    image: mariadb:11
    container_name: oracle-typecho-db
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
    container_name: oracle-typecho
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - "127.0.0.1:8083:80"
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

render_compose() {
    local service="$1"
    local password="${2:-change-me}"
    local domain="${3:-}"

    validate_service "$service" || return $?
    case "$service" in
        hugo) render_hugo_compose ;;
        wordpress) render_wordpress_compose "$password" ;;
        halo) render_halo_compose "$password" "$domain" ;;
        typecho) render_typecho_compose "$password" ;;
    esac
}

nginx_conf_path() {
    local service="$1"
    local domain="$2"

    printf '%s/oracle-%s-%s.conf\n' "${NGINX_CONF_DIR%/}" "$service" "$domain"
}

nginx_ssl_domain_dir() {
    local domain="$1"

    printf '%s/%s\n' "${NGINX_SSL_DIR%/}" "$domain"
}

validate_proxy_paths() {
    local path

    for path in "$NGINX_CONF_DIR" "$NGINX_SSL_DIR" "$ACME_HOME" "$ACME_SH"; do
        if ! is_safe_absolute_path "$path"; then
            printf 'Unsafe proxy path: %s\n' "$path" >&2
            return 1
        fi
    done
    return 0
}

validate_certificate_mode() {
    case "$CERT_MODE" in
        cloudflare|standalone) return 0 ;;
        *) printf 'Unknown certificate mode: %s\n' "$CERT_MODE" >&2; return 1 ;;
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
# Oracle app service reverse proxy for $service
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

    printf '[DRY-RUN] Would write Nginx config: %s\n' "$conf_path"
    render_nginx_config "$service" "$domain" || return $?
    cat <<EOF
[DRY-RUN] Certificate mode: $CERT_MODE
[DRY-RUN] Would issue and install certificate with acme.sh:
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
        printf '[DRY-RUN] Would write standalone renew wrapper: %s\n' "$script_path"
        render_standalone_renew_script "$domain"
    fi
    cat <<EOF
$ACME_SH --install-cert -d $domain --ecc --home $ACME_HOME \\
  --fullchain-file $ssl_dir/fullchain.cer \\
  --key-file $ssl_dir/private.key \\
  --reloadcmd "systemctl reload nginx"
chmod 600 $ssl_dir/private.key
chmod 644 $ssl_dir/fullchain.cer
[DRY-RUN] Would add idempotent root crontab renew task:
(crontab -l 2>/dev/null || true) > /tmp/oracle-services.cron
cp -a /tmp/oracle-services.cron /tmp/oracle-services.cron.new
grep -v 'ORACLE_APP_SERVICE_RENEW:$escaped_domain:' /tmp/oracle-services.cron.new > /tmp/oracle-services.cron.filtered
mv /tmp/oracle-services.cron.filtered /tmp/oracle-services.cron.new
cat >> /tmp/oracle-services.cron.new <<'CRON_EOF'
$renew_line
CRON_EOF
crontab /tmp/oracle-services.cron.new
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
        printf 'Missing Cloudflare DNS-01 credential environment variable(s): %s\n' "$missing" >&2
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
        printf 'Nginx not found. Please install Nginx manually.\n' >&2
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
                printf 'Unsafe acme.sh parent directory: %s\n' "$current" >&2
                return 1
            fi
            continue
        fi
        if [[ ! -d "$current" ]]; then
            printf 'Unsafe acme.sh parent directory: %s\n' "$current" >&2
            return 1
        fi
        if ! is_root_owned "$current" || is_group_or_other_writable "$current"; then
            printf 'Unsafe acme.sh parent directory: %s\n' "$current" >&2
            return 1
        fi
    done

    resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
    while [[ -n "$resolved_dir" && "$resolved_dir" != "/" ]]; do
        if ! is_root_owned "$resolved_dir" || is_group_or_other_writable "$resolved_dir"; then
            printf 'Unsafe acme.sh parent directory: %s\n' "$resolved_dir" >&2
            return 1
        fi
        resolved_dir="$(dirname "$resolved_dir")"
    done
    return 0
}

validate_root_executable_path() {
    local path="$1"

    if [[ ! -f "$path" || ! -x "$path" || -L "$path" ]]; then
        printf 'Unsafe acme.sh path: %s\n' "$path" >&2
        return 1
    fi
    if ! is_root_owned "$path"; then
        printf 'Unsafe acme.sh owner: %s\n' "$path" >&2
        return 1
    fi
    if is_group_or_other_writable "$path"; then
        printf 'Unsafe acme.sh permissions: %s\n' "$path" >&2
        return 1
    fi
    validate_root_owned_path_chain "$path" || return $?
    return 0
}

validate_acme_home_path() {
    if [[ ! -d "$ACME_HOME" || -L "$ACME_HOME" ]]; then
        printf 'Unsafe acme.sh home: %s\n' "$ACME_HOME" >&2
        return 1
    fi
    if ! is_root_owned "$ACME_HOME" || is_group_or_other_writable "$ACME_HOME"; then
        printf 'Unsafe acme.sh home: %s\n' "$ACME_HOME" >&2
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
        printf 'Unsafe acme.sh path\n' >&2
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

    printf 'acme.sh not found: %s\n' "$ACME_SH" >&2
    printf 'Install acme.sh first, then rerun this command.\n' >&2
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
    grep -v "ORACLE_APP_SERVICE_RENEW:$escaped_domain:" "$new_cron" > "$filtered_cron" || true
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
    log "Configured HTTPS proxy for $service at https://$domain/"
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
  <title>Oracle Hugo Site</title>
</head>
<body>
  <main>
    <h1>Oracle Hugo Site</h1>
    <p>Replace this static page with your Hugo generated public directory.</p>
  </main>
</body>
</html>
EOF
    fi
}

deploy_service() {
    local service="${1:-}"
    local domain="${2:-}"
    local dir password compose_password cmd

    validate_service "$service" || exit $?
    if [[ -n "$domain" ]]; then
        validate_domain "$domain" || exit $?
        validate_proxy_paths || exit $?
        validate_certificate_mode || exit $?
        if [[ "$DRY_RUN" != "1" && "$CERT_MODE" == "cloudflare" ]]; then
            require_cloudflare_credentials || exit $?
        fi
    fi
    dir="$(service_dir "$service")" || exit $?
    password="$(load_or_create_password "$service" "$dir")" || exit $?

    if [[ "$DRY_RUN" == "1" ]]; then
        compose_password="$password"
        if [[ -f "$dir/.env" ]] && grep -q '^ORACLE_SERVICE_PASSWORD=' "$dir/.env"; then
            compose_password="<redacted-existing-password>"
        fi
        printf '[DRY-RUN] Would deploy %s under %s\n' "$service" "$dir"
        render_compose "$service" "$compose_password" "$domain" || return $?
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
    render_compose "$service" "$password" "$domain" > "$dir/docker-compose.yml" || return $?
    chmod 600 "$dir/docker-compose.yml" || return $?

    cmd="$(compose_cmd)" || {
        printf 'Docker Compose not found. Run install-docker first.\n' >&2
        exit 1
    }
    (cd "$dir" && $cmd up -d)
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        return $rc
    fi
    log "Deployed $service in $dir"
    if [[ -n "$domain" ]]; then
        configure_proxy "$service" "$domain" || return $?
    fi
}

install_docker() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '[DRY-RUN] Would install Docker using the detected package manager\n'
        return 0
    fi

    need_root
    if command -v docker >/dev/null 2>&1 && compose_cmd >/dev/null 2>&1; then
        log "Docker and Docker Compose already installed"
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
        printf 'Unsupported package manager. Please install Docker manually.\n' >&2
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
        printf 'Service is not deployed: %s\n' "$service" >&2
        exit 1
    fi

    cmd="$(compose_cmd)" || {
        printf 'Docker Compose not found.\n' >&2
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
        printf 'Service is not deployed: %s\n' "$service" >&2
        exit 1
    fi

    cmd="$(compose_cmd)" || {
        printf 'Docker Compose not found.\n' >&2
        exit 1
    }
    output="$(cd "$dir" && $cmd ps 2>&1)" || {
        printf '%s\n' "$output" >&2
        printf 'Service is not healthy: %s\n' "$service" >&2
        exit 1
    }

    if printf '%s\n' "$output" | grep -Eiq '(^|[[:space:]])(exited|dead|unhealthy|restarting)([[:space:]]|$)'; then
        printf '%s\n' "$output"
        printf 'Service is not healthy: %s\n' "$service" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -Eiq '(running|up|healthy)'; then
        printf '%s\n' "$output"
        printf 'Service is not healthy: %s\n' "$service" >&2
        exit 1
    fi

    printf '%s\n' "$output"
    printf '%s verify OK\n' "$service"
}

check_script() {
    validate_certificate_mode || return $?
    printf '%s\n' "oracle_app_services.sh OK"
}

MENU_VALUE=""

prompt_service_name() {
    printf 'Service (hugo/wordpress/halo/typecho): '
    IFS= read -r MENU_VALUE || return 1
    validate_service "$MENU_VALUE" || return $?
}

prompt_required_domain() {
    printf 'Domain (example.com): '
    IFS= read -r MENU_VALUE || return 1
    validate_domain "$MENU_VALUE" || return $?
}

prompt_optional_domain() {
    printf 'Domain (optional, press Enter to skip HTTPS): '
    IFS= read -r MENU_VALUE || return 1
    if [[ -n "$MENU_VALUE" ]]; then
        validate_domain "$MENU_VALUE" || return $?
    fi
}

prompt_certificate_mode() {
    local choice

    cat <<'EOF'
Certificate mode:
  1) Let's Encrypt + acme.sh + Cloudflare Token (recommended)
  2) Let's Encrypt standalone
EOF
    printf 'Choose certificate mode [1]: '
    IFS= read -r choice || return 1
    case "$choice" in
        ''|1) CERT_MODE="cloudflare" ;;
        2) CERT_MODE="standalone" ;;
        *) printf 'Invalid certificate mode selection: %s\n' "$choice" >&2; return 1 ;;
    esac
}

service_action_from_menu_choice() {
    case "$1" in
        5) printf 'status\n' ;;
        6) printf 'logs\n' ;;
        7) printf 'stop\n' ;;
        8) printf 'uninstall\n' ;;
        *) return 1 ;;
    esac
}

run_menu_action() {
    local choice="$1"
    local service domain action

    case "$choice" in
        1) list_services ;;
        2) install_docker ;;
        3)
            prompt_service_name || return $?
            service="$MENU_VALUE"
            prompt_optional_domain || return $?
            domain="$MENU_VALUE"
            if [[ -n "$domain" ]]; then
                prompt_certificate_mode || return $?
            fi
            deploy_service "$service" "$domain"
            ;;
        4)
            prompt_service_name || return $?
            service="$MENU_VALUE"
            prompt_required_domain || return $?
            domain="$MENU_VALUE"
            prompt_certificate_mode || return $?
            configure_proxy "$service" "$domain"
            ;;
        5|6|7|8)
            prompt_service_name || return $?
            service="$MENU_VALUE"
            action="$(service_action_from_menu_choice "$choice")" || return $?
            service_action "$action" "$service"
            ;;
        9)
            prompt_service_name || return $?
            verify_service "$MENU_VALUE"
            ;;
        10) check_script ;;
        h|help) usage ;;
        *) printf 'Invalid menu choice: %s\n' "$choice" >&2; return 1 ;;
    esac
}

interactive_menu() {
    local choice

    while true; do
        cat <<'EOF'
Oracle App Services Menu
  1) List supported services
  2) Install Docker
  3) Deploy service
  4) Configure HTTPS proxy
  5) Service status
  6) Follow service logs
  7) Stop service
  8) Uninstall service
  9) Verify service
  10) Check script
  h) Help
  0) Exit
EOF
        printf 'Choose an action: '
        IFS= read -r choice || return 0
        case "$choice" in
            0|q|quit|exit) return 0 ;;
            *) run_menu_action "$choice" || return $? ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Usage: oracle_app_services.sh [command] [service] [domain]

Run without arguments to open the interactive menu.

Commands:
  list                    List supported services
  install-docker          Install Docker and Docker Compose plugin
  deploy <service> [domain] Deploy hugo, wordpress, halo, or typecho; optionally configure HTTPS proxy
  proxy <service> <domain>  Configure Nginx reverse proxy, Let's Encrypt certificate, and renewal
  status <service>        Show Docker Compose status
  logs <service>          Follow Docker Compose logs
  stop <service>          Stop a service
  uninstall <service>     Stop and remove a service project
  verify <service>        Verify Docker Compose service health
  check                   Validate script
  help                    Show this help

Certificate modes:
  ORACLE_SERVICES_CERT_MODE=cloudflare   Let's Encrypt + acme.sh + Cloudflare Token (recommended)
  ORACLE_SERVICES_CERT_MODE=standalone   Let's Encrypt standalone
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
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
