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
    @Published private(set) var memorySamples: [String:ModelMemorySample] = [:]

    let models: ModelStore
    private let worker: InferenceClient
    private let defaults: UserDefaults
    private let stateURL: URL
    private var queueReadError: String?
    private var underCriticalPressure = false
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
            }
        } catch {
            queueReadError = "Could not read " + stateURL.path + ". The existing queue is preserved. " + error.localizedDescription
            notice = queueReadError
        }
        if let data = defaults.data(forKey: "memoryMeasurements") {
            memorySamples = (try? JSONDecoder().decode([String:ModelMemorySample].self, from: data)) ?? [:]
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
        schedule()
    }

    private func restoreSamplingPreset() {
        let key = "sampling-" + activeGenerationID
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SamplingPreset.self, from: $0) }
        (saved ?? SamplingPreset(GenerationOptions())).apply(to: &generation)
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
            let opts = generation
            guard !opts.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError("Enter a prompt.") }
            guard opts.width >= 64, opts.height >= 64, opts.width.isMultiple(of: 8), opts.height.isMultiple(of: 8),
                  (1...100).contains(opts.count), opts.steps > 0, (0...1).contains(opts.strength), opts.guidance.isFinite,
                  opts.seed.map({ (0...Int(UInt32.max)).contains($0) }) ?? true else {
                throw StudioError("Check image dimensions (multiples of eight), image count (1–100), steps, and seed.")
            }
            let generator = try selected(activeGenerationID, .generation)
            let enhancer = opts.autoEnhance ? try selected(activeEnhancementID, .enhancement) : nil
            let adapters = try opts.loras.map { try selected($0.modelID, .lora) }
            let seeds = (0..<opts.count).map { i in opts.seed.map { ($0 + i) % (Int(UInt32.max) + 1) } ?? Int.random(in: 0...Int(UInt32.max)) }
            let reference = try opts.reference.map(InputImage.init)
            enqueue(JobRecipe(generator: generator, enhancer: enhancer, loras: adapters, generation: opts, enhancement: enhancement,
                              reference: reference, inputs: [], seeds: seeds, directory: outputDirectory, format: exportFormat, jpegQuality: jpegQuality),
                    title: opts.count == 1 ? "Generate image" : "Generate \(opts.count) images")
        } catch { notice = error.localizedDescription }
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
        jobs.insert(StudioJob(id: UUID(), title: title, recipe: recipe), at: 0)
        persist()
        schedule()
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.running,.pending].contains(jobs[i].status) else { return }
        jobs[i].status = .cancelled
        jobs[i].message = "Cancelled"
        if runningID == id { runner?.cancel(); worker.stop() }
        persist()
    }

    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), [.failed,.cancelled].contains(jobs[i].status) else { return }
        jobs[i].status = .pending
        jobs[i].message = "Queued for retry"
        persist()
        schedule()
    }

    func shutdown() {
        if let id = runningID { cancel(id) }
        worker.stop()
        persist()
    }

    func save(_ url: URL, to destination: URL) throws {
        if url.standardizedFileURL == destination.standardizedFileURL { return }
        let fileExtension = destination.pathExtension.lowercased()
        let format: ExportFormat
        switch fileExtension {
        case "png": format = .png
        case "tif", "tiff": format = .tiff
        case "jpg", "jpeg": format = .jpeg
        default: throw StudioError("Choose a PNG, JPEG, or TIFF extension.")
        }
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: destination.path)
        if existing { throw StudioError("Choose a new filename to preserve the existing file.") }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".refract-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let copying = format.fileExtension == url.pathExtension.lowercased()
        if copying { try fm.copyItem(at: url, to: temp) }
        else { try ImageFiles.export(url, to: temp, format: format, quality: jpegQuality, metadataSource: url) }
        let sidecar = url.appendingPathExtension("json")
        var metadata = fm.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil
        if let data = metadata, var receipt = try? JSONDecoder().decode(OutputReceipt.self, from: data) {
            receipt.request.outputPath = destination.path
            receipt.exportFormat = format
            if !copying { receipt.jpegQuality = jpegQuality }
            metadata = try JSONEncoder.pretty.encode(receipt)
        }
        try ImageFiles.publishStaged(temp, to: destination, receipt: metadata)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

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
            if Task.isCancelled || !jobs.contains(where: { $0.status == .pending }) { worker.stop() }
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
            let recipe = job.recipe
            var resolved: [String: StudioModel] = [:]
            for model in [recipe.generator,recipe.enhancer].compactMap({ $0 }) + recipe.loras {
                try Task.checkCancellation()
                resolved[model.id] = try await models.resolve(model)
            }
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update(job.id) { $0.elapsed = previousTime + Date().timeIntervalSince(start) } }
            }
            defer { timer.invalidate() }
            try await process(job, resolved: resolved)
            try Task.checkCancellation()
            update(job.id) { $0.status = .completed; $0.progress = 1; $0.message = "Completed" }
        } catch {
            worker.stop()
            if !Task.isCancelled { update(job.id) { $0.status = .failed; $0.message = error.localizedDescription } }
        }
    }

    private func process(_ job: StudioJob, resolved: [String: StudioModel]) async throws {
        let recipe = job.recipe
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("refract-" + job.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var referenceCopy: URL?
        var results = Dictionary(uniqueKeysWithValues: job.results.map { ($0.index,$0) })
        let routes = [recipe.generator,recipe.enhancer].compactMap { $0.flatMap { resolved[$0.id] } }
        let adapters = recipe.loras.compactMap { resolved[$0.id] }
        let count = recipe.seeds.count
        guard count > 0, !routes.isEmpty else { throw StudioError("Empty job.") }
        for (stage,model) in routes.enumerated() {
            let generating = model.kind == .generation
            for (i, seed) in recipe.seeds.enumerated() {
                try Task.checkCancellation()
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
                let opts = recipe.generation
                let request = WorkerRequest(operation: generating ? "generate" : "enhance", modelID: model.id, modelPath: model.path, modelVariant: model.variant,
                                            configPath: model.configPath, inputPath: input?.path, outputPath: raw.path, prompt: opts.prompt,
                                            negativePrompt: opts.negativePrompt, width: width, height: height, steps: opts.steps,
                                            guidance: opts.guidance, seed: seed, strength: opts.strength, sampler: opts.sampler, scheduler: opts.scheduler, predictionType: opts.predictionType, zeroTerminalSNR: opts.zeroTerminalSNR,
                                            loras: zip(adapters,opts.loras).map { AdapterWeight(id:$0.0.id, path:$0.0.path, scale:$0.1.scale) }, softness: recipe.enhancement.softness)
                let label = "\(generating ? "Generating" : "Enhancing") \(i + 1) of \(count)"
                func progress(_ fraction: Double?, _ message: String) {
                    self.update(job.id) {
                        $0.message = message.isEmpty ? label : label + " · " + message
                        $0.progress = fraction.map { (Double(stage * count + i) + min(max($0,0),1)) / Double(count * routes.count) }
                    }
                }
                let base = recipe.generator == nil ? String(recipe.inputs[i].url.deletingPathExtension().lastPathComponent.prefix(70)) : "refract"
                let suffix = generating ? "" : "-\(width)x\(height)"
                let name = base + "-" + job.id.uuidString.prefix(8).lowercased() + String(format:"-%03d", i + 1) + suffix
                let output = recipe.directory.appendingPathComponent(name).appendingPathExtension(recipe.format.fileExtension)
                let alreadyPublished = try recover(output, job: job, index: i, request: request)
                if !alreadyPublished {
                    var inferenceRequest = request
                    if generating, let reference = recipe.reference {
                        if referenceCopy == nil {
                            let copy = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension(reference.url.pathExtension)
                            try await Task.detached(priority: .utility) {
                                try reference.validate()
                                try FileManager.default.copyItem(at: reference.url.resolvingSymlinksInPath(), to: copy)
                                try reference.validate()
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
                    if let sample {
                        memorySamples[model.id] = sample
                        if let data = try? JSONEncoder().encode(memorySamples) { defaults.set(data, forKey: "memoryMeasurements") }
                    }
                    var publishedRequest = request
                    publishedRequest.outputPath = output.path
                    let receipt = OutputReceipt(jobID: job.id, index: i, model: model, request: publishedRequest, original: generating ? recipe.reference?.url : (results[i]?.original ?? input),
                                                loras: recipe.loras, generatedBy: !generating ? recipe.generator : nil, exportFormat: recipe.format, jpegQuality: recipe.jpegQuality,
                                                runtime: worker.runtimeIdentity, memory: sample, processingSize: worker.processingSize)
                    let data = try JSONEncoder.pretty.encode(receipt)
                    let metadataSource = generating ? nil : (results[i]?.original ?? input)
                    try await Task.detached(priority: .utility) {
                        try ImageFiles.publish(raw: raw, output: output, format: recipe.format, quality: recipe.jpegQuality, source: metadataSource, receipt: data)
                    }.value
                }
                var item = existing ?? StudioResult(id: UUID(), original: generating ? output : input!, enhanced: nil, seed: seed, index: i)
                if !generating { item.enhanced = output }
                try? fm.removeItem(at: raw)
                results[i] = item
                update(job.id) { $0.results = results.values.sorted { $0.index < $1.index } }
                selectedResult = item
                persist()
            }
        }
    }

    /// Recover the interval between publishing an output and checkpointing the queue.
    private func recover(_ output: URL, job: StudioJob, index: Int, request: WorkerRequest) throws -> Bool {
        let fm = FileManager.default
        let receiptURL = output.appendingPathExtension("json")
        let hasFile = fm.fileExists(atPath: output.path)
        guard hasFile || fm.fileExists(atPath: receiptURL.path) else { return false }
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(OutputReceipt.self, from: data),
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
        try fm.removeItem(at: receiptURL)
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
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: stateURL, options: .atomic)
        } catch { notice = "Could not save the queue. " + error.localizedDescription }
    }

    private func persistPreferences() {
        defaults.set(activeGenerationID, forKey:"generationModel")
        defaults.set(activeEnhancementID, forKey:"enhancementModel")
        defaults.set(outputDirectory, forKey:"outputFolder")
        defaults.set(exportFormat.rawValue, forKey:"exportType")
        defaults.set(jpegQuality, forKey:"jpegQuality")
    }


}

private struct OutputReceipt: Codable {
    let jobID: UUID
    let index: Int
    let model: StudioModel
    var request: WorkerRequest
    let original: URL?
    let loras: [StudioModel]
    let generatedBy: StudioModel?
    var exportFormat: ExportFormat
    var jpegQuality: Double
    let runtime: String
    let memory: ModelMemorySample?
    let processingSize: ModelImageSize?
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return encoder
    }
}
