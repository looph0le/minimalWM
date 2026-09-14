#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
APP_INSTALL_DIR="/Applications"
APP_NAME="minimalWM"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "Building universal minimalWM.app..."
"$(dirname "$0")/Packaging/package-app.sh"

APP="$(pwd)/dist/minimalWM.app"

if [ ! -x "$APP/Contents/MacOS/minimalWM" ]; then
    echo "Build failed."
    exit 1
fi

echo "Installing to $APP_INSTALL_DIR..."
launchctl unload "$LAUNCH_AGENTS/com.minimalWM.plist" 2>/dev/null || true
for pid in $(pgrep -x minimalWM 2>/dev/null || true); do
    kill "$pid" 2>/dev/null || true
done
ditto "$APP" "$APP_INSTALL_DIR/minimalWM.app"

mkdir -p "$LAUNCH_AGENTS"
cat > "$LAUNCH_AGENTS/com.minimalWM.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.minimalWM</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP_INSTALL_DIR/minimalWM.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/minimalWM.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/minimalWM.log</string>
</dict>
</plist>
EOF

echo ""
echo "Installed: $APP_INSTALL_DIR/minimalWM.app"
echo "Launch Agent: $LAUNCH_AGENTS/com.minimalWM.plist"
echo ""
echo "To start now:   launchctl load $LAUNCH_AGENTS/com.minimalWM.plist"
echo "To stop:        launchctl unload $LAUNCH_AGENTS/com.minimalWM.plist"
echo "To uninstall:   rm -rf $APP_INSTALL_DIR/minimalWM.app && rm $LAUNCH_AGENTS/com.minimalWM.plist"
echo ""
echo "Grant Accessibility permission when prompted."
