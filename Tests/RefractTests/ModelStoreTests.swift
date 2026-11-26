import Foundation
import XCTest
@testable import Refract

@MainActor
final class ModelStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeAdapter(to url: URL) throws {
        let header = Data(#"{"lora_unet_x.lora_down.weight":{"dtype":"F16","shape":[1,1],"data_offsets":[0,2]},"lora_unet_x.lora_up.weight":{"dtype":"F16","shape":[1,1],"data_offsets":[2,4]}}"#.utf8)
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        data.append(Data(count: 4))
        try data.write(to: url)
    }

    func testWrongKindImportAndMoveExternalWeightsToTrash() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("portrait.safetensors")
        try writeAdapter(to: source)
        let expected = try Data(contentsOf: source)
        let trash = root.appendingPathComponent("isolated-trash.safetensors")
        let store = ModelStore(directory: root, trash: { path in
            try FileManager.default.moveItem(at: path, to: trash)
            return trash
        })
        for kind in [ModelKind.generation, .enhancement] {
            do {
                try await store.importModel(at: source, kind: kind)
                XCTFail("Accepted an adapter as \(kind)")
            } catch is ModelError { }
        }
        XCTAssertTrue(store.models.isEmpty)
        let adapter = try await store.importModel(at: source)
        XCTAssertEqual(adapter.kind, .lora)
        XCTAssertEqual(adapter.path, source.path)
        XCTAssertFalse(adapter.managed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory.path))
        let removal = store.removal(for: adapter)
        XCTAssertFalse(removal.followsLink)
        try store.remove(removal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: trash), expected)
        XCTAssertTrue(ModelStore(directory: root).models.isEmpty)
    }

    func testLinkedModelTrashUsesConfirmedTargetAndRejectsRetargeting() async throws {
        let root = try temporaryDirectory()
        let fm = FileManager.default
        let source = root.appendingPathComponent("original.safetensors")
        let alternate = root.appendingPathComponent("alternate.safetensors")
        let link = root.appendingPathComponent("linked.safetensors")
        let trash = root.appendingPathComponent("isolated-trash.safetensors")
        try writeAdapter(to: source)
        try writeAdapter(to: alternate)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        let store = ModelStore(directory: root, trash: { path in
            try fm.moveItem(at: path, to: trash)
            return trash
        })
        let imported = try await store.importModel(at: link)
        let removal = store.removal(for: imported)
        XCTAssertTrue(removal.followsLink)
        XCTAssertEqual(removal.target, source.resolvingSymlinksInPath())
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: alternate)
        XCTAssertThrowsError(try store.remove(removal))
        XCTAssertTrue(fm.fileExists(atPath: alternate.path))
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        try store.remove(removal)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertTrue(fm.fileExists(atPath: trash.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), source.path)
    }

    func testManagedCheckpointRemovalChecksOwnershipAndMovesWholePackage() throws {
        let root = try temporaryDirectory()
        let entry = try XCTUnwrap(ModelStore.catalog.first { $0.id == "sdxl-base-1-0" })
        let package = root.appendingPathComponent("Models/Refract Packages/" + entry.id)
        let file = package.appendingPathComponent(try XCTUnwrap(entry.checkpointFile).path)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        // A damaged managed checkpoint must still be removable. Ownership comes from the catalog and package marker.
        try Data([1]).write(to: file)
        let model = StudioModel(id: entry.identity, name: entry.name, kind: .generation, path: file.path, variant: entry.variant,
                                configPath: nil, precision: entry.precision, license: entry.license, bytes: 1, managed: true)
        struct Index: Encodable { let models: [StudioModel]; let modelDirectory: URL; let dismissedPaths: [String] }
        let index = Index(models: [model], modelDirectory: root.appendingPathComponent("Models"), dismissedPaths: [])
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("model-index.json"))
        let trash = root.appendingPathComponent("isolated-trash")
        let store = ModelStore(directory: root, trash: { url in
            XCTAssertEqual(url.path, package.path)
            try FileManager.default.moveItem(at: url, to: trash)
            return trash
        })
        let marker = package.appendingPathComponent(".refract-managed-model")
        try "unrelated".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.remove(store.removal(for: model)))
        try entry.provenanceID.write(to: marker, atomically: true, encoding: .utf8)
        let foreign = package.appendingPathComponent("my-original.png")
        try Data([42]).write(to: foreign)
        XCTAssertThrowsError(try store.remove(store.removal(for: model)))
        XCTAssertEqual(try Data(contentsOf: foreign), Data([42]))
        XCTAssertEqual(store.models, [model])
        try FileManager.default.removeItem(at: foreign)
        try store.remove(store.removal(for: model))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(file.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(ModelStore(directory: root).models.isEmpty)
    }

    func testResumeAppendsOnlyMatchingRangeAndRestartsOnFullResponse() throws {
        let root = try temporaryDirectory()
        let address = URL(string: "https://example.invalid/weight")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: address)
        let destination = root.appendingPathComponent("weight.partial")
        for (status, range, disposition, data) in [(206, "bytes 3-5/6", URLSession.ResponseDisposition.allow, "def"),
                                                  (206, "bytes 1-3/6", .cancel, ""), (200, "", .allow, "abcdef")] {
            try Data("abc".utf8).write(to: destination)
            let transfer = ModelTransfer(destination: destination, received: 3, size: 6, progress: { _ in })
            let response = try XCTUnwrap(HTTPURLResponse(url: address, statusCode: status, httpVersion: "HTTP/1.1",
                                                         headerFields: range.isEmpty ? [:] : ["Content-Range": range]))
            transfer.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, disposition) }
            if disposition == .allow { transfer.urlSession(session, dataTask: task, didReceive: Data(data.utf8)) }
            transfer.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(try Data(contentsOf: destination), Data((disposition == .allow ? "abcdef" : "abc").utf8))
        }
    }
}
