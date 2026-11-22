import Foundation
enum AudioWire {
    static let magic: UInt32 = 0x47434231
    static let headerSize = 8, maxPayload = 640
    enum Kind: UInt16 { case hello = 1, status = 2, silence = 0x20, silenceResult = 0x21, diagnosticError = 0x22, startDownlink = 0x30, downlinkPCM = 0x31, startUplink = 0x32, uplinkPCM = 0x33, stop = 0x34, startDuplex = 0x35 }
    static func serviceIdentity(_ payload: Data) -> String? {
        guard let text=String(data:payload,encoding:.utf8),
              text.range(of: "^GCB1_ANDROID_PCM_V1;build=20261031-059-r1;pid=[0-9]+;started=[0-9]+;session=[0-9a-f]+$",options:.regularExpression) != nil else { return nil }
        return text
    }
    static func encode(_ kind: Kind, _ payload: Data = Data()) throws -> Data {
        guard payload.count <= maxPayload else { throw WireError.invalid }
        var d = Data(); append(magic, &d); append(kind.rawValue, &d); append(UInt16(payload.count), &d); d.append(payload); return d
    }
    static func decode(_ d: Data) throws -> (Kind, Data) {
        guard d.count >= headerSize, u32(d,0) == magic, let k = Kind(rawValue:u16(d,4)) else { throw WireError.invalid }
        let n = Int(u16(d,6)); guard n <= maxPayload, d.count == headerSize+n else { throw WireError.invalid }
        return (k, d.subdata(in:headerSize..<d.count))
    }
    private static func append<T: FixedWidthInteger>(_ x:T,_ d:inout Data) { var v=x.bigEndian; withUnsafeBytes(of:&v){ d.append(contentsOf:$0) } }
    private static func u16(_ d:Data,_ i:Int)->UInt16 { UInt16(d[i])<<8 | UInt16(d[i+1]) }
    private static func u32(_ d:Data,_ i:Int)->UInt32 { UInt32(d[i])<<24 | UInt32(d[i+1])<<16 | UInt32(d[i+2])<<8 | UInt32(d[i+3]) }
    enum WireError:Error { case invalid }
}
