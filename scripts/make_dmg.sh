#!/bin/bash
# 打 DMG。先跑 build_app.sh（universal + ad-hoc 签名），再把 .app 和
# Applications 快捷方式塞进一个压缩过的只读镜像。
# 用法：MARKETING_VERSION=2.4.0 scripts/make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${MARKETING_VERSION:-2.4.0}"
APP="build/MacPulse.app"
STAGING="dist/dmg-staging"
OUT="dist/MacPulseAI-${VERSION}.dmg"

[ -d "$APP" ] || { echo "先跑 scripts/build_app.sh" >&2; exit 1; }

# 发布包必须是双架构：只有 x86_64 的话，Apple Silicon 用户全程跑在 Rosetta 里。
ARCHS=$(lipo -archs "$APP/Contents/MacOS/MacPulse")
case "$ARCHS" in
  *arm64*) : ;;
  *) echo "拒绝打包：产物缺 arm64（当前 $ARCHS）。用 scripts/build_app.sh 重建。" >&2; exit 1 ;;
esac

rm -rf "$STAGING" "$OUT"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "MacPulse AI ${VERSION}" \
    -srcfolder "$STAGING" -ov -format UDZO "$OUT" >/dev/null

rm -rf "$STAGING"
echo "$OUT  ($(du -h "$OUT" | cut -f1), $ARCHS)"
