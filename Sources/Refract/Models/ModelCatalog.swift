import Foundation

enum ModelKind: String, Codable, CaseIterable, Sendable {
    case generation, enhancement, lora
}

struct StudioModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ModelKind
    let path: String
    let variant: String
    let configPath: String?
    let precision: String
    let license: String
    let bytes: Int64
    let managed: Bool
}

struct CatalogModel: Identifiable, Sendable {
    struct File: Sendable {
        let path: String
        let size: Int64
        /// LFS files use SHA-256. Small Git-tracked files use the Git blob SHA-1.
        let digest: String
        init(_ path: String, _ size: Int64, _ digest: String) {
            self.path = path; self.size = size; self.digest = digest
        }
    }
    let id: String
    let name: String
    let kind: ModelKind
    let variant: String
    let precision: String
    let license: String
    let detail: String
    let repository: String
    let revision: String?
    let files: [File]
    var checkpointFilename: String? = nil
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    var canDownload: Bool { revision != nil && !files.isEmpty }
    var checkpointFile: File? { files.first { $0.path == checkpointFilename } }
    var provenanceID: String { "hf:\(repository)@\(revision ?? "unqualified")" }
    var identity: String { checkpointFile?.digest ?? provenanceID }
    func downloadURL(_ file: File) -> URL {
        sourceURL.appendingPathComponent("resolve").appendingPathComponent(revision!).appendingPathComponent(file.path)
    }
}

struct ModelMemoryGuidance {
    let recommendedGB: Int
    let referenceSize: ModelImageSize
}

enum RefractCatalog {
    static func memoryGuidance(for variant: String) -> ModelMemoryGuidance? {
        let generation = ModelImageSize(width: 832, height: 1216)
        let enhancement = ModelImageSize(width: 1664, height: 2432)
        // Round up from the measured worker peaks to leave room for macOS and other apps.
        // The SDXL family estimate uses the Juggernaut XI benchmark.
        switch variant {
        case "sdxl": // 18.9 GiB.
            return .init(recommendedGB: 32, referenceSize: generation)
        case "flux1-krea-dev": // 24.1 GiB.
            return .init(recommendedGB: 32, referenceSize: generation)
        case "qwen-image-2512": // 30.0 GiB.
            return .init(recommendedGB: 48, referenceSize: generation)
        case "z-image-turbo": // 16.2 GiB.
            return .init(recommendedGB: 24, referenceSize: generation)
        case "seedvr2-3b", "seedvr2-7b", "seedvr2-7b-sharp": // 20.7, 22.7, and 22.4 GiB.
            return .init(recommendedGB: 32, referenceSize: enhancement)
        default:
            return nil
        }
    }

    static let entries: [CatalogModel] = [
        .init(id: "juggernaut-xi", name: "Juggernaut XI v11", kind: .generation, variant: "sdxl", precision: "Mixed FP16/FP32", license: "CC BY-NC-ND 4.0 · commercial license available", detail: "Import a local SDXL checkpoint. The model publisher manages access and licensing.", repository: "RunDiffusion/Juggernaut-XI-v11", revision: nil, files: [
            .init("Juggernaut-XI-byRunDiffusion.safetensors", 7105350536, "33e58e86686f6b386c526682b5da9228ead4f91d994abd4b053442dc5b42719e")
        ], checkpointFilename: "Juggernaut-XI-byRunDiffusion.safetensors"),
        .init(id: "sdxl-base-1-0", name: "Stable Diffusion XL Base 1.0", kind: .generation, variant: "sdxl", precision: "FP16", license: "CreativeML Open RAIL++-M", detail: "Stability AI’s original SDXL checkpoint for text-to-image and image-to-image generation.", repository: "stabilityai/stable-diffusion-xl-base-1.0", revision: "462165984030d82259a11f4367a4eed129e94a7b", files: [
            .init("sd_xl_base_1.0.safetensors", 6938078334, "31e35c80fc4829d14f90153f4c74cd59c90b779f6afe05a74cd6120b893f7e5b"),
            .init("LICENSE.md", 14109, "af7e355e31c0d976933aa0d06759611151ad8c39"),
            .init("README.md", 8668, "3de812966870aa7122954891ce74faabc77335a9")
        ], checkpointFilename: "sd_xl_base_1.0.safetensors"),
        .init(id: "flux1-krea-dev-q4", name: "FLUX.1 Krea Dev", kind: .generation, variant: "flux1-krea-dev", precision: "MLX Q4", license: "FLUX.1 [dev] Non-Commercial License", detail: "Krea and Black Forest Labs’ text-to-image model with an emphasis on photographic style.", repository: "filipstrand/FLUX.1-Krea-dev-mflux-4bit", revision: "439c33277a6ecfec20e441968526b4a67245603c", files: [
            .init("README.md", 1509, "c358c7053649beed2ba735993320925efe104c1f"),
            .init("text_encoder/0.safetensors", 69436583, "bbff69d07bd7bffccdff52655adf5e0c4781a814b253d2f4e0f93398a2858625"),
            .init("text_encoder_2/0.safetensors", 2145878331, "17cd0e3b0c0344b3db0a81a8494af5deda78a62d861ac571b5141d271dc79224"),
            .init("text_encoder_2/1.safetensors", 533312162, "f0b403b26b4815004425cf623618684bfc17a8f9e416e58928c350a4158ceef0"),
            .init("tokenizer/merges.txt", 524619, "76e821f1b6f0a9709293c3b6b51ed90980b3166b"),
            .init("tokenizer/special_tokens_map.json", 588, "cf0682d6de72c1547f41b4f6d7c59f62deffef94"),
            .init("tokenizer/tokenizer_config.json", 755, "a7aab9a5e5f754b27e602ceeecaf4b3313c87c81"),
            .init("tokenizer/vocab.json", 1059962, "469be27c5c010538f845f518c4f5e8574c78f7c8"),
            .init("tokenizer_2/added_tokens.json", 2593, "3f5132007c4fcf42b75b65c8b6aa49c7098bcdf4"),
            .init("tokenizer_2/special_tokens_map.json", 2543, "17ade346a1042cbe0c1436f5bedcbd85c099d582"),
            .init("tokenizer_2/spiece.model", 791656, "d60acb128cf7b7f2536e8f38a5b18a05535c9e14c7a355904270e15b0945ea86"),
            .init("tokenizer_2/tokenizer_config.json", 20868, "fda2cf84fbfde51a9aa2c4af6996ff1db81d7cff"),
            .init("transformer/0.safetensors", 2129626742, "52c7d2dd7de53cc2f45b08edfe0c1744f23c375e365001eb88c610e4d6cca09e"),
            .init("transformer/1.safetensors", 2141393619, "e526ae27525564f657b5581951e42405cd2c3adcc1a18f078ccd1ed26f6e5498"),
            .init("transformer/2.safetensors", 2130572515, "1beb5d725688e6081d8d4d5bd53f9d992944a94cf854d27a6115adb803680599"),
            .init("transformer/3.safetensors", 297640240, "cd98c64268be2795f6f4300d822f0eafaa216bb2c5f2e3b953446339158be1d5"),
            .init("vae/0.safetensors", 164654153, "299fede20c105142b3ee99467983d2aa3249222e37237398f7873c10ebc237d9")
        ]),
        .init(id: "qwen-image-2512-q4", name: "Qwen Image 2512", kind: .generation, variant: "qwen-image-2512", precision: "MLX Q4", license: "Apache-2.0", detail: "Qwen’s text-to-image model for detailed scenes and typography.", repository: "AbstractFramework/qwen-image-2512-4bit", revision: "423f1f5bf708c6e11eb78881ef9738422cea0814", files: [
            .init("LICENSE.md", 11358, "d645695673349e3947e8e5ae42332d0ac3164cd7"),
            .init("README.md", 2218, "a58fbb535f175749d3670b4b0ad19f424cee7bcf"),
            .init("text_encoder/0.safetensors", 2142182659, "b17f5c5e9a67d4e1e99661429afe277cacc6dfa1b29d505bf38d8b5f1e4ad0da"),
            .init("text_encoder/1.safetensors", 1835614566, "c379ed1c78714f3aacbd5a6e3ad708f0cc33c4a4f6689ef3010e294dbfd93d54"),
            .init("text_encoder/model.safetensors.index.json", 49256, "d876abafe0142384f7283ae648453245bdb4d113"),
            .init("tokenizer/tokenizer.json", 11417006, "444a80c37c7f34f485c050cf374595a0cb7d88735459cf0505fd204453c33178"),
            .init("tokenizer/tokenizer_config.json", 269, "3299687e615af5b239e5000b69cb0cb62ee2008f"),
            .init("transformer/0.safetensors", 2133769869, "bfbf470e8f82255b91c09cedb70c691b262f1ab54c233818b6b91185bbce71b1"),
            .init("transformer/1.safetensors", 2142940100, "0dccd27b42a47929d1c3d22bce3666dcfda98ef8c95a1e866f5a249d701ee1f5"),
            .init("transformer/2.safetensors", 2103978106, "74db3805640dc9d9c625ee6f5cd944f2850159b0a105bdd85ee2d850c8727108"),
            .init("transformer/3.safetensors", 2121682265, "9ba68067e9412f2a0cce2174f06fd907aaf2723b4762a1db615571ac44f81a0b"),
            .init("transformer/4.safetensors", 2142940118, "937f9a01dba1e116511b83c8ca8c3d27b239d5c2a25a8ebac71dff19c9c0d7f5"),
            .init("transformer/5.safetensors", 2103978210, "017c1a3b4afc6bc12f287e33d368df67e949528c6f48847bbf2a5d5e151613af"),
            .init("transformer/6.safetensors", 449941880, "a463c3ad6caec4f7ed524af88da2b92d5247ff410dbe55a208838dafdb6c6ec0"),
            .init("transformer/model.safetensors.index.json", 241693, "30943ca4517231bf5b17be2dce3f7c6cb7f70731"),
            .init("vae/0.safetensors", 253586147, "2c2db147e652a0e011c1c5f40345ab84e9a95819ee9c7b29eb29f245cccd8f64"),
            .init("vae/model.safetensors.index.json", 13512, "b0196601c3c7ed7381ccb7fa2a085b402241130a")
        ]),
        .init(id: "z-image-turbo-q4", name: "Z-Image Turbo", kind: .generation, variant: "z-image-turbo", precision: "MLX Q4", license: "Apache-2.0", detail: "Tongyi’s distilled text-to-image model for short generation runs.", repository: "AbstractFramework/z-image-turbo-4bit", revision: "0548f8787a105e240924f05ecf304b2d0436a5cf", files: [
            .init("LICENSE.md", 11358, "d645695673349e3947e8e5ae42332d0ac3164cd7"),
            .init("README.md", 1786, "dcd43a0c6ff8f337dd420a2d5768fbf0c7725640"),
            .init("text_encoder/0.safetensors", 2135435091, "33215c600fd1742b64006093523d4feb8dc596a4cd455074f47b7f43aa813f9c"),
            .init("text_encoder/1.safetensors", 127582107, "49ea0b86e08bfa0250c1d2b5b8565e897dda6763416a8393946819b6dbc7b0ea"),
            .init("text_encoder/model.safetensors.index.json", 51332, "cd39f6f35a77ef9c746d7f5eccf5cf08f2706b7d"),
            .init("tokenizer/chat_template.jinja", 4168, "01be9b307daa2d425f7c168c9fb145a286e0afb4"),
            .init("tokenizer/tokenizer.json", 11422650, "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
            .init("tokenizer/tokenizer_config.json", 664, "9fd0fb48e73786f54fb04e98892f5f5a0ebeebdb"),
            .init("transformer/0.safetensors", 2140225936, "8fb51d340cc31f6d53dcf5d5b8e5e993ad9a931e02799ca6612da4997afffcf3"),
            .init("transformer/1.safetensors", 1323528959, "331a56e0a7ee5facac842a6e1b8ff98a86dfb472403d58db718c065b2a19ff0a"),
            .init("transformer/model.safetensors.index.json", 61606, "1d4fb1035cdfff0f744824be23184d3daff887c1"),
            .init("vae/0.safetensors", 164654111, "4adc5a44795e6573a04373b5f4dd81baba0916886db9902e097af8919d03b179"),
            .init("vae/model.safetensors.index.json", 17378, "293dafb9dfea5cb1ef8394bd2175b6cd536cea20")
        ]),
        .init(id: "seedvr2-3b-q8", name: "SeedVR2 3B", kind: .enhancement, variant: "seedvr2-3b", precision: "MLX Q8 / BF16", license: "Apache-2.0", detail: "General-purpose photographic restoration and upscaling. Start here for smaller memory use.", repository: "AbstractFramework/seedvr2-3b-8bit", revision: "6e6b162d1e96c873ad93645508bbc4636814c0c7", files: [
            .init("transformer/0.safetensors", 2142146507, "a68bb0bf17470d417678b16dd51ec8a6410b7c533886aefeda47aedfe0235145"),
            .init("transformer/1.safetensors", 2075381973, "85eae079a8138a63062cb05e03c5d45831aeeabb6332f23a1cc07691cc24f75f"),
            .init("transformer/model.safetensors.index.json", 73103, "3946dc5ea76176289a110b38637025b8fe007288"),
            .init("vae/0.safetensors", 499360590, "74b7f7b71d22220f7e09a6602420d82a8fa72cbdbe4a170226ddb270cc65af42"),
            .init("vae/model.safetensors.index.json", 17767, "a5f8e9fada4e4e3feb067e213e406ab1a2c5f458")
        ]),
        .init(id: "seedvr2-7b-q8", name: "SeedVR2 7B", kind: .enhancement, variant: "seedvr2-7b", precision: "MLX Q8 / BF16", license: "Apache-2.0", detail: "Larger general-purpose restoration model. Memory also depends on output dimensions.", repository: "AbstractFramework/seedvr2-7b-8bit", revision: "255ef593009a46428cff505aac3371aeebd6705f", files: [
            .init("transformer/0.safetensors", 2135388223, "b04426cb99ff80cdcb34866db5cdcca5a6484d6e0f556b351a44e822cfb57f21"),
            .init("transformer/1.safetensors", 2127082245, "32b0efcc5467f57d69e3d3187c771ab8f207cbf5c242e132518c3b3f54e6c8d3"),
            .init("transformer/2.safetensors", 2127099749, "6f6cf03603c052572143466ee48be545918c82beaa6e8c9db81b25fbbb8e2f52"),
            .init("transformer/3.safetensors", 2127099701, "57183580106d6eb4ef9c3a680abb07bb1fcc29d26ed5059177009d204f2a7f65"),
            .init("transformer/4.safetensors", 241011065, "39b3d6221dcb5e76fe799926953bc8f7970b47a0b20a8766b18c81b000a5ce93"),
            .init("transformer/model.safetensors.index.json", 98591, "8b80b46fd2e9fc36ec713fb0c2335c676cb8d385"),
            .init("vae/0.safetensors", 499360590, "b489aede6ae5d3c72c07343f1e04ce358b61fa6975a6aa502de70fe4ba8bd006"),
            .init("vae/model.safetensors.index.json", 17767, "5432d83edddf826a7e90c989b3f720bafdb94c8b")
        ]),
        .init(id: "seedvr2-7b-sharp-int8", name: "SeedVR2 7B Sharp", kind: .enhancement, variant: "seedvr2-7b-sharp", precision: "MLX INT8 / FP16", license: "Apache-2.0", detail: "Sharpening-tuned 7B weights for stronger texture and edge detail.", repository: "benc0/SeedVR2-7B-sharp-mlx-int8", revision: "915bd948e5fe9b8e6fc0024c1eef86ebf0ec5ad0", files: [
            .init("config.json", 646, "9458f5818a91371e1bfbc9aa086991d4fcc174af"),
            .init("pos_emb.safetensors", 594008, "d2e06cadb10f1f149b5aa781185b250eb60f0e64327f12efd17886cecc9c2984"),
            .init("transformer.safetensors", 8757682180, "6efd63abb1a3f7d69ee095f2fa6653a6141ffdcb3d423204b7583afa56666e4e"),
            .init("vae.safetensors", 501324772, "a2efbfb38a82a99a9cd16432ca5d564510678d228ce6209692d528aa32285cfb")
        ])
    ]
}

enum ModelCatalogRow: Identifiable {
    enum ID: Hashable {
        case curated(String)
        case local(String)
    }

    case curated(CatalogModel, StudioModel?)
    case local(StudioModel)

    var id: ID {
        switch self {
        case .curated(let entry, _): .curated(entry.id)
        case .local(let model): .local(model.id)
        }
    }

    var entry: CatalogModel? {
        if case .curated(let entry, _) = self { return entry }
        return nil
    }

    var model: StudioModel? {
        switch self {
        case .curated(_, let model): model
        case .local(let model): model
        }
    }

    var name: String {
        switch self {
        case .curated(let entry, _): entry.name
        case .local(let model): model.name
        }
    }

    var kind: ModelKind {
        switch self {
        case .curated(let entry, _): entry.kind
        case .local(let model): model.kind
        }
    }

    static func make(catalog: [CatalogModel], localModels: [StudioModel]) -> [Self] {
        var remaining = localModels
        let curated: [Self] = catalog.map { entry in
            let match = remaining.firstIndex { $0.id == entry.identity && $0.kind == entry.kind }
                ?? entry.checkpointFile.flatMap { checkpoint in
                    remaining.firstIndex { model in
                        model.kind == entry.kind && model.variant == entry.variant
                            && model.id.hasPrefix(checkpoint.digest + "+")
                    }
                }
            return .curated(entry, match.map { remaining.remove(at: $0) })
        }
        return (curated + remaining.map(Self.local)).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct ModelDownload: Sendable {
    var fraction: Double
    var message: String
    var isRunning: Bool
    var isCancelling = false
}

struct ModelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
