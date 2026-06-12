# OCI 实例配置更新脚本

一个交互式 Bash 脚本，用于通过 CLI 管理 OCI 计算实例配置与创建流程。

## 功能特性

- **OCI 环境检查**：验证 OCI CLI、jq、配置文件和连接状态
  - 缺失常见依赖时会自动尝试安装
- **实例管理**：列出、查看、启动、停止实例
- **一键修改实例配置**：默认将实例改为 4 OCPU / 24 GB 内存，并尝试将启动盘扩容到 200 GB
- **实例创建**：保存关键参数并复用已保存配置创建新实例
  - 一键创建实例默认使用 Ubuntu 24.04、A1.Flex、4 OCPU、24 GB、200 GB 启动盘、120 VPU/GB
  - 一键创建实例会复用区间默认值，并按“获取关键参数并保存”的查询方式获取可用性域、子网和镜像 ID
  - 如查询不到可用性域、子网或镜像 ID，会停止并提示人工处理
  - 如未找到 SSH 公钥，会自动在数据目录生成实例登录密钥对
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
  - 直接更新后台任务按固定请求间隔非阻塞发起请求，默认每 60 秒一次
  - 完整更新流程（停止→更新→启动）
- **后台任务**：创建和管理后台任务，支持自动重试
- **通知**：更新/创建成功后支持邮件（SMTP）或 Telegram 机器人通知
- **配置文件支持**：使用 JSON 配置文件批量更新
- **任务恢复**：恢复已停止的任务，保留执行次数
- **卸载功能**：支持交互式卸载 OCI 配置、日志、脚本数据，并自动清理脚本安装过的依赖

## 系统要求

- Bash 3.x+（兼容 macOS）
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
- [jq](https://stedolan.github.io/jq/)
- curl（用于通知和自动安装）
- Python 3 和 venv（用于安装 OCI CLI）
- ssh-keygen（用于自动生成实例登录密钥）
- `column`（可选，用于表格对齐显示；未安装时脚本会自动降级为普通文本显示）

## 依赖安装

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y bash curl jq python3 python3-venv openssh-client bsdextrautils
```

说明：
- `python3-venv` 用于 OCI CLI 官方安装器
- `openssh-client` 提供 `ssh-keygen`
- `bsdextrautils` 提供 `column`
- `OCI CLI` 可通过脚本的“检查 OCI 环境”菜单自动安装最新版本
- 脚本的“检查 OCI 环境”菜单也支持在缺失依赖时自动尝试安装

### macOS

```bash
brew install jq openssh
```

说明：
- macOS 自带 `bash` 和 `curl`
- `column` 通常系统自带
- `openssh` 提供新版 `ssh-keygen`
- `OCI CLI` 可通过脚本的“检查 OCI 环境”菜单自动安装最新版本
- 脚本的“检查 OCI 环境”菜单也支持在缺失依赖时自动尝试安装

脚本自动安装系统依赖时，会优先使用当前系统可用的包管理器：
`apt-get`、`dnf`、`yum`、`pacman`、`zypper`、`apk` 或 `brew`。
脚本会自动尝试安装缺失的 `jq`、`curl`、Python 3/venv、`ssh-keygen`、`column` 对应包和 OCI CLI。
脚本会记录自己安装过的系统包，卸载脚本时会自动清理这些记录中的依赖；用户原本已安装的依赖不会被记录，也不会被自动卸载。

## 快速开始

```bash
# 方式 1：下载后本地运行
./oracle_oci_tool.sh

# 方式 2：直接远程运行
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_oci_tool.sh)
```

无论使用哪种方式，脚本数据默认都会保存在 `~/.oracle_oci_tool`，避免因切换启动方式而丢失任务、通知配置或创建配置。

## 主菜单

| 选项 | 描述 |
|------|------|
| 1 | 检查 OCI 环境 |
| 2 | 初始化 OCI 配置 |
| 3 | 查看 OCI 配置 |
| 4 | 管理实例 |
| 5 | 创建实例 |
| 6 | 管理后台任务 |
| 7 | 配置通知 |
| 8 | 卸载脚本 |
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
4. 下载或创建私钥文件（默认放在 `~/.oracle_oci_tool/oci/oci_api_key.pem`）

### 通知（可选）

通过菜单选项 `[7] 配置通知` 配置通知方式：
- 邮件：脚本内置 QQ 邮箱 `smtp.qq.com:465` 和 163 邮箱 `smtp.163.com:465` 默认值；密码一般填写邮箱授权码，不是登录密码
- Telegram：在 Telegram 搜索 `@BotFather`，发送 `/newbot` 创建机器人，复制返回的 Token 作为 TG Bot ID/Token；先给机器人发送任意消息后，脚本会尝试自动获取 Chat ID
- 也可以选择邮件 + Telegram，或关闭通知

## 数据目录

默认数据目录：

```text
~/.oracle_oci_tool/
├── bin/
│   └── oci
├── oracle-cli/
│   └── installations/
├── oci/
│   ├── config
│   └── oci_api_key.pem
├── ssh/
│   ├── oci_instance_key
│   └── oci_instance_key.pub
├── notification_config.conf
├── tasks/
├── update_instance_config.json
├── create_instance_config.json
├── create_instance_beginner.json
└── create_instance_config.draft.json
```

说明：
- 本地执行 `./oracle_oci_tool.sh` 和远程执行 `bash <(curl ...)` 使用同一个数据目录
- 首次运行新版脚本时，如旧数据仍在脚本目录中，会自动迁移常见配置和任务到 `~/.oracle_oci_tool`
- 首次运行新版脚本时，如检测到旧 `~/.oci/config` 且数据目录中尚无 OCI 配置，会自动复制到 `~/.oracle_oci_tool/oci/config`
- 首次运行新版脚本时，如检测到旧 `email_config.conf`，会自动迁移为 `notification_config.conf`
- 脚本运行时通过临时环境变量 `OCI_CLI_CONFIG_FILE` 使用数据目录中的 OCI 配置，不需要写入 shell rc 文件
- 如需自定义目录，可在运行前设置环境变量 `OCI_TOOL_HOME`
- 通过“卸载脚本”功能时，可选择是否删除此数据目录

## 脚本文件

```text
./
└── oracle_oci_tool.sh      # 主脚本
```

## 后台任务

- 任务在后台运行，支持自动重试或固定间隔请求
- 支持“更新实例”和“创建实例”两类任务
- 直接更新实例任务使用 `request_interval` 控制请求间隔，默认 60 秒；请求本身未返回时，下一次请求仍会按间隔发起
- 完整更新流程和创建实例任务继续使用 `retry_interval` 作为失败后的重试间隔
- 执行次数在重启后保留
- 支持恢复已停止的任务
- 支持实时查看日志

## 卸载说明

- 主菜单提供 `[8] 卸载脚本`
- 可交互式选择是否停止后台任务、删除数据目录、删除 OCI 配置、删除私钥、清理旧 `~/.oci`
- 会尽力删除常见 OCI CLI 安装文件
- 会自动卸载脚本记录过的系统依赖（如 `jq`、`curl`、Python 3/venv、`column` 对应包）

## 创建实例参数说明

- 一键创建实例会复用区间默认值，并查询可用性域、子网和镜像 ID；查询结果中如包含已保存值则继续使用已保存值，否则使用第一个查询结果
- 如果查询不到子网，一键创建实例会询问是否创建子网；子网创建流程默认创建公有子网，也可取消并跳过设置 `subnetId`
- 如果查询不到其他必要资源，一键创建实例会停止并提示先人工处理；如缺少 SSH 公钥，会在数据目录自动生成密钥对
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

- 通知配置文件（`notification_config.conf`）可能包含 SMTP 凭证和 Telegram Bot ID/Token
- 所有敏感文件已自动添加到 `.gitignore`
- **切勿将** `notification_config.conf`、旧版 `email_config.conf` 或 `tasks/` 目录提交到版本控制系统

## 开源协议

MIT License
