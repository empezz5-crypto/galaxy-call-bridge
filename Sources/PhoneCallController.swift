import Foundation
import SwiftUI
import AppKit
import Network

@MainActor final class PhoneCallController:ObservableObject {
    @Published var state:CallPhase = .unknown
    @Published var connected=false
    @Published var busy=false
    @Published var notice="Galaxy 연결 확인 중"
    @Published var number=""
    @Published private(set) var outgoingNumber:String?
    /// Contact name, else number, of the ringing call; nil when unknown or not ringing.
    @Published private(set) var incomingLabel:String?
    @Published var canDial=false
    @Published var canAnswer=false
    @Published var canEnd=false
    @Published private(set) var callHistory:[PhoneCallHistoryItem]=[]
    @Published private(set) var historyMessage=""
    @Published private(set) var historyLoading=false
    @Published var ringEnabled=true { didSet { if !ringEnabled { ringingSound?.stop() } } }
    private var polling:Timer?
    private var ringingSound:NSSound?
    private var lastRing=Date.distantPast
    private var inflight=false
    private var helper:Process?
    private var helperLastRun=Date.distantPast
    /// Called with "started=yes|no" when the tunnel helper reported a Shizuku recovery attempt.
    var onShizukuRecovery:((String)->Void)?
    private let io=DispatchQueue(label:"gcb.phone.control")
    private var connection:NWConnection?
    private var timeout:DispatchWorkItem?
    private var pendingID:UUID?
    private var pendingAction:String?
    private var outgoingDeadline:Date?
    private var completion:((Result<PhoneControlReply,Error>)->Void)?
    private var incoming=Data()
    private let historyStore=CallHistoryStore()
    private let serial="--trusted-auto"
    private let port:NWEndpoint.Port
    private enum ControlError:Error { case unavailable, invalid, timeout }

    init(startMonitoring:Bool=true, port:UInt16=38242) {
        self.port=NWEndpoint.Port(rawValue:port)!
        callHistory=historyStore.load()
        guard startMonitoring else { return }
        polling=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        guard !inflight, !busy else { return }
        if !connected && Date().timeIntervalSince(helperLastRun)>10 { repairTunnel(); return }
        request(action:"status") { [weak self] result in self?.applyStatus(result) }
    }
    func loadRecentCalls() {
        guard connected,!historyLoading,!busy,!inflight else { historyMessage=connected ? historyMessage : "Galaxy 연결을 확인 중입니다."; return }
        historyLoading=true;historyMessage="최근 통화목록을 불러오는 중"
        request(action:"recentCalls") { [weak self] result in
            guard let self else { return };self.historyLoading=false
            switch result {
            case .failure:self.historyMessage="통화목록을 가져오지 못했습니다. Galaxy 연결을 확인하세요."
            case .success(let reply):
                guard reply.ok,reply.build=="20261031-059-r1",let rows=reply.calls else {
                    self.historyMessage=reply.error=="CALL_LOG_PERMISSION_DENIED" ? "Galaxy/Shizuku 권한이 통화목록 읽기를 허용하지 않습니다." : "통화목록을 읽지 못했습니다."
                    return
                }
                var merged=Dictionary(uniqueKeysWithValues:self.callHistory.map{($0.id,$0)})
                rows.forEach{merged[$0.id]=$0}
                self.callHistory=Array(merged.values).sorted{$0.date>$1.date}.prefix(200).map{$0}
                self.historyMessage=self.historyStore.save(self.callHistory)
                    ? "최근 통화 \(rows.count)건 · 이 Mac에 저장"
                    : "최근 통화는 가져왔지만 Mac 저장 권한을 확인하지 못했습니다."
            }
        }
    }
    func clearCallHistory() {
        if historyStore.clear() { callHistory=[];historyMessage="이 Mac에 저장된 통화목록을 삭제했습니다." }
        else { historyMessage="Mac에 저장된 통화목록을 삭제하지 못했습니다." }
    }
    private func repairTunnel() {
        guard helper==nil else { return }
        guard let path=Bundle.main.resourceURL?.appendingPathComponent("connect-local-tunnel.sh") else { return }
        helperLastRun=Date(); let process=Process(); helper=process
        process.executableURL=URL(fileURLWithPath:"/bin/sh")
        process.arguments=[path.path,serial,"38242","--wireless-settings-screen-confirmed","","gcb_control_v1"]
        var env=ProcessInfo.processInfo.environment
        env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";env["ADB_SERVER_SOCKET"]="tcp:127.0.0.1:5037"
        env.removeValue(forKey:"ANDROID_ADB_SERVER_PORT");process.environment=env
        let out=Pipe();process.standardOutput=out;process.standardError=FileHandle.nullDevice
        process.terminationHandler={ [weak self] p in
            let stdout=String(data:out.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
            Task { @MainActor in
            guard let self else {return}; self.helper=nil
            if stdout.contains("Shizuku recovery attempted") { self.onShizukuRecovery?(stdout.contains("(started=yes)") ? "started=yes" : "started=no") }
            guard p.terminationStatus==0 else { self.setDisconnected(); return }
            self.request(action:"status") { [weak self] result in self?.applyStatus(result) }
        } }
        do { try process.run() } catch { helper=nil;setDisconnected() }
    }
    func dial() {
        guard connected,!busy,state == .idle,canDial else { notice="Galaxy 연결과 통화 상태를 확인하세요";return }
        guard let n=PhoneNumberRules.normalize(number) else { notice="일반 전화번호를 입력하세요. 특수 서비스 번호는 Galaxy에서 이용하세요.";return }
        perform("dial",number:n)
    }
    func answer() { guard connected,!busy,state == .ringing,canAnswer else {return};perform("answer") }
    func end() { guard connected,!busy,(state == .ringing || state == .active),canEnd else {return};perform("end") }
    private func perform(_ action:String,number:String?=nil) {
        if inflight {
            guard pendingAction=="status" || pendingAction=="recentCalls" else { return }
            historyLoading=false
            // An explicit click takes priority over polling; never replay a call command.
            clearRequest()
        }
        busy=true
        if action == "dial" {
            outgoingNumber=number
            outgoingDeadline=Date().addingTimeInterval(30)
            state = .dialing
            notice="전화 거는 중"
        }
        request(action:action,number:number) { [weak self] result in
            guard let self else {return};self.busy=false
            switch result {
            case .failure: self.setDisconnected();self.notice="요청 결과를 확인하지 못했습니다. Galaxy 화면을 확인하세요."
            case .success(let reply):
                guard reply.build=="20261031-059-r1" else { self.setDisconnected();return }
                guard reply.ok else {
                    if action == "dial" {
                        self.outgoingDeadline=nil; self.outgoingNumber=nil
                        self.state = reply.state ?? .idle
                    }
                    self.notice=self.message(for:reply.error); return
                }
                self.applyStatus(.success(reply))
                if action=="dial" {
                    self.outgoingNumber=number
                    if self.state == .idle || self.state == .dialing {
                        self.outgoingDeadline=Date().addingTimeInterval(30)
                        self.state = .dialing
                    }
                    self.notice="발신 중 · Galaxy에서 연결 신호를 기다립니다"
                } else {
                    self.notice=action=="answer" ? "응답 요청됨 · 연결 확인 중" : "통화 종료 요청됨"
                }
                if action != "dial" { self.ringingSound?.stop() }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.refresh() }
            }
        }
    }
    private func message(for code:String?) -> String {
        switch code {
        case "EMERGENCY_NUMBER", "EMERGENCY_NUMBER_BLOCKED":return "긴급전화는 Galaxy에서 직접 걸어주세요."
        case "INVALID_NUMBER":return "전화번호를 확인하세요. 특수 서비스 번호는 지원하지 않습니다."
        case "EMERGENCY_CHECK_UNAVAILABLE":return "긴급전화 안전 확인에 실패해 발신을 막았습니다. Galaxy 상태를 확인하세요."
        case "SHORT_CODE_BLOCKED":return "긴급·서비스 단축번호는 Galaxy에서 직접 걸어주세요."
        case "NOT_IDLE","INVALID_STATE","NOT_RINGING","CALL_NOT_IDLE","CALL_NOT_RINGING","NO_CALL","COMMAND_PENDING","ACTION_PENDING":return "통화 상태가 바뀌었습니다. 잠시 후 확인하세요."
        case "PERMISSION_DENIED","UNSUPPORTED","DIAL_UNAVAILABLE","ANSWER_UNAVAILABLE","END_UNAVAILABLE":return "Galaxy 통화 제어 권한을 확인하지 못했습니다. 진단에서 확인하세요."
        default:return "Galaxy가 요청을 처리하지 못했습니다. 휴대전화 화면을 확인하세요."
        }
    }
    private func applyStatus(_ result:Result<PhoneControlReply,Error>) {
        switch result {
        case .failure:setDisconnected()
        case .success(let reply):
            guard reply.ok,reply.build=="20261031-059-r1",let phase=reply.state else {setDisconnected();return}
            let old=state;connected=true
            if phase == .active || phase == .ringing {
                state=phase
                outgoingDeadline=nil
                if phase == .ringing { outgoingNumber=nil }
            } else if phase == .idle, let deadline=outgoingDeadline, deadline>Date() {
                state = .dialing
            } else {
                state=phase
                if phase == .idle || phase == .unknown {
                    outgoingDeadline=nil
                    outgoingNumber=nil
                }
            }
            if old == .active && phase == .idle {
                DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in self?.loadRecentCalls() }
            }
            incomingLabel = phase == .ringing ? CallerDisplay.label(name:reply.incomingName,number:reply.incomingNumber) : nil
            canDial=reply.canDial ?? false;canAnswer=reply.canAnswer ?? false;canEnd=reply.canEnd ?? false
            if old != state || notice=="Galaxy 연결 확인 중" || notice=="Galaxy 연결이 끊겼습니다" {
                notice=state == .idle ? "Galaxy S25 연결됨" : state == .dialing ? "발신 중 · 연결 신호 대기" : state == .ringing ? "Galaxy에 걸려온 전화입니다" : state == .active ? "Galaxy 통화 중" : "상태를 확인하지 못했습니다"
            }
            if phase == .ringing {
                NSApplication.shared.dockTile.badgeLabel="전화"
                if ringEnabled && Date().timeIntervalSince(lastRing)>=3 {
                    lastRing=Date();ringingSound=NSSound(named:"Glass");ringingSound?.play()
                }
            } else { ringingSound?.stop();NSApplication.shared.dockTile.badgeLabel=nil }
        }
    }
    private func setDisconnected() {
        connected=false;state = .unknown;canDial=false;canAnswer=false;canEnd=false
        outgoingDeadline=nil;outgoingNumber=nil;incomingLabel=nil
        notice="Galaxy 연결이 끊겼습니다";ringingSound?.stop();NSApplication.shared.dockTile.badgeLabel=nil
    }
    private func request(action:String,number:String?=nil,completion:@escaping(Result<PhoneControlReply,Error>)->Void) {
        guard !inflight else { completion(.failure(ControlError.unavailable));return }
        var object=["action":action];if let number {object["number"]=number}
        guard let payload=try? JSONSerialization.data(withJSONObject:object),payload.count<1024 else {completion(.failure(ControlError.invalid));return}
        inflight=true;incoming.removeAll();self.completion=completion
        let id=UUID();pendingID=id;pendingAction=action
        let c=NWConnection(host:"127.0.0.1",port:port,using:.tcp);connection=c
        c.stateUpdateHandler={ [weak self] state in Task { @MainActor in
            guard let self,self.pendingID==id else {return}
            switch state {
            case .ready:
                c.send(content:payload+Data([10]),completion:.contentProcessed { error in
                    guard error != nil else {return};Task { @MainActor in self.finish(id,.failure(ControlError.unavailable)) }
                });self.receive(c,id)
            case .failed: self.finish(id,.failure(ControlError.unavailable))
            default:break
            }
        } }
        let timeout=DispatchWorkItem { [weak self] in Task { @MainActor in self?.finish(id,.failure(ControlError.timeout)) } };self.timeout=timeout
        DispatchQueue.main.asyncAfter(deadline:.now()+(action=="recentCalls" ? 8 : 3),execute:timeout);c.start(queue:io)
    }
    private func receive(_ c:NWConnection,_ id:UUID) {
        c.receive(minimumIncompleteLength:1,maximumLength:2048) { [weak self] data,_,done,error in Task { @MainActor in
            guard let self,self.pendingID==id else {return}
            if let data {self.incoming.append(data)}
            guard self.incoming.count<=32768 else {self.finish(id,.failure(ControlError.invalid));return}
            if let end=self.incoming.firstIndex(of:10) {
                let line=Data(self.incoming[..<end])
                guard let reply=try? JSONDecoder().decode(PhoneControlReply.self,from:line) else {self.finish(id,.failure(ControlError.invalid));return}
                self.finish(id,.success(reply))
            } else if done || error != nil {self.finish(id,.failure(ControlError.unavailable))}
            else {self.receive(c,id)}
        } }
    }
    private func finish(_ id:UUID,_ result:Result<PhoneControlReply,Error>) {
        guard pendingID==id else {return}
        let callback=completion;clearRequest()
        callback?(result)
    }
    private func clearRequest() {
        completion=nil;pendingID=nil;pendingAction=nil;inflight=false
        timeout?.cancel();timeout=nil;connection?.cancel();connection=nil;incoming.removeAll()
    }
}
