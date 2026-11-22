import SwiftUI

/// The everyday phone surface. Device and protocol diagnostics live in a separate sheet.
struct PhoneHomeView: View {
    @ObservedObject var calls: PhoneCallController
    @ObservedObject var audio: AudioExperimentController
    let showDiagnostics: () -> Void

    @State private var answerDrag: CGFloat = 0
    @State private var showingHistory = false
    @State private var soundOptions = false
    @FocusState private var numberFocused: Bool

    private var inCall: Bool { calls.state == .dialing || calls.state == .active || calls.state == .ringing }
    private var ink: Color { inCall ? .white : Color(red: 0.13, green: 0.15, blue: 0.19) }
    private var panel: Color { inCall ? Color(red:0.14,green:0.16,blue:0.22) : .white }
    private var canvas: Color { inCall ? Color(red:0.07,green:0.09,blue:0.14) : Color(red:0.955,green:0.961,blue:0.972) }
    private let green = Color(red: 0.08, green: 0.61, blue: 0.32)
    private let blue = Color(red: 0.16, green: 0.36, blue: 0.85)
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
    private let letters = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "", ""]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                phoneCard
                HStack(spacing:6) {
                    Circle().fill(calls.connected ? green : .orange).frame(width:6,height:6)
                    Text(calls.connected ? "Galaxy 연결됨" : "Galaxy 연결 확인 중")
                    Spacer()
                    Button(action:showDiagnostics) { Image(systemName:"slider.horizontal.3") }
                        .buttonStyle(.plain).accessibilityLabel("소리 및 연결 설정")
                }.font(.caption).foregroundStyle(.secondary)
                if let failure=audio.microphoneFailure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                DisclosureGroup("외장 헤드폰 · DGM20",isExpanded:$soundOptions) {
                    VStack(spacing:10) { connectionCard; audioCard }.padding(.top,8)
                }.font(.caption)
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(canvas)
        .foregroundStyle(ink)
        .preferredColorScheme(inCall ? .dark : .light)
        .animation(.easeInOut(duration:0.2),value:inCall)
        .onChange(of:calls.state) { _ in answerDrag=0 }
        .onChange(of:showingHistory) { show in if show { calls.loadRecentCalls() } }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text("GALAXY CALL BRIDGE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Text(inCall ? "통화" : "전화").font(.system(size: 28, weight: .bold))
            }
            Spacer()
            Button(action: showDiagnostics) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 42, height: 42)
                    .background(panel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("연결 설정 및 진단 열기")
            .help("연결 설정 및 진단")
        }
    }

    private var phoneCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label(calls.state == .ringing ? "수신 전화" : calls.state == .dialing ? "발신 중" : calls.state == .active ? "통화 중" : "키패드", systemImage: calls.state == .idle || calls.state == .unknown ? "circle.grid.3x3.fill" : "phone.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if calls.busy { ProgressView().controlSize(.small).accessibilityLabel("통화 요청 처리 중") }
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 18)

            if calls.state == .idle || calls.state == .unknown {
                Picker("전화 화면",selection:$showingHistory) {
                    Text("키패드").tag(false)
                    Text("최근 통화").tag(true)
                }.pickerStyle(.segmented).padding(.bottom,16)
            }

            if calls.state == .ringing || calls.state == .dialing || calls.state == .active {
                ongoingCall
            } else if showingHistory {
                callHistory
            } else {
                dialpad
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 28))
    }

    private var callHistory: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("최근 통화").font(.system(size:20,weight:.bold))
                Spacer()
                Button { calls.loadRecentCalls() } label: { Image(systemName:"arrow.clockwise").frame(width:32,height:32) }
                    .buttonStyle(.plain).disabled(calls.historyLoading || !calls.connected)
                Button("Mac 목록 지우기") { calls.clearCallHistory() }.font(.system(size:12,weight:.medium))
                    .buttonStyle(.plain).disabled(calls.callHistory.isEmpty)
            }
            Text(calls.historyMessage.isEmpty ? "최근 통화목록은 이 Mac에만 저장됩니다." : calls.historyMessage)
                .font(.system(size:11)).foregroundStyle(.secondary)
            if calls.historyLoading { ProgressView().frame(maxWidth:.infinity).padding(.vertical,20) }
            else if calls.callHistory.isEmpty {
                VStack(spacing:9) {
                    Image(systemName:"phone.arrow.down.left").font(.system(size:26)).foregroundStyle(.secondary)
                    Text("통화목록이 없어요").font(.system(size:15,weight:.semibold))
                    Text("Galaxy 연결 후 새로고침을 누르세요.").font(.system(size:11)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,minHeight:170)
            } else {
                ScrollView {
                    LazyVStack(spacing:0) {
                        ForEach(calls.callHistory) { item in
                            Button {
                                calls.number=item.number ?? ""
                                showingHistory=false
                            } label: {
                                HStack(spacing:11) {
                                    Image(systemName:item.type == 2 ? "phone.arrow.up.right.fill" : (item.type == 3 || item.type == 5 || item.type == 6) ? "phone.arrow.down.left.fill" : "phone.arrow.down.left")
                                        .font(.system(size:13,weight:.semibold))
                                        .foregroundStyle((item.type == 3 || item.type == 5 || item.type == 6) ? Color.red : green)
                                        .frame(width:34,height:34).background(canvas,in:Circle())
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(item.name?.isEmpty == false ? item.name! : item.number ?? "번호 없음")
                                            .font(.system(size:14,weight:.semibold)).lineLimit(1)
                                        Text("\(item.label) · \(item.timestamp.formatted(date:.abbreviated,time:.shortened))")
                                            .font(.system(size:10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength:4)
                                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle()).padding(.vertical,10)
                            }.buttonStyle(.plain).help("번호를 입력란에 넣기")
                            Divider()
                        }
                    }
                }.frame(maxHeight:390)
            }
            Text("항목을 누르면 번호만 입력됩니다. 초록 버튼을 눌러 발신하세요.")
                .font(.system(size:10)).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,4)
    }

    private var dialpad: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                TextField("전화번호 입력", text: $calls.number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .medium))
                    .multilineTextAlignment(.center)
                    .focused($numberFocused)
                    .accessibilityLabel("전화를 걸 번호")
                    .onSubmit { requestDial() }
                if !calls.number.isEmpty {
                    Button {
                        calls.number.removeLast()
                    } label: {
                        Image(systemName: "delete.left").font(.system(size: 18))
                            .frame(width: 36, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("마지막 숫자 지우기")
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 8) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    Button {
                        if calls.number.count < 32 { KeypadSound.play(key); calls.number.append(key) }
                    } label: {
                        VStack(spacing: 0) {
                            Text(key).font(.system(size: 29, weight: .regular))
                            if !letters[index].isEmpty {
                                Text(letters[index]).font(.system(size: 9, weight: .semibold)).tracking(1.5)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 58, height: 58)
                        .background(canvas, in: Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(PhoneKeyStyle())
                    .accessibilityLabel(key == "*" ? "별표" : key == "#" ? "샵" : key)
                }
            }
            .frame(maxWidth: 304)

            Button(action: requestDial) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(canDial ? green : Color.gray.opacity(0.35), in: Circle())
            }
            .buttonStyle(PhoneKeyStyle())
            .disabled(!canDial)
            .accessibilityLabel("입력한 번호로 전화 걸기")
            .padding(.top, 2)
            Text(calls.connected ? "Galaxy S25로 전화 걸기" : "Galaxy 연결을 기다리고 있어요")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var ongoingCall: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(calls.state == .ringing ? green.opacity(0.08) : blue.opacity(0.07)).frame(width: 144, height: 144)
                Circle().fill(calls.state == .ringing ? green.opacity(0.08) : blue.opacity(0.07)).frame(width: 112, height: 112)
                Image(systemName: "person.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(calls.state == .ringing ? green : blue)
            }
            .padding(.top, 12)
            VStack(spacing: 8) {
                Text(calls.state == .ringing ? "전화가 왔어요" : calls.state == .dialing ? "전화를 거는 중…" : "통화 중이에요")
                    .font(.system(size: 27, weight: .bold))
                Text(calls.state == .ringing ? calls.incomingLabel ?? "Galaxy S25" : calls.outgoingNumber ?? "Galaxy S25")
                    .font(.system(size: (calls.state == .ringing ? calls.incomingLabel : calls.outgoingNumber) == nil ? 15 : 22, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .monospacedDigit().foregroundStyle(.secondary)
                if calls.state == .dialing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("상대방에게 연결 신호를 보내는 중")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 28)
            if calls.state == .ringing {
                HStack(alignment: .bottom, spacing: 56) {
                    callAction("거절", symbol: "phone.down.fill", color: .red) { calls.end() }
                    VStack(spacing: 9) {
                        Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(green)
                        Button { calls.answer() } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 28, weight: .medium)).foregroundStyle(.white)
                                .frame(width: 58, height: 58).background(green, in: Circle())
                        }
                        .buttonStyle(PhoneKeyStyle())
                        .offset(y: answerDrag)
                        .simultaneousGesture(DragGesture(minimumDistance: 12)
                            .onChanged { answerDrag = max(-60, min(0, $0.translation.height)) }
                            .onEnded { value in
                                answerDrag = 0
                                if value.translation.height < -42 && !calls.busy && calls.canAnswer && calls.state == .ringing { calls.answer() }
                            })
                        .disabled(calls.busy || !calls.connected || !calls.canAnswer)
                        .accessibilityLabel("수신 전화 받기")
                        .help("클릭하거나 위로 밀어 전화 받기")
                        Text("받기").font(.system(size: 13, weight: .medium))
                    }
                }
                Text("초록 버튼을 누르거나 위로 밀어 받으세요")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                callAction("통화 종료", symbol: "phone.down.fill", color: .red) {
                    calls.end()
                }
                Text(audio.running ? "통화 사운드는 오른쪽에서 조절하세요" : "통화 오디오는 자동으로 연결됩니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 370)
    }

    private func callAction(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 9) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 27, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 58, height: 58).background(color, in: Circle())
            }
            .buttonStyle(PhoneKeyStyle())
            .disabled(calls.busy || !calls.connected || !calls.canEnd)
            .accessibilityLabel(title)
            Text(title).font(.system(size: 13, weight: .medium))
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 26)).foregroundStyle(blue)
                    .frame(width: 44, height: 48)
                    .background(blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Galaxy S25").font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(calls.connected ? green : Color.orange).frame(width: 6, height: 6)
                        Text(calls.connected ? calls.state == .active ? "통화 연결됨" : calls.state.label : "연결 확인 중")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { calls.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 30, height: 34)
                }
                .buttonStyle(.plain).disabled(calls.busy)
                .accessibilityLabel("Galaxy 통화 상태 새로고침")
            }
            if !calls.notice.isEmpty && (!calls.connected || calls.notice.contains("못") || calls.notice.contains("실패")) {
                Text(calls.notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.6)
            Toggle("이 Mac에서 벨소리", isOn: $calls.ringEnabled)
                .toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12)).tint(green)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 24))
    }

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("통화 사운드").font(.system(size: 17, weight: .bold))
                Spacer()
                Button { audio.refreshAudioDevices() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).disabled(audio.running)
                .accessibilityLabel("연결된 스피커와 마이크 다시 확인")
            }
            deviceRow("스피커", detail: audio.outputDescription, symbol: "speaker.wave.2.fill")
            deviceRow("마이크", detail: audio.inputDescription, symbol: "mic.fill")
            if audio.running && audio.activeMode?.usesMicrophone == true {
                Button { audio.toggleMicrophoneMute() } label: {
                    Label(audio.microphoneMuted ? "마이크 켜기" : "음소거", systemImage:audio.microphoneMuted ? "mic.slash.fill" : "mic.fill")
                }.disabled(!audio.audioReady)
            }
            if let failure=audio.microphoneFailure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            VStack(alignment:.leading) {
                VStack(alignment:.leading,spacing:8) {
                    Text(String(format:"마이크 음량 %.1f배",audio.microphoneGain)).font(.caption)
                    Slider(value:$audio.microphoneGain,in:1...6,step:0.5).accessibilityLabel("마이크 음량")
                    Text(audioStatus).font(.caption).foregroundStyle(.secondary)
                    Button("연결 진단",action:showDiagnostics)
                }.padding(.top,8)
            }.font(.system(size:12))
        }
        .padding(20)
        .background(panel, in: RoundedRectangle(cornerRadius: 24))
    }

    private func deviceRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(blue)
                .frame(width: 28, height: 28).background(blue.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var audioStatus: String {
        if audio.running {
            if let failure=audio.microphoneFailure { return "상대방 음성 수신 유지 · 내 목소리 전달 중단: " + failure }
            if !audio.audioReady { return "통화 오디오 시작 중 · 연결과 장치 확인" }
            return audio.microphoneMuted ? "마이크가 꺼져 있어요. 상대방에게 내 소리가 전달되지 않습니다." : (audio.activeMode == .duplex ? "DGM20 마이크와 외장 헤드폰 연결됨" : "통화 오디오 사용 중")
        }
        if audio.state.hasPrefix("중지") {
            return "오디오가 중지됐어요. 다시 시작할 수 있고, 중지 이유는 연결 설정 및 진단에서 확인할 수 있어요."
        }
        return "통화가 연결되면 DGM20 마이크와 외장 헤드폰를 자동 연결합니다."
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield").font(.system(size: 11))
            Text("통화목록은 이 Mac에만 저장")
                .font(.system(size: 11))
            Spacer()

        }
        .foregroundStyle(.secondary)
    }

    private var canDial: Bool {
        calls.connected && calls.canDial && !calls.busy && calls.state == .idle && PhoneNumberRules.normalize(calls.number) != nil
    }

    private func requestDial() {
        guard canDial else { return }
        numberFocused = false
        calls.dial()
    }
}

private struct PhoneKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
