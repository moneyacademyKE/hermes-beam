#!/bin/bash
set -e

# setup_launchd.sh
# Sets up the Hermes Telegram Gateway as a macOS LaunchAgent.
# It automatically restarts the process within seconds of failure (Self-Healing).

echo "══════════════════════════════════════════════════"
echo "  Hermes BEAM — launchd Service Installer"
echo "══════════════════════════════════════════════════"

# 1. OS Verification
OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
    echo "Error: This script is only supported on macOS (Darwin)."
    exit 1
fi

# 2. Path Resolutions
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
BEAM_DIR="$PROJECT_DIR/hermes_beam"

GLEAM_PATH=$(which gleam || true)
if [ -z "$GLEAM_PATH" ]; then
    # Try common Homebrew locations
    if [ -f "/opt/homebrew/bin/gleam" ]; then
        GLEAM_PATH="/opt/homebrew/bin/gleam"
    elif [ -f "/usr/local/bin/gleam" ]; then
        GLEAM_PATH="/usr/local/bin/gleam"
    else
        echo "Error: gleam binary not found in PATH or standard Homebrew directories."
        exit 1
    fi
fi

echo "Resolved gleam path:  $GLEAM_PATH"
echo "Resolved project dir: $PROJECT_DIR"
echo "Resolved hermes_beam: $BEAM_DIR"

# 3. Verify Env file and Token
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
ENV_FILE="$HERMES_HOME/.env"
LOG_DIR="$HERMES_HOME/logs"

mkdir -p "$LOG_DIR"

if [ -f "$ENV_FILE" ]; then
    echo "Found environment file at $ENV_FILE"
    if grep -q "HERMES_TELEGRAM_TOKEN" "$ENV_FILE"; then
        echo "Telegram token configuration found in $ENV_FILE"
    else
        echo "Warning: HERMES_TELEGRAM_TOKEN is not set in $ENV_FILE. Please add it for the gateway to poll successfully."
    fi
else
    echo "Warning: $ENV_FILE does not exist. Please configure your Hermes directory and environment before starting."
fi

# 4. Define PLIST details
PLIST_LABEL="co.hermes.gateway"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# 5. Unload existing service if loaded
if launchctl list | grep -q "$PLIST_LABEL"; then
    echo "Unloading existing launchd service: $PLIST_LABEL..."
    # Attempt modern bootout, fallback to legacy unload
    launchctl bootout "gui/$UID" "$PLIST_PATH" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
    sleep 1
fi

# 6. Generate PLIST file
echo "Generating plist file at $PLIST_PATH..."
cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$GLEAM_PATH</string>
        <string>run</string>
        <string>--</string>
        <string>--telegram</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$BEAM_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
        <key>ERL_COMPILER_OPTIONS</key>
        <string>nowarn_deprecated_catch</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/gateway_err.log</string>
</dict>
</plist>
EOF

# Set permissions
chmod 644 "$PLIST_PATH"

# 7. Load/Bootstrap Service
echo "Loading and starting launchd service..."
# Attempt modern bootstrap, fallback to legacy load
launchctl bootstrap "gui/$UID" "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH"

echo "══════════════════════════════════════════════════"
echo "  Hermes Telegram Gateway service setup completed!"
echo "  Label: $PLIST_LABEL"
echo "  Standard Output Log: $LOG_DIR/gateway.log"
echo "  Standard Error Log:  $LOG_DIR/gateway_err.log"
echo "══════════════════════════════════════════════════"
