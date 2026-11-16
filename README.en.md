<p align="center">
  <img src="Assets/AppIcon.svg" width="112" height="112" alt="">
</p>

<h1 align="center">Tiny Usage</h1>

<p align="center">
  See how much Claude, Codex, and OpenCode Go quota you have left and when it resets, right from your Mac menu bar.
</p>

<p align="center">
  <a href="https://tiny-usage.ayue.dev/en">Website</a>
  · <strong><a href="#install">Install</a></strong>
  · <a href="https://github.com/AhaYue/tiny-usage/issues">Feedback</a>
  · <a href="README.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/AhaYue/tiny-usage/releases/latest"><img src="https://img.shields.io/github/v/release/AhaYue/tiny-usage?style=flat&color=2563eb" alt="Latest release"></a>
  <a href="https://github.com/AhaYue/tiny-usage/actions/workflows/ci.yml?query=branch%3Amain+event%3Apush"><img src="https://img.shields.io/github/actions/workflow/status/AhaYue/tiny-usage/ci.yml?branch=main&amp;event=push&amp;label=BUILD" alt="Build status"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-30363d?style=flat&logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-30363d?style=flat" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-30363d?style=flat" alt="MIT License"></a>
</p>

<p align="center">
  <em>Some numbers are reassuring to have in the menu bar.</em><br>
  CPU 40%, RAM 76%, temperature 56 °C.<br>
  Hmm… and ...
</p>

<p align="center">
  <img src="docs/screenshot.png" width="460" alt="Tiny Usage menu bar and panel showing Claude and Codex quota bars, reset countdowns, and reset credits">
</p>

<p align="center"><strong>See what’s left at a glance, without a click.</strong></p>

## Install

Requires an Apple Silicon Mac running macOS 14 or later.

```sh
brew install --cask ahayue/tap/tiny-usage
```

Or [download the DMG](https://github.com/AhaYue/tiny-usage/releases/latest/download/TinyUsage.dmg) (about 1 MB), open it, and drag **Tiny Usage** to **Applications**.

### First launch

If macOS blocks the first launch, go to **System Settings → Privacy & Security → Open Anyway**.

Use your existing Claude Code and Codex logins. To connect OpenCode Go, open **Settings → OpenCode Go**.

## Features

- **Menu bar**: See your remaining quota and a marker for time until reset.
- **Details panel**: Click for exact percentages, reset countdowns, and available reset credits.
- **Service visibility**: Choose which services appear in the menu bar.
- **Colors**: Choose default, subtle, or custom colors.
- **Language**: Use English, Simplified Chinese, or your system language.
- **Updates**: Automatic checks, with a manual check in Settings.

## How Tiny Usage reads your quota

No sign-up required. Your Mac queries providers directly. Tiny Usage has no backend or telemetry.

<details>
<summary>Provider setup and authorization</summary>

- **Claude Code**: On first launch, Tiny Usage backs up your settings and connects to your existing `statusLine`. It keeps the original command running and saves only quota percentages and reset times. If data is stale, it can run `/usage` with your CLI login. Use **Settings → About → Claude status line → Disconnect** to restore the original status line and turn off automatic reconnection.
- **Claude details (optional)**: Authorize your Claude Code or Claude Desktop login from the Claude card to see model limits and reset credits. Tiny Usage requests Keychain access after you confirm and only reads the credentials.
- **Codex**: Uses your CLI login to query quota and reads session history from the same Codex directory, including a custom `CODEX_HOME`.
- **OpenCode Go**: Reuse the `opencode-go` API key or enter a personal key for the subscription’s workspace. Manually entered keys are stored in Keychain. See 5-hour, weekly, and monthly limits, or click **Open billing** for the workspace credit balance.

</details>

<details>
<summary>Performance</summary>

Closing the panel releases its view. The menu bar redraws once a minute and pauses during sleep. With the panel closed, a pre-Sparkle Apple Silicon build used 32.5 MiB of physical memory and averaged 0.17% of one CPU core over 30 seconds. See the [measurement notes](docs/PERFORMANCE.md).

</details>

<details>
<summary>Build from source</summary>

With Xcode and Swift 6, run `bash scripts/build-app.sh release` from the repository root to create `dist/Tiny Usage.app`.

</details>

[MIT License](LICENSE) · Based on [Mimir](https://github.com/erayendes/mimir) · Updates by [Sparkle](https://github.com/sparkle-project/Sparkle) · Menu bar design inspired by [ai-usage](https://github.com/wawaka/ai-usage)
