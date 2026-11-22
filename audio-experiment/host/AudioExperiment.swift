import AVFoundation
import Foundation
import Network
import SwiftUI
import Darwin
import AudioToolbox

@MainActor final class AudioExperimentController: ObservableObject {
    enum Mode: String, Equatable {
        case downlink = "휴대전화 음성 → Mac 스피커", uplink = "DGM20 마이크 → 휴대전화", duplex = "Mac에서 통화"
        var usesMicrophone: Bool { self == .uplink || self == .duplex }
        var usesPlayback: Bool { self == .downlink || self == .duplex }
        var gateMode: PCMExperimentGate.Mode { switch self { case .downlink: return .downlink; case .uplink: return .uplink; case .duplex: return .duplex } }
        var startKind: AudioWire.Kind { switch self { case .downlink: return .startDownlink; case .uplink: return .startUplink; case .duplex: return .startDuplex } }
    }
    @Published private(set) var state = "대기 · 오디오 장치 미접근"
    @Published private(set) var running = false
    @Published private(set) var tunnelState = "기존 터널 상태 미확인"
    @Published private(set) var tunnelCheckRunning = false
    @Published private(set) var tunnelMonitorEnabled = false
    private var tunnelMonitorTimer: DispatchSourceTimer?
    private var connection: NWConnection?
    private var activeSession = UUID()
    private var recoveryProcess: Process?
    private var microphoneEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capture: MicrophoneCaptureBuffer?
    private var inputDeviceID: AudioDeviceID?
    private var configurationObserver: NSObjectProtocol?
    private var playbackObserver: NSObjectProtocol?
    private var deviceMonitor: DispatchSourceTimer?
    @Published var microphoneGain: Double = 2
    @Published private(set) var inputDescription = "DGM20 · 시작 전 장치 확인"
    @Published private(set) var outputDescription = "출력 장치 확인 전"
    @Published private(set) var microphoneLevel = "입력 레벨 · 상향 시작 후 표시"
    private var transmittedPCMFrames=0, transmittedPCMBytes=0, micProcessedFrames=0, sendDrops=0
    @Published private(set) var microphoneFailure: String?
    private var microphoneRecoveries = 0
    private var micTapInstalled = false
    @Published private(set) var activeMode: Mode?
    @Published private(set) var microphoneMuted = false
    var audioReady: Bool {
        guard running, let mode, gate.androidStarted else { return false }
        return (!mode.usesMicrophone || microphoneEngine?.isRunning == true)
            && (!mode.usesPlayback || playbackEngine?.isRunning == true)
    }
    private var mode: Mode? { get { activeMode } set { activeMode = newValue } }
    private var deadline: DispatchWorkItem?
    private var receiveBuffer = Data()
    #if GCB_PROTOCOL_TEST
    private var diagnosticOnly = false
    #endif
    private var helloReceived = false
    @Published private(set) var serviceIdentity = "Android 실행 빌드 미확인"
    private var lastRX = "none", lastTX = "none"
    private var receivedPCMFrames = 0, receivedPCMBytes = 0
    #if GCB_PROTOCOL_TEST
    private let diagnosticURL: URL? = nil
    #else
    private let diagnosticURL = LocalDiagnosticJournal().fileURL
    #endif
    /// Trace a Shizuku recovery attempt reported by a tunnel helper run (no phone data involved).
    func traceRecovery(_ detail: String) { trace("shizukuRecovery", detail) }
    /// Last written tunnelCheck result; a steady failure or success is logged once, not every 15 s.
    private var lastTunnelCheckTrace = ""
    private func trace(_ event: String, _ detail: String) {
        guard let url=diagnosticURL else { return }
            let value: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event, "session": activeSession.uuidString, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "detail": detail]
        LocalDiagnosticJournal.rotateIfNeeded(url)
        guard let data=try? JSONSerialization.data(withJSONObject:value), let file=try? FileHandle(forWritingTo:url) else { return }
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf:data+Data([10])) } catch { }
    }
    private let io = DispatchQueue(label: "gcb.audio.io", qos: .userInitiated)
    private let lock = NSLock()
    private let playbackQueue = BoundedFrameQueue<Data>(capacity:5)
    private let sendQueue = BoundedFrameQueue<Data>(capacity:5)
    private var gate = PCMExperimentGate()
    private var scheduledPlaybackFrames = 0
    private var micFlush: DispatchSourceTimer?
    private var playbackTimer: DispatchSourceTimer?
    private var sendBusy = false
    private let port: NWEndpoint.Port = 38241
    // Matches the exact Wireless debugging IP:port the user verified on the phone.
    // A changed endpoint must be verified again; do not silently trust a new device/port.
    private let verifiedWirelessSerial = "--trusted-auto"
    private let monitorPreference = UserDefaults(suiteName: "local.gunhee.GalaxyCallBridge") ?? .standard

    init() {
        #if !GCB_PROTOCOL_TEST
        refreshAudioDevices()
        if monitorPreference.bool(forKey: "KeepLocalTunnel") {
            tunnelMonitorEnabled = true
            startTunnelMonitorTimer()
            DispatchQueue.main.async { [weak self] in self?.reconcileTunnel() }
        }
        #endif
    }

    func refreshAudioDevices() {
        guard !running else { return }
        inputDescription = (try? MicrophoneInput.resolveDGM20()).map { "\($0.name) · 선택됨, 미사용" } ?? "DGM20 · 연결 안 됨"
        outputDescription = MicrophoneInput.externalHeadphones().map { "\($0.name) · 선택됨, 미사용" } ?? "출력 장치 없음"
    }

    func repairAndCheckTunnel() {
        guard !running, recoveryProcess == nil, !tunnelCheckRunning else { return }
        tunnelMonitorEnabled = true
        monitorPreference.set(true, forKey: "KeepLocalTunnel")
        startTunnelMonitorTimer()
        reconcileTunnel()
    }

    func stopTunnelMonitor() {
        tunnelMonitorEnabled = false
        monitorPreference.set(false, forKey: "KeepLocalTunnel")
        tunnelMonitorTimer?.cancel(); tunnelMonitorTimer = nil
        tunnelState = "로컬 터널 자동 복구 중지 · 기존 연결은 유지"
    }

    private func startTunnelMonitorTimer() {
        guard tunnelMonitorTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: io)
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.tunnelMonitorEnabled, !self.running, !self.tunnelCheckRunning else { return }
                self.reconcileTunnel()
            }
        }
        tunnelMonitorTimer = timer; timer.resume()
    }

    private func reconcileTunnel() {
        guard !running, !tunnelCheckRunning, recoveryProcess == nil else { return }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("connect-local-tunnel.sh"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            tunnelState = "복구 도구를 찾지 못했습니다."
            return
        }
        tunnelCheckRunning = true
        tunnelState = "확인된 무선 연결을 점검·복구 중 · 오디오 미시작"
        let process = Process(); recoveryProcess = process
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, verifiedWirelessSerial, "38241", "--wireless-settings-screen-confirmed"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["ADB_SERVER_SOCKET"] = "tcp:127.0.0.1:5037"
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        process.environment = environment
        let out = Pipe(), err = Pipe(); process.standardOutput = out; process.standardError = err
        process.terminationHandler = { [weak self] p in
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self else { return }
                let recovery = stdout.contains("Shizuku recovery attempted (started=yes)") ? "started=yes" : stdout.contains("Shizuku recovery attempted") ? "started=no" : "none"
                let result = "exit=\(p.terminationStatus); created=\(stdout.contains("forward created")); listener=\(stdout.contains("listener @gcb_audio_v1 confirmed")); recovery=\(recovery)"
                // Record each recovery attempt itself; otherwise only state changes.
                if recovery != "none" || result != self.lastTunnelCheckTrace { self.trace("tunnelCheck", result) }
                self.lastTunnelCheckTrace = result
                self.recoveryProcess = nil
                guard p.terminationStatus == 0 else {
                    self.tunnelCheckRunning = false
                    self.tunnelState = "자동 복구 대기 · \((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))"
                    return
                }
                self.tunnelCheckRunning = false
                let detail = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                self.tunnelState = self.tunnelMonitorEnabled
                    ? "ADB 포워드 + Android abstract listener 확인 · 15초 자동 복구 유지 · 오디오 미시작"
                    : "ADB 포워드 + Android abstract listener 확인 · 오디오 미시작"
                if !detail.isEmpty { self.tunnelState += " · " + detail.replacingOccurrences(of: "\n", with: " ") }
            }
        }
        do { try process.run() } catch {
            recoveryProcess = nil; tunnelCheckRunning = false
            tunnelState = "ADB 복구 도구 실행 실패 · \(error.localizedDescription)"
        }
    }

    func start(_ requested: Mode, testReady: Bool) {
        guard !tunnelCheckRunning else { state = "터널 복구·연결 점검이 끝난 뒤 다시 시도하세요"; return }
        guard !running else { return }
        guard gate.begin(requested.gateMode,ready:testReady) else { state = "차단됨 · 먼저 사용자가 시험 준비를 확인해야 합니다"; return }
        mode = requested; running = true; microphoneMuted = false; helloReceived = false; receiveBuffer.removeAll(keepingCapacity: true)
        let session = UUID(); activeSession = session
        lastRX="none"; lastTX="none"; receivedPCMFrames=0; receivedPCMBytes=0
        transmittedPCMFrames=0; transmittedPCMBytes=0; micProcessedFrames=0; sendDrops=0
        microphoneLevel="입력 레벨 · 상향 시작 후 표시"
        trace("pcmStartRequested", String(describing: requested.gateMode))
        state = "Mac 127.0.0.1 로컬 터널 연결 중 · 오디오 열기 전"
        let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp); connection = c
        c.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                guard let self, self.running, self.activeSession == session, self.connection === c else { return }
                switch s {
                case .ready: self.state = "ADB 로컬 터널 연결됨 · Android 서비스 식별 응답 대기"
                case .failed(let e): self.stop(reason: "터널 오류: \(e.localizedDescription)")
                case .cancelled: self.stop(reason: "터널 연결 종료")
                default: break
                }
            }
        }
        c.start(queue: io); receiveNext(on: c, session: session)
        if requested == .uplink {
            let w = DispatchWorkItem { [weak self] in Task { @MainActor in guard let self, self.activeSession==session else { return }; self.stop(reason: "60초 안전 제한") } }; deadline = w
            DispatchQueue.main.asyncAfter(deadline: .now()+60, execute:w)
        }
    }

    func stop(reason: String = "사용자가 중지") {
        // NWConnection may report .failed and receive(error) concurrently. Preserve the first, useful cause.
        guard running || microphoneEngine != nil || playbackEngine != nil || connection != nil else { return }
        let ending = connection
        trace("pcmStop", "reason=\(reason); rx=\(lastRX); tx=\(lastTX); frames=\(receivedPCMFrames); bytes=\(receivedPCMBytes); txFrames=\(transmittedPCMFrames); txBytes=\(transmittedPCMBytes); sendDrops=\(sendDrops)")
        activeSession = UUID()
        // Send STOP directly before closing: the queued sender previously ran after connection=nil.
        if let c=ending {
            if let frame=try? AudioWire.encode(.stop) { c.send(content:frame,completion:.contentProcessed { _ in c.cancel() }) }
            else { c.cancel() }
            io.asyncAfter(deadline:.now()+1) { c.cancel() }
        }; connection=nil
        if let observer=configurationObserver { NotificationCenter.default.removeObserver(observer) }; configurationObserver=nil
        if let observer=playbackObserver { NotificationCenter.default.removeObserver(observer) }; playbackObserver=nil
        deviceMonitor?.cancel(); deviceMonitor=nil
        capture?.stop(); capture=nil; inputDeviceID=nil
        deadline?.cancel(); deadline=nil; micFlush?.cancel(); micFlush=nil; playbackTimer?.cancel(); playbackTimer=nil
        if let e=microphoneEngine { if micTapInstalled { e.inputNode.removeTap(onBus:0); micTapInstalled=false }; e.stop() }; microphoneEngine=nil
        player?.stop(); player=nil; playbackEngine?.stop(); playbackEngine=nil
        lock.lock(); playbackQueue.reset(); sendQueue.reset(); sendBusy=false; scheduledPlaybackFrames=0; lock.unlock(); gate.stop()
        microphoneFailure=nil; microphoneRecoveries=0
        running=false; microphoneMuted=false; let old=mode?.rawValue ?? "오디오"; mode=nil; state="중지 · \(old) · \(reason)"
        refreshAudioDevices()
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard running, mode?.usesMicrophone == true, gate.androidStarted else { return }
        microphoneMuted = muted
        if muted { sendQueue.reset() }
        trace("micMute", muted ? "on" : "off")
    }
    func toggleMicrophoneMute() { setMicrophoneMuted(!microphoneMuted) }

    private func requestAndroidStart() {
        guard let mode, running, helloReceived else { return }
        guard mode.usesMicrophone else { send(kind:mode.startKind); return }
        let session = activeSession
        state = "DGM20 마이크 권한 확인 중 · 음성 시작 전"
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self, self.running, self.activeSession == session else { return }
                guard allowed else { self.stop(reason:"마이크 권한 거부"); return }
                self.gate.authorizeMicrophone(true)
                self.send(kind:mode.startKind)
            }
        }
    }
    private func startAudioIfConfirmed() {
        guard let mode, running, gate.androidStarted else { return }
        // Both endpoints belong to this explicit session; any failure tears both down.
        if mode.usesMicrophone, !gate.canOpenMicrophone { stop(reason:"마이크 권한 확인 전 시작 차단"); return }
        #if !GCB_PROTOCOL_TEST
        if mode.usesPlayback { configurePlayback() }
        if running, mode.usesMicrophone { configureMic() }
        #endif
    }
    private func configureMic() {
        guard running, gate.canOpenMicrophone, microphoneEngine == nil else { return }
        do {
            let device=try MicrophoneInput.resolveDGM20()
            let e=AVAudioEngine(), input=e.inputNode
            guard let unit=input.audioUnit else { stop(reason:"DGM20 오디오 장치 연결 실패"); return }
            try MicrophoneInput.bind(device,to:unit)
            let format=input.outputFormat(forBus:0)
            guard let capture=MicrophoneCaptureBuffer(inputFormat:format) else { stop(reason:"DGM20 입력 포맷 구성 실패"); return }
            microphoneEngine=e; self.capture=capture; inputDeviceID=device.id
            input.installTap(onBus:0,bufferSize:1024,format:format) { buffer,_ in capture.append(buffer) }; micTapInstalled=true
            try e.start()
            guard MicrophoneInput.currentDevice(unit)==device.id else { throw MicrophoneInput.InputError.changed }
            gate.markMicOpened()
            inputDescription="\(device.name) · 사용 중 (입력 1채널)"
            trace("micInput","id=\(device.id); sampleRate=\(format.sampleRate); channels=\(format.channelCount); channel=1; gain=\(microphoneGain)")
            state = mode == .duplex ? "Mac에서 통화 중 · DGM20 마이크 + 스피커" : "상향 모드 실행 · DGM20 → 상대방"
            let session=activeSession
            configurationObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:e,queue:nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.activeSession==session, self.microphoneEngine===e else { return }
                    self.recoverMicrophone(e, device:device, source:"configuration")
                }
            }
            let monitor=DispatchSource.makeTimerSource(queue:io)
            monitor.schedule(deadline:.now()+0.25,repeating:.milliseconds(250))
            monitor.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, self.activeSession==session, self.running else { return }
                    guard MicrophoneInput.isAlive(device.id), MicrophoneInput.currentDevice(unit)==device.id else {
                        self.failMicrophone("DGM20 장치 확인 실패", source:"device-monitor"); return
                    }
                }
            }
            deviceMonitor=monitor; monitor.resume(); startMicSender()
        } catch { failMicrophone("DGM20 시작 실패 · \(error.localizedDescription)", source:"start") }
    }
    private func failMicrophone(_ reason: String, source: String) {
        trace("micFailure", "source=\(source); expected=\(inputDeviceID ?? 0); actual=\(microphoneEngine?.inputNode.audioUnit.flatMap { MicrophoneInput.currentDevice($0) } ?? 0)")
        guard mode == .duplex, gate.androidStarted else { stop(reason:reason); return }
        if let observer=configurationObserver { NotificationCenter.default.removeObserver(observer) }; configurationObserver=nil
        deviceMonitor?.cancel(); deviceMonitor=nil; micFlush?.cancel(); micFlush=nil
        capture?.stop(); capture=nil
        if let e=microphoneEngine {
            if micTapInstalled { e.inputNode.removeTap(onBus:0); micTapInstalled=false }
            e.stop()
        }
        microphoneEngine=nil
        microphoneFailure=reason
        inputDescription="DGM20 · 전달 중단"
        microphoneLevel="내 목소리 전달 안 됨"
        state="상대방 음성 수신 유지 · DGM20 마이크 확인 필요"
    }
    private func recoverMicrophone(_ engine: AVAudioEngine, device: MicrophoneInput.Device, source: String) {
        guard let unit=engine.inputNode.audioUnit else { failMicrophone("DGM20 입력 장치 없음",source:source); return }
        let actual=MicrophoneInput.currentDevice(unit)
        trace("micConfiguration", "source=\(source); expected=\(device.id); actual=\(actual ?? 0); alive=\(MicrophoneInput.isAlive(device.id)); running=\(engine.isRunning); recoveries=\(microphoneRecoveries)")
        guard MicrophoneInput.isAlive(device.id), actual == device.id else {
            failMicrophone("DGM20 연결이 변경됐습니다",source:source); return
        }
        // A delayed startup notification alone is not evidence of device removal.
        if engine.isRunning { return }
        guard microphoneRecoveries < 2 else { failMicrophone("DGM20 입력 재연결 실패",source:source); return }
        microphoneRecoveries += 1
        if micTapInstalled { engine.inputNode.removeTap(onBus:0); micTapInstalled=false }
        capture?.stop()
        let format=engine.inputNode.outputFormat(forBus:0)
        guard let buffer=MicrophoneCaptureBuffer(inputFormat:format) else { failMicrophone("DGM20 입력 형식 오류",source:source); return }
        capture=buffer
        engine.inputNode.installTap(onBus:0,bufferSize:1024,format:format) { pcm,_ in buffer.append(pcm) }; micTapInstalled=true
        do {
            try engine.start()
            guard MicrophoneInput.currentDevice(unit)==device.id else { throw MicrophoneInput.InputError.changed }
            trace("micRecovered", "attempt=\(microphoneRecoveries); rate=\(format.sampleRate); channels=\(format.channelCount)")
        } catch { failMicrophone("DGM20 입력 재시작 실패",source:source) }
    }
    private func startMicSender() {
        let session=activeSession
        let timer=DispatchSource.makeTimerSource(queue:io)
        timer.schedule(deadline:.now(),repeating:.milliseconds(20))
        timer.setEventHandler { [weak self] in Task { @MainActor in
            guard let self, self.running, self.activeSession==session, let capture=self.capture else { return }
            let diagnostics=capture.diagnostics()
            guard diagnostics.errors==0 else { self.stop(reason:"마이크 포맷 변환 오류"); return }
            guard let frame=capture.pop() else { return }
            do {
                let result=try MicrophoneGain.process(frame,gain:self.microphoneGain)
                self.micProcessedFrames += 1
                if self.micProcessedFrames % 10 == 1 {
                    self.microphoneLevel=self.microphoneMuted ? "마이크 음소거 · 전송 무음" : String(format:"입력 %.0f dB · 전송 %.0f dB · %.1f배%@",result.inputDBFS,result.outputDBFS,result.effectiveGain,result.limitedSampleCount>0 ? " · 큰 소리 제한 중" : "")
                }
                if self.micProcessedFrames % 50 == 1 {
                    self.trace("micLevel",String(format:"inputDBFS=%.0f; outputDBFS=%.0f; gain=%.1f; peak=%.3f; limited=%d; dropped=%d; muted=%d",result.inputDBFS,self.microphoneMuted ? MicrophoneGain.silenceDBFS : result.outputDBFS,result.effectiveGain,self.microphoneMuted ? 0 : result.outputPeak,self.microphoneMuted ? 0 : result.limitedSampleCount,diagnostics.dropped,self.microphoneMuted ? 1 : 0))
                }
                self.send(kind:.uplinkPCM,payload:MicrophoneTransmission.payload(result.pcm,muted:self.microphoneMuted))
            } catch { self.stop(reason:"마이크 PCM 처리 오류") }
        } }
        micFlush=timer; timer.resume()
    }
    private func configurePlayback() {
        guard running, gate.androidStarted, mode?.usesPlayback == true, playbackEngine == nil else { return }
        guard let fmt=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1) else { stop(reason:"출력 포맷 구성 실패"); return }
        let e=AVAudioEngine(), p=AVAudioPlayerNode()
        playbackEngine=e; player=p
        do {
            guard let device=MicrophoneInput.externalHeadphones(), let unit=e.outputNode.audioUnit else {
                stop(reason:"외장 헤드폰를 찾지 못했습니다"); return
            }
            try MicrophoneInput.bind(device,to:unit)
            e.attach(p); e.connect(p,to:e.mainMixerNode,format:fmt)
            try e.start()
            guard MicrophoneInput.currentDevice(unit)==device.id else { stop(reason:"스피커 지정 실패"); return }
            trace("speakerOutput","id=\(device.id); externalHeadphones=true")
            p.play()
            if let unit=e.outputNode.audioUnit, let id=MicrophoneInput.currentDevice(unit), let name=MicrophoneInput.name(id) { outputDescription="\(name) · 재생 중" }
            state="하향 모드 실행 · 재생 큐 최대 5프레임"
            let session=activeSession
            playbackObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:e,queue:nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.activeSession==session, self.playbackEngine===e else { return }
                    self.stop(reason:"스피커 연결 또는 설정이 바뀌었습니다. 다시 시작하세요.")
                }
            }
            let t=DispatchSource.makeTimerSource(queue:io)
            t.schedule(deadline:.now(),repeating:.milliseconds(20))
            t.setEventHandler { [weak self] in Task { @MainActor in
                guard let self, self.running, self.activeSession==session else { return }
                self.playOne()
            } }
            playbackTimer=t; t.resume()
        } catch { stop(reason:"출력 엔진 시작 실패: \(error.localizedDescription)") }
    }
    private func playOne() {
        lock.lock(); guard scheduledPlaybackFrames<5, let d=playbackQueue.pop() else { lock.unlock(); return }; scheduledPlaybackFrames += 1; lock.unlock()
        guard let p=player, let f=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1), let b=AVAudioPCMBuffer(pcmFormat:f,frameCapacity:320), let ch=b.floatChannelData?[0] else { lock.lock(); scheduledPlaybackFrames=max(0,scheduledPlaybackFrames-1); lock.unlock(); return }
        let count=min(320,d.count/2); d.withUnsafeBytes { raw in let s=raw.bindMemory(to:Int16.self); for i in 0..<count { ch[i]=Float(Int16(littleEndian:s[i]))/32768.0 } }; b.frameLength=AVAudioFrameCount(count)
        let session=activeSession
        p.scheduleBuffer(b,completionCallbackType:.dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeSession == session else { return }
                self.scheduledPlaybackFrames=max(0,self.scheduledPlaybackFrames-1)
            }
        }
    }
    private func receiveNext(on c: NWConnection, session: UUID) {
        c.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data,_,done,error in
            Task { @MainActor in
                guard let self, self.running, self.activeSession == session, self.connection === c else { return }
                if let data { self.consume(data) }
                if done || error != nil { self.stop(reason:"터널 읽기 종료 · \(error == nil ? "상대 소켓 EOF" : "네트워크 오류") · 마지막 수신 \(self.lastRX) · PCM \(self.receivedPCMFrames)프레임/\(self.receivedPCMBytes)바이트") }
                else if self.running { self.receiveNext(on: c, session: session) }
            }
        }
    }
    private func consume(_ data:Data) {
        receiveBuffer.append(data)
        while receiveBuffer.count>=8 {
            let b=[UInt8](receiveBuffer.prefix(8)); let magic=UInt32(b[0])<<24|UInt32(b[1])<<16|UInt32(b[2])<<8|UInt32(b[3]); let kind=UInt16(b[4])<<8|UInt16(b[5]); let n=Int(UInt16(b[6])<<8|UInt16(b[7]))
            guard magic==AudioWire.magic,n<=640 else { stop(reason:"잘못된 프레임"); return }; guard receiveBuffer.count>=8+n else{return}
            let payload=receiveBuffer.subdata(in:8..<8+n); receiveBuffer.removeSubrange(0..<8+n)
            if kind != AudioWire.Kind.downlinkPCM.rawValue {
                lastRX="kind=\(kind)"
                trace("pcmRX", "kind=\(kind); bytes=\(n)")
            }
            if kind==AudioWire.Kind.hello.rawValue {
                guard !helloReceived, let identity=AudioWire.serviceIdentity(payload) else { stop(reason:"Android 서비스 구버전 또는 식별 실패 · 서비스 업데이트 필요"); return }
                helloReceived=true; serviceIdentity=identity; lastRX="HELLO \(identity)"; trace("pcmHELLO",identity)
                state="Shizuku PCM 서비스 확인 · 명시적 모드 시작"
                #if GCB_PROTOCOL_TEST
                if diagnosticOnly { send(kind:.diagnosticError) }
                else { stop(reason:"test-only-start-blocked") }
                #else
                requestAndroidStart()
                #endif
            }
            else if kind==AudioWire.Kind.status.rawValue {
                let s=String(data:payload,encoding:.utf8) ?? "상태 응답"; state=s
                lastRX=s; trace("pcmStatus",s)
                if s=="STARTED" { guard helloReceived, !gate.androidStarted else { stop(reason:"잘못된 STARTED 순서"); return }; gate.acknowledgeStarted(); startAudioIfConfirmed() } else if s.hasPrefix("BLOCKED") || s.hasPrefix("STOPPED") || s.hasPrefix("ERROR:") { stop(reason:s) }
            } else if kind==AudioWire.Kind.downlinkPCM.rawValue {
                guard mode?.usesPlayback == true, gate.androidStarted, !payload.isEmpty, payload.count % 2 == 0 else { stop(reason:"잘못된 PCM 순서/길이"); return }
                receivedPCMFrames += 1; receivedPCMBytes += payload.count
                if receivedPCMFrames == 1 { trace("pcmFirstFrame", "bytes=\(payload.count)") }
                lock.lock(); _ = playbackQueue.push(payload); lock.unlock()
            }
            if !running { return }
        }
    }
    #if GCB_PROTOCOL_TEST
    func checkLiveErrorDelivery() async -> String {
        diagnosticOnly=true; running=true; mode = .downlink; helloReceived=false; receiveBuffer.removeAll()
        let session=UUID(); activeSession=session
        let c=NWConnection(host:"127.0.0.1",port:port,using:.tcp); connection=c
        c.start(queue:io); receiveNext(on:c,session:session)
        for _ in 0..<100 { if !running { break }; try? await Task.sleep(nanoseconds:100_000_000) }
        if running { stop(reason:"diagnostic-timeout") }
        return state
    }
    func checkSyntheticSession(_ chunks: [Data], mode requested: Mode, microphoneAllowed: Bool, microphoneFails: Bool = false) -> (state: String, running: Bool, frames: Int) {
        gate.stop(); _ = gate.begin(requested.gateMode,ready:true)
        gate.authorizeMicrophone(microphoneAllowed)
        running=true; mode=requested; helloReceived=true; receiveBuffer.removeAll(); receivedPCMFrames=0; receivedPCMBytes=0
        for (index,chunk) in chunks.enumerated() {
            if running { consume(chunk) }
            if index == 0 && microphoneFails { failMicrophone("synthetic mic failure",source:"test") }
        }
        let result=(state:state,running:running,frames:receivedPCMFrames)
        stop(reason:"synthetic-finished")
        return result
    }
    func checkErrorDelivery(_ chunks: [Data]) -> String {
        running=true; mode = .downlink; helloReceived=false; receiveBuffer.removeAll()
        for chunk in chunks { if running { consume(chunk) } }
        stop(reason:"터널 읽기 종료")
        return state
    }
    #endif
    private func send(kind:AudioWire.Kind,payload:Data=Data()) { sendThreadSafe(kind:kind,payload:payload) }
    private func sendThreadSafe(kind:AudioWire.Kind,payload:Data=Data()) {
        guard let frame=try? AudioWire.encode(kind,payload) else{return}
        guard sendQueue.push(frame) else { if kind == .uplinkPCM { sendDrops += 1 }; return }
        Task { @MainActor in self.drainSendQueue() }
    }
    private func drainSendQueue() {
        guard !sendBusy, let frame=sendQueue.pop(), let c=connection else{return}; sendBusy=true
        let session=activeSession
        let isUplink=(try? AudioWire.decode(frame).0) == .uplinkPCM
        if let decoded=try? AudioWire.decode(frame), decoded.0 != .uplinkPCM {
            lastTX="kind=\(decoded.0.rawValue)"; trace("pcmTX",lastTX)
        }
        c.send(content:frame,completion:.contentProcessed { [weak self] e in
            Task { @MainActor in
                guard let self, self.activeSession == session, self.connection === c else{return}; self.sendBusy=false
                if let e { self.stop(reason:"터널 쓰기 오류: \(e.localizedDescription)") } else {
                    if isUplink { self.transmittedPCMFrames += 1; self.transmittedPCMBytes += frame.count-AudioWire.headerSize }
                    self.drainSendQueue()
                }
            }
        })
    }
}
struct AudioExperimentPanel: View {
    @ObservedObject var controller: AudioExperimentController
    let ready: Bool
    var body: some View {
        GroupBox("PCM 실험 · 실제 통화 준비 후에만 시작") {
            VStack(alignment:.leading,spacing:8) {
                Text(controller.state).font(.headline)
                VStack(alignment:.leading,spacing:4) {
                    Text("스피커: " + controller.outputDescription)
                    HStack {
                        Text("마이크: " + controller.inputDescription)
                        Button("장치 다시 확인") { controller.refreshAudioDevices() }.disabled(controller.running)
                    }
                    HStack {
                        Text("상대방에게 보내는 음량")
                        Slider(value:$controller.microphoneGain,in:1...6,step:0.5).frame(maxWidth:220).accessibilityLabel("마이크 송신 증폭")
                        Text(String(format:"%.1f배",controller.microphoneGain)).monospacedDigit()
                        Text(controller.microphoneLevel).foregroundStyle(.secondary)
                    }
                }.font(.caption)
                Text(controller.serviceIdentity).font(.caption).textSelection(.enabled)
                Text("기존 ADB 로컬 터널만 사용합니다. 개별 진단 또는 Mac에서 양방향 통화를 선택할 수 있습니다. HFP/SCO 연결은 필수 조건이 아닙니다. Android 서비스가 통화 모드와 권한을 검사해 PCM 시작 및 통화 종료를 판정합니다.").font(.caption)
                HStack {
                    Button("휴대전화 음성 → Mac 스피커 시작") { controller.start(.downlink,testReady:ready) }.disabled(controller.running || controller.tunnelCheckRunning || !ready)
                    Button("DGM20 마이크 → 휴대전화 시작") { controller.start(.uplink,testReady:ready) }.disabled(controller.running || controller.tunnelCheckRunning || !ready)
                    Button("Mac에서 통화") { controller.start(.duplex,testReady:ready) }.disabled(controller.running || controller.tunnelCheckRunning || !ready)
                    Button("즉시 중지") { controller.stop() }.disabled(!controller.running)
                    Button(controller.tunnelMonitorEnabled ? "터널 자동 복구 중지" : "터널 복구·자동 유지 시작") {
                        if controller.tunnelMonitorEnabled { controller.stopTunnelMonitor() }
                        else { controller.repairAndCheckTunnel() }
                    }.disabled(controller.running || controller.tunnelCheckRunning)
                }
                Text(controller.tunnelState + " · 통화 오디오/마이크는 시작하지 않습니다.").font(.caption)
                Text(ready
                     ? "준비 확인됨 · Android 서비스가 시작 요청 때 통화 모드와 권한을 다시 검사합니다."
                     : "시작 차단 · 앱을 다시 열면 준비 확인이 해제됩니다. 실제 Android 통화 연결 후 아래 ‘통화 시험 준비 확인…’을 눌러야 시작 버튼이 활성화됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
        }
    }
}
