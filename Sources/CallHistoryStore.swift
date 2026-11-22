import Foundation

/// Keeps only the latest 200 phone call metadata records in a private local file.
struct CallHistoryStore {
    private let file:URL
    private let privateDirectory:Bool
    init(fileManager:FileManager = .default) {
        let root=(try? fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        let directory=root.appendingPathComponent("GalaxyCallBridge",isDirectory:true)
        file=directory.appendingPathComponent("call-history.json")
        do {
            try fileManager.createDirectory(at:directory,withIntermediateDirectories:true)
            try fileManager.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
            privateDirectory=true
        } catch { privateDirectory=false }
    }
    func load() -> [PhoneCallHistoryItem] {
        guard let data=try? Data(contentsOf:file),let rows=try? JSONDecoder().decode([PhoneCallHistoryItem].self,from:data) else { return [] }
        return Array(rows.sorted{$0.date>$1.date}.prefix(200))
    }
    func save(_ rows:[PhoneCallHistoryItem]) -> Bool {
        guard privateDirectory,let data=try? JSONEncoder().encode(Array(rows.sorted{$0.date>$1.date}.prefix(200))) else { return false }
        do {
            try data.write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            return true
        } catch { try? FileManager.default.removeItem(at:file);return false }
    }
    func clear() -> Bool {
        do { if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) };return true }
        catch { return false }
    }
}
