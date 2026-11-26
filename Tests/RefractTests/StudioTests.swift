import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Refract

private func writeImage(_ destination: URL, width: Int, height: Int) throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.42, green: 0.52, blue: 0.72, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

@MainActor private final class TestClient: InferenceClient {
    var requests: [InferenceRequest] = []
    var failAt: Int?
    var onRender: ((InferenceRequest) throws -> Void)?
    func render(_ request: InferenceRequest, progress: @escaping (Double?, String) -> Void) async throws {
        requests.append(request)
        try onRender?(request)
        if failAt == requests.count { throw StudioError("Intentional test interruption") }
        try await Task.sleep(nanoseconds: 10_000_000)
        progress(0.7, "Rendering")
        try writeImage(URL(fileURLWithPath: request.outputPath), width: request.width, height: request.height)
    }
    func stop() {}
}

final class StudioTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func checkpoint(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("fixture.safetensors")
        let tensors: [(String,[Int])] = [
            ("model.diffusion_model.input_blocks.0.0.weight",[320,4,3,3]),
            ("model.diffusion_model.label_emb.0.0.weight",[1280,2816]),
            ("conditioner.embedders.0.test",[1]), ("conditioner.embedders.1.test",[1]), ("first_stage_model.test",[1])
        ]
        var index: [String:Any] = [:], bytes = 0
        for (key, shape) in tensors {
            let end = bytes + shape.reduce(2,*)
            index[key] = ["dtype":"F16","shape":shape,"data_offsets":[bytes,end]] as [String:Any]
            bytes = end
        }
        let header = try JSONSerialization.data(withJSONObject:index)
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of:&length) { Data($0) }
        data.append(header)
        data.append(Data(count:bytes))
        try data.write(to:url)
        return url
    }

    @MainActor func testSnapshotPartialFailureRetryAndPreserveSource() async throws {
        let root = try temporary(), models = ModelStore(directory:root), client = TestClient()
        let source = try checkpoint(root)
        let checkpoint = try await models.importModel(at: source)
        XCTAssertEqual(checkpoint.kind, .generation)
        XCTAssertEqual(checkpoint.path, source.path)
        XCTAssertFalse(checkpoint.managed)
        let defaults = isolatedDefaults()
        let studio = StudioStore(models: models, worker: client, directory: root, defaults: defaults)
        studio.outputDirectory = root.appendingPathComponent("outputs")
        studio.generation.prompt = "First recipe"
        studio.generation.count = 3
        studio.generation.seed = 57
        studio.generation.width = 64
        studio.generation.height = 64
        client.failAt = 2
        studio.generate()
        studio.generation.prompt = "Another recipe"
        try await wait(studio)
        let failed = try XCTUnwrap(studio.jobs.first)
        XCTAssertEqual(failed.status,.failed)
        XCTAssertEqual(failed.results.count,1)
        let firstFile = try Data(contentsOf: failed.results[0].original)
        studio.retry(failed.id)
        try await wait(studio)
        let final = try XCTUnwrap(studio.jobs.first)
        XCTAssertEqual(final.status,.completed, final.message)
        XCTAssertEqual(final.results.count,3)
        XCTAssertEqual(client.requests.map(\.seed),[57,58,58,59])
        XCTAssertTrue(client.requests.allSatisfy { $0.prompt == "First recipe" })
        XCTAssertEqual(try Data(contentsOf: final.results[0].original),firstFile)
        XCTAssertTrue(final.results.allSatisfy { FileManager.default.fileExists(atPath:$0.original.appendingPathExtension("json").path) })
        let restored = StudioStore(models:models,worker:TestClient(),directory:root,defaults:defaults)
        XCTAssertEqual(restored.jobs.first?.results.count,3)
    }

    @MainActor func testRetryAfterQueueCheckpointWasInterrupted() async throws {
        let root = try temporary(), models = ModelStore(directory:root)
        try await models.importModel(at:checkpoint(root),kind:.generation)
        let defaults = isolatedDefaults()
        let first = StudioStore(models:models,worker:TestClient(),directory:root,defaults:defaults)
        first.outputDirectory = root.appendingPathComponent("images")
        first.generation.prompt = "Recover this image"
        first.generation.width = 64
        first.generation.height = 64
        first.generate()
        try await wait(first)
        let queue = root.appendingPathComponent("jobs.json")
        var journal = try JSONDecoder().decode([StudioJob].self,from:Data(contentsOf:queue))
        let published = try XCTUnwrap(journal.first?.results.first?.original)
        journal[0].status = .running
        journal[0].results = []
        try JSONEncoder().encode(journal).write(to:queue,options:.atomic)
        let client = TestClient()
        let restored = StudioStore(models:models,worker:client,directory:root,defaults:defaults)
        XCTAssertEqual(restored.jobs.first?.status,.failed)
        restored.retry(journal[0].id)
        try await wait(restored)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(restored.jobs.first?.results.first?.original,published)
        // A process may also exit after publishing just the companion receipt.
        try FileManager.default.removeItem(at:published)
        try JSONEncoder().encode(journal).write(to:queue,options:.atomic)
        let secondClient = TestClient()
        let second = StudioStore(models:models,worker:secondClient,directory:root,defaults:defaults)
        second.retry(journal[0].id)
        try await wait(second)
        XCTAssertEqual(second.jobs.first?.status,.completed)
        XCTAssertEqual(secondClient.requests.count,1)
    }

    @MainActor func testTrashGeneratedResultRollsBackAndStaysTrashedOnRetry() async throws {
        let root = try temporary(), models = ModelStore(directory: root)
        try await models.importModel(at: checkpoint(root))
        let client = TestClient()
        client.failAt = 2
        let defaults = isolatedDefaults()
        let store = StudioStore(models: models, worker: client, directory: root, defaults: defaults)
        store.outputDirectory = root.appendingPathComponent("images")
        store.generation.prompt = "Trash the first image"
        store.generation.width = 64
        store.generation.height = 64
        store.generation.seed = 51
        store.generation.count = 2
        store.generate()
        try await wait(store)
        let job = try XCTUnwrap(store.jobs.first)
        let discarded = try XCTUnwrap(job.results.first)
        let originalReceipt = discarded.original.appendingPathExtension("json")
        XCTAssertThrowsError(try store.trashGeneratedResult(discarded.id) { _ in throw StudioError("Trash unavailable") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: discarded.original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalReceipt.path))
        XCTAssertEqual(store.jobs.first?.results.count, 1)
        let trash = root.appendingPathComponent("test-trash")
        try store.trashGeneratedResult(discarded.id) { try FileManager.default.moveItem(at: $0, to: trash) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)),
                       [discarded.original.lastPathComponent, originalReceipt.lastPathComponent])
        let retryClient = TestClient()
        let reopened = StudioStore(models: models, worker: retryClient, directory: root, defaults: defaults)
        reopened.retry(job.id)
        try await wait(reopened)
        XCTAssertEqual(retryClient.requests.map(\.seed), [52])
        XCTAssertEqual(reopened.jobs.first?.results.map(\.seed), [52])
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.original.path))
    }

    @MainActor func testClearFilmstripKeepsFilesAndJobHistoryAcrossRelaunch() async throws {
        let root = try temporary(), models = ModelStore(directory: root)
        try await models.importModel(at: checkpoint(root))
        let defaults = isolatedDefaults()
        let store = StudioStore(models: models, worker: TestClient(), directory: root, defaults: defaults)
        store.outputDirectory = root.appendingPathComponent("images")
        store.generation.prompt = "Keep the source image"
        store.generation.width = 64
        store.generation.height = 64
        store.generate()
        try await wait(store)
        let first = try XCTUnwrap(store.jobs.first?.results.first)
        let bytes = try Data(contentsOf: first.original)
        store.clearFilmstrip(generated: true)
        XCTAssertTrue(try XCTUnwrap(store.jobs.first).filmstripResults.isEmpty)
        XCTAssertNil(store.selectedResult)
        let reopened = StudioStore(models: models, worker: TestClient(), directory: root, defaults: defaults)
        XCTAssertEqual(reopened.jobs.first?.results, [first])
        XCTAssertTrue(try XCTUnwrap(reopened.jobs.first).filmstripResults.isEmpty)
        XCTAssertEqual(try Data(contentsOf: first.original), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.original.appendingPathExtension("json").path))

        reopened.generation = store.generation
        reopened.generate()
        try await wait(reopened)
        XCTAssertEqual(reopened.jobs.flatMap(\.filmstripResults).count, 1)
        XCTAssertEqual(reopened.jobs.flatMap(\.results).count, 2)
    }

    @MainActor func testUnreadableQueueSurvivesQuit() throws {
        let root = try temporary(), file = root.appendingPathComponent("jobs.json"), damaged = Data("damaged".utf8)
        try damaged.write(to:file)
        let store = StudioStore(models:ModelStore(directory:root),worker:TestClient(),directory:root,defaults:isolatedDefaults())
        XCTAssertNotNil(store.notice)
        store.shutdown()
        XCTAssertEqual(try Data(contentsOf:file),damaged)
    }

    @MainActor func testSaveAsPreservesExistingSidecar() throws {
        let root = try temporary()
        let studio = StudioStore(models: ModelStore(directory: root), worker: TestClient(), directory: root, defaults: isolatedDefaults())
        let source = root.appendingPathComponent("original.png")
        try writeImage(source, width: 80, height: 64)
        let output = root.appendingPathComponent("manual-name.jpg")
        let sidecar = output.appendingPathExtension("json")
        let existing = Data("other image settings".utf8)
        try existing.write(to: sidecar)
        XCTAssertThrowsError(try studio.save(source, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: sidecar), existing)
        try FileManager.default.removeItem(at: sidecar)
        try studio.save(source, to: output)
        XCTAssertEqual(try ImageFiles.dimensions(of: output).0, 80)
    }

    @MainActor func testReferenceSnapshotSurvivesEditDuringBatch() async throws {
        let root = try temporary(), catalog = ModelStore(directory: root), client = TestClient()
        try await catalog.importModel(at: checkpoint(root), kind: .generation)
        let original = root.appendingPathComponent("reference.png")
        try writeImage(original, width: 81, height: 65)
        let bytes = try Data(contentsOf: original)
        client.onRender = { request in
            let workerInput = URL(fileURLWithPath: try XCTUnwrap(request.inputPath))
            XCTAssertNotEqual(workerInput, original)
            XCTAssertEqual(try Data(contentsOf: workerInput), bytes)
            XCTAssertEqual(request.width, 81)
            XCTAssertEqual(request.height, 65)
            XCTAssertEqual(request.preserveReferenceSize, true)
            if client.requests.count == 1 { try writeImage(original, width: 96, height: 64) }
        }
        defer { client.onRender = nil }
        let studio = StudioStore(models: catalog, worker: client, directory: root, defaults: isolatedDefaults())
        studio.outputDirectory = root.appendingPathComponent("images")
        studio.generation.prompt = "Test the same reference twice"
        studio.generation.reference = original
        studio.generation.preserveReferenceSize = true
        studio.generation.count = 2
        studio.generate()
        try await wait(studio)
        XCTAssertEqual(studio.jobs.first?.status, .completed)
        XCTAssertEqual(client.requests.count, 2)
        let result = try XCTUnwrap(studio.jobs.first?.results.first?.original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.appendingPathExtension("json"))) as? [String: Any])
        XCTAssertEqual((json["request"] as? [String: Any])?["inputPath"] as? String, original.path)
    }

    @MainActor func testCancelPendingAndRunningJob() async throws {
        let root = try temporary(), catalog = ModelStore(directory:root), client = TestClient()
        try await catalog.importModel(at:checkpoint(root),kind:.generation)
        let store = StudioStore(models:catalog,worker:client,directory:root,defaults:isolatedDefaults())
        store.outputDirectory = root.appendingPathComponent("images")
        store.generation.prompt = "Cancel this batch"
        store.generation.width = 64
        store.generation.height = 64
        store.generation.count = 5
        store.generate()
        let first = try XCTUnwrap(store.jobs.first?.id)
        store.generate()
        let second = try XCTUnwrap(store.jobs.first?.id)
        store.cancel(second)
        let deadline = Date().addingTimeInterval(5)
        while client.requests.count < 2 && Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertEqual(store.jobs.first(where: { $0.id == first })?.status, .running)
        store.cancel(first)
        try await Task.sleep(nanoseconds:60_000_000)
        XCTAssertTrue(store.jobs.allSatisfy { $0.status == .cancelled })
        XCTAssertEqual(store.jobs.first(where: { $0.id == first })?.results.count,1)
        XCTAssertEqual(store.jobs.first(where: { $0.id == second })?.results.count,0)
        store.retry(second)
        try await wait(store)
        XCTAssertEqual(store.jobs.first?.results.count,5)
    }

    @MainActor func testProgressCountsQueuedGenerationBatches() async throws {
        let root = try temporary(), models = ModelStore(directory: root), client = TestClient()
        try await models.importModel(at: checkpoint(root))
        let store = StudioStore(models: models, worker: client, directory: root, defaults: isolatedDefaults())
        store.outputDirectory = root.appendingPathComponent("images")
        store.generation.prompt = "Queue counter"
        store.generation.width = 64
        store.generation.height = 64
        var progress: [String] = []
        client.onRender = { _ in
            let job = try XCTUnwrap(store.jobs.first { $0.status == .running })
            let position = try XCTUnwrap(store.generationBatchPosition(for: job))
            XCTAssertTrue(job.message.hasPrefix("Generating ·"))
            progress.append("\(position.current)/\(position.total)")
        }
        for _ in 1...3 { store.generate() }
        try await wait(store)
        XCTAssertEqual(progress, ["1/3", "2/3", "3/3"])

        client.onRender = { _ in
            let job = try XCTUnwrap(store.jobs.first { $0.status == .running })
            XCTAssertNil(store.generationBatchPosition(for: job))
        }
        defer { client.onRender = nil }
        store.generate()
        try await wait(store)
        XCTAssertEqual(store.jobs.first?.status, .completed)
    }

    func testImageGeometryAndExports() throws {
        let root = try temporary(), input = root.appendingPathComponent("original.png")
        try writeImage(input,width:13,height:17)
        var options = EnhancementOptions()
        XCTAssertEqual(try ImageFiles.outputDimensions(for:input,options:options).0,26)
        options.customLongEdge = 51
        XCTAssertEqual(try ImageFiles.outputDimensions(for:input,options:options).0,39)
        for format in [ExportFormat.jpeg,.tiff,.png] {
            let file = root.appendingPathComponent("output." + format.fileExtension)
            try ImageFiles.publish(raw:input,output:file,format:format,quality:0.85,source:input,receipt:Data("{}".utf8))
            XCTAssertEqual(try ImageFiles.dimensions(of:file).1,17)
            XCTAssertThrowsError(try ImageFiles.publish(raw:input,output:file,format:format,quality:0.85,source:input,receipt:Data()))
        }
        XCTAssertEqual(try ImageFiles.expand([input,root]).count,4)
    }

    @MainActor private func wait(_ store: StudioStore) async throws {
        let deadline = Date().addingTimeInterval(12)
        while store.jobs.contains(where:{ [.pending,.running].contains($0.status) }) {
            guard Date() < deadline else { throw StudioError("Queue timed out.") }
            try await Task.sleep(nanoseconds:20_000_000)
        }
    }
}
