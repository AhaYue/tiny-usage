<h1 align="center">Tiny Usage</h1>

<p align="center">
  Claude and Codex quotas in your macOS menu bar.<br>
  Native, about 1 MB to download, no account to create.
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="431" alt="Tiny Usage in the menu bar with its panel open">
</p>

## What it shows

- **Both windows at a glance.** Each service gets two bars in the menu bar: the 5-hour window on top, the weekly one below.
- **Colour by what's left.** Green at 50% or more, orange from 20% to 49%, red below 20%. The same number is always the same colour.
- **A time marker on each bar.** The thin line shows how much of the window's time is left. A bar that reaches past the line means quota is lasting longer than the clock.
- **Per-model limits and reset credits.** The panel lists each model's weekly limit, when every window resets, and any reset credits with their expiry.
- **Honest about stale data.** A reading that couldn't be refreshed is labelled as such. Missing quota stays unknown instead of being shown as full.

The menu bar can show bars, percentages or both, and either the remaining or the used amount.

## Install

Requires macOS 14 or later on Apple Silicon.

1. Download `TinyUsage-x.y.z.dmg` from the [latest release](https://github.com/AhaYue/tiny-usage/releases/latest).
2. Drag **Tiny Usage** into **Applications** and open it.
3. macOS will block the first launch, because the app isn't notarized by Apple. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

If you prefer the terminal, this does the same as step 3:

```sh
xattr -dr com.apple.quarantine "/Applications/Tiny Usage.app"
```

After that, updates install from inside the app. It checks once a day, and **Settings → Check for updates** checks on demand.

## Where the numbers come from

Everything is read on your Mac. Tiny Usage has no server and sends no telemetry.

| Service | Source | Needs |
| --- | --- | --- |
| Claude | Claude Code's status line, captured locally | Claude Code in use |
| Claude (reset credits, full quota) | Anthropic's usage API, with your existing Claude Code or Claude desktop login | One-time authorization |
| Codex | The Codex CLI's login and local session files | `codex login` |

### What changes on your Mac

On first launch, Tiny Usage connects itself to Claude Code's status line so it can read your quota without asking for any credential:

- It sets `statusLine` in `~/.claude/settings.json` to a small script. A status line you already have keeps running and showing exactly as before.
- It keeps a backup of the original file as `settings.json.tiny-usage-backup`, next to it.
- The script saves only the quota percentages and reset times. The rest of the status-line input is never written to disk.

To undo it, open **Settings → About → Claude status line → Disconnect**. Your original status line is restored, and Tiny Usage doesn't reconnect on its own afterwards.

Usage appears after you next use Claude Code.

### Authorization is optional

Reset credits and per-model limits aren't in the status line. To see them, use the authorize button on the Claude card and confirm. Only then does macOS ask for keychain access to your Claude login, and to the Claude desktop app's session if that app is installed. Tiny Usage reads those credentials, and never refreshes, rotates or writes them back. Opening the panel or a normal refresh never triggers a keychain prompt.

### Limits

These quota endpoints are private and undocumented. Anthropic or OpenAI can change them at any time, and a card may stop updating until Tiny Usage catches up. Tiny Usage is not affiliated with or endorsed by either company.

## Settings

| Setting | Options |
| --- | --- |
| Display | Remaining or used |
| Menu bar | Bars, percent, or both |
| Refresh rate | Auto (adaptive, 2–30 min), every 5 / 15 / 30 min, or manual only |
| Launch at login | On or off |

App state lives in `~/Library/Application Support/Tiny Usage/`. **Settings → Open data folder** takes you there.

## Build from source

You need the Xcode toolchain with Swift 6.

```sh
bash scripts/test.sh               # tests, isolated from your real logins and keychain
bash scripts/build-app.sh release  # → dist/Tiny Usage.app
open "dist/Tiny Usage.app"
```

Other useful scripts:

| Script | What it does |
| --- | --- |
| `scripts/preview.sh` | Renders the panel and its states to PNGs with demo data |
| `scripts/package.sh` | Makes the release zip and DMG from the built app |
| `scripts/restart-as-new-user.sh` | Rebuilds and launches as a first-time user, keeping your logins |

Project layout and conventions are in [AGENTS.md](AGENTS.md); measurements are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Releasing

1. Add a `## [x.y.z]` section to the top of [CHANGELOG.md](CHANGELOG.md), with an English and a Chinese list.
2. Push the tag: `git tag vx.y.z && git push origin vx.y.z`.
3. GitHub Actions tests, builds, signs the update, creates the release and adds it to `appcast.xml`.

To rehearse without publishing, run the **Release** workflow by hand from the Actions tab.

Updates are signed with an EdDSA key held in the `SPARKLE_PRIVATE_KEY` repository secret. If that key is lost, installed copies can no longer be updated.

## Credits

- [Mimir](https://github.com/erayendes/mimir) by Eray Endes (MIT). Tiny Usage is derived from it: the provider parsers, quota cards and reset-credit handling started there.
- [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT) for in-app updates.
- [ai-usage](https://github.com/wawaka/ai-usage) as a visual reference for the menu bar. None of its code or assets are used.

Claude and Codex are trademarks of their respective owners.

## License

[MIT](LICENSE)
