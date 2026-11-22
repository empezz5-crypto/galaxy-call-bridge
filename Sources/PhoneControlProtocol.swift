import Foundation

enum CallPhase:String,Codable { case idle, dialing, ringing, active, unknown
    var label:String { switch self { case .idle:return "전화를 걸어보세요"; case .dialing:return "발신 중 · 연결 신호 대기"; case .ringing:return "전화가 왔어요"; case .active:return "통화 중"; case .unknown:return "Galaxy 연결을 확인하세요" } }
}
struct PhoneControlReply:Decodable {
    let ok:Bool
    let state:CallPhase?
    let canDial:Bool?
    let canAnswer:Bool?
    let canEnd:Bool?
    let build:String?
    let error:String?
    let calls:[PhoneCallHistoryItem]?
    /// Only present while ringing; null/absent when Android cannot determine the caller.
    let incomingNumber:String?
    let incomingName:String?
}
/// Caller text for the incoming card; never logged or persisted.
enum CallerDisplay {
    static func label(name:String?,number:String?) -> String? {
        if let n=clean(name) { return n }
        guard let digits=clean(number) else { return nil }
        if digits.count==11, digits.hasPrefix("010"), digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(4))-\(digits.suffix(4))"
        }
        return digits
    }
    private static func clean(_ value:String?) -> String? {
        guard let value else { return nil }
        let t=String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64)).trimmingCharacters(in:.whitespaces)
        return t.isEmpty ? nil : t
    }
}
struct PhoneCallHistoryItem:Codable,Identifiable,Hashable {
    let id:Int64
    let number:String?
    let name:String?
    let date:Int64
    let duration:Int64
    let type:Int
    var timestamp:Date { Date(timeIntervalSince1970:Double(date)/1000) }
    var label:String { switch type { case 1:return "수신"; case 2:return "발신"; case 3,5,6:return "부재중"; default:return "통화" } }
}
enum PhoneNumberRules {
    static func normalize(_ value:String) -> String? {
        let allowed=CharacterSet(charactersIn:"+0123456789 ()-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let n=value.filter { !" ()-".contains($0) }
        let digits=n.hasPrefix("+") ? String(n.dropFirst()) : n
        guard (3...32).contains(digits.count), n.count<=32, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return n
    }
}
