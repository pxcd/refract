import XCTest
@testable import Refract

/// Opt-in hardware acceptance test using the delivered app's relocatable runtime and real model files.
final class OfflineBatchTests: XCTestCase {
    @MainActor func testPackagedBatch() async throws {
        let env = ProcessInfo.processInfo.environment
        let resources = try XCTUnwrapOrSkip(env["REFRACT_QA_RESOURCES"])
        let generator = try XCTUnwrap(env["REFRACT_QA_SDXL"])
        let enhancer = try XCTUnwrap(env["REFRACT_QA_SEEDVR"])
        let directory = URL(fileURLWithPath:try XCTUnwrap(env["REFRACT_QA_OUTPUTS"]))
        let run = directory.appendingPathComponent(UUID().uuidString)
        let catalog = ModelStore(directory:run)
        try await catalog.importModel(at:URL(fileURLWithPath:generator),kind:.generation)
        try await catalog.importModel(at:URL(fileURLWithPath:enhancer),kind:.enhancement)
        let client = WorkerClient(resources:URL(fileURLWithPath:resources))
        let store = StudioStore(models:catalog,worker:client,directory:run,defaults:isolatedDefaults())
        defer { store.shutdown() }
        store.outputDirectory = run.appendingPathComponent("images")
        let count = Int(env["REFRACT_QA_COUNT"] ?? "10") ?? 10
        XCTAssertTrue((1...100).contains(count))
        store.generation.count = count
        store.generation.seed = 314159
        store.generation.prompt = "Editorial photograph of a red enamel coffee pot with a wooden handle on an old walnut table by a rain-streaked window, soft morning side light, realistic material texture."
        store.generation.autoEnhance = true
        var expectedSize = (832, 1216)
        if let source = env["REFRACT_QA_REFERENCE"] {
            let url = URL(fileURLWithPath: source)
            store.generation.reference = url
            store.generation.preserveReferenceSize = true
            expectedSize = try ImageFiles.dimensions(of: url)
        }
        store.generate()
        store.generation.count = 1
        store.generation.prompt = "New draft"
        store.activeEnhancementID = ""
        let interrupt = env["REFRACT_QA_INTERRUPT"] == "1"
        var preserved: (URL, Data)?
        let deadline = Date().addingTimeInterval(7200)
        var last = ""
        while let job = store.jobs.first, [.pending,.running].contains(job.status) {
            let summary = "\(job.status.rawValue) · \(job.results.count) originals · \(job.results.filter { $0.enhanced != nil }.count) enhanced"
            if last != summary { print(summary); last = summary }
            if interrupt, preserved == nil, job.message.hasPrefix("Enhancing"),
               let original = job.results.first?.original {
                preserved = (original, try Data(contentsOf: original))
                store.cancel(job.id)
                XCTAssertEqual(store.jobs.first?.status,.cancelled)
                store.retry(job.id)
            }
            if Date() >= deadline { XCTFail("Offline batch timed out"); return }
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        let job = try XCTUnwrap(store.jobs.first,store.notice ?? "Job missing")
        XCTAssertEqual(job.status,.completed,job.message)
        XCTAssertEqual(job.results.count,count)
        XCTAssertEqual(job.results.map(\.seed),Array(314159..<(314159+count)))
        for pair in job.results {
            let after = try XCTUnwrap(pair.enhanced)
            let originalSize = try ImageFiles.dimensions(of:pair.original)
            let afterSize = try ImageFiles.dimensions(of:after)
            XCTAssertEqual(originalSize.0, expectedSize.0); XCTAssertEqual(originalSize.1, expectedSize.1)
            XCTAssertEqual(afterSize.0, expectedSize.0 * 2); XCTAssertEqual(afterSize.1, expectedSize.1 * 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath:after.appendingPathExtension("json").path))
        }
        if interrupt {
            let item = try XCTUnwrap(preserved, "The real worker cancellation point was not reached")
            XCTAssertEqual(try Data(contentsOf: item.0),item.1)
        }
        XCTAssertNotEqual(client.runtimeIdentity, "development")
        print("Completed real offline batch in \(job.elapsed)s at \(run.path)")
    }

    @MainActor func testPackagedEnhancement() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputPath = env["REFRACT_QA_INPUT"] else { throw XCTSkip("Supply a real standalone Enhance input for the hardware test.") }
        let resources = try XCTUnwrap(env["REFRACT_QA_RESOURCES"])
        let enhancer = try XCTUnwrap(env["REFRACT_QA_SEEDVR"])
        let base = URL(fileURLWithPath:try XCTUnwrap(env["REFRACT_QA_OUTPUTS"]))
        let root = base.appendingPathComponent(UUID().uuidString)
        let input = URL(fileURLWithPath:inputPath)
        let modelStore = ModelStore(directory:root)
        try await modelStore.importModel(at:URL(fileURLWithPath:enhancer),kind:.enhancement)
        let client = WorkerClient(resources:URL(fileURLWithPath:resources))
        let store = StudioStore(models:modelStore,worker:client,directory:root,defaults:isolatedDefaults())
        defer { store.shutdown() }
        store.outputDirectory = root.appendingPathComponent("images")
        store.enhance([input])
        let deadline = Date().addingTimeInterval(1800)
        while store.jobs.isEmpty || store.jobs.contains(where: { [.pending,.running].contains($0.status) }) {
            if let error = store.notice { throw StudioError(error) }
            if Date() >= deadline { throw StudioError("Standalone enhancement timed out.") }
            try await Task.sleep(nanoseconds:500_000_000)
        }
        let job = try XCTUnwrap(store.jobs.first)
        XCTAssertEqual(job.status,.completed,job.message)
        let result = try XCTUnwrap(job.results.first?.enhanced)
        let expected = try ImageFiles.outputDimensions(for:input,options:store.enhancement)
        let actual = try ImageFiles.dimensions(of:result)
        XCTAssertEqual(expected.0,actual.0)
        XCTAssertEqual(expected.1,actual.1)
        XCTAssertEqual(job.results.first?.original.standardizedFileURL,input.standardizedFileURL)
        XCTAssertNotEqual(client.runtimeIdentity,"development")
        print("Completed standalone \(job.recipe.enhancer?.name ?? "SeedVR2") at \(actual.0) × \(actual.1) in \(job.elapsed)s. Saved \(result.path)")
    }

    private func XCTUnwrapOrSkip(_ value: String?) throws -> String {
        guard let value else { throw XCTSkip("Set REFRACT_QA_RESOURCES and local model paths to run the hardware acceptance test.") }
        return value
    }
}
