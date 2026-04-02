#!/bin/bash

# OCI 实例管理工具 - 交互式菜单版本
# 功能：提供交互式菜单管理 OCI 实例

# ================================
# 全局变量
# ================================
INSTANCE_OCIDS=()  # 实例 OCID 数组

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
# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI_CONFIG_FILE="$HOME/.oci/config"
UPDATE_JSON="${SCRIPT_DIR}/instance_update.json"
RETRY_SCRIPT="${SCRIPT_DIR}/retry_update.sh"
TASK_DIR="${SCRIPT_DIR}/tasks"
EMAIL_CONFIG_FILE="${SCRIPT_DIR}/email_config.conf"

# ================================
# 邮件通知配置（默认值）
# ================================
SMTP_HOST=""
SMTP_PORT=""
SMTP_USER=""
SMTP_PASS=""
EMAIL_TO=""

# ================================
# 加载邮件配置
# ================================
load_email_config() {
    if [[ -f "$EMAIL_CONFIG_FILE" ]]; then
        source "$EMAIL_CONFIG_FILE"
        return 0
    fi
    return 1
}

# ================================
# 保存邮件配置
# ================================
save_email_config() {
    mkdir -p "$(dirname "$EMAIL_CONFIG_FILE")"
    cat > "$EMAIL_CONFIG_FILE" << EOF
# 邮件通知配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_USER="${SMTP_USER}"
SMTP_PASS="${SMTP_PASS}"
EMAIL_TO="${EMAIL_TO}"
EOF
    chmod 600 "$EMAIL_CONFIG_FILE"
    log_success "邮件配置已保存到: $EMAIL_CONFIG_FILE"
}

# ================================
# 配置邮件参数
# ================================
configure_email() {
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}配置邮件通知${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    # 显示当前配置
    if [[ -f "$EMAIL_CONFIG_FILE" ]]; then
        echo -e "${CYAN}当前配置:${NC}"
        echo "  SMTP 服务器: ${SMTP_HOST:-未设置}"
        echo "  SMTP 端口: ${SMTP_PORT:-未设置}"
        echo "  发件人邮箱: ${SMTP_USER:-未设置}"
        echo "  收件人邮箱: ${EMAIL_TO:-未设置}"
        echo ""
    fi

    echo "请输入邮件配置（直接回车保持当前值）:"
    echo ""

    # SMTP 服务器
    local new_host
    read -p "SMTP 服务器 [当前: ${SMTP_HOST}]: " new_host
    SMTP_HOST="${new_host:-$SMTP_HOST}"

    # SMTP 端口
    local new_port
    read -p "SMTP 端口 [当前: ${SMTP_PORT}]: " new_port
    SMTP_PORT="${new_port:-$SMTP_PORT}"

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

    echo ""
    echo -e "${CYAN}配置摘要:${NC}"
    echo "  SMTP 服务器: ${SMTP_HOST}"
    echo "  SMTP 端口: ${SMTP_PORT}"
    echo "  发件人邮箱: ${SMTP_USER}"
    echo "  收件人邮箱: ${EMAIL_TO}"
    echo ""

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
# 测试邮件发送
# ================================
test_email_config() {
    if [[ -z "$SMTP_HOST" || -z "$SMTP_USER" || -z "$EMAIL_TO" ]]; then
        log_error "邮件配置不完整，请先配置邮件参数"
        return 1
    fi

    echo ""
    read -p "是否发送测试邮件? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        send_email_notification "OCI 实例配置管理工具 测试邮件" "这是一封测试邮件\n\n发送时间: $(date '+%Y-%m-%d %H:%M:%S')\n\n如果您收到此邮件，说明邮件配置正确。"
    fi
}

# ================================
# 邮件通知函数
# ================================
send_email_notification() {
    local subject="$1"
    local body="$2"

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

${body}"

    # 使用 curl 发送邮件 (SMTP with SSL, LOGIN认证)
    echo "$email_content" | curl -s --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
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

# ================================
# 日志函数
# ================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# ================================
# 暂停函数
# ================================
pause() {
    echo ""
    read -p "按任意键继续..." -n 1 -r
}

# ================================
# 后台任务管理
# ================================

# 创建任务目录
init_task_dir() {
    mkdir -p "$TASK_DIR"
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
                    echo ""
                    log_warn "检测到该实例已有后台任务正在运行！"
                    echo ""
                    echo "  任务 ID: $task_id"
                    echo "  任务类型: $(jq -r '.task_type' "$task_info" 2>/dev/null)"
                    echo "  创建时间: $(jq -r '.create_time' "$task_info" 2>/dev/null)"
                    echo "  目标 OCPU: $(jq -r '.target_ocpus' "$task_info" 2>/dev/null)"
                    echo "  目标内存: $(jq -r '.target_memory' "$task_info" 2>/dev/null) GB"
                    echo "  执行次数: $(jq -r '.attempt' "$task_info" 2>/dev/null)"
                    echo ""
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
# 参数: $1=task_type, $2=instance_ocid, $3=target_ocpus, $4=target_memory, $5=retry_interval, $6=skip_check(可选)
create_background_task() {
    local task_type="$1"  # direct_update 或 full_update
    local instance_ocid="$2"
    local target_ocpus="$3"
    local target_memory="$4"
    local retry_interval="$5"
    local skip_check="${6:-false}"  # 是否跳过已有任务检测

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
            echo ""
            log_warn "检测到该实例已有后台任务正在运行"
            echo ""
            echo "现有任务 ID: $existing_task_id"
            echo "任务类型: $(jq -r '.task_type' "$existing_task/task.info")"
            echo "创建时间: $(jq -r '.create_time' "$existing_task/task.info")"
            echo "目标 OCPU: $(jq -r '.target_ocpus' "$existing_task/task.info")"
            echo "目标内存: $(jq -r '.target_memory' "$existing_task/task.info")GB"
            echo ""
            read -p "是否停止现有任务并创建新任务? [y/N]: " -r
            [[ -z "$REPLY" ]] && REPLY="n"
            echo

            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "操作已取消"
                pause
                return 0
            fi

            # 停止现有任务
            stop_task "$existing_task_id"
            log_success "已停止现有任务"
            echo ""
        fi
    fi

    # 生成任务 ID
    local task_id=$(date +%Y%m%d-%H%M%S)_$$
    local task_path="$TASK_DIR/$task_id"

    # 创建任务目录
    mkdir -p "$task_path"

    # 写入任务信息
    cat > "$task_path/task.info" << EOF
{
    "task_id": "$task_id",
    "task_type": "$task_type",
    "instance_ocid": "$instance_ocid",
    "target_ocpus": $target_ocpus,
    "target_memory": $target_memory,
    "retry_interval": $retry_interval,
    "create_time": "$(date -Iseconds)",
    "status": "running"
}
EOF

    # 启动后台任务
    (
        exec_background_task "$task_id" "$task_type" "$instance_ocid" "$target_ocpus" "$target_memory" "$retry_interval"
    ) &>"$task_path/task.log" &

    local pid=$!
    echo $pid > "$task_path/task.pid"

    log_success "后台任务已创建"
    echo ""
    echo "任务 ID: $task_id"
    echo "日志文件: $task_path/task.log"
    echo ""
    echo -e "${CYAN}提示: 任务将在后台持续执行，您可以：${NC}"
    echo "  - 选择菜单 [9] 查看任务进度"
    echo "  - 退出此脚本不会影响后台任务"
    echo ""
}

# 后台执行任务
exec_background_task() {
    local task_id="$1"
    local task_type="$2"
    local instance_ocid="$3"
    local target_ocpus="$4"
    local target_memory="$5"
    local retry_interval="$6"

    local task_path="$TASK_DIR/$task_id"
    local log_file="$task_path/task.log"
    local status_file="$task_path/task.status"

    log_info() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$log_file"
    }

    log_error() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$log_file"
    }

    log_success() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1" >> "$log_file"
    }

    log_info "后台任务启动"
    log_info "任务类型: $task_type"
    log_info "实例 OCID: $instance_ocid"
    log_info "目标 OCPU: $target_ocpus"
    log_info "目标内存: ${target_memory}GB"
    log_info "重试间隔: ${retry_interval}秒"

    # 更新任务状态函数
    update_task_status() {
        local attempt="$1"
        local last_status="$2"
        local last_error="$3"

        # 更新任务信息文件
        if [[ -f "$task_path/task.info" ]]; then
            local temp_file="$task_path/task.info.tmp"

            # 对错误信息进行 JSON 转义（jq -Rs 会自动处理）
            local escaped_error
            escaped_error=$(echo "$last_error" | jq -Rs .)

            jq --arg attempt "$attempt" \
               --arg status "$last_status" \
               --arg error "$escaped_error" \
               --arg time "$(date -Iseconds)" \
               '.attempt = ($attempt | tonumber) |
                .last_status = $status |
                .last_error = $error |
                .last_attempt_time = $time' \
               "$task_path/task.info" > "$temp_file"
            mv "$temp_file" "$task_path/task.info"
        fi
    }

    # 从 task.info 读取当前执行次数，而不是从 0 开始
    local attempt=$(jq -r '.attempt // 0' "$task_path/task.info")
    while true; do
        ((attempt++))
        log_info "第 $attempt 次尝试..."

        if [[ "$task_type" == "direct_update" ]]; then
            # 直接更新（不停止实例）
            local result
            result=$(oci compute instance update \
                --instance-id "$instance_ocid" \
                --shape-config "{\"ocpus\": $target_ocpus, \"memory-in-gbs\": $target_memory}" \
                --force \
                --output json 2>&1)

            if [[ $? -eq 0 ]]; then
                log_success "更新成功！"
                # 发送邮件通知
                send_email_notification "OCI 实例配置更新成功" "实例 ${instance_ocid} 配置更新成功\n\n更新内容:\n- OCPUs: ${target_ocpus}\n- Memory: ${target_memory} GB\n\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
                # 更新任务状态
                update_task_status "$attempt" "success" ""
                jq '.status = "completed" | .end_time = "'"$(date -Iseconds)"'"' \
                    "$task_path/task.info" > "$task_path/task.info.tmp"
                mv "$task_path/task.info.tmp" "$task_path/task.info"
                exit 0
            else
                # 提取错误信息
                local error_msg
                error_msg=$(echo "$result" | jq -r '.message // .error.message // "未知错误"' 2>/dev/null || echo "$result")
                log_error "更新失败: $result"
                update_task_status "$attempt" "failed" "$error_msg"
                log_info "等待 ${retry_interval} 秒后重试..."
                sleep "$retry_interval"
            fi

        elif [[ "$task_type" == "full_update" ]]; then
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
            # 发送邮件通知
            send_email_notification "OCI 实例完整更新流程成功" "实例 ${instance_ocid} 完整更新流程成功\n\n更新内容:\n- OCPUs: ${target_ocpus}\n- Memory: ${target_memory} GB\n\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            update_task_status "$attempt" "success" ""
            # 更新任务状态
            jq '.status = "completed" | .end_time = "'"$(date -Iseconds)"'"' \
                "$task_path/task.info" > "$task_path/task.info.tmp"
            mv "$task_path/task.info.tmp" "$task_path/task.info"
            exit 0
        fi
    done
}

# 列出所有任务
list_background_tasks() {
    init_task_dir

    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}后台任务列表${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

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
        local instance_ocid=$(jq -r '.instance_ocid' "$task_info")
        local target_ocpus=$(jq -r '.target_ocpus' "$task_info")
        local target_memory=$(jq -r '.target_memory' "$task_info")
        local status=$(jq -r '.status' "$task_info")

        # 新增字段：执行次数、上次状态、上次错误
        local attempt=$(jq -r '.attempt // 0' "$task_info")
        local last_status=$(jq -r '.last_status // "N/A"' "$task_info")
        local last_error=$(jq -r '.last_error // ""' "$task_info")
        local last_attempt_time=$(jq -r '.last_attempt_time // "N/A"' "$task_info")

        # 提取实例名称（从 OCID 中提取）
        local instance_short="${instance_ocid##*.}"  # 取最后一个点之后的内容

        # 检查进程是否还在运行
        local pid_file="$task_path/task.pid"
        if [[ -f "$pid_file" ]]; then
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

        echo -e "#$task_count ${BOLD}$task_id${NC}"
        echo "  类型: $task_type"
        echo "  实例: ${instance_short:0:20}..."
        echo "  目标: ${target_ocpus} OCPU / ${target_memory} GB"
        echo -e "  状态: ${status_color}${status}${NC}"
        echo -e "  执行次数: ${BOLD}${attempt}${NC}"
        echo -e "  上次状态: ${last_status_color}${last_status}${NC}"

        # 显示错误信息（如果有）- 提取关键信息并翻译
        if [[ -n "$last_error" && "$last_error" != "null" && "$last_error" != "" ]]; then
            # 提取关键错误信息 - 去掉 ServiceError: 前缀，提取 JSON 部分
            local error_json error_code error_message error_translated
            error_json=$(echo "$last_error" | sed 's/^ServiceError:[[:space:]]*//' | tail -n +0)
            error_code=$(echo "$error_json" | jq -r '.code // "Unknown"' 2>/dev/null || echo "Unknown")
            error_message=$(echo "$error_json" | jq -r '.message // ""' 2>/dev/null || echo "")

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

            echo -e "  ${RED}✗ 错误: [$error_translated] $msg_translated${NC}"
        fi

        if [[ "$last_attempt_time" != "N/A" ]]; then
            echo "  上次尝试: $last_attempt_time"
        fi

        echo ""
    done

    if [[ $task_count -eq 0 ]]; then
        echo "暂无后台任务"
        echo ""
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
        echo -e "${BOLD}========================================${NC}"
        echo -e "${BOLD}任务详情: $task_id${NC}"
        echo -e "${BOLD}========================================${NC}"
        echo ""

        # 显示任务信息（格式化）
        local task_info="$task_path/task.info"
        if [[ -f "$task_info" ]]; then
            echo -e "${CYAN}任务信息:${NC}"

            # 读取并格式化显示
            local task_type instance_ocid target_ocpus target_memory status attempt create_time
            local last_status last_error last_attempt_time

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
            {
                echo -e "任务ID\t$task_id"
                echo -e "类型\t$task_type"
                echo -e "实例OCID\t${instance_ocid:0:50}..."
                echo -e "目标配置\t${target_ocpus} OCPU / ${target_memory} GB"
                echo -e "重试间隔\t$(jq -r '.retry_interval // 10' "$task_info") 秒"
                echo -e "创建时间\t$create_time"
                echo -e "当前状态\t${status_color}${status}${NC}"
                echo -e "执行次数\t$attempt"
                echo -e "上次状态\t${last_status_color}${last_status}${NC}"
                echo -e "上次尝试\t$last_attempt_time"
            } | column -t -s $'\t'
            echo ""

            # 显示错误信息（如果有）- 格式化显示
            if [[ -n "$last_error" && "$last_error" != "null" && "$last_error" != "" ]]; then
                echo -e "${RED}========================================${NC}"
                echo -e "${RED}错误详情:${NC}"
                echo -e "${RED}========================================${NC}"

                # 提取关键错误信息 - 去掉 ServiceError: 前缀，提取 JSON 部分
                local error_json error_code error_message error_status error_timestamp error_request_id
                error_json=$(echo "$last_error" | sed 's/^ServiceError:[[:space:]]*//' | tail -n +0)
                error_code=$(echo "$error_json" | jq -r '.code // "Unknown"' 2>/dev/null || echo "Unknown")
                error_message=$(echo "$error_json" | jq -r '.message // ""' 2>/dev/null || echo "")
                error_status=$(echo "$error_json" | jq -r '.status // ""' 2>/dev/null || echo "")
                error_timestamp=$(echo "$error_json" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
                error_request_id=$(echo "$error_json" | jq -r '.["opc-request-id"] // ""' 2>/dev/null || echo "")

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
                    echo -e "错误代码\t${RED}$error_code_translated${NC}"
                    echo -e "错误消息\t$msg_translated"
                    [[ -n "$error_status" && "$error_status" != "null" ]] && echo -e "HTTP状态\t$error_status"
                    [[ -n "$error_timestamp" && "$error_timestamp" != "null" ]] && echo -e "时间戳\t$error_timestamp"
                    [[ -n "$error_request_id" && "$error_request_id" != "null" ]] && echo -e "请求ID\t${error_request_id:0:40}..."
                } | column -t -s $'\t'
                echo ""

                # 显示建议
                echo -e "${YELLOW}建议:${NC}"
                case "$error_code" in
                    InternalError)
                        echo "  - OCI 服务端临时问题，请稍后重试"
                        echo "  - 如果持续出现，请联系 Oracle 支持"
                        ;;
                    NotAuthorizedOrNotFound)
                        echo "  - 检查 IAM 用户是否有足够的权限"
                        echo "  - 确认实例 OCID 是否正确"
                        echo "  - 确认实例是否已被删除"
                        ;;
                    InvalidParameter)
                        echo "  - 检查请求参数是否正确"
                        echo "  - 确认目标配置是否在允许范围内"
                        ;;
                    LimitExceeded|ServiceError)
                        if [[ "$error_message" == *"Out of host capacity"* ]]; then
                            echo "  - 主机容量不足是常见问题，建议："
                            echo "    1. 降低目标配置（如 2 OCPU → 1 OCPU）"
                            echo "    2. 更换可用性域 (AD)"
                            echo "    3. 在非高峰时段重试"
                            echo "    4. 保持任务继续重试，直到成功"
                        else
                            echo "  - 请稍后重试或联系 Oracle 支持"
                        fi
                        ;;
                    *)
                        echo "  - 请查看完整错误日志获取更多信息"
                        ;;
                esac
                echo ""
            fi
        fi

        # 显示日志选项
        local log_file="$task_path/task.log"
        if [[ -f "$log_file" ]]; then
            echo -e "${CYAN}日志操作:${NC}"
            echo "  1) 查看最近日志 (最后20行)"
            echo "  2) 实时查看日志 (tail -f)"
            echo "  3) 查看完整日志"
            echo "  0) 返回"
            echo ""
            read -p "请选择: " -r

            case $REPLY in
                1)
                    echo ""
                    echo -e "${BOLD}最近日志:${NC}"
                    echo -e "${BOLD}----------------------------------------${NC}"
                    tail -20 "$log_file"
                    echo -e "${BOLD}----------------------------------------${NC}"
                    echo ""
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

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}实时日志监控: $task_id${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo -e "${CYAN}按 Ctrl+C 返回上一级${NC}"
    echo ""

    # 临时替换全局 trap，让 Ctrl+C 能返回上一级而不是退出脚本
    trap 'echo -e "\n${YELLOW}返回上一级...${NC}"; kill $(jobs -p) 2>/dev/null; trap "echo -e \"\n${YELLOW}操作已取消${NC}\"; exit 0" INT TERM; return 0' INT TERM

    # 在后台运行 tail -f
    tail -f "$log_file" 2>/dev/null &
    local tail_pid=$!

    # 等待 tail 进程，Ctrl+C 会触发 trap
    wait $tail_pid 2>/dev/null

    # 恢复全局 trap
    trap 'echo -e "\n${YELLOW}操作已取消${NC}"; exit 0' INT TERM
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
    local current_status=$(jq -r '.status' "$task_info")

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
    (
        exec_background_task "$task_id" "$task_type" "$instance_ocid" "$target_ocpus" "$target_memory" "$retry_interval"
    ) &>"$task_path/task.log" &

    local pid=$!
    echo $pid > "$task_path/task.pid"

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
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║       OCI 实例配置管理工具 v1.0                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ================================
# 检查 OCI CLI 是否安装
# ================================
check_oci_cli() {
    if ! command -v oci &> /dev/null; then
        log_error "OCI CLI 未安装"
        echo ""
        echo "安装方法:"
        echo "  bash -c \"\$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)\""
        echo ""
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
    return 0
}

# ================================
# 检查 OCI 环境
# ================================
check_oci_environment() {
    show_header
    echo -e "${BOLD}[1] 检查 OCI 环境${NC}"
    echo "========================================"
    echo ""

    local all_ok=true

    # 检查 OCI CLI
    echo -n "检查 OCI CLI... "
    if check_oci_cli; then
        local oci_version
        oci_version=$(oci --version 2>/dev/null | head -1)
        echo -e "${GREEN}✓ 已安装${NC} ($oci_version)"
    else
        echo -e "${RED}✗ 未安装${NC}"
        all_ok=false
    fi

    # 检查 jq
    echo -n "检查 jq... "
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}✓ 已安装${NC}"
    else
        echo -e "${YELLOW}✗ 未安装${NC}"
        all_ok=false
    fi

    # 检查 OCI 配置
    echo -n "检查 OCI 配置... "
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        echo -e "${GREEN}✓ 存在${NC} ($OCI_CONFIG_FILE)"
    else
        echo -e "${YELLOW}✗ 不存在${NC}"
        all_ok=false
    fi

    # 检查私钥文件
    echo -n "检查私钥文件... "
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        local key_file
        key_file=$(grep "^key_file=" "$OCI_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | head -1)
        key_file="${key_file/#\~/$HOME}"
        if [[ -f "$key_file" ]]; then
            echo -e "${GREEN}✓ 存在${NC} ($key_file)"
        else
            echo -e "${YELLOW}✗ 不存在${NC} ($key_file)"
        fi
    fi

    # 测试连接
    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        echo ""
        echo -n "测试 OCI 连接... "
        if oci os ns get --output json &>/dev/null; then
            local namespace
            namespace=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
            echo -e "${GREEN}✓ 成功${NC} (命名空间: $namespace)"
        else
            echo -e "${RED}✗ 失败${NC}"
            all_ok=false
        fi
    fi

    echo ""
    if $all_ok; then
        log_success "环境检查通过"
    else
        log_warn "部分检查未通过，请先配置环境"
    fi

    pause
}

# ================================
# 初始化 OCI 配置
# ================================
init_oci_config() {
    show_header
    echo -e "${BOLD}[2] 初始化 OCI 配置${NC}"
    echo "========================================"
    echo ""

    # 检查现有配置
    local existing_user="" existing_fingerprint="" existing_tenancy=""
    local existing_region="" existing_key=""

    if [[ -f "$OCI_CONFIG_FILE" ]]; then
        echo -e "${GREEN}✓ 检测到现有 OCI CLI 配置${NC}"
        # 读取现有配置
        while IFS= read -r line; do
            [[ "$line" =~ ^user= ]] && existing_user="${line#user=}"
            [[ "$line" =~ ^fingerprint= ]] && existing_fingerprint="${line#fingerprint=}"
            [[ "$line" =~ ^tenancy= ]] && existing_tenancy="${line#tenancy=}"
            [[ "$line" =~ ^region= ]] && existing_region="${line#region=}"
            [[ "$line" =~ ^key_file= ]] && existing_key="${line#key_file=}"
        done < "$OCI_CONFIG_FILE"
        existing_key="${existing_key/#\~/$HOME}"
        echo ""
    fi

    echo -e "${YELLOW}请输入 OCI 配置信息（直接回车使用当前值）:${NC}"
    echo ""

    # 用户 OCID
    if [[ -n "$existing_user" ]]; then
        echo -e "用户 OCID: ${CYAN}$existing_user${NC}"
        read -p "按回车保持，或输入新值: " user_input
        USER_OCID="${user_input:-$existing_user}"
    else
        read -p "用户 OCID: " USER_OCID
    fi
    while [[ -z "$USER_OCID" || ! "$USER_OCID" =~ ^ocid1\.user\.oc1\. ]]; do
        echo -e "${RED}无效的用户 OCID，格式应为: ocid1.user.oc1...${NC}"
        read -p "用户 OCID: " USER_OCID
    done

    # API 密钥指纹
    if [[ -n "$existing_fingerprint" ]]; then
        echo -e "API 密钥指纹: ${CYAN}$existing_fingerprint${NC}"
        read -p "按回车保持，或输入新值: " fp_input
        FINGERPRINT="${fp_input:-$existing_fingerprint}"
    else
        read -p "API 密钥指纹 (例如: 12:34:56:78:90:ab:cd:ef): " FINGERPRINT
    fi
    while [[ -z "$FINGERPRINT" ]]; do
        echo -e "${RED}指纹不能为空${NC}"
        read -p "API 密钥指纹: " FINGERPRINT
    done

    # 租户 OCID
    if [[ -n "$existing_tenancy" ]]; then
        echo -e "租户 OCID: ${CYAN}$existing_tenancy${NC}"
        read -p "按回车保持，或输入新值: " tenancy_input
        TENANCY_OCID="${tenancy_input:-$existing_tenancy}"
    else
        read -p "租户 OCID: " TENANCY_OCID
    fi
    while [[ -z "$TENANCY_OCID" || ! "$TENANCY_OCID" =~ ^ocid1\.tenancy\.oc1\. ]]; do
        echo -e "${RED}无效的租户 OCID，格式应为: ocid1.tenancy.oc1...${NC}"
        read -p "租户 OCID: " TENANCY_OCID
    done

    # 选择区域
    echo ""
    echo "常用区域:"
    echo "  1) ap-chuncheon-1    (春川)"
    echo "  2) ap-seoul-1        (首尔)"
    echo "  3) ap-tokyo-1        (东京)"
    echo "  4) ap-osaka-1        (大阪)"
    echo "  5) us-ashburn-1      (阿什本)"
    echo "  6) us-phoenix-1      (凤凰城)"
    echo "  7) eu-frankfurt-1    (法兰克福)"
    echo "  8) 其他 (手动输入)"
    echo ""

    if [[ -n "$existing_region" ]]; then
        echo -e "当前区域: ${CYAN}$existing_region${NC}"
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
    echo ""
    local default_key="${existing_key:-$HOME/.oci/oci_api_key.pem}"
    echo -e "私钥文件路径: ${CYAN}$default_key${NC}"
    read -p "按回车保持，或输入新路径: " key_input
    KEY_FILE="${key_input:-$default_key}"
    KEY_FILE="${KEY_FILE/#\~/$HOME}"

    # 检查私钥文件
    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}警告: 私钥文件不存在: $KEY_FILE${NC}"
        echo "请确保稍后将私钥文件放置到正确位置"
    fi

    # 配置摘要
    echo ""
    echo "========================================"
    echo -e "${BOLD}配置摘要:${NC}"
    echo "  用户 OCID:     $USER_OCID"
    echo "  租户 OCID:     $TENANCY_OCID"
    echo "  区域:          $REGION"
    echo "  私钥文件:      $KEY_FILE"
    echo "========================================"

    read -p "确认保存配置? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    echo

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
        log_success "OCI CLI 配置已保存到: $OCI_CONFIG_FILE"

        # 验证连接
        echo ""
        log_info "验证 OCI 连接..."
        if oci os ns get --output json &>/dev/null; then
            local namespace
            namespace=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
            log_success "OCI 连接成功，命名空间: $namespace"
        else
            log_warn "OCI 连接验证失败，请检查配置"
        fi
    else
        echo "配置已取消"
    fi

    pause
}

# ================================
# 查看 OCI 配置
# ================================
view_oci_config() {
    show_header
    echo -e "${BOLD}[3] 查看 OCI 配置${NC}"
    echo "========================================"
    echo ""

    if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
        log_error "OCI 配置文件不存在"
        log_info "请先执行 [2] 初始化 OCI 配置"
        pause
        return 1
    fi

    echo -e "${BOLD}OCI CLI 配置文件内容:${NC}"
    echo "文件路径: $OCI_CONFIG_FILE"
    echo ""
    echo "----------------------------------------"
    cat "$OCI_CONFIG_FILE"
    echo "----------------------------------------"
    echo ""

    # 测试连接
    log_info "测试 OCI 连接..."
    if oci os ns get --output json &>/dev/null; then
        local namespace
        namespace=$(oci os ns get --query 'data' --raw-output 2>/dev/null)
        log_success "连接成功，命名空间: $namespace"
    else
        log_error "连接失败，请检查配置"
    fi

    pause
}

# ================================
# 列出实例
# ================================
list_instances() {
    show_header
    echo -e "${BOLD}[4] 列出实例${NC}"
    echo "========================================"
    echo ""

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
    instance_count=$(echo "$instances_json" | jq -r '.data | length' 2>/dev/null)

    if [[ -z "$instance_count" || "$instance_count" -eq 0 ]]; then
        log_warn "未找到任何实例"
        pause
        return 0
    fi

    echo ""
    echo -e "${CYAN}找到 $instance_count 个实例，正在获取详细信息...${NC}"
    echo ""

    # 使用临时文件收集表格数据
    local table_data=$(mktemp)
    echo -e "序号\t名称\t状态\tOCPU\t内存(GB)\t形状\t实例 OCID" > "$table_data"
    echo -e "----\t----\t------\t------\t----------\t------\t--------------------------------------------------" >> "$table_data"

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
            name=$(echo "$detail_json" | jq -r '.data["display-name"] // "N/A"')
            state=$(echo "$detail_json" | jq -r '.data["lifecycle-state"] // "N/A"')
            shape=$(echo "$detail_json" | jq -r '.data.shape // "N/A"')
            ocpus=$(echo "$detail_json" | jq -r '.data["shape-config"].ocpus // "N/A"')
            memory=$(echo "$detail_json" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
            ocid_short="${instance_ocid:0:47}..."

            # 添加到表格（不带颜色代码）
            echo -e "$idx\t$name\t$state\t$ocpus\t$memory\t$shape\t$ocid_short" >> "$table_data"
        else
            echo -e "$idx\t获取失败\tN/A\tN/A\tN/A\tN/A\tN/A" >> "$table_data"
        fi
    done < <(echo "$instances_json" | jq -r '.data[].id' 2>/dev/null)

    # 显示表格（自动对齐）
    column -t -s $'\t' "$table_data"
    rm -f "$table_data"

    echo ""

    # 提供选择功能
    echo -e "${CYAN}提示: 输入序号选择实例查看完整信息，或按回车返回${NC}"
    echo ""

    read -p "请选择实例序号 [1-${instance_count}]，或按回车返回: " choice

    if [[ -z "$choice" ]]; then
        pause
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -le "$instance_count" && "$choice" -ge 1 ]]; then
        local selected_ocid="${INSTANCE_OCIDS[$choice]}"

        # 获取实例详细信息
        local selected_detail
        selected_detail=$(oci compute instance get \
            --instance-id "$selected_ocid" \
            --output json 2>/dev/null)

        if [[ -n "$selected_detail" ]]; then
            local selected_name selected_state selected_shape selected_ocpus selected_memory
            selected_name=$(echo "$selected_detail" | jq -r '.data["display-name"] // "N/A"')
            selected_state=$(echo "$selected_detail" | jq -r '.data["lifecycle-state"] // "N/A"')
            selected_shape=$(echo "$selected_detail" | jq -r '.data.shape // "N/A"')
            selected_ocpus=$(echo "$selected_detail" | jq -r '.data["shape-config"].ocpus // "N/A"')
            selected_memory=$(echo "$selected_detail" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')

            # 第一部分：关键信息
            echo ""
            echo -e "${BOLD}========================================${NC}"
            echo -e "${BOLD}实例关键信息 #${choice}${NC}"
            echo -e "${BOLD}========================================${NC}"
            # 使用表格格式显示
            {
                echo -e "名称\t$selected_name"
                echo -e "状态\t$selected_state"
                echo -e "OCPU\t$selected_ocpus"
                echo -e "内存(GB)\t$selected_memory"
                echo -e "形状\t$selected_shape"
                echo -e "OCID\t$selected_ocid"
            } | column -t -s $'\t'
            echo ""

            # 第二部分：完整 JSON
            read -p "是否查看完整 JSON 信息? [Y/n]: " view_json
            [[ -z "$view_json" ]] && view_json="y"

            if [[ $view_json =~ ^[Yy]$ ]]; then
                echo ""
                echo -e "${BOLD}========================================${NC}"
                echo -e "${BOLD}完整 JSON 信息${NC}"
                echo -e "${BOLD}========================================${NC}"
                echo "$selected_detail" | jq '.'
                echo ""

                read -p "是否保存到文件? [Y/n]: " save_json
                [[ -z "$save_json" ]] && save_json="y"

                if [[ $save_json =~ ^[Yy]$ ]]; then
                    local json_file="instance_${selected_name}_$(date +%Y%m%d-%H%M%S).json"
                    echo "$selected_detail" > "$json_file"
                    log_success "已保存到: $json_file"
                    echo ""
                fi
            fi
        else
            echo -e "${RED}获取实例详情失败${NC}"
        fi
    else
        echo -e "${RED}无效选择，请输入 1-${instance_count} 之间的数字${NC}"
    fi

    echo ""
    pause
}

# ================================
# 停止实例（交互式）
# ================================
stop_instance() {
    show_header
    echo -e "${BOLD}[5] 停止实例${NC}"
    echo "========================================"
    echo ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入实例 ID
    echo -e "${YELLOW}请输入要停止的实例 ID:${NC}"
    read -p "实例 OCID: " INSTANCE_OCID
    while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
        echo -e "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
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
        name=$(echo "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(echo "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        echo ""
        echo "当前实例信息:"
        echo "  名称: $name"
        echo "  状态: $state"
    fi

    echo ""
    read -p "确认停止实例? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
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

            echo -n "."
            sleep 5
            ((waited += 5))
        done
        echo ""
    else
        log_error "停止实例失败: $result"
    fi

    echo ""
    pause
}

# ================================
# 启动实例（交互式）
# ================================
start_instance() {
    show_header
    echo -e "${BOLD}[6] 启动实例${NC}"
    echo "========================================"
    echo ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入实例 ID
    echo -e "${YELLOW}请输入要启动的实例 ID:${NC}"
    read -p "实例 OCID: " INSTANCE_OCID
    while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
        echo -e "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
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
        name=$(echo "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(echo "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        echo ""
        echo "当前实例信息:"
        echo "  名称: $name"
        echo "  状态: $state"
    fi

    echo ""
    read -p "确认启动实例? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
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

            echo -n "."
            sleep 5
            ((waited += 5))
        done
        echo ""
    else
        log_error "启动实例失败: $result"
    fi

    echo ""
    pause
}

# ================================
# 直接更新实例配置（交互式）
# ================================
update_instance_config_direct() {
    show_header
    echo -e "${BOLD}[7] 直接更新实例配置${NC}"
    echo "========================================"
    echo ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入参数
    echo -e "${YELLOW}请输入更新参数:${NC}"
    echo ""

    # 实例 ID（如果已经设置则跳过）
    if [[ -z "$INSTANCE_OCID" ]]; then
        read -p "实例 OCID: " INSTANCE_OCID
        while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
            echo -e "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
            read -p "实例 OCID: " INSTANCE_OCID
        done
    else
        echo -e "${GREEN}✓${NC} 实例 OCID: ${INSTANCE_OCID:0:30}..."
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
        name=$(echo "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(echo "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        current_ocpus=$(echo "$current_info" | jq -r '.data["shape-config"].ocpus // "N/A"')
        current_memory=$(echo "$current_info" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
        shape=$(echo "$current_info" | jq -r '.data.shape // "N/A"')

        echo ""
        echo "当前实例信息:"
        echo "  名称: $name"
        echo "  状态: $state"
        echo "  形状: $shape"
        echo "  当前 OCPU: $current_ocpus"
        echo "  当前内存: ${current_memory} GB"
        echo ""
        echo "目标配置:"
        echo "  目标 OCPU: $TARGET_OCPUS"
        echo "  目标内存: ${TARGET_MEMORY} GB"
        echo "  重试间隔: ${RETRY_INTERVAL} 秒"
    fi

    echo ""
    read -p "确认执行直接更新? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
        pause
        return 0
    fi

    # 创建后台任务
    create_background_task "direct_update" "$INSTANCE_OCID" "$TARGET_OCPUS" "$TARGET_MEMORY" "$RETRY_INTERVAL"
}

# ================================
# 生成更新配置模板
# ================================
generate_update_template() {
    local instance_ocid="$1"
    local output_file="${2:-instance_update.json}"

    show_header
    echo -e "${BOLD}生成更新配置模板${NC}"
    echo "========================================"
    echo ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    # 如果没有传入实例 OCID，需要交互输入
    if [[ -z "$instance_ocid" ]]; then
        read -p "请输入实例 OCID: " instance_ocid
        while [[ -z "$instance_ocid" || ! "$instance_ocid" =~ ^ocid1\.instance\.oc1\. ]]; do
            echo -e "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
            read -p "请输入实例 OCID: " instance_ocid
        done
    fi

    echo ""
    echo "模板类型:"
    echo "  1) 精简模板            (仅包含更新必需字段)"
    echo "  2) 完整模板            (包含所有可用字段)"
    echo ""
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
            current_ocpus=$(echo "$current_info" | jq -r '.data["shape-config"].ocpus // 1')
            current_memory=$(echo "$current_info" | jq -r '.data["shape-config"]["memory-in-gbs"] // 6')
            current_shape=$(echo "$current_info" | jq -r '.data.shape // "VM.Standard.A1.Flex"')

            # 询问目标配置
            echo ""
            echo "当前配置: $current_ocpus OCPU, ${current_memory} GB 内存"
            echo ""
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
            echo ""
            echo -e "${CYAN}提示: 此模板包含所有可用参数。您需要修改以下内容:${NC}"
            echo "  1. 将 'string' 占位符改为实际值或删除该字段"
            echo "  2. 将 'ALLOW_DOWNTIME|AVOID_DOWNTIME' 改为 ALLOW_DOWNTIME 或 AVOID_DOWNTIME"
            echo "  3. 删除不需要的字段"
        else
            log_error "生成配置模板失败"
            return 1
        fi
    fi

    echo ""
    echo -e "${BOLD}模板内容:${NC}"
    echo "----------------------------------------"
    jq '.' "$output_file" 2>/dev/null | head -30
    echo "----------------------------------------"
    echo ""

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

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}使用配置文件更新${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    # 列出当前目录下的 JSON 配置文件
    echo -e "${CYAN}当前目录下的配置文件:${NC}"
    local json_files=()
    while IFS= read -r -d '' file; do
        json_files+=("$file")
    done < <(find . -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null | sort -z)

    if [[ ${#json_files[@]} -eq 0 ]]; then
        log_warn "未找到配置文件 (*.json)"
        echo ""
        echo "选项:"
        echo "  1) 生成新的配置模板"
        echo "  2) 手动输入配置文件路径"
        echo "  0) 返回"
        echo ""
        read -p "请选择: " choice

        case $choice in
            1)
                local instance_ocid output_file
                read -p "实例 OCID: " instance_ocid
                read -p "输出文件名 [instance_update.json]: " output_file
                output_file="${output_file:-instance_update.json}"
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
        echo ""
        for i in "${!json_files[@]}"; do
            echo "  $((i+1))) ${json_files[$i]#./}"
        done
        echo "  0) 返回"
        echo ""
        read -p "请选择配置文件: " file_choice

        if [[ "$file_choice" -eq 0 ]]; then
            return 0
        elif [[ "$file_choice" -ge 1 && "$file_choice" -le ${#json_files[@]} ]]; then
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
        echo ""
        echo -e "${YELLOW}检测到以下问题:${NC}"
        echo "  - instanceId 可能是占位符"
        echo "  - update-operation-constraint 可能是占位符"
        echo ""
        echo "请先编辑配置文件，修改以下内容:"
        echo "  1. 将 instanceId 改为实际的实例 OCID"
        echo "  2. 将 update-operation-constraint 改为 ALLOW_DOWNTIME 或 AVOID_DOWNTIME"
        echo "  3. 将其他 'string' 值改为实际值或删除该字段"
        echo ""
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
    echo ""
    echo -e "${BOLD}配置文件内容:${NC}"
    echo "----------------------------------------"
    jq '.' "$config_file" 2>/dev/null | head -30
    echo "----------------------------------------"
    echo ""

    # 提取关键信息显示
    local instance_id ocpus memory
    instance_id=$(jq -r '.instanceId // "N/A"' "$config_file" 2>/dev/null)
    ocpus=$(jq -r '.shapeConfig.ocpus // "N/A"' "$config_file" 2>/dev/null)
    memory=$(jq -r '.shapeConfig.memoryInGBs // "N/A"' "$config_file" 2>/dev/null)

    # 显示更新模式和配置
    local mode_desc="直接更新"
    [[ "$mode" == "full" ]] && mode_desc="完整更新流程 (停止→更新→启动)"

    echo -e "${BOLD}更新配置:${NC}"
    echo "  模式: $mode_desc"
    echo "  实例: ${instance_id:0:50}..."
    echo "  目标 OCPU: $ocpus"
    echo "  目标内存: ${memory} GB"
    echo ""

    # 确认执行
    echo -e "${YELLOW}警告: 更新操作将替换实例的配置${NC}"
    read -p "确认执行更新? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
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
            --output json 2>&1)

        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "配置更新成功"

            # 3. 启动实例
            log_info "步骤 3/3: 启动实例..."
            if start_instance; then
                log_success "完整更新流程执行成功！"
                # 发送邮件通知
                send_email_notification "OCI 实例配置文件更新成功" "实例 ${instance_id} 配置文件更新成功\n\n配置文件: $config_file\n\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            else
                log_warn "启动实例失败，请手动启动"
            fi
        else
            log_error "配置更新失败"
            echo ""
            echo "错误输出:"
            echo "$update_result"

            # 询问是否创建后台重试任务
            echo ""
            read -p "是否创建后台任务自动重试完整流程? [Y/n]: " -r
            [[ -z "$REPLY" ]] && REPLY="y"

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local retry_interval
                read -p "重试间隔 (秒) [默认: 10]: " retry_interval
                retry_interval="${retry_interval:-10}"

                # 创建后台任务（跳过检测，因为前面已经检测过了）
                create_background_task "full_update" "$instance_id" "$target_ocpus" "$target_memory" "$retry_interval" "true"
            fi
        fi
    else
        # 直接更新模式
        log_info "执行直接更新..."

        local update_result
        update_result=$(yes | oci compute instance update \
            --from-json "file://$config_file" \
            --output json 2>&1)

        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "更新命令执行成功"
            echo ""
            echo "更新结果:"
            echo "$update_result" | jq '.' 2>/dev/null || echo "$update_result"

            # 询问是否创建后台监控任务
            echo ""
            read -p "是否创建后台任务持续监控并重试? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local retry_interval
                read -p "重试间隔 (秒) [默认: 10]: " retry_interval
                retry_interval="${retry_interval:-10}"

                # 创建后台任务（跳过检测，因为前面已经检测过了）
                create_background_task "direct_update" "$instance_id" "$target_ocpus" "$target_memory" "$retry_interval" "true"
            fi
        else
            log_error "更新命令执行失败"
            echo ""
            echo "错误输出:"
            echo "$update_result"

            # 询问是否创建后台重试任务
            echo ""
            read -p "是否创建后台任务自动重试? [Y/n]: " -r
            [[ -z "$REPLY" ]] && REPLY="y"

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                local retry_interval
                read -p "重试间隔 (秒) [默认: 10]: " retry_interval
                retry_interval="${retry_interval:-10}"

                # 创建后台任务（跳过检测，因为前面已经检测过了）
                create_background_task "direct_update" "$instance_id" "$target_ocpus" "$target_memory" "$retry_interval" "true"
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
    echo -e "${BOLD}[8] 完整更新流程 (停止→更新→启动)${NC}"
    echo "========================================"
    echo ""

    if ! check_oci_cli; then
        pause
        return 1
    fi

    if ! check_oci_config; then
        pause
        return 1
    fi

    # 交互式输入参数
    echo -e "${YELLOW}请输入更新参数:${NC}"
    echo ""

    # 实例 ID（如果已经设置则跳过）
    if [[ -z "$INSTANCE_OCID" ]]; then
        read -p "实例 OCID: " INSTANCE_OCID
        while [[ -z "$INSTANCE_OCID" || ! "$INSTANCE_OCID" =~ ^ocid1\.instance\.oc1\. ]]; do
            echo -e "${RED}无效的实例 OCID，格式应为: ocid1.instance.oc1...${NC}"
            read -p "实例 OCID: " INSTANCE_OCID
        done
    else
        echo -e "${GREEN}✓${NC} 实例 OCID: ${INSTANCE_OCID:0:30}..."
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
        name=$(echo "$current_info" | jq -r '.data["display-name"] // "N/A"')
        state=$(echo "$current_info" | jq -r '.data["lifecycle-state"] // "N/A"')
        current_ocpus=$(echo "$current_info" | jq -r '.data["shape-config"].ocpus // "N/A"')
        current_memory=$(echo "$current_info" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
        shape=$(echo "$current_info" | jq -r '.data.shape // "N/A"')

        echo ""
        echo "当前实例信息:"
        echo "  名称: $name"
        echo "  状态: $state"
        echo "  形状: $shape"
        echo "  当前 OCPU: $current_ocpus"
        echo "  当前内存: ${current_memory} GB"
        echo ""
        echo "目标配置:"
        echo "  目标 OCPU: $TARGET_OCPUS"
        echo "  目标内存: ${TARGET_MEMORY} GB"
        echo "  重试间隔: ${RETRY_INTERVAL} 秒"
    fi

    echo ""
    read -p "确认执行完整更新流程? [Y/n]: " -r
    [[ -z "$REPLY" ]] && REPLY="y"
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
        pause
        return 0
    fi

    # 创建后台任务
    create_background_task "full_update" "$INSTANCE_OCID" "$TARGET_OCPUS" "$TARGET_MEMORY" "$RETRY_INTERVAL"
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
        echo -e "${BOLD}[4] 管理实例${NC}"
        echo "========================================"
        echo ""

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
        instance_count=$(echo "$instances_json" | jq '.data | length')

        if [[ "$instance_count" -eq 0 ]]; then
            log_warn "未找到任何实例"
            pause
            return 0
        fi

        log_success "找到 $instance_count 个实例"
        echo ""

        # 显示实例列表（卡片式）- 只获取一次数据
        echo -e "${BOLD}实例列表${NC}"
        echo -e "${BOLD}========================================${NC}"

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
                name=$(echo "$detail_json" | jq -r '.data["display-name"] // "N/A"')
                state=$(echo "$detail_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                ocpus=$(echo "$detail_json" | jq -r '.data["shape-config"].ocpus // "N/A"')
                memory=$(echo "$detail_json" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
                shape=$(echo "$detail_json" | jq -r '.data.shape // "N/A"')

                # 状态颜色
                local state_color
                case "$state" in
                    RUNNING) state_color="${GREEN}" ;;
                    STOPPED) state_color="${RED}" ;;
                    *) state_color="${YELLOW}" ;;
                esac

                # 显示实例卡片（完整 OCID）
                echo -e "#${idx} ${name}"
                echo -e "  状态:  ${state_color}${state}${NC}"
                echo -e "  配置:  ${ocpus} OCPU / ${memory} GB"
                echo -e "  形状:  ${shape}"
                echo -e "  OCID:  ${instance_ocid}"
                echo ""
            fi
        done < <(echo "$instances_json" | jq -r '.data[].id')

        echo -e "${BOLD}========================================${NC}"
        echo ""

        # 内层循环：操作选项（不重新获取数据）
        while true; do
            echo "操作选项:"
            echo "  1) 查看实例完整配置    (JSON格式)"
            echo "  2) 输入配置参数更新    (交互式输入)"
            echo "  3) 使用配置文件更新    (JSON文件)"
            echo "  4) 停止实例"
            echo "  5) 启动实例"
            echo "  0) 返回主菜单"
            echo ""

            read -p "请选择操作: " -r

            case $REPLY in
                1)
                    # 查看完整配置 (JSON)
                    read -p "选择实例序号 (1-$instance_count): " choice
                    if [[ "$choice" -ge 1 && "$choice" -le "$instance_count" ]]; then
                        local selected_ocid="${INSTANCE_OCIDS[$choice]}"

                        log_info "获取实例配置..."
                        local detail_json
                        detail_json=$(oci compute instance get \
                            --instance-id "$selected_ocid" \
                            --output json 2>/dev/null)

                        if [[ -n "$detail_json" ]]; then
                            echo ""
                            echo -e "${BOLD}========================================${NC}"
                            echo -e "${BOLD}实例完整配置 (JSON) #${choice}${NC}"
                            echo -e "${BOLD}========================================${NC}"
                            echo "$detail_json" | jq '.'
                            echo ""

                            read -p "是否保存到文件? [Y/n]: " save_json
                            [[ -z "$save_json" ]] && save_json="y"

                            if [[ $save_json =~ ^[Yy]$ ]]; then
                                local name
                                name=$(echo "$detail_json" | jq -r '.data["display-name"] // "instance"')
                                local json_file="instance_${name}_$(date +%Y%m%d-%H%M%S).json"
                                echo "$detail_json" > "$json_file"
                                log_success "已保存到: $json_file"
                                echo ""
                            fi
                        else
                            log_error "获取实例配置失败"
                        fi
                    else
                        log_error "无效选择"
                    fi
                    ;;
                2)
                    # 输入配置参数更新 - 子菜单
                    update_by_input_params "$instance_count"
                    ;;
                3)
                    # 使用配置文件更新 - 子菜单
                    update_by_config_file "$instance_count"
                    ;;
                4)
                    # 停止实例
                    read -p "选择实例序号 (1-$instance_count): " choice
                    if [[ "$choice" -ge 1 && "$choice" -le "$instance_count" ]]; then
                        local selected_ocid="${INSTANCE_OCIDS[$choice]}"
                        INSTANCE_OCID="$selected_ocid"
                        stop_instance
                    else
                        log_error "无效选择"
                    fi
                    ;;
                5)
                    # 启动实例
                    read -p "选择实例序号 (1-$instance_count): " choice
                    if [[ "$choice" -ge 1 && "$choice" -le "$instance_count" ]]; then
                        local selected_ocid="${INSTANCE_OCIDS[$choice]}"
                        INSTANCE_OCID="$selected_ocid"
                        start_instance
                    else
                        log_error "无效选择"
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
    done
}

# ================================
# 输入配置参数更新 (子菜单)
# ================================
update_by_input_params() {
    local instance_count=$1

    while true; do
        echo ""
        echo -e "${BOLD}----------------------------------------${NC}"
        echo -e "${BOLD}输入配置参数更新${NC}"
        echo -e "${BOLD}----------------------------------------${NC}"
        echo ""
        echo "更新方式:"
        echo "  1) 直接更新            (仅更新配置，不停止实例)"
        echo "  2) 完整更新流程        (停止→更新→启动)"
        echo "  0) 返回上一级"
        echo ""

        read -p "请选择更新方式: " -r

        case $REPLY in
            1)
                # 直接更新
                read -p "选择实例序号 (1-$instance_count): " choice
                if [[ "$choice" -ge 1 && "$choice" -le "$instance_count" ]]; then
                    INSTANCE_OCID="${INSTANCE_OCIDS[$choice]}"
                    update_instance_config_direct
                else
                    log_error "无效选择"
                fi
                ;;
            2)
                # 完整更新流程
                read -p "选择实例序号 (1-$instance_count): " choice
                if [[ "$choice" -ge 1 && "$choice" -le "$instance_count" ]]; then
                    INSTANCE_OCID="${INSTANCE_OCIDS[$choice]}"
                    update_instance_config_full
                else
                    log_error "无效选择"
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
        echo ""
        echo -e "${BOLD}----------------------------------------${NC}"
        echo -e "${BOLD}使用配置文件更新${NC}"
        echo -e "${BOLD}----------------------------------------${NC}"
        echo ""
        echo "操作选项:"
        echo "  1) 生成配置模板        (从实例生成 JSON 模板)"
        echo "  2) 直接更新            (使用配置文件，不停止实例)"
        echo "  3) 完整更新流程        (停止→更新→启动)"
        echo "  0) 返回上一级"
        echo ""

        read -p "请选择操作: " -r

        case $REPLY in
            1)
                # 生成配置模板
                read -p "选择实例序号 (1-$instance_count，或回车手动输入): " choice
                local selected_ocid=""
                if [[ -n "$choice" && "$choice" -ge 1 && "$choice" -le "$instance_count" ]]; then
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
        echo -e "${BOLD}[5] 管理后台任务${NC}"
        echo "========================================"
        echo ""

        # 列出所有任务
        list_background_tasks

        local task_count=${#TASK_IDS[@]}

        echo "操作选项:"
        echo "  1) 查看任务详情"
        echo "  2) 停止任务"
        echo "  3) 恢复任务"
        echo "  4) 删除任务记录"
        echo "  5) 刷新列表"
        echo "  0) 返回主菜单"
        echo ""

        read -p "请选择操作: " -r

        case $REPLY in
            1)
                if [[ $task_count -eq 0 ]]; then
                    log_warn "暂无任务"
                    continue
                fi
                read -p "选择任务序号 (1-$task_count): " task_num
                if [[ "$task_num" -ge 1 && "$task_num" -le "$task_count" ]]; then
                    local task_id="${TASK_IDS[$task_num]}"
                    view_task_detail "$task_id"
                else
                    log_error "无效选择"
                fi
                ;;
            2)
                if [[ $task_count -eq 0 ]]; then
                    log_warn "暂无任务"
                    continue
                fi
                read -p "选择任务序号 (1-$task_count): " task_num
                if [[ "$task_num" -ge 1 && "$task_num" -le "$task_count" ]]; then
                    local task_id="${TASK_IDS[$task_num]}"
                    stop_task "$task_id"
                else
                    log_error "无效选择"
                fi
                read -p "按回车键继续..." -r
                ;;
            3)
                if [[ $task_count -eq 0 ]]; then
                    log_warn "暂无任务"
                    continue
                fi
                read -p "选择任务序号 (1-$task_count): " task_num
                if [[ "$task_num" -ge 1 && "$task_num" -le "$task_count" ]]; then
                    local task_id="${TASK_IDS[$task_num]}"
                    resume_task "$task_id"
                else
                    log_error "无效选择"
                fi
                read -p "按回车键继续..." -r
                ;;
            4)
                if [[ $task_count -eq 0 ]]; then
                    log_warn "暂无任务"
                    continue
                fi
                read -p "选择任务序号 (1-$task_count): " task_num
                if [[ "$task_num" -ge 1 && "$task_num" -le "$task_count" ]]; then
                    local task_id="${TASK_IDS[$task_num]}"
                    delete_task "$task_id"
                else
                    log_error "无效选择"
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
    echo -e "${BOLD}[H] 帮助信息${NC}"
    echo "========================================"
    echo ""

    echo -e "${BOLD}主菜单功能说明:${NC}"
    echo ""
    echo "  [1] 检查 OCI 环境"
    echo "      检查 OCI CLI、jq、配置文件和连接状态"
    echo ""
    echo "  [2] 初始化 OCI 配置"
    echo "      配置 OCI CLI (~/.oci/config)"
    echo "      需要提供: 用户 OCID、指纹、租户 OCID、区域、私钥路径"
    echo ""
    echo "  [3] 查看 OCI 配置"
    echo "      显示 OCI CLI 配置文件内容"
    echo "      测试 OCI 连接"
    echo ""
    echo "  [4] 管理实例"
    echo "      列出所有实例，支持以下操作:"
    echo "        - 查看实例完整配置 (JSON)"
    echo "        - 输入配置参数更新 (交互式)"
    echo "        - 使用配置文件更新 (JSON)"
    echo "        - 停止/启动实例"
    echo ""
    echo "  [5] 管理后台任务"
    echo "      查看所有后台任务，支持以下操作:"
    echo "        - 查看任务详情和日志"
    echo "        - 停止/恢复/删除任务"
    echo "        - 实时查看日志"
    echo ""
    echo "  [6] 配置邮件通知"
    echo "      配置 SMTP 服务器信息"
    echo "      更新成功后自动发送邮件通知"
    echo "      支持测试邮件发送"
    echo ""
    echo -e "${BOLD}更新方式说明:${NC}"
    echo ""
    echo "  输入配置参数更新:"
    echo "    - 直接更新: 不停止实例，直接修改配置"
    echo "    - 完整流程: 停止→更新→启动"
    echo ""
    echo "  使用配置文件更新:"
    echo "    - 生成 JSON 配置模板"
    echo "    - 直接更新或完整流程"
    echo ""
    echo -e "${BOLD}配置文件位置:${NC}"
    echo "   OCI CLI 配置: ~/.oci/config"
    echo "   私钥文件:     ~/.oci/oci_api_key.pem"
    echo "   邮件配置:     ./email_config.conf"
    echo "   任务目录:     ./tasks/"
    echo ""
    echo -e "${BOLD}如何获取 OCI 配置信息:${NC}"
    echo "   1. 登录 OCI 控制台: https://cloud.oracle.com"
    echo "   2. 进入 用户设置 -> API 密钥"
    echo "   3. 添加或查看 API 密钥，获取:"
    echo "      - 用户 OCID"
    echo "      - 指纹"
    echo "      - 租户 OCID"
    echo "   4. 下载或创建私钥文件"
    echo ""
    echo "========================================"

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
        echo -e "${GREEN}✓${NC} OCI 配置已加载: 区域=${region:-未知}"
    else
        echo -e "${YELLOW}!${NC} 尚未配置，请先执行 [2] 初始化 OCI 配置"
    fi

    # 显示邮件配置状态
    if [[ -f "$EMAIL_CONFIG_FILE" && -n "$SMTP_HOST" ]]; then
        echo -e "${GREEN}✓${NC} 邮件配置已加载: ${SMTP_USER} -> ${EMAIL_TO}"
    else
        echo -e "${YELLOW}!${NC} 邮件通知未配置"
    fi

    echo ""
    echo -e "${BOLD}请选择操作:${NC}"
    echo ""
    echo "  1) 检查 OCI 环境"
    echo "  2) 初始化 OCI 配置"
    echo "  3) 查看 OCI 配置"
    echo "  4) 管理实例"
    echo "  5) 管理后台任务"
    echo "  6) 配置邮件通知"
    echo "  h) 帮助信息"
    echo ""
    echo "  0) 退出"
    echo ""
    echo "========================================"
}

# ================================
# 主循环
# ================================
main() {
    while true; do
        show_menu
        read -p "请输入选项: " -r
        echo ""

        case $REPLY in
            1) check_oci_environment ;;
            2) init_oci_config ;;
            3) view_oci_config ;;
            4) manage_instances ;;
            5) manage_background_tasks ;;
            6) configure_email && test_email_config ;;
            h|H) show_help ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# ================================
# 异常处理
# ================================
trap 'echo -e "\n${YELLOW}操作已取消${NC}"; exit 0' INT TERM

# ================================
# 启动主程序
# ================================
# 加载邮件配置
load_email_config

# 启动主菜单
main
