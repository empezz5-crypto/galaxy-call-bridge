import Foundation
import Combine

// Auto-audio guards must observe stored values, including simultaneous connection/state changes.
@MainActor final class TransitionFixture: ObservableObject {
    @Published var active = false
    @Published var checking = true
    var connected = false
}
@main struct PublishedTransitionChecks {
    @MainActor static func main() async {
        let fixture = TransitionFixture()
        var immediateReadWasStale = false
        var starts = 0
        let immediate = fixture.$active.dropFirst().sink { active in
            immediateReadWasStale = active && !fixture.active
        }
        let deferred = fixture.$active.removeDuplicates().receive(on: RunLoop.main).sink { active in
            if active && fixture.active && fixture.connected && !fixture.checking { starts += 1 }
        }
        fixture.active = true
        fixture.connected = true
        fixture.checking = false
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(immediateReadWasStale, "Fixture must reproduce Published willSet ordering")
        precondition(starts == 1, "Deferred activation must see all stored state and start once")
        fixture.active = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        precondition(starts == 1, "Idle must never start audio")
        withExtendedLifetime((immediate, deferred)) {}
        print("PASS deferred auto-audio transition; no audio or call operations")
    }
}
