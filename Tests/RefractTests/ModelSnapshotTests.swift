import CryptoKit
import Foundation
import XCTest
@testable import Refract

final class ModelSnapshotTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testPackageContainsOnlyListedFilesAndSurvivesSourceChange() async throws {
        let source = try temporaryDirectory()
        let stage = try temporaryDirectory()
        let component = source.appendingPathComponent("transformer")
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: false)
        let original = Data([11, 22, 33])
        let blob = source.appendingPathComponent("cache-blob")
        try original.write(to: blob)
        try FileManager.default.createSymbolicLink(at: component.appendingPathComponent("0.safetensors"), withDestinationURL: blob)
        try Data("fixture notes".utf8).write(to: component.appendingPathComponent("extra.json"))
        let file = CatalogModel.File("transformer/0.safetensors", 3, sha256(original))

        let snapshot = try await ModelInspector.shared.snapshotPackage(at: source, files: [file], in: stage)
        let published = snapshot.appendingPathComponent(file.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.path), ["transformer"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: published.deletingLastPathComponent().path), ["0.safetensors"])
        XCTAssertFalse(try published.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        let mutable = try FileHandle(forWritingTo: blob)
        try mutable.write(contentsOf: Data([44, 55, 66]))
        try mutable.close()
        XCTAssertEqual(try Data(contentsOf: published), original)
    }

    func testChangedPackageIsRejectedAndPartialSnapshotIsRemoved() async throws {
        let source = try temporaryDirectory(), stage = try temporaryDirectory()
        let data = Data([1, 2, 3])
        try data.write(to: source.appendingPathComponent("a"))
        try Data([4, 5, 6]).write(to: source.appendingPathComponent("b"))
        let manifest = ["a", "b"].map { CatalogModel.File($0, 3, sha256(data)) }
        do {
            _ = try await ModelInspector.shared.snapshotPackage(at: source, files: manifest, in: stage)
            XCTFail("A changed catalog artifact cannot be used for inference.")
        } catch let error as ModelError {
            XCTAssertTrue(error.localizedDescription.contains("differ"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [])
    }


    func testReadmeLicenseUsesOnlyBoundedFrontMatter() async throws {
        let root = try temporaryDirectory()
        let input = root.appendingPathComponent("fixture.safetensors")
        let entries: [String: Any] = [
            "lora_unet.fixture.lora_down.weight": ["dtype": "F16", "shape": [1, 1], "data_offsets": [0, 2]],
            "lora_unet.fixture.lora_up.weight": ["dtype": "F16", "shape": [1, 1], "data_offsets": [2, 4]]
        ]
        let header = try JSONSerialization.data(withJSONObject: entries)
        var length = UInt64(header.count).littleEndian
        var payload = withUnsafeBytes(of: &length) { Data($0) }
        payload.append(header)
        payload.append(Data(repeating: 0, count: 4))
        try payload.write(to: input)
        let readme = root.appendingPathComponent("README.md")
        try "---\nlicense: fixture-license\n---\n".write(to: readme, atomically: true, encoding: .utf8)
        let first = try await ModelInspector.shared.inspect(at: input, kind: .lora)
        XCTAssertEqual(first.license, "fixture-license")
        let largeFrontMatter = "---\n" + String(repeating: " ", count: 33 * 1024) + "\nlicense: late\n---\n"
        try largeFrontMatter.write(to: readme, atomically: true, encoding: .utf8)
        let second = try await ModelInspector.shared.inspect(at: input, kind: .lora)
        XCTAssertEqual(second.license, "See checkpoint publisher")
    }

    func testLegacySDXLIdentityProducesSingleIsolatedWeightsFile() async throws {
        let root = try temporaryDirectory()
        let weights = Data([8, 7, 6, 5])
        let path = root.appendingPathComponent("legacy.safetensors")
        try weights.write(to: path)
        let model = StudioModel(id: sha256(weights) + "+" + String(repeating: "a", count: 64), name: "Legacy", kind: .generation,
                                path: path.path, variant: "sdxl", configPath: root.path, precision: "FP16",
                                license: "Fixture", bytes: Int64(weights.count), managed: false)
        let snapshot = try await ModelInspector.shared.inferenceSnapshot(of: model, in: try temporaryDirectory())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.deletingLastPathComponent().path), ["weights.safetensors"])
        XCTAssertEqual(try Data(contentsOf: snapshot), weights)
    }

    func testLegacySchedulerReadsOnlyTypedDefaultsFromIdentifiedBytes() async throws {
        let root = try temporaryDirectory()
        let paths = [
            "model_index.json", "unet/config.json", "vae/config.json", "text_encoder/config.json",
            "text_encoder_2/config.json", "scheduler/scheduler_config.json",
            "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json",
            "tokenizer_2/vocab.json", "tokenizer_2/merges.txt", "tokenizer_2/tokenizer_config.json"
        ]
        func model(with scheduler: String) throws -> StudioModel {
            var manifest = Data()
            for path in paths.sorted() {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data((path == "scheduler/scheduler_config.json" ? scheduler : "{}").utf8)
                try data.write(to: url)
                manifest.append(contentsOf: "\(path)\0\(sha256(data))\n".utf8)
            }
            return StudioModel(id: String(repeating: "a", count: 64) + "+" + sha256(manifest),
                               name: "Legacy", kind: .generation, path: root.appendingPathComponent("weights.safetensors").path,
                               variant: "sdxl", configPath: nil, precision: "F16", license: "Fixture", bytes: 1, managed: false)
        }

        let valid = try model(with: #"{"prediction_type":"v_prediction","rescale_betas_zero_snr":true,"_class_name":"Unused"}"#)
        let values = try await ModelInspector.shared.legacySchedulerDefaults(for: valid)
        XCTAssertEqual(values.predictionType, "v_prediction")
        XCTAssertEqual(values.zeroTerminalSNR, true)
        let invalid = try model(with: #"{"prediction_type":"sample","rescale_betas_zero_snr":1}"#)
        let unsupported = try await ModelInspector.shared.legacySchedulerDefaults(for: invalid)
        XCTAssertNil(unsupported.predictionType)
        XCTAssertNil(unsupported.zeroTerminalSNR)
        do {
            _ = try await ModelInspector.shared.legacySchedulerDefaults(for: valid)
            XCTFail("A different scheduler file must not supply settings for this saved model.")
        } catch let error as ModelError {
            XCTAssertTrue(error.localizedDescription.contains("changed"))
        }
    }
}
