#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="${SWIFT_MODULECACHE_PATH:-${TMPDIR:-/tmp}/GCB-0.3.8-module-cache}"
mkdir -p "$MODULE_CACHE"
# Fixed bundle ID + stable signing identity keep the TCC (microphone/Bluetooth) grants across versions.
# Launch Services is still pointed at the requested release by launching the versioned .app path.
APP_VERSION="0.6.4"
export MACOSX_DEPLOYMENT_TARGET=15.0
APP_ID="local.gunhee.GalaxyCallBridge"
APP="${APP_OUTPUT:-$ROOT/build/GalaxyCallBridge-$APP_VERSION.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X "$ROOT/audio-experiment/connect-local-tunnel.sh" "$APP/Contents/Resources/connect-local-tunnel.sh"
cp -X "$ROOT/audio-experiment/discover-device.py" "$APP/Contents/Resources/discover-device.py"
swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library -sdk "$SDK" -framework AppKit -framework SwiftUI -framework IOBluetooth -framework CoreAudio -framework AVFoundation -framework Network \
  "$ROOT/Sources/BluetoothDeviceIdentity.swift" "$ROOT/Sources/LocalDiagnostics.swift" "$ROOT/Sources/AppInstanceLifecycle.swift" "$ROOT/Sources/GalaxyCallBridge.swift" "$ROOT/Sources/PhoneControlProtocol.swift" "$ROOT/Sources/CallHistoryStore.swift" "$ROOT/Sources/PhoneCallController.swift" "$ROOT/Sources/PhoneHomeView.swift" "$ROOT/Sources/KeypadSound.swift" "$ROOT/Sources/CallPresence.swift" "$ROOT/audio-experiment/host/AudioWire.swift" "$ROOT/audio-experiment/host/PCMExperimentCore.swift" "$ROOT/audio-experiment/host/AudioExperiment.swift" "$ROOT/audio-experiment/host/MicrophoneInput.swift" "$ROOT/audio-experiment/host/MicrophoneGain.swift" \
  -o "$APP/Contents/MacOS/GalaxyCallBridge"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GalaxyCallBridge</string>
<key>CFBundleIdentifier</key><string>${APP_ID}</string>
<key>CFBundleName</key><string>Galaxy Call Bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${APP_VERSION}</string>
<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>${MACOSX_DEPLOYMENT_TARGET}</string>
<key>NSMicrophoneUsageDescription</key><string>Galaxy 통화 중 DGM20 마이크로 상대방에게 말하기 위해 사용합니다. 통화 음성은 저장하지 않습니다.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>페어링 기기 목록과 사용자가 확인한 Bluetooth HFP 서비스 조회 및 통화 연결을 위해 Bluetooth에 접근합니다.</string>
</dict></plist>
PLIST
# Stable signature => designated requirement is identifier+certificate (not cdhash), so TCC keeps the grant.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $2; exit}' || true)}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "WARNING: no Apple Development identity found; signing ad-hoc. TCC permissions (microphone etc.) will NOT persist across builds." >&2
fi
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$APP_ID" "$APP"
codesign -dr - "$APP"
if [[ "${1:-}" == "--self-check" ]]; then
  TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/GCBIdentityChecks.XXXXXX")"
  swiftc -module-cache-path "$MODULE_CACHE" -framework CoreAudio "$ROOT/Sources/BluetoothDeviceIdentity.swift" "$ROOT/Sources/LocalDiagnostics.swift" "$ROOT/tests/main.swift" -o "$TEST_BIN"
  "$TEST_BIN"
  rm -f "$TEST_BIN"
fi
