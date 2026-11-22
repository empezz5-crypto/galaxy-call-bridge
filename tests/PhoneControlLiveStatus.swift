import Foundation
import AppKit

/// Opt-in read-only status through the production controller; never sends call commands.
@main struct LiveStatus {
    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--live-read-only") else {
            print("Pass --live-read-only to query existing loopback control status only.")
            return
        }
        let controller=PhoneCallController(startMonitoring:false)
        controller.ringEnabled=false
        controller.connected=true // Use the existing forward without running its helper.
        controller.refresh()
        for _ in 0..<40 {
            if controller.state != .unknown || !controller.connected { break }
            try? await Task.sleep(nanoseconds:100_000_000)
        }
        guard controller.connected,controller.state != .unknown else {
            print("FAIL live control status unavailable");exit(1)
        }
        print("PASS production controller: connected=true state=\(controller.state.rawValue) canDial=\(controller.canDial) canAnswer=\(controller.canAnswer) canEnd=\(controller.canEnd); no call/audio commands")
    }
}
