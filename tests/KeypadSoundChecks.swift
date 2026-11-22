import AppKit
@main struct KeypadSoundChecks {
 @MainActor static func main() {
  var tones=Set<Data>()
  for key in "123456789*0#" {
   guard let data=KeypadSound.wave(String(key)), let sound=NSSound(data:data) else { fatalError("invalid tone") }
   precondition(data.count==7982 && sound.duration>0.08 && sound.duration<0.1)
   tones.insert(data)
  }
  precondition(tones.count==12 && KeypadSound.wave("x")==nil && KeypadSound.wave("")==nil)
  print("PASS 12 distinct decodable 90ms keypad sounds; no playback or calls")
 }
}
