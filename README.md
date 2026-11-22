# Galaxy Call Bridge

Galaxy Call Bridge lets a Mac control cellular calls on a Samsung Galaxy S25 and carry two-way call audio through a headset and DGM20 USB microphone. The phone remains the cellular endpoint.

## Requirements

- macOS 15 or later, Xcode Command Line Tools, Python 3 and Homebrew Android platform-tools.
- Galaxy S25 (tested on SM-S931N), with authorized USB or wireless debugging and Shizuku.
- Android SDK Platform 36, Build Tools 36.0.0 and Homebrew OpenJDK 17 to build the companion.

## Build and connect

1. Run `./build.sh --self-check` and `./companion-diagnostics/build-local.sh`.
2. Install the resulting companion APK on your own authorized device. Start Shizuku, open the companion, and grant its Shizuku request.
3. In `~/Library/Application Support/GalaxyCallBridge/trusted-device.json`, set `{"serial":"YOUR_S25_HARDWARE_SERIAL"}`. Read the hardware serial locally with `adb -d shell getprop ro.serialno` over authorized USB. Keep this file private.
4. Open `build/GalaxyCallBridge-0.6.4.app`. Use **전화 열기** in the menu bar to open the dialer. Grant microphone access for audio.
5. For wireless operation, pair the Mac in Android Wireless debugging. The app discovers the registered device's TLS service and remembers its last verified address.

## Verification and limits

- Incoming calls and two-way audio through an external headset and DGM20 were verified on the S25 with 0.6.2. Version 0.6.4 was verified to open its call-control tunnel over wireless ADB.
- Wi-Fi roaming, unattended recovery after a phone reboot, and long calls remain unverified. A network that blocks local discovery can prevent reconnection after the phone's address or port changes.
- Bluetooth call control remains experimental. Echo cancellation and caller contact-name display are not implemented.
- Call audio is not recorded by the app. Recent call details are stored locally. Do not commit local data, logs, enrollment files or signing keys.

The Android companion bundles Shizuku API 13.1.5. See its [third-party license](companion-diagnostics/vendor/SHIZUKU-API-LICENSE).

## License

Galaxy Call Bridge is licensed under the [MIT License](LICENSE).
