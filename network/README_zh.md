# Linux VPS 网络调优

`net_tune.py` 用于查看 VPS 的网络配置、按流量预算测速，并根据结果生成调优方案。直接运行只读取本机信息。调优方案会在应用前显示原值和新值，应用后可以回滚。

当前版本为 **1.0.0**。支持五种优化侧重点、业务路径对比，以及 TCP 参数和 GSO 的开机加载。

## 快速开始

### 1. 在要调优的 VPS 上查看现状

**本地运行**。将 `net_tune.sh` 和所有 `net_tune*.py` 放在同一目录，进入该目录执行。

```bash
bash net_tune.sh --install-deps
```

**直接远程运行**。在 Linux VPS 的 Bash 终端中执行，需要 `curl` 能访问 GitHub。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yhj945/tools/main/network/net_tune.sh) --install-deps
```

`--install-deps` 会用当前系统的软件包管理器自动补齐缺失的 Python、网络工具和 iperf3，需要 root 或 `sudo` 权限。依赖已齐时，去掉这个参数即可只读查看本机。本地也可直接运行 `./net_tune.py`。远程入口每次下载同一份代码快照，运行完会清理临时文件。测速预算从实际测速开始计算，启动时下载脚本和软件包另占流量。

输出包含默认路由、网卡和当前 TCP 参数。只想看系统、CPU、内存和出口网卡的概况时，可以运行 `./net_tune.py auto`，无需准备测速机。

### 选择优化侧重点

使用 `--mode` 选择目标。默认是均衡模式。模式会改变测试负载和优选标准，最终参数仍取决于机器配置及同路径实测；不会仅凭模式名称套用一组固定参数。

| 模式 | 参数 | 优先改善 |
| --- | --- | --- |
| 均衡 | `--mode balanced` | 小请求、下载、并发与空闲后恢复的整体表现 |
| 下载 | `--mode download` | 单流下载吞吐，同时保护响应耗时和完成率 |
| 日常使用 | `--mode daily` | 网页与接口的小请求、首字节、并发资源和空闲后首次响应 |
| 稳定性 | `--mode stability` | 超时、慢请求和重传；允许不超过 10% 的中位耗时/吞吐取舍 |
| 并发 | `--mode concurrency` | 多请求同时传输的总吞吐，同时保护最慢请求 |

```bash
./net_tune.py auto --mode daily
./net_tune.py auto --mode stability
```

下载/均衡的传输初筛可继续使用下面的 iperf3 流程；日常、稳定性、并发请看[业务测试](#测日常访问与偶发卡顿)。

这两条命令只识别本机、选择目标，不测速或修改配置。稳定性模式不能保证修复机房拥塞、Wi-Fi 干扰等链路问题；没有候选通过验收时保留原配置。

### 2. 在测速机上启动 iperf3

使用自己管理或已获准使用的测速机。VPS 和测速机都需要 iperf3 3.9 或更新版本。在**测速机**上运行以下命令，并确保 VPS 能访问它的 TCP 5201 端口。

```bash
iperf3 -s -J
```

### 3. 回到 VPS，测速并确认方案

把 `PEER` 换成测速机的 IP 或域名。先用第一条命令估算轮数和流量，再运行第二条命令测速。若有可应用的方案，终端会列出变更并等待确认。输入 `y` 后回车即可应用，直接回车则取消。已用 root 登录时可以省略 `sudo`。

```bash
./net_tune.py auto --peer PEER --dry-run
sudo ./net_tune.py auto --peer PEER --apply
```

远程入口也接受这些子命令。应用或回滚时，在 root 的 Bash 终端中运行，例如先用 `sudo bash` 进入管理员终端。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yhj945/tools/main/network/net_tune.sh) auto --peer PEER --apply
```

自动调优测的是 VPS 到测速机的 TCP 上行单流，结果用于选择拥塞控制和调整 TCP 发送缓冲区上限。样本不足或没有可应用的变更时，工具会给出原因。

默认测速目标为 **20 Mbps**，单次命令的流量预算为 **128 MiB**。可用 `--rate-mbps` 和 `--budget-mib` 修改。首轮、失败和超时都计入预算。预算按测速负载和预留余量计算，云厂商账单还可能计入协议开销和重传。

想实测并查看建议，可以省略 `--apply`。随后再带 `--apply` 运行会重新测速并使用本次预算。想比较调优前后的收益，可在应用前[保存一份基线报告](#对比调优前后的效果)。

## 查看结果和回滚

```bash
sudo ./net_tune.py status
```

`status` 显示当前 TCP 配置、脚本管理的启动配置和事务历史。撤销最近一次有效调优时，先预览将恢复的内容，再执行并确认。

```bash
sudo ./net_tune.py rollback --dry-run
sudo ./net_tune.py rollback
```

应用失败时，工具会自动尝试撤销本次写入。恢复信息保存在 `/var/lib/net-tune/`，进程被强制结束或主机掉电后可用 `rollback` 继续恢复。若相关配置后来被其他工具修改，回滚会报告冲突并保留后来写入的值。

## 对比调优前后的效果

在应用前保存 `before.json`。以下示例在指定对端测 TCP 上行和下行，各测 1 流和 4 流，每轮 3 秒。速率是并发流的合计目标。第一条命令预览轮数和流量，第二条命令生成报告。

```bash
./net_tune.py bench --peer PEER --rates-mbps 20 --budget-mib 256 --dry-run
./net_tune.py bench --peer PEER --rates-mbps 20 --budget-mib 256 > before.json
```

应用后，在同一主机、同一启动周期内，用相同对端、出口、测试参数和流量预算生成 `after.json`，再查看差值。

```bash
./net_tune.py bench --peer PEER --rates-mbps 20 --budget-mib 256 > after.json
./net_tune.py compare before.json after.json
```

对比结果包括接收吞吐、负载下的 RTT p95、每 MiB 重传和 CPU 用量。可增加 `--rounds` 观察多轮吞吐波动，并用 `--dry-run` 重新估算流量。想了解代理下载等业务的改善幅度，应在实际业务路径上用相同对端和预算复测。

### 测日常访问与偶发卡顿

使用 `web` 测小请求、下载保护、并发请求和空闲后恢复。下面用公开测速对象演示，所有请求都计入预算。完整对比应使用支持 `{bytes}` 返回指定大小内容的地址，或支持 HTTP Range 的固定文件（至少 1 MiB），并确认文件足够覆盖所选模式的下载负载。这样同一地址才能同时测小请求和下载。

```bash
# 先预览，不访问网络
./net_tune.py web --mode daily --url 'https://speed.cloudflare.com/__down?bytes={bytes}' --dry-run

# 按 128 MiB 预算测试，保存完整报告
./net_tune.py web --mode daily --url 'https://speed.cloudflare.com/__down?bytes={bytes}' \
  --budget-mib 128 > web-before.json
```

没有本地脚本时，也可直接远程预览；去掉末尾的 `--dry-run` 才会开始业务测试：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yhj945/tools/main/network/net_tune.sh) \
  web --mode daily --url 'https://speed.cloudflare.com/__down?bytes={bytes}' --budget-mib 128 --dry-run
```

普通网页可以观察状态码和响应计时。正文超过当前请求上限时会记录体积上限错误；HTML 小页面不能作为下载吞吐的优选依据。

在 VPS 上执行，测的是 VPS 到网站的路径。要测实际代理体验，应在 Linux 客户端执行，并指定现有代理端口，例如加 `--proxy socks5h://127.0.0.1:7890`。测试不会更改代理选择或系统网络配置。HTTP 连接需要绑定出口时可加 `--interface`；使用回环代理时，由代理程序控制其外网出口。

`--url` 可重复指定。测速服务若支持在 URL 中用大小参数返回固定内容，可使用 `{bytes}` 占位符，由工具代入各负载的字节数。需要固定对端时用 `--resolve HOST:PORT:ADDRESS`。

也可以让 `auto` 显示易读的业务基线摘要：

```bash
./net_tune.py auto --mode daily --web-url 'https://speed.cloudflare.com/__down?bytes={bytes}' --budget-mib 128
```

单份基线不能证明某套配置更好，所以这一步不生成应用项。完成受控变更后，用完全相同的命令生成 `web-after.json`，比较所选目标：

```bash
./net_tune.py compare web-before.json web-after.json --mode daily
```

业务测试区分连接/传输失败、HTTP 应用响应、重定向和体积上限；HTTP 403/429 等不直接当成网络断流。固定路径对照请使用最终 URL，3xx 重定向保留原状态，不隐式换站或追加请求。

业务测试会记录成功/失败、首字节、请求完成时间、p95 和空闲连接是否复用。默认 3 轮，空闲请求间隔 20 秒；稳定性模式为 60 秒。可用 `--rounds`、`--idle-seconds`、`--timeout`、`--deadline` 调整。p95 应结合样本数解读，3 个样本时它就是最慢的那个样本。

预算在每组请求发起前全额预留，计入所有并发请求、空闲前后两个请求、两段代理业务链路估算及余量；失败和中断不退款。报告中的 `complete` 表示测试矩阵执行完毕，具体请求是否成功查看 `summary` 的完成数和失败数。测试不执行 JavaScript，也不等于浏览器完整首屏；重传未采集时记录为 `null`，不当成零重传。

使用代理时，远端 DNS 无法从客户端计时中单独分离，DNS 值为 `null`；连接计时只表示客户端可见的连接阶段。DNS、连接、TLS、首字节各阶段计时不能直接相加。

空闲测试使用同一 HTTP/1.1 连接，支持直接 HTTP(S)、无认证 SOCKS5 和 HTTP CONNECT 代理。测试只依赖 Python 标准库和 curl 7.29+，`--install-deps` 会补齐缺失的 curl。浏览器的 HTTP/2、HTTP/3 和客户端实际路由仍需要按业务单独验证。

<details>
<summary>更多测速选项和报告说明</summary>

- 用 `-4`、`-6`、`--source`、`--port` 固定 IP 版本、源地址和端口。用 `--rates-mbps 20,40,60` 测多个速率档位。
- `--protocol udp` 记录接收端丢包和抖动。测速机需允许相应的 UDP 端口，旧版 iperf3 的上行 UDP 汇总还需要服务端用 `-J` 启动。
- 每轮发起前先预留预算，包括并发流、空载 RTT 探测和重试。失败、超时和中断按该轮预留全额计入。预算不足或达到总时限时，工具会停止安排后续轮次。`--dry-run` 会显示正常负载估算、最大单轮预留和失败重试上界。测速机需遵循请求的速率。
- 报告会记录实际出口和负载期间的 TCP RTT。下行 RTT 优先从对端发送流采集。TCP 上行可用 `ss` 和 `stdbuf` 记录重传字节，按每 MiB 接收数据归一化，便于比较不同 MSS。缺失的指标在 JSON 中显示为 `null`。

</details>

## 从报告生成和应用计划

已有报告时，可以直接使用本地文件进行自动选型。

| 手头的报告 | 查看建议 |
| --- | --- |
| `bench` 生成的完整报告 | `./net_tune.py auto --from-bench before.json` |
| 同一业务路径的配对实测记录（`net-tune-results-v1` 格式） | `./net_tune.py auto --from-results results.json` |
| 同一配置基线、四类业务负载的配对记录（`net-tune-results-v2`） | `./net_tune.py auto --from-results results.json --mode daily` |

报告需来自当前主机、启动周期和网络命名空间，且测速出口仍一致。使用配对记录时，工具会核对当前配置，并在相同的下载大小和轮数下比较完成率、吞吐和重传。

<details>
<summary>受控测试与业务配对记录（高级）</summary>

业务配对记录可以由受控测试流程生成，`net_tune_web.paired_web(before, after)` 可将两份同路径 `web` 报告转成配对负载。导入选型时，顶层仍须包含要调优主机的 `scope`、`peer`、`interface`、`baseline` 和各候选的 `settings/workloads`；客户端观察机不能冒充 VPS。下载配对记录（`net-tune-results-v1`）只支持均衡/下载初筛，日常、稳定性和并发模式需要包含四类业务负载的 `net-tune-results-v2` 记录。

业务选优要求至少三对小请求、下载、并发、空闲恢复证据。完成率不能下降，p95 耗时回退不能超过 10%，有至少三对重传数据时，重传字节不能增加超过 5%；中位耗时/吞吐通常允许 5% 波动，稳定性模式放宽到 10%。完成率提高或目标改善达到 5% 时可判定收益，稳定性模式也可依据已采集的重传下降至少 25% 判断。首字节、吞吐或重传缺失时会明确标注，不补造数据。URL、观察机、边缘节点或负载不一致的记录不参与优选。

</details>

确认要应用时，用 `sudo` 运行对应的 `auto` 命令并加上 `--apply`。工具会复用报告，预览后等待确认。

需要保存计划文件，或手动指定调优选项时，用 `plan` 生成 JSON，再用 `apply` 预览和执行。

```bash
./net_tune.py plan --from-bench before.json --json > plan.json
./net_tune.py apply plan.json --dry-run
sudo ./net_tune.py apply plan.json
```

这份计划使用报告中的单流吞吐、空载 RTT 和本机可用内存估算缓冲区上限，按需提高上限。也可填入业务实测值，例如 `--bandwidth-mbps 500 --rtt-ms 80`。已确认的批处理可在应用命令后加 `--yes`，仍会显示预览。

<details>
<summary>指定或比较 TCP 拥塞控制算法</summary>

知道要使用哪个算法时，可在 `plan` 中指定 `--cc bbr` 等内核支持的算法。需要用报告自动选择时，生成计划时加 `--cc auto`。下面的例子对照 CUBIC 和 BBR，需两端支持相关算法，且当前算法是其中之一。

```bash
./net_tune.py bench --peer PEER --direction up --streams 1 \
  --rates-mbps 20 --rounds 3 --cc cubic,bbr > ab.json
./net_tune.py plan --from-bench ab.json --cc auto --json > plan.json
```

选型至少需要三对可确认发送端算法的同轮样本，比较最高档位的上行单流吞吐、负载 RTT 和重传。每对允许的波动为吞吐下降 5%、负载 RTT 上升 10%、重传增加 10% 或一个绝对门槛（取较大值）。至少四分之三的配对要在同一指标上达标，分别为吞吐提高 5%、负载 RTT 降低 20%，或重传下降至少 25% 且达到绝对门槛。

每 MiB 接收数据的重传字节记录齐全时，绝对门槛为 1 KiB。按重传次数比较时，门槛为每 MiB 1 次。基线吞吐达到目标速率的 90% 时，该对样本用于判断 RTT 和重传收益。

</details>

### 重启后继续生效

调优默认在本次启动内生效。需要重启后继续加载时，在 `auto` 或 `plan` 中加 `--persist`，再预览和应用。TCP 参数写入 `/etc/sysctl.d/90-net-tune.conf`，工具会检查启动加载器和配置覆盖。

GSO 也支持开机加载。例如，已经实测确认单段 GSO 有收益后，可以这样保存；即使当前值已经为 1，也会补齐启动配置：

```bash
sudo ./net_tune.py plan --interface eth0 --gso-single-segment --persist --json > gso-plan.json
sudo ./net_tune.py apply gso-plan.json --dry-run
sudo ./net_tune.py apply gso-plan.json
sudo ./net_tune.py status
```

GSO 启动服务支持 systemd 和 OpenRC，按网卡名和 MAC 地址校验身份，等待网络就绪后设置上限。启动助手保存在 `/usr/local/lib/net-tune/`，不依赖远程运行时的临时目录。应用失败会自动恢复启动文件、服务状态及运行值；使用 `rollback` 也会撤销持久化。重启后回滚 GSO 时，恢复的是该次启动在服务运行前记录的值。

网卡队列和路由调整仍只在本次启动内生效。`--persist` 不会把这些运行时调整加入开机配置。

<details>
<summary>GSO 是什么，为什么要按路径测试？</summary>

GSO（Generic Segmentation Offload，通用分段卸载）让 Linux 在内部先处理较大的数据块，临近发送时再按 MSS 拆成报文，减少逐包处理的 CPU 开销。可参阅 [Linux 内核说明](https://docs.kernel.org/networking/segmentation-offloads.html#generic-segmentation-offload)。

`--gso-single-segment` 将出口网卡的 `gso_max_segs` 上限设为 1。较小的批次可能减小发送突发，也可能增加 CPU 开销、影响大流量吞吐，所以应比较实际路径上的耗时、吞吐和重传后再保留。GSO 上限按“段”计数，MSS 按“字节”计数。

</details>

## 进阶调优

### VLESS 下载预设

把 `eth0` 换成实际出口网卡。可用 `./net_tune.py inspect --peer 203.0.113.20` 查询目标的出口，示例 IP 需替换为实际目标 IP。

```bash
./net_tune.py plan --profile vless --interface eth0 --json > vless.json
./net_tune.py apply vless.json --dry-run
```

预设需要内核支持 BBR，以及现有 `fq` 根队列或单根默认 `fq_codel`。它启用单分段 GSO 和从 1290 字节 MSS 起步的 TCP 路径 MTU 探测。在 `fq` 上按需启用 pacing，使用默认 `fq_codel` 时沿用现有队列。

应用前先在实际代理路径上记录基线。确认预览后可用 `sudo ./net_tune.py apply vless.json` 应用，再用相同对端和预算复测。新建连接和复用连接分别对照短下载、长下载的完成率、吞吐与重传字节。首个请求和失败请求都计入预算。

### 按路径实测调整单项参数

以下选项可加入 `plan --interface eth0 --json`，并按上面的步骤保存、预览和应用计划。示例数值需根据自己的路径实测选定。

| 要调的项目 | `plan` 选项 | 生效范围和条件 |
| --- | --- | --- |
| 单分段 GSO | `--gso-single-segment` | 将出口网卡的 GSO 分段上限设为 1 |
| TCP 路径 MTU 探测 | `--mtu-probe-mss 1290` | 在当前网络命名空间启用探测并设置起始 MSS，可与单分段 GSO 一起测试 |
| MTU 探测策略 | `--mtu-probing 0/1/2` | 分别为关闭、按需、始终探测；使用 VLESS 预设时保持 2 |
| 初始拥塞窗口 | `--initcwnd 48` | 单位为报文段。作用于 IPv4 主表默认路由的新连接，要求该路由唯一且可恢复 |
| 默认路由 MTU | `--route-mtu 1342` | 单位为字节。作用于经过 IPv4 主表默认路由的流量，上限为出口网卡的 MTU |
| `fq` 发包节奏 | `--enable-fq-pacing` | 启用现有 `fq` 根队列的 pacing。需要写入时，队列须有显式非零句柄，且未设置 `maxrate` |
| 出向整形 | `--shape-mbps 95 --shaper cake` | 作用于目标网卡的全部出向流量，只接管可恢复的单根默认队列，也支持 `--shaper tbf` |

当提高测速档位后吞吐趋于平稳、丢包或重传却上升时，计划可给出整形建议。确认整形速率时复测吞吐和负载 RTT。需要改动已有的整形速率时，可先回滚原事务，再生成新计划。

## 环境要求和帮助

适用于 Debian、Ubuntu、RHEL 系列（含 Rocky Linux、AlmaLinux）、Fedora、openSUSE、Arch Linux 和 Alpine 的常规 VPS 环境。容器和受限 VPS 可用的功能取决于内核和网络命名空间权限。

需要 Python 3.8 或更新版本，无需额外的 Python 包。自动安装支持 `apt-get`、`dnf`、`yum`、`pacman`、`zypper` 和 `apk`。若系统仓库缺少所需包或提供的版本过旧，请先安装满足版本要求的工具。

| 用途 | 需要的组件或权限 |
| --- | --- |
| 查看系统和网络状态 | 可读的 `/proc`、`/sys`。查看路由、网卡和队列还需支持 JSON 输出的 iproute2（`ip`、`tc`）。Alpine 需要完整的 iproute2 |
| 主动测速 | iperf3 3.9 或更新版本。安装 `ping` 可采集空载 RTT |
| HTTP 业务测试 | curl 7.29 或更新版本；空闲连接测试还会使用 Python 标准库 |
| 应用和回滚 | root 及目标网络命名空间的写权限。出向整形还需内核支持 CAKE 或 TBF |
| 持久化 TCP 参数 | systemd，或已启用 `sysctl` 启动服务且支持 `sysctl --system` 的 OpenRC |
| 持久化 GSO | systemd 或 OpenRC，以及可写 GSO 分段上限的内核和 iproute2 |

用 `./net_tune.py --help` 查看所有命令，也可用 `./net_tune.py bench --help` 查看单个命令的参数。

<details>
<summary>诊断输出和退出码</summary>

诊断 JSON 包含网卡统计、有效内存上限，以及 TCP、UDP 和 softnet 累计计数。比较累计计数时，观察相同时长内的增量。

退出码 `0` 表示成功或完成预览，`1` 表示输入、环境或写入错误，`2` 表示测速报告不完整，`130` 表示操作中断。

</details>

<details>
<summary>本地验证</summary>

在项目根目录运行。

```bash
python3 -m unittest discover -s network/tests -v
NET_TUNE_NETNS_TEST=1 python3 -m unittest discover -s network/tests -v
```

第二条命令需要支持非特权用户命名空间的 Linux，以及 `unshare`、`ip`、`tc`、`ss`、`rg`。提供 iperf3 时会在隔离命名空间里额外运行 IPv6 本地 TCP/UDP 测速。内核写入测试使用独立的网络、挂载和 PID 命名空间。

</details>
