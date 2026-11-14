# Tiny Usage

基于 [Mimir](https://github.com/erayendes/mimir) 的原生 macOS 菜单栏配额 App，首版支持 **Claude + Codex**。保留 Mimir 的配额卡片、模型细分、重置卡与到期时间；菜单栏独立实现服务图标、上下双条、时间游标及百分比，颜色按剩余量变化（≥50% 绿、20–49% 黄、<20% 红）。

Swift / AppKit / SwiftUI，macOS 14+。当前构建为 Apple Silicon 版本，无 WebView、Electron、Node 运行时或第三方 Swift 包依赖。

## 打开

构建产物位于 `dist/Tiny Usage.app`，双击即可启动。也可以在本目录执行：

```sh
open "dist/Tiny Usage.app"
```

默认显示剩余量。点击菜单栏打开卡片，右键可快速切换显示模式、样式和退出。设置里的「显示数值」（剩余量 / 已用量）同时作用于菜单栏和面板，颜色始终按剩余量判断；「菜单栏样式」「刷新频率」为下拉选择。

- **Claude**：优先使用新鲜的本地 statusLine 数据；完整数据按调度补充。首次没有数据时，在齿轮设置中选择“授权凭据”，或启用“Claude 免提示读取”。打开面板本身不会触发授权。
- **Codex**：读取已有 CLI 登录，查询配额和重置卡；网络失败后尝试本地配额事件与上次快照。
- **Claude Desktop**：在设置中打开“桌面版备用来源”，再按需授权。某些 Claude 重置卡字段只有这个来源提供。未确认属于同一组织时单独显示 Desktop 卡片。
- **重置卡**：显示数量、服务端提供的适用范围、到期倒计时。多张卡可展开查看；已到期的卡不继续列为可用。只展示数据，不自动消耗或兑换重置卡。
- **数据状态**：显示来源和采集时间。缺失配额保持未知；跨过重置时间的旧记录不会自动变成“满额”。从旧数据保留的附加项目会说明来源。
- **配额显示**：每个窗口和模型细分各占一行：名称、进度条、剩余百分比、行末重置倒计时（如 `6d 20h`、`2h 30m`，各卡片对齐成一列）；悬停显示具体重置时刻。颜色只看剩余量，与菜单栏一致。悬停服务名可看数据来源与采集时间，顶部显示最近更新时间。
- **时间游标**：菜单栏每根条上的细竖线，与条同向移动——显示剩余量时它是剩余时间（从右往左走），显示已用时是已过时间。填充越过游标表示配额比时间宽裕；游标不影响颜色。

私有用量接口、客户端字段与账号权益可能变化。没有返回的重置卡或适用范围不会凭空补造。

## 本地 statusLine 采集

只在设置里主动启用时安装，不在启动或后台刷新时修改 Claude Code 配置。

- 自有文件：配置目录中的 `tiny-usage-statusline.sh`、`tiny-usage.json`、`tiny-usage-statusline-backup.json`。
- 配置备份：`settings.json.tiny-usage-backup`。
- 保存完整原 `statusLine` 对象，保持原命令 stdin、stdout 和附加字段；采集器只落盘配额字段，不保存完整状态栏输入。
- 使用独立的 Foundation 小程序处理输入，不启动整个 GUI App。
- 关闭时只恢复属于本 App 的 statusLine 字段，保留安装后的其他设置。检测到外部修改则保留现场并提示，不覆盖整个配置文件。
- 已有 Mimir hook 时直接读取 `mimir-usage.json`，不再叠加包装。

应用状态存于 `~/Library/Application Support/Tiny Usage/`，凭证镜像使用独立的 `TinyUsage-claude-oauth` Keychain service。其他工具的 token 不刷新、不旋转、不写回；过期后由原客户端重新登录。

## 内存与后台工作

- 去掉上游的 Sentry、TelemetryDeck、Sparkle 依赖，以及 Widget（桌面小组件、App Group 共享快照）和 `mimir://` 深链路由。
- 不含 Antigravity：上游的 Antigravity 取数（本地 language server、Cockpit 凭据与缓存、`agy` CLI）、卡片分组及相关测试已全部移除，只保留 Claude 与 Codex。
- 面板关闭后释放 NSHostingView 和 TimelineView，并注销面板及事件监听。
- 一个 60 秒定时器负责重画菜单栏（倒计时、游标，只在内存中绘制），带 10 秒容差；睡眠时停止，唤醒后恢复。
- **刷新频率**可在设置中选择：自动（每分钟读本地，网络 2–30 分钟自适应，重置时刻补一次）、每 5 / 15 / 30 分钟（本地读取和网络请求都不快于该间隔，不在重置时刻额外请求）、仅手动（只在点「刷新用量」或「授权凭据」时读取）。
- 网络按账号自适应调度：数据变化时回到刷新频率的下限（自动为 120 秒），稳定时逐步退避，最长 1800 秒或所选间隔。补充接口也有独立的持久化冷却。
- HTTP 429 的 Retry-After 支持秒数和日期；手动刷新不会绕过冷却。
- Codex 历史目录索引缓存 5 分钟，只保留最近 8 个候选文件；每份文件最多读取末尾 1 MiB，不把整段会话存进 App 状态。
- 品牌图标在内存缓存；菜单栏直接绘制 NSImage，不反复生成临时图片。

实测条件、原始采样及限制见 [性能记录](docs/PERFORMANCE.md)。这些是短时测量，不代表长期稳定性保证。

## 构建和测试

需要 Xcode 工具链（本机验证 Swift 6.2.4）。在本目录执行：

```sh
bash scripts/test.sh
bash scripts/build-app.sh release
```

测试脚本设置独立的测试 HOME 和状态目录，不访问真实 Keychain 或 Desktop 登录。核心回归覆盖配额、真实窗口长度、重置卡、过期快照、请求冷却、状态栏恢复及有界日志读取。

为兼容继承的测试，内部模块名保留 `Mimir`；产品和 bundle 标识分别为 `TinyUsage`、`dev.tinyusage.macos`，与上游 App 分离。

本地包使用 ad-hoc 签名，也可通过 `SIGN_IDENTITY` 指定本机签名身份；当前没有商店发布、公证或自动更新流程。需要登录自启时，建议先将 App 放入 Applications，再从设置开启。

## 预览和复测

```sh
"dist/Tiny Usage.app/Contents/MacOS/TinyUsage" --render-preview "$PWD/docs/preview.png"
"dist/Tiny Usage.app/Contents/MacOS/TinyUsage" --smoke-test "$PWD/docs/runtime"
```

以上两种模式只使用明确标注的合成数据，不安装 hook、不查询账号。smoke-test 会驱动 AppKit 菜单栏按钮、点击设置、切换显示、关闭和重新打开，保存真实窗口截图及结果。退出该演示进程后重新打开 App，回到正常模式。

正常模式下关闭面板后，可用 PID 进行只读性能采样：

```sh
python3 -I scripts/profile.py <PID> docs/runtime/performance-idle.json
vmmap -summary <PID>
```

![Tiny Usage 演示预览](docs/preview-dark.png)

## 授权来源

Mimir 为 MIT，保留其版权及许可，见 [LICENSE](LICENSE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。ai-usage 仅作为显示交互参考，本项目未复制其绘图源码或素材。
