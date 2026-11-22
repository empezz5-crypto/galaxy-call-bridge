import AppKit
import CoreAudio

/// Local keypad feedback only; never sends tones or digits to the phone.
@MainActor enum KeypadSound {
    private static var current: NSSound?
    static func play(_ key: String) {
        guard let device=MicrophoneInput.externalHeadphones() else { return }
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var uid:CFString?, size=UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device.id,&address,0,nil,&size,&uid)==noErr, let uid,
              let data=wave(key), let sound=NSSound(data:data) else { return }
        current?.stop()
        sound.playbackDeviceIdentifier=uid as String
        sound.volume=0.3
        current=sound
        sound.play()
    }
    static func wave(_ key:String) -> Data? {
        let rows=["123","456","789","*0#"]
        guard let row=rows.firstIndex(where:{$0.contains(key)}), key.count==1,
              let column=Array(rows[row]).firstIndex(of:Character(key)) else { return nil }
        let low=[697.0,770,852,941][row], high=[1209.0,1336,1477][column]
        let rate=44100, count=3969
        var data=Data()
        func word<T:FixedWidthInteger>(_ n:T) { var v=n.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        data.append(contentsOf:"RIFF".utf8);word(UInt32(36+count*2));data.append(contentsOf:"WAVEfmt ".utf8)
        word(UInt32(16));word(UInt16(1));word(UInt16(1));word(UInt32(rate));word(UInt32(rate*2));word(UInt16(2));word(UInt16(16))
        data.append(contentsOf:"data".utf8);word(UInt32(count*2))
        for i in 0..<count {
            let fade=min(1,min(Double(i)/220,Double(count-1-i)/220))
            let time=Double(i)/Double(rate)
            word(Int16((sin(2 * .pi * low * time)+sin(2 * .pi * high * time))*5000*fade))
        }
        return data
    }
}
