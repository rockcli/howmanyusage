#!/bin/bash
# Install to /Applications, register LaunchAgent autostart, then launch
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

echo "==> Installing to /Applications"
rm -rf /Applications/HowManyUsage.app
cp -R build/HowManyUsage.app /Applications/

echo "==> Registering LaunchAgent autostart"
PLIST="$HOME/Library/LaunchAgents/com.local.howmanyusage.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.howmanyusage</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/HowManyUsage.app/Contents/MacOS/HowManyUsage</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed. The three-bar menu bar icon should appear (click to view usage, auto-refresh every 10 min)."
echo "To uninstall: launchctl unload $PLIST && rm $PLIST && rm -rf /Applications/HowManyUsage.app"
