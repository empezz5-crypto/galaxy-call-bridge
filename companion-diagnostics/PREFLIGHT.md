# GalaxyCallBridge Android companion diagnostics — final device result

Updated: 2026-10-13

## Completed

- Created this dedicated folder on the external drive inside the existing GalaxyCallBridge project.
- Confirmed the pre-authorized ADB target is the Samsung SM-S931N / Galaxy S25, Android 16 / API 36. Device serial omitted.
- Downloaded Shizuku v13.6.0 only from the official download page's RikkaApps GitHub link and installed it as a fresh package (no previous Shizuku package was present).
- Built and installed our companion diagnostic app. The official Shizuku API/provider/AIDL/shared 13.1.5 artifacts are included. A first runtime attempt exposed omitted AIDL classes; this was fixed. A second attempt exposed missing provider-AAR manifest merge entries; the exact official API permission and V3 metadata were added. The corrected app launched and received the Shizuku binder.
- Used the in-app authorization dialog and selected “Always allow” for `com.galaxycallbridge.diagnostics` only. The app reported “Shizuku UserService connected.”
- Started Shizuku with the exact command shown by the installed app’s “Show command” UI (not a guessed/stale `start.sh` path):
  `adb shell /data/app/~~u-FtvYj_UQu21IXwdI4Hyw==/moe.shizuku.privileged.api-icoE4h7KWRGAc8Z70XwA-w==/lib/arm64/libshizuku.so`
- Starter reported exit code 0 and server PID 10908. `ps` showed `shizuku_server` running as `shell` (UID 2000); Shizuku UI showed it running.

## Official Shizuku package verification

- Official download page: https://shizuku.rikka.app/download/
- Official release: https://github.com/RikkaApps/Shizuku/releases/tag/v13.6.0
- Asset: `shizuku-v13.6.0.r1086.2650830c-release.apk`
- Package/version: `moe.shizuku.privileged.api`, `13.6.0.r1086.2650830c`, version code 1086.
- `apksigner verify --verbose`: signature integrity passed with v2 scheme; one signer.
- Observed signer certificate SHA-256: `268b5590e868fb08bae7e0ac413564cd1ff88f5ccff74af9dbd0dc918e30db30`.
- Observed APK SHA-256: `6e273ab0e991c4e79bc8b1bbb9b9dd739ccac1a8712a541a214078886b7b790f`.
- These are observations from the installed official artifact; no independently published signer fingerprint/checksum was claimed or available. It was a fresh install, not an update.

## On-device diagnostic results

The UserService ran under UID **2000**, matching shell. It reported:

- `CALL_AUDIO_INTERCEPTION` held: **yes**
- `AudioManager.isPstnCallAudioInterceptable()` method present: **yes**
- Explicit non-capture capability query returned: **true**

Android 16 AOSP's `AudioService.isPstnCallAudioInterceptable()` checks whether both telephony TX and telephony RX audio devices are enumerated, then returns true. This confirms the platform reports both telephony audio endpoints as available to the service. It does **not** prove that a call is active, that those endpoints carry call audio, or that any audio can be captured/injected or routed bidirectionally. See [Android 16 AOSP implementation](https://android.googlesource.com/platform/frameworks/base/+/android16-release/services/core/java/com/android/server/audio/AudioService.java) and the [AudioService AIDL permission annotation](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/media/java/android/media/IAudioService.aidl).

No `AudioRecord`/`AudioTrack` was obtained or started; no PCM was read, played, injected, saved, or sent. No call was placed, answered, or ended. No mic, contact, call-log, default dialer, Bluetooth pairing, wireless debugging, or Android security settings were changed. The Mac foreground app was not changed.

## Companion app and checks

- Source/build: `AndroidManifest.xml`, `src/main/java/`, `build-local.sh`; built APK: `build/companion-diagnostics.apk`.
- Official Shizuku API/provider/AIDL/shared artifacts 13.1.5 are in `vendor/`.
- Manifest declares only the Shizuku API permission `moe.shizuku.manager.permission.API_V23`; there are no microphone, telephony, contacts, or call-log permissions.
- `verify-noncall.sh` passed after the provider manifest merge fix. It checks package identity, the sole Shizuku API permission, absence of telephony/PCM/PII APIs, and APK signature integrity.

## Rollback

In Shizuku's app authorization list, revoke only `GalaxyCallBridge 진단`; then uninstall `com.galaxycallbridge.diagnostics` in Android settings. Stop the Shizuku service from the Shizuku app if desired. Shizuku stops on reboot for this ADB startup mode. No security settings need to be changed.
