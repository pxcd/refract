import Foundation

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case png, jpeg, tiff
    var id: Self { self }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

struct LoRAChoice: Codable, Hashable, Identifiable {
    var modelID: String
    var scale: Double = 1
    var id: String { modelID }
}

struct GenerationOptions: Codable, Hashable {
    var prompt = ""
    var negativePrompt = ""
    var width = 832
    var height = 1216
    var steps = 35
    var guidance = 5.0
    var seed: Int?
    var count = 1
    var sampler = "DPM++ 2M"
    var scheduler = "Karras"
    var predictionType: String?
    var zeroTerminalSNR: Bool?
    var strength = 0.65
    var reference: URL?
    var preserveReferenceSize: Bool?
    var loras: [LoRAChoice] = []
    var autoEnhance = false
}

struct SamplingPreset: Codable, Equatable {
    let steps: Int
    let guidance: Double
    let sampler: String
    let scheduler: String
    let predictionType: String?
    let zeroTerminalSNR: Bool?

    init(_ options: GenerationOptions) {
        steps = options.steps
        guidance = options.guidance
        sampler = options.sampler
        scheduler = options.scheduler
        predictionType = options.predictionType
        zeroTerminalSNR = options.zeroTerminalSNR
    }

    func apply(to options: inout GenerationOptions) {
        options.steps = steps
        options.guidance = guidance
        options.sampler = sampler
        options.scheduler = scheduler
        options.predictionType = predictionType
        options.zeroTerminalSNR = zeroTerminalSNR
    }
}

struct EnhancementOptions: Codable, Hashable {
    var scale = 2.0
    var customLongEdge: Int?
    var softness = 0.0
}

enum JobStatus: String, Codable, CaseIterable {
    case pending, running, completed, failed, cancelled
}

struct StudioResult: Codable, Hashable, Identifiable {
    let id: UUID
    let original: URL
    var enhanced: URL?
    let seed: Int
    var index: Int = 0
}

struct InputImage: Codable {
    let url: URL
    let size: Int?
    let modified: Date?

    init(_ url: URL) throws {
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard resource.isRegularFile == true else { throw StudioError("Select an image file.") }
        self.url = url
        size = resource.fileSize
        modified = resource.contentModificationDate
    }

    func validate() throws {
        let current = try InputImage(url)
        if current.size != size || current.modified != modified {
            throw StudioError("The source changed after queueing: " + url.lastPathComponent)
        }
    }
}

struct JobRecipe: Codable {
    let generator: StudioModel?
    let enhancer: StudioModel?
    let loras: [StudioModel]
    let generation: GenerationOptions
    let enhancement: EnhancementOptions
    let reference: InputImage?
    let inputs: [InputImage]
    let seeds: [Int]
    let directory: URL
    let format: ExportFormat
    let jpegQuality: Double
}

struct StudioJob: Codable, Identifiable {
    let id: UUID
    let title: String
    let recipe: JobRecipe
    var status = JobStatus.pending
    var message = "Queued"
    var progress: Double? = 0
    var elapsed: TimeInterval = 0
    var results: [StudioResult] = []
    var trashedResultIndices: Set<Int>?
    var hiddenFilmstripResults: Set<UUID>?

    var filmstripResults: [StudioResult] {
        results.filter { hiddenFilmstripResults?.contains($0.id) != true }
    }
}

struct StudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct InferenceRequest: Codable {
    var id = UUID().uuidString
    var operation: String
    var modelID: String?
    var modelPath: String
    var modelVariant: String
    var configPath: String?
    var inputPath: String?
    var outputPath: String
    var prompt: String
    var negativePrompt: String
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var seed: Int
    var strength: Double
    var sampler: String
    var scheduler: String
    var predictionType: String?
    var zeroTerminalSNR: Bool?
    var loras: [AdapterWeight]
    var softness: Double
    var preserveReferenceSize: Bool? = nil
}

struct AdapterWeight: Codable {
    var id: String?
    let path: String
    let scale: Double
}

@MainActor protocol InferenceClient: AnyObject {
    var runtimeIdentity: String { get }
    var measuredPeakBytes: UInt64? { get }
    var processingSize: ModelImageSize? { get }
    func render(_ request: InferenceRequest, progress: @escaping (Double?, String) -> Void) async throws
    func stop()
}

extension InferenceClient {
    var runtimeIdentity: String { "development" }
    var measuredPeakBytes: UInt64? { nil }
    var processingSize: ModelImageSize? { nil }
}

struct ModelMemorySample: Codable {
    let width: Int
    let height: Int
    let peak: UInt64

    var description: String {
        let gib = String(format: "%.1f", Double(peak) / 1_073_741_824)
        return "On this Mac: " + gib + " GiB peak worker footprint at " + String(width) + " × " + String(height) + "."
    }
}

struct ModelImageSize: Codable {
    let width: Int
    let height: Int
}
