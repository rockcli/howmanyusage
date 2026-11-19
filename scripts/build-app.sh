#!/bin/bash
# Build the menu bar app: swift release build + .app bundling
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/HowManyUsage.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Fallback for a broken CommandLineTools (mixed 16.2/16.4 install: SwiftPM manifests
# fail to link, and the 6.0.3 compiler rejects the 15.5 SDK). Compiles directly with
# swiftc against the matching MacOSX15.2.sdk, using a VFS overlay to mask the
# duplicate SwiftBridging modulemap (16.4's bridging.modulemap over 16.2's
# module.modulemap) and a private clang module cache. Drop the fallback once the
# CLT is reinstalled and `swift build` works again.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk"
EMPTY="build/empty.modulemap"
OVERLAY="build/mask-bridging.yaml"
MCACHE="build/modules-cache"
touch "$EMPTY"
cat > "$OVERLAY" <<EOF
{
  "version": 0,
  "roots": [
    { "name": "/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap",
      "type": "file",
      "external-contents": "$(pwd)/$EMPTY" }
  ]
}
EOF

echo "==> swift build (release)"
if swift build -c release --package-path app; then
  cp app/.build/release/HowManyUsage "$APP/Contents/MacOS/"
else
  echo "==> swift build failed (broken CLT) — building with swiftc against $SDK"
  swiftc -O -sdk "$SDK" -vfsoverlay "$(pwd)/$OVERLAY" -Xcc "-fmodules-cache-path=$(pwd)/$MCACHE" \
    -o "$APP/Contents/MacOS/HowManyUsage" app/Sources/HowManyUsage/*.swift
fi

echo "==> Generating icon"
if swift scripts/make-icon.swift >/dev/null 2>&1 && [ -f build/HowManyUsage.icns ]; then
  cp build/HowManyUsage.icns "$APP/Contents/Resources/"
elif swift -sdk "$SDK" -vfsoverlay "$(pwd)/$OVERLAY" -Xcc "-fmodules-cache-path=$(pwd)/$MCACHE" scripts/make-icon.swift >/dev/null 2>&1 && [ -f build/HowManyUsage.icns ]; then
  cp build/HowManyUsage.icns "$APP/Contents/Resources/"
else
  echo "    (skipped: icon generation failed; app still works)"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>HowManyUsage</string>
  <key>CFBundleIdentifier</key><string>com.local.howmanyusage</string>
  <key>CFBundleName</key><string>howmanyusage</string>
  <key>CFBundleDisplayName</key><string>howmanyusage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>HowManyUsage</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>howmanyusage</string>
</dict>
</plist>
EOF

echo "==> ad-hoc signing"
codesign --force --sign - "$APP"

echo "Built: $APP"
