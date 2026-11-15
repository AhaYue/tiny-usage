# Changelog · 更新日志

To release: add a `## [x.y.z]` section at the top with a `### English` and a `### 中文` list, then push the `vx.y.z` tag. The section becomes the GitHub Release notes; the in-app update window shows the list in the user's language.

发布新版本时，在最上面加一节 `## [x.y.z]`，分别写 `### English` 和 `### 中文` 两个列表，再推送 `vx.y.z` 标签。这一节会成为 GitHub Release 说明，应用内更新窗口按用户语言显示对应列表。

## [1.1.0]

### English

- Connect OpenCode Go from Settings to see your 5-hour, weekly, and monthly quotas and reset times.
- See Claude Code quotas on first launch with your existing CLI login when fresh status-line data is unavailable.
- Keep Codex quota readings and session history tied to the same login directory, including custom `CODEX_HOME` folders.
- Switch between English, Simplified Chinese, and the system language in Settings.

### 中文

- 可在设置中接入 OpenCode Go，查看 5 小时、每周、月度配额及重置时间。
- 状态栏没有新数据时，可用已有的 Claude Code 登录查询配额，首次打开即可显示。
- Codex 配额与本地会话统一使用同一登录目录，支持自定义 `CODEX_HOME`。
- 可在设置中选择英文、简体中文或跟随系统。

## [1.0.0]

### English

- First public release: Claude and Codex quotas in the menu bar, with reset times and reset credits.
- Claude usage is read locally through Claude Code's status line; any status line you already have keeps working.
- In-app updates. The DMG is about 1 MB.
- English and Simplified Chinese.

### 中文

- 首个公开版本：在菜单栏显示 Claude 和 Codex 配额、重置时间与重置卡。
- 通过 Claude Code 状态栏在本地读取 Claude 用量，原有状态栏照常工作。
- 支持应用内自动更新，DMG 约 1 MB。
- 支持英文和简体中文。
