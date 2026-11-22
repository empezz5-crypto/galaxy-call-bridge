import Foundation
import Darwin

/// An isolated loopback peer. This executable links only the call controller/protocol:
/// no audio controller, ADB helper, device endpoint, or call API is used.
private final class MockPhonePeer: @unchecked Sendable {
    enum Scenario { case delayedStatus, commandTimeout }
    let port: UInt16
    private let listener: Int32
    private let scenario: Scenario
    private let lock = NSLock()
    private var actions = [String]()
    private var closed = false
    private var clients = Set<Int32>()
    private let queue = DispatchQueue(label: "gcb.test.peer", attributes: .concurrent)

    init(_ scenario: Scenario) throws {
        self.scenario = scenario
        let opened = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard opened >= 0 else { throw TestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(opened, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(opened, 8) == 0 else {
            Darwin.close(opened); throw TestError.socket
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let identified = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(opened, $0, &length)
            }
        }
        guard identified == 0 else { Darwin.close(opened); throw TestError.socket }
        listener = opened
        port = UInt16(bigEndian: address.sin_port)
        precondition(port != 38241 && port != 38242 && port != 0)
        queue.async { [self] in acceptClients() }
    }

    func count(_ action: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return actions.filter { $0 == action }.count
    }

    func stop() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let remaining = Array(clients)
        lock.unlock()
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        for client in remaining { Darwin.shutdown(client, SHUT_RDWR) }
    }

    private func acceptClients() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            lock.lock()
            if closed { lock.unlock(); Darwin.close(client); return }
            clients.insert(client); lock.unlock()
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            queue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer {
            lock.lock(); clients.remove(client); lock.unlock()
            Darwin.close(client)
        }
        var request = Data()
        while request.count <= 1024 {
            var byte: UInt8 = 0
            guard Darwin.recv(client, &byte, 1, 0) == 1 else { return }
            if byte == 10 { break }
            request.append(byte)
        }
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: String],
              let action = object["action"], ["status", "dial"].contains(action) else {
            preconditionFailure("Unexpected mock request")
        }
        if action == "dial" { precondition(object["number"] == "5550100") }
        lock.lock(); actions.append(action); let statusIndex = actions.filter { $0 == "status" }.count; lock.unlock()

        let replyState: String
        if action == "status", statusIndex == 1, scenario == .delayedStatus {
            // This response predates the explicit dial. It must not revert the active state.
            Thread.sleep(forTimeInterval: 0.9)
            replyState = "idle"
        } else if action == "dial", scenario == .commandTimeout {
            // The request may have taken effect: timeout must never retry the action.
            Thread.sleep(forTimeInterval: 4.0)
            replyState = "active"
        } else { replyState = "active" }
        let reply: [String: Any] = ["ok": true, "state": replyState, "build": "20261031-059-r1",
                                   "canDial": replyState == "idle", "canAnswer": false, "canEnd": replyState == "active"]
        guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.append(10)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base.advanced(by: offset), raw.count - offset, 0)
                if written <= 0 { break }
                offset += written
            }
        }
    }
    enum TestError: Error { case socket }
}

@main struct PhoneControlDeliveryChecks {
    @MainActor private static func controller(_ peer: MockPhonePeer) -> PhoneCallController {
        let controller = PhoneCallController(startMonitoring: false, port: peer.port)
        controller.ringEnabled = false
        controller.connected = true; controller.state = .idle; controller.canDial = true
        controller.number = "5550100"
        return controller
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool, timeout: Double = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Mock condition timed out")
    }

    @MainActor static func main() async throws {
        let peer = try MockPhonePeer(.delayedStatus)
        defer { peer.stop() }
        let phone = controller(peer)
        phone.refresh()
        await waitUntil { peer.count("status") == 1 }
        phone.dial()
        precondition(phone.state == .dialing && phone.busy, "Dial must change screen before reply")
        phone.dial() // A repeated click during the same command must not add a command.
        await waitUntil { peer.count("dial") == 1 && !phone.busy }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(peer.count("dial") == 1)
        precondition(phone.connected && phone.state == .active && !phone.canDial && phone.canEnd)
        print("PASS explicit dial supersedes delayed status; one command; stale reply ignored")

        let stalled = try MockPhonePeer(.commandTimeout)
        defer { stalled.stop() }
        let uncertain = controller(stalled)
        uncertain.dial()
        uncertain.dial()
        await waitUntil { stalled.count("dial") == 1 }
        await waitUntil({ !uncertain.busy }, timeout: 4)
        precondition(!uncertain.connected && uncertain.state == .unknown)
        precondition(uncertain.notice.contains("요청 결과를 확인하지 못했습니다"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        precondition(stalled.count("dial") == 1 && stalled.count("status") == 0)
        precondition(!uncertain.connected && uncertain.state == .unknown)
        print("PASS command timeout never retries; late success does not overwrite uncertainty")
        print("PASS isolated ephemeral loopback only; audio sources and device calls not linked or invoked")
    }
}
