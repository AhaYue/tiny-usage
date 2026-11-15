<h1 align="center">Tiny Usage</h1>

<p align="center">
  在 macOS 菜单栏查看 Claude 和 Codex 配额。<br>
  原生应用，下载约 1 MB，无需注册账号。
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="431" alt="菜单栏中的 Tiny Usage 及展开的面板">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/panel-zh-dark.png">
    <img src="docs/panel-zh-light.png" width="288" alt="Tiny Usage 面板，显示 Claude 和 Codex 配额">
  </picture>
</p>

## 显示什么

- **两个窗口一眼看完。** 每个服务在菜单栏占两根条：上面是 5 小时窗口，下面是周窗口。
- **颜色只看剩余量。** 剩余 50% 及以上为绿色，20%–49% 为橙色，低于 20% 为红色。同一个数字永远是同一种颜色。
- **每根条上有时间游标。** 细竖线表示这个窗口还剩多少时间。条超过竖线，说明配额比时间宽裕。
- **模型细分和重置卡。** 面板列出各模型的周配额、每个窗口的重置时间，以及重置卡的数量和到期时间。
- **旧数据如实标注。** 没能刷新的读数会标明是旧数据；缺失的配额保持未知，不会显示成满额。

菜单栏可以显示双条、百分比或两者，数值可选剩余量或已用量。

## 安装

需要 macOS 14 或更高版本，Apple Silicon。

1. 从[最新发布](https://github.com/AhaYue/tiny-usage/releases/latest)下载 `TinyUsage-x.y.z.dmg`。
2. 把 **Tiny Usage** 拖进 **应用程序** 并打开。
3. 应用没有经过 Apple 公证，首次打开会被 macOS 拦下。打开 **系统设置 → 隐私与安全性**，滚动到底部点击 **仍要打开**。

也可以在终端执行下面的命令，效果与第 3 步相同：

```sh
xattr -dr com.apple.quarantine "/Applications/Tiny Usage.app"
```

之后的更新在应用内完成：每天自动检查一次，也可以在 **设置 → 检查更新** 里手动检查。

## 数据从哪来

所有读取都在本机完成。Tiny Usage 没有服务器，也不上报任何数据。

| 服务 | 来源 | 需要 |
| --- | --- | --- |
| Claude | Claude Code 状态栏，本地采集 | 正在使用 Claude Code |
| Claude（重置卡、完整配额） | Anthropic 用量接口，使用已有的 Claude Code 或 Claude 桌面应用登录 | 一次授权 |
| Codex | Codex CLI 的登录和本地会话文件 | `codex login` |

### 会改动你电脑上的什么

首次启动时，Tiny Usage 会自动接入 Claude Code 的状态栏，这样不需要任何凭据就能读到配额：

- 把 `~/.claude/settings.json` 里的 `statusLine` 指向一个小脚本。你原有的状态栏照常运行，显示内容不变。
- 在同一目录保留原文件的备份 `settings.json.tiny-usage-backup`。
- 脚本只保存配额百分比和重置时间，状态栏输入的其余内容不会写入磁盘。

想撤销时，打开 **设置 → 关于 → Claude 状态栏 → 移除接入**。原来的状态栏会恢复，之后 Tiny Usage 也不会自行重新接入。

下次使用 Claude Code 后就会出现用量。

### 授权是可选的

重置卡和模型细分不在状态栏数据里。想看这些，点击 Claude 卡片上的授权按钮并确认，这时 macOS 才会询问是否允许读取钥匙串中的 Claude 登录凭据；如果装有 Claude 桌面应用，也会询问其会话凭据。Tiny Usage 只读取这些凭据，不刷新、不轮换、不写回。打开面板和普通刷新不会弹出钥匙串授权框。

### 局限

这些配额接口是未公开的私有接口，Anthropic 和 OpenAI 随时可能调整，届时对应卡片可能暂停更新，直到 Tiny Usage 跟进。Tiny Usage 与这两家公司没有关联，也未获其认可。

## 设置

| 设置 | 选项 |
| --- | --- |
| 显示数值 | 剩余量、已用量 |
| 菜单栏样式 | 双条、百分比、双条＋百分比 |
| 刷新频率 | 自动（2–30 分钟自适应）、每 5 / 15 / 30 分钟、仅手动 |
| 登录时启动 | 开、关 |

应用状态保存在 `~/Library/Application Support/Tiny Usage/`，可从 **设置 → 打开数据文件夹** 进入。

## 从源码构建

需要带 Swift 6 的 Xcode 工具链。

```sh
bash scripts/test.sh               # 测试，与真实登录和钥匙串隔离
bash scripts/build-app.sh release  # → dist/Tiny Usage.app
open "dist/Tiny Usage.app"
```

其他常用脚本：

| 脚本 | 作用 |
| --- | --- |
| `scripts/preview.sh` | 用演示数据把面板及各状态渲染成 PNG |
| `scripts/package.sh` | 把构建好的应用打成发布用的 zip 和 DMG |
| `scripts/restart-as-new-user.sh` | 重新构建并以首次使用的身份启动，保留已有登录 |

代码结构和约定见 [AGENTS.md](AGENTS.md)，性能实测见 [docs/PERFORMANCE.md](docs/PERFORMANCE.md)。

## 发布

1. 在 [CHANGELOG.md](CHANGELOG.md) 顶部加一节 `## [x.y.z]`，分别写英文和中文列表。
2. 推送标签：`git tag vx.y.z && git push origin vx.y.z`。
3. GitHub Actions 会依次测试、构建、给更新包签名、创建 Release，并写入 `appcast.xml`。

想先演练而不发布，可在 Actions 页手动运行 **Release** 工作流。

更新包用 EdDSA 密钥签名，私钥保存在仓库 Secret `SPARKLE_PRIVATE_KEY` 中。私钥丢失后，已安装的版本将无法再收到更新。

## 致谢

- [Mimir](https://github.com/erayendes/mimir)，作者 Eray Endes（MIT）。Tiny Usage 派生自它，数据解析、配额卡片和重置卡处理都源于此。
- [Sparkle](https://github.com/sparkle-project/Sparkle)（MIT），提供应用内更新。
- [ai-usage](https://github.com/wawaka/ai-usage)，菜单栏的视觉参考，未使用其代码或素材。

Claude 和 Codex 是各自所有者的商标。

## 许可

[MIT](LICENSE)
