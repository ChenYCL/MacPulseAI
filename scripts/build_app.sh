#!/bin/bash
# 构建 MacPulse.app（release）并 ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MacPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacPulse "$APP/Contents/MacOS/MacPulse"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 五行原画：扁平拷进 Resources，NSImage(named:) 与 MythAsset 都能找到
if [ -d Sources/MacPulse/Resources ]; then
  cp -f Sources/MacPulse/Resources/* "$APP/Contents/Resources/" 2>/dev/null || true
fi
# SPM resource bundle（swift run / 测试路径）
if [ -d .build/release/MacPulse_MacPulse.bundle ]; then
  rm -rf "$APP/Contents/Resources/MacPulse_MacPulse.bundle"
  cp -R .build/release/MacPulse_MacPulse.bundle "$APP/Contents/Resources/"
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
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
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
echo "Built $(pwd)/$APP"
