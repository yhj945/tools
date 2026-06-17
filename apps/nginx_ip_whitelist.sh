#!/bin/bash
set -u

TOOL_VERSION="v1.0.0"
PROJECT_URL="https://github.com/yhj945/tools"
SAFE_ROOT_PATH="/usr/sbin:/usr/bin:/sbin:/bin"

if [[ "${EUID:-1}" == "0" ]]; then
    PATH="$SAFE_ROOT_PATH"
    export PATH
fi

NGINX_CONTAINER_NAME="${NGINX_IPWL_CONTAINER_NAME:-nginx}"
WHITELIST_RELATIVE_PATH="${NGINX_IPWL_RELATIVE_PATH:-snippets/ip-whitelist.conf}"
WHITELIST_INCLUDE_OVERRIDE="${NGINX_IPWL_INCLUDE_PATH:-}"
REVIEW_DIFF="${NGINX_IPWL_REVIEW_DIFF:-ask}"
MARKER="# managed by nginx_ip_whitelist.sh"

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

NGINX_ROOT_DIR=""
NGINX_CONF_FILE=""
DETECTED_NGINX_CONF_FILE=""
CONF_D_DIR=""
CONTAINER_CONF_D=""
NGINX_RUNTIME="file"
ASSOCIATED_DOCKER_CONTAINER=""
NGINX_AVAILABLE=0
NGINX_DETECT_ERROR=""
WHITELIST_FILE=""
WHITELIST_INCLUDE_PATH=""
MENU_RETURNED=0
SELECTED_SITE_CONF=""
SELECTED_SERVER_START=0
SELECTED_SERVER_END=0
SELECTED_SERVER_LABEL=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

show_header() {
    printf '\n'
    printf '%b' "$CYAN"
    cat <<'EOF'
 _   _       _              ___ ____   __        ___     _ _       _ _     _
| \ | | __ _(_)_ __ __  __ |_ _|  _ \  \ \      / / |__ (_) |_ ___| (_)___| |_
|  \| |/ _` | | '_ \ \/ /  | || |_) |  \ \ /\ / /| '_ \| | __/ _ \ | / __| __|
| |\  | (_| | | | | |>  <   | ||  __/    \ V  V / | | | | | ||  __/ | \__ \ |_
|_| \_|\__, |_|_| |_/_/\_\ |___|_|        \_/\_/  |_| |_|_|\__\___|_|_|___/\__|
       |___/
EOF
    printf '%b' "$NC"
    printf '%b\n' "${GREEN}Nginx IP 白名单片段、站点选择与 reload 管理工具${NC}"
    printf 'GitHub: %s  Version: %s  Script: apps/nginx_ip_whitelist.sh\n' "$PROJECT_URL" "$TOOL_VERSION"
    printf '%b\n' "${BOLD}------------------------------------------------------------${NC}"
    printf '%b\n' "${BOLD}[ Nginx IP 白名单管理工具 控制台 ]${NC}"
    printf '%b\n\n' "${BOLD}------------------------------------------------------------${NC}"
}

show_section() {
    printf '\n'
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}$1${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
}

menu_print() {
    printf '%b' "$*" >&2
}

pause_menu() {
    printf '\n按回车键继续...'
    IFS= read -r _ || true
    printf '\n'
}

abs_dir() {
    local dir="$1"
    (cd "$dir" 2>/dev/null && pwd -P) || return 1
}

find_upward_nginx_root() {
    local start="$1"
    local dir count

    dir="$(abs_dir "$start" 2>/dev/null || true)"
    [[ -n "$dir" ]] || return 1
    count=0
    while [[ "$dir" != "/" && $count -lt 8 ]]; do
        if [[ -f "$dir/nginx.conf" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
        count=$((count + 1))
    done
    return 1
}

docker_nginx_running() {
    local name

    command -v docker >/dev/null 2>&1 || return 1
    if [[ -n "$NGINX_CONTAINER_NAME" ]] \
        && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$NGINX_CONTAINER_NAME" \
        && docker_container_has_nginx "$NGINX_CONTAINER_NAME"; then
        return 0
    fi

    name="$(discover_docker_nginx_container 2>/dev/null || true)"
    [[ -n "$name" ]] || return 1
    NGINX_CONTAINER_NAME="$name"
    return 0
}

docker_container_has_nginx() {
    local name="$1"

    docker exec "$name" sh -c 'command -v nginx >/dev/null 2>&1' >/dev/null 2>&1 \
        || docker exec "$name" nginx -V >/dev/null 2>&1
}

discover_docker_nginx_container() {
    local name image command choice
    local -a containers labels

    command -v docker >/dev/null 2>&1 || return 1

    while IFS=$'\t' read -r name image command; do
        [[ -n "$name" ]] || continue
        if docker_container_has_nginx "$name"; then
            containers+=("$name")
            labels+=("$name | image=$image | command=$command")
        fi
    done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Command}}' 2>/dev/null)

    if (( ${#containers[@]} == 0 )); then
        return 1
    fi
    if (( ${#containers[@]} == 1 )); then
        printf '%s\n' "${containers[0]}"
        return 0
    fi

    printf '检测到多个运行中的 Nginx 容器，请选择要管理的容器：\n' >&2
    local i=1
    for name in "${labels[@]}"; do
        printf '  %s) %s\n' "$i" "$name" >&2
        i=$((i + 1))
    done
    printf '  0) 取消\n' >&2

    if [[ ! -t 0 ]]; then
        printf '非交互环境下自动选择第一个 Nginx 容器：%s\n' "${containers[0]}" >&2
        printf '%s\n' "${containers[0]}"
        return 0
    fi

    while true; do
        printf '请输入选项：' >&2
        IFS= read -r choice || return 1
        case "$choice" in
            0|q|quit|exit) return 1 ;;
            '')
                continue
                ;;
            *)
                if is_uint "$choice" && (( choice >= 1 && choice <= ${#containers[@]} )); then
                    printf '%s\n' "${containers[$((choice - 1))]}"
                    return 0
                fi
                printf '菜单选项无效：%s\n' "$choice" >&2
                ;;
        esac
    done
}

container_path_to_host_path() {
    local container_path="$1" mounts source dest best_source="" best_dest="" suffix

    [[ -n "$NGINX_CONTAINER_NAME" ]] || return 1
    mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\n" .Source .Destination}}{{end}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)" || return 1
    while IFS= read -r line; do
        IFS=$'\t' read -r source dest _ <<< "$line"
        if [[ -z "$dest" ]]; then
            source="${line%%[[:space:]]*}"
            dest="${line##*[[:space:]]}"
        fi
        [[ -n "$source" && -n "$dest" ]] || continue
        if [[ "$container_path" == "$dest" || "$container_path" == "$dest"/* ]]; then
            if (( ${#dest} > ${#best_dest} )); then
                best_source="$source"
                best_dest="$dest"
            fi
        fi
    done <<< "$mounts"

    [[ -n "$best_source" ]] || return 1
    suffix="${container_path#$best_dest}"
    printf '%s%s\n' "${best_source%/}" "$suffix"
}

show_docker_nginx_mounts_hint() {
    printf '已识别 Docker Nginx 容器：%s，但未找到可映射到宿主机的 /etc/nginx 配置挂载。\n' "$NGINX_CONTAINER_NAME" >&2
    printf '当前容器挂载：\n' >&2
    docker inspect --format '{{range .Mounts}}{{printf "  %s -> %s\n" .Source .Destination}}{{end}}' "$NGINX_CONTAINER_NAME" 2>/dev/null >&2 || true
}

path_is_under() {
    local child="$1" parent="$2"

    [[ -n "$child" && -n "$parent" ]] || return 1
    child="$(cd "$child" 2>/dev/null && pwd -P)" || return 1
    parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
    [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

find_associated_docker_container() {
    local name source dest target line mounts
    local -a targets

    command -v docker >/dev/null 2>&1 || return 1
    docker ps >/dev/null 2>&1 || return 1

    targets=("$NGINX_ROOT_DIR")
    [[ -n "$CONF_D_DIR" ]] && targets+=("$CONF_D_DIR")

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        docker_container_has_nginx "$name" || continue
        mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\n" .Source .Destination}}{{end}}' "$name" 2>/dev/null)" || continue
        while IFS= read -r line; do
            IFS=$'\t' read -r source dest _ <<< "$line"
            [[ -n "$source" && -n "$dest" ]] || continue
            case "$dest" in
                /etc/nginx|/etc/nginx/*|/etc/nginx/conf.d|/etc/nginx/conf.d/*) ;;
                *) continue ;;
            esac
            for target in "${targets[@]}"; do
                if path_is_under "$target" "$source"; then
                    printf '%s\n' "$name"
                    return 0
                fi
            done
        done <<< "$mounts"
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)

    return 1
}

local_nginx_status() {
    if command -v nginx >/dev/null 2>&1; then
        printf '已安装'
    else
        printf '未安装'
    fi
}

systemd_nginx_status() {
    if ! command -v systemctl >/dev/null 2>&1; then
        printf '不可用'
    elif systemctl is-active --quiet nginx 2>/dev/null; then
        printf '运行中'
    else
        printf '未运行'
    fi
}

docker_nginx_status() {
    if ! command -v docker >/dev/null 2>&1; then
        printf '未安装 docker'
        return 0
    fi
    if ! docker ps >/dev/null 2>&1; then
        printf '无 Docker API 权限'
        return 0
    fi
    if docker_nginx_running; then
        printf '运行中（容器：%s）' "$NGINX_CONTAINER_NAME"
    else
        printf '未发现运行中的 Nginx 容器'
    fi
}

docker_nginx_mount_status() {
    local root_mount confd_mount

    docker_nginx_running || {
        printf '未关联'
        return 0
    }
    root_mount="$(container_path_to_host_path /etc/nginx 2>/dev/null || true)"
    confd_mount="$(container_path_to_host_path /etc/nginx/conf.d 2>/dev/null || true)"
    if [[ -n "$root_mount" ]]; then
        printf '/etc/nginx -> %s' "$root_mount"
    elif [[ -n "$confd_mount" ]]; then
        printf '/etc/nginx/conf.d -> %s' "$confd_mount"
    else
        printf '未发现 /etc/nginx bind mount'
    fi
}

find_docker_nginx_root() {
    local host_root host_conf host_conf_d tmp_root

    if command -v docker >/dev/null 2>&1 && ! docker ps >/dev/null 2>&1; then
        printf '检测到 docker，但当前用户无法访问 Docker API；可使用 sudo 或把用户加入 docker 组后重试。\n' >&2
        return 1
    fi
    docker_nginx_running || return 1

    host_root="$(container_path_to_host_path /etc/nginx 2>/dev/null || true)"
    if [[ -n "$host_root" && -f "$host_root/nginx.conf" ]]; then
        NGINX_RUNTIME="docker"
        printf '%s\t%s\n' "$host_root" "$NGINX_CONTAINER_NAME"
        return 0
    fi

    host_conf="$(container_path_to_host_path /etc/nginx/nginx.conf 2>/dev/null || true)"
    if [[ -n "$host_conf" && -f "$host_conf" ]]; then
        NGINX_RUNTIME="docker"
        printf '%s\t%s\n' "$(dirname "$host_conf")" "$NGINX_CONTAINER_NAME"
        return 0
    fi

    host_conf_d="$(container_path_to_host_path /etc/nginx/conf.d 2>/dev/null || true)"
    if [[ -n "$host_conf_d" && -d "$host_conf_d" ]]; then
        tmp_root="$(mktemp -d)"
        if docker exec "$NGINX_CONTAINER_NAME" sh -c 'cat /etc/nginx/nginx.conf' > "$tmp_root/nginx.conf" 2>/dev/null; then
            NGINX_RUNTIME="docker"
            printf '%s\t%s\n' "$tmp_root" "$NGINX_CONTAINER_NAME"
            return 0
        fi
        printf '检测到 Docker Nginx 容器，但只找到 conf.d 挂载，未能读取容器内 nginx.conf。请设置 NGINX_IPWL_ROOT 或 NGINX_IPWL_CONF_D。\n' >&2
        return 1
    fi

    show_docker_nginx_mounts_hint
    return 1
}

nginx_build_option() {
    local option="$1" nginx_bin="${2:-nginx}"

    command -v "$nginx_bin" >/dev/null 2>&1 || [[ "$nginx_bin" == /* && -x "$nginx_bin" ]] || return 1
    "$nginx_bin" -V 2>&1 | awk -v option="$option" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ "^--" option "=") {
                    sub("^--" option "=", "", $i)
                    print $i
                    exit
                }
            }
        }
    '
}

resolve_nginx_conf_path() {
    local conf_path="$1" nginx_bin="${2:-nginx}" prefix

    [[ -n "$conf_path" ]] || return 1
    if [[ "$conf_path" == /* ]]; then
        printf '%s\n' "$conf_path"
        return 0
    fi

    prefix="$(nginx_build_option prefix "$nginx_bin" 2>/dev/null || true)"
    [[ -n "$prefix" ]] || prefix="/etc/nginx"
    printf '%s/%s\n' "${prefix%/}" "$conf_path"
}

running_nginx_conf_path() {
    ps -eo args 2>/dev/null | awk '
        /nginx: master process/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "-c" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

systemd_nginx_conf_path() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl show nginx --property=ExecStart --value 2>/dev/null | sed -n 's/.* -c \([^ ;]*\).*/\1/p' | head -n 1
}

systemd_nginx_binary() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl show nginx --property=ExecStart --value 2>/dev/null | sed -n 's/.*argv\\[\\]=\\([^ ;]*nginx\\).*/\1/p' | head -n 1
}

find_host_nginx_conf() {
    local conf_path nginx_bin

    conf_path="$(running_nginx_conf_path 2>/dev/null || true)"
    if [[ -z "$conf_path" ]]; then
        conf_path="$(systemd_nginx_conf_path 2>/dev/null || true)"
    fi

    nginx_bin="$(systemd_nginx_binary 2>/dev/null || true)"
    [[ -n "$nginx_bin" ]] || nginx_bin="nginx"

    if [[ -z "$conf_path" ]]; then
        conf_path="$(nginx_build_option conf-path "$nginx_bin" 2>/dev/null || true)"
    fi
    conf_path="$(resolve_nginx_conf_path "$conf_path" "$nginx_bin" 2>/dev/null || true)"

    if [[ -n "$conf_path" && -f "$conf_path" ]]; then
        printf '%s\n' "$conf_path"
        return 0
    fi

    return 1
}

find_nginx_root() {
    local script_dir cwd candidate root conf runtime docker_result container

    if [[ -n "${NGINX_IPWL_ROOT:-}" ]]; then
        root="$(abs_dir "$NGINX_IPWL_ROOT")" || return 1
        [[ -f "$root/nginx.conf" ]] || {
            printf '未在 NGINX_IPWL_ROOT 找到 nginx.conf：%s\n' "$root" >&2
            return 1
        }
        printf 'file\t%s\t%s/nginx.conf\n' "$root" "$root"
        return 0
    fi

    docker_result="$(find_docker_nginx_root || true)"
    if [[ -n "$docker_result" ]]; then
        IFS=$'\t' read -r root container <<< "$docker_result"
        printf 'docker\t%s\t%s/nginx.conf\t%s\n' "$root" "$root" "$container"
        return 0
    fi

    conf="$(find_host_nginx_conf || true)"
    if [[ -n "$conf" ]]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
            runtime="systemd"
        else
            runtime="system"
        fi
        printf '%s\t%s\t%s\n' "$runtime" "$(dirname "$conf")" "$conf"
        return 0
    fi

    cwd="$(pwd -P)"
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"

    for candidate in "$cwd" "$script_dir" "$(dirname "$cwd")" "$(dirname "$script_dir")"; do
        if [[ -f "$candidate/nginx.conf" ]]; then
            printf 'file\t%s\t%s/nginx.conf\n' "$candidate" "$candidate"
            return 0
        fi
    done

    root="$(find_upward_nginx_root "$cwd" 2>/dev/null || true)"
    if [[ -n "$root" ]]; then
        printf 'file\t%s\t%s/nginx.conf\n' "$root" "$root"
        return 0
    fi

    root="$(find_upward_nginx_root "$script_dir" 2>/dev/null || true)"
    if [[ -n "$root" ]]; then
        printf 'file\t%s\t%s/nginx.conf\n' "$root" "$root"
        return 0
    fi

    printf '未能从 Nginx 服务或 nginx 二进制推导出正在使用的 nginx.conf。\n' >&2
    printf '请确认 nginx/docker 服务正在运行，或设置 NGINX_IPWL_ROOT 指向 nginx.conf 所在目录。\n' >&2
    printf '如果 Nginx 在 Docker 中，请确认 /etc/nginx、/etc/nginx/nginx.conf 或 /etc/nginx/conf.d 已 bind mount 到宿主机。\n' >&2
    return 1
}

detect_conf_d_dir() {
    local dir mapped

    if [[ -n "${NGINX_IPWL_CONF_D:-}" ]]; then
        dir="$(abs_dir "$NGINX_IPWL_CONF_D")" || return 1
        printf '%s\n' "$dir"
        return 0
    fi

    if [[ -d "$NGINX_ROOT_DIR/conf.d" ]]; then
        printf '%s\n' "$NGINX_ROOT_DIR/conf.d"
        return 0
    fi

    if [[ "$NGINX_RUNTIME" == "docker" && -n "$CONTAINER_CONF_D" ]]; then
        mapped="$(container_path_to_host_path "$CONTAINER_CONF_D" 2>/dev/null || true)"
        if [[ -n "$mapped" && -d "$mapped" ]]; then
            printf '%s\n' "$mapped"
            return 0
        fi
    fi

    printf '未找到 conf.d 目录。请设置 NGINX_IPWL_CONF_D。\n' >&2
    return 1
}

detect_container_conf_d() {
    local parsed

    if [[ -n "${NGINX_IPWL_CONTAINER_CONF_D:-}" ]]; then
        printf '%s\n' "${NGINX_IPWL_CONTAINER_CONF_D%/}"
        return 0
    fi

    parsed="$(awk '
        /^[[:space:]]*include[[:space:]]+.*conf\.d\/\*\.conf[[:space:]]*;/ {
            p=$2
            gsub(/\r/, "", p)
            sub(/;$/, "", p)
            sub(/\/\*\.conf$/, "", p)
            print p
            exit
        }
    ' "$NGINX_CONF_FILE")"

    if [[ -n "$parsed" && "$parsed" == /* ]]; then
        printf '%s\n' "${parsed%/}"
        return 0
    fi

    printf '/etc/nginx/conf.d\n'
}

detect_whitelist_include_path() {
    if [[ -n "$WHITELIST_INCLUDE_OVERRIDE" ]]; then
        printf '%s\n' "$WHITELIST_INCLUDE_OVERRIDE"
        return 0
    fi

    if [[ "$NGINX_RUNTIME" == "docker" || -n "$ASSOCIATED_DOCKER_CONTAINER" ]]; then
        printf '%s/%s\n' "$CONTAINER_CONF_D" "$WHITELIST_RELATIVE_PATH"
        return 0
    fi

    printf '%s/%s\n' "$CONF_D_DIR" "$WHITELIST_RELATIVE_PATH"
}

init_paths() {
    local detected detected_container err_file

    NGINX_AVAILABLE=0
    NGINX_DETECT_ERROR=""
    err_file="$(mktemp)" || return 1
    detected="$(find_nginx_root 2>"$err_file")" || {
        NGINX_DETECT_ERROR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        return 1
    }
    rm -f "$err_file"
    IFS=$'\t' read -r NGINX_RUNTIME NGINX_ROOT_DIR NGINX_CONF_FILE detected_container <<< "$detected"
    [[ -n "$detected_container" ]] && NGINX_CONTAINER_NAME="$detected_container"

    err_file="$(mktemp)" || return 1
    CONTAINER_CONF_D="$(detect_container_conf_d 2>"$err_file")" || {
        NGINX_DETECT_ERROR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        return 1
    }
    rm -f "$err_file"

    err_file="$(mktemp)" || return 1
    CONF_D_DIR="$(detect_conf_d_dir 2>"$err_file")" || {
        NGINX_DETECT_ERROR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        return 1
    }
    rm -f "$err_file"

    WHITELIST_FILE="$CONF_D_DIR/$WHITELIST_RELATIVE_PATH"
    ASSOCIATED_DOCKER_CONTAINER="$(find_associated_docker_container 2>/dev/null || true)"
    WHITELIST_INCLUDE_PATH="$(detect_whitelist_include_path)"
    NGINX_AVAILABLE=1
}

require_nginx_available() {
    if (( NGINX_AVAILABLE == 1 )); then
        return 0
    fi

    printf '当前未检测到可管理的 Nginx 配置。\n' >&2
    if [[ -n "$NGINX_DETECT_ERROR" ]]; then
        printf '%s\n' "$NGINX_DETECT_ERROR" >&2
    fi
    printf '请启动 Nginx/Docker Nginx，或设置 NGINX_IPWL_ROOT/NGINX_IPWL_CONF_D 后重试。\n' >&2
    return 1
}

ensure_whitelist_file() {
    mkdir -p "$(dirname "$WHITELIST_FILE")" || return $?
    if [[ -f "$WHITELIST_FILE" ]]; then
        return 0
    fi

    cat > "$WHITELIST_FILE" <<'EOF'
# Nginx IP whitelist managed by nginx_ip_whitelist.sh
# One allow directive per line, for example:
# allow 203.0.113.10;
# allow 203.0.113.0/24;
# allow 2001:db8::1;
# allow 2001:db8:abcd::/48;

deny all;
EOF
}

list_whitelist_entries() {
    [[ -f "$WHITELIST_FILE" ]] || return 0
    awk '
        /^[[:space:]]*allow[[:space:]]+/ {
            ip=$2
            sub(/;$/, "", ip)
            if (ip != "all") print ip
        }
    ' "$WHITELIST_FILE"
}

count_whitelist_entries() {
    list_whitelist_entries | awk 'NF {n++} END {print n+0}'
}

replace_file_preserve_attrs() {
    local tmp="$1" target="$2"

    if [[ -e "$target" ]]; then
        chmod --reference="$target" "$tmp" 2>/dev/null || true
        chown --reference="$target" "$tmp" 2>/dev/null || true
    fi
    mv "$tmp" "$target"
}

rewrite_whitelist_entries() {
    local tmp entry
    tmp="$(mktemp)" || return 1

    cat > "$tmp" <<'EOF'
# Nginx IP whitelist managed by nginx_ip_whitelist.sh
# One allow directive per line. IPv4, IPv6 and CIDR are supported.

EOF

    for entry in "$@"; do
        [[ -n "$entry" ]] || continue
        printf 'allow %s;\n' "$entry" >> "$tmp"
    done
    printf '\ndeny all;\n' >> "$tmp"
    replace_file_preserve_attrs "$tmp" "$WHITELIST_FILE"
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_ipv4_cidr() {
    local value="$1" ip prefix octet
    local -a octets

    ip="${value%%/*}"
    prefix=""
    if [[ "$value" == */* ]]; then
        prefix="${value##*/}"
        is_uint "$prefix" || return 1
        (( prefix >= 0 && prefix <= 32 )) || return 1
    fi

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        is_uint "$octet" || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

validate_ip_or_cidr_with_python() {
    local value="$1"

    command -v python3 >/dev/null 2>&1 || return 127
    python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$value" >/dev/null 2>&1
}

validate_ip_or_cidr() {
    local value="$1" rc

    if [[ -z "$value" || "$value" == -* || "$value" =~ [[:space:]] || "$value" == *';'* || "$value" == "all" ]]; then
        printf 'IP/CIDR 不安全：%s\n' "$value" >&2
        return 1
    fi

    validate_ip_or_cidr_with_python "$value"
    rc=$?
    if (( rc == 0 )); then
        return 0
    fi
    if (( rc == 127 )); then
        if validate_ipv4_cidr "$value"; then
            return 0
        fi
        printf '缺少 python3，无法可靠校验 IPv6/CIDR：%s\n' "$value" >&2
        return 1
    fi

    printf 'IP/CIDR 格式无效：%s\n' "$value" >&2
    return 1
}

read_tokens() {
    local input="$1"
    input="${input//,/ }"
    printf '%s\n' $input
}

add_whitelist_ips() {
    local input token added
    local -a entries tokens merged

    ensure_whitelist_file || return $?
    if (( $# > 0 )); then
        input="$*"
    else
        printf '请输入要添加的 IP/CIDR（多个用空格或逗号分隔，输入 0 返回）：'
        IFS= read -r input || return 1
    fi

    case "$input" in
        0|q|quit|exit|'')
            MENU_RETURNED=1
            return 0
            ;;
    esac

    mapfile -t tokens < <(read_tokens "$input")
    for token in "${tokens[@]}"; do
        validate_ip_or_cidr "$token" || return $?
    done

    mapfile -t entries < <(list_whitelist_entries)
    mapfile -t merged < <({ printf '%s\n' "${entries[@]}"; printf '%s\n' "${tokens[@]}"; } | awk 'NF && !seen[$0]++')
    added=$(( ${#merged[@]} - ${#entries[@]} ))
    rewrite_whitelist_entries "${merged[@]}" || return $?
    printf '已更新白名单，新增 %s 条。\n' "$added"
}

remove_whitelist_ips() {
    local input token idx entry removed found
    local -a entries tokens keep remove_values

    ensure_whitelist_file || return $?
    mapfile -t entries < <(list_whitelist_entries)
    if (( ${#entries[@]} == 0 )); then
        printf '白名单为空，无需移除。\n'
        return 0
    fi

    printf '当前白名单：\n'
    idx=1
    for entry in "${entries[@]}"; do
        printf '  %s) %s\n' "$idx" "$entry"
        idx=$((idx + 1))
    done

    if (( $# > 0 )); then
        input="$*"
    else
        printf '请输入要移除的编号或 IP/CIDR（多个用空格或逗号分隔，输入 0 返回）：'
        IFS= read -r input || return 1
    fi

    case "$input" in
        0|q|quit|exit|'')
            MENU_RETURNED=1
            return 0
            ;;
    esac

    mapfile -t tokens < <(read_tokens "$input")
    for token in "${tokens[@]}"; do
        if is_uint "$token" && (( token >= 1 && token <= ${#entries[@]} )); then
            remove_values+=("${entries[$((token - 1))]}")
        else
            validate_ip_or_cidr "$token" || return $?
            remove_values+=("$token")
        fi
    done

    removed=0
    for entry in "${entries[@]}"; do
        found=0
        for token in "${remove_values[@]}"; do
            if [[ "$entry" == "$token" ]]; then
                found=1
                break
            fi
        done
        if (( found == 1 )); then
            removed=$((removed + 1))
        else
            keep+=("$entry")
        fi
    done

    rewrite_whitelist_entries "${keep[@]}" || return $?
    printf '已更新白名单，移除 %s 条。\n' "$removed"
}

list_server_blocks() {
    local file="$1"
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function brace_delta(line, tmp, opens, closes) {
            tmp = line
            opens = gsub(/\{/, "{", tmp)
            tmp = line
            closes = gsub(/\}/, "}", tmp)
            return opens - closes
        }
        function emit_block() {
            if (label == "") label = "未设置 server_name"
            if (listen_values != "") label = label " | listen=" listen_values
            print start "\t" end "\t" label
        }
        /^[[:space:]]*server[[:space:]]*\{/ && !in_server {
            in_server = 1
            start = NR
            depth = 0
            label = ""
            listen_values = ""
        }
        in_server {
            if ($0 ~ /^[[:space:]]*listen[[:space:]]+/) {
                listen = $0
                sub(/^[[:space:]]*listen[[:space:]]+/, "", listen)
                sub(/;[[:space:]]*$/, "", listen)
                listen = trim(listen)
                if (listen != "") {
                    if (listen_values != "") listen_values = listen_values ", "
                    listen_values = listen_values listen
                }
            }
            if ($0 ~ /^[[:space:]]*server_name[[:space:]]+/ && label == "") {
                name = $0
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", name)
                sub(/;[[:space:]]*$/, "", name)
                label = trim(name)
            }
            depth += brace_delta($0)
            if (depth <= 0) {
                end = NR
                emit_block()
                in_server = 0
            }
        }
        END {
            if (in_server) {
                end = NR
                emit_block()
            }
        }
    ' "$file"
}

site_conf_label() {
    local file="$1" labels
    labels="$(list_server_blocks "$file" | awk -F '\t' '{
        if (labels != "") labels = labels ", "
        labels = labels $3
    } END { print labels }')"
    if [[ -n "$labels" ]]; then
        printf '%s' "$labels"
    else
        printf '未设置 server_name'
    fi
}

server_block_enabled() {
    local file="$1" start="$2" end="$3"
    awk -v marker="$MARKER" -v start="$start" -v end="$end" '
        NR >= start && NR <= end && index($0, marker) { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$file"
}

list_site_conf_files() {
    find "$CONF_D_DIR" -maxdepth 1 -type f -name '*.conf' ! -name 'default.conf' -exec grep -l '^[[:space:]]*server[[:space:]]*{' {} \; | sort
}

select_server_block() {
    local file="$1" choice block start end label
    local -a blocks

    mapfile -t blocks < <(list_server_blocks "$file")
    if (( ${#blocks[@]} == 0 )); then
        printf '未在站点配置中找到 server 块：%s\n' "$file" >&2
        return 1
    fi

    if [[ -n "${NGINX_IPWL_SERVER_NAME:-}" ]]; then
        for block in "${blocks[@]}"; do
            IFS=$'\t' read -r start end label <<< "$block"
            if [[ " $label " == *" $NGINX_IPWL_SERVER_NAME "* ]]; then
                SELECTED_SERVER_START="$start"
                SELECTED_SERVER_END="$end"
                SELECTED_SERVER_LABEL="$label"
                return 0
            fi
        done
        printf '未在 %s 找到 server_name：%s\n' "$file" "$NGINX_IPWL_SERVER_NAME" >&2
        return 1
    fi

    if (( ${#blocks[@]} == 1 )); then
        IFS=$'\t' read -r SELECTED_SERVER_START SELECTED_SERVER_END SELECTED_SERVER_LABEL <<< "${blocks[0]}"
        return 0
    fi

    while true; do
        menu_print '请选择要管理的站点 server 块：\n'
        local i=1
        for block in "${blocks[@]}"; do
            IFS=$'\t' read -r start end label <<< "$block"
            printf '  %s) %s（行 %s-%s）%s\n' "$i" "$label" "$start" "$end" \
                "$(server_block_enabled "$file" "$start" "$end" && printf ' - 已启用' || true)" >&2
            i=$((i + 1))
        done
        menu_print '  0) 返回\n'
        menu_print '请输入选项：'
        IFS= read -r choice || return 1
        case "$choice" in
            0|q|quit|exit)
                MENU_RETURNED=1
                return 1
                ;;
            '') continue ;;
            *)
                if is_uint "$choice" && (( choice >= 1 && choice <= ${#blocks[@]} )); then
                    IFS=$'\t' read -r SELECTED_SERVER_START SELECTED_SERVER_END SELECTED_SERVER_LABEL <<< "${blocks[$((choice - 1))]}"
                    return 0
                fi
                printf '菜单选项无效：%s\n' "$choice" >&2
                ;;
        esac
    done
}

select_site_conf() {
    local choice file
    local -a files

    SELECTED_SITE_CONF=""
    SELECTED_SERVER_START=0
    SELECTED_SERVER_END=0
    SELECTED_SERVER_LABEL=""

    if [[ -n "${NGINX_IPWL_SITE_CONF:-}" ]]; then
        if [[ "$NGINX_IPWL_SITE_CONF" == /* ]]; then
            file="$NGINX_IPWL_SITE_CONF"
        else
            file="$CONF_D_DIR/$NGINX_IPWL_SITE_CONF"
        fi
        [[ -f "$file" ]] || {
            printf '站点配置不存在：%s\n' "$file" >&2
            return 1
        }
        SELECTED_SITE_CONF="$file"
        select_server_block "$file"
        return $?
    fi

    mapfile -t files < <(list_site_conf_files)
    if (( ${#files[@]} == 0 )); then
        printf '未在 %s 找到站点配置文件。\n' "$CONF_D_DIR" >&2
        return 1
    fi
    if (( ${#files[@]} == 1 )); then
        SELECTED_SITE_CONF="${files[0]}"
        select_server_block "$SELECTED_SITE_CONF"
        return $?
    fi

    while true; do
        menu_print '请选择要管理的站点配置：\n'
        local i=1
        for file in "${files[@]}"; do
            printf '  %s) %s - %s\n' "$i" "$(basename "$file")" "$(site_conf_label "$file")" >&2
            i=$((i + 1))
        done
        menu_print '  0) 返回\n'
        menu_print '请输入选项：'
        IFS= read -r choice || return 1
        case "$choice" in
            0|q|quit|exit)
                MENU_RETURNED=1
                return 1
                ;;
            '') continue ;;
            *)
                if is_uint "$choice" && (( choice >= 1 && choice <= ${#files[@]} )); then
                    SELECTED_SITE_CONF="${files[$((choice - 1))]}"
                    select_server_block "$SELECTED_SITE_CONF"
                    return $?
                fi
                printf '菜单选项无效：%s\n' "$choice" >&2
                ;;
        esac
    done
}

backup_conf_file() {
    local file="$1" backup
    backup="$file.bak.$(date '+%Y%m%d%H%M%S')"
    cp -p "$file" "$backup" || return $?
    printf '%s\n' "$backup"
}

restore_conf_backup() {
    local file="$1" backup="$2"

    cp -p "$backup" "$file" || return $?
    printf '已从备份回滚配置：%s\n' "$backup" >&2
}

show_file_diff() {
    local file="$1" candidate="$2"

    if command -v git >/dev/null 2>&1; then
        git diff --no-index -- "$file" "$candidate" || true
        return 0
    fi

    diff -u "$file" "$candidate" || true
}

review_candidate_change() {
    local file="$1" candidate="$2" choice

    case "$REVIEW_DIFF" in
        0|no|NO|false|FALSE|never|NEVER)
            return 0
            ;;
        1|yes|YES|true|TRUE|always|ALWAYS)
            show_section "配置变更 Diff"
            show_file_diff "$file" "$candidate"
            printf '\n是否应用以上修改？[y/N]：'
            IFS= read -r choice || return 1
            case "$choice" in
                y|Y|yes|YES) return 0 ;;
                *) printf '已取消应用修改。\n' >&2; return 1 ;;
            esac
            ;;
    esac

    [[ -t 0 ]] || return 0
    printf '是否查看本次配置变更 diff？[y/N]：'
    IFS= read -r choice || return 0
    case "$choice" in
        y|Y|yes|YES)
            show_section "配置变更 Diff"
            show_file_diff "$file" "$candidate"
            printf '\n是否应用以上修改？[y/N]：'
            IFS= read -r choice || return 1
            case "$choice" in
                y|Y|yes|YES) return 0 ;;
                *) printf '已取消应用修改。\n' >&2; return 1 ;;
            esac
            ;;
    esac
}

insert_whitelist_include() {
    local file="$1" start="$2" end="$3" tmp remaining rc
    tmp="$(mktemp)" || return 1

    awk -v include_path="$WHITELIST_INCLUDE_PATH" -v marker="$MARKER" -v start="$start" -v end="$end" '
        function indent_of(line) {
            match(line, /^[ \t]*/)
            return substr(line, RSTART, RLENGTH) "    "
        }
        function is_protected_location(line) {
            return line ~ /^[[:space:]]*location[[:space:]]+/ && line !~ /\/\.well-known\/acme-challenge/
        }
        function in_scope() {
            return NR >= start && NR <= end
        }
        function is_single_line_block(line) {
            return line ~ /\{/ && line ~ /\}/
        }
        in_scope() && $0 ~ marker { next }
        {
            print
            if (in_scope() && pending && $0 ~ /\{/) {
                if (is_single_line_block($0)) {
                    bad_single_line = 1
                    bad_line = NR
                    next
                }
                print pending_indent "include " include_path "; " marker
                pending = 0
                inserted++
            }
            if (in_scope() && !pending && is_protected_location($0)) {
                if ($0 ~ /\{/) {
                    if (is_single_line_block($0)) {
                        bad_single_line = 1
                        bad_line = NR
                        next
                    }
                    print indent_of($0) "include " include_path "; " marker
                    inserted++
                } else {
                    pending = 1
                    pending_indent = indent_of($0)
                }
            }
        }
        END {
            if (bad_single_line) {
                exit 3
            }
            if (inserted == 0) exit 2
        }
    ' "$file" > "$tmp"
    rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        if (( rc == 3 )); then
            printf '发现单行 location 块，无法安全插入白名单。请先改成多行 location：%s\n' "$file" >&2
        else
            printf '未找到可插入白名单的 location 块：%s\n' "$file" >&2
        fi
        return 1
    fi

    review_candidate_change "$file" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    replace_file_preserve_attrs "$tmp" "$file" || return $?
    remaining="$(grep -F "$MARKER" "$file" 2>/dev/null | wc -l | tr -d ' ')"
    printf '已启用白名单：%s | server_name=%s（文件内 marker 总数：%s）\n' "$file" "$SELECTED_SERVER_LABEL" "$remaining"
}

remove_whitelist_include() {
    local file="$1" start="$2" end="$3" tmp before after
    tmp="$(mktemp)" || return 1
    before="$(awk -v marker="$MARKER" -v start="$start" -v end="$end" 'NR >= start && NR <= end && index($0, marker) { n++ } END { print n+0 }' "$file")"
    awk -v marker="$MARKER" -v start="$start" -v end="$end" '
        NR >= start && NR <= end && index($0, marker) { next }
        { print }
    ' "$file" > "$tmp" || return $?
    review_candidate_change "$file" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    replace_file_preserve_attrs "$tmp" "$file" || return $?
    after="$(grep -F "$MARKER" "$file" 2>/dev/null | wc -l | tr -d ' ')"
    printf '已禁用白名单：%s | server_name=%s（本 server 移除 %s 处，文件内剩余 %s 处）\n' "$file" "$SELECTED_SERVER_LABEL" "$before" "$after"
}

enable_whitelist() {
    local backup entries

    ensure_whitelist_file || return $?
    entries="$(count_whitelist_entries)"
    if (( entries == 0 )); then
        printf '白名单为空。请先添加至少一个 IP/CIDR，再启用。\n' >&2
        return 1
    fi

    select_site_conf || return $?
    backup="$(backup_conf_file "$SELECTED_SITE_CONF")" || return $?
    printf '已备份配置：%s\n' "$backup"
    insert_whitelist_include "$SELECTED_SITE_CONF" "$SELECTED_SERVER_START" "$SELECTED_SERVER_END" || return $?
    if ! nginx_test; then
        printf 'Nginx 配置检查失败，正在回滚本次修改。\n' >&2
        restore_conf_backup "$SELECTED_SITE_CONF" "$backup" || return $?
        return 1
    fi
}

disable_whitelist() {
    local backup

    select_site_conf || return $?
    backup="$(backup_conf_file "$SELECTED_SITE_CONF")" || return $?
    printf '已备份配置：%s\n' "$backup"
    remove_whitelist_include "$SELECTED_SITE_CONF" "$SELECTED_SERVER_START" "$SELECTED_SERVER_END" || return $?
    if ! nginx_test; then
        printf 'Nginx 配置检查失败，正在回滚本次修改。\n' >&2
        restore_conf_backup "$SELECTED_SITE_CONF" "$backup" || return $?
        return 1
    fi
}

nginx_test() {
    case "$NGINX_RUNTIME" in
        docker)
            docker exec "$NGINX_CONTAINER_NAME" nginx -t
            return $?
            ;;
        file)
            if [[ -n "$ASSOCIATED_DOCKER_CONTAINER" ]]; then
                docker exec "$ASSOCIATED_DOCKER_CONTAINER" nginx -t
                return $?
            fi
            if command -v nginx >/dev/null 2>&1; then
                nginx -t -c "$NGINX_CONF_FILE"
                return $?
            fi
            if docker_nginx_running; then
                printf '检测到 Docker Nginx 容器：%s，但当前脚本目录未关联到该容器的 /etc/nginx 挂载。\n' "$NGINX_CONTAINER_NAME" >&2
                printf '当前脚本目录：%s\n' "$NGINX_ROOT_DIR" >&2
                printf 'Docker 配置挂载：%s\n' "$(docker_nginx_mount_status)" >&2
                printf '因此无法用容器检查这个指定配置。请改用容器实际挂载目录，或安装本机 nginx 后执行 nginx -t -c。\n' >&2
                return 1
            fi
            printf '未找到本机 nginx 命令，也未找到关联 Docker Nginx 容器，无法检查指定配置：%s\n' "$NGINX_CONF_FILE" >&2
            return 1
            ;;
        system|systemd)
            if command -v nginx >/dev/null 2>&1; then
                nginx -t -c "$NGINX_CONF_FILE"
                return $?
            fi
            printf '未找到本机 nginx 命令，无法检查指定配置：%s\n' "$NGINX_CONF_FILE" >&2
            return 1
            ;;
    esac

    if docker_nginx_running; then
        docker exec "$NGINX_CONTAINER_NAME" nginx -t
        return $?
    fi

    if [[ -f "$NGINX_ROOT_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
        (cd "$NGINX_ROOT_DIR" && docker compose exec -T nginx nginx -t)
        return $?
    fi

    printf '未找到可用的 nginx 或 Docker，跳过 nginx -t。\n' >&2
    return 0
}

nginx_reload() {
    case "$NGINX_RUNTIME" in
        docker)
            docker exec "$NGINX_CONTAINER_NAME" nginx -s reload
            return $?
            ;;
        systemd)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl reload nginx
                return $?
            fi
            ;;
        system)
            if command -v nginx >/dev/null 2>&1; then
                nginx -s reload
                return $?
            fi
            ;;
        file)
            if [[ -n "$ASSOCIATED_DOCKER_CONTAINER" ]]; then
                docker exec "$ASSOCIATED_DOCKER_CONTAINER" nginx -s reload
                return $?
            fi
            if docker_nginx_running; then
                printf '检测到 Docker Nginx 容器：%s，但当前脚本目录未关联到该容器的 /etc/nginx 挂载。\n' "$NGINX_CONTAINER_NAME" >&2
                printf '当前脚本目录：%s\n' "$NGINX_ROOT_DIR" >&2
                printf 'Docker 配置挂载：%s\n' "$(docker_nginx_mount_status)" >&2
                printf '因此不会 reload 该容器，避免重载与当前脚本目录无关的配置。\n' >&2
                return 1
            fi
            printf '当前为 file 模式，且未找到关联 Docker Nginx 容器，不自动 reload 真实 Nginx 服务。\n' >&2
            printf '请在确认该目录对应的实际服务后手动 reload，或使用 Docker/systemd 自动检测模式运行。\n' >&2
            return 1
            ;;
    esac

    if docker_nginx_running; then
        docker exec "$NGINX_CONTAINER_NAME" nginx -s reload
        return $?
    fi

    if [[ -f "$NGINX_ROOT_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
        (cd "$NGINX_ROOT_DIR" && docker compose exec -T nginx nginx -s reload)
        return $?
    fi

    if command -v nginx >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl reload nginx
            return $?
        fi
        nginx -s reload
        return $?
    fi

    printf '未找到可用的 nginx 或 Docker，无法自动 reload。\n' >&2
    return 1
}

check_and_offer_reload() {
    local choice

    show_section "检查 Nginx 配置"
    nginx_test || return $?
    offer_reload
}

offer_reload() {
    local choice

    printf '\n是否立即 reload Nginx？[y/N]：'
    IFS= read -r choice || return 0
    case "$choice" in
        y|Y|yes|YES)
            nginx_reload
            ;;
        *)
            printf '已跳过 reload。\n'
            ;;
    esac
}

show_status_separator() {
    printf '%b\n' "${BOLD}------------------------------------------------------------${NC}"
}

show_status() {
    local file block start end label enabled count
    local -a entries files blocks

    if (( NGINX_AVAILABLE != 1 )); then
        printf '%b\n' "${BOLD}脚本状态${NC}"
        printf '  脚本运行模式：未检测到 Nginx\n'
        printf '  状态：%b不可用%b\n' "$YELLOW" "$NC"

        printf '\n%b\n' "${BOLD}Nginx 环境${NC}"
        printf '  本机 nginx 命令：%s\n' "$(local_nginx_status)"
        printf '  systemd nginx：%s\n' "$(systemd_nginx_status)"
        printf '  Docker Nginx：%s\n' "$(docker_nginx_status)"
        printf '  Docker 配置挂载：%s\n' "$(docker_nginx_mount_status)"
        if [[ -n "$NGINX_DETECT_ERROR" ]]; then
            printf '\n%b\n' "${BOLD}检测信息${NC}"
            printf '%s\n' "$NGINX_DETECT_ERROR" | sed 's/^/  /'
        fi
        cat <<'EOF'

可用操作：
  - h) 查看帮助
  - 0) 退出

要启用完整功能，请启动 Nginx/Docker Nginx，或设置：
  NGINX_IPWL_ROOT=/path/to/nginx-conf-dir
  NGINX_IPWL_CONF_D=/path/to/conf.d
EOF
        show_status_separator
        return 0
    fi

    ensure_whitelist_file || return $?
    count="$(count_whitelist_entries)"
    mapfile -t entries < <(list_whitelist_entries)
    mapfile -t files < <(list_site_conf_files)

    printf '%b\n' "${BOLD}脚本配置${NC}"
    printf '  脚本运行模式：%s\n' "$NGINX_RUNTIME"
    printf '  Nginx 根目录：%s\n' "$NGINX_ROOT_DIR"
    printf '  nginx.conf：%s\n' "$NGINX_CONF_FILE"
    printf '  conf.d 目录：%s\n' "$CONF_D_DIR"
    printf '  配置内 conf.d：%s\n' "$CONTAINER_CONF_D"

    printf '\n%b\n' "${BOLD}Nginx 环境${NC}"
    printf '  本机 nginx 命令：%s\n' "$(local_nginx_status)"
    printf '  systemd nginx：%s\n' "$(systemd_nginx_status)"
    printf '  Docker Nginx：%s\n' "$(docker_nginx_status)"
    printf '  Docker 配置挂载：%s\n' "$(docker_nginx_mount_status)"
    if [[ "$NGINX_RUNTIME" == "docker" ]]; then
        printf '  Docker 容器：%s\n' "$NGINX_CONTAINER_NAME"
    elif [[ -n "$ASSOCIATED_DOCKER_CONTAINER" ]]; then
        printf '  关联 Docker 容器：%s\n' "$ASSOCIATED_DOCKER_CONTAINER"
    elif docker_nginx_running; then
        printf '  关联 Docker 容器：未关联当前脚本目录\n'
    fi

    printf '\n%b\n' "${BOLD}白名单${NC}"
    printf '  白名单文件：%s\n' "$WHITELIST_FILE"
    printf '  include 路径：%s\n' "$WHITELIST_INCLUDE_PATH"
    printf '  条目数：%s\n' "$count"
    if (( ${#entries[@]} > 0 )); then
        printf '  IP/CIDR：\n'
        for file in "${entries[@]}"; do
            printf '    - %s\n' "$file"
        done
    fi

    printf '\n%b\n' "${BOLD}站点配置${NC}"
    if (( ${#files[@]} == 0 )); then
        printf '  未找到非 default.conf 的站点配置。\n'
        show_status_separator
        return 0
    fi
    for file in "${files[@]}"; do
        printf '  - %s\n' "$(basename "$file")"
        mapfile -t blocks < <(list_server_blocks "$file")
        for block in "${blocks[@]}"; do
            IFS=$'\t' read -r start end label <<< "$block"
            enabled="否"
            if server_block_enabled "$file" "$start" "$end"; then
                enabled="是"
            fi
            printf '      server_name=%s | 行=%s-%s | 已启用=%s\n' "$label" "$start" "$end" "$enabled"
        done
    done
    show_status_separator
}

run_menu_action() {
    local choice="$1"
    MENU_RETURNED=0
    case "$choice" in
        1) show_section "查看状态"; show_status ;;
        2) show_section "添加白名单 IP/CIDR"; require_nginx_available && add_whitelist_ips ;;
        3) show_section "移除白名单 IP/CIDR"; require_nginx_available && remove_whitelist_ips ;;
        4) show_section "启用白名单"; require_nginx_available && enable_whitelist && offer_reload ;;
        5) show_section "禁用白名单"; require_nginx_available && disable_whitelist && offer_reload ;;
        6) show_section "检查 Nginx 配置"; require_nginx_available && nginx_test ;;
        7) show_section "Reload Nginx"; require_nginx_available && nginx_reload ;;
        h|help) show_section "帮助"; usage ;;
        *) printf '菜单选项无效：%s\n' "$choice" >&2; return 1 ;;
    esac
}

interactive_menu() {
    local choice rc

    while true; do
        show_header
        show_status
        printf '\n'
        if (( NGINX_AVAILABLE == 1 )); then
            cat <<'EOF'
请选择操作：
  1) 查看状态
  2) 添加白名单 IP/CIDR
  3) 移除白名单 IP/CIDR
  4) 启用白名单
  5) 禁用白名单
  6) 检查 Nginx 配置
  7) Reload Nginx
  h) 帮助

  0) 退出
EOF
        else
            cat <<'EOF'
请选择操作：
  1) 查看状态
  h) 帮助

  0) 退出
EOF
        fi
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
                pause_menu
                ;;
        esac
    done
}

usage() {
    cat <<'EOF'
用法：nginx_ip_whitelist.sh [命令] [参数]

不带参数运行会打开交互式菜单。会优先从 Docker/systemd/nginx 二进制推导正在使用的配置文件。

命令：
  menu                 打开交互式菜单
  status               查看白名单状态和站点配置
  add <IP/CIDR...>     添加一个或多个白名单 IP/CIDR
  remove <IP/CIDR...>  移除一个或多个白名单 IP/CIDR；也可在菜单中按编号移除
  enable               为选中的 server 块内 location 插入白名单 include
  disable              移除选中的 server 块内脚本插入的白名单 include
  check                执行 nginx -t
  reload               reload Nginx
  help                 显示帮助

环境变量：
  NGINX_IPWL_ROOT             nginx.conf 所在目录
  NGINX_IPWL_CONF_D           宿主机 conf.d 目录
  NGINX_IPWL_CONTAINER_CONF_D 容器内 conf.d 目录，默认从 nginx.conf include 自动检测
  NGINX_IPWL_INCLUDE_PATH     强制指定写入站点配置的 include 路径
  NGINX_IPWL_SITE_CONF        指定要管理的站点配置文件名或绝对路径
  NGINX_IPWL_SERVER_NAME      指定要管理的 server_name（同一文件多 server 时可用）
  NGINX_IPWL_CONTAINER_NAME   Docker 容器名，默认 nginx
  NGINX_IPWL_REVIEW_DIFF      是否在应用前预览 diff：ask/1/0，默认 ask（仅交互终端询问）

说明：
  Docker 场景需要 /etc/nginx、/etc/nginx/nginx.conf 或 conf.d 通过 bind mount 映射到宿主机。
  宿主机 Nginx 会优先读取 master 进程 -c、systemd ExecStart -c、nginx -V --conf-path。
EOF
}

main() {
    local cmd="${1:-menu}"

    init_paths || true

    case "$cmd" in
        menu) interactive_menu ;;
        status) show_status ;;
        add) shift; require_nginx_available && add_whitelist_ips "$@" ;;
        remove|rm) shift; require_nginx_available && remove_whitelist_ips "$@" ;;
        enable) require_nginx_available && enable_whitelist ;;
        disable) require_nginx_available && disable_whitelist ;;
        check) require_nginx_available && nginx_test ;;
        reload) require_nginx_available && nginx_reload ;;
        h|help|-h|--help) usage ;;
        *) printf '未知命令：%s\n' "$cmd" >&2; usage; exit 1 ;;
    esac
}

main "$@"
