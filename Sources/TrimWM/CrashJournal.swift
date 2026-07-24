import CoreGraphics
import Foundation

struct JournalEntry: Codable, Equatable, Sendable {
    let bootID: String
    let token: WindowToken
    let bundleID: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(bootID: String, token: WindowToken, bundleID: String, frame: CGRect) {
        self.bootID = bootID
        self.token = token
        self.bundleID = bundleID
        x = frame.minX; y = frame.minY; width = frame.width; height = frame.height
    }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct CrashJournal {
    let url: URL
    let bootID: String
    private(set) var entries: [WindowToken: JournalEntry] = [:]

    init(url: URL, bootID: String) {
        self.url = url
        self.bootID = bootID
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data) {
            for entry in decoded where entry.bootID == bootID && entries[entry.token] == nil {
                entries[entry.token] = entry
            }
        }
    }

    mutating func record(_ token: WindowToken, bundleID: String, frame: CGRect) throws {
        try record([JournalEntry(bootID: bootID, token: token, bundleID: bundleID, frame: frame)])
    }

    mutating func record(_ newEntries: [JournalEntry]) throws {
        var updated = entries
        var changed = false
        for entry in newEntries where updated[entry.token] == nil {
            updated[entry.token] = entry
            changed = true
        }
        guard changed else { return }
        try save(updated)
        entries = updated
    }

    mutating func remove(_ token: WindowToken) throws {
        var updated = entries
        guard updated.removeValue(forKey: token) != nil else { return }
        try save(updated)
        entries = updated
    }

    private func save(_ entries: [WindowToken: JournalEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries.values.sorted { $0.token < $1.token })
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
