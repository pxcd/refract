import Foundation
import XCTest
@testable import Refract

final class RuntimeScratchTests: XCTestCase {
    func testReclaimsAbandonedSessionsWhilePreservingActiveAndUnrelatedItems() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }

        let active = try RuntimeScratch(temporaryDirectory: temporary)
        let work = try active.makeDirectory()
        let input = work.appendingPathComponent("reference.png")
        try Data([1, 2, 3]).write(to: input)
        let session = work.deletingLastPathComponent().deletingLastPathComponent()
        let root = session.deletingLastPathComponent()

        // A copied session has the same on-disk layout without the original process's open lock.
        let abandoned = root.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try fm.copyItem(at: session, to: abandoned)
        let unrelated = root.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let userFile = unrelated.appendingPathComponent("keep.txt")
        try Data([4]).write(to: userFile)
        let foreign = root.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try fm.copyItem(at: session, to: foreign)
        try Data([5]).write(to: foreign.appendingPathComponent("unexpected.txt"))
        let link = root.appendingPathComponent("run-" + UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)

        var other: RuntimeScratch? = try RuntimeScratch(temporaryDirectory: temporary)
        XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: input), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: userFile), Data([4]))
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("unexpected.txt")), Data([5]))
        XCTAssertNoThrow(try fm.destinationOfSymbolicLink(atPath: link.path))
        let owned = try XCTUnwrap(other).makeDirectory()
        other = nil
        XCTAssertFalse(fm.fileExists(atPath: owned.path))
        withExtendedLifetime(active) {}
    }
}
