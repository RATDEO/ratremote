#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Foundation Models and modern SwiftUI macros require a full Xcode toolchain.
# An explicit DEVELOPER_DIR takes precedence over installed Xcode versions.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  fi
fi

swift build -c release

APP="$ROOT/build/RatRemote.app"
BIN="$ROOT/.build/release/RatRemote"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RatRemote"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>RatRemote</string>
  <key>CFBundleIdentifier</key>
  <string>org.ratremote.app</string>
  <key>CFBundleName</key>
   <string>RatRemote</string>
   <key>CFBundleIconFile</key>
   <string>AppIcon</string>
   <key>CFBundlePackageType</key>
  <string>APPL</string>
 <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>GCSupportsControllerUserInteraction</key>
  <true/>
  <key>GCSupportsMultipleMicroGamepads</key>
  <true/>
  <key>GCSupportedGameControllers</key>
  <array>
    <dict>
      <key>ProfileName</key>
      <string>MicroGamepad</string>
    </dict>
    <dict>
      <key>ProfileName</key>
      <string>DirectionalGamepad</string>
    </dict>
    <dict>
      <key>ProfileName</key>
      <string>ExtendedGamepad</string>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>RatRemote records your selected microphone for Apple on-device dictation and remote command workflows.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>RatRemote uses Apple on-device speech recognition for dictation and command text.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>RatRemote can run user-approved AppleScript actions returned by your inference server.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>RatRemote connects to your local inference and computer-use servers on your LAN.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSScreenCaptureUsageDescription</key>
  <string>RatRemote captures the screen so your vision model can locate requested interface targets.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>RatRemote uses Bluetooth to connect directly to the Siri Remote touchpad for pointer control.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>RatRemote needs Input Monitoring permission to receive Siri Remote touchpad input from macOS.</string>
  </dict>
</plist>
PLIST

ENTITLEMENTS="$ROOT/build/RatRemote.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${RATREMOTE_CODESIGN_IDENTITY:--}"

if [[ -f "$ROOT/AppIcon.icns" ]]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# A release build can provide RAT_LLAMA_SERVER=/path/to/llama-server. For local
# builds, reuse a Homebrew/PATH installation when present. The copied helper is
# signed as nested code by the final --deep codesign invocation.
LLAMA_SERVER_SOURCE="${RAT_LLAMA_SERVER:-}"
if [[ -z "$LLAMA_SERVER_SOURCE" ]] && command -v llama-server >/dev/null 2>&1; then
  LLAMA_SERVER_SOURCE="$(command -v llama-server)"
fi
if [[ -n "$LLAMA_SERVER_SOURCE" && -x "$LLAMA_SERVER_SOURCE" ]]; then
  cp "$LLAMA_SERVER_SOURCE" "$APP/Contents/MacOS/llama-server"
  chmod 755 "$APP/Contents/MacOS/llama-server"
  echo "Bundled llama-server from $LLAMA_SERVER_SOURCE"
else
  echo "llama-server not bundled; set RAT_LLAMA_SERVER or install llama.cpp"
fi

codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=/Signed by: /p; s/^Signature=/Signature=/p'
echo "$APP"
