import AVFoundation
import Foundation
@main struct Check {
 static func main() {
    let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
    let capture=MicrophoneCaptureBuffer(inputFormat:format)!
    var frames=0, maxSample=0
    for iteration in 0..<20 {
        let b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:960)!; b.frameLength=960
        for i in 0..<960 {
            b.floatChannelData![0][i]=Float(sin(Double(iteration*960+i)*2*Double.pi*1000/48000)*0.1)
            b.floatChannelData![1][i]=0
        }
        capture.append(b)
        while let data=capture.pop() {
            precondition(data.count==640); frames += 1
            let bytes=Array(data)
            for i in stride(from:0,to:bytes.count,by:2) { maxSample=max(maxSample,abs(Int(Int16(bitPattern:UInt16(bytes[i])|UInt16(bytes[i+1])<<8)))) }
        }
    }
    precondition(frames>=18 && frames<=20)
    precondition(maxSample>3000 && maxSample<3500)
    precondition(capture.diagnostics().errors==0)
    capture.stop();precondition(capture.pop()==nil)
    print("PASS synthetic DGM20-style stereo 48k→mono 16k conversion, channel 1 unity amplitude, 640-byte frames, stop clears queue; no audio device opened")
 }
}
