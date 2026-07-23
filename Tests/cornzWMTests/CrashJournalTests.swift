import CoreGraphics
import Foundation
import XCTest
@testable import cornzWM

final class CrashJournalTests: XCTestCase {
    func testPersistsFirstVisibleFrameAndRemovesAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "journal.json")
        var journal = CrashJournal(url: url, bootID: "boot-a")
        let window = WindowToken(pid: 9, id: 4)
        let original = CGRect(x: 10, y: 20, width: 300, height: 400)
        try journal.record(window, bundleID: "example", frame: original)
        try journal.record(window, bundleID: "example", frame: .zero)
        XCTAssertEqual(CrashJournal(url: url, bootID: "boot-a").entries[window]?.frame, original)
        try journal.remove(window)
        XCTAssertTrue(CrashJournal(url: url, bootID: "boot-a").entries.isEmpty)
    }

    func testIgnoresEntriesFromAnotherBoot() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "journal.json")
        var journal = CrashJournal(url: url, bootID: "old")
        try journal.record(WindowToken(pid: 1, id: 1), bundleID: "example", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertTrue(CrashJournal(url: url, bootID: "new").entries.isEmpty)
    }

    func testFailedPersistenceDoesNotCommitMemoryState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = CrashJournal(url: directory.appending(path: "journal.json"), bootID: "boot")
        XCTAssertThrowsError(try journal.record(WindowToken(pid: 1, id: 1), bundleID: "app", frame: .zero))
        XCTAssertTrue(journal.entries.isEmpty)
    }

    func testDuplicatePersistedTokensDoNotCrashAndKeepFirstFrame() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "journal.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let token = WindowToken(pid: 1, id: 1)
        let frame = CGRect(x: 1, y: 2, width: 300, height: 400)
        let first = JournalEntry(bootID: "boot", token: token, bundleID: "app", frame: frame)
        let second = JournalEntry(bootID: "boot", token: token, bundleID: "app", frame: frame.offsetBy(dx: 20, dy: 20))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([first, second]).write(to: url)
        XCTAssertEqual(CrashJournal(url: url, bootID: "boot").entries[token]?.frame, frame)
    }

    func testFailedRemovalKeepsMemoryEntryForLaterRetry() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = parent.appending(path: "journal.json")
        let token = WindowToken(pid: 1, id: 1)
        var journal = CrashJournal(url: url, bootID: "boot")
        try journal.record(token, bundleID: "app", frame: .zero)
        try FileManager.default.removeItem(at: parent)
        try Data("not a directory".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertThrowsError(try journal.remove(token))
        XCTAssertNotNil(journal.entries[token])
    }
}
