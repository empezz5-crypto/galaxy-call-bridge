import Foundation
@main struct Checks {
 static func main() throws {
    precondition(PhoneNumberRules.normalize("010-1234-5678")=="01012345678")
    precondition(PhoneNumberRules.normalize("+82 (10) 1234-5678")=="+821012345678")
    for bad in ["", "*#06#", "tel:01012345678", "123\n456", "++821234", "010;anything", String(repeating:"1",count:40)] { precondition(PhoneNumberRules.normalize(bad)==nil) }
    let reply=try JSONDecoder().decode(PhoneControlReply.self,from:Data("{\"ok\":true,\"state\":\"ringing\",\"canDial\":true,\"canAnswer\":true,\"canEnd\":true,\"build\":\"20261013-050-r2\"}".utf8))
    precondition(reply.state == .ringing && reply.canAnswer == true)
    let unavailable=try JSONDecoder().decode(PhoneControlReply.self,from:Data("{\"ok\":false,\"error\":\"UNSUPPORTED\"}".utf8))
    precondition(!unavailable.ok && unavailable.state==nil)
    let ringing=try JSONDecoder().decode(PhoneControlReply.self,from:Data("{\"ok\":true,\"state\":\"ringing\",\"build\":\"x\",\"incomingNumber\":\"01012345678\",\"incomingName\":null}".utf8))
    precondition(ringing.incomingNumber=="01012345678" && ringing.incomingName==nil)
    let unknownCaller=try JSONDecoder().decode(PhoneControlReply.self,from:Data("{\"ok\":true,\"state\":\"ringing\",\"incomingNumber\":null}".utf8))
    precondition(unknownCaller.incomingNumber==nil && CallerDisplay.label(name:unknownCaller.incomingName,number:unknownCaller.incomingNumber)==nil)
    precondition(reply.incomingNumber==nil, "older Android builds omit the fields")
    precondition(CallerDisplay.label(name:nil,number:"01012345678")=="010-1234-5678")
    precondition(CallerDisplay.label(name:"홍길동",number:"01012345678")=="홍길동")
    precondition(CallerDisplay.label(name:"  ",number:"+821012345678")=="+821012345678")
    precondition(CallerDisplay.label(name:nil,number:"")==nil)
    precondition(CallerDisplay.label(name:nil,number:"12\n3")=="123")
    print("PASS caller number decode/display fallback")
    print("PASS phone number normalization/rejection and control state parsing; no call action invoked")
 }
}
