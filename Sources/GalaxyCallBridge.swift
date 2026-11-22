import AppKit
import SwiftUI
import IOBluetooth
import UniformTypeIdentifiers

struct DeviceRow: Identifiable {
    let id: String; let name: String; let connected: Bool; let cachedAG: Bool?; let device: IOBluetoothDevice; let displayHint: String; let sdpQueried: Bool
    var displayName: String { displayHint.isEmpty ? name : "\(name) · \(displayHint)" }
    var serviceLabel: String {
        if cachedAG == true { return "HFP AG 확인됨" }
        return sdpQueried ? "저장 SDP에 AG 없음" : "SDP 미조회"
    }
}
enum ConnectionLabel { static func korean(connected: Bool) -> String { connected ? "Bluetooth 링크 연결됨" : "Bluetooth 링크 끊김" } }

@MainActor final class DeviceStore: NSObject, ObservableObject, @preconcurrency IOBluetoothHandsFreeDeviceDelegate, @preconcurrency IOBluetoothDeviceAsyncCallbacks {
    @Published private(set) var devices: [DeviceRow] = []
    @Published var selectedID: String?
    @Published private(set) var hfp = "HFP 연결 안 됨"
    @Published private(set) var sco = "SCO 오디오 안 됨"
    @Published private(set) var callActive = "활성 통화 상태 이벤트 미수신"
    @Published private(set) var callActiveValue: Int?
    @Published private(set) var callSetup = "통화 설정 이벤트 미수신"
    @Published private(set) var callHeld = "보류 상태 이벤트 미수신"
    @Published private(set) var callNotice = "통화 제어 이벤트 대기"
    @Published private(set) var events: [String] = []
    @Published private(set) var audioOutput = AudioOutputSnapshot(totalDeviceCount: nil, outputDeviceCount: nil, defaultOutputDeviceID: nil, queryStatus: -1)
    private let diagnostics = LocalDiagnosticJournal()
    var diagnosticsLocation: String { "~/Library/Application Support/GalaxyCallBridge/diagnostics.jsonl" }
    var diagnosticsStateLabel: String { diagnostics.lastWriteSucceeded ? "로컬 진단 기록 가능" : "로컬 진단 파일 기록 불가" }
    var audioDeliveryLabel: String {
        audioOutput.hasDefaultOutput
            ? "CoreAudio 기본 출력 식별됨 · Bluetooth 통화 음성 전달은 미검증"
            : "CoreAudio 기본 출력 식별 안 됨 · Bluetooth 통화 음성 전달은 미검증"
    }
    @Published var error: String?
    private var session: IOBluetoothHandsFreeDevice?
    private var pendingSDP: (deviceID: String, requestID: UUID)?
    private var sdpTimeout: DispatchWorkItem?
    override init() {
        super.init()
        diagnostics.record(event: .appStarted, status: .started)
        refreshAudioOutput()
    }
    var selected: DeviceRow? { devices.first { $0.id == selectedID } }
    var hfpOn: Bool { session?.isConnected == true }
    var scoOn: Bool { session?.isSCOConnected() == true }

    func refresh() {
        // Read existing paired list and cached SDP records only. Never call performSDPQuery here.
        guard let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            diagnostics.record(event: .pairedDeviceInventory, status: .failed)
            error = "페어링 기기를 읽지 못했습니다. Bluetooth 접근 권한/상태를 확인하세요."
            return
        }
        diagnostics.record(event: .pairedDeviceInventory, status: .succeeded, indicatorValue: list.count)
        let uniqueDevices = BluetoothDeviceIdentity.uniqueByID(list) { device in
            BluetoothDeviceIdentity.id(address: device.addressString,
                                       fallback: String(describing: ObjectIdentifier(device)))
        }
        let rows = uniqueDevices.map { d in
            let identity = BluetoothDeviceIdentity.id(address: d.addressString,
                                                     fallback: String(describing: ObjectIdentifier(d)))
            let records = d.services as? [IOBluetoothSDPServiceRecord]
            return DeviceRow(id: identity, name: d.name ?? "이름 없는 기기", connected: d.isConnected(),
                             cachedAG: records?.contains { $0.matchesUUID16(0x111F) }, device: d,
                             displayHint: "", sdpQueried: records != nil)
        }
        let sameNameGroups = Dictionary(grouping: rows, by: { $0.name.localizedLowercase })
        let nameCounts = sameNameGroups.mapValues(\.count)
        let hintsByID = sameNameGroups.values.reduce(into: [String: String]()) { result, group in
            guard group.count > 1 else { return }
            result.merge(BluetoothDeviceIdentity.uniqueDisplayHints(ids: group.map(\.id))) { current, _ in current }
        }
        devices = rows.map { row in
            guard (nameCounts[row.name.localizedLowercase] ?? 0) > 1 else { return row }
            return DeviceRow(id: row.id, name: row.name, connected: row.connected, cachedAG: row.cachedAG,
                             device: row.device, displayHint: hintsByID[row.id] ?? "식별정보 없음", sdpQueried: row.sdpQueried)
        }.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
        // Preserve an explicit selection. When multiple devices exist, never silently target the first row.
        if !devices.contains(where: { $0.id == selectedID }) {
            selectedID = devices.count == 1 ? devices.first?.id : nil
        }
        error = nil
    }
    func queryHFPServiceThenConnect() {
        guard let target = selected else { error = "기기를 선택하세요. 이름이 같은 여러 기기가 있으면 주소 끝자리로 대상을 구분해 직접 선택해야 합니다."; return }
        guard pendingSDP == nil else { error = "이미 Bluetooth 서비스 조회가 진행 중입니다."; return }
        // Cached absence can be stale or incomplete; the explicit UI confirmation authorizes a fresh SDP query.
        let requestID = UUID()
        pendingSDP = (target.id, requestID)
        hfp = "SDP 서비스 조회 중 · 새 Bluetooth 링크가 열릴 수 있음"
        log("사용자 확인 후 SDP 조회 시작 · Bluetooth baseband 연결 가능")
        let slowResponseWarning = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSDP?.requestID == requestID else { return }
            // Keep accepting the original callback: this Mac's SDP response arrived after 25 seconds.
            self.hfp = "SDP 조회 지연 · 결과 대기 중"
            self.log("SDP 25초 초과 · 제한 시간 연장 후 콜백 대기")
            let finalTimeout = DispatchWorkItem { [weak self] in
                guard let self, self.pendingSDP?.requestID == requestID else { return }
                self.pendingSDP = nil
                self.hfp = "SDP 조회 시간 초과 · 연결 상태 미확인"
                self.log("SDP 최종 제한 시간 초과")
            }
            self.sdpTimeout = finalTimeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: finalTimeout)
        }
        sdpTimeout = slowResponseWarning
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: slowResponseWarning)
        let status = target.device.performSDPQuery(self)
        diagnostics.record(event: .sdpQueryStarted, status: status == kIOReturnSuccess ? .accepted : .failed, errorCode: status)
        guard status == kIOReturnSuccess else {
            sdpTimeout?.cancel(); sdpTimeout = nil; pendingSDP = nil
            hfp = "SDP 조회 시작 실패 (\(status))"
            error = "Bluetooth SDP 조회를 시작하지 못했습니다. 상태 코드: \(status)"
            return
        }
    }

    private func updateSDPRow(device: IOBluetoothDevice, hasHFPAG: Bool?, queryFinished: Bool) {
        let identity = BluetoothDeviceIdentity.id(address: device.addressString,
                                                  fallback: String(describing: ObjectIdentifier(device)))
        guard let index = devices.firstIndex(where: { $0.id == identity }) else { return }
        let old = devices[index]
        devices[index] = DeviceRow(id: old.id, name: old.name, connected: device.isConnected(),
                                   cachedAG: hasHFPAG, device: device, displayHint: old.displayHint,
                                   sdpQueried: queryFinished)
    }

    func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        DispatchQueue.main.async {
            let identity = BluetoothDeviceIdentity.id(address: device.addressString,
                                                       fallback: String(describing: ObjectIdentifier(device)))
            guard let pending = self.pendingSDP, pending.deviceID == identity else { return }
            self.sdpTimeout?.cancel(); self.sdpTimeout = nil; self.pendingSDP = nil
            self.diagnostics.record(event: .sdpQueryCompleted, status: status == kIOReturnSuccess ? .succeeded : .failed, errorCode: status)
            guard status == kIOReturnSuccess else {
                self.updateSDPRow(device: device, hasHFPAG: nil, queryFinished: false)
                self.hfp = "SDP 조회 실패 (\(status))"
                self.error = "Bluetooth 서비스 조회가 실패했습니다. 상태 코드: \(status). HFP 연결은 시도하지 않았습니다."
                self.log("SDP 조회 오류 콜백 · 상태 \(status)")
                return
            }
            let records = device.services as? [IOBluetoothSDPServiceRecord]
            let advertised = records?.contains { $0.matchesUUID16(0x111F) } == true
            self.updateSDPRow(device: device, hasHFPAG: advertised, queryFinished: true)
            guard advertised else {
                self.hfp = "조회 완료 · HFP Audio Gateway 미광고 (지원 확인 안 됨)"
                self.log("SDP 성공 · HFP AG UUID 0x111F 미광고")
                return
            }
            self.log("SDP 성공 · HFP AG UUID 0x111F 확인 · HFP 링크 연결 시작")
            self.connectConfirmedHFP(device: device)
        }
    }

    func remoteNameRequestComplete(_ device: IOBluetoothDevice, status: IOReturn) { }
    func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) { }

    private func connectConfirmedHFP(device: IOBluetoothDevice) {
        guard let session = IOBluetoothHandsFreeDevice(device: device, delegate: self) else {
            hfp = "HFP AG 확인됨 · 세션 초기화 실패"; error = "HFP AG는 조회됐지만 HFP 세션 생성이 실패했습니다."
            diagnostics.record(event: .hfpConnectRequested, status: .failed)
            return
        }
        self.session = session
        hfp = "HFP AG 확인됨 · HFP 서비스 연결 중"
        diagnostics.record(event: .hfpConnectRequested, status: .requested)
        session.connect()
    }

    func connect() {
        guard let d = selected else { error = "기기를 선택하세요."; return }
        guard d.cachedAG == true else { error = "캐시에서 HFP Audio Gateway (0x111F)를 확인하지 못했습니다. 먼저 사용자 확인을 거쳐 서비스 조회를 하세요."; return }
        log("사용자가 HFP 연결을 확인함")
        connectConfirmedHFP(device: d.device)
    }
    func disconnect() {
        diagnostics.record(event: .hfpDisconnectRequested, status: .requested)
        session?.disconnect(); hfp = "HFP 해제 요청 중"; log("사용자 HFP 해제")
    }
    func connectSCO() {
        guard let s = session, s.isConnected else { error = "HFP 연결 후 시도하세요."; diagnostics.record(event: .operationRejected, status: .failed); return }
        sco = "SCO 연결 요청 중"
        diagnostics.record(event: .scoConnectRequested, status: .requested, audio: audioOutput)
        log("사용자 확인으로 SCO 요청")
        s.connectSCO()
    }
    func disconnectSCO() {
        diagnostics.record(event: .scoDisconnectRequested, status: .requested)
        session?.disconnectSCO(); sco = "SCO 해제 요청 중"; log("사용자 SCO 해제")
    }
    func transferAudioToComputer() {
        guard let s = session, s.isConnected else { error = "HFP 연결 후 시도하세요."; diagnostics.record(event: .transferAudioToComputerRequested, status: .failed); return }
        callNotice = "Mac 오디오 경로 전환 요청 전송됨 · 실제 경로 미확인"
        log("사용자 확인으로 transferAudioToComputer 요청 · 오디오 경로 미검증")
        diagnostics.record(event: .transferAudioToComputerRequested, status: .requested, audio: audioOutput)
        s.transferAudioToComputer()
        diagnostics.record(event: .transferAudioToComputerRequested, status: .invokedVoidAPI, audio: audioOutput)
    }
    func dial(_ number: String) { guard let s = session, s.isConnected else { error = "HFP 연결 후 발신하세요."; return }; guard !number.trimmingCharacters(in: .whitespaces).isEmpty else { error = "전화번호를 입력하세요."; return }; s.dialNumber(number); callNotice = "발신 요청 전송됨"; diagnostics.record(event: .outgoingCallRequested, status: .requested); log("사용자가 발신 요청") }
    func answer() { guard let s = session, s.isConnected else { error = "HFP 연결 상태를 확인하세요."; return }; s.acceptCall(); callNotice = "응답 요청 전송됨"; diagnostics.record(event: .incomingCallAnswered, status: .requested); log("사용자가 응답 요청") }
    func endCall() { guard let s = session, s.isConnected else { error = "HFP 연결 상태를 확인하세요."; return }; s.endCall(); callNotice = "통화 종료 요청 전송됨"; diagnostics.record(event: .callEnded, status: .requested); log("사용자가 통화 종료 요청") }
    func poll() {
        if let s = session {
            let connected = s.isConnected
            let scoConnected = s.isSCOConnected()
            hfp = connected ? "HFP 서비스 연결됨" : "HFP 서비스 연결 안 됨"
            sco = scoConnected ? "SCO 링크 연결됨 · 양방향 음성 미검증" : "SCO 오디오 링크 대기"
            diagnostics.record(event: .hfpStateRead, status: connected ? .connected : .disconnected)
            diagnostics.record(event: .scoStateRead, status: scoConnected ? .connected : .disconnected)
        }
        refreshAudioOutput()
    }
    func refreshAudioOutput() {
        audioOutput = AudioOutputSnapshot.read()
        let status: DiagnosticStatus = audioOutput.hasDefaultOutput ? .readOnly : .noDefaultOutput
        diagnostics.record(event: .coreAudioOutputSnapshot, status: status, errorCode: audioOutput.queryStatus, audio: audioOutput)
    }
    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "진단 로그 내보내기"
        panel.prompt = "진단 파일 저장"
        panel.nameFieldStringValue = "GalaxyCallBridge-diagnostics.jsonl"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            diagnostics.record(event: .diagnosticsExport, status: .cancelled)
            return
        }
        do {
            diagnostics.record(event: .diagnosticsExport, status: .requested)
            try diagnostics.export(to: url)
            diagnostics.record(event: .diagnosticsExport, status: .exported)
            try diagnostics.export(to: url)
        } catch {
            self.error = "진단 파일을 내보내지 못했습니다."
            diagnostics.record(event: .diagnosticsExport, status: .failed)
        }
    }
    private func log(_ text: String) { events.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0); if events.count > 8 { events.removeLast() } }
    func handsFree(_ device: IOBluetoothHandsFree, connected status: NSNumber) { DispatchQueue.main.async { let ok = status.int32Value == 0; self.hfp = ok ? "HFP 서비스 연결됨" : "HFP 연결 실패 (\(status))"; self.diagnostics.record(event: .hfpConnectionResult, status: ok ? .connected : .failed, errorCode: status.int32Value); self.log("HFP 연결 완료 콜백 · 상태 \(status)") } }
    func handsFree(_ device: IOBluetoothHandsFree, disconnected status: NSNumber) { DispatchQueue.main.async { self.hfp = "HFP 서비스 연결 해제됨"; self.sco = "SCO 오디오 안 됨"; self.diagnostics.record(event: .hfpDisconnectionResult, status: status.int32Value == 0 ? .disconnected : .failed, errorCode: status.int32Value); self.log("HFP 연결 해제 콜백 · 상태 \(status)") } }
    func handsFree(_ device: IOBluetoothHandsFree, scoConnectionOpened status: NSNumber) { DispatchQueue.main.async { let ok = status.int32Value == 0; self.sco = HFPEventLabels.scoStatus(status.int32Value); self.diagnostics.record(event: .scoConnectionResult, status: ok ? .succeeded : .failed, errorCode: status.int32Value, audio: self.audioOutput); self.log("SCO 연결 콜백 · 상태 \(status) · \(self.sco)") } }
    func handsFree(_ device: IOBluetoothHandsFree, scoConnectionClosed status: NSNumber) { DispatchQueue.main.async { self.sco = "SCO 오디오 링크 닫힘"; self.diagnostics.record(event: .scoDisconnectionResult, status: status.int32Value == 0 ? .succeeded : .failed, errorCode: status.int32Value); self.log("SCO 해제 콜백 · 상태 \(status)") } }
    func handsFree(_ device: IOBluetoothHandsFreeDevice, isServiceAvailable value: NSNumber) { DispatchQueue.main.async { self.hfp = value.boolValue ? "HFP 서비스 사용 가능" : "HFP 서비스 사용 불가"; self.log("서비스 가용성 이벤트 수신") } }
    func handsFree(_ device: IOBluetoothHandsFreeDevice, isCallActive value: NSNumber) { DispatchQueue.main.async { self.callActiveValue = value.intValue; self.callActive = HFPEventLabels.callActive(value.intValue) + " (HFP 이벤트)"; self.diagnostics.record(event: .callActiveIndicator, status: .valueReported, indicatorValue: value.intValue); self.log("활성 통화 상태 이벤트 수신") } }
    func handsFree(_ device: IOBluetoothHandsFreeDevice, callSetupMode value: NSNumber) { DispatchQueue.main.async { self.callSetup = HFPEventLabels.callSetup(value.intValue) + " (HFP 이벤트)"; self.diagnostics.record(event: .callSetupIndicator, status: .valueReported, indicatorValue: value.intValue); self.log("통화 설정 이벤트 수신") } }
    func handsFree(_ device: IOBluetoothHandsFreeDevice, callHoldState value: NSNumber) { DispatchQueue.main.async { self.callHeld = HFPEventLabels.callHeld(value.intValue) + " (HFP 이벤트)"; self.diagnostics.record(event: .callHoldIndicator, status: .valueReported, indicatorValue: value.intValue); self.log("통화 보류 상태 이벤트 수신") } }
    func handsFree(_ device: IOBluetoothHandsFreeDevice, incomingCallFrom number: String) { DispatchQueue.main.async { self.callNotice = "수신 통화 알림 (발신자 정보 미보관)"; self.diagnostics.record(event: .incomingCallIndicator, status: .detailsOmitted); self.log("수신 통화 이벤트 · 번호 미보관") } }
    func handsFree(_ device: IOBluetoothHandsFreeDevice, currentCall callInfo: [AnyHashable: Any]) { DispatchQueue.main.async { self.callNotice = "통화 정보 이벤트 수신 (세부정보 미보관)"; self.diagnostics.record(event: .currentCallIndicator, status: .detailsOmitted); self.log("통화 정보 이벤트 · 미보관") } }
}

struct DiagnosticsView: View {
    @StateObject private var store = DeviceStore()
    @State private var number = ""
    @State private var confirm: Action?
    @ObservedObject var audioExperiment: AudioExperimentController
    @State private var testReady = false
    @State private var readyPrompt = false
    enum Action: String, Identifiable { case sdp, connect, disconnect, sco, unsco, transferAudio, dial, answer, end; var id: String { rawValue }; var title: String { ["sdp":"HFP 서비스 조회 후 연결", "connect":"HFP 연결", "disconnect":"HFP 연결 해제", "sco":"SCO 오디오 연결", "unsco":"SCO 오디오 해제", "transferAudio":"통화 오디오를 Mac으로 전환", "dial":"전화 발신", "answer":"수신 전화 응답", "end":"통화 종료"][rawValue]! }; var prompt: String { ["sdp":"선택한 기기에서 SDP 서비스 조회를 실행합니다. 이 조회는 Bluetooth baseband 링크를 새로 열 수 있습니다. HFP Audio Gateway(0x111F)가 확인되면 HFP 서비스 연결까지 이어집니다. 전화 발신·응답·종료는 하지 않습니다. 진행할까요?", "connect":"확인된 HFP 서비스를 연결합니다. 진행할까요?", "disconnect":"HFP 연결을 끊을까요?", "sco":"선택한 기기에 SCO 오디오 연결을 시작합니다. 진행할까요?", "unsco":"SCO 오디오를 해제할까요?", "transferAudio":"휴대전화에 통화 오디오를 Mac으로 전환하도록 요청합니다. 진행 중인 통화의 오디오 경로가 바뀔 수 있습니다. 전화를 걸거나 받거나 끊지는 않습니다. 진행할까요?", "dial":"입력한 번호로 실제 전화를 겁니다. 번호와 대상을 확인했습니까?", "answer":"수신 중인 실제 전화에 응답합니다. 진행할까요?", "end":"현재 실제 통화를 종료합니다. 진행할까요?"][rawValue]! } }
    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 14) {
            HStack { VStack(alignment: .leading) { Text("Galaxy Call Bridge").font(.largeTitle.bold()); Text("HFP 연결과 통화 오디오 진단 · 동작 전 확인 필수").foregroundStyle(.secondary) }; Spacer(); Button("기기 목록 새로고침") { store.refresh() } }
            GroupBox("페어링 기기 및 캐시된 HFP 서비스 · 읽기 전용") {
                VStack(alignment: .leading, spacing: 8) {
                    if store.devices.isEmpty { Text(store.error ?? "기기 목록 조회 전 · 버튼을 눌러 직접 조회하세요").foregroundStyle(.secondary) }
                    Text("Bluetooth 기기 조회는 자동 실행하지 않습니다. macOS 권한 창이 표시되면 승인하지 말고 먼저 내용을 확인하세요.").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.devices) { device in
                        PairedDeviceRow(device: device, selected: store.selectedID == device.id) {
                            store.selectedID = device.id
                        }
                    }
                    if let target = store.selected {
                        if target.cachedAG == true {
                            Button("확인된 HFP 서비스 연결…") { confirm = .connect }.disabled(store.hfpOn)
                        } else {
                            Button(target.sdpQueried ? "HFP 서비스 다시 조회…" : "HFP 서비스 조회 후 연결…") { confirm = .sdp }.disabled(store.hfpOn)
                        }
                    }
                    HStack { Button("HFP 해제…") { confirm = .disconnect }.disabled(!store.hfpOn) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("통화 오디오 · HFP/SCO와 실제 음성 경로 구분") { VStack(alignment: .leading, spacing: 8) { Text(store.hfp); Text(store.sco); HStack { Button("SCO 연결…") { confirm = .sco }.disabled(!store.hfpOn || store.scoOn); Button("SCO 해제…") { confirm = .unsco }.disabled(!store.scoOn); Button("통화 오디오를 Mac으로 전환…") { confirm = .transferAudio }.disabled(!store.hfpOn); Button("상태 새로고침") { store.poll() } }; Text(store.audioOutput.summary); Text(store.audioDeliveryLabel); HStack { Button("CoreAudio 출력 다시 읽기") { store.refreshAudioOutput() }; Button("진단 로그 내보내기…") { store.exportDiagnostics() } }; Text("CoreAudio 장치 식별은 출력 경로의 존재만 나타냅니다. 별도 PCM 실험 패널은 사용자가 명시적으로 시작해야 작동합니다. SCO/HFP API나 실험 코드 빌드는 실제 통화 음성 재생·마이크 입력 성공을 증명하지 않습니다.").font(.caption).foregroundStyle(.secondary); Text("\(store.diagnosticsStateLabel) · \(store.diagnosticsLocation) · 번호·통화 내용은 기록하지 않음").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            GroupBox("통화 제어") { VStack(alignment: .leading, spacing: 8) { Text(store.callNotice).font(.headline); Text("활성: \(store.callActive) · 설정: \(store.callSetup) · 보류: \(store.callHeld)").font(.caption); HStack { TextField("전화번호", text: $number).frame(maxWidth: 220); Button("발신") { store.dial(number) }.disabled(!store.hfpOn); Button("응답") { store.answer() }.disabled(!store.hfpOn); Button("종료") { store.endCall() }.disabled(!store.hfpOn) } }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            AudioExperimentPanel(controller: audioExperiment, ready: testReady)
            Button(testReady ? "통화 시험 준비 해제" : "통화 시험 준비 확인…") { if testReady { testReady=false; audioExperiment.stop(reason: "준비 해제") } else { readyPrompt=true } }
                .confirmationDialog("통화 시험 준비 확인", isPresented: $readyPrompt, titleVisibility: .visible) {
                    Button("준비됨 · 별도로 실제 통화를 시작한 경우에만") { testReady.toggle() }
                    Button("취소", role: .cancel) { }
                } message: { Text("이 확인은 실제 통화 발신/응답을 수행하지 않습니다. 대상 통화가 활성이고 실험 준비가 끝났을 때만 PCM 모드 시작 버튼을 사용할 수 있습니다. 마이크 권한 요청은 상향 모드 시작 시에만 표시됩니다.") }
            GroupBox("최근 이벤트") { VStack(alignment: .leading) { if store.events.isEmpty { Text("이벤트 없음") }; ForEach(Array(store.events.enumerated()), id: \.offset) { _, e in Text(e).font(.caption) } }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            Spacer(minLength: 8); Text("전화번호부·녹음 없음. 수신 번호/통화 상세를 보관하지 않습니다. SDK API 존재는 실기기 성공을 보증하지 않습니다.").font(.caption).foregroundStyle(.secondary)
        }.padding(22)
        }
        .scrollIndicators(.visible)
        .frame(minWidth: 840, minHeight: 520)
        .confirmationDialog(confirm?.title ?? "확인", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) { Button("진행", role: confirm == .end ? .destructive : nil) { runConfirmed() }; Button("취소", role: .cancel) { confirm = nil } } message: { Text(confirm?.prompt ?? "") }
        .alert("요청 실패", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("확인", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func runConfirmed() { guard let a = confirm else { return }; confirm = nil; switch a { case .sdp: store.queryHFPServiceThenConnect(); case .connect: store.connect(); case .disconnect: store.disconnect(); case .sco: store.connectSCO(); case .unsco: store.disconnectSCO(); case .transferAudio: store.transferAudioToComputer(); case .dial: store.dial(number); case .answer: store.answer(); case .end: store.endCall() } }
}
struct PairedDeviceRow: View {
    let device: DeviceRow
    let selected: Bool
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text("\(device.displayName) — \(ConnectionLabel.korean(connected: device.connected))")
                    .lineLimit(1)
                Spacer()
                Text(device.serviceLabel).font(.caption)
            }
        }.buttonStyle(.plain)
    }
}

struct ContentView: View {
    @ObservedObject var calls:PhoneCallController
    @ObservedObject var audio:AudioExperimentController
    @State private var diagnostics=false
    var body: some View {
        PhoneHomeView(calls:calls,audio:audio,showDiagnostics:{ diagnostics=true })
            .frame(minWidth:380,minHeight:660)
            .sheet(isPresented:$diagnostics) {
                VStack(spacing:0) {
                    HStack { Text("연결 설정 및 진단").font(.headline); Spacer(); Button("닫기") { diagnostics=false }.keyboardShortcut(.cancelAction) }.padding()
                    DiagnosticsView(audioExperiment:audio)
                }.frame(width:980,height:760)
            }

    }
}

@main struct GalaxyCallBridgeApp: App {
    @StateObject private var presence=CallPresence()
    init() { AppInstanceLifecycle.enforceLatestAndSingleInstance() }
    var body: some Scene {
        MenuBarExtra { ConnectionMenu(calls:presence.calls) } label: { ConnectionMenuLabel(calls:presence.calls) }
        phoneWindow
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }

    private var phoneWindow: some Scene {
        Window("Galaxy Call Bridge", id: "phone") {
            ContentView(calls: presence.calls, audio: presence.audio)
        }
        .defaultSize(width: 420, height: 740)
    }
}
