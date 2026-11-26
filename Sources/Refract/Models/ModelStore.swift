import Combine
import Foundation

@MainActor
final class ModelStore: ObservableObject {
    static let catalog = RefractCatalog.entries
    @Published private(set) var models: [StudioModel]
    @Published private(set) var modelDirectory: URL
    @Published private(set) var downloads: [String: ModelDownload] = [:]
    @Published private(set) var notice: String?

    private struct State: Codable {
        var models: [StudioModel]
        var modelDirectory: URL
        var dismissedPaths: Set<String>
    }
    private let trash: (URL) throws -> URL?
    private let index: URL
    private var dismissedPaths: Set<String>
    private let fm = FileManager.default
    private struct Transfer {
        let token: UUID
        let task: Task<(model: StudioModel, fromStaging: Bool), Error>
    }
    private var transfers: [String: Transfer] = [:]
    private var readError: String?
    private let inspector = ModelInspector.shared
    private static let marker = ".refract-managed-model"

    /// An explicit directory is isolated from the user's catalog and automatic discovery.
    init(directory: URL? = nil, trash: ((URL) throws -> URL?)? = nil) {
        self.trash = trash ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Refract")
        index = support.appendingPathComponent("model-index.json")
        let defaults = State(models: [], modelDirectory: support.appendingPathComponent("Models"), dismissedPaths: [])
        let state: State
        do {
            state = try FileManager.default.fileExists(atPath: index.path) ? JSONDecoder().decode(State.self, from: Data(contentsOf: index)) : defaults
        } catch {
            state = defaults
            readError = "Cannot read the model catalog at \(index.path). Restore the file before making changes: \(error.localizedDescription)"
        }
        models = state.models
        modelDirectory = state.modelDirectory
        dismissedPaths = state.dismissedPaths
        notice = readError
        if directory == nil, readError == nil { Task { await discoverCachedModels() } }
    }

    private func persist(models: [StudioModel], directory: URL, dismissed: Set<String>) throws {
        if let readError { throw ModelError(readError) }
        try fm.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = State(models: models, modelDirectory: directory, dismissedPaths: dismissed)
        try JSONEncoder().encode(state).write(to: index, options: .atomic)
        self.models = models; modelDirectory = directory; dismissedPaths = dismissed
    }

    func setModelDirectory(_ url: URL) throws {
        guard transfers.isEmpty else { throw ModelError("Finish or cancel current downloads before changing model storage.") }
        guard url.isFileURL else { throw ModelError("Choose a local folder.") }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: url.path) else { throw ModelError("The selected folder is not writable.") }
        try persist(models: models, directory: url.standardizedFileURL, dismissed: dismissedPaths)
        downloads = [:]
    }

    @discardableResult
    func importModel(at url: URL, kind: ModelKind? = nil) async throws -> StudioModel {
        let model = try await inspector.inspect(at: url.standardizedFileURL, kind: kind)
        try register(model)
        return models.first(where: { $0.id == model.id }) ?? model
    }

    private func register(_ model: StudioModel) throws {
        var result = models.filter { $0.path != model.path || $0.id == model.id }
        if let i = result.firstIndex(where: { $0.id == model.id }) {
            if result[i].managed && !model.managed && fm.fileExists(atPath: result[i].path) { return }
            result[i] = model
        } else { result.append(model) }
        try persist(models: result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, directory: modelDirectory, dismissed: dismissedPaths.subtracting([model.path]))
    }

    private func discoverCachedModels() async {
        for url in await inspector.cachedJuggernautFiles() {
            guard !dismissedPaths.contains(url.path), !models.contains(where: { $0.path == url.path }) else { continue }
            do {
                let model = try await inspector.inspect(at: url, kind: .generation)
                if !dismissedPaths.contains(url.path), !models.contains(where: { $0.id == model.id }) { try register(model) }
            } catch { notice = "Could not register \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    func verify(_ model: StudioModel) async throws { try await inspector.verify(model) }

    /// A relink is accepted only when the newly registered file matches the snapshot identity.
    func resolve(_ snapshot: StudioModel) async throws -> StudioModel {
        let current = models.first { $0.id == snapshot.id && $0.kind == snapshot.kind } ?? snapshot
        try await verify(current)
        return current
    }

    func unlink(_ model: StudioModel) throws {
        guard !model.managed, models.contains(model) else {
            throw ModelError("Choose a linked model to unlink from Refract.")
        }
        try persist(models: models.filter { $0.id != model.id }, directory: modelDirectory,
                    dismissed: dismissedPaths.union([model.path]))
    }

    struct ModelRemoval {
        let model: StudioModel
        let target: URL
        let entry: CatalogModel
    }

    func removal(for model: StudioModel) -> ModelRemoval? {
        guard model.managed, let entry = Self.catalog.first(where: { $0.identity == model.id && $0.canDownload }) else {
            return nil
        }
        let url = URL(fileURLWithPath: model.path)
        let package = entry.checkpointFile != nil ? url.deletingLastPathComponent() : url
        return ModelRemoval(model: model, target: package, entry: entry)
    }

    func remove(_ removal: ModelRemoval) throws {
        if let readError { throw ModelError(readError) }
        let record = removal.model
        guard models.contains(record), let current = self.removal(for: record), current.target == removal.target else {
            throw ModelError("The model location changed. Open the confirmation again.")
        }
        let target = current.target
        let entry = current.entry
        if transfers[entry.id] != nil { throw ModelError("Finish or cancel the model download first.") }
        let remaining = models.filter { $0.id != record.id }
        let dismissed = dismissedPaths.union([record.path])
        var trashed: URL?
        if fm.fileExists(atPath: target.path) {
            guard target.lastPathComponent == entry.id,
                  target.deletingLastPathComponent().lastPathComponent == "Refract Packages",
                  (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  (try? String(contentsOf: target.appendingPathComponent(Self.marker), encoding: .utf8)) == entry.provenanceID else {
                throw ModelError("The package ownership record does not match.")
            }
            try verifyTrashContents(target, entry: entry)
            trashed = try trash(target)
        }
        do {
            try persist(models: remaining, directory: modelDirectory, dismissed: dismissed)
            downloads[entry.id] = nil
        } catch {
            if let trashed, !fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: trashed, to: target)
            }
            throw error
        }
    }

    private func verifyTrashContents(_ directory: URL, entry: CatalogModel) throws {
        var folders = Set<String>()
        for file in entry.files {
            var parent = (file.path as NSString).deletingLastPathComponent
            while !parent.isEmpty && folders.insert(parent).inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let permitted = Set(entry.files.map(\.path) + [Self.marker, ".DS_Store"]).union(folders).union(folders.map { $0 + "/.DS_Store" })
        guard let children = fm.enumerator(atPath: directory.path),
              children.allObjects.allSatisfy({ ($0 as? String).map(permitted.contains) == true }) else {
            throw ModelError("This package contains additional files. Move those files out before removing it.")
        }
    }

    private func stagingFolder(for entry: CatalogModel, root: URL) -> URL {
        root.appendingPathComponent("Refract Packages/.\(entry.id).partial", isDirectory: true)
    }

    func hasPartialDownload(_ entry: CatalogModel) -> Bool {
        let marker = stagingFolder(for: entry, root: modelDirectory).appendingPathComponent(Self.marker)
        return (try? String(contentsOf: marker, encoding: .utf8)) == entry.provenanceID
    }

    func cancelDownload(_ entry: CatalogModel) throws {
        if let transfer = transfers[entry.id] {
            downloads[entry.id]?.isCancelling = true
            downloads[entry.id]?.message = "Canceling download…"
            transfer.task.cancel()
            return
        }
        try discardStaging(for: entry, root: modelDirectory)
        downloads[entry.id] = nil
    }

    private func discardStaging(for entry: CatalogModel, root: URL) throws {
        let staging = stagingFolder(for: entry, root: root)
        guard fm.fileExists(atPath: staging.path) else { return }
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard staging.resolvingSymlinksInPath().path == stagingFolder(for: entry, root: resolvedRoot).path,
              (try? String(contentsOf: staging.appendingPathComponent(Self.marker), encoding: .utf8)) == entry.provenanceID else {
            throw ModelError("The partial download does not belong to this model revision.")
        }
        try verifyTrashContents(staging, entry: entry)
        try fm.removeItem(at: staging)
    }

    func download(_ requested: CatalogModel) async throws {
        guard let entry = Self.catalog.first(where: { $0.id == requested.id && $0.identity == requested.identity }), entry.canDownload else {
            throw ModelError("This model uses local import or requires qualification.")
        }
        guard transfers[entry.id] == nil else { throw ModelError("This model is already downloading.") }
        downloads[entry.id] = .init(fraction: 0, message: "Preparing download", isRunning: true)
        let root = modelDirectory
        let token = UUID()
        let final = root.appendingPathComponent("Refract Packages/\(entry.id)", isDirectory: true)
        let staging = stagingFolder(for: entry, root: root)
        let task = Task { try await acquire(entry, final: final, staging: staging, token: token) }
        transfers[entry.id] = Transfer(token: token, task: task)
        defer { transfers[entry.id] = nil }
        do {
            let download = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if downloads[entry.id]?.isCancelling == true { throw CancellationError() }
            try Task.checkCancellation()
            // After this point there is no suspension between moving the verified package and registering it.
            if download.fromStaging { try fm.moveItem(at: staging, to: final) }
            try register(download.model)
            downloads[entry.id] = .init(fraction: 1, message: "Installed", isRunning: false)
        } catch {
            if downloads[entry.id]?.isCancelling == true {
                do { try discardStaging(for: entry, root: root) }
                catch {
                    downloads[entry.id] = .init(fraction: 0, message: error.localizedDescription, isRunning: false)
                    throw error
                }
                downloads[entry.id] = nil
                throw CancellationError()
            }
            let text = error is CancellationError ? "Download interrupted · resume to continue" : error.localizedDescription
            downloads[entry.id] = .init(fraction: downloads[entry.id]?.fraction ?? 0, message: text, isRunning: false)
            throw error
        }
    }

    private func acquire(_ entry: CatalogModel, final: URL, staging: URL, token: UUID) async throws
        -> (model: StudioModel, fromStaging: Bool) {
        try Task.checkCancellation()
        let parent = final.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: final.path) {
            guard (try? String(contentsOf: final.appendingPathComponent(Self.marker), encoding: .utf8)) == entry.provenanceID else { throw ModelError("The destination exists and is owned by another file or package.") }
            return (try await inspector.installedModel(in: final, entry: entry), false)
        }
        let marker = staging.appendingPathComponent(Self.marker)
        if fm.fileExists(atPath: staging.path) {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == entry.provenanceID else { throw ModelError("The download staging folder belongs to another revision.") }
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try entry.provenanceID.write(to: marker, atomically: true, encoding: .utf8)
        }
        var completed: Int64 = 0
        for file in entry.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            let dir = target.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard target.resolvingSymlinksInPath().path == parent.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("Refract Packages/.\(entry.id).partial/\(file.path)").path else {
                throw ModelError("The partial download points outside its managed folder.")
            }
            var received = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            if received >= file.size {
                do { try await inspector.check(file, at: target); completed += file.size; continue }
                catch is CancellationError { throw CancellationError() }
                catch { try fm.removeItem(at: target); received = 0 }
            }
            let start = completed
            let transfer = ModelTransfer(destination: target, received: received, size: file.size) { [weak self] count in
                Task { @MainActor in
                    guard let self, self.transfers[entry.id]?.token == token,
                          self.downloads[entry.id]?.isCancelling != true else { return }
                    self.downloads[entry.id] = .init(fraction: Double(start + count) / Double(entry.bytes), message: "Downloading \(file.path)", isRunning: true)
                }
            }
            try await transfer.run(url: entry.downloadURL(file))
            do { try await inspector.check(file, at: target) }
            catch is CancellationError { throw CancellationError() }
            catch { try fm.removeItem(at: target); throw error }
            completed += file.size
        }
        try Task.checkCancellation()
        downloads[entry.id] = .init(fraction: 1, message: "Verifying package", isRunning: true)
        let checked = try await inspector.installedModel(in: staging, entry: entry)
        let target = entry.checkpointFile.map { final.appendingPathComponent($0.path) } ?? final
        let model = StudioModel(id: checked.id, name: checked.name, kind: checked.kind, path: target.path,
                                variant: checked.variant, configPath: checked.configPath, precision: checked.precision,
                                license: checked.license, bytes: checked.bytes, managed: checked.managed)
        return (model, true)
    }
}
