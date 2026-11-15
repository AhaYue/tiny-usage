<h1 align="center">Tiny Usage</h1>

<p align="center">
  <strong>额度抬眼即知</strong>
</p>

<p align="center">
  <strong><a href="https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg">下载 Mac 版</a></strong>
  · <a href="https://tiny-usage.ayue.dev">官网</a>
  · <a href="README.md">English</a>
  <br>
  <sub>macOS 14+ · Apple Silicon · 下载约 1 MB</sub>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="400" alt="Tiny Usage 在 macOS 菜单栏显示 Claude 和 Codex 的配额，展开的面板显示重置倒计时">
</p>

<p align="center">
  <em>有些数字，挂在菜单栏才安心。</em><br>
  CPU 40%、RAM 76%、温度 56 °C。<br>
  嗯……Claude 和 Codex 的额度还剩多少？何时reset？
</p>

## 一眼看清

- **Claude、Codex 和 OpenCode Go** 并排看。
- **看竖线**，了解重置剩余时间。
- **点开面板**，查看重置卡。

## 原生，够轻

用 Swift、AppKit 和 SwiftUI 写的原生 Mac 应用，无 WebView、Electron 或 Node.js。关掉面板就释放视图，菜单栏每分钟重绘一次，Mac 睡眠时暂停。

| DMG | 内存¹ | 空闲 CPU¹ | 第三方依赖 |
| :---: | :---: | :---: | :---: |
| **约 1 MB** | **32.5 MiB** | **0.17%** | **1 个**（Sparkle） |

<sub>¹ 物理内存和空闲 CPU 来自集成 Sparkle 前的 Apple Silicon 构建，采样时面板关闭。CPU 为 30 秒平均值，按单核计算。<a href="docs/PERFORMANCE.md">性能实测</a></sub>

## 下载和安装

### Homebrew

```sh
brew install --cask ahayue/tap/tiny-usage
```

### DMG

直接[下载 DMG](https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg)，或用下方的 `curl` 命令下载并打开。然后把 **Tiny Usage** 拖进 **应用程序**。

```sh
curl -fL -o TinyUsage.dmg \
  https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg \
  && open TinyUsage.dmg
```

### 首次启动

如果 macOS 拦截首次启动，前往 **系统设置 → 隐私与安全性 → 仍要打开**。

如果你已登录 Claude Code，Tiny Usage 首次打开就可以查询配额。它也可以读取 Codex 已有的 CLI 登录和本地会话记录。要添加 OpenCode Go，打开 **设置 → OpenCode Go**。

应用支持自动检查更新，也可以在 **设置 → 检查更新**中手动检查。

在 **设置 → 语言**中可选择「跟随系统」「English」或「简体中文」，切换即时生效。

## 用量从哪里来

Tiny Usage 使用你已有的 Claude 和 Codex 环境，也可选接入 OpenCode Go。无需注册，无自建服务器，也不收集遥测数据。配额查询由你的 Mac 直接连接服务商。

首次启动会自动接入 Claude Code 的状态栏，可在设置里移除。

<details>
<summary>服务接入、可选授权与数据来源</summary>

- **Claude Code。** Tiny Usage 会接入 `~/.claude/settings.json` 里的 `statusLine`，让原有状态栏照常运行，并备份配置文件为 `settings.json.tiny-usage-backup`。状态栏采集只保存配额百分比和重置时间。缺少新数据时，Tiny Usage 可让已登录的 Claude Code 执行内置 `/usage`，查询 5 小时和每周配额。在 **设置 → 关于 → Claude 状态栏 → 移除接入**可以恢复原有状态栏，之后由你决定是否重新接入。
- **更多 Claude 明细。** 要从 Anthropic 获取模型配额和重置卡，可以在 Claude 卡片上授权使用已有的 Claude Code 或 Claude 桌面应用登录。你确认后，macOS 才会请求钥匙串权限。Tiny Usage 只读取凭据，不刷新或写回。
- **Codex。** Tiny Usage 可以使用已有的 CLI 登录向 OpenAI 查询配额。本地会话文件和登录来自同一个 Codex 目录，自定义 `CODEX_HOME` 时也一样。
- **OpenCode Go。** 在 **设置 → OpenCode Go** 复用 `opencode-go` 已连接的 API key，或填写套餐所在工作区的个人 key。手动填写的 key 存在 macOS 钥匙串，用来查询 5 小时、每周和月度额度。点 **打开账单** 可前往 OpenCode Console 查看工作区充值余额。

</details>

<details>
<summary>从源码构建</summary>

使用带 Swift 6 的 Xcode 工具链，在仓库根目录运行 `bash scripts/build-app.sh release`，生成 `dist/Tiny Usage.app`。

</details>

[MIT 许可](LICENSE) · 源自 [Mimir](https://github.com/erayendes/mimir) · [Sparkle](https://github.com/sparkle-project/Sparkle) 提供应用内更新 · 菜单栏设计参考 [ai-usage](https://github.com/wawaka/ai-usage)
