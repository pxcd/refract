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
        var installations: [String: ManagedPackageIdentity]? = nil
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

    /// Atomic replacement prevents torn writes. The separate, persistent lock makes read/modify/write
    /// transactions from other Refract processes see the latest index.
    private func updateState(_ change: (inout State) throws -> Void) throws {
        let directory = try ManagedModelDirectory.root(at: index.deletingLastPathComponent())
        let lock = try directory.lock(".model-index.lock", wait: true)
        defer { withExtendedLifetime(lock) {} }
        var state: State
        if try directory.exists(index.lastPathComponent) {
            let file = try directory.file(index.lastPathComponent)
            state = try JSONDecoder().decode(State.self, from: file.readToEnd() ?? Data())
        } else {
            state = State(models: [], modelDirectory: directory.url.appendingPathComponent("Models"), dismissedPaths: [])
        }
        try change(&state)
        try JSONEncoder().encode(state).write(to: directory.url.appendingPathComponent(index.lastPathComponent), options: .atomic)
        models = state.models
        modelDirectory = state.modelDirectory
        dismissedPaths = state.dismissedPaths
        readError = nil
    }

    func setModelDirectory(_ url: URL) throws {
        guard transfers.isEmpty else { throw ModelError("Finish or cancel current downloads before changing model storage.") }
        guard url.isFileURL else { throw ModelError("Choose a local folder.") }
        let selected = try ManagedModelDirectory.root(at: url)
        guard fm.isWritableFile(atPath: selected.url.path) else { throw ModelError("The selected folder is not writable.") }
        try updateState { $0.modelDirectory = selected.url }
        downloads = [:]
    }

    @discardableResult
    func importModel(at url: URL, kind: ModelKind? = nil) async throws -> StudioModel {
        let model = try await inspector.inspect(at: url.standardizedFileURL, kind: kind)
        try register(model)
        return models.first(where: { $0.id == model.id }) ?? model
    }

    private func register(_ model: StudioModel, discovered: Bool = false, installation: ManagedPackageIdentity? = nil) throws {
        try updateState { state in
            if discovered && (state.dismissedPaths.contains(model.path) || state.models.contains(where: { $0.id == model.id })) { return }
            for old in state.models where old.path == model.path && old.id != model.id {
                state.installations?[old.id] = nil
            }
            state.models.removeAll { $0.path == model.path && $0.id != model.id }
            if let i = state.models.firstIndex(where: { $0.id == model.id }) {
                if state.models[i].managed && !model.managed && fm.fileExists(atPath: state.models[i].path) { return }
                state.models[i] = model
            } else { state.models.append(model) }
            state.models.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            state.dismissedPaths.remove(model.path)
            if let installation {
                if state.installations == nil { state.installations = [:] }
                state.installations?[model.id] = installation
            } else { state.installations?[model.id] = nil }
        }
    }

    private func discoverCachedModels() async {
        for url in await inspector.cachedJuggernautFiles() {
            guard !dismissedPaths.contains(url.path), !models.contains(where: { $0.path == url.path }) else { continue }
            do {
                let model = try await inspector.inspect(at: url, kind: .generation)
                try register(model, discovered: true)
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
        try updateState { state in
            guard !model.managed, state.models.contains(model) else {
                throw ModelError("Choose a linked model to unlink from Refract.")
            }
            state.models.removeAll { $0.id == model.id }
            state.dismissedPaths.insert(model.path)
            state.installations?[model.id] = nil
        }
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
        let record = removal.model
        guard let current = self.removal(for: record), current.target == removal.target,
              current.target.lastPathComponent == current.entry.id,
              current.target.deletingLastPathComponent().lastPathComponent == "Refract Packages" else {
            throw ModelError("The model location changed. Open the confirmation again.")
        }
        let entry = current.entry
        let root = current.target.deletingLastPathComponent().deletingLastPathComponent()
        if transfers[entry.id] != nil { throw ModelError("Finish or cancel the model download first.") }
        func forget(_ state: inout State) throws {
            guard state.models.contains(record) else { throw ModelError("The registered model changed. Reopen its details.") }
            state.models.removeAll { $0.id == record.id }
            state.dismissedPaths.insert(record.path)
            state.installations?[record.id] = nil
        }
        guard fm.fileExists(atPath: current.target.deletingLastPathComponent().path) else {
            // An offline or removed library has no package to trash. Never recreate its mount path.
            try updateState(forget)
            downloads[entry.id] = nil
            return
        }
        // Take package locks before the index lock in every operation that needs both.
        let packages = try packageDirectory(root: root, create: false)
        let lease = try packages.lock(lockName(entry))
        defer { withExtendedLifetime(lease) {} }
        let target = packages.url.appendingPathComponent(entry.id, isDirectory: true)
        var trashed: URL?
        do {
            try updateState { state in
                let expected = state.installations?[record.id]
                try forget(&state)
                if try packages.exists(entry.id) {
                    let directory = try packages.child(entry.id)
                    if let expected, try !expected.matches(directory.identity()) {
                        throw ModelError("The registered package location changed. Reverify the model before removing it.")
                    }
                    try checkMarker(directory, entry: entry)
                    _ = try inventory(directory, entry: entry)
                    trashed = try trash(target)
                }
            }
            downloads[entry.id] = nil
        } catch {
            if let trashed, !(try packages.exists(entry.id)) { try fm.moveItem(at: trashed, to: target) }
            throw error
        }
    }

    private func packageDirectory(root: URL, create: Bool = true) throws -> ManagedModelDirectory {
        try ManagedModelDirectory.root(at: root, create: create).child("Refract Packages", create: create)
    }

    private func stagingName(_ entry: CatalogModel) -> String { ".\(entry.id).partial" }
    private func lockName(_ entry: CatalogModel) -> String { ".\(entry.id).lock" }

    private func checkMarker(_ directory: ManagedModelDirectory, entry: CatalogModel) throws {
        let marker = try directory.file(Self.marker)
        let expected = Data(entry.provenanceID.utf8)
        guard try marker.read(upToCount: expected.count + 1) == expected else {
            throw ModelError("The package ownership record does not match this catalog revision.")
        }
    }

    /// Only manifest files, their containing folders, the marker and Finder metadata belong to us.
    private func inventory(_ root: ManagedModelDirectory, entry: CatalogModel) throws -> [(String, Bool)] {
        let files = Set(entry.files.map(\.path) + [Self.marker])
        var folders: Set<String> = []
        for file in entry.files {
            var folder = (file.path as NSString).deletingLastPathComponent
            while !folder.isEmpty, folders.insert(folder).inserted { folder = (folder as NSString).deletingLastPathComponent }
        }
        var contents: [(String, Bool)] = []
        func inspect(_ directory: ManagedModelDirectory, prefix: String) throws {
            for name in try directory.names() {
                let path = prefix + name
                if folders.contains(path) {
                    try inspect(directory.child(name), prefix: path + "/")
                    contents.append((path, true))
                } else if files.contains(path) || name == ".DS_Store" {
                    _ = try directory.file(name)
                    contents.append((path, false))
                } else {
                    throw ModelError("This package contains additional files. Move those files out before continuing.")
                }
            }
        }
        try inspect(root, prefix: "")
        return contents
    }

    func hasPartialDownload(_ entry: CatalogModel) -> Bool {
        guard fm.fileExists(atPath: modelDirectory.appendingPathComponent("Refract Packages/\(stagingName(entry))/\(Self.marker)").path),
              let packages = try? packageDirectory(root: modelDirectory, create: false),
              let partial = try? packages.child(stagingName(entry)) else { return false }
        return (try? checkMarker(partial, entry: entry)) != nil
    }

    func cancelDownload(_ entry: CatalogModel) throws {
        if let transfer = transfers[entry.id] {
            downloads[entry.id]?.isCancelling = true
            downloads[entry.id]?.message = "Canceling download…"
            transfer.task.cancel()
            return
        }
        guard fm.fileExists(atPath: modelDirectory.appendingPathComponent("Refract Packages").path) else {
            downloads[entry.id] = nil
            return
        }
        let packages = try packageDirectory(root: modelDirectory, create: false)
        let lease = try packages.lock(lockName(entry))
        defer { withExtendedLifetime(lease) {} }
        try discardStaging(for: entry, in: packages)
        downloads[entry.id] = nil
    }

    private func discardStaging(for entry: CatalogModel, in packages: ManagedModelDirectory) throws {
        let name = stagingName(entry)
        guard try packages.exists(name) else { return }
        let staging = try packages.child(name)
        try checkMarker(staging, entry: entry)
        let contents = try inventory(staging, entry: entry)
        for (path, isDirectory) in contents where path != Self.marker {
            let (directory, leaf) = try staging.parent(of: path)
            try directory.remove(leaf, directory: isDirectory)
        }
        try staging.remove(Self.marker)
        try packages.remove(name, directory: true)
    }

    func download(_ requested: CatalogModel) async throws {
        guard let entry = Self.catalog.first(where: { $0.id == requested.id && $0.identity == requested.identity }), entry.canDownload else {
            throw ModelError("This model uses local import or requires qualification.")
        }
        guard transfers[entry.id] == nil else { throw ModelError("This model is already downloading.") }
        let packages = try packageDirectory(root: modelDirectory)
        let lease = try packages.lock(lockName(entry))
        defer { withExtendedLifetime(lease) {} }
        downloads[entry.id] = .init(fraction: 0, message: "Preparing download", isRunning: true)
        let token = UUID()
        let task = Task { try await acquire(entry, in: packages, token: token) }
        transfers[entry.id] = Transfer(token: token, task: task)
        defer { transfers[entry.id] = nil }
        do {
            let download = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if downloads[entry.id]?.isCancelling == true { throw CancellationError() }
            try Task.checkCancellation()
            if download.fromStaging { try packages.move(stagingName(entry), to: entry.id) }
            do {
                let binding = try packages.child(entry.id).identity()
                try register(download.model, installation: binding)
            }
            catch {
                if download.fromStaging { try packages.move(entry.id, to: stagingName(entry)) }
                throw error
            }
            downloads[entry.id] = .init(fraction: 1, message: "Installed", isRunning: false)
        } catch {
            if downloads[entry.id]?.isCancelling == true {
                do { try discardStaging(for: entry, in: packages) }
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

    private func acquire(_ entry: CatalogModel, in packages: ManagedModelDirectory, token: UUID) async throws
        -> (model: StudioModel, fromStaging: Bool) {
        try Task.checkCancellation()
        if try packages.exists(entry.id) {
            let installed = try packages.child(entry.id)
            try checkMarker(installed, entry: entry)
            _ = try inventory(installed, entry: entry)
            return (try await inspector.installedModel(in: installed.url, entry: entry), false)
        }
        let name = stagingName(entry)
        let resumed = try packages.exists(name)
        let staging = try packages.child(name, create: !resumed)
        if resumed {
            try checkMarker(staging, entry: entry)
            _ = try inventory(staging, entry: entry)
        } else {
            let marker = try staging.file(Self.marker, writing: true, create: true, exclusive: true)
            try marker.write(contentsOf: Data(entry.provenanceID.utf8))
            try marker.close()
        }
        try staging.makePrivate()
        var completed: Int64 = 0
        for file in entry.files {
            try Task.checkCancellation()
            let target = staging.url.appendingPathComponent(file.path)
            let (directory, leaf) = try staging.parent(of: file.path, create: true)
            let output = try directory.file(leaf, writing: true, create: true)
            defer { try? output.close() }
            var received = Int64(try output.seekToEnd())
            if received >= file.size {
                if received == file.size, try await inspector.digest(target, gitBlob: file.digest.count == 40) == file.digest {
                    completed += file.size
                    continue
                }
                // Only a definite size/digest mismatch invalidates a prefix. Never remove a pathname recursively.
                try output.truncate(atOffset: 0)
                received = 0
            }
            let start = completed
            let transfer = ModelTransfer(output: output, received: received, size: file.size) { [weak self] count in
                Task { @MainActor in
                    guard let self, self.transfers[entry.id]?.token == token,
                          self.downloads[entry.id]?.isCancelling != true else { return }
                    self.downloads[entry.id] = .init(fraction: Double(start + count) / Double(entry.bytes), message: "Downloading \(file.path)", isRunning: true)
                }
            }
            try await transfer.run(url: entry.downloadURL(file))
            try output.close()
            try await inspector.check(file, at: target)
            completed += file.size
        }
        try Task.checkCancellation()
        downloads[entry.id] = .init(fraction: 1, message: "Verifying package", isRunning: true)
        _ = try inventory(staging, entry: entry)
        let checked = try await inspector.installedModel(in: staging.url, entry: entry)
        let final = packages.url.appendingPathComponent(entry.id, isDirectory: true)
        let target = entry.checkpointFile.map { final.appendingPathComponent($0.path) } ?? final
        let model = StudioModel(id: checked.id, name: checked.name, kind: checked.kind, path: target.path,
                                variant: checked.variant, configPath: checked.configPath, precision: checked.precision,
                                license: checked.license, bytes: checked.bytes, managed: checked.managed)
        return (model, true)
    }
}
