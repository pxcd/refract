import CryptoKit
import Darwin
import Foundation

/// Runs file I/O away from the UI. Reuse the digest only while the underlying file's
/// volume, inode, size, modification time and change time all match the verified version.
actor ModelInspector {
    static let shared = ModelInspector()
    private struct Stamp: Equatable {
        var device: dev_t, inode: ino_t, size: Int64, mtime: Int, mtimeNanos: Int, ctime: Int, ctimeNanos: Int
        init(_ path: String) throws {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw ModelError("Model file is missing or inaccessible. Locate the original file and import it again.\n\(path)")
            }
            self.init(info)
        }
        init(_ handle: FileHandle) throws {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw ModelError("Cannot identify the opened model file.") }
            self.init(info)
        }
        private init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            mtime = info.st_mtimespec.tv_sec; mtimeNanos = info.st_mtimespec.tv_nsec
            ctime = info.st_ctimespec.tv_sec; ctimeNanos = info.st_ctimespec.tv_nsec
        }
    }
    private var cache: [String: (Stamp, String)] = [:]
    private let files = FileManager.default

    func digest(_ url: URL, gitBlob: Bool = false, cacheResult: Bool = true) throws -> String {
        let file = try ModelSnapshotFiles.openRegular(url)
        defer { try? file.close() }
        let stamp = try Stamp(file)
        let key = (gitBlob ? "git:" : "sha256:") + url.path
        if cacheResult, let cached = cache[key], cached.0 == stamp { return cached.1 }
        var sha = SHA256(), git = Insecure.SHA1()
        if gitBlob { git.update(data: Data("blob \(stamp.size)\0".utf8)) }
        while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if gitBlob { git.update(data: chunk) } else { sha.update(data: chunk) }
        }
        guard try Stamp(file) == stamp, try Stamp(url.path) == stamp else { throw ModelError("A model file changed during verification. Retry after it finishes writing.") }
        let result = gitBlob ? Self.hex(git.finalize()) : Self.hex(sha.finalize())
        if cacheResult { cache[key] = (stamp, result) }
        return result
    }
    private static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func check(_ file: CatalogModel.File, at url: URL) throws {
        guard try Stamp(url.path).size == file.size,
              try digest(url, gitBlob: file.digest.count == 40) == file.digest else {
            throw ModelError("Verification failed for \(file.path). Its contents differ from the catalog revision.")
        }
    }

    func inspect(at url: URL, kind requestedKind: ModelKind?, managed: Bool = false) throws -> StudioModel {
        if requestedKind == .enhancement || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return try inspectPackage(at: url, kind: requestedKind, managed: managed)
        }
        guard url.pathExtension.lowercased() == "safetensors" else {
            throw ModelError("Choose a single .safetensors file for an SDXL checkpoint or LoRA.")
        }
        let file = try ModelSnapshotFiles.openRegular(url)
        defer { try? file.close() }
        let stamp = try Stamp(file)
        let length = stamp.size
        guard let prefix = try file.read(upToCount: 8), prefix.count == 8 else { throw ModelError("Incomplete safetensors header.") }
        let headerSize = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard headerSize <= 100_000_000, length > 8, headerSize < UInt64(length - 8),
              let header = try file.read(upToCount: Int(headerSize)), header.count == headerSize,
              var contents = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            throw ModelError("The file has an invalid safetensors header.")
        }
        let metadata = contents.removeValue(forKey: "__metadata__") as? [String: String] ?? [:]
        let tensors = contents.compactMapValues { $0 as? [String: Any] }
        let payload = length - Int64(headerSize) - 8
        let dtypeBytes: [String: Int64] = ["BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1, "U16": 2, "I16": 2, "F16": 2, "BF16": 2, "U32": 4, "I32": 4, "F32": 4, "U64": 8, "I64": 8, "F64": 8]
        var ranges: [(Int64, Int64)] = []
        for tensor in tensors.values {
            guard let offsets = tensor["data_offsets"] as? [Int64], offsets.count == 2,
                  offsets[0] >= 0, offsets[0] <= offsets[1], offsets[1] <= payload,
                  let shape = tensor["shape"] as? [Int64], let type = tensor["dtype"] as? String, var count = dtypeBytes[type] else {
                throw ModelError("Invalid or unsupported safetensors layout.")
            }
            for dimension in shape {
                let (next, overflow) = count.multipliedReportingOverflow(by: dimension)
                guard dimension >= 0, !overflow else { throw ModelError("Invalid tensor dimensions.") }
                count = next
            }
            guard count == offsets[1] - offsets[0] else { throw ModelError("Tensor dimensions disagree with file size.") }
            ranges.append((offsets[0], offsets[1]))
        }
        var end: Int64 = 0
        for (start, next) in ranges.sorted(by: <) {
            guard start == end else { throw ModelError("Overlapping or missing safetensors data.") }
            end = next
        }
        guard !tensors.isEmpty, tensors.count == contents.count, end == payload else { throw ModelError("Incomplete safetensors payload.") }
        let kind = requestedKind ?? (tensors["model.diffusion_model.input_blocks.0.0.weight"] == nil ? .lora : .generation)
        if kind == .generation {
            let input = tensors["model.diffusion_model.input_blocks.0.0.weight"]?["shape"] as? [Int]
            let embedding = tensors["model.diffusion_model.label_emb.0.0.weight"]?["shape"] as? [Int]
            guard input == [320, 4, 3, 3], embedding == [1280, 2816],
                  tensors.keys.contains(where: { $0.hasPrefix("conditioner.embedders.0.") }),
                  tensors.keys.contains(where: { $0.hasPrefix("conditioner.embedders.1.") }),
                  tensors.keys.contains(where: { $0.hasPrefix("first_stage_model.") }) else {
                throw ModelError("This file does not contain a complete standard four-channel SDXL base checkpoint with both text encoders and VAE.")
            }
        } else {
            let adapterKeys = tensors.keys.filter { $0.contains(".lora_down.") || $0.contains(".lora_A.") || $0.contains(".lora.down.") || $0.contains(".lora_linear_layer.down.") }
            let base = (metadata["ss_base_model_version"] ?? metadata["modelspec.architecture"] ?? "").lowercased()
            let hasOtherCrossAttention = adapterKeys.contains { key in
                guard key.contains("attn2"), key.contains("to_k") || key.contains("to_v"), let shape = tensors[key]?["shape"] as? [Int], shape.count == 2 else { return false }
                return shape[1] != 2048
            }
            let isKnownOther = !base.isEmpty && !base.contains("sdxl") && !base.contains("stable-diffusion-xl") && !base.contains("sd_xl")
            guard !isKnownOther, !hasOtherCrossAttention, !adapterKeys.isEmpty, adapterKeys.allSatisfy({ key in
                let up = key.replacingOccurrences(of: ".lora_down.", with: ".lora_up.").replacingOccurrences(of: ".lora_A.", with: ".lora_B.").replacingOccurrences(of: ".down.", with: ".up.")
                return tensors[up] != nil
            }) else { throw ModelError("Choose an SDXL LoRA with matching up/down tensors. The selected file has incompatible architecture or incomplete adapters.") }
        }
        let tensorTypes = Set(tensors.values.compactMap { $0["dtype"] as? String }).sorted()
        let precision = tensorTypes.map { ["F16":"FP16", "F32":"FP32"][ $0 ] ?? $0 }.joined(separator: " / ")
        let hash = try digest(url)
        guard try Stamp(file) == stamp, try Stamp(url.path) == stamp else {
            throw ModelError("The model changed during import. Retry after it finishes writing.")
        }
        // Keep existing reference IDs stable. These sidecars are never given to the inference worker.
        let config = kind == .generation ? matchingConfig(for: url) : nil
        let configID = try config.map { try configFingerprint($0) }
        let id = hash + (configID.map { "+" + $0 } ?? "")
        let known = RefractCatalog.entries.first { $0.kind == kind && $0.canDownload && $0.identity == hash }
        let license = known?.license ?? metadata["modelspec.license"] ?? cardLicense(at: url.deletingLastPathComponent()) ?? "See checkpoint publisher"
        return StudioModel(id: id, name: known?.name ?? url.deletingPathExtension().lastPathComponent, kind: kind, path: url.path,
                           variant: kind == .generation ? "sdxl" : "sdxl-lora", configPath: nil,
                           precision: precision, license: license, bytes: length, managed: managed)
    }

    func installedModel(in directory: URL, entry: CatalogModel) throws -> StudioModel {
        if let checkpoint = entry.checkpointFile {
            for file in entry.files { try check(file, at: directory.appendingPathComponent(file.path)) }
            let candidate = try inspect(at: directory.appendingPathComponent(checkpoint.path), kind: entry.kind, managed: true)
            guard candidate.id == entry.identity else { throw ModelError("The installed checkpoint's local configuration differs from the catalog.") }
            return candidate
        }
        return try packageModel(at: directory, entry: entry, managed: true)
    }

    private func inspectPackage(at url: URL, kind: ModelKind?, managed: Bool) throws -> StudioModel {
        let candidates = RefractCatalog.entries.filter { entry in
            guard (kind == nil || kind == entry.kind), entry.canDownload, entry.checkpointFile == nil else { return false }
            return entry.files.allSatisfy { file in (try? Stamp(url.appendingPathComponent(file.path).path).size) == file.size }
        }
        var validationError: Error?
        for entry in candidates {
            do { return try packageModel(at: url, entry: entry, managed: managed) }
            catch { if validationError == nil { validationError = error } }
        }
        throw validationError ?? ModelError("Choose a complete model package that matches a downloadable catalog revision.")
    }

    private func packageModel(at url: URL, entry: CatalogModel, managed: Bool) throws -> StudioModel {
        guard entry.canDownload, entry.checkpointFile == nil else { throw ModelError("This catalog entry has no downloadable model package.") }
        for file in entry.files { try check(file, at: url.appendingPathComponent(file.path)) }
        // The MLX loader globs shards and may consume additional weights in the two component folders.
        let componentDirectories = Set(entry.files.map { ($0.path as NSString).deletingLastPathComponent })
        for directory in componentDirectories {
            let actual = try files.contentsOfDirectory(atPath: url.appendingPathComponent(directory).path)
            let expected = Set(entry.files.filter { ($0.path as NSString).deletingLastPathComponent == directory }.map { ($0.path as NSString).lastPathComponent })
            if actual.contains(where: { $0.hasSuffix(".safetensors") && !expected.contains($0) }) {
                throw ModelError("The \(directory) folder contains shards outside the selected model revision.")
            }
        }
        return StudioModel(id: entry.identity, name: entry.name, kind: entry.kind, path: url.path, variant: entry.variant,
                           configPath: nil, precision: entry.precision, license: entry.license, bytes: entry.bytes, managed: managed)
    }


    /// The caller owns the private parent and keeps this snapshot for the lifetime of its worker route.
    func inferenceSnapshot(of model: StudioModel, in parent: URL) throws -> URL {
        if let entry = RefractCatalog.entries.first(where: {
            $0.identity == model.id && $0.kind == model.kind && $0.variant == model.variant && $0.canDownload && $0.checkpointFile == nil
        }) {
            return try snapshotPackage(at: URL(fileURLWithPath: model.path), files: entry.files, in: parent)
        }
        guard (model.kind == .generation && model.variant == "sdxl") || (model.kind == .lora && model.variant == "sdxl-lora"),
              let weightDigest = model.id.split(separator: "+").first, weightDigest.count == 64 else {
            throw ModelError("Unsupported model identity for " + model.name)
        }
        let source = URL(fileURLWithPath: model.path)
        return try withSnapshotDirectory(in: parent) { directory in
            let target = directory.appendingPathComponent("weights.safetensors")
            try copyVerified(source, to: target, size: model.bytes, expected: String(weightDigest))
            return target
        }
    }

    /// Construct a new package from the manifest. Even optional runtime configuration files are absent
    /// unless the catalog pins them, so runtime discovery cannot expand the verified set.
    func snapshotPackage(at source: URL, files manifest: [CatalogModel.File], in parent: URL) throws -> URL {
        try withSnapshotDirectory(in: parent) { directory in
            for file in manifest {
                try Task.checkCancellation()
                let target = directory.appendingPathComponent(file.path)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
                try copyVerified(source.appendingPathComponent(file.path), to: target, size: file.size, expected: file.digest)
            }
            return directory
        }
    }

    private func withSnapshotDirectory(in parent: URL, build: (URL) throws -> URL) throws -> URL {
        try Task.checkCancellation()
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { return try build(directory) }
        catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private func copyVerified(_ source: URL, to target: URL, size: Int64, expected: String) throws {
        try ModelSnapshotFiles.copyRegular(from: source, to: target, size: size)
        guard try Stamp(target.path).size == size,
              try digest(target, gitBlob: expected.count == 40, cacheResult: false) == expected else {
            throw ModelError("The contents of " + source.lastPathComponent + " differ from the linked model revision.")
        }
    }

    private static let configFiles = ["model_index.json", "unet/config.json", "vae/config.json", "scheduler/scheduler_config.json", "text_encoder/config.json", "text_encoder_2/config.json", "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json", "tokenizer_2/vocab.json", "tokenizer_2/merges.txt", "tokenizer_2/tokenizer_config.json"]
    private func matchingConfig(for checkpoint: URL) -> URL? {
        let directory = checkpoint.deletingLastPathComponent()
        return Self.configFiles.allSatisfy { files.isReadableFile(atPath: directory.appendingPathComponent($0).path) } ? directory : nil
    }
    private static let schedulerFile = "scheduler/scheduler_config.json"

    func legacySchedulerDefaults(for model: StudioModel) throws -> (predictionType: String?, zeroTerminalSNR: Bool?) {
        let parts = model.id.split(separator: "+", omittingEmptySubsequences: false)
        guard model.kind == .generation, model.variant == "sdxl", parts.count == 2 else { return (nil, nil) }
        guard let directory = matchingConfig(for: URL(fileURLWithPath: model.path)) else {
            throw ModelError("The linked SDXL configuration is missing. Re-import the checkpoint.")
        }
        let handle = try ModelSnapshotFiles.openRegular(directory.appendingPathComponent(Self.schedulerFile))
        defer { try? handle.close() }
        let limit = 128 * 1024
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw ModelError("Expected an SDXL scheduler configuration of at most 128 KiB.")
        }
        // Bind the exact bytes we parse to the saved ID, even if the original path changes during the read.
        let schedulerDigest = Self.hex(SHA256.hash(data: data))
        guard try configFingerprint(directory, schedulerDigest: schedulerDigest) == parts[1] else {
            throw ModelError("The linked SDXL configuration has changed. Re-import the checkpoint.")
        }
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError("Expected a JSON object in the SDXL scheduler configuration.")
        }
        let prediction = (config["prediction_type"] as? String).flatMap {
            ["epsilon", "v_prediction"].contains($0) ? $0 : nil
        }
        let zeroSNR = (config["rescale_betas_zero_snr"] as? NSNumber).flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
        }
        return (prediction, zeroSNR)
    }

    private func configFingerprint(_ directory: URL, schedulerDigest: String? = nil) throws -> String {
        var entries = Set(Self.configFiles)
        for subdirectory in ["tokenizer", "tokenizer_2", "scheduler", "text_encoder", "text_encoder_2", "unet", "vae"] {
            for name in try files.contentsOfDirectory(atPath: directory.appendingPathComponent(subdirectory).path)
                where ["json", "txt", "model"].contains((name as NSString).pathExtension) { entries.insert(subdirectory + "/" + name) }
        }
        var hash = SHA256()
        for path in entries.sorted() {
            let digest: String
            if path == Self.schedulerFile, let schedulerDigest {
                digest = schedulerDigest
            } else {
                digest = try self.digest(directory.appendingPathComponent(path))
            }
            hash.update(data: Data("\(path)\0\(digest)\n".utf8))
        }
        return Self.hex(hash.finalize())
    }
    private func cardLicense(at directory: URL) -> String? {
        guard let file = try? ModelSnapshotFiles.openRegular(directory.appendingPathComponent("README.md")) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 32 * 1024) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return lines[1..<end].first(where: { $0.hasPrefix("license:") })?.dropFirst(8).trimmingCharacters(in: .whitespaces)
    }

    func verify(_ model: StudioModel) throws {
        let observed = try inspect(at: URL(fileURLWithPath: model.path), kind: model.kind, managed: model.managed)
        guard observed.id == model.id, observed.variant == model.variant else { throw ModelError("\(model.name) or its configuration has changed. Re-import it and submit a new job.") }
    }

    func cachedJuggernautFiles() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let root = (env["HF_HUB_CACHE"] ?? env["HUGGINGFACE_HUB_CACHE"]).map { URL(fileURLWithPath: $0) } ??
            (env["HF_HOME"].map { URL(fileURLWithPath: $0) } ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface")).appendingPathComponent("hub")
        let repos = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return repos.filter { $0.lastPathComponent.lowercased().hasPrefix("models--") && $0.lastPathComponent.lowercased().contains("juggernaut") }.flatMap { repo -> [URL] in
            let snapshots = (try? files.contentsOfDirectory(at: repo.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil)) ?? []
            return snapshots.sorted(by: { $0.path < $1.path }).flatMap { directory in
                ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "safetensors" }
            }
        }
    }
}
