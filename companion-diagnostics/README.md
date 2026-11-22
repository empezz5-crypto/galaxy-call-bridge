# GalaxyCallBridge Android 동반 앱 — 0.5.4

Galaxy S25의 Shizuku UserService에서 통화 상태·제어, 통화목록 메타데이터, PSTN PCM을 제공하는 Android 동반 앱입니다. 메인 Activity는 UID·권한·capability를 표시하고 서비스를 연결하는 역할입니다. 전화 명령은 Mac의 명시적인 사용자 동작에서, PCM 오디오는 실제 통화 연결 후 자동으로 시작합니다.

- 요구 실행 서비스 빌드: `20261014-053-r1`
- UserService version: `2026101404`
- 호환 Mac: `0.5.4`
- APK: `build/companion-diagnostics.apk`

`053-r1`은 기존 9자리 미만 단축번호 차단을 유지하고, Mac 요청 시 Android CallLog에서 최근 50건의 통화 정보만 반환합니다. 이 조회는 Shizuku UserService의 `com.android.shell` UID가 가진 시스템 `READ_CALL_LOG` 권한을 사용하며 APK에 권한을 추가하지 않습니다. 통화 중에는 PCM 양방향 세션을 통화 종료까지 유지하고 종료 상태를 감지하면 닫습니다.

## 제공 기능

| 구성 | 역할 |
| --- | --- |
| `MainActivity` | Shizuku 연결 및 비캡처 UID·권한·API 확인 |
| `CallControlServer` / `@gcb_control_v1` | 읽기 전용 `status`, 명시적 `dial`/`answer`/`end`. Mac 포워드 `127.0.0.1:38242` |
| `CallControlServer` / `recentCalls` | Mac 요청 시 최근 통화 50건의 번호·이름·시각·길이·유형을 반환 |
| `ProbeService` / `@gcb_audio_v1` | HELLO/무음/오류 진단, 하향·상향·동시 양방향 PCM. Mac 포워드 `127.0.0.1:38241` |
| `CallAudioBuilders` | 실제 shell UID/package attribution과 PSTN 속성을 갖춘 endpoint builder 준비·비캡처 계약 확인 |

전화 제어는 통화 상태·권한을 다시 확인하고 잘못된 번호·특수 서비스 문자열·긴급전화를 차단합니다. 요청 원문과 전화번호는 로그에 남기지 않습니다. `status`에는 최소 상태와 명령 가능 여부·빌드만 반환하며, 통화 목록은 사용자의 요청으로 Mac 화면에 표시하고 Mac 로컬 저장소에만 보관합니다. Android 서비스 로그에는 조회 건수만 남깁니다.

PCM endpoint는 하향 `0x30`, 상향 `0x32`, 양방향 `0x35` START와 통화 모드·`CALL_AUDIO_INTERCEPTION`·capability 검사를 통과한 뒤 만듭니다. 허용된 Shizuku가 감지되면 동반 앱은 UserService와 로컬 리스너를 자동 연결합니다. Mac 앱은 실제 통화가 active가 되면 양방향 시작을 자동 요청합니다. 앱 실행·HELLO·합성 무음 왕복·오류 자체 검사 `0x22`는 endpoint를 만들지 않습니다. PCM16 / 16 kHz / mono이며 통화 종료·소켓 오류·STOP에 오디오를 해제합니다. 하향/양방향 세션은 통화 종료까지, 상향 단방향 진단은 60초 유지합니다. 오디오 중지는 전화 자동 종료가 아닙니다.

## 빌드와 비캡처 검사

이 디렉터리에서 실행합니다.

```sh
./build-local.sh
./verify-noncall.sh
```

로컬 디버그 키로 APK를 서명합니다. Android SDK는 `/opt/homebrew/share/android-commandlinetools`, Java는 17입니다. Shizuku API/provider/AIDL/shared AAR 13.1.5는 `vendor/`를 사용합니다.

매니페스트는 Shizuku 연동 권한 `moe.shizuku.manager.permission.API_V23`만 선언하며 앱 자체의 마이크·연락처·통화 기록 권한을 추가하지 않습니다. 통화/오디오 API는 승인된 Shizuku shell 프로세스에서 실행합니다. `verify-noncall.sh`는 APK 신원·선언 권한·서명과 지연 실행 게이트를 검사하며 실제 전화·PCM·마이크 캡처는 하지 않습니다.

## 서비스 교체와 런타임 확인

APK 업데이트만으로 이전 Shizuku UserService가 교체됐다고 추정하지 않습니다. `.version(...)`과 실제 빌드가 함께 바뀌어야 하며, 수명 종료를 위한 Shizuku reserved destroy transaction `16777115`를 구현합니다.

기존 shell-only 준비 receiver는 `android.permission.DUMP`로 보호하며 통화가 없는 AudioManager 모드에서 기존 Shizuku 권한으로 리스너만 준비합니다. Activity를 앞으로 띄우거나 PCM을 시작하지 않습니다. 통화 중 앱·서비스 교체는 금지하고 현재 통화 상태를 읽기 전용으로 확인한 뒤 진행합니다. 새 페어링이나 네트워크 설정을 바꾸지 않습니다.

실행 확인에는 PCM HELLO의 빌드/PID/서비스 시작 시각/세션과 통화 제어 `status`의 빌드를 사용합니다. 설치 APK 해시 일치만으로 최신 서비스 실행을 입증할 수 없습니다. Android `GCB_PCM`/통화 제어 로그에는 단계·고정 오류 코드·예외 종류·프레임/바이트 수 같은 메타데이터만 남깁니다. 번호·상대방 정보·통화 내용·원시 음성·예외 원문은 저장하지 않습니다.

## 실제 성공 범위

UID 2000, `CALL_AUDIO_INTERCEPTION` 허용, `isPstnCallAudioInterceptable()==true`는 확인됐지만 이것만으로 음성 추출이나 주입 성공을 뜻하지 않습니다. 0.4.7에서 사용자가 실제 하향 청취를 확인했습니다. 상향은 작게 들린다는 피드백이 있고 0.4.8의 DGM20/증폭 이후 품질 개선은 미확인입니다. 0.5.3 실제 전화 제어와 양방향 음성은 사용자 통화에서 추가 검증해야 합니다. 에코 제거는 아직 없습니다.

과거 preflight는 [PREFLIGHT.md](PREFLIGHT.md), 시간순 오류·수정·실행 증거는 [STATUS.md](../audio-experiment/STATUS.md)에 보존합니다. 기능의 현재 설명은 이 문서와 [상위 README](../README.md)를 기준으로 하고, 예전 “오디오/전화 조작 미구현” 설명은 현재 버전에 적용하지 않습니다.

0.5.4는 활성 통화에서 DGM20 상향과 Mac 출력 하향을 자동 연결합니다. 실제 양방향 통화 음질은 사용자 시험으로 확인해야 합니다. 자세한 적용 상태는 [상태 기록](../audio-experiment/STATUS.md)을 확인하세요.
