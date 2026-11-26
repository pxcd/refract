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
    var memoryEstimate: String { RefractCatalog.memoryNote(for: variant) }
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
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    var memoryEstimate: String { RefractCatalog.memoryNote(for: variant) }
    var canDownload: Bool { revision != nil && !files.isEmpty }
    var checkpointFile: File? { kind == .generation ? files.first { $0.path.hasSuffix(".safetensors") } : nil }
    var provenanceID: String { "hf:\(repository)@\(revision ?? "unqualified")" }
    var identity: String { checkpointFile?.digest ?? provenanceID }
    func downloadURL(_ file: File) -> URL {
        sourceURL.appendingPathComponent("resolve").appendingPathComponent(revision!).appendingPathComponent(file.path)
    }
}

enum RefractCatalog {
    static func memoryNote(for variant: String) -> String {
        switch variant {
        case "sdxl": return "Juggernaut XI measured 18.9 GiB peak worker footprint at 832 × 1216 on an M5 Pro with 48 GB. Other checkpoints and sizes vary."
        case "seedvr2-3b": return "Measured 20.7 GiB peak worker footprint at 1664 × 2432 (Q8, M5 Pro with 48 GB)."
        case "seedvr2-7b": return "Measured 22.7 GiB peak worker footprint at 1664 × 2432 (Q8, M5 Pro with 48 GB)."
        case "seedvr2-7b-sharp": return "Measured 22.4 GiB peak worker footprint at 1664 × 2432 (INT8, M5 Pro with 48 GB)."
        case "sdxl-lora": return "Adapter memory depends on the active checkpoint and selected layers."
        default: return "Memory estimate pending for this model and output size."
        }
    }
    static let entries: [CatalogModel] = [
        .init(id: "juggernaut-xi", name: "Juggernaut XI v11", kind: .generation, variant: "sdxl", precision: "Mixed FP16/FP32", license: "CC BY-NC-ND 4.0 · commercial license available", detail: "Import a local SDXL checkpoint. The model publisher manages access and licensing.", repository: "RunDiffusion/Juggernaut-XI-v11", revision: nil, files: []),
        .init(id: "sdxl-base-1-0", name: "Stable Diffusion XL Base 1.0", kind: .generation, variant: "sdxl", precision: "FP16", license: "CreativeML Open RAIL++-M", detail: "Stability AI’s original SDXL checkpoint for text-to-image and image-to-image generation.", repository: "stabilityai/stable-diffusion-xl-base-1.0", revision: "462165984030d82259a11f4367a4eed129e94a7b", files: [
            .init("sd_xl_base_1.0.safetensors", 6938078334, "31e35c80fc4829d14f90153f4c74cd59c90b779f6afe05a74cd6120b893f7e5b"),
            .init("LICENSE.md", 14109, "af7e355e31c0d976933aa0d06759611151ad8c39"),
            .init("README.md", 8668, "3de812966870aa7122954891ce74faabc77335a9")
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

struct ModelDownload: Sendable {
    var fraction: Double
    var message: String
    var isRunning: Bool
}

struct ModelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
