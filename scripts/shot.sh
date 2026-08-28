#!/bin/bash
# 截当前 MacPulse 主窗口，用于 UI 自检 / README 配图。
# 用法：scripts/shot.sh out.png
#
# 只按窗口 ID 截图，不 activate、不 open —— 那些操作会把窗口推到前台并可能
# 触发默认按钮，截出来的就不是「应用自己的样子」了。
set -euo pipefail
OUT="${1:-/tmp/macpulse-shot.png}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WID=$(swift "$ROOT/scripts/windowid.swift" 2>/dev/null || true)
if [ -z "${WID:-}" ]; then
    echo "MacPulse 窗口未找到（先 open build/MacPulse.app）" >&2
    exit 1
fi
screencapture -x -o -l "$WID" "$OUT"
echo "$OUT (window $WID)"
