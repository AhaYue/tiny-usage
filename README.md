<h1 align="center">Tiny Usage</h1>

<p align="center">
  <strong>Quota at a glance</strong>
</p>

<p align="center">
  <strong><a href="https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg">Download for Mac</a></strong>
  · <a href="https://tiny-usage.ayue.dev/en">Website</a>
  · <a href="README.zh-CN.md">简体中文</a>
  <br>
  <sub>macOS 14+ · Apple Silicon · About 1 MB</sub>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="400" alt="Tiny Usage shows Claude and Codex in the macOS menu bar, with reset countdowns in the open panel">
</p>

<p align="center">
  <em>Some numbers are oddly reassuring in the menu bar.</em><br>
  CPU 40%, RAM 76%, temp 56 °C.<br>
  So… how much Claude and Codex quota is left? When does it reset?
</p>

## What you can see

- See **Claude, Codex, and OpenCode Go** side by side.
- The **time marker** shows how much of the window is left before reset.
- **Open the panel** to see your reset credits.

## Native and lightweight

Built with Swift, AppKit, and SwiftUI. No WebView, Electron, or Node.js. Closing the panel releases its view. The menu bar redraws once a minute and pauses during sleep.

| DMG | Memory¹ | CPU¹ | Libraries |
| :---: | :---: | :---: | :---: |
| **≈ 1 MB** | **32.5 MiB** | **0.17%** | **1** (Sparkle) |

<sub>¹ Physical memory and idle CPU were measured with the panel closed on an Apple Silicon build predating Sparkle. CPU is the 30-second average as a percentage of one core. <a href="docs/PERFORMANCE.md">Performance notes</a></sub>

## Download and install

### Homebrew

```sh
brew install --cask ahayue/tap/tiny-usage
```

### DMG

[Download the DMG](https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg) or download and open it with `curl`. Then drag **Tiny Usage** to **Applications**.

```sh
curl -fL -o TinyUsage.dmg \
  https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg \
  && open TinyUsage.dmg
```

### First launch

If macOS blocks the first launch, go to **System Settings → Privacy & Security → Open Anyway**.

If you’re signed in to Claude Code, Tiny Usage can query its quota on first launch. For Codex, it uses your existing CLI login and local session history. To add OpenCode Go, open **Settings → OpenCode Go**.

Tiny Usage checks for updates automatically. To check manually, open **Settings → Check for updates**.

Choose **Follow System**, **English**, or **简体中文** in **Settings → Language**. The change takes effect immediately.

## How Tiny Usage reads your quota

Tiny Usage uses your existing Claude and Codex setup, plus OpenCode Go if you connect it. It has no Tiny Usage account, backend, or telemetry. Provider queries go directly from your Mac.

On first launch, Tiny Usage connects to the Claude Code status line. You can disconnect it in Settings.

<details>
<summary>Provider setup, optional authorization, and data sources</summary>

- **Claude Code.** Tiny Usage wraps `statusLine` in `~/.claude/settings.json` and keeps your existing status line running. It backs up the file as `settings.json.tiny-usage-backup` and saves only quota percentages and reset times from the status line. When fresh data is missing, it can run Claude Code’s built-in `/usage` with your existing CLI login to read the 5-hour and weekly quotas. Use **Settings → About → Claude status line → Disconnect** to restore the original status line. Tiny Usage will only reconnect the status line if you ask it to.
- **More Claude details.** To get model limits and reset credits from Anthropic, authorize access from the Claude card using your existing Claude Code or Claude Desktop login. macOS asks for Keychain access only after you confirm. Tiny Usage reads these credentials without refreshing or writing them back.
- **Codex.** Tiny Usage can use the CLI’s existing login to query OpenAI. It reads local session files from the same Codex directory as the login, including when `CODEX_HOME` is set.
- **OpenCode Go.** In **Settings → OpenCode Go**, reuse the API key connected to the `opencode-go` provider or enter a personal key for the subscription’s workspace. Tiny Usage stores a manually entered key in the macOS Keychain and uses it to read the 5-hour, weekly, and monthly limits. **Open billing** opens the OpenCode Console for your workspace’s credit balance.

</details>

<details>
<summary>Build from source</summary>

With Xcode and Swift 6, run `bash scripts/build-app.sh release` from the repository root to create `dist/Tiny Usage.app`.

</details>

[MIT License](LICENSE) · Based on [Mimir](https://github.com/erayendes/mimir) · Updates by [Sparkle](https://github.com/sparkle-project/Sparkle) · Menu bar design inspired by [ai-usage](https://github.com/wawaka/ai-usage)
