#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"

# Rebuild first so a failed build does not interrupt the current app.
bash "$project/scripts/build-app.sh" release

session="$(mktemp -d "${TMPDIR:-/tmp}/tinyusage-new-user.XXXXXX")"
fresh_app="$session/Tiny Usage (New User).app"
session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
bundle_id="dev.tinyusage.newuser.$session_id"
mkdir -p "$session/state"

ditto "$project/dist/Tiny Usage.app" "$fresh_app"
plist="$fresh_app/Contents/Info.plist"
# A new bundle identity isolates Tiny Usage preferences without hiding CLI data.
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tiny Usage (New User)' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Tiny Usage (New User)' "$plist"
# The throwaway app must not take over the regular app's URL scheme.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$plist"

# Simulate installing Tiny Usage on the current machine, not a new macOS account.
# Keep the actual home and existing Claude/Codex configuration and session files.
# Only our own preferences, cached state, token mirrors, and grants start fresh.
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:TINY_USAGE_HOME string $session/state" "$plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:TINY_USAGE_NEW_USER_SESSION string $session_id" "$plist"
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CLAUDE_CONFIG_DIR string $CLAUDE_CONFIG_DIR" "$plist"
fi
if [[ -n "${CODEX_HOME:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CODEX_HOME string $CODEX_HOME" "$plist"
fi
codesign --force --sign - --identifier "$bundle_id" "$fresh_app"
codesign --verify --strict "$fresh_app"

pids="$(pgrep -x TinyUsage || true)"
if [[ -n "$pids" ]]; then
  while IFS= read -r app_pid; do
    kill -TERM "$app_pid" 2>/dev/null || true
  done <<< "$pids"
fi
for ((attempt = 0; attempt < 50; attempt++)); do
  if ! pgrep -x TinyUsage >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -x TinyUsage >/dev/null; then
  printf 'Some Tiny Usage instances have not exited; launch cancelled.\n' >&2
  exit 1
fi
printf 'All previous Tiny Usage instances have exited.\n'

printf '%s\n' "$bundle_id" > "$session/bundle-id.txt"
printf '%s\n' "$fresh_app" > "$session/app-path.txt"
open -n "$fresh_app" \
  --env "TINY_USAGE_HOME=$session/state" \
  --env "TINY_USAGE_NEW_USER_SESSION=$session_id" \
  --stdout "$session/app.log" --stderr "$session/app.log" \
  --args --show-panel
printf 'New-user session: %s\nApplication: %s\nState directory: %s\nBundle: %s\nCLI data: existing user directories preserved\n' \
  "$session" "$fresh_app" "$session/state" "$bundle_id"
