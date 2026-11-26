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

    func testWrongKindImportAndExternalRemovalPreserveWeights() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("portrait.safetensors")
        try writeAdapter(to: source)
        let expected = try Data(contentsOf: source)
        let store = ModelStore(directory: root, trash: { _ in XCTFail("External model went to Trash"); return nil })
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
        try store.remove(adapter)
        XCTAssertEqual(try Data(contentsOf: source), expected)
        XCTAssertTrue(ModelStore(directory: root).models.isEmpty)
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
        XCTAssertThrowsError(try store.remove(model))
        try entry.provenanceID.write(to: marker, atomically: true, encoding: .utf8)
        let foreign = package.appendingPathComponent("my-original.png")
        try Data([42]).write(to: foreign)
        XCTAssertThrowsError(try store.remove(model))
        XCTAssertEqual(try Data(contentsOf: foreign), Data([42]))
        XCTAssertEqual(store.models, [model])
        try FileManager.default.removeItem(at: foreign)
        try store.remove(model)
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
