#!/bin/bash
# 逐页截图，用于 UI 自检 / README 配图。
# 每页各自冷启动一次（--pane 落到目标页），比点顶栏可复现。
# 用法：scripts/sweep.sh <输出目录>
set -euo pipefail
OUTDIR="${1:-/tmp/mpsweep}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacPulse.app/Contents/MacOS/MacPulse"
mkdir -p "$OUTDIR"

shoot() {   # shoot <名字> [--pane <raw>]
    local name="$1"; shift
    pkill -f "MacPulse.app/Contents/MacOS/MacPulse" 2>/dev/null || true
    sleep 1.5
    "$APP" "$@" >/dev/null 2>&1 &
    sleep 7
    local wid
    wid=$(swift "$ROOT/scripts/windowid.swift")
    screencapture -x -o -l "$wid" "$OUTDIR/$name.png"
    sips -Z 1400 "$OUTDIR/$name.png" --out "$OUTDIR/$name.jpg" >/dev/null 2>&1
    echo "$name"
}

shoot roster
for p in status clean software optimize analyze security; do
    shoot "$p" --pane "$p"
done

pkill -f "MacPulse.app/Contents/MacOS/MacPulse" 2>/dev/null || true
