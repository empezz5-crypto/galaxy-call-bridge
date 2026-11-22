import AppKit
import Foundation

enum AppInstanceLifecycle {
    private static let appPrefix = "GalaxyCallBridge"
    private static let bundleIDPrefix = "local.gunhee.GalaxyCallBridge"

    static func enforceLatestAndSingleInstance() {
        let currentURL = Bundle.main.bundleURL
        let currentPID = ProcessInfo.processInfo.processIdentifier
        // Never enumerate the external build directory during launch. Reconcile only
        // processes macOS already knows about, once the application event loop starts.
        DispatchQueue.main.async {
            reconcileRunningInstances(currentURL: currentURL, currentPID: currentPID)
        }
    }

    private static func reconcileRunningInstances(currentURL: URL, currentPID: pid_t) {
        guard let currentVersion = version(fromBundleFilename: currentURL.lastPathComponent) else { return }
        let buildDirectory = currentURL.deletingLastPathComponent().path
        let matching: [(app: NSRunningApplication, version: [Int])] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != currentPID, !app.isTerminated,
                  let url = app.bundleURL,
                  url.deletingLastPathComponent().path == buildDirectory,
                  let id = app.bundleIdentifier,
                  id == bundleIDPrefix || id.hasPrefix(bundleIDPrefix + ".v"),
                  let version = version(fromBundleFilename: url.lastPathComponent) else { return nil }
            return (app, version)
        }
        let candidates = [(pid: currentPID, version: currentVersion)]
            + matching.map { (pid: $0.app.processIdentifier, version: $0.version) }
        guard preferredPID(candidates) == currentPID else {
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            return
        }
        for candidate in matching { _ = candidate.app.terminate() }
    }

    // Pure filename parsing: reading another bundle or its Info.plist can prompt for
    // external-volume access and must not be part of duplicate-process handling.
    static func version(fromBundleFilename filename: String) -> [Int]? {
        if filename == appPrefix + ".app" { return [0] }
        let prefix = appPrefix + "-", suffix = ".app"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let raw = filename.dropFirst(prefix.count).dropLast(suffix.count)
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var result = [Int]()
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else { return nil }
            result.append(value)
        }
        return result
    }

    static func preferredPID(_ candidates: [(pid: pid_t, version: [Int])]) -> pid_t? {
        candidates.max { lhs, rhs in
            if versionLess(lhs.version, rhs.version) { return true }
            if versionLess(rhs.version, lhs.version) { return false }
            // Deterministic ties prevent two concurrently launched copies from
            // each terminating the other. PID order is a stable tie-break, not launch time.
            return lhs.pid < rhs.pid
        }?.pid
    }

    static func versionLess(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
