import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

enum MicrophoneInput {
    struct Device { let id: AudioDeviceID; let name: String }
    enum InputError: LocalizedError {
        case unavailable, ambiguous, bindFailed(OSStatus), changed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "DGM20 입력을 찾지 못했습니다. USB 연결을 확인하세요."
            case .ambiguous: return "DGM20 입력이 여러 개입니다. 사용할 기기 하나만 연결하세요."
            case .bindFailed(let status): return "DGM20 입력 지정 실패 (\(status))"
            case .changed: return "마이크 연결 또는 설정이 바뀌었습니다. DGM20 연결 후 다시 시작하세요."
            }
        }
    }
    static func resolveDGM20() throws -> Device {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else { throw InputError.unavailable }
        guard size>=MemoryLayout<AudioDeviceID>.size else { throw InputError.unavailable }
        var devices=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        let status=devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!) }
        guard status==noErr else { throw InputError.unavailable }
        let matches=devices.compactMap { id -> Device? in
            guard isAlive(id), hasInput(id), let name=name(id), name.localizedCaseInsensitiveContains("DGM20") else { return nil }
            return Device(id:id,name:name)
        }
        guard !matches.isEmpty else { throw InputError.unavailable }
        guard matches.count==1 else { throw InputError.ambiguous }
        return matches[0]
    }
    static func externalHeadphones() -> Device? {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else { return nil }
        var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        let status=ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!) }
        guard status==noErr else { return nil }
        return ids.compactMap { id -> Device? in
            guard isAlive(id), let label=name(id), (label == "외장 헤드폰" || label.caseInsensitiveCompare("External Headphones") == .orderedSame) else { return nil }
            return Device(id:id,name:label)
        }.first
    }
    static func defaultOutput() -> Device? {
        var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var id=AudioDeviceID(0), size=UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&id)==noErr,
              id != 0, let label=name(id) else { return nil }
        return Device(id:id,name:label)
    }
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceIsAlive,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var size=UInt32(MemoryLayout<UInt32>.size), alive:UInt32=0
        return AudioObjectGetPropertyData(id,&a,0,nil,&size,&alive)==noErr && alive != 0
    }
    private static func hasInput(_ id:AudioDeviceID) -> Bool {
        var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,mScope:kAudioDevicePropertyScopeInput,mElement:0)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(id,&a,0,nil,&size)==noErr, size>=MemoryLayout<AudioBufferList>.size else { return false }
        let memory=UnsafeMutableRawPointer.allocate(byteCount:Int(size),alignment:MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id,&a,0,nil,&size,memory)==noErr else { return false }
        let buffers=UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to:AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels>0 }
    }
    static func name(_ id:AudioDeviceID) -> String? {
        var a=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var size=UInt32(MemoryLayout<CFString?>.size), value:CFString?
        let status=withUnsafeMutablePointer(to:&value) { AudioObjectGetPropertyData(id,&a,0,nil,&size,$0) }
        guard status==noErr, let value else { return nil }; return value as String
    }
    static func bind(_ device:Device, to unit:AudioUnit) throws {
        var id=device.id
        let status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status==noErr else { throw InputError.bindFailed(status) }
        guard currentDevice(unit)==device.id else { throw InputError.changed }
    }
    static func currentDevice(_ unit:AudioUnit) -> AudioDeviceID? {
        var id=AudioDeviceID(0), size=UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,&size)==noErr else { return nil }
        return id
    }
}

// Owned by one explicit mic session. Audio callbacks never touch MainActor state.
final class MicrophoneCaptureBuffer: @unchecked Sendable {
    private let lock=NSLock()
    private let converter:AVAudioConverter
    private let outputFormat:AVAudioFormat
    private var enabled=true
    private var pending=Data()
    private var frames=[Data]()
    private var dropped=0, conversionErrors=0
    init?(inputFormat:AVAudioFormat) {
        guard inputFormat.sampleRate>0, inputFormat.channelCount>0,
              let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true),
              let converter=AVAudioConverter(from:inputFormat,to:format) else { return nil }
        outputFormat=format; self.converter=converter
        // DGM20 channel 1, explicit unity channel mapping; do not sum/attenuate stereo.
        converter.channelMap=[0]
    }
    func append(_ input:AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        let capacity=AVAudioFrameCount(Double(input.frameLength)*16000/input.format.sampleRate+64)
        guard let out=AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:max(capacity,320)) else { conversionErrors += 1; return }
        var supplied=false, error:NSError?
        converter.convert(to:out,error:&error) { _,status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied=true; status.pointee = .haveData; return input
        }
        guard error == nil, let samples=out.int16ChannelData else { conversionErrors += 1; return }
        pending.append(Data(bytes:samples[0],count:Int(out.frameLength)*2))
        while pending.count>=640 {
            let frame=Data(pending.prefix(640)); pending.removeFirst(640)
            if frames.count<5 { frames.append(frame) } else { dropped += 1 }
        }
    }
    func pop() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }
    func diagnostics() -> (dropped:Int, errors:Int) {
        lock.lock(); defer { lock.unlock() }; return (dropped,conversionErrors)
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }; enabled=false; pending.removeAll(); frames.removeAll()
    }
}
