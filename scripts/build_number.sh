#!/bin/bash
# Monotonic CFBundleVersion from a "major.minor[.patch]" version: Sparkle compares this number,
# so every release must produce a larger one. 0.2.0 → 2000, 1.4.3 → 1004003.
set -euo pipefail
IFS=. read -r maj min pat <<< "${1%%-*}"
for n in "${maj:-0}" "${min:-0}" "${pat:-0}"; do
  [[ "$n" =~ ^[0-9]+$ ]] && (( n < 1000 )) || { echo "bad version: $1" >&2; exit 1; }
done
echo $(( ${maj:-0} * 1000000 + ${min:-0} * 1000 + ${pat:-0} ))
