import Foundation

final class BoundedFrameQueue<Element> {
    private let lock = NSLock()
    private let capacity: Int
    private var items = [Element]()
    init(capacity: Int) { precondition(capacity > 0); self.capacity = capacity }
    @discardableResult func push(_ item: Element) -> Bool { lock.lock(); defer { lock.unlock() }; guard items.count < capacity else { return false }; items.append(item); return true }
    func pop() -> Element? { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? nil : items.removeFirst() }
    func reset() { lock.lock(); items.removeAll(keepingCapacity: true); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

struct PCMExperimentGate {
    enum Mode { case downlink, uplink, duplex
        var usesMicrophone: Bool { self == .uplink || self == .duplex }
    }
    private(set) var mode: Mode?
    private(set) var androidStarted = false
    private(set) var micOpened = false
    private(set) var microphoneAllowed = false
    var canOpenMicrophone: Bool { mode?.usesMicrophone == true && androidStarted && microphoneAllowed }
    private(set) var deadline: Date?
    mutating func begin(_ mode: Mode, ready: Bool, now: Date = Date()) -> Bool {
        guard ready, self.mode == nil else { return false }
        self.mode = mode; androidStarted = false; micOpened = false; microphoneAllowed = false; deadline = now.addingTimeInterval(60); return true
    }
    mutating func acknowledgeStarted() { guard mode != nil else { return }; androidStarted = true }
    mutating func authorizeMicrophone(_ allowed: Bool) { if mode?.usesMicrophone == true { microphoneAllowed = allowed } }
    mutating func markMicOpened() { if canOpenMicrophone { micOpened = true } }
    mutating func stop() { mode=nil; androidStarted=false; micOpened=false; microphoneAllowed=false; deadline=nil }
    mutating func shouldStop(now: Date, androidCallActive: Bool = true, socketConnected: Bool = true) -> Bool { mode != nil && (!androidCallActive || !socketConnected || (deadline.map { now >= $0 } ?? true)) }
}

/// Muting preserves pacing and frame size without reopening or rerouting the microphone.
enum MicrophoneTransmission {
    static func payload(_ pcm: Data, muted: Bool) -> Data { muted ? Data(repeating: 0, count: pcm.count) : pcm }
}
