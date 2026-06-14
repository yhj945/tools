#!/bin/bash
set -u

INSTALL_PATH="${ORACLE_KEEPALIVE_INSTALL_PATH:-/usr/local/bin/oracle_keepalive.sh}"
CONFIG_FILE="${ORACLE_KEEPALIVE_CONFIG:-/etc/oracle-keepalive.conf}"
SERVICE_FILE="${ORACLE_KEEPALIVE_SERVICE_FILE:-/etc/systemd/system/oracle-keepalive.service}"
SERVICE_NAME="oracle-keepalive.service"
LOCK_DIR="${ORACLE_KEEPALIVE_LOCK_DIR:-/run/oracle-keepalive.lock}"
SAFE_ROOT_PATH="/usr/sbin:/usr/bin:/sbin:/bin"

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

    printf 'At least one keepalive method must be enabled.\n' >&2
    return 1
}

validate_network_url() {
    local url="$1"

    if [[ -z "$url" || "$url" == -* || "$url" =~ [[:cntrl:]] ]]; then
        printf 'Unsafe network URL\n' >&2
        return 1
    fi
    case "$url" in
        http://*|https://*) return 0 ;;
        *)
            printf 'Unsafe network URL\n' >&2
            return 1
            ;;
    esac
}

validate_network_urls() {
    local urls url

    if [[ "$KEEPALIVE_NETWORK_URLS" =~ [[:cntrl:]] ]]; then
        printf 'Unsafe network URL\n' >&2
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

    printf 'Unsafe network rate limit\n' >&2
    return 1
}

need_root() {
    if [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]]; then
        printf '请使用 root 运行此命令 / Please run this command as root\n' >&2
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
        printf 'Unsafe path for %s: %s\n' "$label" "$path" >&2
        return 1
    fi
    case "$path" in
        *'*'*|*'?'*|*'['*|*']'*|*'%'*)
            printf 'Unsafe path for %s: %s\n' "$label" "$path" >&2
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

    log "CPU keepalive started: cores=$cores target=${KEEPALIVE_CPU_TARGET_PERCENT}% pids=$CPU_PIDS"
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
        log "Memory metrics unavailable; skip this cycle"
        return 0
    fi

    used=$((total - available))
    (( used >= 0 )) || used=0
    target=$((total * KEEPALIVE_MEMORY_TARGET_PERCENT / 100))
    if (( used >= target )); then
        log "Memory already above target; used_kb=$used target_kb=$target"
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

    log "Memory keepalive allocating ${need_mb}MB for ${KEEPALIVE_MEMORY_HOLD_SECONDS}s"
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
    log "Network keepalive downloading for ${KEEPALIVE_NETWORK_DURATION_SECONDS}s at ${KEEPALIVE_NETWORK_RATE_LIMIT}: $url"
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

    log "No curl or wget found; skip network keepalive"
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
        log "Lock path is a symlink; refusing cleanup: $LOCK_DIR"
        return 1
    fi
    if [[ ! -d "$LOCK_DIR" ]]; then
        return 0
    fi
    if [[ -L "$LOCK_DIR/pid" ]]; then
        log "Lock pid is a symlink; refusing cleanup: $LOCK_DIR/pid"
        return 1
    fi

    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    if rmdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi

    log "Lock directory contains unexpected files; refusing recursive removal: $LOCK_DIR"
    return 1
}

acquire_lock() {
    if [[ -L "$LOCK_DIR" ]]; then
        log "Lock path is a symlink; refusing to start: $LOCK_DIR"
        exit 1
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    if [[ -L "$LOCK_DIR/pid" ]]; then
        log "Lock pid is a symlink; refusing to start: $LOCK_DIR/pid"
        exit 1
    fi

    local old_pid=""
    [[ -r "$LOCK_DIR/pid" ]] && old_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    if is_uint "$old_pid" && kill -0 "$old_pid" 2>/dev/null; then
        log "Already running with PID $old_pid"
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
Description=Oracle low-interference keepalive daemon
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
        printf '[DRY-RUN] Would write config: %s\n' "$CONFIG_FILE"
        render_config
        printf '[DRY-RUN] Would write systemd unit: %s\n' "$SERVICE_FILE"
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
    log "Installed and started $SERVICE_NAME"
}

uninstall_service() {
    validate_install_paths || return $?
    if [[ "${ORACLE_KEEPALIVE_DRY_RUN:-0}" == "1" ]]; then
        printf '[DRY-RUN] Would stop and remove %s\n' "$SERVICE_NAME"
        return 0
    fi

    need_root
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$INSTALL_PATH"
    remove_lock_dir_safely || return $?
    systemctl daemon-reload 2>/dev/null || true
    log "Uninstalled $SERVICE_NAME"
}

status_service() {
    systemctl status "$SERVICE_NAME" --no-pager
}

logs_service() {
    journalctl -u "$SERVICE_NAME" -f
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
        printf 'CPU: SKIP\n'
        return 0
    fi
    if ! is_uint "$current"; then
        current="$(current_cpu_percent || true)"
    fi
    if ! is_uint "$current"; then
        printf 'CPU: FAIL current=unknown target=%s%%\n' "$KEEPALIVE_CPU_TARGET_PERCENT"
        return 1
    fi
    if (( current >= KEEPALIVE_CPU_TARGET_PERCENT )); then
        printf 'CPU: PASS current=%s%% target=%s%%\n' "$current" "$KEEPALIVE_CPU_TARGET_PERCENT"
        return 0
    fi
    printf 'CPU: FAIL current=%s%% target=%s%%\n' "$current" "$KEEPALIVE_CPU_TARGET_PERCENT"
    return 1
}

verify_memory() {
    local current="${KEEPALIVE_VERIFY_MEMORY_PERCENT:-}"

    if [[ "$KEEPALIVE_MEMORY_ENABLED" != "1" ]]; then
        printf 'Memory: SKIP\n'
        return 0
    fi
    if ! is_uint "$current"; then
        current="$(current_memory_percent || true)"
    fi
    if ! is_uint "$current"; then
        printf 'Memory: FAIL current=unknown target=%s%%\n' "$KEEPALIVE_MEMORY_TARGET_PERCENT"
        return 1
    fi
    if (( current >= KEEPALIVE_MEMORY_TARGET_PERCENT )); then
        printf 'Memory: PASS current=%s%% target=%s%%\n' "$current" "$KEEPALIVE_MEMORY_TARGET_PERCENT"
        return 0
    fi
    printf 'Memory: FAIL current=%s%% target=%s%%\n' "$current" "$KEEPALIVE_MEMORY_TARGET_PERCENT"
    return 1
}

verify_network() {
    local url tmp_file rc

    if [[ "$KEEPALIVE_NETWORK_ENABLED" != "1" ]]; then
        printf 'Network: SKIP\n'
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
        printf 'Network: FAIL curl/wget unavailable\n'
        return 1
    fi

    if [[ -s "$tmp_file" ]]; then
        rm -f "$tmp_file" 2>/dev/null || true
        printf 'Network: PASS url=%s\n' "$url"
        return 0
    fi

    rm -f "$tmp_file" 2>/dev/null || true
    printf 'Network: FAIL url=%s rc=%s\n' "$url" "$rc"
    return 1
}

verify_keepalive() {
    load_config
    normalize_config || return $?

    local rc=0
    verify_cpu || rc=1
    verify_memory || rc=1
    verify_network || rc=1
    return $rc
}

check_script() {
    load_config
    normalize_config || return $?
    printf '%s\n' "oracle_keepalive.sh OK"
}

run_menu_action() {
    case "$1" in
        1) run_daemon ;;
        2) install_service ;;
        3) uninstall_service ;;
        4) status_service ;;
        5) logs_service ;;
        6) check_script ;;
        7) verify_keepalive ;;
        h|help) usage ;;
        *) printf 'Invalid menu choice: %s\n' "$1" >&2; return 1 ;;
    esac
}

interactive_menu() {
    local choice

    while true; do
        cat <<'EOF'
Oracle Keepalive Menu
  1) Run keepalive daemon in foreground
  2) Install and start systemd service
  3) Uninstall systemd service
  4) Show service status
  5) Follow service logs
  6) Check script configuration
  7) Verify selected keepalive methods
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
Usage: oracle_keepalive.sh [command]

Run without arguments to open the interactive menu.

Commands:
  run        Run keepalive daemon in foreground
  install    Install and start systemd service
  uninstall  Stop and remove systemd service
  status     Show systemd service status
  logs       Follow systemd logs
  check      Validate script configuration defaults
  verify     Verify selected keepalive methods
  help       Show this help
EOF
}

case "${1:-menu}" in
    menu) interactive_menu ;;
    run) run_daemon ;;
    install) install_service ;;
    uninstall) uninstall_service ;;
    status) status_service ;;
    logs) logs_service ;;
    check) check_script ;;
    verify) verify_keepalive ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
