#!/bin/bash
set -u

INSTALL_PATH="${ORACLE_KEEPALIVE_INSTALL_PATH:-/usr/local/bin/oracle_keepalive.sh}"
CONFIG_FILE="${ORACLE_KEEPALIVE_CONFIG:-/etc/oracle-keepalive.conf}"
SERVICE_FILE="${ORACLE_KEEPALIVE_SERVICE_FILE:-/etc/systemd/system/oracle-keepalive.service}"
SERVICE_NAME="oracle-keepalive.service"
LOCK_DIR="${ORACLE_KEEPALIVE_LOCK_DIR:-/run/oracle-keepalive.lock}"
SAFE_ROOT_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
PROJECT_URL="https://github.com/yhj945/tools"
TOOL_VERSION="v1.0.0"

if [[ "${EUID:-1}" == "0" ]]; then
    PATH="$SAFE_ROOT_PATH"
    export PATH
fi

KEEPALIVE_CPU_ENABLED="${KEEPALIVE_CPU_ENABLED:-1}"
KEEPALIVE_CPU_TARGET_PERCENT="${KEEPALIVE_CPU_TARGET_PERCENT:-25}"
KEEPALIVE_CPU_CYCLE_SECONDS="${KEEPALIVE_CPU_CYCLE_SECONDS:-10}"
KEEPALIVE_MEMORY_ENABLED="${KEEPALIVE_MEMORY_ENABLED:-1}"
KEEPALIVE_MEMORY_TARGET_PERCENT="${KEEPALIVE_MEMORY_TARGET_PERCENT:-25}"
KEEPALIVE_MEMORY_MAX_MB="${KEEPALIVE_MEMORY_MAX_MB:-0}"
KEEPALIVE_MEMORY_HOLD_SECONDS="${KEEPALIVE_MEMORY_HOLD_SECONDS:-300}"
KEEPALIVE_MEMORY_REST_SECONDS="${KEEPALIVE_MEMORY_REST_SECONDS:-300}"
KEEPALIVE_NETWORK_ENABLED="${KEEPALIVE_NETWORK_ENABLED:-1}"
KEEPALIVE_NETWORK_INTERVAL_SECONDS="${KEEPALIVE_NETWORK_INTERVAL_SECONDS:-2700}"
KEEPALIVE_NETWORK_DURATION_SECONDS="${KEEPALIVE_NETWORK_DURATION_SECONDS:-180}"
KEEPALIVE_NETWORK_RATE_LIMIT="${KEEPALIVE_NETWORK_RATE_LIMIT:-512k}"
KEEPALIVE_NETWORK_URLS="${KEEPALIVE_NETWORK_URLS:-https://speed.cloudflare.com/__down?bytes=1000000000 https://speed.hetzner.de/1GB.bin http://proof.ovh.net/files/1Gio.dat}"

CPU_PIDS=""
MEMORY_LOOP_PID=""
NETWORK_LOOP_PID=""

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

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

normalize_bool() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
        *) printf '0\n' ;;
    esac
}

validate_keepalive_methods() {
    if [[ "$KEEPALIVE_CPU_ENABLED" == "1" || "$KEEPALIVE_MEMORY_ENABLED" == "1" || "$KEEPALIVE_NETWORK_ENABLED" == "1" ]]; then
        return 0
    fi

    printf '至少需要启用一种保活方式。\n' >&2
    return 1
}

validate_network_url() {
    local url="$1"

    if [[ -z "$url" || "$url" == -* || "$url" =~ [[:cntrl:]] ]]; then
        printf '网络 URL 不安全。\n' >&2
        return 1
    fi
    case "$url" in
        http://*|https://*) return 0 ;;
        *)
            printf '网络 URL 不安全。\n' >&2
            return 1
            ;;
    esac
}

validate_network_urls() {
    local urls url

    if [[ "$KEEPALIVE_NETWORK_URLS" =~ [[:cntrl:]] ]]; then
        printf '网络 URL 不安全。\n' >&2
        return 1
    fi
    [[ "$KEEPALIVE_NETWORK_ENABLED" == "1" ]] || return 0
    read -r -a urls <<< "$KEEPALIVE_NETWORK_URLS"
    if (( ${#urls[@]} == 0 )); then
        return 0
    fi
    for url in "${urls[@]}"; do
        validate_network_url "$url" || return $?
    done
    return 0
}

validate_network_rate_limit() {
    if [[ "$KEEPALIVE_NETWORK_RATE_LIMIT" =~ ^[0-9]+[kKmMgG]?$ ]]; then
        return 0
    fi

    printf '网络限速参数不安全。\n' >&2
    return 1
}

need_root() {
    if [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
        printf '请使用 root 运行此命令。\n' >&2
        exit 1
    fi
}

strip_config_quotes() {
    local value="$1"

    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value#\"}"
        value="${value%\"}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi
    printf '%s\n' "$value"
}

load_config() {
    local line key value

    [[ -r "$CONFIG_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="$(strip_config_quotes "${line#*=}")"
        case "$key" in
            KEEPALIVE_CPU_ENABLED|KEEPALIVE_CPU_TARGET_PERCENT|KEEPALIVE_CPU_CYCLE_SECONDS|\
            KEEPALIVE_MEMORY_ENABLED|KEEPALIVE_MEMORY_TARGET_PERCENT|KEEPALIVE_MEMORY_MAX_MB|\
            KEEPALIVE_MEMORY_HOLD_SECONDS|KEEPALIVE_MEMORY_REST_SECONDS|KEEPALIVE_NETWORK_ENABLED|\
            KEEPALIVE_NETWORK_INTERVAL_SECONDS|KEEPALIVE_NETWORK_DURATION_SECONDS|KEEPALIVE_NETWORK_RATE_LIMIT|\
            KEEPALIVE_NETWORK_URLS)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$CONFIG_FILE"
}

validate_plain_path() {
    local label="$1"
    local path="$2"

    if [[ -z "$path" || "$path" != /* || "$path" == -* || "$path" =~ [[:space:]] ]]; then
        printf '%s 路径不安全：%s\n' "$label" "$path" >&2
        return 1
    fi
    case "$path" in
        *'*'*|*'?'*|*'['*|*']'*|*'%'*)
            printf '%s 路径不安全：%s\n' "$label" "$path" >&2
            return 1
            ;;
    esac
    return 0
}

validate_install_paths() {
    validate_plain_path ORACLE_KEEPALIVE_INSTALL_PATH "$INSTALL_PATH" || return $?
    validate_plain_path ORACLE_KEEPALIVE_CONFIG "$CONFIG_FILE" || return $?
    validate_plain_path ORACLE_KEEPALIVE_SERVICE_FILE "$SERVICE_FILE" || return $?
}

normalize_config() {
    KEEPALIVE_CPU_ENABLED="$(normalize_bool "$KEEPALIVE_CPU_ENABLED")"
    KEEPALIVE_MEMORY_ENABLED="$(normalize_bool "$KEEPALIVE_MEMORY_ENABLED")"
    KEEPALIVE_NETWORK_ENABLED="$(normalize_bool "$KEEPALIVE_NETWORK_ENABLED")"

    is_uint "$KEEPALIVE_CPU_TARGET_PERCENT" || KEEPALIVE_CPU_TARGET_PERCENT=25
    is_uint "$KEEPALIVE_CPU_CYCLE_SECONDS" || KEEPALIVE_CPU_CYCLE_SECONDS=10
    is_uint "$KEEPALIVE_MEMORY_TARGET_PERCENT" || KEEPALIVE_MEMORY_TARGET_PERCENT=25
    is_uint "$KEEPALIVE_MEMORY_MAX_MB" || KEEPALIVE_MEMORY_MAX_MB=0
    is_uint "$KEEPALIVE_MEMORY_HOLD_SECONDS" || KEEPALIVE_MEMORY_HOLD_SECONDS=300
    is_uint "$KEEPALIVE_MEMORY_REST_SECONDS" || KEEPALIVE_MEMORY_REST_SECONDS=300
    is_uint "$KEEPALIVE_NETWORK_INTERVAL_SECONDS" || KEEPALIVE_NETWORK_INTERVAL_SECONDS=2700
    is_uint "$KEEPALIVE_NETWORK_DURATION_SECONDS" || KEEPALIVE_NETWORK_DURATION_SECONDS=180

    (( KEEPALIVE_CPU_TARGET_PERCENT >= 1 )) || KEEPALIVE_CPU_TARGET_PERCENT=25
    (( KEEPALIVE_CPU_TARGET_PERCENT <= 80 )) || KEEPALIVE_CPU_TARGET_PERCENT=80
    (( KEEPALIVE_CPU_CYCLE_SECONDS >= 2 )) || KEEPALIVE_CPU_CYCLE_SECONDS=10
    (( KEEPALIVE_MEMORY_TARGET_PERCENT >= 1 )) || KEEPALIVE_MEMORY_TARGET_PERCENT=25
    (( KEEPALIVE_MEMORY_TARGET_PERCENT <= 80 )) || KEEPALIVE_MEMORY_TARGET_PERCENT=80
    (( KEEPALIVE_MEMORY_HOLD_SECONDS >= 1 )) || KEEPALIVE_MEMORY_HOLD_SECONDS=300
    (( KEEPALIVE_MEMORY_REST_SECONDS >= 1 )) || KEEPALIVE_MEMORY_REST_SECONDS=300
    (( KEEPALIVE_NETWORK_INTERVAL_SECONDS >= 60 )) || KEEPALIVE_NETWORK_INTERVAL_SECONDS=2700
    (( KEEPALIVE_NETWORK_DURATION_SECONDS >= 1 )) || KEEPALIVE_NETWORK_DURATION_SECONDS=180

    validate_keepalive_methods || return $?
    validate_network_rate_limit || return $?
    validate_network_urls
}

get_cores() {
    local cores=""

    cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if ! is_uint "$cores" || (( cores < 1 )); then
        cores="$(awk '/^processor[[:space:]]*:/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null || true)"
    fi
    if ! is_uint "$cores" || (( cores < 1 )); then
        cores=1
    fi

    printf '%s\n' "$cores"
}

cpu_worker() {
    local busy_seconds="$1"
    local idle_seconds="$2"
    local load_pid=""

    cleanup_cpu_worker() {
        [[ -n "$load_pid" ]] && kill "$load_pid" 2>/dev/null || true
        [[ -n "$load_pid" ]] && wait "$load_pid" 2>/dev/null || true
        exit 0
    }

    trap cleanup_cpu_worker INT TERM
    while true; do
        if command -v yes >/dev/null 2>&1; then
            yes >/dev/null &
        else
            dd if=/dev/zero of=/dev/null bs=1048576 count=4096 >/dev/null 2>&1 &
        fi

        load_pid=$!
        sleep "$busy_seconds"
        kill "$load_pid" 2>/dev/null || true
        wait "$load_pid" 2>/dev/null || true
        load_pid=""
        (( idle_seconds > 0 )) && sleep "$idle_seconds"
    done
}

start_cpu_loop() {
    local cores total_slots target_slots full_workers partial_percent busy idle started

    cores="$(get_cores)"
    total_slots=$((cores * 100))
    target_slots=$((cores * KEEPALIVE_CPU_TARGET_PERCENT))
    (( target_slots > total_slots )) && target_slots=$total_slots

    full_workers=$((target_slots / 100))
    partial_percent=$((target_slots % 100))
    started=0

    while (( started < full_workers && started < cores )); do
        cpu_worker "$KEEPALIVE_CPU_CYCLE_SECONDS" 0 &
        CPU_PIDS="$CPU_PIDS $!"
        started=$((started + 1))
    done

    if (( partial_percent > 0 && started < cores )); then
        busy=$((KEEPALIVE_CPU_CYCLE_SECONDS * partial_percent / 100))
        (( busy >= 1 )) || busy=1
        (( busy <= KEEPALIVE_CPU_CYCLE_SECONDS )) || busy=$KEEPALIVE_CPU_CYCLE_SECONDS
        idle=$((KEEPALIVE_CPU_CYCLE_SECONDS - busy))
        cpu_worker "$busy" "$idle" &
        CPU_PIDS="$CPU_PIDS $!"
    fi

    log "CPU 保活已启动：核心数=$cores 目标=${KEEPALIVE_CPU_TARGET_PERCENT}% pids=$CPU_PIDS"
}

mem_total_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

mem_available_kb() {
    awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

memory_pressure_python() {
    local mb="$1"

    python3 - "$mb" <<'PY'
import sys
import time
mb = int(sys.argv[1])
block = bytearray(mb * 1024 * 1024)
for index in range(0, len(block), 4096):
    block[index] = 1
time.sleep(10 ** 8)
PY
}

memory_pressure_fallback() {
    local mb="$1"
    local file=""

    file="$(mktemp "${TMPDIR:-/tmp}/oracle-keepalive-memory.XXXXXX")" || return 1
    cleanup_file() {
        rm -f "$file" 2>/dev/null || true
        exit 0
    }

    dd if=/dev/zero of="$file" bs=1048576 count="$mb" conv=notrunc >/dev/null 2>&1 || return 1
    trap cleanup_file INT TERM
    sleep 100000000
}

run_memory_once() {
    local total available used target need_kb need_mb cap_mb pressure_pid=""

    cleanup_memory_pressure() {
        [[ -n "$pressure_pid" ]] && kill "$pressure_pid" 2>/dev/null || true
        [[ -n "$pressure_pid" ]] && wait "$pressure_pid" 2>/dev/null || true
        exit 0
    }
    trap cleanup_memory_pressure INT TERM

    total="$(mem_total_kb || true)"
    available="$(mem_available_kb || true)"
    if ! is_uint "$total" || ! is_uint "$available" || (( total <= 0 )); then
        log "无法读取内存指标，本轮跳过"
        return 0
    fi

    used=$((total - available))
    (( used >= 0 )) || used=0
    target=$((total * KEEPALIVE_MEMORY_TARGET_PERCENT / 100))
    if (( used >= target )); then
        log "内存使用率已达到目标：used_kb=$used target_kb=$target"
        return 0
    fi

    need_kb=$((target - used))
    need_mb=$((need_kb / 1024))
    (( need_mb >= 1 )) || need_mb=1

    cap_mb="$KEEPALIVE_MEMORY_MAX_MB"
    if (( cap_mb == 0 )); then
        cap_mb=$((available / 1024 - 128))
        (( cap_mb >= 1 )) || cap_mb=1
    fi
    (( need_mb <= cap_mb )) || need_mb=$cap_mb

    log "内存保活分配 ${need_mb}MB，保持 ${KEEPALIVE_MEMORY_HOLD_SECONDS}s"
    if command -v python3 >/dev/null 2>&1; then
        memory_pressure_python "$need_mb" &
    else
        memory_pressure_fallback "$need_mb" &
    fi
    pressure_pid=$!
    sleep "$KEEPALIVE_MEMORY_HOLD_SECONDS"
    kill "$pressure_pid" 2>/dev/null || true
    wait "$pressure_pid" 2>/dev/null || true
    pressure_pid=""
}

memory_loop() {
    trap 'exit 0' INT TERM
    while true; do
        run_memory_once
        sleep "$KEEPALIVE_MEMORY_REST_SECONDS"
    done
}

pick_network_url() {
    local minute index current count

    read -r -a urls <<< "$KEEPALIVE_NETWORK_URLS"
    count="${#urls[@]}"
    if (( count == 0 )); then
        printf '%s\n' 'https://speed.cloudflare.com/__down?bytes=1000000000'
        return 0
    fi

    minute="$(date '+%M' 2>/dev/null || echo 0)"
    is_uint "$minute" || minute=0
    index=$((10#$minute % count))
    current="${urls[$index]}"
    printf '%s\n' "$current"
}

run_network_once() {
    [[ "$KEEPALIVE_NETWORK_ENABLED" == "1" ]] || return 0

    local url net_pid=""
    cleanup_network() {
        [[ -n "$net_pid" ]] && kill "$net_pid" 2>/dev/null || true
        [[ -n "$net_pid" ]] && wait "$net_pid" 2>/dev/null || true
        exit 0
    }
    trap cleanup_network INT TERM

    url="$(pick_network_url)"
    log "网络保活下载 ${KEEPALIVE_NETWORK_DURATION_SECONDS}s，限速 ${KEEPALIVE_NETWORK_RATE_LIMIT}：$url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time "$KEEPALIVE_NETWORK_DURATION_SECONDS" --limit-rate "$KEEPALIVE_NETWORK_RATE_LIMIT" -o /dev/null -- "$url" &
        net_pid=$!
        wait "$net_pid" 2>/dev/null || true
        net_pid=""
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        timeout "$KEEPALIVE_NETWORK_DURATION_SECONDS" wget -q --timeout=10 --tries=1 --limit-rate="$KEEPALIVE_NETWORK_RATE_LIMIT" -O /dev/null -- "$url" &
        net_pid=$!
        wait "$net_pid" 2>/dev/null || true
        net_pid=""
        return 0
    fi

    log "未找到 curl 或 wget，跳过网络保活"
}

network_loop() {
    trap 'exit 0' INT TERM
    while true; do
        run_network_once
        sleep "$KEEPALIVE_NETWORK_INTERVAL_SECONDS"
    done
}

remove_lock_dir_safely() {
    if [[ -L "$LOCK_DIR" ]]; then
        log "锁路径是符号链接，拒绝清理：$LOCK_DIR"
        return 1
    fi
    if [[ ! -d "$LOCK_DIR" ]]; then
        return 0
    fi
    if [[ -L "$LOCK_DIR/pid" ]]; then
        log "锁 pid 是符号链接，拒绝清理：$LOCK_DIR/pid"
        return 1
    fi

    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    if rmdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi

    log "锁目录包含非预期文件，拒绝递归删除：$LOCK_DIR"
    return 1
}

acquire_lock() {
    if [[ -L "$LOCK_DIR" ]]; then
        log "锁路径是符号链接，拒绝启动：$LOCK_DIR"
        exit 1
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    if [[ -L "$LOCK_DIR/pid" ]]; then
        log "锁 pid 是符号链接，拒绝启动：$LOCK_DIR/pid"
        exit 1
    fi

    local old_pid=""
    [[ -r "$LOCK_DIR/pid" ]] && old_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    if is_uint "$old_pid" && kill -0 "$old_pid" 2>/dev/null; then
        log "已经在运行，PID=$old_pid"
        exit 0
    fi

    remove_lock_dir_safely || exit 1
    mkdir "$LOCK_DIR" || exit 1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

kill_process_tree() {
    local signal="$1"
    local parent_pid="$2"
    local child_pid

    [[ -n "$parent_pid" ]] || return 0
    if command -v pgrep >/dev/null 2>&1; then
        while IFS= read -r child_pid; do
            [[ -n "$child_pid" ]] || continue
            kill_process_tree "$signal" "$child_pid"
        done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
    fi
    kill "-$signal" "$parent_pid" 2>/dev/null || true
}

cleanup() {
    trap - INT TERM EXIT
    local pid

    for pid in $CPU_PIDS "$MEMORY_LOOP_PID" "$NETWORK_LOOP_PID"; do
        kill_process_tree TERM "${pid:-}"
    done
    sleep 0.2
    for pid in $CPU_PIDS "$MEMORY_LOOP_PID" "$NETWORK_LOOP_PID"; do
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill_process_tree KILL "$pid"
        fi
    done
    wait 2>/dev/null || true
    remove_lock_dir_safely 2>/dev/null || true
}

run_daemon() {
    load_config
    normalize_config || exit $?
    acquire_lock
    trap cleanup EXIT
    trap 'cleanup; exit 0' INT TERM

    if [[ "$KEEPALIVE_CPU_ENABLED" == "1" ]]; then
        start_cpu_loop
    fi
    if [[ "$KEEPALIVE_MEMORY_ENABLED" == "1" ]]; then
        memory_loop &
        MEMORY_LOOP_PID=$!
    fi
    if [[ "$KEEPALIVE_NETWORK_ENABLED" == "1" ]]; then
        network_loop &
        NETWORK_LOOP_PID=$!
    fi
    wait
}

config_quote() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"\n' "$value"
}

render_config() {
    cat <<EOF
KEEPALIVE_CPU_ENABLED=$KEEPALIVE_CPU_ENABLED
KEEPALIVE_CPU_TARGET_PERCENT=$KEEPALIVE_CPU_TARGET_PERCENT
KEEPALIVE_CPU_CYCLE_SECONDS=$KEEPALIVE_CPU_CYCLE_SECONDS
KEEPALIVE_MEMORY_ENABLED=$KEEPALIVE_MEMORY_ENABLED
KEEPALIVE_MEMORY_TARGET_PERCENT=$KEEPALIVE_MEMORY_TARGET_PERCENT
KEEPALIVE_MEMORY_MAX_MB=$KEEPALIVE_MEMORY_MAX_MB
KEEPALIVE_MEMORY_HOLD_SECONDS=$KEEPALIVE_MEMORY_HOLD_SECONDS
KEEPALIVE_MEMORY_REST_SECONDS=$KEEPALIVE_MEMORY_REST_SECONDS
KEEPALIVE_NETWORK_ENABLED=$KEEPALIVE_NETWORK_ENABLED
KEEPALIVE_NETWORK_INTERVAL_SECONDS=$KEEPALIVE_NETWORK_INTERVAL_SECONDS
KEEPALIVE_NETWORK_DURATION_SECONDS=$KEEPALIVE_NETWORK_DURATION_SECONDS
KEEPALIVE_NETWORK_RATE_LIMIT=$KEEPALIVE_NETWORK_RATE_LIMIT
KEEPALIVE_NETWORK_URLS=$(config_quote "$KEEPALIVE_NETWORK_URLS")
EOF
}

render_service() {
    local cores quota

    cores="$(get_cores)"
    quota="$((cores * KEEPALIVE_CPU_TARGET_PERCENT))%"

    cat <<EOF
[Unit]
Description=Oracle 低干扰保活服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$CONFIG_FILE
Environment=PATH=$SAFE_ROOT_PATH
ExecStart=$INSTALL_PATH run
Restart=always
RestartSec=30
Nice=19
CPUWeight=1
CPUQuota=$quota
IOSchedulingClass=idle
OOMScoreAdjust=500
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

install_service() {
    validate_install_paths || return $?
    load_config
    normalize_config || return $?
    if [[ "${ORACLE_KEEPALIVE_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY-RUN] 将写入配置：%s\n' "$CONFIG_FILE"
        render_config
        printf '[DRY-RUN] 将写入 systemd unit：%s\n' "$SERVICE_FILE"
        render_service
        return 0
    fi

    need_root
    install -m 755 "$0" "$INSTALL_PATH" || return $?
    render_config > "$CONFIG_FILE" || return $?
    chmod 600 "$CONFIG_FILE" || return $?
    render_service > "$SERVICE_FILE" || return $?
    systemctl daemon-reload || return $?
    systemctl enable --now "$SERVICE_NAME" || return $?
    log "已安装并启动 $SERVICE_NAME"
}

uninstall_service() {
    validate_install_paths || return $?
    if [[ "${ORACLE_KEEPALIVE_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY-RUN] 将停止并移除 %s\n' "$SERVICE_NAME"
        return 0
    fi

    need_root
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$INSTALL_PATH"
    remove_lock_dir_safely || return $?
    systemctl daemon-reload 2>/dev/null || true
    log "已卸载 $SERVICE_NAME"
}

status_service() {
    systemctl status "$SERVICE_NAME" --no-pager
}

logs_service() {
    local follow_choice

    if [[ ! -f "$SERVICE_FILE" ]]; then
        printf '保活 systemd 服务尚未安装：%s\n' "$SERVICE_NAME" >&2
        printf '请先选择 [3] 安装/更新并启动 systemd 服务。\n' >&2
        return 1
    fi
    if ! command -v journalctl >/dev/null 2>&1; then
        printf '未找到 journalctl，无法查看 systemd 日志。\n' >&2
        return 1
    fi

    printf '查看服务日志：%s\n' "$SERVICE_NAME"
    printf '先显示最近 80 行日志；是否继续跟随实时日志？\n'
    printf '进入实时日志后按 Ctrl+C 返回菜单。\n\n'
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || return $?
    printf '\n是否跟随实时日志？[y/N]：'
    IFS= read -r follow_choice || return 0
    case "$follow_choice" in
        y|Y|yes|YES)
            printf '正在跟随 %s 日志，按 Ctrl+C 返回菜单。\n' "$SERVICE_NAME"
            journalctl -u "$SERVICE_NAME" -f
            ;;
    esac
}

stop_service() {
    need_root
    systemctl stop "$SERVICE_NAME"
    log "已停止 $SERVICE_NAME"
}

restart_service() {
    need_root
    systemctl restart "$SERVICE_NAME"
    log "已重启 $SERVICE_NAME"
}

lock_running_pid() {
    local pid=""

    if [[ -r "$LOCK_DIR/pid" && ! -L "$LOCK_DIR/pid" ]]; then
        pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
        if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$pid"
            return 0
        fi
    fi
    return 1
}

systemd_service_state() {
    command -v systemctl >/dev/null 2>&1 || {
        printf '不可用\n'
        return 1
    }
    systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
}

keepalive_is_running() {
    local state

    if lock_running_pid >/dev/null 2>&1; then
        return 0
    fi
    state="$(systemd_service_state)"
    [[ "$state" == "active" ]]
}

enabled_methods_label() {
    local methods=() method label="" separator=""

    [[ "$KEEPALIVE_CPU_ENABLED" == "1" ]] && methods+=("CPU")
    [[ "$KEEPALIVE_MEMORY_ENABLED" == "1" ]] && methods+=("内存")
    [[ "$KEEPALIVE_NETWORK_ENABLED" == "1" ]] && methods+=("网络")
    if (( ${#methods[@]} == 0 )); then
        printf '无\n'
    else
        for method in "${methods[@]}"; do
            label="${label}${separator}${method}"
            separator="、"
        done
        printf '%s\n' "$label"
    fi
}

show_header() {
    printf '\n'
    printf '%b' "$CYAN"
    cat <<'EOF'
  ___                 _        _  __                 _      _    _ _
 / _ \ _ __ __ _  ___| | ___  | |/ /___  ___ _ __   / \    | |  (_) |_   _____
| | | | '__/ _` |/ __| |/ _ \ | ' // _ \/ _ \ '_ \ / _ \   | |  | | \ \ / / _ \
| |_| | | | (_| | (__| |  __/ | . \  __/  __/ |_) / ___ \  | |__| | |\ V /  __/
 \___/|_|  \__,_|\___|_|\___| |_|\_\___|\___| .__/_/   \_\ |____|_|_| \_/ \___|
                                            |_|
EOF
    printf '%b' "$NC"
    printf '%b\n' "${GREEN}Oracle Always Free 低干扰保活与 systemd 管理工具${NC}"
    printf 'GitHub: %s  Version: %s  Script: oracle/oracle_keepalive.sh\n' "$PROJECT_URL" "$TOOL_VERSION"
    printf '%b\n' "${BOLD}------------------------------------------------------------${NC}"
    printf '%b\n' "${BOLD}[ Oracle Always Free 保活工具 控制台 ]${NC}"
    printf '%b\n\n' "${BOLD}------------------------------------------------------------${NC}"
}

show_section() {
    printf '\n'
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}$1${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
}

show_menu_status() {
    local config_state config_note methods state pid=""

    load_config
    if normalize_config >/dev/null 2>&1; then
        config_state="${GREEN}✓${NC}"
        if [[ -r "$CONFIG_FILE" ]]; then
            config_note="已加载配置：$CONFIG_FILE"
        else
            config_note="使用脚本默认配置（尚未安装配置文件）"
        fi
        methods="$(enabled_methods_label)"
    else
        config_state="${YELLOW}!${NC}"
        config_note="配置校验失败，请执行 [6] 查看详情"
        methods="不可用"
    fi

    printf '%b %s\n' "$config_state" "$config_note"
    printf '  配置启用方式：%s\n' "$methods"

    if [[ -f "$SERVICE_FILE" ]]; then
        state="$(systemd_service_state)"
        case "$state" in
            active) printf '%b systemd 服务已安装并正在运行\n' "${GREEN}✓${NC}" ;;
            inactive|failed|activating|deactivating) printf '%b systemd 服务已安装，当前状态：%s\n' "${YELLOW}!${NC}" "$state" ;;
            *) printf '%b systemd 服务已安装，状态未知或 systemctl 不可用\n' "${YELLOW}!${NC}" ;;
        esac
    else
        printf '%b systemd 服务尚未安装\n' "${YELLOW}!${NC}"
    fi

    if pid="$(lock_running_pid 2>/dev/null)"; then
        printf '%b 检测到保活进程正在运行，PID=%s\n' "${GREEN}✓${NC}" "$pid"
    else
        printf '%b 未检测到正在运行的保活进程\n' "${YELLOW}!${NC}"
    fi
}

current_memory_percent() {
    local total available used

    total="$(mem_total_kb || true)"
    available="$(mem_available_kb || true)"
    if ! is_uint "$total" || ! is_uint "$available" || (( total <= 0 )); then
        return 1
    fi
    used=$((total - available))
    (( used >= 0 )) || used=0
    printf '%s\n' $((used * 100 / total))
}

read_proc_cpu_totals() {
    local stat_file="${KEEPALIVE_VERIFY_CPU_STAT_FILE:-/proc/stat}"
    local label user nice system idle iowait irq softirq steal guest guest_nice total idle_all

    [[ -r "$stat_file" ]] || return 1
    read -r label user nice system idle iowait irq softirq steal guest guest_nice < "$stat_file" || return 1
    [[ "$label" == "cpu" ]] || return 1
    for value in "$user" "$nice" "$system" "$idle" "${iowait:-0}" "${irq:-0}" "${softirq:-0}" "${steal:-0}" "${guest:-0}" "${guest_nice:-0}"; do
        is_uint "$value" || return 1
    done
    idle_all=$((idle + ${iowait:-0}))
    total=$((user + nice + system + idle + ${iowait:-0} + ${irq:-0} + ${softirq:-0} + ${steal:-0} + ${guest:-0} + ${guest_nice:-0}))
    printf '%s %s\n' "$idle_all" "$total"
}

current_cpu_percent_from_proc() {
    local first second idle1 total1 idle2 total2 idle_delta total_delta busy_delta sample_seconds

    first="$(read_proc_cpu_totals || true)"
    [[ -n "$first" ]] || return 1
    read -r idle1 total1 <<< "$first"
    sample_seconds="${KEEPALIVE_VERIFY_CPU_SAMPLE_SECONDS:-1}"
    is_uint "$sample_seconds" || sample_seconds=1
    (( sample_seconds >= 1 )) || sample_seconds=1
    sleep "$sample_seconds"
    second="$(read_proc_cpu_totals || true)"
    [[ -n "$second" ]] || return 1
    read -r idle2 total2 <<< "$second"
    total_delta=$((total2 - total1))
    idle_delta=$((idle2 - idle1))
    (( total_delta > 0 && idle_delta >= 0 )) || return 1
    busy_delta=$((total_delta - idle_delta))
    (( busy_delta >= 0 )) || busy_delta=0
    printf '%s\n' $((busy_delta * 100 / total_delta))
}

current_cpu_percent_from_ps() {
    local cores

    command -v ps >/dev/null 2>&1 || return 1
    cores="$(get_cores)"
    ps -A -o %cpu= 2>/dev/null | awk -v cores="$cores" '
        { sum += $1 }
        END {
            if (cores < 1) cores = 1
            printf "%d\n", (sum / cores) + 0.5
        }
    '
}

current_cpu_percent() {
    local current

    current="$(current_cpu_percent_from_proc || true)"
    if is_uint "$current"; then
        printf '%s\n' "$current"
        return 0
    fi
    current="$(current_cpu_percent_from_ps || true)"
    if is_uint "$current"; then
        printf '%s\n' "$current"
        return 0
    fi
    return 1
}

verify_cpu() {
    local current="${KEEPALIVE_VERIFY_CPU_PERCENT:-}"

    if [[ "$KEEPALIVE_CPU_ENABLED" != "1" ]]; then
        printf 'CPU：跳过\n'
        return 0
    fi
    if ! is_uint "$current"; then
        current="$(current_cpu_percent || true)"
    fi
    if ! is_uint "$current"; then
        printf 'CPU：失败 当前=未知 目标=%s%%\n' "$KEEPALIVE_CPU_TARGET_PERCENT"
        return 1
    fi
    if (( current >= KEEPALIVE_CPU_TARGET_PERCENT )); then
        printf 'CPU：通过 当前=%s%% 目标=%s%%\n' "$current" "$KEEPALIVE_CPU_TARGET_PERCENT"
        return 0
    fi
    printf 'CPU：失败 当前=%s%% 目标=%s%%\n' "$current" "$KEEPALIVE_CPU_TARGET_PERCENT"
    return 1
}

verify_memory() {
    local current="${KEEPALIVE_VERIFY_MEMORY_PERCENT:-}"

    if [[ "$KEEPALIVE_MEMORY_ENABLED" != "1" ]]; then
        printf '内存：跳过\n'
        return 0
    fi
    if ! is_uint "$current"; then
        current="$(current_memory_percent || true)"
    fi
    if ! is_uint "$current"; then
        printf '内存：失败 当前=未知 目标=%s%%\n' "$KEEPALIVE_MEMORY_TARGET_PERCENT"
        return 1
    fi
    if (( current >= KEEPALIVE_MEMORY_TARGET_PERCENT )); then
        printf '内存：通过 当前=%s%% 目标=%s%%\n' "$current" "$KEEPALIVE_MEMORY_TARGET_PERCENT"
        return 0
    fi
    printf '内存：失败 当前=%s%% 目标=%s%%\n' "$current" "$KEEPALIVE_MEMORY_TARGET_PERCENT"
    return 1
}

verify_network() {
    local url tmp_file rc

    if [[ "$KEEPALIVE_NETWORK_ENABLED" != "1" ]]; then
        printf '网络：跳过\n'
        return 0
    fi
    url="$(pick_network_url)"
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/oracle-keepalive-network.XXXXXX")" || return 1

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time "$KEEPALIVE_NETWORK_DURATION_SECONDS" --limit-rate "$KEEPALIVE_NETWORK_RATE_LIMIT" -o "$tmp_file" -- "$url"
        rc=$?
    elif command -v wget >/dev/null 2>&1; then
        timeout "$KEEPALIVE_NETWORK_DURATION_SECONDS" wget -q --timeout=10 --tries=1 --limit-rate="$KEEPALIVE_NETWORK_RATE_LIMIT" -O "$tmp_file" -- "$url"
        rc=$?
    else
        rm -f "$tmp_file" 2>/dev/null || true
        printf '网络：失败，curl/wget 不可用\n'
        return 1
    fi

    if [[ -s "$tmp_file" ]]; then
        rm -f "$tmp_file" 2>/dev/null || true
        printf '网络：通过 url=%s\n' "$url"
        return 0
    fi

    rm -f "$tmp_file" 2>/dev/null || true
    printf '网络：失败 url=%s rc=%s\n' "$url" "$rc"
    return 1
}

verify_keepalive() {
    load_config
    normalize_config || return $?

    if ! keepalive_is_running; then
        printf '未检测到正在运行的保活服务或前台保活进程。\n' >&2
        printf '请先选择 [2] 前台试运行，或选择 [3] 安装并启动 systemd 服务。\n' >&2
        return 1
    fi

    printf '已检测到保活进程正在运行，开始验证当前配置启用的方式：%s\n' "$(enabled_methods_label)"
    local rc=0
    verify_cpu || rc=1
    verify_memory || rc=1
    verify_network || rc=1
    return $rc
}

check_script() {
    load_config
    normalize_config || return $?
    printf '%s\n' "oracle_keepalive.sh 检查通过"
}

show_config_summary() {
    load_config
    normalize_config || return $?

    printf '配置文件：%s\n' "$CONFIG_FILE"
    if [[ -r "$CONFIG_FILE" ]]; then
        printf '配置来源：已安装配置文件\n'
    else
        printf '配置来源：脚本默认值\n'
    fi
    printf '启用方式：%s\n' "$(enabled_methods_label)"
    printf 'CPU：启用=%s 目标=%s%% 周期=%ss\n' "$KEEPALIVE_CPU_ENABLED" "$KEEPALIVE_CPU_TARGET_PERCENT" "$KEEPALIVE_CPU_CYCLE_SECONDS"
    printf '内存：启用=%s 目标=%s%% 单轮上限=%sMB 保持=%ss 休息=%ss\n' \
        "$KEEPALIVE_MEMORY_ENABLED" "$KEEPALIVE_MEMORY_TARGET_PERCENT" "$KEEPALIVE_MEMORY_MAX_MB" \
        "$KEEPALIVE_MEMORY_HOLD_SECONDS" "$KEEPALIVE_MEMORY_REST_SECONDS"
    printf '网络：启用=%s 间隔=%ss 持续=%ss 限速=%s\n' \
        "$KEEPALIVE_NETWORK_ENABLED" "$KEEPALIVE_NETWORK_INTERVAL_SECONDS" \
        "$KEEPALIVE_NETWORK_DURATION_SECONDS" "$KEEPALIVE_NETWORK_RATE_LIMIT"
}

pause_menu() {
    printf '\n按回车键继续...'
    IFS= read -r _ || true
    printf '\n'
}

run_menu_action() {
    case "$1" in
        1) show_section "查看状态和配置"; show_menu_status; printf '\n'; show_config_summary ;;
        2) show_section "前台试运行保活进程"; run_daemon ;;
        3) show_section "安装/更新并启动 systemd 服务"; ( install_service ) ;;
        4) show_section "重启 systemd 服务"; ( restart_service ) ;;
        5) show_section "停止 systemd 服务"; ( stop_service ) ;;
        6) show_section "查看 systemd 服务日志"; logs_service ;;
        7) show_section "验证正在运行的保活效果"; verify_keepalive ;;
        8) show_section "检查配置"; show_config_summary; printf '\n'; check_script ;;
        9) show_section "卸载 systemd 服务"; ( uninstall_service ) ;;
        h|help) show_section "帮助"; usage ;;
        *) printf '菜单选项无效：%s\n' "$1" >&2; return 1 ;;
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
  1) 查看状态和配置
  2) 前台试运行保活进程
  3) 安装/更新并启动 systemd 服务
  4) 重启 systemd 服务
  5) 停止 systemd 服务
  6) 查看 systemd 服务日志
  7) 验证正在运行的保活效果
  8) 检查配置
  9) 卸载 systemd 服务
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
                if (( rc == 0 )) && [[ "$choice" == "2" || "$choice" == "6" ]]; then
                    continue
                fi
                pause_menu
                ;;
        esac
    done
}

usage() {
    cat <<'EOF'
用法：oracle_keepalive.sh [命令]

不带参数运行会打开交互式菜单。

命令：
  run        前台运行保活进程
  install    安装并启动 systemd 服务
  uninstall  停止并移除 systemd 服务
  stop       停止 systemd 服务
  restart    重启 systemd 服务
  status     查看 systemd 服务状态
  logs       查看 systemd 服务日志
  check      检查脚本配置
  verify     验证正在运行的保活效果
  help       显示帮助
EOF
}

case "${1:-menu}" in
    menu) interactive_menu ;;
    run) run_daemon ;;
    install) install_service ;;
    uninstall) uninstall_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) status_service ;;
    logs) logs_service ;;
    check) check_script ;;
    verify) verify_keepalive ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
