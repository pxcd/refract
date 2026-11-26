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

    func testUnlinkKeepsOriginalAndAllowsReimport() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("portrait.safetensors")
        try writeAdapter(to: source)
        let expected = try Data(contentsOf: source)
        let store = ModelStore(directory: root, trash: { _ in
            XCTFail("A linked model must never be moved to Trash")
            return nil
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
        XCTAssertNil(store.removal(for: adapter))
        let entry = try XCTUnwrap(ModelStore.catalog.first { $0.canDownload })
        XCTAssertThrowsError(try store.remove(.init(model: adapter, target: source, entry: entry)))
        try store.unlink(adapter)
        XCTAssertEqual(try Data(contentsOf: source), expected)
        let reopened = ModelStore(directory: root)
        XCTAssertTrue(reopened.models.isEmpty)
        let reimported = try await reopened.importModel(at: source)
        XCTAssertEqual(reimported, adapter)
    }

    func testUnlinkLeavesRetargetedSymlinkAndBothWeightFiles() async throws {
        let root = try temporaryDirectory()
        let fm = FileManager.default
        let source = root.appendingPathComponent("original.safetensors")
        let alternate = root.appendingPathComponent("alternate.safetensors")
        let link = root.appendingPathComponent("linked.safetensors")
        try writeAdapter(to: source)
        try writeAdapter(to: alternate)
        let originalBytes = try Data(contentsOf: source)
        let alternateBytes = try Data(contentsOf: alternate)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        let store = ModelStore(directory: root)
        let model = try await store.importModel(at: link)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: alternate)
        try store.unlink(model)
        XCTAssertTrue(store.models.isEmpty)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), alternate.path)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try Data(contentsOf: alternate), alternateBytes)
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
            XCTAssertEqual(url.path, try ManagedModelDirectory.root(at: package, create: false).url.path)
            try FileManager.default.moveItem(at: url, to: trash)
            return trash
        })
        let marker = package.appendingPathComponent(".refract-managed-model")
        let removal = try XCTUnwrap(store.removal(for: model))
        XCTAssertThrowsError(try store.unlink(model))
        try "unrelated".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.remove(removal))
        try entry.provenanceID.write(to: marker, atomically: true, encoding: .utf8)
        let foreign = package.appendingPathComponent("my-original.png")
        try Data([42]).write(to: foreign)
        XCTAssertThrowsError(try store.remove(removal))
        XCTAssertEqual(try Data(contentsOf: foreign), Data([42]))
        XCTAssertEqual(store.models, [model])
        try FileManager.default.removeItem(at: foreign)
        try store.remove(removal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(file.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(ModelStore(directory: root).models.isEmpty)
    }

    func testSeparateStoresMergeImportsAndUnlinksOnDisk() async throws {
        let root = try temporaryDirectory()
        let first = ModelStore(directory: root)
        let second = ModelStore(directory: root)
        let firstURL = root.appendingPathComponent("first.safetensors")
        let secondURL = root.appendingPathComponent("second.safetensors")
        try writeAdapter(to: firstURL)
        var alternate = try Data(contentsOf: firstURL)
        alternate[alternate.count - 1] = 1
        try alternate.write(to: secondURL)
        let firstModel = try await first.importModel(at: firstURL)
        let secondModel = try await second.importModel(at: secondURL)
        XCTAssertEqual(Set(second.models.map(\.id)), [firstModel.id, secondModel.id])
        try first.unlink(firstModel)
        XCTAssertEqual(ModelStore(directory: root).models, [secondModel])
        XCTAssertThrowsError(try second.unlink(firstModel))
    }

    func testPackageBindingSurvivesReopenAndDistinguishesInstallations() throws {
        let root = try ManagedModelDirectory.root(at: temporaryDirectory())
        let first = try root.child("first", create: true).identity()
        let second = try root.child("second", create: true).identity()
        let persisted = try JSONDecoder().decode(ManagedPackageIdentity.self, from: JSONEncoder().encode(first))
        XCTAssertTrue(try persisted.matches(root.child("first").identity()))
        XCTAssertFalse(persisted.matches(second))
    }

    func testPackageLeaseProtectsCancellationUntilReleased() throws {
        let root = try temporaryDirectory()
        let store = ModelStore(directory: root)
        let entry = try XCTUnwrap(ModelStore.catalog.first { $0.canDownload })
        let packages = try ManagedModelDirectory.root(at: store.modelDirectory).child("Refract Packages", create: true)
        let partial = try packages.child(".\(entry.id).partial", create: true)
        let marker = try partial.file(".refract-managed-model", writing: true, create: true)
        try marker.write(contentsOf: Data(entry.provenanceID.utf8))
        try marker.close()
        let lease = try packages.lock(".\(entry.id).lock")
        XCTAssertThrowsError(try store.cancelDownload(entry))
        XCTAssertTrue(store.hasPartialDownload(entry))
        try lease.close()
        try store.cancelDownload(entry)
        XCTAssertFalse(store.hasPartialDownload(entry))
    }

    func testCatalogRowsKeepIdentityWhenModelsBecomeAvailable() throws {
        let juggernaut = try XCTUnwrap(ModelStore.catalog.first { $0.id == "juggernaut-xi" })
        let zImage = try XCTUnwrap(ModelStore.catalog.first { $0.id == "z-image-turbo-q4" })
        XCTAssertFalse(juggernaut.canDownload)
        XCTAssertNotNil(juggernaut.checkpointFile)
        let linked = StudioModel(id: juggernaut.identity + "+config", name: "My Juggernaut", kind: .generation,
                                 path: "/unused/juggernaut.safetensors", variant: juggernaut.variant, configPath: "/unused",
                                 precision: "FP16", license: juggernaut.license, bytes: 1, managed: false)
        let installed = StudioModel(id: zImage.identity, name: zImage.name, kind: .generation,
                                    path: "/unused/z-image", variant: zImage.variant, configPath: nil,
                                    precision: zImage.precision, license: zImage.license, bytes: 1, managed: true)
        let lora = StudioModel(id: "local-adapter", name: "My LoRA", kind: .lora, path: "/unused/lora.safetensors",
                               variant: "sdxl-lora", configPath: nil, precision: "FP16", license: "Custom",
                               bytes: 1, managed: false)
        let entries = [juggernaut, zImage]
        let before = ModelCatalogRow.make(catalog: entries, localModels: [lora])
        let after = ModelCatalogRow.make(catalog: entries, localModels: [linked, installed, lora])
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(after.first { $0.id == .curated(juggernaut.id) }?.model, linked)
        XCTAssertEqual(after.first { $0.id == .curated(zImage.id) }?.model, installed)
        XCTAssertEqual(after.first { $0.id == .local(lora.id) }?.kind, .lora)
    }

    func testCancelInterruptedDownloadOnlyDiscardsOwnedPartialFiles() throws {
        let root = try temporaryDirectory()
        let entry = try XCTUnwrap(ModelStore.catalog.first { $0.id == "sdxl-base-1-0" })
        let store = ModelStore(directory: root)
        let fm = FileManager.default
        let packages = store.modelDirectory.appendingPathComponent("Refract Packages")
        let installed = packages.appendingPathComponent(entry.id)
        let staging = packages.appendingPathComponent(".\(entry.id).partial")
        for directory in [staging, installed] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent(try XCTUnwrap(entry.checkpointFile).path))
        }
        let marker = staging.appendingPathComponent(".refract-managed-model")
        try "unrelated".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.cancelDownload(entry))

        try entry.provenanceID.write(to: marker, atomically: true, encoding: .utf8)
        let foreign = staging.appendingPathComponent("user-image.png")
        try Data([42]).write(to: foreign)
        XCTAssertThrowsError(try store.cancelDownload(entry))
        XCTAssertEqual(try Data(contentsOf: foreign), Data([42]))
        try fm.removeItem(at: foreign)

        let restored = ModelStore(directory: root)
        XCTAssertTrue(restored.hasPartialDownload(entry))
        try restored.cancelDownload(entry)
        XCTAssertFalse(restored.hasPartialDownload(entry))
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        XCTAssertTrue(fm.fileExists(atPath: installed.path))
        XCTAssertNil(restored.downloads[entry.id])
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
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let transfer = ModelTransfer(output: output, received: 3, size: 6, progress: { _ in })
            let response = try XCTUnwrap(HTTPURLResponse(url: address, statusCode: status, httpVersion: "HTTP/1.1",
                                                         headerFields: range.isEmpty ? [:] : ["Content-Range": range]))
            transfer.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, disposition) }
            if disposition == .allow { transfer.urlSession(session, dataTask: task, didReceive: Data(data.utf8)) }
            transfer.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(try Data(contentsOf: destination), Data((disposition == .allow ? "abcdef" : "abc").utf8))
        }
    }
}
