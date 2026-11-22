#!/bin/sh
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APK="$BASE/build/companion-diagnostics.apk"
AAPT=/opt/homebrew/share/android-commandlinetools/build-tools/36.0.0/aapt
APKSIGNER=/opt/homebrew/share/android-commandlinetools/build-tools/36.0.0/apksigner
[ -f "$APK" ] || { echo 'FAIL: APK missing; build first'; exit 1; }
unzip -l "$APK" | grep -Eq '[[:space:]]classes\.dex$' || { echo 'FAIL: classes.dex missing at APK root'; exit 1; }
"$AAPT" dump badging "$APK" | grep -q "package: name='com.galaxycallbridge.diagnostics'" || { echo 'FAIL: package id'; exit 1; }
PERMS=$("$AAPT" dump permissions "$APK")
if printf '%s\n' "$PERMS" | grep 'uses-permission' | grep -v 'moe.shizuku.manager.permission.API_V23'; then echo 'FAIL: unexpected Android permission'; printf '%s\n' "$PERMS"; exit 1; fi
printf '%s\n' "$PERMS" | grep -q 'moe.shizuku.manager.permission.API_V23' || { echo 'FAIL: Shizuku API permission missing'; exit 1; }
if grep -n -E 'AudioRecord|AudioTrack|startRecording|RECORD_AUDIO|READ_CONTACTS|READ_CALL_LOG|ACTION_CALL|CALL_PHONE|\.play\(' "$BASE/src/main/java/com/galaxycallbridge/diagnostics/MainActivity.java"; then
  echo 'FAIL: UI eagerly accesses audio, calls, or PII'; exit 1
fi
grep -q 'type==START_DOWN || type==START_UP' "$BASE/src/main/java/com/galaxycallbridge/diagnostics/ProbeService.java" || { echo 'FAIL: explicit start gate missing'; exit 1; }
if grep -Eq 'android.permission.(INTERNET|RECORD_AUDIO|READ_CONTACTS|READ_CALL_LOG|CALL_PHONE)' "$BASE/AndroidManifest.xml"; then echo 'FAIL: unexpected Android permission'; exit 1; fi
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"
"$APKSIGNER" verify --verbose "$APK" >/dev/null
echo 'PASS: package identity, only Shizuku API permission, no Internet/mic/PII permissions, deferred PCM API gates, APK signature integrity.'
grep -q 'CallAudioBuilders.downlink(context,f)' "$BASE/src/main/java/com/galaxycallbridge/diagnostics/ProbeService.java"
grep -q 'CallAudioBuilders.uplink(context,f)' "$BASE/src/main/java/com/galaxycallbridge/diagnostics/ProbeService.java"
if grep -q '\.build()' "$BASE/src/main/java/com/galaxycallbridge/diagnostics/CallAudioBuilders.java"; then
  # Attribute/source build() is allowed; endpoint builder.build() must remain in gated ProbeService.
  if grep -q 'builder.build()' "$BASE/src/main/java/com/galaxycallbridge/diagnostics/CallAudioBuilders.java"; then exit 1; fi
fi
