#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/ay-usage-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/state"
AY_USAGE_TEST_HOME="$fixture/home" AY_USAGE_HOME="$fixture/state" \
  swift test --package-path "$project" "$@"
