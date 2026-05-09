# Codex 配额用量分析工具

一个用于在 chatgpt.com 页面内分析 Codex 配额用量的 Tampermonkey 用户脚本。它将原始配额计算逻辑封装为页面看板，直接把用量数据整理成表格展示，支持本地缓存最近一次分析结果，并可导出 JSON。

<!-- AUTO-GENERATED:START -->
## 功能特性

- **页面内看板**：在 chatgpt.com 页面右下角增加悬浮控制按钮和分析窗口
- **限制窗口概览**：展示主限制与额外限制的 5 小时窗口、7 天窗口，以及 UTC/本地重置时间
- **周额度估算**：根据 7 天窗口的 `used_percent` 反推总周额度与剩余额度
- **用量汇总**：展示上次重置至今、本月初至今、近一段时间的用量汇总
- **每日明细**：展示每日 Credits、折算 USD、用户数、线程数、轮数和 Token 数
- **客户端拆分**：按 client ID 汇总各时间范围内的用量
- **时区诊断**：展示浏览器时区、UTC 偏移、后端时间、日期桶边界等诊断信息
- **本地缓存**：使用 `localStorage` 保存最近一次渲染结果和可导出数据
- **JSON 导出**：将最近一次分析结果导出为带时间戳的 JSON 文件
- **手动 Token 兜底**：自动获取授权失败时，可临时在本机填写 `CONFIG.MANUAL_ACCESS_TOKEN`
<!-- AUTO-GENERATED:END -->

## 系统要求

- 支持用户脚本的浏览器
- Tampermonkey 或兼容的用户脚本管理器
- 已登录的 chatgpt.com 会话
- 当前账号可访问 ChatGPT Web 使用的 Codex 用量 API

## 安装方式

1. 安装 Tampermonkey 或其他兼容的用户脚本管理器。
2. 新建一个用户脚本。
3. 将 `codex-quota-compass.js` 的全部内容复制到用户脚本编辑器中。
4. 保存用户脚本。
5. 打开或刷新 `https://chatgpt.com/` 页面。

## 快速开始

```text
openai/
└── codex-quota-compass.js      # Tampermonkey 用户脚本
```

安装完成后：

1. 打开 `https://chatgpt.com/` 并确认已登录。
2. 点击右下角悬浮看板按钮。
3. 在菜单中选择“运行全量分析”。
4. 等待脚本拉取用量数据并渲染表格。
5. 如需保存结果，可选择“导出数据 JSON”。

## 菜单说明

<!-- AUTO-GENERATED:START -->
| 操作 | 说明 |
|------|------|
| 运行全量分析 | 拉取用量 API，计算配额估算结果，并渲染看板 |
| 显示/隐藏窗口 | 切换分析窗口显示状态 |
| 导出数据 JSON | 下载最近一次可用的分析数据 |
| 清空缓存 | 删除 `localStorage` 中缓存的分析结果 |
| 关闭菜单 | 隐藏悬浮操作菜单 |
<!-- AUTO-GENERATED:END -->

## 数据来源

<!-- AUTO-GENERATED:START -->
脚本读取同源 ChatGPT 接口数据：

| 接口 | 用途 |
|------|------|
| `/api/auth/session` | 从当前已登录浏览器会话中尝试查找 access token |
| `/backend-api/wham/usage` | 读取当前限制窗口与已用百分比 |
| `/backend-api/wham/analytics/daily-workspace-usage-counts` | 读取按天聚合的用量分析数据 |
<!-- AUTO-GENERATED:END -->

脚本使用带 `credentials: include` 的浏览器 `fetch` 请求，因此依赖当前浏览器登录状态。脚本不会把拉取到的数据发送到任何第三方服务器。

## 配置说明

<!-- AUTO-GENERATED:START -->
配置常量定义在 `buildAnalysisData()` 内部：

| 常量 | 默认值 | 说明 |
|------|--------|------|
| `DATE_BUCKET_MODE` | `utc` | API 查询边界使用的日期桶口径 |
| `USD_PER_CREDIT` | `40 / 1000` | 汇总表中使用的近似 USD 折算比例 |
| `ROLLING_DAYS` | `30` | 近一段时间汇总使用的天数 |
| `MANUAL_ACCESS_TOKEN` | 空字符串 | 可选的本机临时 token 兜底配置 |
| `USAGE_PATH` | `/backend-api/wham/usage` | 限制窗口概览接口 |
| `DAILY_USAGE_PATH` | `/backend-api/wham/analytics/daily-workspace-usage-counts` | 每日用量分析接口 |
<!-- AUTO-GENERATED:END -->

仅在自己的电脑上临时修改 `MANUAL_ACCESS_TOKEN` 进行排障。不要分享包含 token、Cookie 或 Authorization 请求头的脚本、截图或日志。

## 缓存数据

默认浏览器存储键：

```text
codex-quota-compass:last-analysis
```

缓存对象包含：

- 已渲染的看板 HTML
- 最近一次分析时间
- 可导出的结构化分析数据

可通过用户脚本菜单中的“清空缓存”删除缓存。

## 导出数据

JSON 导出文件名格式：

```text
codex-quota-compass-YYYYMMDD-HHMMSS.json
```

导出数据包含：

- 导出时间
- 配置值
- 时区诊断
- 限制窗口概览
- 周额度估算
- 每日用量明细
- 客户端用量汇总

## 分析口径说明

- `end_date` 是排他边界。
- daily analytics 只能按天聚合，无法精确切到小时或分钟。
- 7 天额度估算是近似值，因为它同时依赖按天聚合数据和整数形式的 `used_percent`。
- 如果当天没有返回，通常是后端 daily analytics 尚未刷新，或当天暂无统计。

## 注意事项及免责声明

### 免责声明

1. **账号责任**：因使用本脚本导致的账号限制、服务终止或其他后果，**用户自行承担全部责任，作者概不负责**。

2. **无后门**：本脚本生成的所有数据均**只存储在浏览器本地**，**无远程服务器、无后门、无数据收集机制**。

3. **使用风险**：本脚本会通过当前登录浏览器会话访问 ChatGPT Web API。不当使用可能违反服务条款或触发账号限制。请在使用前自行了解相关服务政策。

4. **无担保**：本软件按“原样”提供，不提供任何形式的明示或暗示担保。

### 安全提示

- 浏览器会话、Cookie 和 bearer token 都属于敏感凭证。
- 不要把 access token 粘贴到共享代码、Issue、截图、日志或聊天消息中。
- 如使用 `CONFIG.MANUAL_ACCESS_TOKEN`，排障完成后应及时清空。
- 缓存和导出的 JSON 可能包含用量元数据，分享前请先审查内容。

## 开源协议

MIT License

## 致谢

本脚本基于 [BlueSkyXN 的原始逻辑](https://gist.github.com/BlueSkyXN/528e810b98affcecca170e6b9d53d7da) 实现。
