import AppKit
import SwiftUI
import Combine

/// App-owned monitoring survives closing the phone window.
@MainActor final class CallPresence: ObservableObject {
    let calls = PhoneCallController()
    let audio = AudioExperimentController()
    private var subscriptions=Set<AnyCancellable>()
    private var alert:NSPanel?
    private var attempts=0

    init() {
        calls.$state.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] phase in
            guard let self else { return }
            if phase == .ringing { self.showIncoming() } else { self.dismissIncoming() }
            if phase == .active { self.attempts=0; self.startAudio() }
            if phase == .idle || phase == .unknown {
                self.attempts=0
                if self.audio.running { self.audio.stop(reason:"Galaxy 통화 종료 또는 연결 해제") }
            }
        }.store(in:&subscriptions)
        calls.$connected.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] connected in
            if connected { self?.calls.loadRecentCalls() }
        }.store(in:&subscriptions)
        audio.$tunnelCheckRunning.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] checking in
            if !checking { self?.startAudio() }
        }.store(in:&subscriptions)
        audio.$running.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] running in
            guard let self, !running, self.calls.state == .active, self.attempts<3 else { return }
            DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { [weak self] in self?.startAudio() }
        }.store(in:&subscriptions)
        calls.onShizukuRecovery = { [weak self] detail in self?.audio.traceRecovery("control-helper; \(detail)") }
        audio.repairAndCheckTunnel()
    }
    private func startAudio() {
        guard calls.connected,calls.state == .active,!audio.running,!audio.tunnelCheckRunning,attempts<3 else { return }
        attempts += 1
        audio.start(.duplex,testReady:true)
    }
    private func showIncoming() {
        guard alert == nil, let screen=NSScreen.main ?? NSScreen.screens.first else { return }
        let frame=screen.visibleFrame
        let panel=NSPanel(contentRect:NSRect(x:frame.maxX-364,y:frame.maxY-212,width:348,height:196),
                          styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .floating
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=false
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        panel.contentView=NSHostingView(rootView:IncomingCallBanner(calls:calls))
        alert=panel
        panel.orderFrontRegardless() // Nonactivating: preserve keyboard focus in the user's app.
    }
    private func dismissIncoming() { alert?.orderOut(nil);alert=nil }
}

struct IncomingCallBanner: View {
    @ObservedObject var calls:PhoneCallController
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text("수신전화").font(.system(size:13,weight:.medium))
                .foregroundStyle(Color.black.opacity(0.65))
            Text(calls.incomingLabel ?? "Galaxy 수신전화").font(.system(size:25,weight:.bold))
                .foregroundStyle(Color.black.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength:12)
            HStack(alignment:.center) {
                action("받기",symbol:"phone.fill",color:Color(red:0.05,green:0.66,blue:0.37),enabled:calls.canAnswer) {
                    if calls.state == .ringing { calls.answer() }
                }
                Spacer()
                VStack(spacing:4) {
                    Text(calls.busy ? "연결 중…" : "외장 헤드폰")
                    Text("DGM20 마이크").foregroundStyle(.secondary)
                }.font(.system(size:11,weight:.medium)).foregroundStyle(Color.black.opacity(0.7))
                Spacer()
                action("거절",symbol:"phone.down.fill",color:Color(red:0.88,green:0.22,blue:0.19),enabled:calls.canEnd) {
                    if calls.state == .ringing { calls.end() }
                }
            }
        }
        .padding(22).frame(width:348,height:196)
        .background(LinearGradient(colors:[Color(red:1,green:0.98,blue:0.94),Color(red:0.97,green:0.96,blue:1),Color(red:0.94,green:0.99,blue:0.96)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:28))
        .overlay(RoundedRectangle(cornerRadius:28).strokeBorder(.white.opacity(0.7),lineWidth:1))
        .preferredColorScheme(.light)
    }
    private func action(_ title:String,symbol:String,color:Color,enabled:Bool,perform:@escaping ()->Void) -> some View {
        Button(action:perform) {
            Image(systemName:symbol).font(.system(size:24,weight:.semibold))
                .foregroundStyle(.white).frame(width:54,height:54)
                .background(color,in:Circle())
                .opacity(enabled && !calls.busy ? 1 : 0.45)
                .contentShape(Circle())
        }.buttonStyle(.plain)
         .disabled(calls.state != .ringing || !enabled || calls.busy)
         .accessibilityLabel(title).help(title)
    }
}

struct ConnectionMenuLabel: View {
    @ObservedObject var calls:PhoneCallController
    var body:some View {
        Label(calls.connected ? (calls.state == .ringing ? "수신 전화" : calls.state == .active ? "통화 중" : calls.state == .dialing ? "발신 중" : "Galaxy 연결됨") : "Galaxy 연결 중",
              systemImage:calls.connected ? "phone.connection.fill" : "iphone.radiowaves.left.and.right").labelStyle(.titleAndIcon)
    }
}
struct ConnectionMenu:View {
    @ObservedObject var calls:PhoneCallController
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        Text(calls.connected ? "Galaxy 연결됨" : "Galaxy 자동 연결 대기")
        if calls.state == .ringing {
            Button("전화 받기") { calls.answer() }.disabled(calls.busy || !calls.canAnswer)
            Button("거절") { calls.end() }.disabled(calls.busy || !calls.canEnd)
        }
        Divider()
        Button("전화 열기") { openWindow(id:"phone");NSApp.activate(ignoringOtherApps:true) }
        Button("연결 다시 확인") { calls.refresh() }
        Divider()
        Button("종료") { NSApp.terminate(nil) }
    }
}
