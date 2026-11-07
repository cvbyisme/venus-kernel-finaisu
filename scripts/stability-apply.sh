#!/usr/bin/env bash
# Apply scripts/stability-patches/*.patch onto the kernel tree (idempotent).
set -euo pipefail
KDIR="${1:-$PWD/kernel}"
PD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stability-patches"
[ -d "$PD" ] || { echo "[stability] no patch dir"; exit 0; }
shopt -s nullglob
n=0
for p in "$PD"/*.patch; do
  name=$(basename "$p")
  if git -C "$KDIR" apply --reverse --check "$p" >/dev/null 2>&1; then
    echo "[stability] already applied: $name"
  elif git -C "$KDIR" apply --check "$p" >/dev/null 2>&1; then
    git -C "$KDIR" apply "$p"
    echo "[stability] applied: $name"
    n=$((n+1))
  else
    echo "::error::[stability] cannot apply $name"
    git -C "$KDIR" apply --check -v "$p" || true
    exit 1
  fi
done
echo "[stability] done, $n applied"
