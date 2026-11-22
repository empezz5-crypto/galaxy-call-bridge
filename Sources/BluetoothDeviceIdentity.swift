import Foundation

enum BluetoothDeviceIdentity {
    /// Canonical MAC-style identity for stable selection and duplicate suppression.
    static func normalizedAddress(_ address: String?) -> String? {
        guard let address else { return nil }
        let hex = address.filter(\.isHexDigit).uppercased()
        return hex.count == 12 ? hex : nil
    }

    static func id(address: String?, fallback: String) -> String {
        if let address = normalizedAddress(address) { return "mac:\(address)" }
        return "instance:\(fallback)"
    }

    /// Add the shortest useful suffix that distinguishes same-name devices.
    /// Full addresses remain internal and are never shown in the UI.
    static func uniqueDisplayHints(ids: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            guard id.hasPrefix("mac:") else { return (id, "항목 \(index + 1)") }
            let address = String(id.dropFirst(4))
            var length = min(4, address.count)
            while length < address.count && ids.contains(where: { other in
                other != id && other.hasPrefix("mac:") && other.suffix(length) == address.suffix(length)
            }) { length = min(length + 2, address.count) }
            return (id, "기기 끝자리 ··\(address.suffix(length))")
        })
    }

    static func uniqueByID<T>(_ values: [T], id: (T) -> String) -> [T] {
        var seen = Set<String>()
        return values.filter { seen.insert(id($0)).inserted }
    }
}


enum HFPEventLabels {
    static func callActive(_ value: Int?) -> String {
        guard let value else { return "활성 통화 상태 이벤트 미수신" }
        switch value {
        case 0: return "활성 통화 없음"
        case 1: return "활성 통화 있음"
        default: return "활성 통화 상태 알 수 없음 (값 \(value))"
        }
    }

    static func callSetup(_ value: Int?) -> String {
        guard let value else { return "통화 설정 이벤트 미수신" }
        switch value {
        case 0: return "통화 설정 없음"
        case 1: return "수신 통화 알림"
        case 2: return "발신 설정 중"
        case 3: return "상대방 호출 중"
        default: return "통화 설정 상태 알 수 없음 (값 \(value))"
        }
    }

    static func callHeld(_ value: Int?) -> String {
        guard let value else { return "보류 상태 이벤트 미수신" }
        switch value {
        case 0: return "보류 중인 통화 없음"
        case 1: return "활성 통화와 보류 통화 있음"
        case 2: return "활성 통화 없이 보류 통화 있음"
        default: return "보류 상태 알 수 없음 (값 \(value))"
        }
    }

    static func scoStatus(_ status: Int32) -> String {
        guard status != 0 else { return "SCO 링크 열림 · 양방향 음성 미검증" }
        let bits = UInt32(bitPattern: status)
        if bits == 0xE00002C7 {
            return "SCO 연결 거부: kIOReturnUnsupported (0xE00002C7)"
        }
        return String(format: "SCO 연결 실패 (IOReturn %d · 0x%08X)", status, bits)
    }
}
