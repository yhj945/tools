#!/bin/bash

# OCI 实例管理工具 - 交互式菜单版本
# 功能：提供交互式菜单管理 OCI 实例

# ================================
# 全局变量
# ================================
INSTANCE_OCIDS=()  # 实例 OCID 数组
PROJECT_URL="https://github.com/yhj945/tools"
TOOL_VERSION="v1.0"

# ================================
# 颜色定义
# ================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ================================
# 配置文件路径
# ================================
# 获取脚本来源目录
resolve_script_source_dir() {
    local source_path="${BASH_SOURCE[0]:-$0}"
    local source_dir=""

    # 优先使用真实脚本文件所在目录
    if [[ -n "$source_path" && "$source_path" != "-" && "$source_path" != /dev/fd/* && "$source_path" != /proc/self/fd/* ]]; then
        source_dir="$(cd "$(dirname "$source_path")" 2>/dev/null && pwd)"
        if [[ -n "$source_dir" && -f "$source_dir/oracle_oci_tool.sh" ]]; then
            printf '%s\n' "$source_dir"
            return 0
        fi
    fi

    return 1
}

# 获取工具数据目录
resolve_data_dir() {
    # 允许显式指定工具目录，适合通过 bash <(...) 这类方式运行
    if [[ -n "${OCI_TOOL_HOME:-}" && -d "${OCI_TOOL_HOME}" ]]; then
        printf '%s\n' "$(cd "${OCI_TOOL_HOME}" 2>/dev/null && pwd)"
        return 0
    fi

    # 默认使用家目录下固定目录，确保本地执行和远程执行共享同一份数据
    printf '%s\n' "${HOME}/.oracle_oci_tool"
}

SCRIPT_SOURCE_DIR="$(resolve_script_source_dir 2>/dev/null || true)"
DATA_DIR="$(resolve_data_dir)"
OCI_HOME_DIR="${DATA_DIR}/oci"
OCI_CONFIG_FILE="${OCI_HOME_DIR}/config"
OCI_KEY_FILE_DEFAULT="${OCI_HOME_DIR}/oci_api_key.pem"
LEGACY_OCI_CONFIG_FILE="$HOME/.oci/config"
LEGACY_OCI_KEY_FILE="$HOME/.oci/oci_api_key.pem"
OCI_CLI_INSTALL_ROOT="${DATA_DIR}/oracle-cli"
OCI_CLI_BIN_DIR="${DATA_DIR}/bin"
OCI_CLI_BIN="${OCI_CLI_BIN_DIR}/oci"
CREATE_SSH_KEY_DIR="${DATA_DIR}/ssh"
CREATE_SSH_PRIVATE_KEY_DEFAULT="${CREATE_SSH_KEY_DIR}/oci_instance_key"
CREATE_SSH_PUBLIC_KEY_DEFAULT="${CREATE_SSH_PRIVATE_KEY_DEFAULT}.pub"
UPDATE_INSTANCE_CONFIG="${DATA_DIR}/update_instance_config.json"
CREATE_INSTANCE_CONFIG="${DATA_DIR}/create_instance_config.json"
CREATE_INSTANCE_DRAFT_CONFIG="${DATA_DIR}/create_instance_config.draft.json"
BEGINNER_DEFAULTS_CONFIG="${DATA_DIR}/beginner_defaults.json"
RETRY_SCRIPT="${DATA_DIR}/retry_update.sh"
TASK_DIR="${DATA_DIR}/tasks"
NOTIFICATION_CONFIG_FILE="${DATA_DIR}/notification_config.conf"
LEGACY_EMAIL_CONFIG_FILE="${DATA_DIR}/email_config.conf"
EMAIL_CONFIG_FILE="$NOTIFICATION_CONFIG_FILE"
DEPENDENCY_STATE_FILE="${DATA_DIR}/installed_dependencies.conf"
BEGINNER_UPDATE_OCPUS_DEFAULT="4"
BEGINNER_UPDATE_MEMORY_GB_DEFAULT="24"
BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT="200"
BEGINNER_CREATE_IMAGE_OS_DEFAULT="Canonical Ubuntu"
BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT="24.04"
BEGINNER_CREATE_SHAPE_DEFAULT="VM.Standard.A1.Flex"
BEGINNER_CREATE_OCPUS_DEFAULT="4"
BEGINNER_CREATE_MEMORY_GB_DEFAULT="24"
BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT="200"
BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT="120"
OCI_UPDATE_CONNECTION_TIMEOUT="${OCI_UPDATE_CONNECTION_TIMEOUT:-10}"
OCI_UPDATE_READ_TIMEOUT="${OCI_UPDATE_READ_TIMEOUT:-120}"
OCI_UPDATE_MAX_RETRIES="${OCI_UPDATE_MAX_RETRIES:-0}"
OCI_UPDATE_REQUEST_INTERVAL_DEFAULT="${OCI_UPDATE_REQUEST_INTERVAL_DEFAULT:-60}"
OCI_CREATE_CONNECTION_TIMEOUT="${OCI_CREATE_CONNECTION_TIMEOUT:-10}"
OCI_CREATE_READ_TIMEOUT="${OCI_CREATE_READ_TIMEOUT:-120}"
OCI_CREATE_MAX_RETRIES="${OCI_CREATE_MAX_RETRIES:-0}"
OCI_CREATE_MAX_WAIT_SECONDS="${OCI_CREATE_MAX_WAIT_SECONDS:-120}"

sync_legacy_data_dir() {
    local legacy_dir="$SCRIPT_SOURCE_DIR"

    if [[ -z "$legacy_dir" || "$legacy_dir" == "$DATA_DIR" || ! -d "$legacy_dir" ]]; then
        return 0
    fi

    local legacy_items=(
        "update_instance_config.json"
        "create_instance_config.json"
        "create_instance_config.draft.json"
        "notification_config.conf"
        "tasks"
    )

    local item
    for item in "${legacy_items[@]}"; do
        if [[ -e "$legacy_dir/$item" && ! -e "$DATA_DIR/$item" ]]; then
            cp -R "$legacy_dir/$item" "$DATA_DIR/$item" 2>/dev/null
        fi
    done

    if [[ -e "$legacy_dir/email_config.conf" && ! -e "$NOTIFICATION_CONFIG_FILE" && ! -e "$LEGACY_EMAIL_CONFIG_FILE" ]]; then
        cp "$legacy_dir/email_config.conf" "$NOTIFICATION_CONFIG_FILE" 2>/dev/null
    fi
}

sync_legacy_notification_config() {
    if [[ -f "$NOTIFICATION_CONFIG_FILE" ]]; then
        return 0
    fi

    if [[ -f "$LEGACY_EMAIL_CONFIG_FILE" ]]; then
        cp "$LEGACY_EMAIL_CONFIG_FILE" "$NOTIFICATION_CONFIG_FILE" 2>/dev/null || return 0
        chmod 600 "$NOTIFICATION_CONFIG_FILE" 2>/dev/null || true
    fi
}

is_valid_positive_decimal() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN { exit !($1 > 0) }" 2>/dev/null
}

is_valid_boot_volume_size() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 32768 ]]
}

load_beginner_defaults() {
    if [[ ! -f "$BEGINNER_DEFAULTS_CONFIG" ]] || ! jq empty "$BEGINNER_DEFAULTS_CONFIG" 2>/dev/null; then
        return 0
    fi

    BEGINNER_UPDATE_OCPUS_DEFAULT="$(jq -r --arg default_value "$BEGINNER_UPDATE_OCPUS_DEFAULT" '.update.ocpus // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_UPDATE_MEMORY_GB_DEFAULT="$(jq -r --arg default_value "$BEGINNER_UPDATE_MEMORY_GB_DEFAULT" '.update.memoryInGBs // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT="$(jq -r --arg default_value "$BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT" '.update.bootVolumeSizeInGBs // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_IMAGE_OS_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_IMAGE_OS_DEFAULT" '.create.imageOperatingSystem // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT" '.create.imageOperatingSystemVersion // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_SHAPE_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_SHAPE_DEFAULT" '.create.shape // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_OCPUS_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_OCPUS_DEFAULT" '.create.ocpus // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_MEMORY_GB_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_MEMORY_GB_DEFAULT" '.create.memoryInGBs // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT" '.create.bootVolumeSizeInGBs // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
    BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT="$(jq -r --arg default_value "$BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT" '.create.bootVolumeVpusPerGB // $default_value' "$BEGINNER_DEFAULTS_CONFIG")"
}

save_beginner_defaults() {
    local update_ocpus="$1"
    local update_memory="$2"
    local update_boot_volume="$3"
    local create_image_os="$4"
    local create_image_os_version="$5"
    local create_shape="$6"
    local create_ocpus="$7"
    local create_memory="$8"
    local create_boot_volume="$9"
    local create_boot_vpus="${10}"

    mkdir -p "$DATA_DIR"

    jq -n \
        --argjson update_ocpus "$update_ocpus" \
        --argjson update_memory "$update_memory" \
        --argjson update_boot_volume "$update_boot_volume" \
        --arg create_image_os "$create_image_os" \
        --arg create_image_os_version "$create_image_os_version" \
        --arg create_shape "$create_shape" \
        --argjson create_ocpus "$create_ocpus" \
        --argjson create_memory "$create_memory" \
        --argjson create_boot_volume "$create_boot_volume" \
        --argjson create_boot_vpus "$create_boot_vpus" \
        '{
            update: {
                ocpus: $update_ocpus,
                memoryInGBs: $update_memory,
                bootVolumeSizeInGBs: $update_boot_volume
            },
            create: {
                imageOperatingSystem: $create_image_os,
                imageOperatingSystemVersion: $create_image_os_version,
                shape: $create_shape,
                ocpus: $create_ocpus,
                memoryInGBs: $create_memory,
                bootVolumeSizeInGBs: $create_boot_volume,
                bootVolumeVpusPerGB: $create_boot_vpus
            }
        }' > "$BEGINNER_DEFAULTS_CONFIG"
    chmod 600 "$BEGINNER_DEFAULTS_CONFIG" 2>/dev/null || true
}

configure_beginner_defaults() {
    local mode="${1:-all}"
    local update_ocpus update_memory update_boot_volume
    local create_image_os create_image_os_version create_shape create_ocpus create_memory create_boot_volume create_boot_vpus
    local edit_update=false
    local edit_create=false

    load_beginner_defaults

    update_ocpus="$BEGINNER_UPDATE_OCPUS_DEFAULT"
    update_memory="$BEGINNER_UPDATE_MEMORY_GB_DEFAULT"
    update_boot_volume="$BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT"
    create_image_os="$BEGINNER_CREATE_IMAGE_OS_DEFAULT"
    create_image_os_version="$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT"
    create_shape="$BEGINNER_CREATE_SHAPE_DEFAULT"
    create_ocpus="$BEGINNER_CREATE_OCPUS_DEFAULT"
    create_memory="$BEGINNER_CREATE_MEMORY_GB_DEFAULT"
    create_boot_volume="$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT"
    create_boot_vpus="$BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT"

    case "$mode" in
        update)
            edit_update=true
            ;;
        create)
            edit_create=true
            ;;
        *)
            edit_update=true
            edit_create=true
            ;;
    esac

    show_header
    if [[ "$edit_update" == true && "$edit_create" == false ]]; then
        printf '%b\n' "${BOLD}修改一键修改实例配置默认值${NC}"
    elif [[ "$edit_create" == true && "$edit_update" == false ]]; then
        printf '%b\n' "${BOLD}修改一键创建实例默认值${NC}"
    else
        printf '%b\n' "${BOLD}修改一键默认配置${NC}"
    fi
    printf '%s\n' "========================================"
    printf '%s\n' ""
    printf '%s\n' "当前默认值:"
    printf '%s\n' "  一键修改: ${BEGINNER_UPDATE_OCPUS_DEFAULT} OCPU / ${BEGINNER_UPDATE_MEMORY_GB_DEFAULT} GB / ${BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT} GB 启动盘"
    printf '%s\n' "  一键创建: ${BEGINNER_CREATE_SHAPE_DEFAULT} / ${BEGINNER_CREATE_OCPUS_DEFAULT} OCPU / ${BEGINNER_CREATE_MEMORY_GB_DEFAULT} GB / ${BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT} GB 启动盘"
    printf '%s\n' ""

    if [[ "$edit_update" == true ]]; then
        printf '%b\n' "${YELLOW}一键修改实例配置默认值:${NC}"
        read -p "目标 OCPU [默认: ${BEGINNER_UPDATE_OCPUS_DEFAULT}]: " update_ocpus
        update_ocpus="${update_ocpus:-$BEGINNER_UPDATE_OCPUS_DEFAULT}"
        read -p "目标内存 GB [默认: ${BEGINNER_UPDATE_MEMORY_GB_DEFAULT}]: " update_memory
        update_memory="${update_memory:-$BEGINNER_UPDATE_MEMORY_GB_DEFAULT}"
        read -p "目标启动盘 GB [默认: ${BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT}]: " update_boot_volume
        update_boot_volume="${update_boot_volume:-$BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT}"
        printf '%s\n' ""

        if ! is_valid_positive_decimal "$update_ocpus" || ! is_valid_positive_decimal "$update_memory"; then
            log_error "一键修改的 OCPU 和内存必须为大于 0 的数字"
            pause
            return 1
        fi
        if ! is_valid_boot_volume_size "$update_boot_volume"; then
            log_error "一键修改的启动盘大小必须为 1-32768 的整数"
            pause
            return 1
        fi
    fi

    if [[ "$edit_create" == true ]]; then
        printf '%b\n' "${YELLOW}一键创建实例默认值:${NC}"
        read -p "镜像系统 [默认: ${BEGINNER_CREATE_IMAGE_OS_DEFAULT}]: " create_image_os
        create_image_os="${create_image_os:-$BEGINNER_CREATE_IMAGE_OS_DEFAULT}"
        read -p "镜像版本 [默认: ${BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT}]: " create_image_os_version
        create_image_os_version="${create_image_os_version:-$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT}"
        read -p "实例规格 [默认: ${BEGINNER_CREATE_SHAPE_DEFAULT}]: " create_shape
        create_shape="${create_shape:-$BEGINNER_CREATE_SHAPE_DEFAULT}"
        read -p "目标 OCPU [默认: ${BEGINNER_CREATE_OCPUS_DEFAULT}]: " create_ocpus
        create_ocpus="${create_ocpus:-$BEGINNER_CREATE_OCPUS_DEFAULT}"
        read -p "目标内存 GB [默认: ${BEGINNER_CREATE_MEMORY_GB_DEFAULT}]: " create_memory
        create_memory="${create_memory:-$BEGINNER_CREATE_MEMORY_GB_DEFAULT}"
        read -p "目标启动盘 GB [默认: ${BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT}]: " create_boot_volume
        create_boot_volume="${create_boot_volume:-$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT}"
        read -p "启动盘性能 VPU/GB [默认: ${BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT}]: " create_boot_vpus
        create_boot_vpus="${create_boot_vpus:-$BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT}"

        if ! is_valid_positive_decimal "$create_ocpus" || ! is_valid_positive_decimal "$create_memory"; then
            log_error "一键创建的 OCPU 和内存必须为大于 0 的数字"
            pause
            return 1
        fi
        if ! is_valid_boot_volume_size "$create_boot_volume"; then
            log_error "一键创建的启动盘大小必须为 1-32768 的整数"
            pause
            return 1
        fi
        if [[ -z "$create_image_os" || -z "$create_shape" ]]; then
            log_error "镜像系统和实例规格不能为空"
            pause
            return 1
        fi
        if [[ ! "$create_boot_vpus" =~ ^[0-9]+$ || "$create_boot_vpus" -lt 10 || "$create_boot_vpus" -gt 120 || $((create_boot_vpus % 10)) -ne 0 ]]; then
            log_error "启动盘性能必须为 10-120 且为 10 的倍数"
            pause
            return 1
        fi
    fi

    printf '%s\n' ""
    printf '%s\n' "即将保存:"
    [[ "$edit_update" == true ]] && printf '%s\n' "  一键修改: ${update_ocpus} OCPU / ${update_memory} GB / ${update_boot_volume} GB 启动盘"
    if [[ "$edit_create" == true ]]; then
        printf '%s\n' "  一键创建: ${create_shape} / ${create_ocpus} OCPU / ${create_memory} GB / ${create_boot_volume} GB 启动盘"
        printf '%s\n' "  镜像:     ${create_image_os} ${create_image_os_version}"
    fi
    printf '%s\n' "  配置文件: $BEGINNER_DEFAULTS_CONFIG"
    printf '%s\n' ""
    read -p "确认保存默认配置? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        pause
        return 0
    fi

    save_beginner_defaults \
        "$update_ocpus" \
        "$update_memory" \
        "$update_boot_volume" \
        "$create_image_os" \
        "$create_image_os_version" \
        "$create_shape" \
        "$create_ocpus" \
        "$create_memory" \
        "$create_boot_volume" \
        "$create_boot_vpus"

    load_beginner_defaults
    log_success "默认配置已保存"
    pause
}

sync_legacy_oci_config() {
    if [[ -f "$OCI_CONFIG_FILE" || ! -f "$LEGACY_OCI_CONFIG_FILE" ]]; then
        return 0
    fi

    mkdir -p "$OCI_HOME_DIR"
    cp "$LEGACY_OCI_CONFIG_FILE" "$OCI_CONFIG_FILE" 2>/dev/null || return 0
    chmod 600 "$OCI_CONFIG_FILE" 2>/dev/null || true

    if [[ -f "$LEGACY_OCI_KEY_FILE" && ! -f "$OCI_KEY_FILE_DEFAULT" ]]; then
        cp "$LEGACY_OCI_KEY_FILE" "$OCI_KEY_FILE_DEFAULT" 2>/dev/null || true
        chmod 600 "$OCI_KEY_FILE_DEFAULT" 2>/dev/null || true
    fi

    if [[ -f "$OCI_KEY_FILE_DEFAULT" ]]; then
        local legacy_key_escaped new_key_escaped
        legacy_key_escaped=$(printf '%s\n' "$LEGACY_OCI_KEY_FILE" | sed 's/[\/&]/\\&/g')
        new_key_escaped=$(printf '%s\n' "$OCI_KEY_FILE_DEFAULT" | sed 's/[\/&]/\\&/g')
        sed -i.bak \
            -e "s/^key_file=${legacy_key_escaped}$/key_file=${new_key_escaped}/" \
            -e "s/^key_file=~\/.oci\/oci_api_key.pem$/key_file=${new_key_escaped}/" \
            "$OCI_CONFIG_FILE" 2>/dev/null || true
        rm -f "${OCI_CONFIG_FILE}.bak"
    fi
}

init_data_dir() {
    mkdir -p "$DATA_DIR"
    sync_legacy_data_dir
    sync_legacy_notification_config
    sync_legacy_oci_config
}

format_tabular_output() {
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t'
    else
        cat
    fi
}

format_tabular_file() {
    local table_file="$1"

    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$table_file"
    else
        cat "$table_file"
    fi
}

create_timestamped_display_name() {
    local base_name="$1"
    local timestamp

    timestamp="$(date +%Y%m%d-%H%M%S)"
    base_name="${base_name//$'\r'/}"
    [[ -z "$base_name" || "$base_name" == "null" ]] && base_name="oci-instance"
    base_name="$(printf '%s' "$base_name" | sed -E 's/-[0-9]{8}-[0-9]{6}$//')"
    [[ -z "$base_name" ]] && base_name="oci-instance"

    printf '%s-%s\n' "$base_name" "$timestamp"
}

ensure_create_ssh_public_key() {
    local ssh_public_key="$1"
    local expanded_ssh_key

    expanded_ssh_key="$(expand_path "$ssh_public_key")"
    if [[ -n "$ssh_public_key" && -f "$expanded_ssh_key" ]]; then
        log_info "复用已有 SSH 公钥: $expanded_ssh_key"
        SELECT_RESULT="$ssh_public_key"
        return 0
    fi

    if [[ -f "$CREATE_SSH_PUBLIC_KEY_DEFAULT" ]]; then
        log_info "复用数据目录中的 SSH 公钥: $CREATE_SSH_PUBLIC_KEY_DEFAULT"
        SELECT_RESULT="$CREATE_SSH_PUBLIC_KEY_DEFAULT"
        return 0
    fi

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        log_error "未找到 ssh-keygen，无法自动生成 SSH 密钥对"
        return 1
    fi

    mkdir -p "$CREATE_SSH_KEY_DIR"
    chmod 700 "$CREATE_SSH_KEY_DIR" 2>/dev/null || true

    if [[ -f "$CREATE_SSH_PRIVATE_KEY_DEFAULT" ]]; then
        if ! ssh-keygen -y -f "$CREATE_SSH_PRIVATE_KEY_DEFAULT" > "$CREATE_SSH_PUBLIC_KEY_DEFAULT" 2>/dev/null; then
            log_error "无法从已有私钥生成 SSH 公钥: $CREATE_SSH_PRIVATE_KEY_DEFAULT"
            return 1
        fi
    elif ! ssh-keygen \
        -t ed25519 \
        -N "" \
        -C "oracle-oci-tool-$(date +%Y%m%d-%H%M%S)" \
        -f "$CREATE_SSH_PRIVATE_KEY_DEFAULT" >/dev/null 2>&1; then
        log_error "自动生成 SSH 密钥对失败"
        return 1
    fi

    chmod 600 "$CREATE_SSH_PRIVATE_KEY_DEFAULT" 2>/dev/null || true
    chmod 644 "$CREATE_SSH_PUBLIC_KEY_DEFAULT" 2>/dev/null || true
    log_info "已自动生成 SSH 密钥对"
    printf '%s\n' "私钥: $CREATE_SSH_PRIVATE_KEY_DEFAULT"
    printf '%s\n' "公钥: $CREATE_SSH_PUBLIC_KEY_DEFAULT"

    SELECT_RESULT="$CREATE_SSH_PUBLIC_KEY_DEFAULT"
    return 0
}

# ================================
# 通知配置（默认值）
# ================================
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASS=""
EMAIL_TO=""
NOTIFY_METHOD="email"
TG_BOT_ID=""
TG_CHAT_ID=""

# ================================
# 加载通知配置
# ================================
load_email_config() {
    if [[ -f "$EMAIL_CONFIG_FILE" ]]; then
        source "$EMAIL_CONFIG_FILE"
        return 0
    fi
    return 1
}

reload_email_config_for_notification() {
    if [[ -f "$EMAIL_CONFIG_FILE" ]]; then
        load_email_config >/dev/null 2>&1
    fi
}

# ================================
# 保存通知配置
# ================================
save_email_config() {
    mkdir -p "$(dirname "$EMAIL_CONFIG_FILE")"
    cat > "$EMAIL_CONFIG_FILE" << EOF
# 通知配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_USER="${SMTP_USER}"
SMTP_PASS="${SMTP_PASS}"
EMAIL_TO="${EMAIL_TO}"
NOTIFY_METHOD="${NOTIFY_METHOD}"
TG_BOT_ID="${TG_BOT_ID}"
TG_CHAT_ID="${TG_CHAT_ID}"
EOF
    chmod 600 "$EMAIL_CONFIG_FILE"
    log_success "通知配置已保存到: $EMAIL_CONFIG_FILE"
}

# ================================
# 配置通知参数
# ================================
resolve_telegram_chat_id() {
    local bot_id="$1"
    local updates chat_id

    [[ -n "$bot_id" ]] || return 1
    updates=$(curl -s "https://api.telegram.org/bot${bot_id}/getUpdates" 2>/dev/null)
    chat_id=$(printf '%s\n' "$updates" | jq -r '
        .result
        | reverse
        | .[]
        | (.message.chat.id // .edited_message.chat.id // .channel_post.chat.id // .callback_query.message.chat.id // empty)
    ' 2>/dev/null | head -1)

    [[ -n "$chat_id" && "$chat_id" != "null" ]] || return 1
    printf '%s\n' "$chat_id"
}

format_tg_bot_id_for_display() {
    local bot_id="$1"
    local prefix suffix

    if [[ -z "$bot_id" ]]; then
        printf '%s\n' "未设置"
        return 0
    fi

    if [[ "$bot_id" == *:* ]]; then
        prefix="${bot_id%%:*}"
        suffix="${bot_id: -4}"
        printf '%s\n' "${prefix}:...${suffix}"
    else
        printf '%s\n' "$bot_id"
    fi
}

choose_default_smtp_settings() {
    local smtp_choice

    if [[ -n "$SMTP_HOST" && -n "$SMTP_PORT" ]]; then
        return 0
    fi

    printf '%s\n' "Common SMTP defaults:"
    printf '%s\n' "  1) QQ mail   smtp.qq.com:465"
    printf '%s\n' "  2) 163 mail  smtp.163.com:465"
    printf '%s\n' "  3) Custom"
    printf '%s\n' ""
    read -p "Select mail type [default: 1 QQ mail]: " smtp_choice
    smtp_choice="${smtp_choice:-1}"

    case "$smtp_choice" in
        1)
            SMTP_HOST="${SMTP_HOST:-smtp.qq.com}"
            SMTP_PORT="${SMTP_PORT:-465}"
            ;;
        2)
            SMTP_HOST="${SMTP_HOST:-smtp.163.com}"
            SMTP_PORT="${SMTP_PORT:-465}"
            ;;
        3)
            ;;
        *)
            log_warn "Invalid mail type, use QQ mail SMTP by default"
            SMTP_HOST="${SMTP_HOST:-smtp.qq.com}"
            SMTP_PORT="${SMTP_PORT:-465}"
            ;;
    esac
}

configure_email() {
    configure_notifications
}

configure_notifications() {
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}配置通知${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%s\n' ""

    # 显示当前配置
    if [[ -f "$EMAIL_CONFIG_FILE" ]]; then
        printf '%b\n' "${CYAN}当前配置:${NC}"
        printf '%s\n' "  通知方式: ${NOTIFY_METHOD:-email}"
        printf '%s\n' "  SMTP 服务器: ${SMTP_HOST:-未设置}"
        printf '%s\n' "  SMTP 端口: ${SMTP_PORT:-未设置}"
        printf '%s\n' "  发件人邮箱: ${SMTP_USER:-未设置}"
        printf '%s\n' "  收件人邮箱: ${EMAIL_TO:-未设置}"
        printf '%s\n' "  TG Bot ID: $(format_tg_bot_id_for_display "$TG_BOT_ID")"
        printf '%s\n' "  TG Chat ID: ${TG_CHAT_ID:-未设置}"
        printf '%s\n' ""
    fi

    printf '%s\n' "通知方式:"
    printf '%s\n' "  1) 邮件"
    printf '%s\n' "  2) Telegram 机器人"
    printf '%s\n' "  3) 邮件 + Telegram"
    printf '%s\n' "  4) 关闭通知"
    printf '%s\n' ""

    local notify_choice
    read -p "请选择通知方式 [当前: ${NOTIFY_METHOD:-email}]: " notify_choice
    case "$notify_choice" in
        1) NOTIFY_METHOD="email" ;;
        2) NOTIFY_METHOD="telegram" ;;
        3) NOTIFY_METHOD="both" ;;
        4) NOTIFY_METHOD="none" ;;
        "") NOTIFY_METHOD="${NOTIFY_METHOD:-email}" ;;
        *) log_warn "无效通知方式，保持当前配置: ${NOTIFY_METHOD:-email}" ;;
    esac

    if [[ "$NOTIFY_METHOD" == "email" || "$NOTIFY_METHOD" == "both" ]]; then
        printf '%s\n' ""
        printf '%s\n' "请输入邮件配置（直接回车保持当前值）:"
        printf '%s\n' "Tips:"
        printf '%s\n' "  QQ  mail: smtp.qq.com:465"
        printf '%s\n' "  163 mail: smtp.163.com:465"
        printf '%s\n' "  SMTP pass: use app password / auth code, not login password"
        printf '%s\n' ""
        choose_default_smtp_settings

        # SMTP 服务器
        local new_host
        read -p "SMTP 服务器 [当前: ${SMTP_HOST:-smtp.qq.com}]: " new_host
        SMTP_HOST="${new_host:-${SMTP_HOST:-smtp.qq.com}}"

        # SMTP 端口
        local new_port
        read -p "SMTP 端口 [当前: ${SMTP_PORT:-465}]: " new_port
        SMTP_PORT="${new_port:-${SMTP_PORT:-465}}"

        # 发件人邮箱
        local new_user
        read -p "发件人邮箱 [当前: ${SMTP_USER}]: " new_user
        SMTP_USER="${new_user:-$SMTP_USER}"

        # SMTP 密码/授权码
        local new_pass
        read -p "SMTP 密码/授权码 [当前: ******]: " new_pass
        if [[ -n "$new_pass" ]]; then
            SMTP_PASS="$new_pass"
        fi

        # 收件人邮箱
        local new_to
        read -p "收件人邮箱 [当前: ${EMAIL_TO}]: " new_to
        EMAIL_TO="${new_to:-$EMAIL_TO}"
    fi

    if [[ "$NOTIFY_METHOD" == "telegram" || "$NOTIFY_METHOD" == "both" ]]; then
        printf '%s\n' ""
        printf '%s\n' "请输入 Telegram 机器人配置（直接回车保持当前值）:"
        printf '%s\n' "获取 TG Bot ID/Token:"
        printf '%s\n' "  1) 在 Telegram 打开 @BotFather"
        printf '%s\n' "  2) 发送 /newbot 创建机器人"
        printf '%s\n' "  3) 复制 BotFather 返回的 Token，例如 123456789:AA..."
        printf '%s\n' "  4) 打开新机器人，先给它发送任意消息"
        printf '%s\n' "  5) 脚本会尝试自动获取 Chat ID"
        printf '%s\n' ""

        local new_tg_bot_id detected_chat_id new_tg_chat_id
        read -p "TG Bot ID/Token [当前: $(format_tg_bot_id_for_display "$TG_BOT_ID")]: " new_tg_bot_id
        TG_BOT_ID="${new_tg_bot_id:-$TG_BOT_ID}"

        if [[ -n "$TG_BOT_ID" ]]; then
            detected_chat_id="$(resolve_telegram_chat_id "$TG_BOT_ID" || true)"
            if [[ -n "$detected_chat_id" ]]; then
                TG_CHAT_ID="$detected_chat_id"
                log_success "已自动获取 Telegram Chat ID: $TG_CHAT_ID"
            else
                log_warn "未能自动获取 Telegram Chat ID，请先给机器人发送任意消息"
            fi
        fi

        if [[ -z "$TG_CHAT_ID" ]]; then
            read -p "TG Chat ID [当前: ${TG_CHAT_ID:-未设置}，留空表示稍后配置]: " new_tg_chat_id
            TG_CHAT_ID="${new_tg_chat_id:-$TG_CHAT_ID}"
        fi
    fi

    printf '%s\n' ""
    printf '%b\n' "${CYAN}配置摘要:${NC}"
    printf '%s\n' "  通知方式: ${NOTIFY_METHOD}"
    if [[ "$NOTIFY_METHOD" == "email" || "$NOTIFY_METHOD" == "both" ]]; then
        printf '%s\n' "  SMTP 服务器: ${SMTP_HOST}"
        printf '%s\n' "  SMTP 端口: ${SMTP_PORT}"
        printf '%s\n' "  发件人邮箱: ${SMTP_USER}"
        printf '%s\n' "  收件人邮箱: ${EMAIL_TO}"
    fi
    if [[ "$NOTIFY_METHOD" == "telegram" || "$NOTIFY_METHOD" == "both" ]]; then
        printf '%s\n' "  TG Bot ID: $(format_tg_bot_id_for_display "$TG_BOT_ID")"
        printf '%s\n' "  TG Chat ID: ${TG_CHAT_ID:-未设置}"
    fi
    printf '%s\n' ""

    # 确认保存
    read -p "确认保存配置? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        save_email_config
    else
        log_info "已取消保存"
    fi
}

# ================================
# 测试通知发送
# ================================
test_email_config() {
    test_notification_config
}

test_notification_config() {
    reload_email_config_for_notification

    if [[ "${NOTIFY_METHOD:-email}" == "none" ]]; then
        log_info "通知已关闭，跳过测试"
        return 1
    fi

    printf '%s\n' ""
    read -p "是否发送测试通知? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        send_notification "OCI 实例配置管理工具 测试通知" "这是一条测试通知\n发送时间: $(date '+%Y-%m-%d %H:%M:%S')\n如果您收到此通知，说明通知配置正确。"
    fi
}

# ================================
# 通知发送函数
# ================================
send_email_notification() {
    local subject="$1"
    local body="$2"
    local formatted_body

    # 每次发送前重新加载通知配置，确保后台任务也能使用最新保存的配置
    reload_email_config_for_notification

    # 将调用方传入的 \n 等转义序列转换为真实换行，避免邮件正文显示字面量
    formatted_body=$(printf '%b' "$body")

    # 检查邮件配置
    if [[ -z "$SMTP_HOST" || -z "$SMTP_PORT" || -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$EMAIL_TO" ]]; then
        log_warn "邮件配置不完整，跳过邮件通知"
        return 1
    fi

    # 构建邮件内容
    local email_content="From: ${SMTP_USER}
To: ${EMAIL_TO}
Subject: ${subject}
Content-Type: text/plain; charset=UTF-8

${formatted_body}"

    # 使用 curl 发送邮件 (SMTP with SSL, LOGIN认证)
    printf '%s\n' "$email_content" | curl -s --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
        --ssl-reqd \
        --mail-from "${SMTP_USER}" \
        --mail-rcpt "${EMAIL_TO}" \
        --upload-file - \
        --user "${SMTP_USER}:${SMTP_PASS}" \
        --login-options AUTH=LOGIN \
        2>/dev/null

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_info "邮件通知已发送: ${subject}"
    else
        log_warn "邮件通知发送失败 (exit code: ${exit_code})"
    fi

    return $exit_code
}

send_telegram_notification() {
    local subject="$1"
    local body="$2"
    local formatted_body message payload response ok

    reload_email_config_for_notification

    if [[ -z "$TG_BOT_ID" || -z "$TG_CHAT_ID" ]]; then
        log_warn "Telegram 配置不完整，跳过 TG 通知"
        return 1
    fi

    formatted_body=$(printf '%b' "$body")
    message="${subject}

${formatted_body}"
    payload=$(jq -cn \
        --arg chat_id "$TG_CHAT_ID" \
        --arg text "$message" \
        '{chat_id: $chat_id, text: $text, disable_web_page_preview: true}')

    response=$(curl -s \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://api.telegram.org/bot${TG_BOT_ID}/sendMessage" 2>/dev/null)
    ok=$(printf '%s\n' "$response" | jq -r '.ok // false' 2>/dev/null)

    if [[ "$ok" == "true" ]]; then
        log_info "Telegram 通知已发送: ${subject}"
        return 0
    fi

    log_warn "Telegram 通知发送失败"
    return 1
}

send_notification() {
    local subject="$1"
    local body="$2"
    local method
    local failed="false"

    reload_email_config_for_notification
    method="${NOTIFY_METHOD:-email}"

    case "$method" in
        email)
            send_email_notification "$subject" "$body" || failed="true"
            ;;
        telegram)
            send_telegram_notification "$subject" "$body" || failed="true"
            ;;
        both)
            send_email_notification "$subject" "$body" || failed="true"
            send_telegram_notification "$subject" "$body" || failed="true"
            ;;
        none)
            log_info "通知已关闭，跳过发送: ${subject}"
            ;;
        *)
            log_warn "未知通知方式: ${method}，默认尝试邮件通知"
            send_email_notification "$subject" "$body" || failed="true"
            ;;
    esac

    [[ "$failed" != "true" ]]
}

# ================================
# 日志函数
# ================================
log_info() {
    printf '%b\n' "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    printf '%b\n' "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    printf '%b\n' "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    printf '%b\n' "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# ================================
# 暂停函数
# ================================
pause() {
    printf '%s\n' ""
    read -p "按任意键继续..." -n 1 -r
}

# ================================
# 后台任务管理
# ================================

# 创建任务目录
init_task_dir() {
    mkdir -p "$TASK_DIR"
}

# 规范化任务错误信息，兼容旧版本写入的双重转义字符串
normalize_task_error() {
    local raw_error="$1"

    if [[ -z "$raw_error" || "$raw_error" == "null" ]]; then
        return 0
    fi

    printf '%s' "$raw_error" | jq -Rrs 'fromjson? // .' 2>/dev/null || printf '%s' "$raw_error"
}

# 从混合文本中提取 ServiceError 后的 JSON 错误对象
extract_service_error_json() {
    local raw_text="$1"

    printf '%s\n' "$raw_text" | awk '
        /ServiceError:/ {
            capture=1
            started=0
            depth=0
            buffer=""
            next
        }
        capture {
            if (!started && $0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                started=1
            }
            if (started) {
                buffer = buffer $0 "\n"
                opens = gsub(/\{/, "{", $0)
                closes = gsub(/\}/, "}", $0)
                depth += opens - closes
                if (depth == 0) {
                    last_json = buffer
                    capture=0
                }
            }
        }
        END {
            if (last_json != "") {
                printf "%s", last_json
            }
        }
    '
}

# 将任务错误信息解析为 JSON 对象或原始字符串
get_task_error_payload() {
    local raw_error="$1"
    local normalized_error
    local service_error_json

    normalized_error=$(normalize_task_error "$raw_error")

    service_error_json=$(extract_service_error_json "$normalized_error")
    if [[ -n "$service_error_json" ]]; then
        printf '%s' "$service_error_json" | jq -Rrs 'fromjson? // .' 2>/dev/null || printf 'null'
        return 0
    fi

    normalized_error=$(printf '%s' "$normalized_error" | sed '1 s/^ServiceError:[[:space:]]*//')

    printf '%s' "$normalized_error" | jq -Rrs 'fromjson? // .' 2>/dev/null || printf 'null'
}

# 检查实例是否有运行中的任务
# 返回: 0 = 有运行中任务且用户选择不停止, 1 = 无运行中任务或用户选择停止
check_existing_task_for_instance() {
    local instance_ocid="$1"

    init_task_dir

    for task_path in "$TASK_DIR"/*; do
        [[ ! -d "$task_path" ]] && continue

        local task_info="$task_path/task.info"
        [[ ! -f "$task_info" ]] && continue

        local task_instance task_status
        task_instance=$(jq -r '.instance_ocid' "$task_info" 2>/dev/null)
        task_status=$(jq -r '.status' "$task_info" 2>/dev/null)

        # 如果找到针对同一实例的运行中任务
        if [[ "$task_instance" == "$instance_ocid" && "$task_status" == "running" ]]; then
            # 检查进程是否真的在运行
            local pid_file="$task_path/task.pid"
            if [[ -f "$pid_file" ]]; then
                local pid=$(cat "$pid_file" 2>/dev/null)
                if kill -0 "$pid" 2>/dev/null; then
                    local task_id=$(jq -r '.task_id' "$task_info" 2>/dev/null)
                    printf '%s\n' ""
                    log_warn "检测到该实例已有后台任务正在运行！"
                    printf '%s\n' ""
                    printf '%s\n' "  任务 ID: $task_id"
                    printf '%s\n' "  任务类型: $(jq -r '.task_type' "$task_info" 2>/dev/null)"
                    printf '%s\n' "  创建时间: $(jq -r '.create_time' "$task_info" 2>/dev/null)"
                    printf '%s\n' "  目标 OCPU: $(jq -r '.target_ocpus' "$task_info" 2>/dev/null)"
                    printf '%s\n' "  目标内存: $(jq -r '.target_memory' "$task_info" 2>/dev/null) GB"
                    printf '%s\n' "  执行次数: $(jq -r '.attempt' "$task_info" 2>/dev/null)"
                    printf '%s\n' ""
                    read -p "是否停止现有任务并创建新任务? [y/N]: " -r
                    [[ -z "$REPLY" ]] && REPLY="n"

                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        log_info "正在停止现有任务..."

                        # 停止任务进程
                        if kill -TERM "$pid" 2>/dev/null; then
                            sleep 2
                            # 如果进程还在运行，强制终止
                            if kill -0 "$pid" 2>/dev/null; then
                                kill -9 "$pid" 2>/dev/null
                            fi
                        fi

                        # 更新任务状态
                        if [[ -f "$task_info" ]]; then
                            local temp_info="${task_info}.tmp"
                            jq '.status = "stopped" | .end_time = "'"$(date -Iseconds)"'"' \
                                "$task_info" > "$temp_info"
                            mv "$temp_info" "$task_info"
                        fi

                        # 删除 PID 文件
                        rm -f "$pid_file"

                        log_success "现有任务已停止"
                        return 1  # 允许继续创建新任务
                    else
                        log_info "操作已取消"
                        return 0  # 不允许继续
                    fi
                fi
            fi
        fi
    done

    return 1  # 没有运行中的任务，允许继续
}

# 创建新任务
# 参数: $1=task_type, $2=instance_ocid, $3=target_ocpus, $4=target_memory, $5=retry_interval, $6=request_interval, $7=skip_check(可选)
create_background_task() {
    local task_type="$1"  # direct_update_instance 或 full_update_instance
    local instance_ocid="$2"
    local target_ocpus="$3"
    local target_memory="$4"
    local retry_interval="${5:-10}"
    local request_interval="${6:-}"
    local skip_check="${7:-false}"  # 是否跳过已有任务检测
    local request_interval_json="null"

    # 兼容旧调用: 第 6 个参数原来是 skip_check
    if [[ "$request_interval" == "true" || "$request_interval" == "false" ]]; then
        skip_check="$request_interval"
        request_interval=""
    fi

    if [[ "$task_type" == "direct_update_instance" || "$task_type" == "direct_update" ]]; then
        if [[ ! "$request_interval" =~ ^[0-9]+$ || "$request_interval" -le 0 ]]; then
            request_interval="$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT"
        fi
        request_interval_json="$request_interval"
        [[ "$retry_interval" =~ ^[0-9]+$ ]] || retry_interval=0
    else
        if [[ ! "$retry_interval" =~ ^[0-9]+$ || "$retry_interval" -le 0 ]]; then
            retry_interval=10
        fi
    fi

    init_task_dir

    # 如果没有跳过检测，检查是否已有针对同一实例的运行中任务
    if [[ "$skip_check" != "true" ]]; then
        local existing_task=""
        local existing_task_id=""
        for task_path in "$TASK_DIR"/*; do
            [[ ! -d "$task_path" ]] && continue

            local task_info="$task_path/task.info"
            [[ ! -f "$task_info" ]] && continue

            local task_instance=$(jq -r '.instance_ocid' "$task_info")
            local task_status=$(jq -r '.status' "$task_info")

            # 如果找到针对同一实例的运行中任务
            if [[ "$task_instance" == "$instance_ocid" && "$task_status" == "running" ]]; then
                # 检查进程是否真的在运行
                local pid_file="$task_path/task.pid"
                if [[ -f "$pid_file" ]]; then
                    local pid=$(cat "$pid_file")
                    if kill -0 "$pid" 2>/dev/null; then
                        existing_task_id=$(jq -r '.task_id' "$task_info")
                        existing_task="$task_path"
                        break
                    fi
                fi
            fi
        done

        # 如果已有运行中的任务，询问用户
        if [[ -n "$existing_task" ]]; then
            printf '%s\n' ""
            log_warn "检测到该实例已有后台任务正在运行"
            printf '%s\n' ""
            printf '%s\n' "现有任务 ID: $existing_task_id"
            printf '%s\n' "任务类型: $(jq -r '.task_type' "$existing_task/task.info")"
            printf '%s\n' "创建时间: $(jq -r '.create_time' "$existing_task/task.info")"
            printf '%s\n' "目标 OCPU: $(jq -r '.target_ocpus' "$existing_task/task.info")"
            printf '%s\n' "目标内存: $(jq -r '.target_memory' "$existing_task/task.info")GB"
            printf '%s\n' ""
            read -p "是否停止现有任务并创建新任务? [y/N]: " -r
            [[ -z "$REPLY" ]] && REPLY="n"
            printf '
'
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "操作已取消"
                pause
                return 0
            fi

            # 停止现有任务
            stop_task "$existing_task_id"
            log_success "已停止现有任务"
            printf '%s\n' ""
        fi
    fi

    # 生成任务 ID，并用 mkdir 原子创建目录，避免同一秒内连续创建任务时覆盖记录。
    local task_id task_path
    while true; do
        task_id="$(date +%Y%m%d-%H%M%S)_${BASHPID:-$$}_$RANDOM"
        task_path="$TASK_DIR/$task_id"
        if mkdir "$task_path" 2>/dev/null; then
            break
        fi
    done

    # 写入任务信息
    cat > "$task_path/task.info" << EOF
{
    "task_id": "$task_id",
    "task_type": "$task_type",
    "instance_ocid": "$instance_ocid",
    "target_ocpus": $target_ocpus,
    "target_memory": $target_memory,
    "retry_interval": $retry_interval,
    "request_interval": $request_interval_json,
    "create_time": "$(date -Iseconds)",
    "status": "running"
}
EOF

    # 启动后台任务
    (
        exec_background_task "$task_id" "$task_type" "$instance_ocid" "$target_ocpus" "$target_memory" "$retry_interval" "$request_interval"
    ) &>"$task_path/task.log" &

    local pid=$!
    printf '%s\n' $pid > "$task_path/task.pid"

    log_success "后台任务已创建"
    printf '%s\n' ""
    printf '%s\n' "任务 ID: $task_id"
    printf '%s\n' "日志文件: $task_path/task.log"
    printf '%s\n' ""
    printf '%b\n' "${CYAN}提示: 任务将在后台持续执行，您可以：${NC}"
    printf '%s\n' "  - 在主菜单进入“管理后台任务”查看任务进度"
    printf '%s\n' "  - 退出此脚本不会影响后台任务"
    printf '%s\n' ""
}

# 后台执行任务
exec_background_task() {
    local task_id="$1"
    local task_type="$2"
    local instance_ocid="$3"
    local target_ocpus="$4"
    local target_memory="$5"
    local retry_interval="$6"
    local request_interval="${7:-}"

    local task_path="$TASK_DIR/$task_id"
    local log_file="$task_path/task.log"
    local status_file="$task_path/task.status"
    local task_lock_dir="$task_path/.write.lock"

    acquire_task_lock() {
        local lock_pid
        while ! mkdir "$task_lock_dir" 2>/dev/null; do
            if [[ -f "$task_lock_dir/pid" ]]; then
                lock_pid=$(cat "$task_lock_dir/pid" 2>/dev/null || true)
                if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                    rm -rf "$task_lock_dir" 2>/dev/null || true
                    continue
                fi
            fi
            sleep 0.1
        done
        printf '%s\n' "${BASHPID:-$$}" > "$task_lock_dir/pid" 2>/dev/null || true
    }

    release_task_lock() {
        rm -rf "$task_lock_dir" 2>/dev/null || true
    }

    with_task_lock() {
        local rc
        acquire_task_lock
        "$@"
        rc=$?
        release_task_lock
        return "$rc"
    }

    append_task_log_unlocked() {
        local level="$1"
        local message="$2"
        printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$log_file"
    }

    log_info() {
        with_task_lock append_task_log_unlocked "INFO" "$1"
    }

    log_error() {
        with_task_lock append_task_log_unlocked "ERROR" "$1"
    }

    log_success() {
        with_task_lock append_task_log_unlocked "SUCCESS" "$1"
    }

    stop_running_children() {
        local child_pid
        for child_pid in $(jobs -pr 2>/dev/null); do
            kill "$child_pid" 2>/dev/null || true
        done
        wait 2>/dev/null || true
    }

    handle_task_termination() {
        log_info "收到停止信号，正在停止已发起的请求..."
        stop_running_children
        exit 0
    }

    trap handle_task_termination TERM INT

    task_status_is_running() {
        [[ -f "$task_path/task.info" ]] || return 1
        [[ "$(jq -r '.status // "running"' "$task_path/task.info" 2>/dev/null)" == "running" ]]
    }

    update_task_attempt_scheduled_unlocked() {
        local attempt="$1"
        local temp_file="$task_path/task.info.tmp.${BASHPID:-$$}.$RANDOM"

        [[ -f "$task_path/task.info" ]] || return 1
        [[ "$(jq -r '.status // "running"' "$task_path/task.info" 2>/dev/null)" == "running" ]] || return 1

        jq --argjson attempt "$attempt" \
           --arg time "$(date -Iseconds)" \
           '.attempt = ([($attempt), (.attempt // 0)] | max) |
            .last_scheduled_time = $time' \
           "$task_path/task.info" > "$temp_file" && mv "$temp_file" "$task_path/task.info"
    }

    update_task_attempt_scheduled() {
        with_task_lock update_task_attempt_scheduled_unlocked "$1"
    }

    update_task_status_unlocked() {
        local attempt="$1"
        local last_status="$2"
        local last_error="$3"
        local temp_file="$task_path/task.info.tmp.${BASHPID:-$$}.$RANDOM"

        [[ -f "$task_path/task.info" ]] || return 1
        [[ "$(jq -r '.status // "running"' "$task_path/task.info" 2>/dev/null)" == "running" ]] || return 1

        jq --argjson attempt "$attempt" \
           --arg status "$last_status" \
           --arg error "$last_error" \
           --arg time "$(date -Iseconds)" \
           '.attempt = ([($attempt), (.attempt // 0)] | max) |
            if $attempt >= (.last_result_attempt // 0) then
                .last_result_attempt = $attempt |
                .last_status = $status |
                .last_error = $error |
                .last_attempt_time = $time
            else
                .
            end' \
           "$task_path/task.info" > "$temp_file" && mv "$temp_file" "$task_path/task.info"
    }

    update_task_status() {
        with_task_lock update_task_status_unlocked "$1" "$2" "$3"
    }

    mark_task_completed_unlocked() {
        local attempt="$1"
        local temp_file="$task_path/task.info.tmp.${BASHPID:-$$}.$RANDOM"

        [[ -f "$task_path/task.info" ]] || return 1
        [[ "$(jq -r '.status // "running"' "$task_path/task.info" 2>/dev/null)" == "running" ]] || return 1

        jq --argjson attempt "$attempt" \
           --arg time "$(date -Iseconds)" \
           '.attempt = ([($attempt), (.attempt // 0)] | max) |
            .last_result_attempt = ([($attempt), (.last_result_attempt // 0)] | max) |
            .last_status = "success" |
            .last_error = "" |
            .last_attempt_time = $time |
            .status = "completed" |
            .end_time = $time' \
           "$task_path/task.info" > "$temp_file" && mv "$temp_file" "$task_path/task.info"
    }

    mark_task_completed() {
        with_task_lock mark_task_completed_unlocked "$1"
    }

    run_direct_update_attempt() {
        local attempt_no="$1"
        local attempt_start result exit_code attempt_elapsed error_msg

        attempt_start=$(date +%s)
        result=$(oci compute instance update \
            --instance-id "$instance_ocid" \
            --shape-config "{\"ocpus\": $target_ocpus, \"memory-in-gbs\": $target_memory}" \
            --force \
            --connection-timeout "$OCI_UPDATE_CONNECTION_TIMEOUT" \
            --read-timeout "$OCI_UPDATE_READ_TIMEOUT" \
            --max-retries "$OCI_UPDATE_MAX_RETRIES" \
            --output json 2>&1)
        exit_code=$?
        attempt_elapsed=$(($(date +%s) - attempt_start))

        if [[ $exit_code -eq 0 ]]; then
            if mark_task_completed "$attempt_no"; then
                log_info "第 $attempt_no 次请求耗时: ${attempt_elapsed}秒"
                log_success "第 $attempt_no 次请求更新成功！"
                send_notification "OCI 实例配置更新成功" "实例 ${instance_ocid} 配置更新成功\n更新内容:\n- OCPUs: ${target_ocpus}\n- Memory: ${target_memory} GB\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            else
                log_info "第 $attempt_no 次请求成功返回，但任务已结束，已忽略该结果"
            fi
            return 0
        fi

        error_msg=$(printf '%s\n' "$result" | jq -r '.message // .error.message // "未知错误"' 2>/dev/null || printf '%s\n' "$result")
        if update_task_status "$attempt_no" "failed" "$error_msg"; then
            log_error "第 $attempt_no 次请求更新失败: $result"
            log_info "第 $attempt_no 次请求耗时: ${attempt_elapsed}秒"
        else
            log_info "第 $attempt_no 次请求失败返回，但任务已结束，已忽略该结果"
        fi
    }

    run_direct_update_scheduler() {
        local scheduled_request_interval="$request_interval"
        local slept

        if [[ ! "$scheduled_request_interval" =~ ^[0-9]+$ || "$scheduled_request_interval" -le 0 ]]; then
            scheduled_request_interval=$(jq -r '.request_interval // empty' "$task_path/task.info" 2>/dev/null)
        fi
        if [[ ! "$scheduled_request_interval" =~ ^[0-9]+$ || "$scheduled_request_interval" -le 0 ]]; then
            scheduled_request_interval="$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT"
        fi

        log_info "请求调度模式: 固定间隔非阻塞请求"
        log_info "请求间隔: ${scheduled_request_interval}秒"

        local attempt
        attempt=$(jq -r '.attempt // 0' "$task_path/task.info" 2>/dev/null)
        while task_status_is_running; do
            ((attempt++))
            update_task_attempt_scheduled "$attempt" || break
            log_info "第 $attempt 次请求已发起（非阻塞）"
            run_direct_update_attempt "$attempt" &

            slept=0
            while [[ $slept -lt $scheduled_request_interval ]]; do
                task_status_is_running || break 2
                sleep 1
                ((slept++))
            done
        done

        log_info "请求调度器已停止，等待已发起请求返回..."
        wait 2>/dev/null || true
        exit 0
    }

    log_info "后台任务启动"
    log_info "任务类型: $task_type"
    log_info "实例 OCID: $instance_ocid"
    log_info "目标 OCPU: $target_ocpus"
    log_info "目标内存: ${target_memory}GB"
    log_info "OCI 请求超时: connection=${OCI_UPDATE_CONNECTION_TIMEOUT}s, read=${OCI_UPDATE_READ_TIMEOUT}s, max_retries=${OCI_UPDATE_MAX_RETRIES}"
    repair_oci_key_permissions >/dev/null 2>&1 || true

    if [[ "$task_type" == "direct_update_instance" || "$task_type" == "direct_update" ]]; then
        run_direct_update_scheduler
    fi

    # 从 task.info 读取当前执行次数，而不是从 0 开始
    local attempt=$(jq -r '.attempt // 0' "$task_path/task.info")
    while true; do
        ((attempt++))
        log_info "第 $attempt 次尝试..."

        if [[ "$task_type" == "full_update_instance" || "$task_type" == "full_update" ]]; then
            # 完整更新流程（停止→更新→启动）

            # 步骤 1: 停止实例
            log_info "步骤 1/3: 停止实例..."
            oci compute instance action \
                --instance-id "$instance_ocid" \
                --action STOP \
                --output json &>/dev/null

            # 等待实例停止
            local max_wait=120
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                local state
                state=$(oci compute instance get \
                    --instance-id "$instance_ocid" \
                    --query 'data."lifecycle-state"' \
                    --raw-output 2>/dev/null)

                if [[ "$state" == "STOPPED" ]]; then
                    log_success "实例已停止"
                    break
                fi

                sleep 5
                ((waited += 5))
            done

            if [[ $waited -ge $max_wait ]]; then
                log_error "等待实例停止超时"
                update_task_status "$attempt" "failed" "等待实例停止超时"
                log_info "等待 ${retry_interval} 秒后重试..."
                sleep "$retry_interval"
                continue
            fi

            # 步骤 2: 更新配置
            log_info "步骤 2/3: 更新实例配置..."
            local result
            result=$(oci compute instance update \
                --instance-id "$instance_ocid" \
                --shape-config "{\"ocpus\": $target_ocpus, \"memory-in-gbs\": $target_memory}" \
                --force \
                --connection-timeout "$OCI_UPDATE_CONNECTION_TIMEOUT" \
                --read-timeout "$OCI_UPDATE_READ_TIMEOUT" \
                --max-retries "$OCI_UPDATE_MAX_RETRIES" \
                --output json 2>&1)

            if [[ $? -ne 0 ]]; then
                log_error "更新失败: $result"
                log_info "等待 ${retry_interval} 秒后重试..."
                sleep "$retry_interval"
                continue
            fi

            log_success "配置更新成功"

            # 步骤 3: 启动实例
            log_info "步骤 3/3: 启动实例..."
            oci compute instance action \
                --instance-id "$instance_ocid" \
                --action START \
                --output json &>/dev/null

            # 等待实例启动
            max_wait=120
            waited=0
            while [[ $waited -lt $max_wait ]]; do
                state=$(oci compute instance get \
                    --instance-id "$instance_ocid" \
                    --query 'data."lifecycle-state"' \
                    --raw-output 2>/dev/null)

                if [[ "$state" == "RUNNING" ]]; then
                    log_success "实例已启动"
                    break
                fi

                sleep 5
                ((waited += 5))
            done

            if [[ $waited -ge $max_wait ]]; then
                log_error "等待实例启动超时"
                update_task_status "$attempt" "failed" "等待实例启动超时"
                log_info "等待 ${retry_interval} 秒后重试..."
                sleep "$retry_interval"
                continue
            fi

            # 全部成功
            log_success "完整更新流程成功！"
            # 发送通知
            send_notification "OCI 实例完整更新流程成功" "实例 ${instance_ocid} 完整更新流程成功\n\n更新内容:\n- OCPUs: ${target_ocpus}\n- Memory: ${target_memory} GB\n\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            update_task_status "$attempt" "success" ""
            # 更新任务状态
            jq '.status = "completed" | .end_time = "'"$(date -Iseconds)"'"' \
                "$task_path/task.info" > "$task_path/task.info.tmp"
            mv "$task_path/task.info.tmp" "$task_path/task.info"
            exit 0
        fi
    done
}

get_task_type_label() {
    case "$1" in
        direct_update|direct_update_instance) printf '%s\n' "直接更新" ;;
        full_update|full_update_instance) printf '%s\n' "完整更新" ;;
        create_instance) printf '%s\n' "创建实例" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

get_task_subject_label() {
    local task_info="$1"
    local task_type
    task_type=$(jq -r '.task_type // ""' "$task_info")

    if [[ "$task_type" == "create_instance" ]]; then
        jq -r '.display_name // "新实例"' "$task_info"
    else
        local instance_ocid
        instance_ocid=$(jq -r '.instance_ocid // ""' "$task_info")
        local instance_short="${instance_ocid##*.}"
        printf '%s\n' "${instance_short:0:20}..."
    fi
}

get_task_target_label() {
    local task_info="$1"
    local task_type
    task_type=$(jq -r '.task_type // ""' "$task_info")
    local target_ocpus target_memory shape
    target_ocpus=$(jq -r '.target_ocpus // "N/A"' "$task_info")
    target_memory=$(jq -r '.target_memory // "N/A"' "$task_info")
    shape=$(jq -r '.shape // ""' "$task_info")

    if [[ "$task_type" == "create_instance" ]]; then
        if [[ -n "$shape" && "$shape" != "null" ]]; then
            printf '%s\n' "${shape} / ${target_ocpus} OCPU / ${target_memory} GB"
        else
            printf '%s\n' "创建新实例"
        fi
    else
        printf '%s\n' "${target_ocpus} OCPU / ${target_memory} GB"
    fi
}

# 列出所有任务
list_background_tasks() {
    init_task_dir

    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}后台任务列表${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%s\n' ""

    # 声明全局数组存储任务 ID（供后续选择使用）
    TASK_IDS=()
    local task_count=0

    for task_path in "$TASK_DIR"/*; do
        [[ ! -d "$task_path" ]] && continue

        local task_info="$task_path/task.info"
        [[ ! -f "$task_info" ]] && continue

        ((task_count++))
        local task_id=$(jq -r '.task_id' "$task_info")
        TASK_IDS[$task_count]="$task_id"

        local task_type=$(jq -r '.task_type' "$task_info")
        local status=$(jq -r '.status' "$task_info")
        local task_type_label
        task_type_label=$(get_task_type_label "$task_type")
        local subject_label
        subject_label=$(get_task_subject_label "$task_info")
        local target_label
        target_label=$(get_task_target_label "$task_info")

        # 新增字段：执行次数、上次状态、上次错误
        local attempt=$(jq -r '.attempt // 0' "$task_info")
        local last_status=$(jq -r '.last_status // "N/A"' "$task_info")
        local last_error=$(jq -r '.last_error // ""' "$task_info")
        local last_attempt_time=$(jq -r '.last_attempt_time // "N/A"' "$task_info")

        # 检查进程是否还在运行
        local pid_file="$task_path/task.pid"
        if [[ "$status" == "running" && -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if ! kill -0 "$pid" 2>/dev/null; then
                status="stopped"
            fi
        fi

        local status_color
        case "$status" in
            running) status_color="${GREEN}" ;;
            completed) status_color="${CYAN}" ;;
            stopped|failed) status_color="${RED}" ;;
            *) status_color="${YELLOW}" ;;
        esac

        # 上次状态颜色
        local last_status_color
        case "$last_status" in
            success) last_status_color="${GREEN}" ;;
            failed) last_status_color="${RED}" ;;
            *) last_status_color="${YELLOW}" ;;
        esac

        printf '%b\n' "#$task_count ${BOLD}$task_id${NC}"
        printf '%s\n' "  类型: $task_type_label"
        printf '%s\n' "  对象: $subject_label"
        printf '%s\n' "  目标: $target_label"
        printf '%b\n' "  状态: ${status_color}${status}${NC}"
        printf '%b\n' "  执行次数: ${BOLD}${attempt}${NC}"
        printf '%b\n' "  上次状态: ${last_status_color}${last_status}${NC}"

        # 显示错误信息（如果有）- 提取关键信息并翻译
        if [[ -n "$last_error" && "$last_error" != "null" && "$last_error" != "" ]]; then
            local error_payload error_code error_message error_translated
            error_payload=$(get_task_error_payload "$last_error")
            error_code=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .code // "Unknown" else "Unknown" end' 2>/dev/null || printf '%s\n' "Unknown")
            error_message=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .message // "" else . end' 2>/dev/null || printf '%s\n' "")

            # 翻译常见错误
            case "$error_code" in
                InternalError)
                    error_translated="内部错误"
                    ;;
                NotAuthorizedOrNotFound)
                    error_translated="未授权或资源不存在"
                    ;;
                InvalidParameter)
                    error_translated="参数无效"
                    ;;
                LimitExceeded)
                    error_translated="超出限制"
                    ;;
                ServiceError)
                    error_translated="服务错误"
                    ;;
                *)
                    error_translated="$error_code"
                    ;;
            esac

            # 翻译常见错误消息
            local msg_translated="$error_message"
            case "$error_message" in
                *"Out of host capacity"*)
                    msg_translated="主机容量不足 (Out of host capacity)"
                    ;;
                *"quota exceeded"*)
                    msg_translated="配额超限 (Quota exceeded)"
                    ;;
                *"not found"*)
                    msg_translated="资源未找到 (Not found)"
                    ;;
                *"permission denied"*)
                    msg_translated="权限被拒绝 (Permission denied)"
                    ;;
                *"rate limit"*)
                    msg_translated="请求频率限制 (Rate limit)"
                    ;;
            esac

            # 截取显示
            if [[ ${#msg_translated} -gt 80 ]]; then
                msg_translated="${msg_translated:0:77}..."
            fi

            printf '%b\n' "  ${RED}✗ 错误: [$error_translated] $msg_translated${NC}"
        fi

        if [[ "$last_attempt_time" != "N/A" ]]; then
            printf '%s\n' "  上次尝试: $last_attempt_time"
        fi

        printf '%s\n' ""
    done

    if [[ $task_count -eq 0 ]]; then
        printf '%s\n' "暂无后台任务"
        printf '%s\n' ""
    fi
}

# 查看任务详情
view_task_detail() {
    local task_id="$1"
    local task_path="$TASK_DIR/$task_id"

    if [[ ! -d "$task_path" ]]; then
        log_error "任务不存在: $task_id"
        return 1
    fi

    while true; do
        printf '%b\n' "${BOLD}========================================${NC}"
        printf '%b\n' "${BOLD}任务详情: $task_id${NC}"
        printf '%b\n' "${BOLD}========================================${NC}"
        printf '%s\n' ""

        # 显示任务信息（格式化）
        local task_info="$task_path/task.info"
        if [[ -f "$task_info" ]]; then
            printf '%b\n' "${CYAN}任务信息:${NC}"

            # 读取并格式化显示
            local task_type instance_ocid target_ocpus target_memory status attempt create_time
            local last_status last_error last_attempt_time
            local display_name shape config_file created_instance_ocid
            local task_type_label subject_label target_label

            task_type=$(jq -r '.task_type // "N/A"' "$task_info")
            instance_ocid=$(jq -r '.instance_ocid // "N/A"' "$task_info")
            target_ocpus=$(jq -r '.target_ocpus // "N/A"' "$task_info")
            target_memory=$(jq -r '.target_memory // "N/A"' "$task_info")
            status=$(jq -r '.status // "N/A"' "$task_info")
            attempt=$(jq -r '.attempt // 0' "$task_info")
            create_time=$(jq -r '.create_time // "N/A"' "$task_info")
            last_status=$(jq -r '.last_status // "N/A"' "$task_info")
            last_error=$(jq -r '.last_error // ""' "$task_info")
            last_attempt_time=$(jq -r '.last_attempt_time // "N/A"' "$task_info")
            display_name=$(jq -r '.display_name // "N/A"' "$task_info")
            shape=$(jq -r '.shape // "N/A"' "$task_info")
            config_file=$(jq -r '.config_file // ""' "$task_info")
            created_instance_ocid=$(jq -r '.created_instance_ocid // ""' "$task_info")
            task_type_label=$(get_task_type_label "$task_type")
            subject_label=$(get_task_subject_label "$task_info")
            target_label=$(get_task_target_label "$task_info")

            # 状态颜色
            local status_color
            case "$status" in
                running) status_color="${GREEN}" ;;
                completed) status_color="${CYAN}" ;;
                stopped|failed) status_color="${RED}" ;;
                *) status_color="${YELLOW}" ;;
            esac

            local last_status_color
            case "$last_status" in
                success) last_status_color="${GREEN}" ;;
                failed) last_status_color="${RED}" ;;
                *) last_status_color="${YELLOW}" ;;
            esac

            # 显示基础信息
            if [[ "$task_type" == "create_instance" ]]; then
                {
                    printf '%b\n' "任务ID\t$task_id"
                    printf '%b\n' "类型\t$task_type_label"
                    printf '%b\n' "实例名称\t$display_name"
                    printf '%b\n' "实例规格\t$shape"
                    printf '%b\n' "配置文件\t${config_file:-N/A}"
                    printf '%b\n' "目标配置\t$target_label"
                    printf '%b\n' "重试间隔\t$(jq -r '.retry_interval // 30' "$task_info") 秒"
                    printf '%b\n' "创建时间\t$create_time"
                    printf '%b\n' "当前状态\t${status_color}${status}${NC}"
                    printf '%b\n' "执行次数\t$attempt"
                    printf '%b\n' "上次状态\t${last_status_color}${last_status}${NC}"
                    printf '%b\n' "上次尝试\t$last_attempt_time"
                    [[ -n "$created_instance_ocid" ]] && printf '%b\n' "已创建实例\t${created_instance_ocid:0:50}..."
                } | format_tabular_output
            else
                {
                    printf '%b\n' "任务ID\t$task_id"
                    printf '%b\n' "类型\t$task_type_label"
                    printf '%b\n' "实例OCID\t${instance_ocid:0:50}..."
                    printf '%b\n' "目标配置\t$target_label"
                    if [[ "$task_type" == "direct_update" || "$task_type" == "direct_update_instance" ]]; then
                        printf '%b\n' "请求间隔\t$(jq -r '.request_interval // 60' "$task_info") 秒"
                    else
                        printf '%b\n' "重试间隔\t$(jq -r '.retry_interval // 10' "$task_info") 秒"
                    fi
                    printf '%b\n' "创建时间\t$create_time"
                    printf '%b\n' "当前状态\t${status_color}${status}${NC}"
                    printf '%b\n' "执行次数\t$attempt"
                    printf '%b\n' "上次状态\t${last_status_color}${last_status}${NC}"
                    printf '%b\n' "上次尝试\t$last_attempt_time"
                } | format_tabular_output
            fi
            printf '%s\n' ""

            # 显示错误信息（如果有）- 格式化显示
            if [[ -n "$last_error" && "$last_error" != "null" && "$last_error" != "" ]]; then
                printf '%b\n' "${RED}========================================${NC}"
                printf '%b\n' "${RED}错误详情:${NC}"
                printf '%b\n' "${RED}========================================${NC}"

                local error_payload error_code error_message error_status error_timestamp error_request_id
                error_payload=$(get_task_error_payload "$last_error")
                error_code=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .code // "Unknown" else "Unknown" end' 2>/dev/null || printf '%s\n' "Unknown")
                error_message=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .message // "" else . end' 2>/dev/null || printf '%s\n' "")
                error_status=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .status // "" else "" end' 2>/dev/null || printf '%s\n' "")
                error_timestamp=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .timestamp // "" else "" end' 2>/dev/null || printf '%s\n' "")
                error_request_id=$(printf '%s' "$error_payload" | jq -r 'if type == "object" then .["opc-request-id"] // "" else "" end' 2>/dev/null || printf '%s\n' "")

                # 翻译错误代码
                local error_code_translated
                case "$error_code" in
                    InternalError) error_code_translated="内部错误 (InternalError)" ;;
                    NotAuthorizedOrNotFound) error_code_translated="未授权或资源不存在 (NotAuthorizedOrNotFound)" ;;
                    InvalidParameter) error_code_translated="参数无效 (InvalidParameter)" ;;
                    LimitExceeded) error_code_translated="超出限制 (LimitExceeded)" ;;
                    ServiceError) error_code_translated="服务错误 (ServiceError)" ;;
                    *) error_code_translated="$error_code" ;;
                esac

                # 翻译错误消息
                local msg_translated="$error_message"
                case "$error_message" in
                    *"Out of host capacity"*) msg_translated="主机容量不足 - 该区域/AD 目前没有足够的资源" ;;
                    *"quota exceeded"*) msg_translated="配额超限 - 已达到账户资源限制" ;;
                    *"not found"*) msg_translated="资源未找到 - 请检查资源是否存在" ;;
                    *"permission denied"*) msg_translated="权限被拒绝 - 请检查 IAM 策略" ;;
                    *"rate limit"*) msg_translated="请求频率限制 - 请稍后重试" ;;
                esac

                {
                    printf '%b\n' "错误代码\t${RED}$error_code_translated${NC}"
                    printf '%b\n' "错误消息\t$msg_translated"
                    [[ -n "$error_status" && "$error_status" != "null" ]] && printf '%b\n' "HTTP状态\t$error_status"
                    [[ -n "$error_timestamp" && "$error_timestamp" != "null" ]] && printf '%b\n' "时间戳\t$error_timestamp"
                    [[ -n "$error_request_id" && "$error_request_id" != "null" ]] && printf '%b\n' "请求ID\t${error_request_id:0:40}..."
                } | format_tabular_output
                printf '%s\n' ""

                # 显示建议
                printf '%b\n' "${YELLOW}建议:${NC}"
                case "$error_code" in
                    InternalError)
                        printf '%s\n' "  - OCI 服务端临时问题，请稍后重试"
                        printf '%s\n' "  - 如果持续出现，请联系 Oracle 支持"
                        ;;
                    NotAuthorizedOrNotFound)
                        printf '%s\n' "  - 检查 IAM 用户是否有足够的权限"
                        printf '%s\n' "  - 确认实例 OCID 是否正确"
                        printf '%s\n' "  - 确认实例是否已被删除"
                        ;;
                    InvalidParameter)
                        printf '%s\n' "  - 检查请求参数是否正确"
                        printf '%s\n' "  - 确认目标配置是否在允许范围内"
                        ;;
                    LimitExceeded|ServiceError)
                        if [[ "$error_message" == *"Out of host capacity"* ]]; then
                            printf '%s\n' "  - 主机容量不足是常见问题，建议："
                            printf '%s\n' "    1. 降低目标配置（如 2 OCPU → 1 OCPU）"
                            printf '%s\n' "    2. 更换可用性域 (AD)"
                            printf '%s\n' "    3. 在非高峰时段重试"
                            printf '%s\n' "    4. 保持任务继续重试，直到成功"
                        else
                            printf '%s\n' "  - 请稍后重试或联系 Oracle 支持"
                        fi
                        ;;
                    *)
                        printf '%s\n' "  - 请查看完整错误日志获取更多信息"
                        ;;
                esac
                printf '%s\n' ""
            fi
        fi

        # 显示日志选项
        local log_file="$task_path/task.log"
        if [[ -f "$log_file" ]]; then
            printf '%b\n' "${CYAN}日志操作:${NC}"
            printf '%s\n' "  1) 查看最近日志 (最后20行)"
            printf '%s\n' "  2) 实时查看日志 (tail -f)"
            printf '%s\n' "  3) 查看完整日志"
            printf '%s\n' "  0) 返回"
            printf '%s\n' ""
            read -p "请选择: " -r

            case $REPLY in
                1)
                    printf '%s\n' ""
                    printf '%b\n' "${BOLD}最近日志:${NC}"
                    printf '%b\n' "${BOLD}----------------------------------------${NC}"
                    tail -20 "$log_file"
                    printf '%b\n' "${BOLD}----------------------------------------${NC}"
                    printf '%s\n' ""
                    read -p "按回车键继续..." -r
                    ;;
                2)
                    # 实时查看日志
                    follow_task_log "$task_id"
                    ;;
                3)
                    # 查看完整日志（使用 less）
                    less -R "$log_file"
                    ;;
                0)
                    return 0
                    ;;
                *)
                    log_error "无效选项"
                    sleep 1
                    ;;
            esac
        else
            log_warn "暂无日志文件"
            return 0
        fi
    done
}

# 实时查看任务日志
follow_task_log() {
    local task_id="$1"
    local task_path="$TASK_DIR/$task_id"
    local log_file="$task_path/task.log"

    if [[ ! -f "$log_file" ]]; then
        log_error "日志文件不存在"
        return 1
    fi

    printf '%s\n' ""
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}实时日志监控: $task_id${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${CYAN}按 Ctrl+C 返回上一级${NC}"
    printf '%s\n' ""

    # 临时替换全局 trap，让 Ctrl+C 能返回上一级而不是退出脚本
    trap 'printf "%b\n" "\n${YELLOW}返回上一级...${NC}"; kill $(jobs -p) 2>/dev/null; trap "printf \"%b\n\" \"\n${YELLOW}操作已取消${NC}\"; exit 0" INT TERM; return 0' INT TERM

    # 在后台运行 tail -f
    tail -f "$log_file" 2>/dev/null &
    local tail_pid=$!

    # 等待 tail 进程，Ctrl+C 会触发 trap
    wait $tail_pid 2>/dev/null

    # 恢复全局 trap
    trap 'printf "%b\n" "\n${YELLOW}操作已取消${NC}"; exit 0' INT TERM
}

# 停止任务
stop_task() {
    local task_id="$1"
    local task_path="$TASK_DIR/$task_id"

    if [[ ! -d "$task_path" ]]; then
        log_error "任务不存在: $task_id"
        return 1
    fi

    local pid_file="$task_path/task.pid"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log_success "已停止任务: $task_id"
            # 更新任务状态
            if [[ -f "$task_path/task.info" ]]; then
                jq '.status = "stopped" | .end_time = "'"$(date -Iseconds)"'"' \
                    "$task_path/task.info" > "$task_path/task.info.tmp"
                mv "$task_path/task.info.tmp" "$task_path/task.info"
            fi
        else
            log_warn "任务进程已不存在"
        fi
    fi
}

# 恢复任务
resume_task() {
    local task_id="$1"
    local task_path="$TASK_DIR/$task_id"

    if [[ ! -d "$task_path" ]]; then
        log_error "任务不存在: $task_id"
        return 1
    fi

    local task_info="$task_path/task.info"
    if [[ ! -f "$task_info" ]]; then
        log_error "任务信息文件不存在"
        return 1
    fi

    # 读取任务信息
    local task_type=$(jq -r '.task_type' "$task_info")
    local instance_ocid=$(jq -r '.instance_ocid' "$task_info")
    local target_ocpus=$(jq -r '.target_ocpus' "$task_info")
    local target_memory=$(jq -r '.target_memory' "$task_info")
    local retry_interval=$(jq -r '.retry_interval' "$task_info")
    local request_interval=$(jq -r '.request_interval // ""' "$task_info")
    local current_status=$(jq -r '.status' "$task_info")
    local config_file=$(jq -r '.config_file // ""' "$task_info")

    if [[ "$task_type" == "direct_update" || "$task_type" == "direct_update_instance" ]]; then
        if [[ ! "$request_interval" =~ ^[0-9]+$ || "$request_interval" -le 0 ]]; then
            request_interval="$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT"
            jq --argjson request_interval "$request_interval" \
               '.request_interval = $request_interval' \
               "$task_info" > "$task_info.tmp" && mv "$task_info.tmp" "$task_info"
            log_info "旧直接更新任务缺少 request_interval，已自动设置为默认 ${request_interval} 秒"
        fi
    fi

    # 检查任务状态
    if [[ "$current_status" == "running" ]]; then
        # 检查进程是否真的在运行
        local pid_file="$task_path/task.pid"
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "任务已在运行中，无需恢复"
                return 0
            fi
        fi
    fi

    # 重新启动后台任务
    if [[ "$task_type" == "create_instance" ]]; then
        (
            exec_create_instance_task "$task_id" "$config_file" "$retry_interval"
        ) &>"$task_path/task.log" &
    else
        (
            exec_background_task "$task_id" "$task_type" "$instance_ocid" "$target_ocpus" "$target_memory" "$retry_interval" "$request_interval"
        ) &>"$task_path/task.log" &
    fi

    local pid=$!
    printf '%s\n' $pid > "$task_path/task.pid"

    # 更新任务状态
    jq '.status = "running" | .resume_time = "'"$(date -Iseconds)"'"' \
        "$task_info" > "$task_info.tmp"
    mv "$task_info.tmp" "$task_info"

    log_success "任务已恢复: $task_id"
}

# 删除任务
delete_task() {
    local task_id="$1"
    local task_path="$TASK_DIR/$task_id"

    if [[ ! -d "$task_path" ]]; then
        log_error "任务不存在: $task_id"
        return 1
    fi

    # 先停止任务
    stop_task "$task_id" 2>/dev/null

    # 删除任务目录
    rm -rf "$task_path"
    log_success "已删除任务: $task_id"
}

# ================================
# 显示头部
# ================================
show_header() {
    printf '%s\n' ""
    printf '%b\n' "${CYAN}"
    cat <<'EOF'
  ___                 _         ___   ____ ___   _____           _
 / _ \ _ __ __ _  ___| | ___   / _ \ / ___|_ _| |_   _|__   ___ | |
| | | | '__/ _` |/ __| |/ _ \ | | | | |    | |    | |/ _ \ / _ \| |
| |_| | | | (_| | (__| |  __/ | |_| | |___ | |    | | (_) | (_) | |
 \___/|_|  \__,_|\___|_|\___|  \___/ \____|___|   |_|\___/ \___/|_|
EOF
    printf '%b\n' "${NC}"
    printf '%b\n' "${GREEN}OCI 实例配置、创建、更新与后台任务管理工具${NC}"
    printf '%s\n' "GitHub: ${PROJECT_URL}  Version: ${TOOL_VERSION}  Script: oracle/oracle_oci_tool.sh"
    printf '%s\n' "------------------------------------------------------------"
    printf '%b\n' "${BOLD}[ OCI 实例配置管理工具 控制台 ]${NC}"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' ""
}

# ================================
# 系统环境辅助
# ================================
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' "apt"
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' "dnf"
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' "yum"
    elif command -v pacman >/dev/null 2>&1; then
        printf '%s\n' "pacman"
    elif command -v zypper >/dev/null 2>&1; then
        printf '%s\n' "zypper"
    elif command -v apk >/dev/null 2>&1; then
        printf '%s\n' "apk"
    elif command -v brew >/dev/null 2>&1; then
        printf '%s\n' "brew"
    else
        printf '%s\n' "unknown"
    fi
}

dependency_package_for_tool() {
    local manager="$1"
    local tool_name="$2"

    case "$tool_name" in
        jq) printf '%s\n' "jq" ;;
        curl) printf '%s\n' "curl" ;;
        python3)
            case "$manager" in
                pacman) printf '%s\n' "python" ;;
                brew) printf '%s\n' "python" ;;
                *) printf '%s\n' "python3" ;;
            esac
            ;;
        python3_venv)
            case "$manager" in
                apt) printf '%s\n' "python3-venv" ;;
                zypper) printf '%s\n' "python3-venv" ;;
                pacman) printf '%s\n' "python" ;;
                brew) printf '%s\n' "python" ;;
                apk) printf '%s\n' "py3-virtualenv" ;;
                dnf|yum) printf '%s\n' "python3" ;;
                *) return 1 ;;
            esac
            ;;
        column)
            case "$manager" in
                apt) printf '%s\n' "bsdextrautils" ;;
                dnf|yum|pacman|zypper|apk|brew) printf '%s\n' "util-linux" ;;
                *) return 1 ;;
            esac
            ;;
        ssh_keygen)
            case "$manager" in
                apt|apk) printf '%s\n' "openssh-client" ;;
                brew) printf '%s\n' "openssh" ;;
                dnf|yum|zypper) printf '%s\n' "openssh-clients" ;;
                pacman) printf '%s\n' "openssh" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

record_installed_dependency() {
    local manager="$1"
    local package_name="$2"

    mkdir -p "$DATA_DIR"
    touch "$DEPENDENCY_STATE_FILE"
    if ! grep -qx "${manager}:${package_name}" "$DEPENDENCY_STATE_FILE" 2>/dev/null; then
        printf '%s\n' "${manager}:${package_name}" >> "$DEPENDENCY_STATE_FILE"
    fi
}

append_unique_package() {
    local package_name="$1"
    shift
    local existing

    for existing in "$@"; do
        [[ "$existing" == "$package_name" ]] && return 1
    done
    return 0
}

remove_recorded_dependency() {
    local manager="$1"
    local package_name="$2"
    local temp_file="${DEPENDENCY_STATE_FILE}.tmp"

    [[ -f "$DEPENDENCY_STATE_FILE" ]] || return 0
    grep -vx "${manager}:${package_name}" "$DEPENDENCY_STATE_FILE" > "$temp_file" 2>/dev/null || true
    mv "$temp_file" "$DEPENDENCY_STATE_FILE"
}

run_privileged_command() {
    local cmd="$1"

    if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo bash -lc "$cmd"
    else
        bash -lc "$cmd"
    fi
}

install_system_packages() {
    local manager="$1"
    shift

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case "$manager" in
        apt)
            run_privileged_command "apt-get update && apt-get install -y $*"
            ;;
        dnf)
            run_privileged_command "dnf install -y $*"
            ;;
        yum)
            run_privileged_command "yum install -y $*"
            ;;
        pacman)
            run_privileged_command "pacman -Sy --noconfirm $*"
            ;;
        zypper)
            run_privileged_command "zypper --non-interactive install $*"
            ;;
        apk)
            run_privileged_command "apk add --no-cache $*"
            ;;
        brew)
            brew install "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

package_is_installed() {
    local manager="$1"
    local package_name="$2"

    case "$manager" in
        apt)
            dpkg -s "$package_name" >/dev/null 2>&1
            ;;
        dnf|yum|zypper)
            rpm -q "$package_name" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Q "$package_name" >/dev/null 2>&1
            ;;
        apk)
            apk info -e "$package_name" >/dev/null 2>&1
            ;;
        brew)
            brew list --formula "$package_name" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

uninstall_system_packages() {
    local manager="$1"
    shift

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case "$manager" in
        apt)
            run_privileged_command "apt-get remove -y $*"
            ;;
        dnf)
            run_privileged_command "dnf remove -y $*"
            ;;
        yum)
            run_privileged_command "yum remove -y $*"
            ;;
        pacman)
            run_privileged_command "pacman -Rns --noconfirm $*"
            ;;
        zypper)
            run_privileged_command "zypper --non-interactive remove $*"
            ;;
        apk)
            run_privileged_command "apk del $*"
            ;;
        brew)
            brew uninstall "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

uninstall_recorded_dependencies() {
    local entries=("$@")
    local entry manager package_name
    local removed_any="false"
    local failed_any="false"

    if [[ ${#entries[@]} -eq 0 ]]; then
        log_info "没有记录到由脚本自动安装的系统依赖"
        return 0
    fi

    printf '%s\n' ""
    log_info "正在卸载脚本自动安装的系统依赖..."

    for entry in "${entries[@]}"; do
        [[ -z "$entry" || "$entry" != *:* ]] && continue
        manager="${entry%%:*}"
        package_name="${entry#*:}"

        if package_is_installed "$manager" "$package_name"; then
            if uninstall_system_packages "$manager" "$package_name"; then
                log_success "已卸载依赖: ${package_name}"
                remove_recorded_dependency "$manager" "$package_name"
                removed_any="true"
            else
                log_warn "依赖卸载失败: ${package_name}"
                failed_any="true"
            fi
        else
            remove_recorded_dependency "$manager" "$package_name"
        fi
    done

    if [[ "$removed_any" != "true" && "$failed_any" != "true" ]]; then
        log_info "记录中的系统依赖当前均未安装"
    fi

    [[ "$failed_any" != "true" ]]
}

is_private_tool_dir() {
    local dir_path="$1"

    [[ ! -L "$dir_path" ]] || return 1
    mkdir -p "$dir_path"
    [[ ! -L "$dir_path" ]] || return 1
    chmod 700 "$dir_path" 2>/dev/null || true

    [[ -d "$dir_path" ]] || return 1
    [[ "$dir_path" == "$HOME"/* ]] || return 1
    [[ -O "$dir_path" ]] || return 1
    [[ -w "$dir_path" ]] || return 1

    local permissions
    permissions=$(stat -c '%a' "$dir_path" 2>/dev/null || stat -f '%Lp' "$dir_path" 2>/dev/null)
    [[ -n "$permissions" ]] || return 1
    [[ $((10#$permissions % 100)) -eq 0 ]]
}

configure_oci_cli_runtime_env() {
    export OCI_CLI_CONFIG_FILE="$OCI_CONFIG_FILE"

    if [[ -x "$OCI_CLI_BIN" ]]; then
        case ":$PATH:" in
            *":$OCI_CLI_BIN_DIR:"*) ;;
            *) export PATH="$OCI_CLI_BIN_DIR:$PATH" ;;
        esac
        hash -r 2>/dev/null || true
    fi
}

install_oci_cli_interactive() {
    local installer_url="https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh"
    local install_dir="${OCI_CLI_INSTALL_ROOT}/installations/latest-$(date +%Y%m%d-%H%M%S)_$$"
    local exec_dir="$OCI_CLI_BIN_DIR"
    local script_dir="$OCI_CLI_BIN_DIR"
    local installer_file="${OCI_HOME_DIR}/oci-cli-install.sh"
    local installer_home="${OCI_HOME_DIR}/oci-cli-installer-home-$(date +%Y%m%d-%H%M%S)_$$"

    if ! is_private_tool_dir "$OCI_HOME_DIR" || ! is_private_tool_dir "$OCI_CLI_INSTALL_ROOT" || ! is_private_tool_dir "$exec_dir"; then
        log_error "OCI 目录权限不安全，已停止 OCI CLI 自动安装: $OCI_HOME_DIR"
        return 1
    fi

    mkdir -p "$install_dir"
    if ! is_private_tool_dir "$install_dir"; then
        log_error "安装目录权限不安全，已停止 OCI CLI 自动安装: $install_dir"
        return 1
    fi

    mkdir -p "$installer_home"
    if ! is_private_tool_dir "$installer_home"; then
        log_error "安装器临时目录权限不安全，已停止 OCI CLI 自动安装: $installer_home"
        return 1
    fi

    printf '%s\n' ""
    log_info "将自动启动 OCI CLI 官方安装程序"
    printf '%s\n' "安装版本: OCI CLI 最新版本"
    printf '%s\n' "安装目录: $install_dir"
    printf '%s\n' "可执行目录: $exec_dir"
    printf '%s\n' "环境变量: 仅在本脚本运行期间临时使用，不写入用户 ~/.zshrc 或 ~/.bashrc"
    printf '%s\n' ""

    if ! curl -fsSL "$installer_url" -o "$installer_file"; then
        rm -rf "$installer_home"
        log_error "下载 OCI CLI 安装脚本失败"
        return 1
    fi

    HOME="$installer_home" bash "$installer_file" \
        --accept-all-defaults \
        --install-dir "$install_dir" \
        --exec-dir "$exec_dir" \
        --script-dir "$script_dir" \
        --rc-file-path "${installer_home}/oci-cli-installer.rc"
    local exit_code=$?
    rm -f "$installer_file"
    rm -rf "$installer_home"

    if [[ $exit_code -eq 0 ]]; then
        configure_oci_cli_runtime_env
        if ! "$exec_dir/oci" --version >/dev/null 2>&1; then
            log_error "OCI CLI 安装后验证失败"
            return 1
        fi
    fi

    return $exit_code
}

prompt_install_missing_dependencies() {
    local missing_oci="$1"
    local missing_jq="$2"
    local missing_curl="$3"
    local missing_column="$4"
    local missing_python3="${5:-false}"
    local missing_python3_venv="${6:-false}"
    local missing_ssh_keygen="${7:-false}"
    local manager
    local install_packages=()
    local record_packages=()

    manager="$(detect_package_manager)"

    if [[ "$missing_jq" == "false" && "$missing_curl" == "false" && "$missing_column" == "false" && "$missing_oci" == "false" && "$missing_python3" == "false" && "$missing_python3_venv" == "false" && "$missing_ssh_keygen" == "false" ]]; then
        return 0
    fi

    printf '%s\n' ""
    printf '%b\n' "${CYAN}检测到以下缺失项目:${NC}"
    [[ "$missing_oci" == "true" ]] && printf '%s\n' "  - OCI CLI"
    [[ "$missing_jq" == "true" ]] && printf '%s\n' "  - jq"
    [[ "$missing_curl" == "true" ]] && printf '%s\n' "  - curl"
    [[ "$missing_column" == "true" ]] && printf '%s\n' "  - column（用于表格对齐显示，可选）"
    [[ "$missing_python3" == "true" ]] && printf '%s\n' "  - python3"
    [[ "$missing_python3_venv" == "true" ]] && printf '%s\n' "  - python3 venv"
    [[ "$missing_ssh_keygen" == "true" ]] && printf '%s\n' "  - ssh-keygen（用于自动生成实例登录密钥）"
    printf '%s\n' ""
    log_info "将自动尝试安装缺失依赖"

    local tool_name package_name
    for tool_name in jq curl column python3 python3_venv ssh_keygen; do
        case "$tool_name" in
            jq) [[ "$missing_jq" != "true" ]] && continue ;;
            curl) [[ "$missing_curl" != "true" ]] && continue ;;
            column) [[ "$missing_column" != "true" ]] && continue ;;
            python3) [[ "$missing_python3" != "true" ]] && continue ;;
            python3_venv) [[ "$missing_python3_venv" != "true" ]] && continue ;;
            ssh_keygen) [[ "$missing_ssh_keygen" != "true" ]] && continue ;;
        esac

        if package_name="$(dependency_package_for_tool "$manager" "$tool_name")"; then
            if append_unique_package "$package_name" "${install_packages[@]}"; then
                install_packages+=("$package_name")
            fi
        fi
    done

    if [[ ${#install_packages[@]} -gt 0 ]]; then
        for package_name in "${install_packages[@]}"; do
            if ! package_is_installed "$manager" "$package_name"; then
                record_packages+=("$package_name")
            fi
        done

        if install_system_packages "$manager" "${install_packages[@]}"; then
            log_success "系统依赖安装完成"
            for package_name in "${record_packages[@]}"; do
                record_installed_dependency "$manager" "$package_name"
            done
        else
            log_warn "系统依赖自动安装失败"
        fi
    elif [[ "$missing_jq" == "true" || "$missing_curl" == "true" || "$missing_column" == "true" || "$missing_python3" == "true" || "$missing_python3_venv" == "true" || "$missing_ssh_keygen" == "true" ]]; then
        log_warn "未识别到支持的包管理器，无法自动安装系统依赖"
    fi

    if [[ "$missing_oci" == "true" ]]; then
        install_oci_cli_interactive || log_warn "OCI CLI 自动安装未完成"
    fi

    return 0
}

stop_all_running_tasks() {
    init_task_dir

    local stopped_any="false"
    for task_path in "$TASK_DIR"/*; do
        [[ ! -d "$task_path" ]] && continue
        local task_id
        task_id="$(basename "$task_path")"
        stop_task "$task_id" >/dev/null 2>&1 && stopped_any="true"
    done

    [[ "$stopped_any" == "true" ]] && log_info "已尝试停止所有后台任务"
    return 0
}

remove_oci_cli_installation() {
    local removed_any="false"
    local candidates=(
        "$OCI_CLI_BIN"
        "$OCI_CLI_BIN_DIR/oci-cli"
        "$OCI_CLI_BIN_DIR/oci_autocomplete.sh"
        "$OCI_CLI_INSTALL_ROOT"
        "$HOME/bin/oci"
        "$HOME/bin/oci-cli"
        "$HOME/bin/oci_autocomplete.sh"
        "$HOME/lib/oracle-cli"
        "$HOME/.local/bin/oci"
        "$HOME/.local/lib/oracle-cli"
    )

    local path
    for path in "${candidates[@]}"; do
        if [[ -e "$path" ]]; then
            rm -rf "$path"
            removed_any="true"
        fi
    done

    if [[ "$removed_any" == "true" ]]; then
        log_success "已删除常见 OCI CLI 安装文件"
    else
        log_warn "未找到常见 OCI CLI 安装文件，若通过其他方式安装请手动卸载"
    fi
}

uninstall_script() {
    show_header
    printf '%b\n' "${BOLD}[8] 卸载脚本${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""
    printf '%b\n' "${RED}警告: 此操作可能删除依赖、OCI 配置、密钥文件、任务日志和脚本数据${NC}"
    printf '%s\n' ""

    read -p "是否继续进入卸载流程? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "已取消卸载"
        pause
        return 0
    fi

    local recorded_dependency_entries=()
    if [[ -f "$DEPENDENCY_STATE_FILE" ]]; then
        local dependency_entry
        while IFS= read -r dependency_entry; do
            [[ -n "$dependency_entry" ]] && recorded_dependency_entries+=("$dependency_entry")
        done < "$DEPENDENCY_STATE_FILE"
    fi

    printf '%s\n' ""
    read -p "是否先停止所有后台任务? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        stop_all_running_tasks
    fi

    printf '%s\n' ""
    read -p "是否删除脚本数据目录 (${DATA_DIR})? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$DATA_DIR"
        log_success "已删除数据目录: $DATA_DIR"
    fi

    local key_file=""
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        key_file="$(grep "^key_file=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | head -1)"
        key_file="${key_file/#\~/$HOME}"
    fi

    printf '%s\n' ""
    read -p "是否删除 OCI 配置文件 (${OCI_CONFIG_FILE})? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$OCI_CONFIG_FILE"
        log_success "已删除 OCI 配置文件"

        if [[ -n "$key_file" && -f "$key_file" ]]; then
            read -p "是否同时删除私钥文件 (${key_file})? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -f "$key_file"
                log_success "已删除私钥文件"
            fi
        fi

        if [[ -d "$HOME/.oci" ]]; then
            read -p "是否删除整个旧 ~/.oci 目录中的剩余文件? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "$HOME/.oci"
                log_success "已删除旧 ~/.oci 目录"
            fi
        fi
    fi

    printf '%s\n' ""
    read -p "是否尝试卸载 OCI CLI 安装文件? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        remove_oci_cli_installation
    fi

    uninstall_recorded_dependencies "${recorded_dependency_entries[@]}"

    if [[ -n "$SCRIPT_SOURCE_DIR" && -f "$SCRIPT_SOURCE_DIR/oracle_oci_tool.sh" ]]; then
        printf '%s\n' ""
        read -p "是否删除当前本地脚本文件 (${SCRIPT_SOURCE_DIR}/oracle_oci_tool.sh)? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$SCRIPT_SOURCE_DIR/oracle_oci_tool.sh"
            log_success "已删除本地脚本文件"
        fi
    fi

    printf '%s\n' ""
    log_success "卸载流程已完成"
    printf '%s\n' ""
    printf '%s\n' "说明:"
    printf '%s\n' "  - 若 OCI CLI 不是通过常见目录安装，可能仍需手动清理"
    printf '%s\n' "  - 若通过其他方式安装了依赖，请按对应包管理器手动检查"
    pause
}

# ================================
# 检查 OCI CLI 是否安装
# ================================
check_oci_cli() {
    configure_oci_cli_runtime_env

    if ! command -v oci &> /dev/null; then
        log_error "OCI CLI 未安装"
        printf '%s\n' ""
        printf '%s\n' "可执行自动安装:"
        printf '%s\n' "  选择 [1] 检查 OCI 环境，脚本会安装到 ${DATA_DIR} 并临时配置当前运行环境"
        printf '%s\n' ""
        return 1
    fi
    return 0
}

# ================================
# 检查 OCI 配置是否存在
# ================================
check_oci_config() {
    if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
        log_error "OCI 配置文件不存在: $OCI_CONFIG_FILE"
        log_info "请先执行 [2] 初始化 OCI 配置"
        return 1
    fi
    repair_oci_key_permissions >/dev/null 2>&1 || true
    return 0
}

get_oci_key_file_from_config() {
    local config_file="${1:-$OCI_CONFIG_FILE}"
    local key_file

    [[ -f "$config_file" ]] || return 1
    key_file=$(grep "^key_file=" "$config_file" 2>/dev/null | cut -d'=' -f2- | head -1)
    [[ -n "$key_file" ]] || return 1
    key_file="${key_file/#\~/$HOME}"
    printf '%s\n' "$key_file"
}

repair_oci_key_permissions() {
    local key_file key_dir

    key_file="$(get_oci_key_file_from_config 2>/dev/null || true)"
    [[ -n "$key_file" ]] || return 0
    [[ -e "$key_file" ]] || return 0

    if [[ -L "$key_file" ]]; then
        log_warn "OCI 私钥文件是符号链接，已跳过自动修复权限: $key_file"
        return 1
    fi

    key_dir="$(dirname "$key_file")"
    if [[ -d "$key_dir" && ! -L "$key_dir" ]]; then
        chmod 700 "$key_dir" 2>/dev/null || true
    fi

    if chmod 600 "$key_file" 2>/dev/null; then
        return 0
    fi

    if command -v oci >/dev/null 2>&1; then
        if oci setup repair-file-permissions --file "$key_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    log_warn "无法自动修复 OCI 私钥权限，请手动执行: chmod 600 $key_file"
    return 1
}

print_oci_error_detail() {
    local error_output="$1"

    error_output="$(printf '%s\n' "$error_output" | sed '/^[[:space:]]*$/d' | head -n 20)"
    if [[ -n "$error_output" ]]; then
        printf '%s\n' ""
        printf '%b\n' "${YELLOW}OCI CLI 错误详情:${NC}"
        printf '%s\n' "----------------------------------------"
        printf '%s\n' "$error_output"
        printf '%s\n' "----------------------------------------"
    fi
}

print_oci_error_suggestions() {
    local error_output="$1"

    [[ -n "$error_output" ]] || return 0

    printf '%s\n' ""
    printf '%b\n' "${YELLOW}错误解释和建议:${NC}"
    printf '%s\n' "----------------------------------------"

    if [[ "$error_output" == *"Permissions on"* && "$error_output" == *"too open"* ]]; then
        printf '%s\n' "  - 私钥文件权限过宽，OCI CLI 不建议使用当前权限。"
        printf '%s\n' "    建议执行:"
        printf '%s\n' "      chmod 600 ${OCI_KEY_FILE_DEFAULT}"
        printf '%s\n' "    或使用 OCI CLI 提示的 repair-file-permissions 命令修复。"
    fi

    if [[ "$error_output" == *"NotAuthenticated"* || "$error_output" == *'"status": 401'* ]]; then
        printf '%s\n' "  - OCI 返回 NotAuthenticated/401，表示认证信息没有通过。"
        printf '%s\n' "    常见原因:"
        printf '%s\n' "      1) config 中 fingerprint 和 OCI 控制台 API Key 指纹不一致"
        printf '%s\n' "      2) key_file 指向的私钥和控制台上传的公钥不是一对"
        printf '%s\n' "      3) user OCID 或 tenancy OCID 填错"
        printf '%s\n' "      4) API 公钥没有上传到该 user 的 API Keys"
        printf '%s\n' "      5) 私钥文件内容损坏，或复制时多了空格/换行"
        printf '%s\n' "    建议处理:"
        printf '%s\n' "      1) 进入 OCI 控制台 -> 用户设置 -> API 密钥"
        printf '%s\n' "      2) 核对脚本配置里的 user、tenancy、fingerprint"
        printf '%s\n' "      3) 确认 ${OCI_KEY_FILE_DEFAULT} 是对应 API 公钥的私钥"
        printf '%s\n' "      4) 如果不确定，建议重新生成 API Key 并重新执行 [2] 初始化 OCI 配置"
    fi

    if [[ "$error_output" == *"InvalidConfig"* || "$error_output" == *"ConfigFileNotFound"* ]]; then
        printf '%s\n' "  - OCI CLI 配置文件无效或未找到。"
        printf '%s\n' "    建议重新执行 [2] 初始化 OCI 配置。"
    fi

    if [[ "$error_output" == *"Could not find private key"* || "$error_output" == *"No such file"* ]]; then
        printf '%s\n' "  - 私钥文件不存在或路径错误。"
        printf '%s\n' "    请检查 config 中 key_file 是否指向真实存在的私钥文件。"
    fi

    if [[ "$error_output" == *"ConnectionError"* || "$error_output" == *"NameResolutionError"* || "$error_output" == *"Failed to establish"* ]]; then
        printf '%s\n' "  - 网络连接失败，可能是 DNS、代理、防火墙或网络不可达。"
        printf '%s\n' "    请确认服务器可以访问 OCI API endpoint。"
    fi

    printf '%s\n' "----------------------------------------"
}

test_oci_connection() {
    local namespace_output exit_code namespace

    repair_oci_key_permissions >/dev/null 2>&1 || true

    namespace_output=$(oci os ns get --output json 2>&1)
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        namespace=$(printf '%s\n' "$namespace_output" | jq -r '.data // empty' 2>/dev/null)
        if [[ -z "$namespace" || "$namespace" == "null" ]]; then
            namespace=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
        fi
        TEST_OCI_CONNECTION_NAMESPACE="$namespace"
        TEST_OCI_CONNECTION_ERROR=""
        return 0
    fi

    TEST_OCI_CONNECTION_NAMESPACE=""
    TEST_OCI_CONNECTION_ERROR="$namespace_output"
    return "$exit_code"
}

# ================================
# 检查 OCI 环境
# ================================
check_oci_environment() {
    local allow_auto_install="${1:-true}"

    show_header
    printf '%b\n' "${BOLD}[1] 检查 OCI 环境${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    local all_ok=true
    local missing_oci="false"
    local missing_jq="false"
    local missing_curl="false"
    local missing_column="false"
    local missing_python3="false"
    local missing_python3_venv="false"
    local missing_ssh_keygen="false"

    # 检查 OCI CLI
    printf '%s' "检查 OCI CLI... "
    if check_oci_cli; then
        local oci_version
        oci_version=$(oci --version 2>/dev/null | head -1)
        printf '%b\n' "${GREEN}✓ 已安装${NC} ($oci_version)"
    else
        printf '%b\n' "${RED}✗ 未安装${NC}"
        all_ok=false
        missing_oci="true"
    fi

    # 检查 jq
    printf '%s' "检查 jq... "
    if command -v jq &> /dev/null; then
        printf '%b\n' "${GREEN}✓ 已安装${NC}"
    else
        printf '%b\n' "${YELLOW}✗ 未安装${NC}"
        all_ok=false
        missing_jq="true"
    fi

    # 检查 curl
    printf '%s' "检查 curl... "
    if command -v curl &> /dev/null; then
        printf '%b\n' "${GREEN}✓ 已安装${NC}"
    else
        printf '%b\n' "${YELLOW}✗ 未安装${NC}"
        all_ok=false
        missing_curl="true"
    fi

    # 检查 Python 3（OCI CLI 安装器需要）
    printf '%s' "检查 python3... "
    if command -v python3 &> /dev/null; then
        printf '%b\n' "${GREEN}✓ 已安装${NC}"
    else
        printf '%b\n' "${YELLOW}✗ 未安装${NC}"
        all_ok=false
        missing_python3="true"
        missing_python3_venv="true"
    fi

    # 检查 Python venv（OCI CLI 安装器需要）
    printf '%s' "检查 python3 venv... "
    if command -v python3 &> /dev/null && python3 -m venv --help >/dev/null 2>&1; then
        printf '%b\n' "${GREEN}✓ 可用${NC}"
    else
        printf '%b\n' "${YELLOW}✗ 不可用${NC}"
        all_ok=false
        missing_python3_venv="true"
    fi

    # 检查 column（可选）
    printf '%s' "检查 column... "
    if command -v column &> /dev/null; then
        printf '%b\n' "${GREEN}✓ 已安装${NC}"
    else
        printf '%b\n' "${YELLOW}✗ 未安装${NC} (可选，将降级为普通文本显示)"
        missing_column="true"
    fi

    # 检查 ssh-keygen（自动生成实例 SSH 密钥需要）
    printf '%s' "检查 ssh-keygen... "
    if command -v ssh-keygen &> /dev/null; then
        printf '%b\n' "${GREEN}✓ 已安装${NC}"
    else
        printf '%b\n' "${YELLOW}✗ 未安装${NC}"
        all_ok=false
        missing_ssh_keygen="true"
    fi

    # 检查 OCI 配置
    printf '%s' "检查 OCI 配置... "
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        printf '%b\n' "${GREEN}✓ 存在${NC} ($OCI_CONFIG_FILE)"
    else
        printf '%b\n' "${YELLOW}✗ 不存在${NC}"
        all_ok=false
    fi

    # 检查私钥文件
    printf '%s' "检查私钥文件... "
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        local key_file
        key_file=$(grep "^key_file=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | head -1)
        key_file="${key_file/#\~/$HOME}"
        if [[ -f "$key_file" ]]; then
            printf '%b\n' "${GREEN}✓ 存在${NC} ($key_file)"
        else
            printf '%b\n' "${YELLOW}✗ 不存在${NC} ($key_file)"
        fi
    fi

    # 测试连接
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        printf '%s\n' ""
        printf '%s' "测试 OCI 连接... "
        if test_oci_connection; then
            printf '%b\n' "${GREEN}✓ 成功${NC} (命名空间: $TEST_OCI_CONNECTION_NAMESPACE)"
        else
            printf '%b\n' "${RED}✗ 失败${NC}"
            print_oci_error_detail "$TEST_OCI_CONNECTION_ERROR"
            print_oci_error_suggestions "$TEST_OCI_CONNECTION_ERROR"
            all_ok=false
        fi
    fi

    printf '%s\n' ""
    if $all_ok; then
        log_success "环境检查通过"
    else
        log_warn "部分检查未通过，请先配置环境"
    fi

    if [[ "$allow_auto_install" == "true" && ( "$missing_oci" == "true" || "$missing_jq" == "true" || "$missing_curl" == "true" || "$missing_column" == "true" || "$missing_python3" == "true" || "$missing_python3_venv" == "true" || "$missing_ssh_keygen" == "true" ) ]]; then
        prompt_install_missing_dependencies "$missing_oci" "$missing_jq" "$missing_curl" "$missing_column" "$missing_python3" "$missing_python3_venv" "$missing_ssh_keygen"
        printf '%s\n' ""
        log_info "依赖安装流程结束，正在重新检查环境..."
        sleep 1
        check_oci_environment "false"
        return $?
    fi

    pause
    return 0
}

# ================================
# 初始化 OCI 配置
# ================================
init_oci_config() {
    show_header
    printf '%b\n' "${BOLD}[2] 初始化 OCI 配置${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    # 检查现有配置
    local existing_user="" existing_fingerprint="" existing_tenancy=""
    local existing_region="" existing_key=""

    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        printf '%b\n' "${GREEN}✓ 检测到现有 OCI CLI 配置${NC}"
        # 读取现有配置
        while IFS= read -r line; do
            [[ "$line" =~ ^user= ]] && existing_user="${line#user=}"
            [[ "$line" =~ ^fingerprint= ]] && existing_fingerprint="${line#fingerprint=}"
            [[ "$line" =~ ^tenancy= ]] && existing_tenancy="${line#tenancy=}"
            [[ "$line" =~ ^region= ]] && existing_region="${line#region=}"
            [[ "$line" =~ ^key_file= ]] && existing_key="${line#key_file=}"
        done < "$OCI_CONFIG_FILE"
        existing_key="${existing_key/#\~/$HOME}"
        printf '%s\n' ""
    fi

    printf '%b\n' "${YELLOW}请输入 OCI 配置信息（直接回车使用当前值）:${NC}"
    printf '%s\n' ""

    # 用户 OCID
    if [[ -n "$existing_user" ]]; then
        printf '%b\n' "用户 OCID: ${CYAN}$existing_user${NC}"
        read -p "按回车保持，或输入新值: " user_input
        USER_OCID="${user_input:-$existing_user}"
    else
        read -p "用户 OCID: " USER_OCID
    fi
    while [[ -z "$USER_OCID" || ! "$USER_OCID" =~ ^ocid1\.user\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的用户 OCID，格式应为: ocid1.user.oc1...${NC}"
        read -p "用户 OCID: " USER_OCID
    done

    # API 密钥指纹
    if [[ -n "$existing_fingerprint" ]]; then
        printf '%b\n' "API 密钥指纹: ${CYAN}$existing_fingerprint${NC}"
        read -p "按回车保持，或输入新值: " fp_input
        FINGERPRINT="${fp_input:-$existing_fingerprint}"
    else
        read -p "API 密钥指纹 (例如: 12:34:56:78:90:ab:cd:ef): " FINGERPRINT
    fi
    while [[ -z "$FINGERPRINT" ]]; do
        printf '%b\n' "${RED}指纹不能为空${NC}"
        read -p "API 密钥指纹: " FINGERPRINT
    done

    # 租户 OCID
    if [[ -n "$existing_tenancy" ]]; then
        printf '%b\n' "租户 OCID: ${CYAN}$existing_tenancy${NC}"
        read -p "按回车保持，或输入新值: " tenancy_input
        TENANCY_OCID="${tenancy_input:-$existing_tenancy}"
    else
        read -p "租户 OCID: " TENANCY_OCID
    fi
    while [[ -z "$TENANCY_OCID" || ! "$TENANCY_OCID" =~ ^ocid1\.tenancy\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的租户 OCID，格式应为: ocid1.tenancy.oc1...${NC}"
        read -p "租户 OCID: " TENANCY_OCID
    done

    # 选择区域
    printf '%s\n' ""
    printf '%s\n' "常用区域:"
    printf '%s\n' "  1) ap-chuncheon-1    (春川)"
    printf '%s\n' "  2) ap-seoul-1        (首尔)"
    printf '%s\n' "  3) ap-tokyo-1        (东京)"
    printf '%s\n' "  4) ap-osaka-1        (大阪)"
    printf '%s\n' "  5) us-ashburn-1      (阿什本)"
    printf '%s\n' "  6) us-phoenix-1      (凤凰城)"
    printf '%s\n' "  7) eu-frankfurt-1    (法兰克福)"
    printf '%s\n' "  8) 其他 (手动输入)"
    printf '%s\n' ""

    if [[ -n "$existing_region" ]]; then
        printf '%b\n' "当前区域: ${CYAN}$existing_region${NC}"
        read -p "选择区域 (1-8)，或按回车保持: " region_choice
        if [[ -z "$region_choice" ]]; then
            REGION="$existing_region"
        else
            case $region_choice in
                1) REGION="ap-chuncheon-1" ;;
                2) REGION="ap-seoul-1" ;;
                3) REGION="ap-tokyo-1" ;;
                4) REGION="ap-osaka-1" ;;
                5) REGION="us-ashburn-1" ;;
                6) REGION="us-phoenix-1" ;;
                7) REGION="eu-frankfurt-1" ;;
                *) read -p "输入区域代码: " REGION ;;
            esac
        fi
    else
        read -p "选择区域 (1-8): " region_choice
        case $region_choice in
            1) REGION="ap-chuncheon-1" ;;
            2) REGION="ap-seoul-1" ;;
            3) REGION="ap-tokyo-1" ;;
            4) REGION="ap-osaka-1" ;;
            5) REGION="us-ashburn-1" ;;
            6) REGION="us-phoenix-1" ;;
            7) REGION="eu-frankfurt-1" ;;
            *) read -p "输入区域代码: " REGION ;;
        esac
    fi

    # 私钥文件
    printf '%s\n' ""
    local default_key="${existing_key:-$OCI_KEY_FILE_DEFAULT}"
    printf '%b\n' "私钥文件路径: ${CYAN}$default_key${NC}"
    read -p "按回车保持，或输入新路径: " key_input
    KEY_FILE="${key_input:-$default_key}"
    KEY_FILE="${KEY_FILE/#\~/$HOME}"

    # 检查私钥文件
    if [[ ! -f "$KEY_FILE" ]]; then
        printf '%b\n' "${YELLOW}警告: 私钥文件不存在: $KEY_FILE${NC}"
        printf '%s\n' "请确保稍后将私钥文件放置到正确位置"
    fi

    # 配置摘要
    printf '%s\n' ""
    printf '%s\n' "========================================"
    printf '%b\n' "${BOLD}配置摘要:${NC}"
    printf '%s\n' "  用户 OCID:     $USER_OCID"
    printf '%s\n' "  租户 OCID:     $TENANCY_OCID"
    printf '%s\n' "  密钥指纹:      $FINGERPRINT"
    printf '%s\n' "  区域:          $REGION"
    printf '%s\n' "  私钥文件:      $KEY_FILE"
    printf '%s\n' "========================================"

    read -p "确认保存配置? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    printf '
'
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 创建 OCI 配置目录
        mkdir -p "$(dirname "$OCI_CONFIG_FILE")"

        # 写入 OCI CLI 配置文件
        cat > "$OCI_CONFIG_FILE" << EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY_OCID
region=$REGION
key_file=$KEY_FILE
EOF

        chmod 600 "$OCI_CONFIG_FILE"
        repair_oci_key_permissions >/dev/null 2>&1 || true
        log_success "OCI CLI 配置已保存到: $OCI_CONFIG_FILE"

        # 验证连接
        printf '%s\n' ""
        log_info "验证 OCI 连接..."
        if test_oci_connection; then
            log_success "OCI 连接成功，命名空间: $TEST_OCI_CONNECTION_NAMESPACE"
        else
            log_warn "OCI 连接验证失败，请检查配置"
            print_oci_error_detail "$TEST_OCI_CONNECTION_ERROR"
            print_oci_error_suggestions "$TEST_OCI_CONNECTION_ERROR"
        fi
    else
        printf '%s\n' "配置已取消"
    fi

    pause
}

# ================================
# 查看 OCI 配置
# ================================
view_oci_config() {
    show_header
    printf '%b\n' "${BOLD}[3] 查看 OCI 配置${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
        log_error "OCI 配置文件不存在"
        log_info "请先执行 [2] 初始化 OCI 配置"
        pause
        return 1
    fi

    printf '%b\n' "${BOLD}OCI CLI 配置文件内容:${NC}"
    printf '%s\n' "文件路径: $OCI_CONFIG_FILE"
    printf '%s\n' ""
    printf '%s\n' "----------------------------------------"
    cat "$OCI_CONFIG_FILE"
    printf '%s\n' "----------------------------------------"
    printf '%s\n' ""

    # 测试连接
    log_info "测试 OCI 连接..."
    if test_oci_connection; then
        log_success "连接成功，命名空间: $TEST_OCI_CONNECTION_NAMESPACE"
    else
        log_error "连接失败，请检查配置"
        print_oci_error_detail "$TEST_OCI_CONNECTION_ERROR"
        print_oci_error_suggestions "$TEST_OCI_CONNECTION_ERROR"
    fi

    pause
}

# ================================
# 列出实例
# ================================
list_instances() {
    show_header
    printf '%b\n' "${BOLD}[4] 列出实例${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    log_info "获取实例列表..."

    # 获取租户 ID
    local tenancy_id
    tenancy_id=$(grep "^tenancy=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)

    if [[ -z "$tenancy_id" ]]; then
        log_error "无法从配置文件读取租户 ID"
        pause
        return 1
    fi

    # 获取实例列表
    local instances_json
    instances_json=$(oci compute instance list \
        --compartment-id "$tenancy_id" \
        --output json 2>/dev/null)

    if [[ -z "$instances_json" ]]; then
        log_error "获取实例列表失败"
        pause
        return 1
    fi

    # 检查是否有实例
    local instance_count
    instance_count=$(printf '%s\n' "$instances_json" | jq -r '.data | length' 2>/dev/null)

    if [[ -z "$instance_count" || "$instance_count" -eq 0 ]]; then
        log_warn "未找到任何实例"
        pause
        return 0
    fi

    printf '%s\n' ""
    printf '%b\n' "${CYAN}找到 $instance_count 个实例，正在获取详细信息...${NC}"
    printf '%s\n' ""

    # 使用临时文件收集表格数据
    local table_data=$(mktemp)
    printf '%b\n' "序号\t名称\t状态\tOCPU\t内存(GB)\t形状\t实例 OCID" > "$table_data"
    printf '%b\n' "----\t----\t------\t------\t----------\t------\t--------------------------------------------------" >> "$table_data"

    # 存储所有实例 OCID 用于后续选择
    declare -a INSTANCE_OCIDS
    local idx=0
    while IFS= read -r instance_ocid; do
        ((idx++))
        INSTANCE_OCIDS[$idx]="$instance_ocid"

        # 获取实例详细信息
        local detail_json
        detail_json=$(oci compute instance get \
            --instance-id "$instance_ocid" \
            --output json 2>/dev/null)

        if [[ -n "$detail_json" ]]; then
            local name state shape ocpus memory
            name=$(printf '%s\n' "$detail_json" | jq -r '.data["display-name"] // "N/A"')
            state=$(printf '%s\n' "$detail_json" | jq -r '.data["lifecycle-state"] // "N/A"')
            shape=$(printf '%s\n' "$detail_json" | jq -r '.data.shape // "N/A"')
            ocpus=$(printf '%s\n' "$detail_json" | jq -r '.data["shape-config"].ocpus // "N/A"')
            memory=$(printf '%s\n' "$detail_json" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
            ocid_short="${instance_ocid:0:47}..."

            # 添加到表格（不带颜色代码）
            printf '%b\n' "$idx\t$name\t$state\t$ocpus\t$memory\t$shape\t$ocid_short" >> "$table_data"
        else
            printf '%b\n' "$idx\t获取失败\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$table_data"
        fi
    done < <(printf '%s\n' "$instances_json" | jq -r '.data[].id' 2>/dev/null)

    # 显示表格（自动对齐）
    format_tabular_file "$table_data"
    rm -f "$table_data"

    printf '%s\n' ""

    # 提供选择功能
    printf '%b\n' "${CYAN}提示: 输入上方实例列表左侧的序号查看完整信息，或按回车返回${NC}"
    printf '%s\n' ""

    read -p "请输入上方实例列表左侧的序号 [1-${instance_count}]，或按回车返回: " choice

    if [[ -z "$choice" ]]; then
        pause
        return 0
    fi

    if is_valid_list_choice "$choice" "$instance_count"; then
        local selected_ocid="${INSTANCE_OCIDS[$choice]}"

        # 获取实例详细信息
        local selected_detail
        selected_detail=$(oci compute instance get \
            --instance-id "$selected_ocid" \
            --output json 2>/dev/null)

        if [[ -n "$selected_detail" ]]; then
            local selected_name selected_state selected_shape selected_ocpus selected_memory
            selected_name=$(printf '%s\n' "$selected_detail" | jq -r '.data["display-name"] // "N/A"')
            selected_state=$(printf '%s\n' "$selected_detail" | jq -r '.data["lifecycle-state"] // "N/A"')
            selected_shape=$(printf '%s\n' "$selected_detail" | jq -r '.data.shape // "N/A"')
            selected_ocpus=$(printf '%s\n' "$selected_detail" | jq -r '.data["shape-config"].ocpus // "N/A"')
            selected_memory=$(printf '%s\n' "$selected_detail" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')

            # 第一部分：关键信息
            printf '%s\n' ""
            printf '%b\n' "${BOLD}========================================${NC}"
            printf '%b\n' "${BOLD}实例关键信息 #${choice}${NC}"
            printf '%b\n' "${BOLD}========================================${NC}"
            # 使用表格格式显示
            {
                printf '%b\n' "名称\t$selected_name"
                printf '%b\n' "状态\t$selected_state"
                printf '%b\n' "OCPU\t$selected_ocpus"
                printf '%b\n' "内存(GB)\t$selected_memory"
                printf '%b\n' "形状\t$selected_shape"
                printf '%b\n' "OCID\t$selected_ocid"
            } | format_tabular_output
            printf '%s\n' ""

            # 第二部分：完整 JSON
            read -p "是否查看完整 JSON 信息? [Y/n]: " view_json
            [[ -z "$view_json" ]] && view_json="y"

            if [[ $view_json =~ ^[Yy]$ ]]; then
                printf '%s\n' ""
                printf '%b\n' "${BOLD}========================================${NC}"
                printf '%b\n' "${BOLD}完整 JSON 信息${NC}"
                printf '%b\n' "${BOLD}========================================${NC}"
                printf '%s\n' "$selected_detail" | jq '.'
                printf '%s\n' ""

                read -p "是否保存到文件? [Y/n]: " save_json
                [[ -z "$save_json" ]] && save_json="y"

                if [[ $save_json =~ ^[Yy]$ ]]; then
                    local json_file="instance_${selected_name}_$(date +%Y%m%d-%H%M%S).json"
                    printf '%s\n' "$selected_detail" > "$json_file"
                    log_success "已保存到: $json_file"
                    printf '%s\n' ""
                fi
            fi
        else
            printf '%b\n' "${RED}获取实例详情失败${NC}"
        fi
    else
        printf '%b\n' "${RED}无效选择，请输入 1-${instance_count} 之间的数字${NC}"
    fi

    printf '%s\n' ""
    pause
}

# ================================
# 停止实例（交互式）
# ================================
stop_instance() {
    show_header
    printf '%b\n' "${BOLD}[5] 停止实例${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入实例 ID
    printf '%b\n' "${YELLOW}请输入要停止的实例 ID:${NC}"
    read -p "实例 OCID: " INSTANCE_OCID
    while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
        read -p "实例 OCID: " INSTANCE_OCID
    done

    # 获取当前实例信息
    log_info "获取实例信息..."
    local current_info
    current_info=$(oci compute instance get \
        --instance-id "$INSTANCE_OCID" \
        --output json 2>/dev/null)

    if [[ -z "$current_info" ]]; then
        local name state
        name=$(printf '%s\n' "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(printf '%s\n' "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        printf '%s\n' ""
        printf '%s\n' "当前实例信息:"
        printf '%s\n' "  名称: $name"
        printf '%s\n' "  状态: $state"
    fi

    printf '%s\n' ""
    read -p "确认停止实例? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    printf '
'
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        printf '%s\n' "操作已取消"
        pause
        return 0
    fi

    log_info "正在停止实例..."

    local result
    result=$(oci compute instance action \
        --instance-id "$INSTANCE_OCID" \
        --action STOP \
        --output json 2>&1)

    if [[ $? -eq 0 ]]; then
        log_success "停止实例命令已发送"
        log_info "等待实例停止..."

        # 等待实例停止
        local max_wait=120
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local state
            state=$(oci compute instance get \
                --instance-id "$INSTANCE_OCID" \
                --query 'data."lifecycle-state"' \
                --raw-output 2>/dev/null)

            if [[ "$state" == "STOPPED" ]]; then
                log_success "实例已停止"
                break
            fi

            printf '%s' "."
            sleep 5
            ((waited += 5))
        done
        printf '%s\n' ""
    else
        log_error "停止实例失败: $result"
    fi

    printf '%s\n' ""
    pause
}

# ================================
# 启动实例（交互式）
# ================================
start_instance() {
    show_header
    printf '%b\n' "${BOLD}[6] 启动实例${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入实例 ID
    printf '%b\n' "${YELLOW}请输入要启动的实例 ID:${NC}"
    read -p "实例 OCID: " INSTANCE_OCID
    while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
        read -p "实例 OCID: " INSTANCE_OCID
    done

    # 获取当前实例信息
    log_info "获取实例信息..."
    local current_info
    current_info=$(oci compute instance get \
        --instance-id "$INSTANCE_OCID" \
        --output json 2>/dev/null)

    if [[ -n "$current_info" ]]; then
        local name state
        name=$(printf '%s\n' "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(printf '%s\n' "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        printf '%s\n' ""
        printf '%s\n' "当前实例信息:"
        printf '%s\n' "  名称: $name"
        printf '%s\n' "  状态: $state"
    fi

    printf '%s\n' ""
    read -p "确认启动实例? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    printf '
'
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        printf '%s\n' "操作已取消"
        pause
        return 0
    fi

    log_info "正在启动实例..."

    local result
    result=$(oci compute instance action \
        --instance-id "$INSTANCE_OCID" \
        --action START \
        --output json 2>&1)

    if [[ $? -eq 0 ]]; then
        log_success "启动实例命令已发送"
        log_info "等待实例启动..."

        # 等待实例启动
        local max_wait=120
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local state
            state=$(oci compute instance get \
                --instance-id "$INSTANCE_OCID" \
                --query 'data."lifecycle-state"' \
                --raw-output 2>/dev/null)

            if [[ "$state" == "RUNNING" ]]; then
                log_success "实例已启动"
                break
            fi

            printf '%s' "."
            sleep 5
            ((waited += 5))
        done
        printf '%s\n' ""
    else
        log_error "启动实例失败: $result"
    fi

    printf '%s\n' ""
    pause
}

# ================================
# 直接更新实例配置（交互式）
# ================================
update_instance_config_direct() {
    show_header
    printf '%b\n' "${BOLD}[7] 直接更新实例配置${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入参数
    printf '%b\n' "${YELLOW}请输入更新参数:${NC}"
    printf '%s\n' ""

    # 实例 ID（如果已经设置则跳过）
    if [[ -z "$INSTANCE_OCID" ]]; then
        read -p "实例 OCID: " INSTANCE_OCID
        while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
            printf '%b\n' "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
            read -p "实例 OCID: " INSTANCE_OCID
        done
    else
        printf '%b\n' "${GREEN}✓${NC} 实例 OCID: ${INSTANCE_OCID:0:30}..."
    fi

    # 目标 OCPU
    read -p "目标 OCPU 数量 [默认: 4]: " TARGET_OCPUS
    TARGET_OCPUS="${TARGET_OCPUS:-4}"

    # 目标内存
    read -p "目标内存 (GB) [默认: 24]: " TARGET_MEMORY
    TARGET_MEMORY="${TARGET_MEMORY:-24}"

    # 请求间隔
    read -p "请求间隔 (秒) [默认: ${OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}]: " REQUEST_INTERVAL
    REQUEST_INTERVAL="${REQUEST_INTERVAL:-$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}"
    if [[ ! "$REQUEST_INTERVAL" =~ ^[0-9]+$ || "$REQUEST_INTERVAL" -le 0 ]]; then
        log_error "请求间隔必须为正整数"
        pause
        return 1
    fi

    # 获取当前实例信息
    log_info "获取实例当前配置..."
    local current_info
    current_info=$(oci compute instance get \
        --instance-id "$INSTANCE_OCID" \
        --output json 2>/dev/null)

    if [[ -n "$current_info" ]]; then
        local name state current_ocpus current_memory shape
        name=$(printf '%s\n' "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(printf '%s\n' "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        current_ocpus=$(printf '%s\n' "$current_info" | jq -r '.data["shape-config"].ocpus // "N/A"')
        current_memory=$(printf '%s\n' "$current_info" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
        shape=$(printf '%s\n' "$current_info" | jq -r '.data.shape // "N/A"')

        printf '%s\n' ""
        printf '%s\n' "当前实例信息:"
        printf '%s\n' "  名称: $name"
        printf '%s\n' "  状态: $state"
        printf '%s\n' "  形状: $shape"
        printf '%s\n' "  当前 OCPU: $current_ocpus"
        printf '%s\n' "  当前内存: ${current_memory} GB"
        printf '%s\n' ""
        printf '%s\n' "目标配置:"
        printf '%s\n' "  目标 OCPU: $TARGET_OCPUS"
        printf '%s\n' "  目标内存: ${TARGET_MEMORY} GB"
        printf '%s\n' "  请求间隔: ${REQUEST_INTERVAL} 秒"
    fi

    printf '%s\n' ""
    read -p "确认执行直接更新? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    printf '
'
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        printf '%s\n' "操作已取消"
        pause
        return 0
    fi

    # 创建后台任务
    create_background_task "direct_update_instance" "$INSTANCE_OCID" "$TARGET_OCPUS" "$TARGET_MEMORY" "0" "$REQUEST_INTERVAL"
}

resize_instance_boot_volume() {
    local instance_ocid="$1"
    local target_size_gb="$2"

    local instance_json compartment_id availability_domain
    instance_json=$(oci compute instance get \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    if [[ -z "$instance_json" ]]; then
        log_warn "无法获取实例信息，跳过启动盘扩容"
        return 1
    fi

    compartment_id=$(printf '%s\n' "$instance_json" | jq -r '.data["compartment-id"] // empty')
    availability_domain=$(printf '%s\n' "$instance_json" | jq -r '.data["availability-domain"] // empty')
    if [[ -z "$compartment_id" || -z "$availability_domain" ]]; then
        log_warn "无法读取实例区间或可用性域，跳过启动盘扩容"
        return 1
    fi

    local attachment_json boot_volume_id current_size
    attachment_json=$(oci compute boot-volume-attachment list \
        --compartment-id "$compartment_id" \
        --availability-domain "$availability_domain" \
        --instance-id "$instance_ocid" \
        --all \
        --output json 2>/dev/null)
    boot_volume_id=$(printf '%s\n' "$attachment_json" | jq -r '.data[0]["boot-volume-id"] // empty' 2>/dev/null)
    if [[ -z "$boot_volume_id" ]]; then
        log_warn "未找到实例启动盘，跳过启动盘扩容"
        return 1
    fi

    current_size=$(oci bv boot-volume get \
        --boot-volume-id "$boot_volume_id" \
        --query 'data."size-in-gbs"' \
        --raw-output 2>/dev/null)
    if [[ "$current_size" =~ ^[0-9]+$ && "$current_size" -ge "$target_size_gb" ]]; then
        log_info "启动盘当前 ${current_size}GB，已不小于目标 ${target_size_gb}GB"
        return 0
    fi

    log_info "正在将启动盘扩容到 ${target_size_gb}GB..."
    if oci bv boot-volume update \
        --boot-volume-id "$boot_volume_id" \
        --size-in-gbs "$target_size_gb" \
        --force \
        --output json >/dev/null 2>&1; then
        log_success "启动盘扩容命令已执行: ${target_size_gb}GB"
        return 0
    fi

    log_warn "启动盘扩容失败，实例 OCPU/内存更新不受影响"
    return 1
}

beginner_update_instance() {
    local instance_count="$1"
    local choice target_ocpus target_memory target_boot_volume request_interval selected_ocid

    load_beginner_defaults

    printf '%s\n' ""
    printf '%b\n' "${BOLD}一键修改实例配置${NC}"
    printf '%s\n' "----------------------------------------"
    printf '%s\n' "默认配置:"
    printf '%s\n' "  OCPU:       ${BEGINNER_UPDATE_OCPUS_DEFAULT}"
    printf '%s\n' "  内存:       ${BEGINNER_UPDATE_MEMORY_GB_DEFAULT} GB"
    printf '%s\n' "  启动盘:     ${BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT} GB"
    printf '%s\n' "  执行方式:   直接更新 OCPU/内存，并尝试在线扩容启动盘"
    printf '%s\n' ""

    read_instance_list_choice choice "$instance_count"
    if ! is_valid_list_choice "$choice" "$instance_count"; then
        log_invalid_list_choice "$choice" "$instance_count"
        return 1
    fi

    selected_ocid="${INSTANCE_OCIDS[$choice]}"
    read -p "目标 OCPU [默认: ${BEGINNER_UPDATE_OCPUS_DEFAULT}]: " target_ocpus
    target_ocpus="${target_ocpus:-$BEGINNER_UPDATE_OCPUS_DEFAULT}"
    read -p "目标内存 GB [默认: ${BEGINNER_UPDATE_MEMORY_GB_DEFAULT}]: " target_memory
    target_memory="${target_memory:-$BEGINNER_UPDATE_MEMORY_GB_DEFAULT}"
    read -p "目标启动盘 GB [默认: ${BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT}]: " target_boot_volume
    target_boot_volume="${target_boot_volume:-$BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT}"

    read -p "后台请求间隔秒 [默认: ${OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}]: " request_interval
    request_interval="${request_interval:-$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}"

    if [[ ! "$target_ocpus" =~ ^[0-9]+([.][0-9]+)?$ || ! "$target_memory" =~ ^[0-9]+([.][0-9]+)?$ || ! "$target_boot_volume" =~ ^[0-9]+$ || ! "$request_interval" =~ ^[0-9]+$ || "$request_interval" -le 0 ]]; then
        log_error "目标 OCPU、内存、启动盘大小或请求间隔格式无效"
        return 1
    fi

    printf '%s\n' ""
    printf '%s\n' "即将执行:"
    printf '%s\n' "  实例:       ${selected_ocid:0:50}..."
    printf '%s\n' "  OCPU:       $target_ocpus"
    printf '%s\n' "  内存:       ${target_memory} GB"
    printf '%s\n' "  启动盘:     ${target_boot_volume} GB"
    printf '%s\n' ""
    read -p "确认一键修改? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    local update_result exit_code
    log_info "正在更新 OCPU/内存..."
    update_result=$(oci compute instance update \
        --instance-id "$selected_ocid" \
        --shape-config "{\"ocpus\": $target_ocpus, \"memory-in-gbs\": $target_memory}" \
        --force \
        --connection-timeout "$OCI_UPDATE_CONNECTION_TIMEOUT" \
        --read-timeout "$OCI_UPDATE_READ_TIMEOUT" \
        --max-retries "$OCI_UPDATE_MAX_RETRIES" \
        --output json 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_success "OCPU/内存更新命令执行成功"
    else
        log_error "OCPU/内存更新失败，将创建后台任务自动重试"
        printf '%s\n' "$update_result"
        create_background_task "direct_update_instance" "$selected_ocid" "$target_ocpus" "$target_memory" "0" "$request_interval" "true"
    fi

    resize_instance_boot_volume "$selected_ocid" "$target_boot_volume" || true
    printf '%s\n' ""
    log_success "一键修改实例配置流程已完成"
    pause
}

# ================================
# 生成更新配置模板
# ================================
generate_update_template() {
    local instance_ocid="$1"
    local output_file="${2:-update_instance_config.json}"

    show_header
    printf '%b\n' "${BOLD}生成更新配置模板${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    # 如果没有传入实例 OCID，需要交互输入
    if [[ -z "$instance_ocid" ]]; then
        read -p "请输入实例 OCID: " instance_ocid
        while [[ -z "$instance_ocid" || ! "$instance_ocid" =~ ^ocid1\.instance\.oc1\. ]]; do
            printf '%b\n' "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
            read -p "请输入实例 OCID: " instance_ocid
        done
    fi

    printf '%s\n' ""
    printf '%s\n' "模板类型:"
    printf '%s\n' "  1) 精简模板            (仅包含更新必需字段)"
    printf '%s\n' "  2) 完整模板            (包含所有可用字段)"
    printf '%s\n' ""
    read -p "请选择模板类型 [默认: 1]: " template_type
    template_type="${template_type:-1}"

    log_info "正在生成配置模板..."

    if [[ "$template_type" == "1" ]]; then
        # 生成精简模板 - 只包含更新所需的字段
        # 首先获取当前实例信息
        local current_info
        current_info=$(oci compute instance get \
            --instance-id "$instance_ocid" \
            --output json 2>/dev/null)

        if [[ -n "$current_info" ]]; then
            local current_ocpus current_memory current_shape
            current_ocpus=$(printf '%s\n' "$current_info" | jq -r '.data["shape-config"].ocpus // 1')
            current_memory=$(printf '%s\n' "$current_info" | jq -r '.data["shape-config"]["memory-in-gbs"] // 6')
            current_shape=$(printf '%s\n' "$current_info" | jq -r '.data.shape // "VM.Standard.A1.Flex"')

            # 询问目标配置
            printf '%s\n' ""
            printf '%s\n' "当前配置: $current_ocpus OCPU, ${current_memory} GB 内存"
            printf '%s\n' ""
            read -p "目标 OCPU 数量 [默认: $current_ocpus]: " target_ocpus
            target_ocpus="${target_ocpus:-$current_ocpus}"
            read -p "目标内存 (GB) [默认: $current_memory]: " target_memory
            target_memory="${target_memory:-$current_memory}"

            # 生成精简模板
            cat > "$output_file" << EOF
{
  "instanceId": "$instance_ocid",
  "shapeConfig": {
    "ocpus": $target_ocpus,
    "memoryInGBs": $target_memory
  }
}
EOF
            log_success "精简配置模板已生成: $output_file"
        else
            log_error "获取实例信息失败，无法生成精简模板"
            return 1
        fi
    else
        # 生成完整模板 - 使用 OCI CLI 生成
        if oci compute instance update \
            --instance-id "$instance_ocid" \
            --generate-full-command-json-input > "$output_file" 2>/dev/null; then

            log_success "完整配置模板已生成: $output_file"
            printf '%s\n' ""
            printf '%b\n' "${CYAN}提示: 此模板包含所有可用参数。您需要修改以下内容:${NC}"
            printf '%s\n' "  1. 将 'string' 占位符改为实际值或删除该字段"
            printf '%s\n' "  2. 将 'ALLOW_DOWNTIME|AVOID_DOWNTIME' 改为 ALLOW_DOWNTIME 或 AVOID_DOWNTIME"
            printf '%s\n' "  3. 删除不需要的字段"
        else
            log_error "生成配置模板失败"
            return 1
        fi
    fi

    printf '%s\n' ""
    printf '%b\n' "${BOLD}模板内容:${NC}"
    printf '%s\n' "----------------------------------------"
    jq '.' "$output_file" 2>/dev/null | head -30
    printf '%s\n' "----------------------------------------"
    printf '%s\n' ""

    read -p "是否立即编辑此文件? [Y/n]: " edit_now
    [[ -z "$edit_now" ]] && edit_now="y"

    if [[ $edit_now =~ ^[Yy]$ ]]; then
        # 检查可用的编辑器
        if [[ -n "$EDITOR" ]]; then
            $EDITOR "$output_file"
        elif command -v nano &>/dev/null; then
            nano "$output_file"
        elif command -v vim &>/dev/null; then
            vim "$output_file"
        else
            log_warn "未找到编辑器，请手动编辑: $output_file"
        fi
    fi

    return 0
}

# ================================
# 使用配置文件更新实例
# 参数: $1 = 模式 (direct 或 full)
# ================================
update_instance_from_file() {
    local mode="${1:-direct}"  # direct 或 full
    local config_file=""

    printf '%s\n' ""
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%b\n' "${BOLD}使用配置文件更新${NC}"
    printf '%b\n' "${BOLD}========================================${NC}"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    # 列出当前目录下的 JSON 配置文件
    printf '%b\n' "${CYAN}当前目录下的配置文件:${NC}"
    local json_files=()
    while IFS= read -r -d '' file; do
        json_files+=("$file")
    done < <(find . -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null | sort -z)

    if [[ ${#json_files[@]} -eq 0 ]]; then
        log_warn "未找到配置文件 (*.json)"
        printf '%s\n' ""
        printf '%s\n' "选项:"
        printf '%s\n' "  1) 生成新的配置模板"
        printf '%s\n' "  2) 手动输入配置文件路径"
        printf '%s\n' "  0) 返回"
        printf '%s\n' ""
        read -p "请选择: " choice

        case $choice in
            1)
                local instance_ocid output_file
                read -p "实例 OCID: " instance_ocid
                read -p "输出文件名 [update_instance_config.json]: " output_file
                output_file="${output_file:-update_instance_config.json}"
                generate_update_template "$instance_ocid" "$output_file"
                return $?
                ;;
            2)
                read -p "配置文件路径: " config_file
                ;;
            0)
                return 0
                ;;
            *)
                log_error "无效选择"
                return 1
                ;;
        esac
    else
        printf '%s\n' ""
        for i in "${!json_files[@]}"; do
            printf '%s\n' "  $((i+1))) ${json_files[$i]#./}"
        done
        printf '%s\n' "  0) 返回"
        printf '%s\n' ""
        read -p "请输入上方配置文件列表左侧的序号 [1-${#json_files[@]}]，或输入 0 返回: " file_choice
        file_choice="${file_choice//$'\r'/}"
        file_choice="${file_choice//[[:space:]]/}"

        if [[ "$file_choice" == "0" ]]; then
            return 0
        elif is_valid_list_choice "$file_choice" "${#json_files[@]}"; then
            config_file="${json_files[$((file_choice-1))]}"
        else
            log_error "无效选择"
            return 1
        fi
    fi

    # 检查配置文件是否存在
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi

    # 验证 JSON 格式
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "配置文件 JSON 格式无效"
        return 1
    fi

    # 检查配置文件中是否有占位符值
    local has_placeholders=false
    if grep -q "string\|ALLOW_DOWNTIME|AVOID_DOWNTIME\|ocid1\.\.\." "$config_file" 2>/dev/null; then
        # 检查关键字段是否有占位符
        local instance_id_check
        instance_id_check=$(jq -r '.instanceId // ""' "$config_file" 2>/dev/null)
        if [[ "$instance_id_check" == "string" || "$instance_id_check" == *"ocid1..."* ]]; then
            has_placeholders=true
        fi

        # 检查 update-operation-constraint 字段
        local constraint_check
        constraint_check=$(jq -r '.["update-operation-constraint"] // ""' "$config_file" 2>/dev/null)
        if [[ "$constraint_check" == *"ALLOW_DOWNTIME|AVOID_DOWNTIME"* || "$constraint_check" == "string" ]]; then
            has_placeholders=true
        fi
    fi

    if [[ "$has_placeholders" == true ]]; then
        log_warn "配置文件包含占位符值，需要先修改"
        printf '%s\n' ""
        printf '%b\n' "${YELLOW}检测到以下问题:${NC}"
        printf '%s\n' "  - instanceId 可能是占位符"
        printf '%s\n' "  - update-operation-constraint 可能是占位符"
        printf '%s\n' ""
        printf '%s\n' "请先编辑配置文件，修改以下内容:"
        printf '%s\n' "  1. 将 instanceId 改为实际的实例 OCID"
        printf '%s\n' "  2. 将 update-operation-constraint 改为 ALLOW_DOWNTIME 或 AVOID_DOWNTIME"
        printf '%s\n' "  3. 将其他 'string' 值改为实际值或删除该字段"
        printf '%s\n' ""
        read -p "是否立即编辑配置文件? [Y/n]: " -r
        [[ -z "$REPLY" ]] && REPLY="y"

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [[ -n "$EDITOR" ]]; then
                $EDITOR "$config_file"
            elif command -v nano &>/dev/null; then
                nano "$config_file"
            elif command -v vim &>/dev/null; then
                vim "$config_file"
            else
                log_error "未找到可用的编辑器"
                return 1
            fi

            # 重新检查
            if grep -q '"instanceId": "string"' "$config_file" 2>/dev/null; then
                log_error "配置文件仍包含占位符，请修改后再执行"
                return 1
            fi
        else
            return 1
        fi
    fi

    # 显示配置文件内容
    printf '%s\n' ""
    printf '%b\n' "${BOLD}配置文件内容:${NC}"
    printf '%s\n' "----------------------------------------"
    jq '.' "$config_file" 2>/dev/null | head -30
    printf '%s\n' "----------------------------------------"
    printf '%s\n' ""

    # 提取关键信息显示
    local instance_id ocpus memory
    instance_id=$(jq -r '.instanceId // "N/A"' "$config_file" 2>/dev/null)
    ocpus=$(jq -r '.shapeConfig.ocpus // "N/A"' "$config_file" 2>/dev/null)
    memory=$(jq -r '.shapeConfig.memoryInGBs // "N/A"' "$config_file" 2>/dev/null)

    # 显示更新模式和配置
    local mode_desc="直接更新"
    [[ "$mode" == "full" ]] && mode_desc="完整更新流程 (停止→更新→启动)"

    printf '%b\n' "${BOLD}更新配置:${NC}"
    printf '%s\n' "  模式: $mode_desc"
    printf '%s\n' "  实例: ${instance_id:0:50}..."
    printf '%s\n' "  目标 OCPU: $ocpus"
    printf '%s\n' "  目标内存: ${memory} GB"
    printf '%s\n' ""

    # 确认执行
    printf '%b\n' "${YELLOW}警告: 更新操作将替换实例的配置${NC}"
    read -p "确认执行更新? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        printf '%s\n' "操作已取消"
        return 0
    fi

    # 检查是否已有该实例的运行中任务
    if check_existing_task_for_instance "$instance_id"; then
        return 1
    fi

    # 设置全局变量供后续使用
    INSTANCE_OCID="$instance_id"
    local target_ocpus="${ocpus:-4}"
    local target_memory="${memory:-24}"

    # 根据模式执行
    if [[ "$mode" == "full" ]]; then
        # 完整更新流程：停止→更新→启动
        log_info "执行完整更新流程..."

        # 1. 停止实例
        log_info "步骤 1/3: 停止实例..."
        if ! stop_instance; then
            log_warn "停止实例失败或实例已停止，继续执行更新..."
        fi

        # 2. 执行更新
        log_info "步骤 2/3: 执行配置更新..."
        local update_result
        update_result=$(yes | oci compute instance update \
            --from-json "file://$config_file" \
            --connection-timeout "$OCI_UPDATE_CONNECTION_TIMEOUT" \
            --read-timeout "$OCI_UPDATE_READ_TIMEOUT" \
            --max-retries "$OCI_UPDATE_MAX_RETRIES" \
            --output json 2>&1)

        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "配置更新成功"

            # 3. 启动实例
            log_info "步骤 3/3: 启动实例..."
            if start_instance; then
                log_success "完整更新流程执行成功！"
                # 发送通知
                send_notification "OCI 实例配置文件更新成功" "实例 ${instance_id} 配置文件更新成功\n配置文件: $config_file\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            else
                log_warn "启动实例失败，请手动启动"
            fi
        else
            log_error "配置更新失败"
            printf '%s\n' ""
            printf '%s\n' "错误输出:"
            printf '%s\n' "$update_result"

            # 询问是否创建后台重试任务
            printf '%s\n' ""
            read -p "是否创建后台任务自动重试完整流程? [Y/n]: " -r
            [[ -z "$REPLY" ]] && REPLY="y"

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local retry_interval
                read -p "重试间隔 (秒) [默认: 10]: " retry_interval
                retry_interval="${retry_interval:-10}"

                # 创建后台任务（跳过检测，因为前面已经检测过了）
                create_background_task "full_update_instance" "$instance_id" "$target_ocpus" "$target_memory" "$retry_interval" "" "true"
            fi
        fi
    else
        # 直接更新模式
        log_info "执行直接更新..."

        local update_result
        update_result=$(yes | oci compute instance update \
            --from-json "file://$config_file" \
            --connection-timeout "$OCI_UPDATE_CONNECTION_TIMEOUT" \
            --read-timeout "$OCI_UPDATE_READ_TIMEOUT" \
            --max-retries "$OCI_UPDATE_MAX_RETRIES" \
            --output json 2>&1)

        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "更新命令执行成功"
            printf '%s\n' ""
            printf '%s\n' "更新结果:"
            printf '%s\n' "$update_result" | jq '.' 2>/dev/null || printf '%s\n' "$update_result"

            # 询问是否创建后台监控任务
            printf '%s\n' ""
            read -p "是否创建后台任务持续监控并重试? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local request_interval
                read -p "请求间隔 (秒) [默认: ${OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}]: " request_interval
                request_interval="${request_interval:-$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}"
                if [[ ! "$request_interval" =~ ^[0-9]+$ || "$request_interval" -le 0 ]]; then
                    log_error "请求间隔必须为正整数"
                    return 1
                fi

                # 创建后台任务（跳过检测，因为前面已经检测过了）
                create_background_task "direct_update_instance" "$instance_id" "$target_ocpus" "$target_memory" "0" "$request_interval" "true"
            fi
        else
            log_error "更新命令执行失败"
            printf '%s\n' ""
            printf '%s\n' "错误输出:"
            printf '%s\n' "$update_result"

            # 询问是否创建后台重试任务
            printf '%s\n' ""
            read -p "是否创建后台任务自动重试? [Y/n]: " -r
            [[ -z "$REPLY" ]] && REPLY="y"

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local request_interval
                read -p "请求间隔 (秒) [默认: ${OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}]: " request_interval
                request_interval="${request_interval:-$OCI_UPDATE_REQUEST_INTERVAL_DEFAULT}"
                if [[ ! "$request_interval" =~ ^[0-9]+$ || "$request_interval" -le 0 ]]; then
                    log_error "请求间隔必须为正整数"
                    return 1
                fi

                # 创建后台任务（跳过检测，因为前面已经检测过了）
                create_background_task "direct_update_instance" "$instance_id" "$target_ocpus" "$target_memory" "0" "$request_interval" "true"
            fi
        fi
    fi

    return 0
}

# ================================
# 完整更新流程（交互式）
# ================================
update_instance_config_full() {
    show_header
    printf '%b\n' "${BOLD}[8] 完整更新流程 (停止→更新→启动)${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入参数
    printf '%b\n' "${YELLOW}请输入更新参数:${NC}"
    printf '%s\n' ""

    # 实例 ID（如果已经设置则跳过）
    if [[ -z "$INSTANCE_OCID" ]]; then
        read -p "实例 OCID: " INSTANCE_OCID
        while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
            printf '%b\n' "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
            read -p "实例 OCID: " INSTANCE_OCID
        done
    else
        printf '%b\n' "${GREEN}✓${NC} 实例 OCID: ${INSTANCE_OCID:0:30}..."
    fi

    # 目标 OCPU
    read -p "目标 OCPU 数量 [默认: 4]: " TARGET_OCPUS
    TARGET_OCPUS="${TARGET_OCPUS:-4}"

    # 目标内存
    read -p "目标内存 (GB) [默认: 24]: " TARGET_MEMORY
    TARGET_MEMORY="${TARGET_MEMORY:-24}"

    # 重试间隔
    read -p "重试间隔 (秒) [默认: 10]: " RETRY_INTERVAL
    RETRY_INTERVAL="${RETRY_INTERVAL:-10}"

    # 获取当前实例信息
    log_info "获取实例当前配置..."
    local current_info
    current_info=$(oci compute instance get \
        --instance-id "$INSTANCE_OCID" \
        --output json 2>/dev/null)

    if [[ -n "$current_info" ]]; then
        local name state current_ocpus current_memory shape
        name=$(printf '%s\n' "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(printf '%s\n' "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        current_ocpus=$(printf '%s\n' "$current_info" | jq -r '.data["shape-config"].ocpus // "N/A"')
        current_memory=$(printf '%s\n' "$current_info" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
        shape=$(printf '%s\n' "$current_info" | jq -r '.data.shape // "N/A"')

        printf '%s\n' ""
        printf '%s\n' "当前实例信息:"
        printf '%s\n' "  名称: $name"
        printf '%s\n' "  状态: $state"
        printf '%s\n' "  形状: $shape"
        printf '%s\n' "  当前 OCPU: $current_ocpus"
        printf '%s\n' "  当前内存: ${current_memory} GB"
        printf '%s\n' ""
        printf '%s\n' "目标配置:"
        printf '%s\n' "  目标 OCPU: $TARGET_OCPUS"
        printf '%s\n' "  目标内存: ${TARGET_MEMORY} GB"
        printf '%s\n' "  重试间隔: ${RETRY_INTERVAL} 秒"
    fi

    printf '%s\n' ""
    read -p "确认执行完整更新流程? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    printf '
'
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        printf '%s\n' "操作已取消"
        pause
        return 0
    fi

    # 创建后台任务
    create_background_task "full_update_instance" "$INSTANCE_OCID" "$TARGET_OCPUS" "$TARGET_MEMORY" "$RETRY_INTERVAL"
}

# ================================
# 创建实例相关辅助函数
# ================================
get_tenancy_id_from_config() {
    grep "^tenancy=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | head -1
}

expand_path() {
    local path="$1"
    printf '%s\n' "${path/#\~/$HOME}"
}

SELECT_RESULT=""
SELECT_DEFAULT_OPTION_VALUE=""

select_option_pairs() {
    local title="$1"
    shift
    local options=("$@")
    SELECT_RESULT=""

    if [[ ${#options[@]} -eq 0 ]]; then
        SELECT_DEFAULT_OPTION_VALUE=""
        return 1
    fi

    printf '%s\n' ""
    printf '%b\n' "${CYAN}${title}${NC}"
    local i
    for ((i=0; i<${#options[@]}; i++)); do
        local label="${options[$i]%%|*}"
        printf '%s\n' "  $((i+1))) $label"
    done
    printf '%s\n' "  0) 手动输入"
    printf '%s\n' ""

    local choice
    local default_index=1
    local default_label="${options[0]%%|*}"
    local default_value="$SELECT_DEFAULT_OPTION_VALUE"
    local i

    if [[ -n "$default_value" ]]; then
        for ((i=0; i<${#options[@]}; i++)); do
            local option_value="${options[$i]#*|}"
            if [[ "$option_value" == "$default_value" ]]; then
                default_index=$((i+1))
                default_label="${options[$i]%%|*}"
                break
            fi
        done
    fi

    read -p "请选择 [默认: ${default_index} ${default_label}; 0 手动输入]: " choice
    choice="${choice:-$default_index}"
    SELECT_DEFAULT_OPTION_VALUE=""

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#options[@]} ]]; then
        SELECT_RESULT="${options[$((choice-1))]#*|}"
        return 0
    fi

    return 1
}

read_choice_with_default_label() {
    local result_var="$1"
    local prompt="$2"
    local default_value="$3"
    local default_label="$4"
    local input_value

    read -p "${prompt} [默认: ${default_value} ${default_label}]: " input_value
    printf -v "$result_var" '%s' "${input_value:-$default_value}"
}

read_instance_list_choice() {
    local result_var="$1"
    local instance_count="$2"
    local allow_manual="${3:-false}"
    local input_value

    if [[ "$allow_manual" == "true" ]]; then
        read -r -p "请输入上方实例列表左侧的序号 [1-${instance_count}]，或按回车手动输入 OCID: " input_value
    else
        read -r -p "请输入上方实例列表左侧的序号 [1-${instance_count}]: " input_value
    fi

    input_value="${input_value//$'\r'/}"
    input_value="${input_value//[[:space:]]/}"
    input_value="${input_value#\#}"
    printf -v "$result_var" '%s' "$input_value"
}

read_task_list_choice() {
    local result_var="$1"
    local task_count="$2"
    local input_value

    read -r -p "请输入上方任务列表左侧的序号 [1-${task_count}]: " input_value
    input_value="${input_value//$'\r'/}"
    input_value="${input_value//[[:space:]]/}"
    input_value="${input_value#\#}"
    printf -v "$result_var" '%s' "$input_value"
}

pause_no_background_tasks() {
    log_warn "当前没有后台任务，无法执行该操作"
    printf '%s\n' "提示: 创建实例或更新实例时选择后台重试后，任务会显示在这里。"
    read -r -p "按回车键返回任务菜单..."
}

is_valid_list_choice() {
    local choice="$1"
    local max_count="$2"

    choice="${choice//$'\r'/}"
    choice="${choice//[[:space:]]/}"
    choice="${choice#\#}"
    max_count="${max_count//$'\r'/}"
    max_count="${max_count//[[:space:]]/}"

    [[ "$choice" =~ ^[0-9]+$ && "$max_count" =~ ^[0-9]+$ ]] || return 1
    (( choice >= 1 && choice <= max_count ))
}

log_invalid_list_choice() {
    local choice="$1"
    local max_count="$2"

    log_error "无效选择: '${choice}'，请输入 1-${max_count} 之间的数字"
}

query_availability_domains() {
    local default_value="$1"
    local options=()
    while IFS= read -r ad_name; do
        [[ -n "$ad_name" ]] && options+=("${ad_name}|${ad_name}")
    done < <(oci iam availability-domain list --all --output json 2>/dev/null | jq -r '.data[].name // empty')

    SELECT_DEFAULT_OPTION_VALUE="$default_value"
    select_option_pairs "可用性域列表" "${options[@]}"
}

query_shapes() {
    local compartment_id="$1"
    local availability_domain="$2"
    local default_value="$3"
    local options=()

    while IFS= read -r shape_name; do
        [[ -n "$shape_name" ]] && options+=("${shape_name}|${shape_name}")
    done < <(oci compute shape list \
        --compartment-id "$compartment_id" \
        --availability-domain "$availability_domain" \
        --all \
        --output json 2>/dev/null | jq -r '.data[].shape // empty' | sort -u)

    SELECT_DEFAULT_OPTION_VALUE="$default_value"
    select_option_pairs "实例规格列表" "${options[@]}"
}

query_vcns() {
    local compartment_id="$1"
    local options=()

    while IFS=$'\t' read -r display_name vcn_id cidr_block; do
        [[ -z "$vcn_id" ]] && continue
        options+=("${display_name} (${cidr_block})|${vcn_id}")
    done < <(oci network vcn list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null | jq -r '.data[] | [.["display-name"], .id, .["cidr-block"]] | @tsv')

    select_option_pairs "VCN 列表" "${options[@]}"
}

query_image_operating_systems() {
    local compartment_id="$1"
    local default_value="$2"
    local options=()

    while IFS= read -r os_name; do
        [[ -n "$os_name" ]] && options+=("${os_name}|${os_name}")
    done < <(oci compute image list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null | jq -r '.data[]."operating-system" // empty' | sort -u)

    SELECT_DEFAULT_OPTION_VALUE="$default_value"
    select_option_pairs "操作系统列表" "${options[@]}"
}

query_image_operating_system_versions() {
    local compartment_id="$1"
    local operating_system="$2"
    local default_value="$3"
    local options=()

    while IFS= read -r os_version; do
        [[ -n "$os_version" ]] && options+=("${os_version}|${os_version}")
    done < <(oci compute image list \
        --compartment-id "$compartment_id" \
        --operating-system "$operating_system" \
        --all \
        --output json 2>/dev/null | jq -r '.data[]."operating-system-version" // empty' | sort -u)

    SELECT_DEFAULT_OPTION_VALUE="$default_value"
    select_option_pairs "操作系统版本列表 (${operating_system})" "${options[@]}"
}

LAST_CREATED_VCN_ID=""
LAST_CREATED_VCN_CIDR=""
LAST_CREATED_VCN_DEFAULT_ROUTE_TABLE_ID=""
LAST_CREATED_VCN_PUBLIC_READY="false"

generate_default_network_name() {
    local prefix="$1"
    printf '%s\n' "${prefix}-$(date +%m%d%H%M)"
}

generate_default_dns_label() {
    local prefix="$1"
    local cleaned
    cleaned=$(printf '%s\n' "$prefix" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    [[ -z "$cleaned" ]] && cleaned="net"
    cleaned="${cleaned:0:6}"
    printf '%s\n' "${cleaned}$(date +%m%d%H)"
}

get_vcn_cidr() {
    local vcn_id="$1"
    oci network vcn get \
        --vcn-id "$vcn_id" \
        --query 'data."cidr-block"' \
        --raw-output 2>/dev/null
}

get_vcn_default_route_table_id() {
    local vcn_id="$1"
    oci network vcn get \
        --vcn-id "$vcn_id" \
        --query 'data."default-route-table-id"' \
        --raw-output 2>/dev/null
}

derive_default_subnet_cidr() {
    local vcn_cidr="$1"

    if [[ "$vcn_cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}/ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.1.0/24"
    else
        printf '%s\n' "10.0.0.0/24"
    fi
}

ensure_public_route_for_vcn() {
    local compartment_id="$1"
    local vcn_id="$2"
    local igw_name="$3"

    local igw_id route_table_id route_rules_json current_rules
    igw_id=$(oci network internet-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --all \
        --output json 2>/dev/null | jq -r '.data[] | select(."lifecycle-state" == "AVAILABLE") | .id' | head -1)

    if [[ -z "$igw_id" || "$igw_id" == "null" ]]; then
        log_info "正在创建 Internet Gateway..."
        igw_id=$(oci network internet-gateway create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --is-enabled true \
            --display-name "$igw_name" \
            --wait-for-state AVAILABLE \
            --query 'data.id' \
            --raw-output 2>&1)

        if [[ $? -ne 0 ]]; then
            log_error "Internet Gateway 创建失败: $igw_id"
            return 1
        fi
        igw_id="$(printf '%s\n' "$igw_id" | tail -n 1 | tr -d '\r')"
    else
        log_info "复用现有 Internet Gateway: $igw_id"
    fi

    route_table_id=$(get_vcn_default_route_table_id "$vcn_id")
    if [[ -z "$route_table_id" || "$route_table_id" == "null" ]]; then
        log_error "无法获取 VCN 默认路由表"
        return 1
    fi

    current_rules=$(oci network route-table get \
        --rt-id "$route_table_id" \
        --query 'data."route-rules"' \
        --output json 2>/dev/null)
    [[ -z "$current_rules" || "$current_rules" == "null" ]] && current_rules="[]"

    if printf '%s\n' "$current_rules" | jq -e --arg igw_id "$igw_id" '.[] | select(.cidrBlock == "0.0.0.0/0" and .networkEntityId == $igw_id)' >/dev/null 2>&1; then
        log_info "默认路由表已存在公网路由"
        LAST_CREATED_VCN_DEFAULT_ROUTE_TABLE_ID="$route_table_id"
        LAST_CREATED_VCN_PUBLIC_READY="true"
        return 0
    fi

    route_rules_json=$(printf '%s\n' "$current_rules" | jq -c --arg igw_id "$igw_id" '. + [{"cidrBlock":"0.0.0.0/0","networkEntityId":$igw_id}]')

    log_info "正在为默认路由表添加公网路由..."
    local update_result
    update_result=$(oci network route-table update \
        --rt-id "$route_table_id" \
        --route-rules "$route_rules_json" \
        --force \
        --query 'data.id' \
        --raw-output 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "更新默认路由表失败: $update_result"
        return 1
    fi

    LAST_CREATED_VCN_DEFAULT_ROUTE_TABLE_ID="$route_table_id"
    LAST_CREATED_VCN_PUBLIC_READY="true"
    log_success "默认公网路由已配置完成"
    return 0
}

create_vcn_interactive() {
    local compartment_id="$1"

    printf '%s\n' ""
    printf '%b\n' "${BOLD}----------------------------------------${NC}"
    printf '%b\n' "${BOLD}新建 VCN${NC}"
    printf '%b\n' "${BOLD}----------------------------------------${NC}"
    printf '%s\n' ""

    local vcn_name vcn_cidr dns_label create_result vcn_id
    local setup_mode input_value auto_public_network default_vcn_name default_vcn_cidr default_dns_label igw_name

    default_vcn_name="$(generate_default_network_name "auto-vcn")"
    default_vcn_cidr="10.0.0.0/16"
    default_dns_label="$(generate_default_dns_label "vcn")"

    printf '%s\n' "创建模式:"
    printf '%s\n' "  1) 快速创建公网 VCN（推荐，自动创建 Internet Gateway 和默认公网路由）"
    printf '%s\n' "  2) 仅创建基础 VCN"
    printf '%s\n' "  3) 自定义"
    read_choice_with_default_label setup_mode "请选择" "1" "快速创建公网 VCN"
    auto_public_network="true"
    [[ "$setup_mode" == "2" ]] && auto_public_network="false"

    if [[ "$setup_mode" == "3" ]]; then
        read -p "创建后是否自动配置公网访问（Internet Gateway + 默认路由）? [Y/n]: " -r
        [[ -z "$REPLY" ]] && REPLY="y"
        [[ ! $REPLY =~ ^[Yy]$ ]] && auto_public_network="false"
    fi

    read -p "VCN 名称 [默认: ${default_vcn_name}]: " vcn_name
    vcn_name="${vcn_name:-$default_vcn_name}"
    while [[ -z "$vcn_name" ]]; do
        printf '%b\n' "${RED}VCN 名称不能为空${NC}"
        read -p "VCN 名称: " vcn_name
    done

    read -p "VCN CIDR [默认: ${default_vcn_cidr}]: " vcn_cidr
    vcn_cidr="${vcn_cidr:-$default_vcn_cidr}"
    while ! is_valid_cidr_block "$vcn_cidr"; do
        printf '%b\n' "${RED}VCN CIDR 格式无效${NC}"
        read -p "VCN CIDR: " vcn_cidr
    done

    read -p "VCN DNS Label [默认: ${default_dns_label}]: " dns_label
    dns_label="${dns_label:-$default_dns_label}"
    while ! is_valid_dns_label "$dns_label"; do
        printf '%b\n' "${RED}VCN DNS Label 无效，请使用 1-15 位小写字母数字，且必须以字母开头${NC}"
        read -p "VCN DNS Label: " dns_label
    done

    igw_name="${vcn_name}-igw"

    printf '%s\n' ""
    printf '%b\n' "${CYAN}VCN 创建摘要:${NC}"
    printf '%s\n' "  VCN 名称:     $vcn_name"
    printf '%s\n' "  VCN CIDR:     $vcn_cidr"
    printf '%s\n' "  DNS Label:    $dns_label"
    printf '%s\n' "  公网访问:     $([[ "$auto_public_network" == "true" ]] && printf '%s\n' "自动配置" || printf '%s\n' "不自动配置")"
    printf '%s\n' ""

    read -p "确认创建 VCN? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "已取消创建 VCN"
        return 1
    fi

    log_info "正在创建 VCN..."
    create_result=$(oci network vcn create \
        --compartment-id "$compartment_id" \
        --display-name "$vcn_name" \
        --cidr-blocks "[\"$vcn_cidr\"]" \
        --dns-label "$dns_label" \
        --wait-for-state AVAILABLE \
        --query "data.id" \
        --raw-output 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "VCN 创建失败: $create_result"
        return 1
    fi

    vcn_id="$(printf '%s\n' "$create_result" | tail -n 1 | tr -d '\r')"
    if [[ -z "$vcn_id" || "$vcn_id" == "null" || ! "$vcn_id" =~ ^ocid1\.vcn\.oc1\. ]]; then
        log_error "未能从创建结果中解析 VCN OCID"
        printf '%s\n' "$create_result"
        return 1
    fi

    log_success "VCN 创建成功: $vcn_id"
    LAST_CREATED_VCN_ID="$vcn_id"
    LAST_CREATED_VCN_CIDR="$vcn_cidr"
    LAST_CREATED_VCN_DEFAULT_ROUTE_TABLE_ID=""
    LAST_CREATED_VCN_PUBLIC_READY="false"

    if [[ "$auto_public_network" == "true" ]]; then
        if ! ensure_public_route_for_vcn "$compartment_id" "$vcn_id" "$igw_name"; then
            log_warn "VCN 已创建，但公网访问配置未完全自动完成，可稍后手动配置"
        fi
    fi

    SELECT_RESULT="$vcn_id"
    return 0
}

query_images() {
    local compartment_id="$1"
    local operating_system="$2"
    local operating_system_version="$3"
    local shape="$4"
    local default_value="$5"
    local options=()
    local filtered_options=()
    local cmd=(
        oci compute image list
        --compartment-id "$compartment_id"
        --operating-system "$operating_system"
        --sort-by TIMECREATED
        --sort-order DESC
        --all
        --output json
    )

    if [[ -n "$operating_system_version" ]]; then
        cmd+=(--operating-system-version "$operating_system_version")
    fi
    while IFS=$'\t' read -r display_name image_id os_version; do
        [[ -z "$image_id" ]] && continue
        options+=("${display_name} (版本: ${os_version:-N/A})|${image_id}")
    done < <("${cmd[@]}" 2>/dev/null | jq -r '.data[] | [.["display-name"], .id, (.["operating-system-version"] // "N/A")] | @tsv' | head -20)

    if [[ -n "$shape" ]]; then
        local filtered_cmd=("${cmd[@]}" --shape "$shape")
        while IFS=$'\t' read -r display_name image_id os_version; do
            [[ -z "$image_id" ]] && continue
            filtered_options+=("${display_name} (版本: ${os_version:-N/A})|${image_id}")
        done < <("${filtered_cmd[@]}" 2>/dev/null | jq -r '.data[] | [.["display-name"], .id, (.["operating-system-version"] // "N/A")] | @tsv' | head -20)
    fi

    local title="镜像列表 (${operating_system}"
    if [[ -n "$operating_system_version" ]]; then
        title="${title} ${operating_system_version}"
    fi
    title="${title})"

    if [[ ${#filtered_options[@]} -gt 0 ]]; then
        SELECT_DEFAULT_OPTION_VALUE="$default_value"
        select_option_pairs "${title} - 已按实例规格过滤" "${filtered_options[@]}"
    else
        [[ -n "$shape" ]] && log_warn "按当前实例规格未筛到镜像，已回退显示该系统/版本的完整镜像列表"
        SELECT_DEFAULT_OPTION_VALUE="$default_value"
        select_option_pairs "$title" "${options[@]}"
    fi
}

query_subnets() {
    local compartment_id="$1"
    local vcn_id="$2"
    local default_value="$3"
    local options=()
    local cmd=(oci network subnet list --compartment-id "$compartment_id" --all --output json)

    if [[ -n "$vcn_id" ]]; then
        cmd+=(--vcn-id "$vcn_id")
    fi

    while IFS=$'\t' read -r display_name subnet_id cidr_block private_only; do
        [[ -z "$subnet_id" ]] && continue
        local subnet_type="公网"
        [[ "$private_only" == "true" ]] && subnet_type="私网"
        options+=("${display_name} (${cidr_block}, ${subnet_type})|${subnet_id}")
    done < <("${cmd[@]}" 2>/dev/null | jq -r '.data[] | [.["display-name"], .id, .["cidr-block"], (.["prohibit-public-ip-on-vnic"] // false)] | @tsv')

    SELECT_DEFAULT_OPTION_VALUE="$default_value"
    select_option_pairs "子网列表" "${options[@]}"
}

is_valid_cidr_block() {
    local cidr_block="$1"
    [[ "$cidr_block" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

is_valid_dns_label() {
    local dns_label="$1"
    [[ "$dns_label" =~ ^[a-z][a-z0-9]{0,14}$ ]]
}

create_subnet_interactive() {
    local compartment_id="$1"
    local availability_domain="$2"

    printf '%s\n' ""
    printf '%b\n' "${BOLD}----------------------------------------${NC}"
    printf '%b\n' "${BOLD}新建子网${NC}"
    printf '%b\n' "${BOLD}----------------------------------------${NC}"
    printf '%s\n' ""

    local vcn_id subnet_name subnet_cidr dns_label subnet_scope subnet_type prohibit_public_ip use_ad
    local route_table_id security_list_ids_json input_value create_result subnet_id vcn_cidr
    local default_subnet_name default_public_name default_private_name default_subnet_cidr default_dns_label

    printf '%s\n' "VCN 获取方式:"
    printf '%s\n' "  1) 查询并选择"
    printf '%s\n' "  2) 手动输入"
    printf '%s\n' "  3) 新建 VCN"
    read_choice_with_default_label input_value "请选择" "1" "查询并选择"

    if [[ "$input_value" == "1" ]] && query_vcns "$compartment_id"; then
        vcn_id="$SELECT_RESULT"
    elif [[ "$input_value" == "1" ]]; then
        printf '%s\n' ""
        log_warn "未查询到可用 VCN，或未选择 VCN"
        read -p "是否现在新建一个 VCN? [Y/n]: " -r
        [[ -z "$REPLY" ]] && REPLY="y"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if create_vcn_interactive "$compartment_id"; then
                vcn_id="$SELECT_RESULT"
            fi
        fi
    elif [[ "$input_value" == "3" ]]; then
        if create_vcn_interactive "$compartment_id"; then
            vcn_id="$SELECT_RESULT"
        fi
    else
        read -p "VCN OCID: " vcn_id
    fi
    while [[ -z "$vcn_id" || ! "$vcn_id" =~ ^ocid1\.vcn\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的 VCN OCID${NC}"
        read -p "VCN OCID: " vcn_id
    done

    vcn_cidr="$(get_vcn_cidr "$vcn_id")"
    default_public_name="$(generate_default_network_name "public-subnet")"
    default_private_name="$(generate_default_network_name "private-subnet")"
    default_subnet_name="$default_public_name"
    default_subnet_cidr="$(derive_default_subnet_cidr "$vcn_cidr")"
    default_dns_label="$(generate_default_dns_label "subnet")"

    printf '%s\n' ""
    printf '%s\n' "子网类型:"
    printf '%s\n' "  1) 公有子网（允许分配公网IP）"
    printf '%s\n' "  2) 私有子网（禁止分配公网IP）"
    read_choice_with_default_label subnet_type "请选择" "1" "公有子网"
    prohibit_public_ip="false"
    if [[ "$subnet_type" == "2" ]]; then
        prohibit_public_ip="true"
        default_subnet_name="$default_private_name"
    fi

    read -p "子网名称 [默认: ${default_subnet_name}]: " subnet_name
    subnet_name="${subnet_name:-$default_subnet_name}"
    while [[ -z "$subnet_name" ]]; do
        printf '%b\n' "${RED}子网名称不能为空${NC}"
        read -p "子网名称: " subnet_name
    done

    read -p "子网 CIDR [默认: ${default_subnet_cidr}]: " subnet_cidr
    subnet_cidr="${subnet_cidr:-$default_subnet_cidr}"
    while ! is_valid_cidr_block "$subnet_cidr"; do
        printf '%b\n' "${RED}子网 CIDR 格式无效${NC}"
        read -p "子网 CIDR: " subnet_cidr
    done

    read -p "DNS Label [默认: ${default_dns_label}]（可选）: " dns_label
    dns_label="${dns_label:-$default_dns_label}"
    while [[ -n "$dns_label" ]] && ! is_valid_dns_label "$dns_label"; do
        printf '%b\n' "${RED}DNS Label 无效，请使用 1-15 位小写字母数字，且必须以字母开头${NC}"
        read -p "DNS Label（可选）: " dns_label
    done

    printf '%s\n' ""
    printf '%s\n' "子网范围:"
    printf '%s\n' "  1) 区域子网（推荐）"
    printf '%s\n' "  2) 可用性域子网 (${availability_domain})"
    read_choice_with_default_label subnet_scope "请选择" "1" "区域子网"
    use_ad="false"
    [[ "$subnet_scope" == "2" ]] && use_ad="true"

    printf '%s\n' ""
    if [[ "$prohibit_public_ip" == "false" && "$vcn_id" == "$LAST_CREATED_VCN_ID" && "$LAST_CREATED_VCN_PUBLIC_READY" == "true" && -n "$LAST_CREATED_VCN_DEFAULT_ROUTE_TABLE_ID" ]]; then
        route_table_id="$LAST_CREATED_VCN_DEFAULT_ROUTE_TABLE_ID"
        log_info "检测到刚创建的公网 VCN，默认使用其路由表: ${route_table_id}"
        read -p "是否改为手动指定路由表? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "路由表 OCID（可选，直接回车跳过）: " route_table_id
        fi
    else
        read -p "路由表 OCID（可选，直接回车跳过）: " route_table_id
    fi

    read -p "安全列表 OCID JSON 数组（可选，如 [\"ocid1.securitylist...\"]）: " security_list_ids_json
    if [[ -n "$security_list_ids_json" ]]; then
        while ! printf '%s\n' "$security_list_ids_json" | jq -e 'type == "array"' >/dev/null 2>&1; do
            printf '%b\n' "${RED}安全列表必须是 JSON 数组格式${NC}"
            read -p "安全列表 OCID JSON 数组（可选）: " security_list_ids_json
            [[ -z "$security_list_ids_json" ]] && break
        done
    fi

    printf '%s\n' ""
    printf '%b\n' "${CYAN}子网创建摘要:${NC}"
    printf '%s\n' "  VCN:          ${vcn_id:0:50}..."
    [[ -n "$vcn_cidr" ]] && printf '%s\n' "  VCN CIDR:     $vcn_cidr"
    printf '%s\n' "  子网名称:     $subnet_name"
    printf '%s\n' "  CIDR:         $subnet_cidr"
    printf '%s\n' "  DNS Label:    ${dns_label:-未设置}"
    printf '%s\n' "  范围:         $([[ "$use_ad" == "true" ]] && printf '%s\n' "可用性域子网" || printf '%s\n' "区域子网")"
    printf '%s\n' "  类型:         $([[ "$prohibit_public_ip" == "true" ]] && printf '%s\n' "私有子网" || printf '%s\n' "公有子网")"
    [[ -n "$route_table_id" ]] && printf '%s\n' "  路由表:       ${route_table_id:0:50}..."
    [[ -n "$security_list_ids_json" ]] && printf '%s\n' "  安全列表:     已指定"
    printf '%s\n' ""

    read -p "确认创建子网? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "已取消创建子网"
        return 1
    fi

    local cmd=(
        oci network subnet create
        --compartment-id "$compartment_id"
        --vcn-id "$vcn_id"
        --display-name "$subnet_name"
        --cidr-block "$subnet_cidr"
        --prohibit-public-ip-on-vnic "$prohibit_public_ip"
        --wait-for-state AVAILABLE
        --query "data.id"
        --raw-output
    )

    if [[ "$use_ad" == "true" ]]; then
        cmd+=(--availability-domain "$availability_domain")
    fi
    if [[ -n "$dns_label" ]]; then
        cmd+=(--dns-label "$dns_label")
    fi
    if [[ -n "$route_table_id" ]]; then
        cmd+=(--route-table-id "$route_table_id")
    fi
    if [[ -n "$security_list_ids_json" ]]; then
        cmd+=(--security-list-ids "$security_list_ids_json")
    fi

    log_info "正在创建子网..."
    create_result=$("${cmd[@]}" 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "子网创建失败: $create_result"
        return 1
    fi

    subnet_id="$(printf '%s\n' "$create_result" | tail -n 1 | tr -d '\r')"
    if [[ -z "$subnet_id" || "$subnet_id" == "null" || ! "$subnet_id" =~ ^ocid1\.subnet\.oc1\. ]]; then
        log_error "未能从创建结果中解析子网 OCID"
        printf '%s\n' "$create_result"
        return 1
    fi

    log_success "子网创建成功: $subnet_id"
    if [[ "$prohibit_public_ip" == "true" ]]; then
        log_warn "该子网为私有子网，后续创建实例时请将公网 IP 设置为 false"
    fi

    SELECT_RESULT="$subnet_id"
    return 0
}

load_create_instance_defaults() {
    local config_file="$1"
    CREATE_COMPARTMENT_ID="$(get_tenancy_id_from_config)"
    CREATE_AVAILABILITY_DOMAIN=""
    CREATE_SUBNET_ID=""
    CREATE_IMAGE_ID=""
    CREATE_IMAGE_OS="$BEGINNER_CREATE_IMAGE_OS_DEFAULT"
    CREATE_IMAGE_OS_VERSION="$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT"
    CREATE_SSH_PUBLIC_KEY="$CREATE_SSH_PUBLIC_KEY_DEFAULT"
    CREATE_SHAPE="$BEGINNER_CREATE_SHAPE_DEFAULT"
    CREATE_OCPUS="$BEGINNER_CREATE_OCPUS_DEFAULT"
    CREATE_MEMORY_GB="$BEGINNER_CREATE_MEMORY_GB_DEFAULT"
    CREATE_BOOT_VOLUME_SIZE="$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT"
    CREATE_BOOT_VOLUME_VPUS_PER_GB="$BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT"
    CREATE_DISPLAY_NAME="oci-instance-$(date +%Y%m%d-%H%M%S)"
    CREATE_ASSIGN_PUBLIC_IP="true"
    CREATE_RETRY_INTERVAL="10"

    if [[ -f "$config_file" ]] && jq empty "$config_file" 2>/dev/null; then
        CREATE_COMPARTMENT_ID="$(jq -r '.compartmentId // empty' "$config_file")"
        [[ -z "$CREATE_COMPARTMENT_ID" || "$CREATE_COMPARTMENT_ID" == "null" ]] && CREATE_COMPARTMENT_ID="$(get_tenancy_id_from_config)"
        CREATE_AVAILABILITY_DOMAIN="$(jq -r '.availabilityDomain // empty' "$config_file")"
        CREATE_SUBNET_ID="$(jq -r '.subnetId // empty' "$config_file")"
        CREATE_IMAGE_ID="$(jq -r '.imageId // empty' "$config_file")"
        CREATE_IMAGE_OS="$(jq -r --arg default_os "$BEGINNER_CREATE_IMAGE_OS_DEFAULT" '.imageOperatingSystem // $default_os' "$config_file")"
        CREATE_IMAGE_OS_VERSION="$(jq -r --arg default_version "$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT" '.imageOperatingSystemVersion // $default_version' "$config_file")"
        CREATE_SSH_PUBLIC_KEY="$(jq -r '.sshAuthorizedKeysFile // empty' "$config_file")"
        [[ -z "$CREATE_SSH_PUBLIC_KEY" || "$CREATE_SSH_PUBLIC_KEY" == "null" ]] && CREATE_SSH_PUBLIC_KEY="$CREATE_SSH_PUBLIC_KEY_DEFAULT"
        CREATE_SHAPE="$(jq -r --arg default_shape "$BEGINNER_CREATE_SHAPE_DEFAULT" '.shape // $default_shape' "$config_file")"
        CREATE_OCPUS="$(jq -r --arg default_ocpus "$BEGINNER_CREATE_OCPUS_DEFAULT" '.ocpus // ($default_ocpus | tonumber)' "$config_file")"
        CREATE_MEMORY_GB="$(jq -r --arg default_memory "$BEGINNER_CREATE_MEMORY_GB_DEFAULT" '.memoryInGBs // ($default_memory | tonumber)' "$config_file")"
        CREATE_BOOT_VOLUME_SIZE="$(jq -r --arg default_boot "$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT" '.bootVolumeSizeInGBs // ($default_boot | tonumber)' "$config_file")"
        CREATE_BOOT_VOLUME_VPUS_PER_GB="$(jq -r --arg default_vpus "$BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT" '.bootVolumeVpusPerGB // ($default_vpus | tonumber)' "$config_file")"
        CREATE_DISPLAY_NAME="$(jq -r '.displayName // empty' "$config_file")"
        [[ -z "$CREATE_DISPLAY_NAME" || "$CREATE_DISPLAY_NAME" == "null" ]] && CREATE_DISPLAY_NAME="oci-instance-$(date +%Y%m%d-%H%M%S)"
        CREATE_ASSIGN_PUBLIC_IP="$(jq -r '.assignPublicIp // true' "$config_file")"
        CREATE_RETRY_INTERVAL="$(jq -r '.retryInterval // 10' "$config_file")"
    fi
}

validate_create_instance_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "创建实例配置文件不存在: $config_file"
        return 1
    fi

    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "创建实例配置文件 JSON 格式无效: $config_file"
        return 1
    fi

    local compartment_id availability_domain subnet_id image_id ssh_public_key shape display_name assign_public_ip
    local ocpus memory_gbs boot_volume_size boot_volume_vpus_per_gb
    compartment_id=$(jq -r '.compartmentId // empty' "$config_file")
    availability_domain=$(jq -r '.availabilityDomain // empty' "$config_file")
    subnet_id=$(jq -r '.subnetId // empty' "$config_file")
    image_id=$(jq -r '.imageId // empty' "$config_file")
    ssh_public_key=$(jq -r '.sshAuthorizedKeysFile // empty' "$config_file")
    shape=$(jq -r '.shape // empty' "$config_file")
    display_name=$(jq -r '.displayName // empty' "$config_file")
    assign_public_ip=$(jq -r '.assignPublicIp // true' "$config_file")
    ocpus=$(jq -r '.ocpus // empty' "$config_file")
    memory_gbs=$(jq -r '.memoryInGBs // empty' "$config_file")
    boot_volume_size=$(jq -r '.bootVolumeSizeInGBs // empty' "$config_file")
    boot_volume_vpus_per_gb=$(jq -r '.bootVolumeVpusPerGB // empty' "$config_file")

    if [[ -z "$compartment_id" || ! "$compartment_id" =~ ^ocid1\. ]]; then
        log_error "compartmentId 无效"
        return 1
    fi
    if [[ -z "$availability_domain" ]]; then
        log_error "availabilityDomain 不能为空"
        return 1
    fi
    if [[ -n "$subnet_id" && "$subnet_id" != "null" && ! "$subnet_id" =~ ^ocid1\.subnet\.oc1\. ]]; then
        log_error "subnetId 无效"
        return 1
    fi
    if [[ -z "$image_id" || ! "$image_id" =~ ^ocid1\.image\.oc1\. ]]; then
        log_error "imageId 无效"
        return 1
    fi
    if [[ -z "$shape" ]]; then
        log_error "shape 不能为空"
        return 1
    fi
    if [[ -z "$display_name" ]]; then
        log_error "displayName 不能为空"
        return 1
    fi
    if [[ "$assign_public_ip" != "true" && "$assign_public_ip" != "false" ]]; then
        log_error "assignPublicIp 必须为 true 或 false"
        return 1
    fi

    local expanded_ssh_key
    expanded_ssh_key="$(expand_path "$ssh_public_key")"
    if [[ ! -f "$expanded_ssh_key" ]]; then
        log_error "SSH 公钥文件不存在: $expanded_ssh_key"
        return 1
    fi

    if [[ "$shape" == *"Flex"* ]]; then
        if [[ ! "$ocpus" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            log_error "Flex 规格必须提供有效的 ocpus"
            return 1
        fi
        if [[ ! "$memory_gbs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            log_error "Flex 规格必须提供有效的 memoryInGBs"
            return 1
        fi
    fi

    if [[ -n "$boot_volume_size" && "$boot_volume_size" != "null" ]]; then
        if [[ ! "$boot_volume_size" =~ ^[0-9]+$ || "$boot_volume_size" -lt 1 || "$boot_volume_size" -gt 32768 ]]; then
            log_error "bootVolumeSizeInGBs 必须为 1-32768 的整数"
            return 1
        fi
    fi

    if [[ -n "$boot_volume_vpus_per_gb" && "$boot_volume_vpus_per_gb" != "null" ]]; then
        if [[ ! "$boot_volume_vpus_per_gb" =~ ^[0-9]+$ ]]; then
            log_error "bootVolumeVpusPerGB 必须为整数"
            return 1
        fi
        if [[ "$boot_volume_vpus_per_gb" -lt 10 || "$boot_volume_vpus_per_gb" -gt 120 || $((boot_volume_vpus_per_gb % 10)) -ne 0 ]]; then
            log_error "bootVolumeVpusPerGB 必须为 10-120 且为 10 的倍数"
            return 1
        fi
    fi

    return 0
}

show_create_instance_config_summary() {
    local config_file="${1:-$CREATE_INSTANCE_CONFIG}"

    if [[ ! -f "$config_file" ]]; then
        log_warn "尚未保存创建实例配置: $config_file"
        return 1
    fi

    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "配置文件 JSON 格式无效: $config_file"
        return 1
    fi

    local compartment_id availability_domain subnet_id image_id image_os image_os_version shape display_name assign_public_ip
    local ssh_public_key boot_volume_size boot_volume_vpus_per_gb ocpus memory_gbs retry_interval
    compartment_id=$(jq -r '.compartmentId // "N/A"' "$config_file")
    availability_domain=$(jq -r '.availabilityDomain // "N/A"' "$config_file")
    subnet_id=$(jq -r '.subnetId // "N/A"' "$config_file")
    image_id=$(jq -r '.imageId // "N/A"' "$config_file")
    image_os=$(jq -r '.imageOperatingSystem // "N/A"' "$config_file")
    image_os_version=$(jq -r '.imageOperatingSystemVersion // "N/A"' "$config_file")
    shape=$(jq -r '.shape // "N/A"' "$config_file")
    display_name=$(jq -r '.displayName // "N/A"' "$config_file")
    assign_public_ip=$(jq -r '.assignPublicIp // "N/A"' "$config_file")
    ssh_public_key=$(jq -r '.sshAuthorizedKeysFile // "N/A"' "$config_file")
    boot_volume_size=$(jq -r '.bootVolumeSizeInGBs // "N/A"' "$config_file")
    boot_volume_vpus_per_gb=$(jq -r '.bootVolumeVpusPerGB // "N/A"' "$config_file")
    ocpus=$(jq -r '.ocpus // "N/A"' "$config_file")
    memory_gbs=$(jq -r '.memoryInGBs // "N/A"' "$config_file")
    retry_interval=$(jq -r '.retryInterval // 10' "$config_file")

    printf '%s\n' ""
    printf '%b\n' "${BOLD}创建实例配置摘要${NC}"
    printf '%s\n' "----------------------------------------"
    printf '%s\n' "配置文件:      $config_file"
    printf '%s\n' "区间 OCID:     ${compartment_id:0:50}..."
    printf '%s\n' "可用性域:      $availability_domain"
    printf '%s\n' "子网 OCID:     ${subnet_id:0:50}..."
    printf '%s\n' "镜像系统:      $image_os"
    [[ -n "$image_os_version" && "$image_os_version" != "N/A" ]] && printf '%s\n' "系统版本:      $image_os_version"
    printf '%s\n' "镜像 OCID:     ${image_id:0:50}..."
    printf '%s\n' "实例规格:      $shape"
    if [[ "$shape" == *"Flex"* ]]; then
        printf '%s\n' "OCPU:          $ocpus"
        printf '%s\n' "内存(GB):      $memory_gbs"
    fi
    printf '%s\n' "实例名称:      $display_name"
    printf '%s\n' "SSH 公钥:      $ssh_public_key"
    printf '%s\n' "公网 IP:       $assign_public_ip"
    printf '%s\n' "启动盘(GB):    $boot_volume_size"
    printf '%s\n' "启动盘性能:    ${boot_volume_vpus_per_gb} VPU/GB"
    printf '%s\n' "重试间隔(秒):  $retry_interval"
    printf '%s\n' "----------------------------------------"
    printf '%s\n' ""
}

save_create_instance_config() {
    local config_file="$1"
    local compartment_id="$2"
    local availability_domain="$3"
    local subnet_id="$4"
    local image_id="$5"
    local image_os="$6"
    local image_os_version="$7"
    local ssh_public_key="$8"
    local shape="$9"
    local ocpus="${10}"
    local memory_gbs="${11}"
    local boot_volume_size="${12}"
    local boot_volume_vpus_per_gb="${13}"
    local display_name="${14}"
    local assign_public_ip="${15}"
    local retry_interval="${16}"

    local ocpus_json="null"
    local memory_json="null"
    local boot_json="null"
    local boot_vpus_json="null"

    if [[ -n "$ocpus" ]]; then
        ocpus_json="$ocpus"
    fi
    if [[ -n "$memory_gbs" ]]; then
        memory_json="$memory_gbs"
    fi
    if [[ -n "$boot_volume_size" ]]; then
        boot_json="$boot_volume_size"
    fi
    if [[ -n "$boot_volume_vpus_per_gb" ]]; then
        boot_vpus_json="$boot_volume_vpus_per_gb"
    fi

    mkdir -p "$(dirname "$config_file")"

    jq -n \
        --arg compartment_id "$compartment_id" \
        --arg availability_domain "$availability_domain" \
        --arg subnet_id "$subnet_id" \
        --arg image_id "$image_id" \
        --arg image_os "$image_os" \
        --arg image_os_version "$image_os_version" \
        --arg ssh_key "$ssh_public_key" \
        --arg shape "$shape" \
        --arg display_name "$display_name" \
        --argjson assign_public_ip "$assign_public_ip" \
        --argjson ocpus "$ocpus_json" \
        --argjson memory_gbs "$memory_json" \
        --argjson boot_volume_size "$boot_json" \
        --argjson boot_volume_vpus_per_gb "$boot_vpus_json" \
        --argjson retry_interval "$retry_interval" \
        '{
            compartmentId: $compartment_id,
            availabilityDomain: $availability_domain,
            imageId: $image_id,
            imageOperatingSystem: $image_os,
            imageOperatingSystemVersion: $image_os_version,
            sshAuthorizedKeysFile: $ssh_key,
            shape: $shape,
            ocpus: $ocpus,
            memoryInGBs: $memory_gbs,
            bootVolumeSizeInGBs: $boot_volume_size,
            bootVolumeVpusPerGB: $boot_volume_vpus_per_gb,
            displayName: $display_name,
            assignPublicIp: $assign_public_ip,
            retryInterval: $retry_interval
        }
        + (if $subnet_id != "" and $subnet_id != "null" then {subnetId: $subnet_id} else {} end)' > "$config_file"
}

autosave_create_instance_progress() {
    local config_file="$1"
    local compartment_id="$2"
    local availability_domain="$3"
    local subnet_id="$4"
    local image_id="$5"
    local image_os="$6"
    local image_os_version="$7"
    local ssh_public_key="$8"
    local shape="$9"
    local ocpus="${10}"
    local memory_gbs="${11}"
    local boot_volume_size="${12}"
    local boot_volume_vpus_per_gb="${13}"
    local display_name="${14}"
    local assign_public_ip="${15}"
    local retry_interval="${16}"

    local temp_file="${config_file}.autosave"
    save_create_instance_config \
        "$temp_file" \
        "$compartment_id" \
        "$availability_domain" \
        "$subnet_id" \
        "$image_id" \
        "$image_os" \
        "$image_os_version" \
        "$ssh_public_key" \
        "$shape" \
        "$ocpus" \
        "$memory_gbs" \
        "$boot_volume_size" \
        "$boot_volume_vpus_per_gb" \
        "$display_name" \
        "$assign_public_ip" \
        "$retry_interval"
    mv "$temp_file" "$config_file"
}

get_create_instance_resume_file() {
    if [[ -f "$CREATE_INSTANCE_DRAFT_CONFIG" ]] && jq empty "$CREATE_INSTANCE_DRAFT_CONFIG" >/dev/null 2>&1; then
        printf '%s\n' "$CREATE_INSTANCE_DRAFT_CONFIG"
    else
        printf '%s\n' "$CREATE_INSTANCE_CONFIG"
    fi
}

configure_create_instance_params() {
    local config_file="$CREATE_INSTANCE_CONFIG"
    local draft_file="$CREATE_INSTANCE_DRAFT_CONFIG"
    local resume_file

    show_header
    printf '%b\n' "${BOLD}[5] 创建实例 - 获取关键参数并保存${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    trap 'printf "%b\n" "\n${YELLOW}已中断，当前创建实例参数进度已自动保存到: ${draft_file}${NC}"; trap '\''printf "%b\n" "\n${YELLOW}操作已取消${NC}"; exit 0'\'' INT TERM; return 130 2>/dev/null || exit 130' INT TERM

    resume_file="$(get_create_instance_resume_file)"
    load_create_instance_defaults "$resume_file"

    printf '%s\n' "正式配置路径: $config_file"
    printf '%s\n' "草稿路径:     $draft_file"
    if [[ -f "$draft_file" ]]; then
        printf '%b\n' "${GREEN}✓${NC} 检测到未完成草稿，将从草稿继续"
    elif [[ -f "$config_file" ]]; then
        printf '%b\n' "${GREEN}✓${NC} 检测到已确认配置，将作为默认值"
    else
        printf '%b\n' "${YELLOW}!${NC} 尚未保存创建配置，将生成新的配置文件"
    fi
    printf '%b\n' "${CYAN}提示: 本流程会自动保存到草稿文件，只有确认完成时才会更新正式配置${NC}"
    printf '%s\n' ""

    local compartment_id availability_domain subnet_id image_id image_os image_os_version ssh_public_key
    local shape ocpus memory_gbs boot_volume_size boot_volume_vpus_per_gb display_name assign_public_ip retry_interval vcn_id
    local input_value lookup_mode

    read -p "区间 OCID [默认: ${CREATE_COMPARTMENT_ID}]: " input_value
    compartment_id="${input_value:-$CREATE_COMPARTMENT_ID}"
    while [[ -z "$compartment_id" || ! "$compartment_id" =~ ^ocid1\. ]]; do
        printf '%b\n' "${RED}无效的区间 OCID${NC}"
        read -p "区间 OCID: " compartment_id
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$CREATE_AVAILABILITY_DOMAIN" "$CREATE_SUBNET_ID" "$CREATE_IMAGE_ID" "$CREATE_IMAGE_OS" "$CREATE_IMAGE_OS_VERSION" "$CREATE_SSH_PUBLIC_KEY" "$CREATE_SHAPE" "$CREATE_OCPUS" "$CREATE_MEMORY_GB" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$CREATE_DISPLAY_NAME" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    printf '%s\n' ""
    printf '%s\n' "可用性域获取方式:"
    printf '%s\n' "  1) 查询并选择"
    printf '%s\n' "  2) 手动输入"
    read_choice_with_default_label lookup_mode "请选择" "1" "查询并选择"
    if [[ "$lookup_mode" == "1" ]] && query_availability_domains "$CREATE_AVAILABILITY_DOMAIN"; then
        availability_domain="$SELECT_RESULT"
    else
        read -p "可用性域 [默认: ${CREATE_AVAILABILITY_DOMAIN}]: " input_value
        availability_domain="${input_value:-$CREATE_AVAILABILITY_DOMAIN}"
    fi
    while [[ -z "$availability_domain" ]]; do
        printf '%b\n' "${RED}可用性域不能为空${NC}"
        read -p "可用性域: " availability_domain
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$CREATE_SUBNET_ID" "$CREATE_IMAGE_ID" "$CREATE_IMAGE_OS" "$CREATE_IMAGE_OS_VERSION" "$CREATE_SSH_PUBLIC_KEY" "$CREATE_SHAPE" "$CREATE_OCPUS" "$CREATE_MEMORY_GB" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$CREATE_DISPLAY_NAME" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    printf '%s\n' ""
    printf '%s\n' "实例规格获取方式:"
    printf '%s\n' "  1) 查询并选择"
    printf '%s\n' "  2) 手动输入"
    read_choice_with_default_label lookup_mode "请选择" "1" "查询并选择"
    if [[ "$lookup_mode" == "1" ]] && query_shapes "$compartment_id" "$availability_domain" "$CREATE_SHAPE"; then
        shape="$SELECT_RESULT"
    else
        read -p "实例规格 [默认: ${CREATE_SHAPE}]: " input_value
        shape="${input_value:-$CREATE_SHAPE}"
    fi
    while [[ -z "$shape" ]]; do
        printf '%b\n' "${RED}实例规格不能为空${NC}"
        read -p "实例规格: " shape
    done

    ocpus=""
    memory_gbs=""
    if [[ "$shape" == *"Flex"* ]]; then
        read -p "OCPU 数量 [默认: ${CREATE_OCPUS}]: " input_value
        ocpus="${input_value:-$CREATE_OCPUS}"
        while [[ ! "$ocpus" =~ ^[0-9]+([.][0-9]+)?$ ]]; do
            printf '%b\n' "${RED}请输入有效的 OCPU 数值${NC}"
            read -p "OCPU 数量: " ocpus
        done

        read -p "内存 (GB) [默认: ${CREATE_MEMORY_GB}]: " input_value
        memory_gbs="${input_value:-$CREATE_MEMORY_GB}"
        while [[ ! "$memory_gbs" =~ ^[0-9]+([.][0-9]+)?$ ]]; do
            printf '%b\n' "${RED}请输入有效的内存数值${NC}"
            read -p "内存 (GB): " memory_gbs
        done
    fi
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$CREATE_SUBNET_ID" "$CREATE_IMAGE_ID" "$CREATE_IMAGE_OS" "$CREATE_IMAGE_OS_VERSION" "$CREATE_SSH_PUBLIC_KEY" "$shape" "$ocpus" "$memory_gbs" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$CREATE_DISPLAY_NAME" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    printf '%s\n' ""
    printf '%s\n' "子网获取方式:"
    printf '%s\n' "  1) 查询并选择"
    printf '%s\n' "  2) 手动输入"
    printf '%s\n' "  3) 新建子网"
    read_choice_with_default_label lookup_mode "请选择" "1" "查询并选择"
    if [[ "$lookup_mode" == "1" ]]; then
        read -p "VCN OCID（可选，留空则列出区间内全部子网）: " vcn_id
        if query_subnets "$compartment_id" "$vcn_id" "$CREATE_SUBNET_ID"; then
            subnet_id="$SELECT_RESULT"
        else
            printf '%s\n' ""
            log_warn "未查询到可用子网，或未选择子网"
            read -p "是否现在新建一个子网? [Y/n]: " -r
            [[ -z "$REPLY" ]] && REPLY="y"
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if create_subnet_interactive "$compartment_id" "$availability_domain"; then
                    subnet_id="$SELECT_RESULT"
                fi
            fi
        fi
    elif [[ "$lookup_mode" == "3" ]]; then
        if create_subnet_interactive "$compartment_id" "$availability_domain"; then
            subnet_id="$SELECT_RESULT"
        fi
    fi
    if [[ -z "$subnet_id" ]]; then
        read -p "子网 OCID [默认: ${CREATE_SUBNET_ID}]: " input_value
        subnet_id="${input_value:-$CREATE_SUBNET_ID}"
    fi
    while [[ -z "$subnet_id" || ! "$subnet_id" =~ ^ocid1\.subnet\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的子网 OCID${NC}"
        read -p "子网 OCID: " subnet_id
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$CREATE_IMAGE_ID" "$CREATE_IMAGE_OS" "$CREATE_IMAGE_OS_VERSION" "$CREATE_SSH_PUBLIC_KEY" "$shape" "$ocpus" "$memory_gbs" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$CREATE_DISPLAY_NAME" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    printf '%s\n' ""
    printf '%s\n' "镜像获取方式:"
    printf '%s\n' "  1) 查询并选择"
    printf '%s\n' "  2) 手动输入"
    read_choice_with_default_label lookup_mode "请选择" "1" "查询并选择"
    image_os="$CREATE_IMAGE_OS"
    image_os_version="$CREATE_IMAGE_OS_VERSION"
    if [[ "$lookup_mode" == "1" ]]; then
        if query_image_operating_systems "$compartment_id" "$CREATE_IMAGE_OS"; then
            image_os="$SELECT_RESULT"
        else
            read -p "操作系统名称 [默认: ${CREATE_IMAGE_OS}]: " input_value
            image_os="${input_value:-$CREATE_IMAGE_OS}"
        fi
        printf '%s\n' "已选择操作系统: $image_os"
        if query_image_operating_system_versions "$compartment_id" "$image_os" "$CREATE_IMAGE_OS_VERSION"; then
            image_os_version="$SELECT_RESULT"
        else
            read -p "操作系统版本 [默认: ${CREATE_IMAGE_OS_VERSION:-自动选择}]: " input_value
            image_os_version="${input_value:-$CREATE_IMAGE_OS_VERSION}"
        fi
        [[ -n "$image_os_version" ]] && printf '%s\n' "已选择系统版本: $image_os_version"
        if query_images "$compartment_id" "$image_os" "$image_os_version" "$shape" "$CREATE_IMAGE_ID"; then
            image_id="$SELECT_RESULT"
        fi
    fi
    if [[ -z "$image_id" ]]; then
        read -p "镜像 OCID [默认: ${CREATE_IMAGE_ID}]: " input_value
        image_id="${input_value:-$CREATE_IMAGE_ID}"
    fi
    while [[ -z "$image_id" || ! "$image_id" =~ ^ocid1\.image\.oc1\. ]]; do
        printf '%b\n' "${RED}无效的镜像 OCID${NC}"
        read -p "镜像 OCID: " image_id
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$CREATE_SSH_PUBLIC_KEY" "$shape" "$ocpus" "$memory_gbs" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$CREATE_DISPLAY_NAME" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    read -p "SSH 公钥文件 [默认: ${CREATE_SSH_PUBLIC_KEY}]: " input_value
    ssh_public_key="${input_value:-$CREATE_SSH_PUBLIC_KEY}"
    if ! ensure_create_ssh_public_key "$ssh_public_key"; then
        pause
        return 1
    fi
    ssh_public_key="$SELECT_RESULT"
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$ssh_public_key" "$shape" "$ocpus" "$memory_gbs" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$CREATE_DISPLAY_NAME" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    read -p "实例名称 [默认: ${CREATE_DISPLAY_NAME}]: " input_value
    display_name="${input_value:-$CREATE_DISPLAY_NAME}"
    while [[ -z "$display_name" ]]; do
        printf '%b\n' "${RED}实例名称不能为空${NC}"
        read -p "实例名称: " display_name
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$ssh_public_key" "$shape" "$ocpus" "$memory_gbs" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$display_name" "$CREATE_ASSIGN_PUBLIC_IP" "$CREATE_RETRY_INTERVAL"

    read -p "分配公网 IP? [true/false，默认: ${CREATE_ASSIGN_PUBLIC_IP}]: " input_value
    assign_public_ip="${input_value:-$CREATE_ASSIGN_PUBLIC_IP}"
    while [[ "$assign_public_ip" != "true" && "$assign_public_ip" != "false" ]]; do
        printf '%b\n' "${RED}请输入 true 或 false${NC}"
        read -p "分配公网 IP? [true/false]: " assign_public_ip
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$ssh_public_key" "$shape" "$ocpus" "$memory_gbs" "$CREATE_BOOT_VOLUME_SIZE" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$display_name" "$assign_public_ip" "$CREATE_RETRY_INTERVAL"

    read -p "启动盘大小 (GB) [默认: ${CREATE_BOOT_VOLUME_SIZE}，留空表示不指定]: " input_value
    boot_volume_size="${input_value:-$CREATE_BOOT_VOLUME_SIZE}"
    if [[ -n "$boot_volume_size" ]]; then
        while [[ ! "$boot_volume_size" =~ ^[0-9]+$ || "$boot_volume_size" -lt 1 || "$boot_volume_size" -gt 32768 ]]; do
            printf '%b\n' "${RED}请输入有效的启动盘大小，范围 1-32768 GB${NC}"
            read -p "启动盘大小 (GB): " boot_volume_size
        done
    fi
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$ssh_public_key" "$shape" "$ocpus" "$memory_gbs" "$boot_volume_size" "$CREATE_BOOT_VOLUME_VPUS_PER_GB" "$display_name" "$assign_public_ip" "$CREATE_RETRY_INTERVAL"

    read -p "启动盘性能 (VPU/GB) [默认: ${CREATE_BOOT_VOLUME_VPUS_PER_GB}，支持 10-120 且为 10 的倍数]: " input_value
    boot_volume_vpus_per_gb="${input_value:-$CREATE_BOOT_VOLUME_VPUS_PER_GB}"
    while [[ ! "$boot_volume_vpus_per_gb" =~ ^[0-9]+$ || "$boot_volume_vpus_per_gb" -lt 10 || "$boot_volume_vpus_per_gb" -gt 120 || $((boot_volume_vpus_per_gb % 10)) -ne 0 ]]; do
        printf '%b\n' "${RED}请输入有效的启动盘性能，范围 10-120 且必须是 10 的倍数${NC}"
        read -p "启动盘性能 (VPU/GB): " boot_volume_vpus_per_gb
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$ssh_public_key" "$shape" "$ocpus" "$memory_gbs" "$boot_volume_size" "$boot_volume_vpus_per_gb" "$display_name" "$assign_public_ip" "$CREATE_RETRY_INTERVAL"

    read -p "后台重试间隔 (秒) [默认: ${CREATE_RETRY_INTERVAL}]: " input_value
    retry_interval="${input_value:-$CREATE_RETRY_INTERVAL}"
    while [[ ! "$retry_interval" =~ ^[0-9]+$ ]]; do
        printf '%b\n' "${RED}请输入有效的重试间隔${NC}"
        read -p "后台重试间隔 (秒): " retry_interval
    done
    autosave_create_instance_progress "$draft_file" "$compartment_id" "$availability_domain" "$subnet_id" "$image_id" "$image_os" "$image_os_version" "$ssh_public_key" "$shape" "$ocpus" "$memory_gbs" "$boot_volume_size" "$boot_volume_vpus_per_gb" "$display_name" "$assign_public_ip" "$retry_interval"

    printf '%s\n' ""
    printf '%b\n' "${CYAN}当前草稿预览:${NC}"
    show_create_instance_config_summary "$draft_file"
    read -p "确认完成本次设置? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "本次设置未确认，但当前进度已自动保存在草稿: $draft_file"
        trap 'printf "%b\n" "\n${YELLOW}操作已取消${NC}"; exit 0' INT TERM
        pause
        return 0
    fi

    cp "$draft_file" "$config_file"
    rm -f "$draft_file"
    log_success "创建实例配置已保存到: $config_file"
    trap 'printf "%b\n" "\n${YELLOW}操作已取消${NC}"; exit 0' INT TERM
    pause
}

show_saved_create_instance_config() {
    show_header
    printf '%b\n' "${BOLD}[5] 创建实例 - 查看已保存配置${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    local has_any=false

    if [[ -f "$CREATE_INSTANCE_CONFIG" ]]; then
        printf '%b\n' "${GREEN}已确认配置${NC}"
        show_create_instance_config_summary "$CREATE_INSTANCE_CONFIG"
        printf '%b\n' "${BOLD}JSON 内容预览:${NC}"
        printf '%s\n' "----------------------------------------"
        jq '.' "$CREATE_INSTANCE_CONFIG"
        printf '%s\n' "----------------------------------------"
        printf '%s\n' ""
        has_any=true
    fi

    if [[ -f "$CREATE_INSTANCE_DRAFT_CONFIG" ]]; then
        printf '%b\n' "${YELLOW}未完成草稿${NC}"
        show_create_instance_config_summary "$CREATE_INSTANCE_DRAFT_CONFIG"
        printf '%b\n' "${BOLD}JSON 内容预览:${NC}"
        printf '%s\n' "----------------------------------------"
        jq '.' "$CREATE_INSTANCE_DRAFT_CONFIG"
        printf '%s\n' "----------------------------------------"
        printf '%s\n' ""
        has_any=true
    fi

    if [[ "$has_any" != "true" ]]; then
        log_warn "尚未找到已确认配置或草稿配置"
        pause
        return 1
    fi

    pause
}

launch_instance_from_config() {
    local config_file="$1"

    if ! validate_create_instance_config "$config_file"; then
        return 1
    fi

    local compartment_id availability_domain subnet_id image_id ssh_public_key shape display_name assign_public_ip
    local ocpus memory_gbs boot_volume_size boot_volume_vpus_per_gb
    compartment_id=$(jq -r '.compartmentId' "$config_file")
    availability_domain=$(jq -r '.availabilityDomain' "$config_file")
    subnet_id=$(jq -r '.subnetId' "$config_file")
    image_id=$(jq -r '.imageId' "$config_file")
    ssh_public_key="$(expand_path "$(jq -r '.sshAuthorizedKeysFile' "$config_file")")"
    shape=$(jq -r '.shape' "$config_file")
    display_name=$(jq -r '.displayName' "$config_file")
    assign_public_ip=$(jq -r '.assignPublicIp' "$config_file")
    ocpus=$(jq -r '.ocpus // empty' "$config_file")
    memory_gbs=$(jq -r '.memoryInGBs // empty' "$config_file")
    boot_volume_size=$(jq -r '.bootVolumeSizeInGBs // empty' "$config_file")
    boot_volume_vpus_per_gb=$(jq -r '.bootVolumeVpusPerGB // empty' "$config_file")

    local cmd=(
        oci compute instance launch
        --compartment-id "$compartment_id"
        --availability-domain "$availability_domain"
        --shape "$shape"
        --ssh-authorized-keys-file "$ssh_public_key"
        --display-name "$display_name"
        --assign-public-ip "$assign_public_ip"
        # 不等待 RUNNING，launch 接受后即可返回实例 OCID；后续单独轮询开机状态并通知。
        # --wait-for-state RUNNING
        # --wait-interval-seconds 10
        # --max-wait-seconds "$OCI_CREATE_MAX_WAIT_SECONDS"
        --connection-timeout "$OCI_CREATE_CONNECTION_TIMEOUT"
        --read-timeout "$OCI_CREATE_READ_TIMEOUT"
        --max-retries "$OCI_CREATE_MAX_RETRIES"
        --output json
    )
    if [[ -n "$subnet_id" && "$subnet_id" != "null" ]]; then
        cmd+=(--subnet-id "$subnet_id")
    fi

    local source_details_json
    source_details_json=$(jq -cn \
        --arg image_id "$image_id" \
        --arg boot_volume_size "$boot_volume_size" \
        --arg boot_volume_vpus_per_gb "$boot_volume_vpus_per_gb" \
        '{
            sourceType: "image",
            imageId: $image_id
        }
        + (if $boot_volume_size != "" and $boot_volume_size != "null" then {bootVolumeSizeInGBs: ($boot_volume_size | tonumber)} else {} end)
        + (if $boot_volume_vpus_per_gb != "" and $boot_volume_vpus_per_gb != "null" then {bootVolumeVpusPerGB: ($boot_volume_vpus_per_gb | tonumber)} else {} end)')
    cmd+=(--source-details "$source_details_json")

    if [[ "$shape" == *"Flex"* ]]; then
        local shape_config_json
        shape_config_json=$(jq -cn \
            --arg ocpus "$ocpus" \
            --arg memory_gbs "$memory_gbs" \
            '{
                ocpus: ($ocpus | tonumber),
                memory_in_gbs: ($memory_gbs | tonumber)
            }')
        cmd+=(--shape-config "$shape_config_json")
    fi

    "${cmd[@]}"
}

send_create_success_notification() {
    local config_file="$1"
    local instance_id="$2"
    local display_name shape ocpus memory_gbs
    display_name=$(jq -r '.displayName // "N/A"' "$config_file")
    shape=$(jq -r '.shape // "N/A"' "$config_file")
    ocpus=$(jq -r '.ocpus // "N/A"' "$config_file")
    memory_gbs=$(jq -r '.memoryInGBs // "N/A"' "$config_file")

    send_notification \
        "OCI 实例创建成功" \
        "实例 ${display_name} 创建成功\n实例 OCID: ${instance_id}\n规格: ${shape}\nOCPU: ${ocpus}\n内存: ${memory_gbs} GB\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

send_create_boot_notification() {
    local config_file="$1"
    local instance_id="$2"
    local boot_status="$3"
    local display_name
    display_name=$(jq -r '.displayName // "N/A"' "$config_file")

    send_notification \
        "OCI 实例开机${boot_status}" \
        "实例 ${display_name} 开机${boot_status}\n实例 OCID: ${instance_id}\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

wait_created_instance_running() {
    local instance_id="$1"
    local log_prefix="${2:-实例}"
    local max_wait="${OCI_CREATE_MAX_WAIT_SECONDS:-120}"
    local interval=10
    local waited=0
    local state=""

    [[ -n "$instance_id" && "$instance_id" != "null" ]] || return 1

    while [[ $waited -le $max_wait ]]; do
        state=$(oci compute instance get \
            --instance-id "$instance_id" \
            --query 'data."lifecycle-state"' \
            --raw-output \
            --connection-timeout "$OCI_CREATE_CONNECTION_TIMEOUT" \
            --read-timeout "$OCI_CREATE_READ_TIMEOUT" \
            --max-retries "$OCI_CREATE_MAX_RETRIES" 2>/dev/null)

        if [[ "$state" == "RUNNING" ]]; then
            log_success "${log_prefix}已进入 RUNNING"
            return 0
        fi

        if [[ "$state" == "TERMINATED" || "$state" == "TERMINATING" ]]; then
            log_error "${log_prefix}状态异常: $state"
            return 1
        fi

        log_info "${log_prefix}当前状态: ${state:-未知}，等待开机..."
        sleep "$interval"
        ((waited += interval))
    done

    log_warn "${log_prefix}等待 RUNNING 超时，最后状态: ${state:-未知}"
    return 1
}

notify_created_instance_boot_result() {
    local config_file="$1"
    local instance_id="$2"

    [[ -n "$instance_id" && "$instance_id" != "null" ]] || return 1

    if wait_created_instance_running "$instance_id" "实例"; then
        show_created_instance_summary "$instance_id"
        send_create_boot_notification "$config_file" "$instance_id" "成功"
        return 0
    fi

    send_create_boot_notification "$config_file" "$instance_id" "未完成"
    return 1
}

show_created_instance_summary() {
    local instance_id="$1"

    if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
        return 0
    fi

    local detail_json
    detail_json=$(oci compute instance get \
        --instance-id "$instance_id" \
        --output json 2>/dev/null)

    local display_name="N/A"
    local lifecycle_state="N/A"
    local shape="N/A"
    if [[ -n "$detail_json" ]]; then
        display_name=$(printf '%s\n' "$detail_json" | jq -r '.data["display-name"] // "N/A"' 2>/dev/null)
        lifecycle_state=$(printf '%s\n' "$detail_json" | jq -r '.data["lifecycle-state"] // "N/A"' 2>/dev/null)
        shape=$(printf '%s\n' "$detail_json" | jq -r '.data.shape // "N/A"' 2>/dev/null)
    fi

    local vnics_json
    local private_ip="N/A"
    local public_ip="N/A"
    vnics_json=$(oci compute instance list-vnics \
        --instance-id "$instance_id" \
        --output json 2>/dev/null)

    if [[ -n "$vnics_json" ]]; then
        private_ip=$(printf '%s\n' "$vnics_json" | jq -r '.data[0]["private-ip"] // "N/A"' 2>/dev/null)
        public_ip=$(printf '%s\n' "$vnics_json" | jq -r '.data[0]["public-ip"] // "N/A"' 2>/dev/null)
    fi

    printf '%s\n' ""
    printf '%b\n' "${BOLD}实例创建结果摘要${NC}"
    printf '%s\n' "----------------------------------------"
    printf '%s\n' "实例名称:      $display_name"
    printf '%s\n' "实例 OCID:     $instance_id"
    printf '%s\n' "实例状态:      $lifecycle_state"
    printf '%s\n' "实例规格:      $shape"
    printf '%s\n' "私网 IP:       $private_ip"
    printf '%s\n' "公网 IP:       $public_ip"
    printf '%s\n' "----------------------------------------"
    printf '%s\n' ""
}

check_existing_create_task() {
    local display_name="$1"

    init_task_dir

    for task_path in "$TASK_DIR"/*; do
        [[ ! -d "$task_path" ]] && continue

        local task_info="$task_path/task.info"
        [[ ! -f "$task_info" ]] && continue

        local task_type task_status task_display_name
        task_type=$(jq -r '.task_type // empty' "$task_info" 2>/dev/null)
        task_status=$(jq -r '.status // empty' "$task_info" 2>/dev/null)
        task_display_name=$(jq -r '.display_name // empty' "$task_info" 2>/dev/null)

        if [[ "$task_type" == "create_instance" && "$task_status" == "running" && "$task_display_name" == "$display_name" ]]; then
            local pid_file="$task_path/task.pid"
            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file" 2>/dev/null)
                if kill -0 "$pid" 2>/dev/null; then
                    local task_id
                    task_id=$(jq -r '.task_id // empty' "$task_info" 2>/dev/null)
                    printf '%s\n' ""
                    log_warn "检测到同名实例创建任务仍在运行"
                    printf '%s\n' "  任务 ID: $task_id"
                    printf '%s\n' "  实例名称: $display_name"
                    printf '%s\n' ""
                    read -p "是否停止现有任务并创建新任务? [y/N]: " -r
                    [[ -z "$REPLY" ]] && REPLY="n"
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        log_info "操作已取消"
                        return 1
                    fi

                    stop_task "$task_id"
                    break
                fi
            fi
        fi
    done

    return 0
}

find_existing_created_instance() {
    local compartment_id="$1"
    local display_name="$2"

    [[ -n "$compartment_id" && -n "$display_name" ]] || return 1

    local instances_json
    instances_json=$(oci compute instance list \
        --compartment-id "$compartment_id" \
        --all \
        --connection-timeout "$OCI_CREATE_CONNECTION_TIMEOUT" \
        --read-timeout "$OCI_CREATE_READ_TIMEOUT" \
        --max-retries "$OCI_CREATE_MAX_RETRIES" \
        --output json 2>/dev/null)

    [[ -n "$instances_json" ]] || return 1

    printf '%s\n' "$instances_json" | jq -r --arg display_name "$display_name" '
        .data[]
        | select(.["display-name"] == $display_name)
        | select((.["lifecycle-state"] // "") != "TERMINATED")
        | .id
    ' 2>/dev/null | head -1
}

create_instance_background_task() {
    local config_file="${1:-$CREATE_INSTANCE_CONFIG}"
    local retry_interval="${2:-10}"

    if [[ ! "$retry_interval" =~ ^[0-9]+$ ]]; then
        log_error "重试间隔必须为正整数"
        return 1
    fi

    if ! validate_create_instance_config "$config_file"; then
        return 1
    fi

    local display_name shape target_ocpus target_memory compartment_id
    display_name=$(jq -r '.displayName // "N/A"' "$config_file")
    shape=$(jq -r '.shape // "N/A"' "$config_file")
    target_ocpus=$(jq -r '.ocpus // null' "$config_file")
    target_memory=$(jq -r '.memoryInGBs // null' "$config_file")
    compartment_id=$(jq -r '.compartmentId // ""' "$config_file")

    if ! check_existing_create_task "$display_name"; then
        return 1
    fi

    init_task_dir

    local task_id
    task_id="$(date +%Y%m%d-%H%M%S)_$$"
    local task_path="$TASK_DIR/$task_id"
    mkdir -p "$task_path"

    jq -n \
        --arg task_id "$task_id" \
        --arg task_type "create_instance" \
        --arg config_file "$config_file" \
        --arg display_name "$display_name" \
        --arg shape "$shape" \
        --arg compartment_id "$compartment_id" \
        --argjson target_ocpus "$target_ocpus" \
        --argjson target_memory "$target_memory" \
        --argjson retry_interval "$retry_interval" \
        --arg create_time "$(date -Iseconds)" \
        '{
            task_id: $task_id,
            task_type: $task_type,
            config_file: $config_file,
            display_name: $display_name,
            shape: $shape,
            compartment_id: $compartment_id,
            target_ocpus: $target_ocpus,
            target_memory: $target_memory,
            retry_interval: $retry_interval,
            create_time: $create_time,
            status: "running"
        }' > "$task_path/task.info"

    (
        exec_create_instance_task "$task_id" "$config_file" "$retry_interval"
    ) &>"$task_path/task.log" &

    local pid=$!
    printf '%s\n' "$pid" > "$task_path/task.pid"

    log_success "创建实例后台任务已创建"
    printf '%s\n' ""
    printf '%s\n' "任务 ID: $task_id"
    printf '%s\n' "实例名称: $display_name"
    printf '%s\n' "日志文件: $task_path/task.log"
    printf '%s\n' ""
    printf '%b\n' "${CYAN}提示: 任务将在后台持续执行，可在主菜单“管理后台任务”中查看进度${NC}"
    printf '%s\n' ""
}

exec_create_instance_task() {
    local task_id="$1"
    local config_file="$2"
    local retry_interval="$3"
    local task_path="$TASK_DIR/$task_id"
    local log_file="$task_path/task.log"

    log_info() {
        printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$log_file"
    }

    log_error() {
        printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$log_file"
    }

    log_success() {
        printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1" >> "$log_file"
    }

    update_task_status() {
        local attempt="$1"
        local last_status="$2"
        local last_error="$3"
        local created_instance_id="$4"

        if [[ -f "$task_path/task.info" ]]; then
            local temp_file="$task_path/task.info.tmp"
            jq --argjson attempt "$attempt" \
               --arg status "$last_status" \
               --arg error "$last_error" \
               --arg created_instance_id "$created_instance_id" \
               --arg time "$(date -Iseconds)" \
               '.attempt = $attempt |
                .last_status = $status |
                .last_error = $error |
                .last_attempt_time = $time |
                .created_instance_ocid = (if $created_instance_id == "" then .created_instance_ocid else $created_instance_id end)' \
               "$task_path/task.info" > "$temp_file"
            mv "$temp_file" "$task_path/task.info"
        fi
    }

    if ! validate_create_instance_config "$config_file"; then
        update_task_status 0 "failed" "配置文件校验失败" ""
        jq '.status = "failed" | .end_time = "'"$(date -Iseconds)"'"' \
            "$task_path/task.info" > "$task_path/task.info.tmp"
        mv "$task_path/task.info.tmp" "$task_path/task.info"
        exit 1
    fi

    local display_name compartment_id
    display_name=$(jq -r '.displayName // "N/A"' "$config_file")
    compartment_id=$(jq -r '.compartmentId // ""' "$config_file")
    local attempt
    attempt=$(jq -r '.attempt // 0' "$task_path/task.info")

    log_info "后台创建实例任务启动"
    log_info "实例名称: $display_name"
    log_info "配置文件: $config_file"
    log_info "重试间隔: ${retry_interval}秒"
    log_info "OCI 创建请求超时: connection=${OCI_CREATE_CONNECTION_TIMEOUT}s, read=${OCI_CREATE_READ_TIMEOUT}s, max_retries=${OCI_CREATE_MAX_RETRIES}, max_wait=${OCI_CREATE_MAX_WAIT_SECONDS}s"

    while true; do
        local existing_instance_id
        existing_instance_id=$(find_existing_created_instance "$compartment_id" "$display_name" 2>/dev/null || true)
        if [[ -n "$existing_instance_id" && "$existing_instance_id" != "null" ]]; then
            log_success "检测到同名实例已存在，视为创建成功"
            log_info "实例 OCID: $existing_instance_id"
            update_task_status "$attempt" "success" "" "$existing_instance_id"
            send_create_success_notification "$config_file" "$existing_instance_id"
            notify_created_instance_boot_result "$config_file" "$existing_instance_id" || true
            jq '.status = "completed" | .end_time = "'"$(date -Iseconds)"'"' \
                "$task_path/task.info" > "$task_path/task.info.tmp"
            mv "$task_path/task.info.tmp" "$task_path/task.info"
            exit 0
        fi

        ((attempt++))
        log_info "第 $attempt 次尝试创建实例..."

        local result
        result=$(launch_instance_from_config "$config_file" 2>&1)
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            local instance_id
            instance_id=$(printf '%s\n' "$result" | jq -r '.data.id // empty' 2>/dev/null)
            log_success "实例创建成功"
            [[ -n "$instance_id" ]] && log_info "实例 OCID: $instance_id"
            update_task_status "$attempt" "success" "" "$instance_id"
            send_create_success_notification "$config_file" "$instance_id"
            [[ -n "$instance_id" ]] && notify_created_instance_boot_result "$config_file" "$instance_id" || true
            jq '.status = "completed" | .end_time = "'"$(date -Iseconds)"'"' \
                "$task_path/task.info" > "$task_path/task.info.tmp"
            mv "$task_path/task.info.tmp" "$task_path/task.info"
            exit 0
        fi

        local error_msg
        error_msg=$(printf '%s\n' "$result" | jq -r '.message // .error.message // empty' 2>/dev/null)
        [[ -z "$error_msg" ]] && error_msg="$result"
        log_error "实例创建失败: $error_msg"
        update_task_status "$attempt" "failed" "$error_msg" ""
        log_info "等待 ${retry_interval} 秒后重试..."
        sleep "$retry_interval"
    done
}

create_instance_from_saved_config() {
    local config_file="$CREATE_INSTANCE_CONFIG"

    show_header
    printf '%b\n' "${BOLD}[5] 创建实例 - 使用已保存配置${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    if [[ ! -f "$config_file" && -f "$CREATE_INSTANCE_DRAFT_CONFIG" ]]; then
        log_warn "当前只有未确认草稿，尚无正式创建配置"
        printf '%s\n' ""
        printf '%s\n' "提示:"
        printf '%s\n' "  - 先进入“获取关键参数并保存”并确认完成"
        printf '%s\n' "  - 或手动将草稿确认后再创建实例"
        pause
        return 1
    fi

    if ! validate_create_instance_config "$config_file"; then
        pause
        return 1
    fi

    show_create_instance_config_summary "$config_file"

    printf '%s\n' "创建方式:"
    printf '%s\n' "  1) 前台执行一次"
    printf '%s\n' "  2) 后台持续重试"
    printf '%s\n' "  0) 返回"
    printf '%s\n' ""

    local create_mode
    read -p "请选择创建方式 [默认: 2]: " create_mode
    create_mode="${create_mode:-2}"

    case "$create_mode" in
        1)
            local display_name retry_interval result exit_code instance_id
            display_name=$(jq -r '.displayName // "N/A"' "$config_file")
            retry_interval=$(jq -r '.retryInterval // 10' "$config_file")

            if ! check_existing_create_task "$display_name"; then
                pause
                return 1
            fi

            printf '%s\n' ""
            log_info "开始创建实例: $display_name"
            result=$(launch_instance_from_config "$config_file" 2>&1)
            exit_code=$?

            if [[ $exit_code -eq 0 ]]; then
                instance_id=$(printf '%s\n' "$result" | jq -r '.data.id // empty' 2>/dev/null)
                log_success "实例创建成功"
                [[ -n "$instance_id" ]] && printf '%s\n' "实例 OCID: $instance_id"
                send_create_success_notification "$config_file" "$instance_id"
                [[ -n "$instance_id" ]] && notify_created_instance_boot_result "$config_file" "$instance_id" || true
            else
                log_error "实例创建失败"
                printf '%s\n' ""
                printf '%s\n' "错误输出:"
                printf '%s\n' "$result"
                printf '%s\n' ""
                read -p "是否创建后台任务自动重试? [Y/n]: " -r
                [[ -z "$REPLY" ]] && REPLY="y"
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    create_instance_background_task "$config_file" "$retry_interval"
                fi
            fi
            ;;
        2)
            local retry_interval
            retry_interval=$(jq -r '.retryInterval // 10' "$config_file")
            read -p "重试间隔 (秒) [默认: ${retry_interval}]: " REPLY
            retry_interval="${REPLY:-$retry_interval}"
            if [[ ! "$retry_interval" =~ ^[0-9]+$ ]]; then
                log_error "重试间隔必须为正整数"
                pause
                return 1
            fi
            create_instance_background_task "$config_file" "$retry_interval"
            ;;
        0)
            return 0
            ;;
        *)
            log_error "无效选项"
            ;;
    esac

    pause
}

select_default_or_first_value() {
    local default_value="$1"
    shift
    local values=("$@")
    local value

    if [[ -n "$default_value" && "$default_value" != "null" ]]; then
        for value in "${values[@]}"; do
            if [[ "$value" == "$default_value" ]]; then
                printf '%s\n' "$default_value"
                return 0
            fi
        done
    fi

    [[ ${#values[@]} -gt 0 ]] || return 1
    printf '%s\n' "${values[0]}"
}

get_default_availability_domain() {
    local default_value="$1"
    local values=()
    local ad_name

    while IFS= read -r ad_name; do
        [[ -n "$ad_name" ]] && values+=("$ad_name")
    done < <(oci iam availability-domain list --all --output json 2>/dev/null | jq -r '.data[].name // empty')

    select_default_or_first_value "$default_value" "${values[@]}"
}

get_default_subnet_id() {
    local compartment_id="$1"
    local default_value="$2"
    local values=()
    local subnet_id

    while IFS= read -r subnet_id; do
        [[ -n "$subnet_id" ]] && values+=("$subnet_id")
    done < <(oci network subnet list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null | jq -r '.data[].id // empty')

    select_default_or_first_value "$default_value" "${values[@]}"
}

get_default_image_id() {
    local compartment_id="$1"
    local operating_system="$2"
    local operating_system_version="$3"
    local shape="$4"
    local default_value="$5"
    local values=()
    local image_id
    local cmd=(
        oci compute image list
        --compartment-id "$compartment_id"
        --operating-system "$operating_system"
        --sort-by TIMECREATED
        --sort-order DESC
        --all
        --output json
    )

    if [[ -n "$operating_system_version" ]]; then
        cmd+=(--operating-system-version "$operating_system_version")
    fi

    if [[ -n "$shape" ]]; then
        while IFS= read -r image_id; do
            [[ -n "$image_id" ]] && values+=("$image_id")
        done < <("${cmd[@]}" --shape "$shape" 2>/dev/null | jq -r '.data[].id // empty' | head -20)
    fi

    if [[ ${#values[@]} -eq 0 ]]; then
        while IFS= read -r image_id; do
            [[ -n "$image_id" ]] && values+=("$image_id")
        done < <("${cmd[@]}" 2>/dev/null | jq -r '.data[].id // empty' | head -20)
    fi

    select_default_or_first_value "$default_value" "${values[@]}"
}

prepare_beginner_create_config() {
    local config_file="$1"
    local source_config="$2"

    load_beginner_defaults
    load_create_instance_defaults "$source_config"

    local compartment_id availability_domain subnet_id image_os image_os_version shape ocpus memory_gbs
    local boot_volume_size boot_volume_vpus_per_gb ssh_public_key display_name assign_public_ip retry_interval image_id

    compartment_id="$CREATE_COMPARTMENT_ID"
    image_os="$BEGINNER_CREATE_IMAGE_OS_DEFAULT"
    image_os_version="$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT"
    [[ -z "$image_os" || "$image_os" == "null" ]] && image_os="$BEGINNER_CREATE_IMAGE_OS_DEFAULT"
    [[ -z "$image_os_version" || "$image_os_version" == "null" ]] && image_os_version="$BEGINNER_CREATE_IMAGE_OS_VERSION_DEFAULT"
    shape="$BEGINNER_CREATE_SHAPE_DEFAULT"
    [[ -z "$shape" || "$shape" == "null" ]] && shape="$BEGINNER_CREATE_SHAPE_DEFAULT"
    ocpus="$BEGINNER_CREATE_OCPUS_DEFAULT"
    memory_gbs="$BEGINNER_CREATE_MEMORY_GB_DEFAULT"
    boot_volume_size="$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT"
    if [[ "$boot_volume_size" == "150" ]]; then
        log_info "检测到旧的一键创建默认启动盘 150 GB，已自动改为 ${BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT} GB"
        boot_volume_size="$BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT"
    fi
    boot_volume_vpus_per_gb="$BEGINNER_CREATE_BOOT_VOLUME_VPUS_DEFAULT"
    ssh_public_key="$CREATE_SSH_PUBLIC_KEY"
    display_name="$CREATE_DISPLAY_NAME"
    assign_public_ip="$CREATE_ASSIGN_PUBLIC_IP"
    retry_interval="$CREATE_RETRY_INTERVAL"

    if [[ -z "$compartment_id" || "$compartment_id" == "null" ]]; then
        log_error "未找到默认区间 OCID，请先初始化 OCI 配置或执行“获取关键参数并保存”"
        return 1
    fi

    log_info "正在按“获取关键参数并保存”的方式查询默认可用性域..."
    availability_domain="$(get_default_availability_domain "$CREATE_AVAILABILITY_DOMAIN")"
    if [[ -z "$availability_domain" || "$availability_domain" == "null" ]]; then
        log_error "未查询到可用性域，请手动确认区间权限或先执行“获取关键参数并保存”"
        return 1
    fi

    log_info "正在按“获取关键参数并保存”的方式查询默认子网..."
    subnet_id="$(get_default_subnet_id "$compartment_id" "$CREATE_SUBNET_ID")"
    if [[ -z "$subnet_id" || "$subnet_id" == "null" ]]; then
        log_warn "未查询到可用子网"
        read -p "是否现在创建一个子网? [Y/n]: " -r
        [[ -z "$REPLY" ]] && REPLY="y"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if create_subnet_interactive "$compartment_id" "$availability_domain"; then
                subnet_id="$SELECT_RESULT"
            else
                log_warn "未创建子网，将跳过 subnetId 参数继续生成一键配置"
                subnet_id=""
            fi
        else
            log_warn "已跳过创建子网，将不设置 subnetId 参数"
            subnet_id=""
        fi
    fi
    if ! ensure_create_ssh_public_key "$ssh_public_key"; then
        return 1
    fi
    ssh_public_key="$SELECT_RESULT"
    display_name="$(create_timestamped_display_name "$display_name")"

    log_info "正在按“获取关键参数并保存”的方式查询镜像: ${image_os} ${image_os_version}"
    image_id="$(get_default_image_id "$compartment_id" "$image_os" "$image_os_version" "$shape" "$CREATE_IMAGE_ID")"
    if [[ -z "$image_id" || "$image_id" == "null" ]]; then
        log_error "未找到可用镜像: ${image_os} ${image_os_version}"
        return 1
    fi

    save_create_instance_config \
        "$config_file" \
        "$compartment_id" \
        "$availability_domain" \
        "$subnet_id" \
        "$image_id" \
        "$image_os" \
        "$image_os_version" \
        "$ssh_public_key" \
        "$shape" \
        "$ocpus" \
        "$memory_gbs" \
        "$boot_volume_size" \
        "$boot_volume_vpus_per_gb" \
        "$display_name" \
        "$assign_public_ip" \
        "$retry_interval"
}

beginner_create_instance() {
    local source_config="$CREATE_INSTANCE_CONFIG"
    local quick_config="${DATA_DIR}/create_instance_beginner.json"

    show_header
    printf '%b\n' "${BOLD}[5] 创建实例 - 一键创建实例${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    if [[ ! -f "$source_config" && -f "$CREATE_INSTANCE_DRAFT_CONFIG" ]]; then
        source_config="$CREATE_INSTANCE_DRAFT_CONFIG"
    fi

    if ! prepare_beginner_create_config "$quick_config" "$source_config"; then
        printf '%s\n' ""
        printf '%s\n' "提示: 一键创建实例会复用区间默认值，并查询可用性域、子网和镜像 ID。"
        printf '%s\n' "      查询结果中如包含已保存值则继续使用已保存值，否则使用第一个查询结果。"
        printf '%s\n' "      如查询不到，请先确认 OCI 权限，或选择“获取关键参数并保存”手动处理。"
        pause
        return 1
    fi

    show_create_instance_config_summary "$quick_config"
    printf '%s\n' "执行方式:"
    printf '%s\n' "  1) 前台执行一次"
    printf '%s\n' "  2) 后台持续重试"
    printf '%s\n' "  0) 返回"
    printf '%s\n' ""
    read -p "请选择执行方式 [默认: 2]: " -r
    local create_mode="${REPLY:-2}"

    case "$create_mode" in
        1)
            local result exit_code instance_id
            log_info "开始一键创建实例..."
            result=$(launch_instance_from_config "$quick_config" 2>&1)
            exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                instance_id=$(printf '%s\n' "$result" | jq -r '.data.id // empty' 2>/dev/null)
                log_success "实例创建成功"
                [[ -n "$instance_id" ]] && printf '%s\n' "实例 OCID: $instance_id"
                send_create_success_notification "$quick_config" "$instance_id"
                [[ -n "$instance_id" ]] && notify_created_instance_boot_result "$quick_config" "$instance_id" || true
            else
                log_error "实例创建失败"
                printf '%s\n' "$result"
                printf '%s\n' ""
                read -p "是否创建后台任务自动重试? [Y/n]: " -r
                [[ -z "$REPLY" ]] && REPLY="y"
                [[ $REPLY =~ ^[Yy]$ ]] && create_instance_background_task "$quick_config" "$(jq -r '.retryInterval // 10' "$quick_config")"
            fi
            ;;
        2)
            create_instance_background_task "$quick_config" "$(jq -r '.retryInterval // 10' "$quick_config")"
            ;;
        0)
            return 0
            ;;
        *)
            log_error "无效选项"
            ;;
    esac

    pause
}

manage_create_instance() {
    while true; do
        show_header
        printf '%b\n' "${BOLD}[5] 创建实例${NC}"
        printf '%s\n' "========================================"
        printf '%s\n' ""

        if [[ -f "$CREATE_INSTANCE_CONFIG" ]]; then
            local saved_display_name
            saved_display_name=$(jq -r '.displayName // "未命名实例"' "$CREATE_INSTANCE_CONFIG" 2>/dev/null)
            printf '%b\n' "${GREEN}✓${NC} 已确认配置: $saved_display_name"
        else
            printf '%b\n' "${YELLOW}!${NC} 尚未保存已确认的创建实例配置"
        fi
        if [[ -f "$CREATE_INSTANCE_DRAFT_CONFIG" ]]; then
            local draft_display_name
            draft_display_name=$(jq -r '.displayName // "未命名实例"' "$CREATE_INSTANCE_DRAFT_CONFIG" 2>/dev/null)
            printf '%b\n' "${YELLOW}!${NC} 存在未完成草稿: $draft_display_name"
        fi
        printf '%s\n' ""
        load_beginner_defaults
        printf '%s\n' "一键创建默认配置: ${BEGINNER_CREATE_SHAPE_DEFAULT} / ${BEGINNER_CREATE_OCPUS_DEFAULT} OCPU / ${BEGINNER_CREATE_MEMORY_GB_DEFAULT} GB / ${BEGINNER_CREATE_BOOT_VOLUME_GB_DEFAULT} GB 启动盘"
        printf '%s\n' ""
        printf '%s\n' "操作选项:"
        printf '%s\n' "  1) 一键创建实例"
        printf '%s\n' "  2) 获取关键参数并保存"
        printf '%s\n' "  3) 查看已保存配置"
        printf '%s\n' "  4) 使用已保存配置创建实例"
        printf '%s\n' "  5) 修改一键创建实例默认值"
        printf '%s\n' "  0) 返回主菜单"
        printf '%s\n' ""

        read -p "请选择操作: " -r

        case $REPLY in
            1) beginner_create_instance ;;
            2) configure_create_instance_params ;;
            3) show_saved_create_instance_config ;;
            4) create_instance_from_saved_config ;;
            5) configure_beginner_defaults "create" ;;
            0) return 0 ;;
            *)
                log_error "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ================================
# 管理实例
# ================================
manage_instances() {
    # 首先获取实例列表
    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    while true; do
        show_header
        printf '%b\n' "${BOLD}[4] 管理实例${NC}"
        printf '%s\n' "========================================"
        printf '%s\n' ""

        # 列出实例
        log_info "正在获取实例列表..."

        # 获取租户 ID
        local tenancy_id
        tenancy_id=$(grep "^tenancy=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)

        if [[ -z "$tenancy_id" ]]; then
            log_error "无法从配置文件读取租户 ID"
            pause
            return 1
        fi

        local instances_json
        instances_json=$(oci compute instance list \
            --compartment-id "$tenancy_id" \
            --output json 2>/dev/null)

        if [[ $? -ne 0 || -z "$instances_json" ]]; then
            log_error "获取实例列表失败"
            pause
            return 1
        fi

        local instance_count
        instance_count=$(printf '%s\n' "$instances_json" | jq '.data | length')

        if [[ "$instance_count" -eq 0 ]]; then
            log_warn "未找到任何实例"
            pause
            return 0
        fi

        log_success "找到 $instance_count 个实例"
        printf '%s\n' ""

        # 显示实例列表（卡片式）- 只获取一次数据
        printf '%b\n' "${BOLD}实例列表${NC}"
        printf '%b\n' "${BOLD}========================================${NC}"

        # 清空并重新填充全局数组
        INSTANCE_OCIDS=()
        local idx=0
        while IFS= read -r instance_ocid; do
            ((idx++))
            INSTANCE_OCIDS[$idx]="$instance_ocid"

            # 获取实例详细信息
            local detail_json
            detail_json=$(oci compute instance get \
                --instance-id "$instance_ocid" \
                --output json 2>/dev/null)

            if [[ -n "$detail_json" ]]; then
                local name state ocpus memory shape
                name=$(printf '%s\n' "$detail_json" | jq -r '.data["display-name"] // "N/A"')
                state=$(printf '%s\n' "$detail_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                ocpus=$(printf '%s\n' "$detail_json" | jq -r '.data["shape-config"].ocpus // "N/A"')
                memory=$(printf '%s\n' "$detail_json" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
                shape=$(printf '%s\n' "$detail_json" | jq -r '.data.shape // "N/A"')

                # 状态颜色
                local state_color
                case "$state" in
                    RUNNING) state_color="${GREEN}" ;;
                    STOPPED) state_color="${RED}" ;;
                    *) state_color="${YELLOW}" ;;
                esac

                # 显示实例卡片（完整 OCID）
                printf '%b\n' "序号 #${idx}  ${name}"
                printf '%b\n' "  状态:  ${state_color}${state}${NC}"
                printf '%b\n' "  配置:  ${ocpus} OCPU / ${memory} GB"
                printf '%b\n' "  形状:  ${shape}"
                printf '%b\n' "  OCID:  ${instance_ocid}"
                printf '%s\n' ""
            fi
        done < <(printf '%s\n' "$instances_json" | jq -r '.data[].id')

        printf '%b\n' "${BOLD}========================================${NC}"
        printf '%b\n' "${CYAN}后续操作请输入实例名前面的序号，例如看到“序号 #1”就输入 1。${NC}"
        printf '%s\n' ""

        # 内层循环：操作选项（不重新获取数据）
        while true; do
            load_beginner_defaults
            printf '%s\n' "操作选项:"
            printf '%s\n' "  1) 一键修改实例配置 (${BEGINNER_UPDATE_OCPUS_DEFAULT} OCPU / ${BEGINNER_UPDATE_MEMORY_GB_DEFAULT} GB / ${BEGINNER_UPDATE_BOOT_VOLUME_GB_DEFAULT} GB 启动盘)"
            printf '%s\n' "  2) 查看实例完整配置    (JSON格式)"
            printf '%s\n' "  3) 输入配置参数更新    (交互式输入)"
            printf '%s\n' "  4) 使用配置文件更新    (JSON文件)"
            printf '%s\n' "  5) 停止实例"
            printf '%s\n' "  6) 启动实例"
            printf '%s\n' "  7) 修改一键修改实例配置默认值"
            printf '%s\n' "  0) 返回主菜单"
            printf '%s\n' ""

            read -p "请选择操作: " -r

            case $REPLY in
                1)
                    beginner_update_instance "$instance_count"
                    ;;
                2)
                    # 查看完整配置 (JSON)
                    read_instance_list_choice choice "$instance_count"
                    if is_valid_list_choice "$choice" "$instance_count"; then
                        local selected_ocid="${INSTANCE_OCIDS[$choice]}"

                        log_info "获取实例配置..."
                        local detail_json
                        detail_json=$(oci compute instance get \
                            --instance-id "$selected_ocid" \
                            --output json 2>/dev/null)

                        if [[ -n "$detail_json" ]]; then
                            printf '%s\n' ""
                            printf '%b\n' "${BOLD}========================================${NC}"
                            printf '%b\n' "${BOLD}实例完整配置 (JSON) #${choice}${NC}"
                            printf '%b\n' "${BOLD}========================================${NC}"
                            printf '%s\n' "$detail_json" | jq '.'
                            printf '%s\n' ""

                            read -p "是否保存到文件? [Y/n]: " save_json
                            [[ -z "$save_json" ]] && save_json="y"

                            if [[ $save_json =~ ^[Yy]$ ]]; then
                                local name
                                name=$(printf '%s\n' "$detail_json" | jq -r '.data["display-name"] // "instance"')
                                local json_file="instance_${name}_$(date +%Y%m%d-%H%M%S).json"
                                printf '%s\n' "$detail_json" > "$json_file"
                                log_success "已保存到: $json_file"
                                printf '%s\n' ""
                            fi
                        else
                            log_error "获取实例配置失败"
                        fi
                    else
                        log_invalid_list_choice "$choice" "$instance_count"
                    fi
                    ;;
                3)
                    # 输入配置参数更新 - 子菜单
                    update_by_input_params "$instance_count"
                    ;;
                4)
                    # 使用配置文件更新 - 子菜单
                    update_by_config_file "$instance_count"
                    ;;
                5)
                    # 停止实例
                    read_instance_list_choice choice "$instance_count"
                    if is_valid_list_choice "$choice" "$instance_count"; then
                        local selected_ocid="${INSTANCE_OCIDS[$choice]}"
                        INSTANCE_OCID="$selected_ocid"
                        stop_instance
                    else
                        log_invalid_list_choice "$choice" "$instance_count"
                    fi
                    ;;
                6)
                    # 启动实例
                    read_instance_list_choice choice "$instance_count"
                    if is_valid_list_choice "$choice" "$instance_count"; then
                        local selected_ocid="${INSTANCE_OCIDS[$choice]}"
                        INSTANCE_OCID="$selected_ocid"
                        start_instance
                    else
                        log_invalid_list_choice "$choice" "$instance_count"
                    fi
                    ;;
                7)
                    configure_beginner_defaults "update"
                    ;;
                0)
                    return 0
                    ;;
                *)
                    log_error "无效选项"
                    ;;
            esac
        done
    done
}

# ================================
# 输入配置参数更新 (子菜单)
# ================================
update_by_input_params() {
    local instance_count=$1

    while true; do
        printf '%s\n' ""
        printf '%b\n' "${BOLD}----------------------------------------${NC}"
        printf '%b\n' "${BOLD}输入配置参数更新${NC}"
        printf '%b\n' "${BOLD}----------------------------------------${NC}"
        printf '%s\n' ""
        printf '%s\n' "更新方式:"
        printf '%s\n' "  1) 直接更新            (更新成功自动重启)"
        printf '%s\n' "  2) 完整更新流程        (停止→更新→启动)"
        printf '%s\n' "  0) 返回上一级"
        printf '%s\n' ""

        read -p "请选择更新方式: " -r

        case $REPLY in
            1)
                # 直接更新
                read_instance_list_choice choice "$instance_count"
                if is_valid_list_choice "$choice" "$instance_count"; then
                    INSTANCE_OCID="${INSTANCE_OCIDS[$choice]}"
                    update_instance_config_direct
                else
                    log_invalid_list_choice "$choice" "$instance_count"
                fi
                ;;
            2)
                # 完整更新流程
                read_instance_list_choice choice "$instance_count"
                if is_valid_list_choice "$choice" "$instance_count"; then
                    INSTANCE_OCID="${INSTANCE_OCIDS[$choice]}"
                    update_instance_config_full
                else
                    log_invalid_list_choice "$choice" "$instance_count"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                log_error "无效选项"
                ;;
        esac
    done
}

# ================================
# 使用配置文件更新 (子菜单)
# ================================
update_by_config_file() {
    local instance_count=$1

    while true; do
        printf '%s\n' ""
        printf '%b\n' "${BOLD}----------------------------------------${NC}"
        printf '%b\n' "${BOLD}使用配置文件更新${NC}"
        printf '%b\n' "${BOLD}----------------------------------------${NC}"
        printf '%s\n' ""
        printf '%s\n' "操作选项:"
        printf '%s\n' "  1) 生成配置模板        (从实例生成 JSON 模板)"
        printf '%s\n' "  2) 直接更新            (使用配置文件，不停止实例)"
        printf '%s\n' "  3) 完整更新流程        (停止→更新→启动)"
        printf '%s\n' "  0) 返回上一级"
        printf '%s\n' ""

        read -p "请选择操作: " -r

        case $REPLY in
            1)
                # 生成配置模板
                read_instance_list_choice choice "$instance_count" "true"
                local selected_ocid=""
                if is_valid_list_choice "$choice" "$instance_count"; then
                    selected_ocid="${INSTANCE_OCIDS[$choice]}"
                fi
                generate_update_template "$selected_ocid"
                ;;
            2)
                # 直接更新 (使用配置文件)
                update_instance_from_file "direct"
                ;;
            3)
                # 完整更新流程 (使用配置文件)
                update_instance_from_file "full"
                ;;
            0)
                return 0
                ;;
            *)
                log_error "无效选项"
                ;;
        esac
    done
}

# ================================
# 管理后台任务
# ================================
manage_background_tasks() {
    while true; do
        show_header
        printf '%b\n' "${BOLD}[6] 管理后台任务${NC}"
        printf '%s\n' "========================================"
        printf '%s\n' ""

        # 列出所有任务
        list_background_tasks

        local task_count=${#TASK_IDS[@]}

        printf '%s\n' "操作选项:"
        printf '%s\n' "  1) 查看任务详情"
        printf '%s\n' "  2) 停止任务"
        printf '%s\n' "  3) 恢复任务"
        printf '%s\n' "  4) 删除任务记录"
        printf '%s\n' "  5) 刷新列表"
        printf '%s\n' "  0) 返回主菜单"
        printf '%s\n' ""

        read -p "请选择操作: " -r

        case $REPLY in
            1)
                if [[ $task_count -eq 0 ]]; then
                    pause_no_background_tasks
                    continue
                fi
                read_task_list_choice task_num "$task_count"
                if is_valid_list_choice "$task_num" "$task_count"; then
                    local task_id="${TASK_IDS[$task_num]}"
                    view_task_detail "$task_id"
                else
                    log_invalid_list_choice "$task_num" "$task_count"
                fi
                ;;
            2)
                if [[ $task_count -eq 0 ]]; then
                    pause_no_background_tasks
                    continue
                fi
                read_task_list_choice task_num "$task_count"
                if is_valid_list_choice "$task_num" "$task_count"; then
                    local task_id="${TASK_IDS[$task_num]}"
                    stop_task "$task_id"
                else
                    log_invalid_list_choice "$task_num" "$task_count"
                fi
                read -p "按回车键继续..." -r
                ;;
            3)
                if [[ $task_count -eq 0 ]]; then
                    pause_no_background_tasks
                    continue
                fi
                read_task_list_choice task_num "$task_count"
                if is_valid_list_choice "$task_num" "$task_count"; then
                    local task_id="${TASK_IDS[$task_num]}"
                    resume_task "$task_id"
                else
                    log_invalid_list_choice "$task_num" "$task_count"
                fi
                read -p "按回车键继续..." -r
                ;;
            4)
                if [[ $task_count -eq 0 ]]; then
                    pause_no_background_tasks
                    continue
                fi
                read_task_list_choice task_num "$task_count"
                if is_valid_list_choice "$task_num" "$task_count"; then
                    local task_id="${TASK_IDS[$task_num]}"
                    delete_task "$task_id"
                else
                    log_invalid_list_choice "$task_num" "$task_count"
                fi
                read -p "按回车键继续..." -r
                ;;
            5)
                # 刷新列表，重新显示
                continue
                ;;
            0)
                return 0
                ;;
            *)
                log_error "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ================================
# 显示帮助
# ================================
show_help() {
    show_header
    printf '%b\n' "${BOLD}[H] 帮助信息${NC}"
    printf '%s\n' "========================================"
    printf '%s\n' ""

    printf '%b\n' "${BOLD}主菜单功能说明:${NC}"
    printf '%s\n' ""
    printf '%s\n' "  [1] 检查 OCI 环境"
    printf '%s\n' "      检查 OCI CLI、jq、配置文件和连接状态"
    printf '%s\n' ""
    printf '%s\n' "  [2] 初始化 OCI 配置"
    printf '%s\n' "      配置 OCI CLI (${OCI_CONFIG_FILE})"
    printf '%s\n' "      需要提供: 用户 OCID、指纹、租户 OCID、区域、私钥路径"
    printf '%s\n' ""
    printf '%s\n' "  [3] 查看 OCI 配置"
    printf '%s\n' "      显示 OCI CLI 配置文件内容"
    printf '%s\n' "      测试 OCI 连接"
    printf '%s\n' ""
    printf '%s\n' "  [4] 管理实例"
    printf '%s\n' "      列出所有实例，支持以下操作:"
    printf '%s\n' "        - 查看实例完整配置 (JSON)"
    printf '%s\n' "        - 输入配置参数更新 (交互式)"
    printf '%s\n' "        - 使用配置文件更新 (JSON)"
    printf '%s\n' "        - 停止/启动实例"
    printf '%s\n' ""
    printf '%s\n' "  [5] 创建实例"
    printf '%s\n' "      获取创建实例的关键参数并保存配置"
    printf '%s\n' "      使用已保存配置执行前台或后台创建"
    printf '%s\n' "      后台创建失败后自动重试并发送通知"
    printf '%s\n' ""
    printf '%s\n' "  [6] 管理后台任务"
    printf '%s\n' "      查看所有后台任务，支持以下操作:"
    printf '%s\n' "        - 查看任务详情和日志"
    printf '%s\n' "        - 停止/恢复/删除任务"
    printf '%s\n' "        - 实时查看日志"
    printf '%s\n' ""
    printf '%s\n' "  [7] 配置通知"
    printf '%s\n' "      配置邮件或 Telegram 机器人通知"
    printf '%s\n' "      更新/创建成功后按所选方式自动发送通知"
    printf '%s\n' "      支持测试通知发送"
    printf '%s\n' ""
    printf '%s\n' "  [8] 卸载脚本"
    printf '%s\n' "      交互式卸载辅助依赖、OCI 配置、日志和脚本数据"
    printf '%s\n' "      可选删除本地脚本文件"
    printf '%s\n' ""
    printf '%b\n' "${BOLD}更新方式说明:${NC}"
    printf '%s\n' ""
    printf '%s\n' "  输入配置参数更新:"
    printf '%s\n' "    - 直接更新: 不停止实例，直接修改配置"
    printf '%s\n' "    - 完整流程: 停止→更新→启动"
    printf '%s\n' ""
    printf '%s\n' "  使用配置文件更新:"
    printf '%s\n' "    - 生成 JSON 配置模板"
    printf '%s\n' "    - 直接更新或完整流程"
    printf '%s\n' ""
    printf '%s\n' "  创建实例:"
    printf '%s\n' "    - 保存关键参数到 create_instance_config.json"
    printf '%s\n' "    - 使用已保存配置前台执行或后台重试"
    printf '%s\n' ""
    printf '%b\n' "${BOLD}配置文件位置:${NC}"
    printf '%s\n' "   OCI CLI 配置: $OCI_CONFIG_FILE"
    printf '%s\n' "   私钥文件:     $OCI_KEY_FILE_DEFAULT"
    printf '%s\n' "   数据目录:     $DATA_DIR"
    printf '%s\n' "   创建配置:     $CREATE_INSTANCE_CONFIG"
    printf '%s\n' "   通知配置:     $EMAIL_CONFIG_FILE"
    printf '%s\n' "   任务目录:     $TASK_DIR/"
    printf '%s\n' ""
    printf '%b\n' "${BOLD}如何获取 OCI 配置信息:${NC}"
    printf '%s\n' "   1. 登录 OCI 控制台: https://cloud.oracle.com"
    printf '%s\n' "   2. 进入 用户设置 -> API 密钥"
    printf '%s\n' "   3. 添加或查看 API 密钥，获取:"
    printf '%s\n' "      - 用户 OCID"
    printf '%s\n' "      - 指纹"
    printf '%s\n' "      - 租户 OCID"
    printf '%s\n' "   4. 下载或创建私钥文件"
    printf '%s\n' ""
    printf '%s\n' "========================================"

    pause
}

# ================================
# 主菜单
# ================================
show_menu() {
    show_header

    # 显示配置状态
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        local region
        region=$(grep "^region=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)
        printf '%b\n' "${GREEN}✓${NC} OCI 配置已加载: 区域=${region:-未知}"
    else
        printf '%b\n' "${YELLOW}!${NC} 尚未配置，请先执行 [2] 初始化 OCI 配置"
    fi

    # 显示通知配置状态
    if [[ "${NOTIFY_METHOD:-email}" == "none" ]]; then
        printf '%b\n' "${YELLOW}!${NC} 通知已关闭"
    elif [[ -f "$EMAIL_CONFIG_FILE" ]]; then
        printf '%b\n' "${GREEN}✓${NC} 通知配置已加载: ${NOTIFY_METHOD:-email}"
    else
        printf '%b\n' "${YELLOW}!${NC} 通知未配置"
    fi

    if [[ -f "$CREATE_INSTANCE_CONFIG" ]]; then
        local create_name
        create_name=$(jq -r '.displayName // "未命名实例"' "$CREATE_INSTANCE_CONFIG" 2>/dev/null)
        printf '%b\n' "${GREEN}✓${NC} 创建实例正式配置已保存: ${create_name}"
    else
        printf '%b\n' "${YELLOW}!${NC} 创建实例正式配置未保存"
    fi

    if [[ -f "$CREATE_INSTANCE_DRAFT_CONFIG" ]]; then
        local draft_name
        draft_name=$(jq -r '.displayName // "未命名实例"' "$CREATE_INSTANCE_DRAFT_CONFIG" 2>/dev/null)
        printf '%b\n' "${YELLOW}!${NC} 创建实例草稿待确认: ${draft_name}"
    fi

    printf '%s\n' ""
    printf '%b\n' "${BOLD}请选择操作:${NC}"
    printf '%s\n' ""
    printf '%s\n' "  1) 检查 OCI 环境"
    printf '%s\n' "  2) 初始化 OCI 配置"
    printf '%s\n' "  3) 查看 OCI 配置"
    printf '%s\n' "  4) 管理实例"
    printf '%s\n' "  5) 创建实例"
    printf '%s\n' "  6) 管理后台任务"
    printf '%s\n' "  7) 配置通知"
    printf '%s\n' "  8) 卸载脚本"
    printf '%s\n' "  h) 帮助信息"
    printf '%s\n' ""
    printf '%s\n' "  0) 退出"
    printf '%s\n' ""
    printf '%s\n' "========================================"
}

# ================================
# 主循环
# ================================
main() {
    while true; do
        show_menu
        read -p "请输入选项: " -r
        printf '%s\n' ""

        case $REPLY in
            1) check_oci_environment ;;
            2) init_oci_config ;;
            3) view_oci_config ;;
            4) manage_instances ;;
            5) manage_create_instance ;;
            6) manage_background_tasks ;;
            7) configure_notifications && test_notification_config ;;
            8) uninstall_script ;;
            h|H) show_help ;;
            0)
                printf '%b\n' "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                printf '%b\n' "${RED}无效选项，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# ================================
# 异常处理
# ================================
trap 'printf "%b\n" "\n${YELLOW}操作已取消${NC}"; exit 0' INT TERM

# ================================
# 启动主程序
# ================================
# 加载通知配置
init_data_dir
configure_oci_cli_runtime_env
load_email_config

# 启动主菜单
main
