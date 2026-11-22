# Galaxy 통화 PCM — Mac 0.5.0

Galaxy의 일반 통화 음성을 기존 Shizuku와 인증된 ADB 연결을 통해 Mac 루프백으로 전송합니다. Bluetooth HFP/SCO 연결 없이 동작하는 별도 경로입니다. 현재 프로토콜이 요구하는 Android 서비스 빌드는 `20261014-052-r1`, UserService version은 `2026101403`입니다. 설치·실행 확인과 과거 오류 증거는 [STATUS.md](STATUS.md)에 기록합니다.

## 시작과 사용자 동작

- 메인 전화 화면에서 통화 연결 후 `Mac에서 통화`를 누르고 스피커·DGM20 사용을 확인하면 동시 양방향 PCM을 시작합니다.
- 하향만 듣기와 상향만 말하기는 별도 진단 시트에서 시험할 수 있습니다. 하나의 세션에서 선택한 모드만 실행합니다.
- 앱 실행, 상태 조회, 수신 전화 알림, 전화 받기, HELLO, 무음 왕복, 오류 자체 검사는 PCM이나 마이크를 자동으로 시작하지 않습니다.
- 상향/양방향은 명시적 시작 후 Mac 마이크 권한을 확인한 다음 Android 시작을 요청합니다. Mac 오디오 엔진은 Android `STARTED`를 받은 뒤에만 엽니다.
- DGM20을 명시적으로 선택·검증하며, 미연결·장치 변경 시 다른 입력으로 대체하지 않습니다. 송신 증폭은 기본 2배, 수동 1–6배와 리미터이며 장치명·입력 레벨·음소거를 제공합니다.

하향 재생은 통화 종료 시 자동으로 해제됩니다. 상향/양방향은 60초 시험 제한이며 전화 자체는 자동 종료하지 않습니다. 음향 에코 제거는 없으며 동시 양방향 음질·지연·스피커 재유입은 실제 시험 전입니다. 번호·통화 내용·원시 음성은 저장하지 않습니다.

## 소켓과 프로토콜

| 용도 | Mac | Android | 요청 |
| --- | --- | --- | --- |
| PCM | `127.0.0.1:38241` | `@gcb_audio_v1` | 하향 `0x30`, 상향 `0x32`, 동시 양방향 `0x35`, STOP `0x34` |
| 통화 제어 | `127.0.0.1:38242` | `@gcb_control_v1` | 읽기 전용 `status`, 사용자 동작 `dial`/`answer`/`end` |

GCB1 헤더의 kind/length는 big-endian, PCM payload는 signed PCM16 little-endian / 16 kHz / mono / 20 ms / 640바이트입니다. RAM 큐는 제한된 프레임만 유지합니다. Android는 명시적 START 후 통화 모드·권한·capability를 검사하고, 검증된 shell attribution과 PSTN 속성을 사용하는 `CallAudioBuilders`로 해당 AudioRecord/AudioTrack을 만듭니다. 메서드 존재나 capability=true만으로 실제 음성 전달을 입증할 수 없습니다.

양방향은 같은 세션에서 하향 읽기와 상향 쓰기를 함께 수행합니다. 엔드포인트 생성 실패, 통화 종료, 타임아웃, 소켓/형식 오류, 명시적 중지는 양쪽 오디오를 정리합니다. 이전 세션의 늦은 콜백이 새 세션을 시작하거나 종료하지 않도록 식별자를 확인합니다.

## 기존 ADB 연결 유지

도우미 인자: `connect-local-tunnel.sh [exact-adb-serial] [port] [wireless-confirmation] [repair-option] [socket-name]`. 기본 포트/소켓은 `38241` / `gcb_audio_v1`이고, 통화 제어는 `38242` / `gcb_control_v1`을 지정합니다. 도우미는 `127.0.0.1:5037`의 ADB 서버와 기존 인증된 기기에만 포워드를 만듭니다. 다른 포워드를 덮어쓰거나 새 페어링·네트워크 설정을 변경하지 않습니다.

PCM 터널의 자동 유지는 포워드 목록과 Android `/proc/net/unix`만 확인하며 PCM 소켓을 열지 않습니다. 오디오 실행 중에는 유지 점검을 건너뜁니다. 별도 제어 소켓의 `status` 조회는 PCM 소켓을 점유하지 않습니다. 주소·포트는 현재 인증 연결에서 확인하며 과거 주소를 그대로 신뢰하지 않습니다.

## 검사와 증거

저장소 루트에서 실행합니다.

```sh
./audio-experiment/test-wire.sh
./audio-experiment/test-error-delivery.sh
./audio-experiment/test-mic-gain.sh
```

기본 검사는 합성 프레임·시작 게이트·큐/음소거·변환/증폭·실제 Mac controller의 오류 전달/순서를 시험합니다. `test-error-delivery.sh --live`는 별도 비캡처 opcode `0x22` 오류 전달만 확인합니다. HELLO·640바이트 무음 왕복 성공은 실제 통화 성공을 의미하지 않습니다.

0.4.7 하향은 사용자가 실제 Mac에서 들린다고 확인했습니다. 상향은 작게 전달된다는 사용자 피드백이 있으며 0.4.8 DGM20/증폭 적용 후 개선은 미확인입니다. 0.5.3 실제 발신·수신 및 동시 양방향 청취는 미검증입니다. 최종 확인은 사용자가 선택한 통화에서 직접 시작하고 양쪽 청취 결과를 확인해야 합니다.

통화 중 앱·서비스를 종료/업데이트하지 않습니다. 소스/APK 보존본은 `checkpoints/before-0.5.0-20261013.tgz`입니다. 자세한 절차와 현재 배포 상태는 [상위 README](../README.md), [PROJECT.md](../PROJECT.md), [STATUS.md](STATUS.md)를 확인하세요.

최종 적용: 2026-10-14 Mac0.5.3 PID58792, Android052-r1 PID25951. 통화 상태와 비캡처 프로토콜 확인 완료. 실제 통화 자동 하향 재생은 사용자 시험 전입니다. 정확한 근거와 제한은 [상태 기록](STATUS.md)을 확인하세요.
