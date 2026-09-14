#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
APP_NAME="minimalWM"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "Building minimalWM..."
swift build -c release 2>&1

BINARY=".build/arm64-apple-macosx/release/minimalWM"

if [ ! -f "$BINARY" ]; then
    echo "Build failed."
    exit 1
fi

echo "Installing to $INSTALL_DIR..."
cp "$BINARY" "$INSTALL_DIR/$APP_NAME"
chmod +x "$INSTALL_DIR/$APP_NAME"

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
        <string>$INSTALL_DIR/$APP_NAME</string>
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
echo "Installed: $INSTALL_DIR/$APP_NAME"
echo "Launch Agent: $LAUNCH_AGENTS/com.minimalWM.plist"
echo ""
echo "To start now:   launchctl load $LAUNCH_AGENTS/com.minimalWM.plist"
echo "To stop:        launchctl unload $LAUNCH_AGENTS/com.minimalWM.plist"
echo "To uninstall:   rm $INSTALL_DIR/$APP_NAME && rm $LAUNCH_AGENTS/com.minimalWM.plist"
echo ""
echo "Grant Accessibility permission when prompted."
