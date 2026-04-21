# OCI 实例配置更新脚本

一个交互式 Bash 脚本，用于通过 CLI 管理 OCI 计算实例配置与创建流程。

## 功能特性

- **OCI 环境检查**：验证 OCI CLI、jq、配置文件和连接状态
- **实例管理**：列出、查看、启动、停止实例
- **实例创建**：保存关键参数并复用已保存配置创建新实例
  - 设置过程中自动保存到草稿，意外退出后可继续
  - 只有确认完成后才会覆盖正式配置
  - 新建 VCN 时提供默认推荐配置，支持快速创建公网 VCN
  - 查询并选择可用性域、规格、镜像、子网
  - 镜像查询时先显示操作系统列表，再显示对应版本与镜像列表
  - 新建子网时，如没有可用 VCN，也可在流程内直接新建 VCN
  - 查询不到需要的子网时，可在流程内直接新建子网
  - 支持设置引导卷大小与引导卷性能（10-120，且为 10 的倍数）
  - 支持前台创建或后台持续重试创建
  - 创建成功后输出实例 OCID、状态、公网 IP、私网 IP 摘要
- **配置更新**：更新实例 OCPU 和内存设置
  - 直接更新（不停止实例）
  - 完整更新流程（停止→更新→启动）
- **后台任务**：创建和管理后台任务，支持自动重试
- **邮件通知**：更新/创建成功后发送邮件通知（SMTP）
- **配置文件支持**：使用 JSON 配置文件批量更新
- **任务恢复**：恢复已停止的任务，保留执行次数

## 系统要求

- Bash 3.x+（兼容 macOS）
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
- [jq](https://stedolan.github.io/jq/)
- curl（用于邮件通知）

## 快速开始

```bash
# 方式 1：下载后本地运行
./oracle_oci_tool.sh

# 方式 2：直接远程运行
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_oci_tool.sh)
```

无论使用哪种方式，脚本数据默认都会保存在 `~/.oracle_oci_tool`，避免因切换启动方式而丢失任务、邮件配置或创建配置。

## 主菜单

| 选项 | 描述 |
|------|------|
| 1 | 检查 OCI 环境 |
| 2 | 初始化 OCI 配置 |
| 3 | 查看 OCI 配置 |
| 4 | 管理实例 |
| 5 | 创建实例 |
| 6 | 管理后台任务 |
| 7 | 配置邮件通知 |
| h | 帮助信息 |
| 0 | 退出 |

## 配置说明

### OCI CLI 配置

1. 登录 [OCI 控制台](https://cloud.oracle.com)
2. 进入 用户设置 → API 密钥
3. 添加或查看 API 密钥，获取：
   - 用户 OCID
   - 指纹
   - 租户 OCID
4. 下载或创建私钥文件（如 `~/.oci/oci_api_key.pem`）

### 邮件通知（可选）

通过菜单选项 `[7] 配置邮件通知` 配置：
- SMTP 服务器（如 `smtp.qq.com`）
- SMTP 端口（SSL 通常为 `465`）
- 发件人邮箱
- SMTP 密码/授权码
- 收件人邮箱

## 数据目录

默认数据目录：

```text
~/.oracle_oci_tool/
├── email_config.conf
├── tasks/
├── update_instance_config.json
├── create_instance_config.json
└── create_instance_config.draft.json
```

说明：
- 本地执行 `./oracle_oci_tool.sh` 和远程执行 `bash <(curl ...)` 使用同一个数据目录
- 首次运行新版脚本时，如旧数据仍在脚本目录中，会自动迁移常见配置和任务到 `~/.oracle_oci_tool`
- 如需自定义目录，可在运行前设置环境变量 `OCI_TOOL_HOME`

## 脚本文件

```text
./
└── oracle_oci_tool.sh      # 主脚本
```

## 后台任务

- 任务在后台运行，支持自动重试
- 支持“更新实例”和“创建实例”两类任务
- 执行次数在重启后保留
- 支持恢复已停止的任务
- 支持实时查看日志

## 创建实例参数说明

- `create_instance_config.draft.json` 用于保存设置过程中的草稿进度
- `create_instance_config.json` 仅在最终确认后才会覆盖
- 引导卷大小与性能通过 OCI CLI 支持的实例创建参数写入，适用于前台创建和后台重试创建
- `Flex` 规格下，CPU/内存通过 `shape-config` 设置；引导卷大小和性能通过实例启动源参数设置

## ⚠️ 注意事项及免责声明

### 免责声明

1. **账号责任**：因使用本脚本导致的账号封禁、服务终止或其他后果，**用户自行承担全部责任，作者概不负责**。

2. **无后门**：本脚本所有数据均**存储在本地**，**无远程服务器、无后门、无数据收集机制**。

3. **使用风险**：本脚本与 OCI API 交互，不当使用可能违反 OCI 服务条款。请在使用前仔细阅读 OCI 相关政策。

4. **无担保**：本软件按"原样"提供，不提供任何形式的明示或暗示担保。

### 安全提示

- 邮件配置文件（`email_config.conf`）包含敏感的 SMTP 凭证
- 所有敏感文件已自动添加到 `.gitignore`
- **切勿将** `email_config.conf` 或 `tasks/` 目录提交到版本控制系统

## 开源协议

MIT License
