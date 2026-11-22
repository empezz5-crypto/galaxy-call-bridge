import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

let sameDeviceA = BluetoothDeviceIdentity.id(address: "AA:BB:CC:DD:EE:FF", fallback: "one")
let sameDeviceB = BluetoothDeviceIdentity.id(address: "aabbccddeeff", fallback: "two")
let otherDevice = BluetoothDeviceIdentity.id(address: "11:22:33:44:EE:FF", fallback: "three")
check(sameDeviceA == sameDeviceB, "format and case normalize to a stable hardware ID")
check(sameDeviceA != otherDevice, "different Bluetooth addresses remain separately selectable")
let rows = [(name: "거니의 S25", id: sameDeviceA), (name: "거니의 S25", id: sameDeviceB), (name: "거니의 S25", id: otherDevice)]
let unique = BluetoothDeviceIdentity.uniqueByID(rows, id: \.id)
check(unique.count == 2, "duplicate listing of one address collapses; separate same-name phone remains")
let hints = BluetoothDeviceIdentity.uniqueDisplayHints(ids: unique.map(\.id))
check(Set(hints.values).count == 2, "same-name phones receive distinct short labels")
check(hints.values.allSatisfy { !$0.contains("AABBCCDDEEFF") && !$0.contains("11223344EEFF") }, "full Bluetooth addresses are not displayed")
let collisionIDs = ["mac:0011223344ABCD", "mac:FFEEDDCC44ABCD"]
let collisionHints = BluetoothDeviceIdentity.uniqueDisplayHints(ids: collisionIDs)
check(Set(collisionHints.values).count == 2 && collisionHints.values.allSatisfy { $0.hasSuffix("44ABCD") }, "display suffix expands when last four characters collide")
check(BluetoothDeviceIdentity.id(address: nil, fallback: "obj-1") != BluetoothDeviceIdentity.id(address: nil, fallback: "obj-2"), "missing addresses use distinct in-process identity fallback")

check(HFPEventLabels.callActive(nil).contains("미수신"), "missing active-call event stays distinct from inactive")
check(HFPEventLabels.callActive(0) == "활성 통화 없음", "active-call event value zero means no active call")
check(HFPEventLabels.callActive(1) == "활성 통화 있음", "active-call event value one means active call")
check(HFPEventLabels.callSetup(nil).contains("미수신"), "missing call-setup event stays unknown")
check(HFPEventLabels.callSetup(3) == "상대방 호출 중", "call setup value three means remote alerting")
check(HFPEventLabels.callHeld(nil).contains("미수신"), "missing call-hold event stays unknown")
check(HFPEventLabels.callHeld(2) == "활성 통화 없이 보류 통화 있음", "call-hold value two means held call without active call")
check(HFPEventLabels.scoStatus(Int32(bitPattern: 0xE00002C7)).contains("kIOReturnUnsupported"), "unsupported IOReturn is mapped to the SDK name")
check(HFPEventLabels.scoStatus(0).contains("양방향 음성 미검증"), "successful SCO callback does not claim bidirectional audio")

let testLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("GCB-diagnostics-test-\(UUID().uuidString).jsonl")
let journal = LocalDiagnosticJournal(fileURL: testLogURL)
let audioFixture = AudioOutputSnapshot(totalDeviceCount: 3, outputDeviceCount: 2, defaultOutputDeviceID: 42, queryStatus: 0)
check(journal.record(event: .transferAudioToComputerRequested, status: .invokedVoidAPI, audio: audioFixture), "diagnostic journal appends a local API event")
check(journal.record(event: .scoConnectionResult, status: .failed, errorCode: Int32(bitPattern: 0xE00002C7)), "diagnostic journal records SCO failures")
let diagnosticText = (try? String(contentsOf: testLogURL, encoding: .utf8)) ?? ""
check(diagnosticText.contains("transferAudioToComputerRequested") && diagnosticText.contains("invokedVoidAPI"), "diagnostic log records API type and state")
check(diagnosticText.contains("timestamp") && diagnosticText.contains("errorCode"), "diagnostic records carry time and an error-code field")
check(diagnosticText.contains("\"defaultOutputDeviceID\":42") && diagnosticText.contains("\"outputAudioDeviceCount\":2"), "diagnostic log records CoreAudio output endpoint identifiers")
check(diagnosticText.contains("-536870201"), "diagnostic log retains the unsupported IOReturn code")
check(!diagnosticText.localizedCaseInsensitiveContains("phoneNumber") && !diagnosticText.localizedCaseInsensitiveContains("callInfo"), "diagnostic schema omits phone numbers and call details")
let testFileMode = (try? FileManager.default.attributesOfItem(atPath: testLogURL.path)[.posixPermissions] as? NSNumber)?.intValue
check(testFileMode == 0o600, "local diagnostic file is owner-only")
let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("GCB-diagnostics-export-\(UUID().uuidString).jsonl")
do { try journal.export(to: exportURL) } catch { check(false, "diagnostic export writes a selected local destination") }
check((try? String(contentsOf: exportURL, encoding: .utf8)) == diagnosticText, "exported diagnostics match the local journal")
try? FileManager.default.removeItem(at: exportURL)
try? FileManager.default.removeItem(at: testLogURL)
let noOutput = AudioOutputSnapshot(totalDeviceCount: 0, outputDeviceCount: 0, defaultOutputDeviceID: nil, queryStatus: 0)
check(noOutput.summary.contains("기본 출력 장치 없음"), "CoreAudio display separates missing default output from HFP status")

// Rotation: an oversized journal moves to .1.jsonl (replacing the old one) and restarts owner-only.
let rotateURL = FileManager.default.temporaryDirectory.appendingPathComponent("GCB-rotate-\(UUID().uuidString).jsonl")
let rotateOld = rotateURL.deletingPathExtension().appendingPathExtension("1.jsonl")
try? Data("old-generation\n".utf8).write(to: rotateOld)
try? Data(repeating: 0x41, count: 2048).write(to: rotateURL)
LocalDiagnosticJournal.rotateIfNeeded(rotateURL, maxBytes: 4096)
check((try? Data(contentsOf: rotateURL).count) == 2048, "journal below the limit is not rotated")
let rotateJournal = LocalDiagnosticJournal(fileURL: rotateURL)
LocalDiagnosticJournal.rotateIfNeeded(rotateURL, maxBytes: 1024)
check((try? Data(contentsOf: rotateURL).count) == 0, "journal above the limit starts fresh")
check((try? Data(contentsOf: rotateOld).count) == 2048, "rotated journal replaces the old generation")
check((try? FileManager.default.attributesOfItem(atPath: rotateURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
      && (try? FileManager.default.attributesOfItem(atPath: rotateOld.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "rotated and fresh journals stay owner-only")
check(rotateJournal.record(event: .appStarted, status: .succeeded), "journal keeps accepting records after rotation")
try? FileManager.default.removeItem(at: rotateURL); try? FileManager.default.removeItem(at: rotateOld)
