#!/bin/sh
set -eu
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK=/opt/homebrew/share/android-commandlinetools
BT="$SDK/build-tools/36.0.0"
PLATFORM="$SDK/platforms/android-36/android.jar"
WORK="$BASE/build"
KEYSTORE="$BASE/vendor/companion-debug.keystore"
API_AAR="$BASE/vendor/api-13.1.5.aar"
PROVIDER_AAR="$BASE/vendor/provider-13.1.5.aar"
AIDL_AAR="$BASE/vendor/aidl-13.1.5.aar"
SHARED_AAR="$BASE/vendor/shared-13.1.5.aar"
rm -rf "$WORK"
mkdir -p "$WORK/gen" "$WORK/classes" "$WORK/dex" "$WORK/aar-api" "$WORK/aar-provider" "$WORK/aar-aidl" "$WORK/aar-shared" "$WORK/apk"
unzip -q "$API_AAR" classes.jar -d "$WORK/aar-api"
unzip -q "$PROVIDER_AAR" classes.jar -d "$WORK/aar-provider"
unzip -q "$AIDL_AAR" classes.jar -d "$WORK/aar-aidl"
unzip -q "$SHARED_AAR" classes.jar -d "$WORK/aar-shared"
"$BT/aapt" package -f -m -J "$WORK/gen" -M "$BASE/AndroidManifest.xml" -I "$PLATFORM" --min-sdk-version 26 --target-sdk-version 35
CP="$PLATFORM:$WORK/aar-api/classes.jar:$WORK/aar-provider/classes.jar:$WORK/aar-aidl/classes.jar:$WORK/aar-shared/classes.jar"
find "$BASE/src/main/java" "$WORK/gen" -name '*.java' -print > "$WORK/sources.txt"
/usr/bin/env javac -source 8 -target 8 -classpath "$CP" -d "$WORK/classes" @"$WORK/sources.txt"
"$JAVA_HOME/bin/jar" cf "$WORK/classes.jar" -C "$WORK/classes" .
"$BT/d8" --min-api 26 --lib "$PLATFORM" --output "$WORK/dex" "$WORK/classes.jar" "$WORK/aar-api/classes.jar" "$WORK/aar-provider/classes.jar" "$WORK/aar-aidl/classes.jar" "$WORK/aar-shared/classes.jar"
"$BT/aapt" package -f -M "$BASE/AndroidManifest.xml" -I "$PLATFORM" --min-sdk-version 26 --target-sdk-version 35 -F "$WORK/companion-diagnostics-unsigned.apk"
(cd "$WORK/dex" && /usr/bin/zip -q -X "$WORK/companion-diagnostics-unsigned.apk" classes.dex)
"$BT/zipalign" -f 4 "$WORK/companion-diagnostics-unsigned.apk" "$WORK/companion-diagnostics-aligned.apk"
if [ ! -f "$KEYSTORE" ]; then keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias androiddebugkey -dname 'CN=GalaxyCallBridge Local Test,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1; fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android --out "$WORK/companion-diagnostics.apk" "$WORK/companion-diagnostics-aligned.apk"
"$BT/apksigner" verify --verbose --print-certs "$WORK/companion-diagnostics.apk"
