#!/bin/bash
# 构建 MacPulse.app（release）并 ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")/.."

# 显式双架构：在 Apple Silicon 上 `swift build -c release` 实测只产出 x86_64，
# 装到 M 系机器上会整个跑在 Rosetta 里。发布包必须是 universal。
# 传 UNIVERSAL=0 可以跳过（本地迭代时快一半）。
if [ "${UNIVERSAL:-1}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/MacPulse"
  RES_DIR=".build/apple/Products/Release"
else
  swift build -c release
  BIN=".build/release/MacPulse"
  RES_DIR=".build/release"
fi
[ -f "$BIN" ] || { echo "找不到产物 $BIN" >&2; exit 1; }

# 版本号从标签推导，CI 和本地都不用再传。
# 之前这里硬编码 1.0.0，所有历史发布的 Info.plist 都写着 1.0.0；
# 换成默认值同样是把问题从一个数字挪到另一个数字——下次发版照样是错的。
if [ -z "${MARKETING_VERSION:-}" ]; then
  MARKETING_VERSION="${GITHUB_REF_NAME:-$(git describe --tags --abbrev=0 2>/dev/null || echo)}"
  MARKETING_VERSION="${MARKETING_VERSION#v}"
  # 不在标签上（本地迭代）就标成 0.0.0-dev，别谎报成某个正式版本
  case "$MARKETING_VERSION" in
    ''|*[!0-9.]*) MARKETING_VERSION="0.0.0" ;;
  esac
fi
BUILD_VERSION="${BUILD_VERSION:-$(printf '%s' "$MARKETING_VERSION" | tr -d '.')}"
export MARKETING_VERSION BUILD_VERSION

APP="build/MacPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPulse"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 五行原画：扁平拷进 Resources，NSImage(named:) 与 MythAsset 都能找到
if [ -d Sources/MacPulse/Resources ]; then
  cp -f Sources/MacPulse/Resources/* "$APP/Contents/Resources/" 2>/dev/null || true
fi
# SPM resource bundle（swift run / 测试路径）
if [ -d "$RES_DIR/MacPulse_MacPulse.bundle" ]; then
  rm -rf "$APP/Contents/Resources/MacPulse_MacPulse.bundle"
  cp -R "$RES_DIR/MacPulse_MacPulse.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacPulse AI</string>
    <key>CFBundleDisplayName</key><string>MacPulse AI</string>
    <key>CFBundleIdentifier</key><string>com.chenycl.macpulseai</string>
    <key>CFBundleExecutable</key><string>MacPulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 ChenYCL — MIT License</string>
    <key>NSAppTransportSecurity</key>
    <dict/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP  v$MARKETING_VERSION ($(lipo -archs "$APP/Contents/MacOS/MacPulse" 2>/dev/null || echo unknown))"
