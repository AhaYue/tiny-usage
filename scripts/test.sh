#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tiny-usage-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/state"
TINY_USAGE_TEST_HOME="$fixture/home" TINY_USAGE_HOME="$fixture/state" \
  swift test --package-path "$project" "$@"
