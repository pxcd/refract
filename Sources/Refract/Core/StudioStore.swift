import AppKit
import Combine
import Foundation

@MainActor
final class StudioStore: ObservableObject {
    @Published var activeGenerationID: String {
        didSet {
            if oldValue != activeGenerationID { restoreSamplingPreset() }
            persistPreferences()
        }
    }
    @Published var activeEnhancementID: String { didSet { persistPreferences() } }
    @Published var outputDirectory: URL { didSet { persistPreferences() } }
    @Published var exportFormat: ExportFormat { didSet { persistPreferences() } }
    @Published var jpegQuality: Double { didSet { persistPreferences() } }
    @Published var generation = GenerationOptions() {
        didSet {
            guard !activeGenerationID.isEmpty, SamplingPreset(oldValue) != SamplingPreset(generation) else { return }
            if let data = try? JSONEncoder().encode(SamplingPreset(generation)) {
                defaults.set(data, forKey: "sampling-" + activeGenerationID)
            }
        }
    }
    @Published var enhancement = EnhancementOptions()
    @Published private(set) var jobs: [StudioJob] = []
    @Published var notice: String?
    @Published var selectedResult: StudioResult?

    let models: ModelStore
    private let worker: InferenceClient
    private let defaults: UserDefaults
    private let stateURL: URL
    private var queueReadError: String?
    private var underCriticalPressure = false
    private struct VerifiedRoute {
        let directory: URL
        let paths: [String: URL]
    }
    private var verifiedRoute: VerifiedRoute?
    private var scratchSession: RuntimeScratch?
    private var runningID: UUID?
    private var runner: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var modelObservation: AnyCancellable?

    init(models: ModelStore, worker: InferenceClient, directory: URL, defaults: UserDefaults = .standard) {
        self.models = models
        self.worker = worker
        self.defaults = defaults
        stateURL = directory.appendingPathComponent("jobs.json")
        activeGenerationID = defaults.string(forKey: "generationModel") ?? ""
        activeEnhancementID = defaults.string(forKey: "enhancementModel") ?? ""
        outputDirectory = defaults.url(forKey: "outputFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Refract")
        exportFormat = ExportFormat(rawValue: defaults.string(forKey: "exportType") ?? "") ?? .png
        jpegQuality = defaults.object(forKey: "jpegQuality") as? Double ?? 0.92
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                jobs = try JSONDecoder().decode([StudioJob].self, from: Data(contentsOf: stateURL))
                for i in jobs.indices where jobs[i].status == .running {
                    jobs[i].status = .failed
                    jobs[i].message = "Interrupted. Retry to continue from saved outputs."
                }
                let group = activeGenerationGroupID ?? UUID()
                for i in jobs.indices where jobs[i].status == .pending && jobs[i].recipe.generator != nil && jobs[i].generationGroupID == nil {
                    jobs[i].generationGroupID = group
                }
            }
        } catch {
            queueReadError = "Could not read " + stateURL.path + ". The existing queue is preserved. " + error.localizedDescription
            notice = queueReadError
        }
        restoreSamplingPreset()
        modelObservation = models.$models.sink { [weak self] installed in
            // The catalog publishes its new value before the property itself is set.
            self?.selectDefaults(from: installed)
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.underCriticalPressure = self.pressure?.data.contains(.critical) == true
            if self.underCriticalPressure { self.memoryCritical() } else { self.schedule() }
        }
        pressure.resume()
        self.pressure = pressure
        scratchSession = try? RuntimeScratch()
        schedule()
    }

    var generationProfile: GenerationProfile {
        let variant = models.models.first { $0.id == activeGenerationID }?.variant
            ?? ModelStore.catalog.first { $0.identity == activeGenerationID }?.variant
        return variant.flatMap(GenerationProfile.init(rawValue:)) ?? .sdxl
    }

    private func restoreSamplingPreset() {
        let key = "sampling-" + activeGenerationID
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SamplingPreset.self, from: $0) }
        (saved ?? generationProfile.defaultSampling).apply(to: &generation)
    }

    private func selectDefaults(from installed: [StudioModel]) {
        if !installed.contains(where: { $0.id == activeGenerationID && $0.kind == .generation }) {
            activeGenerationID = installed.first(where: { $0.kind == .generation })?.id ?? ""
        }
        if !installed.contains(where: { $0.id == activeEnhancementID && $0.kind == .enhancement }) {
            activeEnhancementID = (installed.first(where: { $0.kind == .enhancement && $0.variant.contains("3b") }) ?? installed.first(where: { $0.kind == .enhancement }))?.id ?? ""
        }
    }

    func generate() {
        do {
            var opts = generation
            guard !opts.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError("Enter a prompt.") }
            let generator = try selected(activeGenerationID, .generation)
            guard let profile = GenerationProfile(rawValue: generator.variant) else {
                throw StudioError("This generation model requires a supported runtime.")
            }
            profile.configure(&opts)
            let reference = try opts.reference.map(InputImage.init)
            let referenceSize = try reference.map { try ImageFiles.dimensions(of: $0.url) }
            if let reference, let referenceSize, opts.preserveReferenceSize == true {
                (opts.width, opts.height) = referenceSize
                try reference.validate()
            } else {
                opts.preserveReferenceSize = nil
                let multiple = profile.dimensionMultiple
                guard opts.width >= 64, opts.height >= 64, opts.width.isMultiple(of: multiple), opts.height.isMultiple(of: multiple) else {
                    throw StudioError("Enter image dimensions of at least 64 pixels on each side, in multiples of \(multiple).")
                }
            }
            try ImageFiles.validateDimensions(width: opts.width, height: opts.height)
            guard (1...100).contains(opts.count), opts.steps > 0, (0...1).contains(opts.strength), opts.guidance.isFinite,
                  opts.seed.map({ (0...Int(UInt32.max)).contains($0) }) ?? true else {
                throw StudioError("Check the image count (1–100), steps, guidance, reference strength, and seed.")
            }
            let enhancer = opts.autoEnhance ? try selected(activeEnhancementID, .enhancement) : nil
            let adapters = try opts.loras.map { try selected($0.modelID, .lora) }
            let seeds = (0..<opts.count).map { i in opts.seed.map { ($0 + i) % (Int(UInt32.max) + 1) } ?? Int.random(in: 0...Int(UInt32.max)) }
            enqueue(JobRecipe(generator: generator, enhancer: enhancer, loras: adapters, generation: opts, enhancement: enhancement,
                              reference: reference, inputs: [], seeds: seeds, directory: outputDirectory, format: exportFormat, jpegQuality: jpegQuality),
                    title: opts.count == 1 ? "Generate image" : "Generate \(opts.count) images")
        } catch { notice = error.localizedDescription }
    }

    func useGenerationSettings(from resultID: UUID, in jobID: UUID) throws {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let generator = job.recipe.generator,
              let result = job.results.first(where: { $0.id == resultID }) else {
            throw StudioError("Generation settings are unavailable for this image.")
        }

        let missing = ([generator] + job.recipe.loras).filter { saved in
            !models.models.contains { model in
                model.id == saved.id && model.kind == saved.kind && FileManager.default.fileExists(atPath: model.path)
            }
        }
        guard missing.isEmpty else {
            let names = missing.map(\.name).joined(separator: ", ")
            throw StudioError("Reinstall or relink \(names) in Models to use these settings.")
        }

        activeGenerationID = generator.id
        var draft = generation
        let saved = job.recipe.generation
        draft.prompt = saved.prompt
        draft.negativePrompt = saved.negativePrompt
        draft.seed = result.seed
        draft.loras = saved.loras
        generation = draft
    }

    func enhance(_ urls: [URL]) {
        do {
            let model = try selected(activeEnhancementID, .enhancement)
            let options = enhancement, directory = outputDirectory, format = exportFormat, quality = jpegQuality
            Task {
                do {
                    let inputs = try await Task.detached(priority: .userInitiated) { try ImageFiles.expand(urls) }.value
                    enqueue(JobRecipe(generator: nil, enhancer: model, loras: [], generation: GenerationOptions(), enhancement: options, reference: nil,
                                      inputs: inputs, seeds: inputs.map { _ in Int.random(in: 0...Int(UInt32.max)) },
                                      directory: directory, format: format, jpegQuality: quality),
                            title: inputs.count == 1 ? "Enhance " + inputs[0].url.lastPathComponent : "Enhance \(inputs.count) images")
                } catch { notice = error.localizedDescription }
            }
        } catch { notice = error.localizedDescription }
    }

    private func selected(_ id: String, _ kind: ModelKind) throws -> StudioModel {
        guard let model = models.models.first(where: { $0.id == id && $0.kind == kind }) else {
            throw StudioError("Choose an installed " + kind.rawValue + " model in Models.")
        }
        return model
    }

    private func enqueue(_ recipe: JobRecipe, title: String) {
        if let queueReadError { notice = queueReadError; return }
        var job = StudioJob(id: UUID(), title: title, recipe: recipe)
        if recipe.generator != nil { job.generationGroupID = activeGenerationGroupID ?? UUID() }
        jobs.insert(job, at: 0)
        persist()
        schedule()
    }

    private var activeGenerationGroupID: UUID? {
        jobs.first { [.pending, .running].contains($0.status) && $0.generationGroupID != nil }?.generationGroupID
    }

    func generationBatchPosition(for job: StudioJob) -> (current: Int, total: Int)? {
        guard job.status == .running, let groupID = job.generationGroupID else { return nil }
        let group = jobs.filter { $0.generationGroupID == groupID }
        guard group.count > 1 else { return nil }
        let finished = group.count { $0.status != .pending && $0.status != .running }
        return (finished + 1, group.count)
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.running,.pending].contains(jobs[i].status) else { return }
        jobs[i].status = .cancelled
        jobs[i].message = "Cancelled"
        if runningID == id { runner?.cancel(); stopWorker() }
        persist()
    }

    func removeQueuedJobs() {
        guard jobs.contains(where: { $0.status == .pending }) else { return }
        // The scheduler can reserve a pending job before its task starts.
        if jobs.contains(where: { $0.id == runningID && $0.status == .pending }) {
            runner?.cancel()
        }
        jobs.removeAll { $0.status == .pending }
        persist()
    }

    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.failed,.cancelled].contains(jobs[i].status) else { return }
        if jobs[i].recipe.generator != nil { jobs[i].generationGroupID = activeGenerationGroupID ?? UUID() }
        jobs[i].status = .pending
        jobs[i].message = "Queued for retry"
        persist()
        schedule()
    }

    func shutdown() {
        if let id = runningID { cancel(id) }
        stopWorker()
        persist()
    }

    func save(_ url: URL, to destination: URL, settings: SharedGenerationSettings? = nil) throws {
        let format: ExportFormat
        switch destination.pathExtension.lowercased() {
        case "png": format = .png
        case "tif", "tiff": format = .tiff
        case "jpg", "jpeg": format = .jpeg
        default: throw StudioError("Choose a PNG, JPEG, or TIFF extension.")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw StudioError("Choose a new filename to preserve the existing file.") }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".refract-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        // Encode from pixels even for same-format exports to drop embedded source metadata.
        try ImageFiles.export(url, to: temp, format: format, quality: jpegQuality)
        try ImageFiles.publishStaged(temp, to: destination, receipt: try settings.map { try JSONEncoder.pretty.encode($0) })
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    var generationHistory: [GenerationHistoryEntry] {
        jobs.flatMap { job -> [GenerationHistoryEntry] in
            guard let model = job.recipe.generator else { return [] }
            let settings = job.recipe.generation
            return job.results.reversed().compactMap { result in
                guard job.hiddenHistoryResults?.contains(result.id) != true else { return nil }
                return GenerationHistoryEntry(jobID: job.id, result: result, prompt: settings.prompt,
                                              negativePrompt: settings.negativePrompt, modelName: model.name,
                                              modelVariant: model.variant)
            }
        }
    }

    func clearGenerationHistory() throws {
        if let queueReadError { throw StudioError(queueReadError) }
        var updated = jobs
        for index in updated.indices where updated[index].recipe.generator != nil {
            let results = updated[index].results
            if !results.isEmpty {
                updated[index].hiddenHistoryResults = Set(results.map(\.id))
            }
        }
        try writeQueue(updated)
        jobs = updated
    }

    var hasFinishedGenerationJobs: Bool {
        jobs.contains { $0.recipe.generator != nil && $0.status != .running && $0.status != .pending }
    }

    func eraseFinishedGenerationJobs() throws {
        if let queueReadError { throw StudioError(queueReadError) }
        let remaining = jobs.filter { $0.recipe.generator == nil || $0.status == .running || $0.status == .pending }
        try writeQueue(remaining)
        jobs = remaining
        if let selectedResult, !remaining.contains(where: { $0.results.contains(selectedResult) }) {
            self.selectedResult = nil
        }
    }

    func clearFilmstrip(generated: Bool) {
        for index in jobs.indices where (jobs[index].recipe.generator != nil) == generated && !jobs[index].results.isEmpty {
            jobs[index].hiddenFilmstripResults = Set(jobs[index].results.map(\.id))
        }
        if let selectedResult, jobs.contains(where: { $0.hiddenFilmstripResults?.contains(selectedResult.id) == true }) {
            self.selectedResult = nil
        }
        persist()
    }

    func canTrashGeneratedResult(_ job: StudioJob) -> Bool {
        job.recipe.generator != nil && runningID != job.id && job.status != .pending && job.status != .running
    }

    func trashGeneratedResult(_ id: UUID, using trash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) throws {
        guard let index = jobs.firstIndex(where: { $0.results.contains(where: { $0.id == id }) }),
              canTrashGeneratedResult(jobs[index]),
              let result = jobs[index].results.first(where: { $0.id == id }) else {
            throw StudioError("Wait for this generation job to finish before moving its output to the Trash.")
        }
        if let queueReadError { throw StudioError(queueReadError) }
        let directory = jobs[index].recipe.directory.standardizedFileURL
        let output = [result.original, result.enhanced].compactMap { $0 }
        guard output.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == directory.path }) else {
            throw StudioError("The generated files are outside their original output folder.")
        }
        let fm = FileManager.default
        var files: [URL] = []
        for image in output {
            if fm.fileExists(atPath: image.path) {
                let values = try image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw StudioError("The output has been replaced. Check its location in Finder.")
                }
                files.append(image)
            }
            let sidecar = image.appendingPathExtension("json")
            if fm.fileExists(atPath: sidecar.path) {
                guard let receipt = try? OutputReceipt.read(sidecar), receipt.jobID == jobs[index].id,
                      receipt.index == result.index, receipt.request.seed == result.seed else {
                    throw StudioError("An unrelated companion file occupies this location. Check it in Finder.")
                }
                files.append(sidecar)
            }
        }
        if !files.isEmpty {
            let name = "Refract " + result.original.deletingPathExtension().lastPathComponent
            let group = directory.appendingPathComponent(name, isDirectory: true)
            let staging = fm.fileExists(atPath: group.path)
                ? directory.appendingPathComponent(name + " " + UUID().uuidString, isDirectory: true) : group
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            // Move the complete set to the Trash as one item. Roll back any partial staging.
            var moves: [(original: URL, staged: URL)] = []
            do {
                for file in files {
                    let staged = staging.appendingPathComponent(file.lastPathComponent)
                    try fm.moveItem(at: file, to: staged)
                    moves.append((file, staged))
                }
                try trash(staging)
            } catch {
                for move in moves.reversed() {
                    try fm.moveItem(at: move.staged, to: move.original)
                }
                _ = rmdir(staging.path)
                throw error
            }
        }
        jobs[index].trashedResultIndices = (jobs[index].trashedResultIndices ?? []).union([result.index])
        jobs[index].hiddenFilmstripResults?.remove(id)
        jobs[index].hiddenHistoryResults?.remove(id)
        jobs[index].results.removeAll { $0.id == id }
        if selectedResult?.id == id {
            selectedResult = jobs[index].filmstripResults.last
                ?? jobs.first(where: { $0.recipe.generator != nil && !$0.filmstripResults.isEmpty })?.filmstripResults.last
        }
        persist()
    }

    private func stopWorker() {
        worker.stop()
        if let directory = verifiedRoute?.directory { try? FileManager.default.removeItem(at: directory) }
        verifiedRoute = nil
    }

    private func makeScratchDirectory() throws -> URL {
        if let scratchSession {
            do { return try scratchSession.makeDirectory() }
            catch { self.scratchSession = nil }
        }
        let session = try RuntimeScratch()
        scratchSession = session
        return try session.makeDirectory()
    }

    private func verifiedPaths(for stage: [StudioModel]) async throws -> [String: URL] {
        if let verifiedRoute, Set(verifiedRoute.paths.keys) == Set(stage.map(\.id)) {
            return verifiedRoute.paths
        }
        if verifiedRoute != nil { stopWorker() }
        let fm = FileManager.default
        let root = try makeScratchDirectory()
        do {
            var paths: [String: URL] = [:]
            for model in stage where paths[model.id] == nil {
                paths[model.id] = try await ModelInspector.shared.inferenceSnapshot(of: model, in: root)
            }
            try Task.checkCancellation()
            verifiedRoute = VerifiedRoute(directory: root, paths: paths)
            return paths
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    private func schedule() {
        guard !underCriticalPressure, runningID == nil, let job = jobs.last(where: { $0.status == .pending }) else { return }
        runningID = job.id
        runner = Task { [weak self] in await self?.run(job) }
    }

    private func update(_ id: UUID, _ body: (inout StudioJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[index]) }
    }

    private func run(_ job: StudioJob) async {
        let start = Date()
        let previousTime = job.elapsed
        defer {
            if Task.isCancelled || !jobs.contains(where: { $0.status == .pending }) { stopWorker() }
            update(job.id) { $0.elapsed = previousTime + Date().timeIntervalSince(start) }
            persist()
            runningID = nil
            runner = nil
            schedule()
        }
        do {
            try Task.checkCancellation()
            update(job.id) { $0.status = .running; $0.message = "Verifying model files"; $0.progress = nil }
            persist()
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update(job.id) { $0.elapsed = previousTime + Date().timeIntervalSince(start) } }
            }
            defer { timer.invalidate() }
            try await process(job)
            try Task.checkCancellation()
            update(job.id) { $0.status = .completed; $0.progress = 1; $0.message = "Completed" }
        } catch {
            stopWorker()
            if !Task.isCancelled { update(job.id) { $0.status = .failed; $0.message = error.localizedDescription } }
        }
    }

    private func process(_ job: StudioJob) async throws {
        let recipe = job.recipe
        let fm = FileManager.default
        let scratch = try makeScratchDirectory()
        defer { try? fm.removeItem(at: scratch) }
        var referenceCopy: URL?
        var results = Dictionary(uniqueKeysWithValues: job.results.map { ($0.index,$0) })
        let routes = [recipe.generator, recipe.enhancer].compactMap { $0 }
        let count = recipe.seeds.count
        guard count > 0, !routes.isEmpty else { throw StudioError("Empty job.") }
        for (stage, model) in routes.enumerated() {
            try Task.checkCancellation()
            let generating = model.kind == .generation
            let adapters = generating ? recipe.loras : []
            var stagePaths: [String: URL]?
            var schedulerDefaults: (predictionType: String?, zeroTerminalSNR: Bool?) = (nil, nil)
            for (i, seed) in recipe.seeds.enumerated() {
                try Task.checkCancellation()
                if job.trashedResultIndices?.contains(i) == true { continue }
                let existing = results[i]
                if generating, let existing, fm.fileExists(atPath: existing.original.path) { continue }
                if !generating, let enhanced = existing?.enhanced, fm.fileExists(atPath: enhanced.path) { continue }
                var input = recipe.reference?.url
                if !generating {
                    if recipe.generator != nil {
                        guard let original = results[i]?.original else { throw StudioError("The generated original is missing.") }
                        input = original
                    } else {
                        try recipe.inputs[i].validate()
                        input = recipe.inputs[i].url
                    }
                }
                let raw = scratch.appendingPathComponent(UUID().uuidString + ".png")
                let (width,height) = try !generating ? ImageFiles.outputDimensions(for: input!, options: recipe.enhancement) : (recipe.generation.width,recipe.generation.height)
                try ImageFiles.validateDimensions(width: width, height: height)
                let opts = recipe.generation
                let request = InferenceRequest(operation: generating ? "generate" : "enhance", modelID: model.id, modelPath: model.path, modelVariant: model.variant,
                                            configPath: model.configPath, inputPath: input?.path, outputPath: raw.path, prompt: opts.prompt,
                                            negativePrompt: opts.negativePrompt, width: width, height: height, steps: opts.steps,
                                            guidance: opts.guidance, seed: seed, strength: opts.strength, sampler: opts.sampler, scheduler: opts.scheduler, predictionType: opts.predictionType, zeroTerminalSNR: opts.zeroTerminalSNR,
                                            loras: zip(adapters,opts.loras).map { AdapterWeight(id:$0.0.id, path:$0.0.path, scale:$0.1.scale) }, softness: recipe.enhancement.softness,
                                            preserveReferenceSize: generating ? opts.preserveReferenceSize : nil)
                let action = generating ? "Generating" : "Enhancing"
                let label = count == 1 ? action : "\(action) \(i + 1) of \(count)"
                let completed = stage * count + i
                let total = Double(count * routes.count)
                func progress(_ fraction: Double?, _ message: String) {
                    self.update(job.id) {
                        $0.message = message.isEmpty ? label : label + " · " + message
                        if let fraction {
                            let reported = (Double(completed) + min(max(fraction, 0), 1)) / total
                            $0.progress = max($0.progress ?? 0, reported)
                        } else if completed > 0 {
                            $0.progress = max($0.progress ?? 0, Double(completed) / total)
                        }
                    }
                }
                let base = recipe.generator == nil ? String(recipe.inputs[i].url.deletingPathExtension().lastPathComponent.prefix(70)) : "refract"
                let suffix = generating ? "" : "-\(width)x\(height)"
                let name = base + "-" + job.id.uuidString.prefix(8).lowercased() + String(format:"-%03d", i + 1) + suffix
                let output = recipe.directory.appendingPathComponent(name).appendingPathExtension(recipe.format.fileExtension)
                let alreadyPublished = try recover(output, job: job, index: i, request: request)
                if !alreadyPublished {
                    if stagePaths == nil {
                        var stageModels: [StudioModel] = []
                        for expected in [model] + adapters {
                            stageModels.append(try await models.resolve(expected))
                        }
                        stagePaths = try await verifiedPaths(for: stageModels)
                        if generating, model.variant == GenerationProfile.sdxl.rawValue,
                           opts.predictionType == nil || opts.zeroTerminalSNR == nil {
                            schedulerDefaults = try await ModelInspector.shared.legacySchedulerDefaults(for: stageModels[0])
                        }
                    }
                    guard let paths = stagePaths, let modelURL = paths[model.id] else { throw StudioError("Missing verified model.") }
                    var inferenceRequest = request
                    inferenceRequest.modelPath = modelURL.path
                    inferenceRequest.configPath = nil
                    inferenceRequest.predictionType = opts.predictionType ?? schedulerDefaults.predictionType
                    inferenceRequest.zeroTerminalSNR = opts.zeroTerminalSNR ?? schedulerDefaults.zeroTerminalSNR
                    inferenceRequest.loras = try zip(adapters, opts.loras).map { adapter, choice in
                        guard let url = paths[adapter.id] else { throw StudioError("Missing verified LoRA.") }
                        return AdapterWeight(id: adapter.id, path: url.path, scale: choice.scale)
                    }
                    if generating, let reference = recipe.reference {
                        if referenceCopy == nil {
                            let copy = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension(reference.url.pathExtension)
                            try await Task.detached(priority: .utility) {
                                try reference.validate()
                                try FileManager.default.copyItem(at: reference.url.resolvingSymlinksInPath(), to: copy)
                                try reference.validate()
                                _ = try ImageFiles.dimensions(of: copy)
                            }.value
                            referenceCopy = copy
                        }
                        inferenceRequest.inputPath = referenceCopy?.path
                    }
                    progress(nil,"Loading")
                    try await worker.render(inferenceRequest, progress: progress)
                    try Task.checkCancellation()
                    let dimensions = try ImageFiles.dimensions(of: raw)
                    guard dimensions == (width,height) else { throw StudioError("The model returned \(dimensions.0) × \(dimensions.1), expected \(width) × \(height).") }
                    let sample = worker.measuredPeakBytes.map { ModelMemorySample(width: width, height: height, peak: $0) }
                    let receipt = OutputReceipt(jobID: job.id, index: i, model: .init(id: model.id),
                                                request: .init(operation: request.operation, seed: seed, width: width, height: height),
                                                memory: sample, processingSize: worker.processingSize)
                    let data = try JSONEncoder.pretty.encode(receipt)
                    let metadataSource = generating ? nil : (results[i]?.original ?? input)
                    try await Task.detached(priority: .utility) {
                        try ImageFiles.publish(raw: raw, output: output, format: recipe.format, quality: recipe.jpegQuality, source: metadataSource, receipt: data)
                    }.value
                }
                let outputDate = alreadyPublished
                    ? (try? output.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    : Date()
                var item = existing ?? StudioResult(id: UUID(), original: generating ? output : input!, enhanced: nil,
                                                    seed: seed, index: i, createdAt: generating ? outputDate : nil)
                if !generating { item.enhanced = output }
                try? fm.removeItem(at: raw)
                results[i] = item
                update(job.id) {
                    $0.results = results.values.sorted { $0.index < $1.index }
                    $0.progress = Double(completed + 1) / total
                }
                if jobs.first(where: { $0.id == job.id })?.hiddenFilmstripResults?.contains(item.id) != true {
                    selectedResult = item
                }
                persist()
            }
        }
    }

    /// Recover the interval between publishing an output and checkpointing the queue.
    private func recover(_ output: URL, job: StudioJob, index: Int, request: InferenceRequest) throws -> Bool {
        let fm = FileManager.default
        let receiptURL = output.appendingPathExtension("json")
        let hasFile = fm.fileExists(atPath: output.path)
        guard hasFile || fm.fileExists(atPath: receiptURL.path) else { return false }
        guard let receipt = try? OutputReceipt.read(receiptURL),
              receipt.jobID == job.id, receipt.index == index, receipt.model.id == request.modelID,
              receipt.request.operation == request.operation, receipt.request.seed == request.seed,
              receipt.request.width == request.width, receipt.request.height == request.height else {
            throw StudioError("An unrelated file occupies " + output.lastPathComponent + ". Move it before retrying.")
        }
        if hasFile {
            guard try ImageFiles.dimensions(of: output) == (request.width, request.height) else {
                throw StudioError("The previously published output has changed. Move it before retrying.")
            }
            return true
        }
        // Only the receipt for this exact job/item was published before interruption.
        guard unlink(receiptURL.path) == 0 else { throw StudioError("Could not remove the incomplete output receipt.") }
        return false
    }

    private func memoryCritical() {
        guard let id = runningID else { return }
        cancel(id)
        update(id) { $0.status = .failed; $0.message = "macOS reported critical memory pressure. Completed files are safe. Retry when more memory is available." }
        persist()
    }

    private func persist() {
        guard queueReadError == nil else { return }
        do {
            try writeQueue(jobs)
        } catch { notice = "Could not save the queue. " + error.localizedDescription }
    }

    private func writeQueue(_ state: [StudioJob]) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func persistPreferences() {
        defaults.set(activeGenerationID, forKey:"generationModel")
        defaults.set(activeEnhancementID, forKey:"enhancementModel")
        defaults.set(outputDirectory, forKey:"outputFolder")
        defaults.set(exportFormat.rawValue, forKey:"exportType")
        defaults.set(jpegQuality, forKey:"jpegQuality")
    }


}

// Keep the nested keys compatible with legacy receipts; prompts and local paths are never required for recovery.
private struct OutputReceipt: Codable {
    struct Model: Codable { let id: String }
    struct Request: Codable {
        let operation: String
        let seed: Int
        let width: Int
        let height: Int
    }
    let jobID: UUID
    let index: Int
    let model: Model
    let request: Request
    let memory: ModelMemorySample?
    let processingSize: ModelImageSize?

    static func read(_ url: URL) throws -> Self {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StudioError("Cannot open the output receipt.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = 4 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw StudioError("Expected a regular output receipt of at most 4 MiB.")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return encoder
    }
}
