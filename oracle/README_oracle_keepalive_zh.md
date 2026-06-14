# Oracle Always Free 保活脚本

`oracle_keepalive.sh` 是一个低干扰资源保活脚本，用于让 Oracle Always Free 实例在 CPU、内存和网络维度保持一定活跃度，降低被判定为空闲的概率。

> 说明：云厂商的空闲判断和回收策略可能变化，本脚本不能保证一定避免回收。请自行确认使用方式是否符合 Oracle 服务条款。

## 功能特性

- 保活方式可选：CPU、内存、网络三类方式都可单独开关，但至少需要启用一项。
- CPU：按整机目标百分比做低优先级周期负载，默认约 25%。
- 内存：按目标使用率动态补足，默认目标 25%，占用后自动释放休息。
- 网络：低频、限速下载到 `/dev/null`，默认 45 分钟一次、每次 3 分钟、限速 `512k`。
- 交互式菜单：无参数运行脚本即可选择前台运行、安装、卸载、状态、日志、检查和验证。
- 验证：`verify` 命令会检查已启用方式是否达到目标或可用。
- systemd：支持一键安装、卸载、查看状态和日志。
- 低干扰：systemd 服务默认使用 `Nice=19`、`CPUWeight=1`、`CPUQuota=<在线 CPU 核数 × 目标百分比>%`、`IOSchedulingClass=idle`、`OOMScoreAdjust=500`。
- 安全清理：前台运行收到停止信号时会清理 CPU、内存和网络子进程；锁目录不会被递归删除。

## 文件位置

源码文件：

```text
oracle/oracle_keepalive.sh
```

安装后默认位置：

```text
/usr/local/bin/oracle_keepalive.sh
/etc/oracle-keepalive.conf
/etc/systemd/system/oracle-keepalive.service
/run/oracle-keepalive.lock/
```

## 快速开始

### 本地运行

推荐直接打开交互式菜单：

```bash
bash oracle_keepalive.sh
```

菜单中可以选择前台运行、安装 systemd 服务、卸载、查看状态、查看日志、检查配置和验证保活方式。

如果需要自动化，也可以继续使用命令参数。前台试运行：

```bash
bash oracle_keepalive.sh run
```

按 `Ctrl+C` 停止。

安装 systemd 服务：

```bash
sudo bash oracle_keepalive.sh install
```

安装后会自动执行：

```bash
systemctl daemon-reload
systemctl enable --now oracle-keepalive.service
```

### 远程运行

```bash
# 打开交互式菜单
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh)

# 自动化兼容：仍可直接指定命令
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh) help
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh) check
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh) verify
```

如果当前 shell 不支持进程替换，可使用管道方式：

```bash
curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh | bash -s -- check
```

也可以直接远程前台运行保活进程：

```bash
bash <(curl -sL https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh) run
```

安装 systemd 服务需要 root 权限。技术上可以一键远程执行，但更建议先下载、审阅脚本，再执行安装：

```bash
curl -fsSLO https://raw.githubusercontent.com/yhj945/tools/main/oracle/oracle_keepalive.sh
less oracle_keepalive.sh
sudo bash oracle_keepalive.sh install
```

### 查看状态

```bash
bash oracle_keepalive.sh status
```

### 查看日志

```bash
bash oracle_keepalive.sh logs
```

### 卸载服务

```bash
sudo bash oracle_keepalive.sh uninstall
```

卸载会停止并禁用 `oracle-keepalive.service`，删除默认安装脚本和 unit 文件，并安全清理锁文件。

## 命令参考

| 命令 | 说明 |
|------|------|
| 无参数 | 打开交互式菜单 |
| `run` | 前台运行保活守护进程 |
| `install` | 安装并启动 systemd 服务 |
| `uninstall` | 停止并移除 systemd 服务 |
| `status` | 查看 systemd 服务状态 |
| `logs` | 跟随 systemd 日志 |
| `check` | 检查脚本默认配置是否可解析，并确认至少启用一项保活方式 |
| `verify` | 验证已启用的保活方式是否达到目标或可用 |
| `help` | 显示帮助信息 |

## 配置项

安装后可编辑：

```text
/etc/oracle-keepalive.conf
```

默认配置：

```bash
KEEPALIVE_CPU_ENABLED=1
KEEPALIVE_CPU_TARGET_PERCENT=25
KEEPALIVE_CPU_CYCLE_SECONDS=10
KEEPALIVE_MEMORY_ENABLED=1
KEEPALIVE_MEMORY_TARGET_PERCENT=25
KEEPALIVE_MEMORY_MAX_MB=0
KEEPALIVE_MEMORY_HOLD_SECONDS=300
KEEPALIVE_MEMORY_REST_SECONDS=300
KEEPALIVE_NETWORK_ENABLED=1
KEEPALIVE_NETWORK_INTERVAL_SECONDS=2700
KEEPALIVE_NETWORK_DURATION_SECONDS=180
KEEPALIVE_NETWORK_RATE_LIMIT=512k
KEEPALIVE_NETWORK_URLS="https://speed.cloudflare.com/__down?bytes=1000000000 https://speed.hetzner.de/1GB.bin http://proof.ovh.net/files/1Gio.dat"
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `KEEPALIVE_CPU_ENABLED` | `1` | 是否启用 CPU 保活；`0` 表示关闭 |
| `KEEPALIVE_CPU_TARGET_PERCENT` | `25` | 整机 CPU 目标百分比，脚本会限制在 1-80 之间 |
| `KEEPALIVE_CPU_CYCLE_SECONDS` | `10` | CPU busy/rest 调度周期 |
| `KEEPALIVE_MEMORY_ENABLED` | `1` | 是否启用内存保活；`0` 表示关闭 |
| `KEEPALIVE_MEMORY_TARGET_PERCENT` | `25` | 目标内存使用率，脚本会按当前可用内存动态补足 |
| `KEEPALIVE_MEMORY_MAX_MB` | `0` | 单轮最大内存占用；`0` 表示自动按可用内存保守计算 |
| `KEEPALIVE_MEMORY_HOLD_SECONDS` | `300` | 每轮内存占用保持时间 |
| `KEEPALIVE_MEMORY_REST_SECONDS` | `300` | 每轮释放后的休息时间 |
| `KEEPALIVE_NETWORK_ENABLED` | `1` | 是否启用网络保活；`0` 表示关闭 |
| `KEEPALIVE_NETWORK_INTERVAL_SECONDS` | `2700` | 网络保活间隔，默认 45 分钟 |
| `KEEPALIVE_NETWORK_DURATION_SECONDS` | `180` | 每次网络下载最长持续时间 |
| `KEEPALIVE_NETWORK_RATE_LIMIT` | `512k` | `curl` / `wget` 下载限速 |
| `KEEPALIVE_NETWORK_URLS` | 多个公开测速文件 URL | 网络保活下载源列表，空格分隔 |

修改配置后重启服务：

```bash
sudo systemctl restart oracle-keepalive.service
```

至少需要启用 `KEEPALIVE_CPU_ENABLED`、`KEEPALIVE_MEMORY_ENABLED`、`KEEPALIVE_NETWORK_ENABLED` 中的一项；如果全部为 `0`，`check`、`install`、`run` 和 `verify` 都会拒绝继续执行。

### 验证是否达标

```bash
bash oracle_keepalive.sh verify
```

`verify` 只检查已启用的方式：

- CPU：对比当前观测值和 `KEEPALIVE_CPU_TARGET_PERCENT`。脚本支持通过 `KEEPALIVE_VERIFY_CPU_PERCENT` 传入外部监控采样值，便于结合云监控或自动化测试。
- 内存：对比当前内存使用率和 `KEEPALIVE_MEMORY_TARGET_PERCENT`。也可通过 `KEEPALIVE_VERIFY_MEMORY_PERCENT` 传入外部采样值。
- 网络：使用当前网络保活 URL 执行一次限时、限速下载，验证网络方式可用。

注意：Oracle 的 7 天窗口和 95 分位 CPU 规则不能通过一次本地采样完全证明，`verify` 用于确认当前选择的策略能产生对应负载或网络请求可用。长期是否达标仍应结合 OCI 控制台监控曲线确认。

注意：`KEEPALIVE_CPU_TARGET_PERCENT` 会同时影响脚本内部 CPU 调度目标和安装时生成的 systemd `CPUQuota` 上限。安装后只编辑 `/etc/oracle-keepalive.conf` 并重启服务时，脚本内部目标会更新，但 unit 中已有的 `CPUQuota` 不会自动重写。如果要把 CPU 目标提高到高于当前 `CPUQuota`，请重新执行 `sudo bash oracle_keepalive.sh install`，或手动修改 `/etc/systemd/system/oracle-keepalive.service` 后执行：

```bash
sudo systemctl daemon-reload
sudo systemctl restart oracle-keepalive.service
```

## dry-run

安装前可以预览会写入的配置和 systemd unit：

```bash
ORACLE_KEEPALIVE_DRY_RUN=1 bash oracle_keepalive.sh install
```

## 注意事项

- 网络保活只做限速下载，不做上传，不执行 speedtest。
- 内存保活会优先使用 `python3` 分配并触碰内存页；没有 `python3` 时回退到临时文件方式。
- 默认参数偏保守，正常业务进程优先级高于保活进程。
- 如果实例本身已有稳定业务负载，可以降低或关闭对应保活项。
- 本脚本只负责 CPU、内存和网络保活，不部署应用服务，也不验证应用服务健康。
- 本脚本不读取 OCI API 密钥，不调用 OCI API。

## 故障排查

### 服务启动失败

```bash
systemctl status oracle-keepalive.service --no-pager
journalctl -u oracle-keepalive.service -n 100 --no-pager
```

### CPU 占用过高

降低：

```bash
KEEPALIVE_CPU_TARGET_PERCENT=10
```

然后重启服务。

### 网络流量过高

降低限速或关闭网络保活：

```bash
KEEPALIVE_NETWORK_RATE_LIMIT=128k
# 或
KEEPALIVE_NETWORK_ENABLED=0
```

### 内存压力过大

降低目标或设置上限：

```bash
KEEPALIVE_MEMORY_TARGET_PERCENT=15
KEEPALIVE_MEMORY_MAX_MB=512
```

## 开源协议

MIT License
