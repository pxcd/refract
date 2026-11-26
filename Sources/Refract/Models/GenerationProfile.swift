enum GenerationProfile: String {
    case sdxl
    case krea = "flux1-krea-dev"
    case qwen = "qwen-image-2512"
    case zImageTurbo = "z-image-turbo"

    var usesSDXLControls: Bool { self == .sdxl }
    var supportsNegativePrompt: Bool { self == .sdxl || self == .qwen }
    var supportsGuidance: Bool { self != .zImageTurbo }
    var dimensionMultiple: Int { self == .sdxl ? 8 : 16 }

    var defaultSampling: SamplingPreset {
        var options = GenerationOptions()
        switch self {
        case .sdxl: break
        case .krea:
            options.steps = 25
            options.guidance = 4.5
        case .qwen:
            options.steps = 40
            options.guidance = 4
        case .zImageTurbo:
            options.steps = 9
            options.guidance = 0
        }
        configure(&options)
        return SamplingPreset(options)
    }

    func configure(_ options: inout GenerationOptions) {
        guard !usesSDXLControls else { return }
        options.reference = nil
        options.preserveReferenceSize = nil
        options.loras = []
        options.sampler = "Native"
        options.scheduler = "Default"
        options.predictionType = nil
        options.zeroTerminalSNR = nil
        if !supportsGuidance { options.guidance = 0 }
        if !supportsNegativePrompt { options.negativePrompt = "" }
    }
}
