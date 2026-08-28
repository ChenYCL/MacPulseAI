#!/bin/bash
# 逐页截图，用于 UI 自检 / README 配图。
# 每页各自冷启动一次（--pane 落到目标页），比点顶栏可复现。
#
# 两个坑：
#   1. 必须等上一个实例真的退出再起下一个。pkill 之后 sleep 一个固定秒数不够——
#      两个同尺寸窗口并存时 windowid.swift 会挑错，截出来的页和文件名对不上。
#   2. 清理/软件/分析页是进去才开始首扫，扫完要时间；等太短会拍到一张空表。
# 用法：scripts/sweep.sh <输出目录> [每页等待秒数]
set -euo pipefail
OUTDIR="${1:-/tmp/mpsweep}"
WAIT="${2:-22}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacPulse.app/Contents/MacOS/MacPulse"
mkdir -p "$OUTDIR"

kill_app() {
    pkill -f "MacPulse.app/Contents/MacOS/MacPulse" 2>/dev/null || true
    for _ in $(seq 1 40); do
        pgrep -f "MacPulse.app/Contents/MacOS/MacPulse" >/dev/null || return 0
        sleep 0.25
    done
    pkill -9 -f "MacPulse.app/Contents/MacOS/MacPulse" 2>/dev/null || true
    sleep 1
}

shoot() {   # shoot <名字> [--pane <raw>]
    local name="$1"; shift
    kill_app
    "$APP" "$@" >/dev/null 2>&1 &
    sleep "$WAIT"
    local n
    n=$(pgrep -f "MacPulse.app/Contents/MacOS/MacPulse" | wc -l | tr -d ' ')
    [ "$n" = "1" ] || { echo "跳过 $name：检测到 $n 个实例" >&2; return 1; }
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

kill_app
