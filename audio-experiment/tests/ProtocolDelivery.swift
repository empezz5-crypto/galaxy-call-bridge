import Foundation
@main struct ProtocolDeliveryChecks {
    @MainActor static func main() async throws {
        let controller=AudioExperimentController()
        if CommandLine.arguments.contains("--live") {
            let state=await controller.checkLiveErrorDelivery()
            print("Live controller result: " + state)
            precondition(state.contains("ERROR:SELFTEST:IOException"))
            print("Runtime identity: " + controller.serviceIdentity)
            return
        }
        let error=try AudioWire.encode(.status,Data("ERROR:START:FACTORY_INVOKE:InvocationTargetException:UnsupportedOperationException".utf8))
        for split in 0...error.count {
            let result=controller.checkErrorDelivery([Data(error.prefix(split)),Data(error.dropFirst(split))])
            precondition(result.contains("ERROR:START:FACTORY_INVOKE:InvocationTargetException:UnsupportedOperationException"))
            precondition(!result.contains("터널 읽기 종료"))
        }
        let identity=Data("GCB1_ANDROID_PCM_V1;build=20261031-059-r1;pid=123;started=123456;session=abc".utf8)
        precondition(AudioWire.serviceIdentity(identity) != nil)
        precondition(AudioWire.serviceIdentity(Data("GCB1_ANDROID_PCM_V1".utf8)) == nil)
        precondition(AudioWire.serviceIdentity(Data("GCB1_ANDROID_PCM_V1;build=20261013-047;pid=123;started=123456;session=abc".utf8)) == nil)
        let started=try AudioWire.encode(.status,Data("STARTED".utf8))
        let pcm=try AudioWire.encode(.downlinkPCM,Data(repeating:0,count:640))
        let duplex=controller.checkSyntheticSession([started,pcm],mode:.duplex,microphoneAllowed:true)
        precondition(duplex.running && duplex.frames==1)
        let degraded=controller.checkSyntheticSession([started,pcm,pcm],mode:.duplex,microphoneAllowed:true,microphoneFails:true)
        precondition(degraded.running && degraded.frames==2 && degraded.state.contains("수신 유지"))
        let failedUplink=controller.checkSyntheticSession([started],mode:.uplink,microphoneAllowed:true,microphoneFails:true)
        precondition(!failedUplink.running)
        let duplicate=controller.checkSyntheticSession([started,started],mode:.duplex,microphoneAllowed:true)
        precondition(!duplicate.running && duplicate.state.contains("STARTED 순서"))
        let unauthorized=controller.checkSyntheticSession([started],mode:.duplex,microphoneAllowed:false)
        precondition(!unauthorized.running && unauthorized.state.contains("마이크 권한"))
        let earlyPCM=controller.checkSyntheticSession([pcm],mode:.duplex,microphoneAllowed:true)
        precondition(!earlyPCM.running && earlyPCM.frames==0)
        let unexpectedDirection=controller.checkSyntheticSession([started,pcm],mode:.uplink,microphoneAllowed:true)
        precondition(!unexpectedDirection.running && unexpectedDirection.frames==0)
        let oddPCM=try AudioWire.encode(.downlinkPCM,Data(repeating:0,count:3))
        let malformed=controller.checkSyntheticSession([started,oddPCM],mode:.duplex,microphoneAllowed:true)
        precondition(!malformed.running && malformed.frames==0)
        controller.setMicrophoneMuted(true)
        precondition(!controller.running && !controller.microphoneMuted)
        print("PASS actual controller: duplex PCM ordering, permissions, duplicate STARTED, wrong direction, odd length, idle mute; no audio opened")
        print("PASS actual controller: every error-frame split preserves cause through EOF; legacy HELLO rejected; no audio opened")
    }
}
