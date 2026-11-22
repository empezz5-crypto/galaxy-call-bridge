import Foundation
import CoreAudio

struct AudioOutputSnapshot: Codable, Equatable {
    let totalDeviceCount: Int?
    let outputDeviceCount: Int?
    let defaultOutputDeviceID: UInt32?
    let queryStatus: Int32

    var summary: String {
        let outputs = outputDeviceCount.map(String.init) ?? "확인 불가"
        let endpoint = defaultOutputDeviceID.map { "기본 출력 장치 ID \($0)" } ?? "기본 출력 장치 없음"
        if queryStatus != 0 {
            return "CoreAudio 출력 장치 조회 실패 (OSStatus \(queryStatus)) · 출력 장치 \(outputs)개"
        }
        return "CoreAudio 출력 장치 \(outputs)개 · \(endpoint)"
    }

    var hasDefaultOutput: Bool { defaultOutputDeviceID != nil }

    static func read() -> AudioOutputSnapshot {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var listSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &deviceAddress, 0, nil, &listSize)
        guard sizeStatus == noErr else {
            return AudioOutputSnapshot(totalDeviceCount: nil, outputDeviceCount: nil,
                                       defaultOutputDeviceID: nil, queryStatus: sizeStatus)
        }

        let count = Int(listSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        var listStatus: OSStatus = noErr
        if listSize > 0 {
            var bufferSize = UInt32(deviceIDs.count * MemoryLayout<AudioDeviceID>.size)
            listStatus = deviceIDs.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(system, &deviceAddress, 0, nil, &bufferSize, bytes.baseAddress!)
            }
        }
        guard listStatus == noErr else {
            return AudioOutputSnapshot(totalDeviceCount: count, outputDeviceCount: nil,
                                       defaultOutputDeviceID: nil, queryStatus: listStatus)
        }

        let outputCount = deviceIDs.reduce(into: 0) { total, deviceID in
            if hasOutputStreams(deviceID) { total += 1 }
        }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultID = AudioDeviceID(kAudioObjectUnknown)
        let defaultStatus = AudioObjectGetPropertyData(system, &defaultAddress, 0, nil, &defaultSize, &defaultID)
        let usableDefault = defaultStatus == noErr && defaultID != AudioDeviceID(kAudioObjectUnknown)
        return AudioOutputSnapshot(totalDeviceCount: count, outputDeviceCount: outputCount,
                                   defaultOutputDeviceID: usableDefault ? UInt32(defaultID) : nil,
                                   queryStatus: defaultStatus)
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }
}

enum DiagnosticEvent: String, Codable {
    case appStarted
    case pairedDeviceInventory
    case sdpQueryRequested
    case sdpQueryStarted
    case sdpQueryCompleted
    case hfpConnectRequested
    case hfpConnectionResult
    case hfpDisconnectRequested
    case hfpDisconnectionResult
    case scoConnectRequested
    case scoConnectionResult
    case scoDisconnectRequested
    case scoDisconnectionResult
    case transferAudioToComputerRequested
    case outgoingCallRequested
    case incomingCallAnswered
    case callEnded
    case callActiveIndicator
    case callSetupIndicator
    case callHoldIndicator
    case incomingCallIndicator
    case currentCallIndicator
    case hfpStateRead
    case scoStateRead
    case coreAudioOutputSnapshot
    case diagnosticsExport
    case operationRejected
}

enum DiagnosticStatus: String, Codable {
    case started
    case requested
    case accepted
    case succeeded
    case failed
    case timedOut
    case connected
    case disconnected
    case routeNotVerified
    case noDefaultOutput
    case readOnly
    case exported
    case cancelled
    case invokedVoidAPI
    case valueReported
    case detailsOmitted
    case notAvailable
}

struct DiagnosticRecord: Codable {
    let timestamp: String
    let event: DiagnosticEvent
    let status: DiagnosticStatus
    let errorCode: Int32?
    let indicatorValue: Int?
    let totalAudioDeviceCount: Int?
    let outputAudioDeviceCount: Int?
    let defaultOutputDeviceID: UInt32?
    let coreAudioStatus: Int32?
}

final class LocalDiagnosticJournal {
    let fileURL: URL?
    private(set) var initializationError: String?
    private(set) var lastWriteSucceeded = false

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
            do {
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                if !fileManager.fileExists(atPath: fileURL.path) {
                    _ = fileManager.createFile(atPath: fileURL.path, contents: Data(),
                                               attributes: [.posixPermissions: 0o600])
                }
            } catch {
                self.initializationError = "diagnostic-file-unavailable"
            }
            return
        }
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
            let directory = base.appendingPathComponent("GalaxyCallBridge", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("diagnostics.jsonl")
            if !fileManager.fileExists(atPath: url.path) {
                _ = fileManager.createFile(atPath: url.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
            }
            self.fileURL = url
        } catch {
            self.fileURL = nil
            self.initializationError = "diagnostic-file-unavailable"
        }
    }

    /// Keeps one previous generation (`name.1.jsonl`) so the journal can never grow without bound.
    static func rotateIfNeeded(_ url: URL, maxBytes: Int = 5 * 1024 * 1024, fileManager: FileManager = .default) {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? fileManager.removeItem(at: old)
        guard (try? fileManager.moveItem(at: url, to: old)) != nil else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: old.path)
        _ = fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }

    @discardableResult
    func record(event: DiagnosticEvent, status: DiagnosticStatus,
                errorCode: Int32? = nil, indicatorValue: Int? = nil,
                audio: AudioOutputSnapshot? = nil, at date: Date = Date()) -> Bool {
        guard let fileURL else { lastWriteSucceeded = false; return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = DiagnosticRecord(
            timestamp: formatter.string(from: date), event: event, status: status,
            errorCode: errorCode, indicatorValue: indicatorValue,
            totalAudioDeviceCount: audio?.totalDeviceCount,
            outputAudioDeviceCount: audio?.outputDeviceCount,
            defaultOutputDeviceID: audio?.defaultOutputDeviceID,
            coreAudioStatus: audio?.queryStatus)
        do {
            let encoder = JSONEncoder()
            let line = try encoder.encode(record) + Data([0x0A])
            Self.rotateIfNeeded(fileURL)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data(),
                                                   attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
            lastWriteSucceeded = true
            return true
        } catch {
            lastWriteSucceeded = false
            return false
        }
    }

    func export(to destination: URL) throws {
        guard let fileURL else { throw CocoaError(.fileReadNoSuchFile) }
        let data = try Data(contentsOf: fileURL)
        try data.write(to: destination, options: .atomic)
    }
}
