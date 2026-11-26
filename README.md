# Refract

A local image studio for Apple Silicon Macs running macOS 27 or later. Generate uses SDXL single-file checkpoints and weighted LoRAs. Enhance restores and upscales stills with SeedVR2. Both workspaces share a serial queue and an aligned before-and-after viewer.

## Build

Use Xcode's Swift toolchain and uv on an Apple Silicon Mac. From the repository root:

```sh
scripts/runtime.sh
swift test
scripts/package.sh
open build/Refract.app
```

The runtime preparation step downloads a private CPython 3.12 and the pinned Darwin arm64 wheels. The packaged app carries its own runtime and runs inference offline. Model downloads are explicit network operations. The package script ad-hoc signs the personal build and writes its source and artifact identity to `build/provenance.json`.

## Models and output

Open Models to add a local SDXL `.safetensors` checkpoint, compatible LoRAs or a supported prepared SeedVR2 package. Existing Hugging Face Juggernaut checkpoints are discovered by reference. A compatible local Diffusers configuration is used when present. The worker also includes offline SDXL configuration and tokenizer resources. Model files remain outside the app. The catalog records the source and license for each curated package.

Run a standalone enhancement by dropping images or a folder in Enhance. Use Fit and Actual Size to compare the aligned images. Choose an output folder, PNG, JPEG or TIFF in Settings. Generated originals and enhancements receive distinct names and individual JSON settings sidecars. The application records queue state and model selections under the user's Application Support/Refract directory. A failed job can retry its unfinished images.

The default SDXL sampler preset targets standard Juggernaut XI. Distilled checkpoints may need different steps and guidance. Use standard four-channel SDXL checkpoints with both text encoders and a VAE. Specialized conditioning architectures and video are outside this release. SeedVR2 reconstructs photographic detail and can change texture or lettering. Memory usage depends on the output geometry as well as model precision. For original-size restoration of images up to 256 pixels on the long edge, Refract runs one 2× restoration and downsamples to the original size to reduce changes to faces and lettering. The settings sidecar includes the internal processing size.

## Runtime and licenses

Exports use the model’s sRGB image output. The source file stays intact. The model manager shows the last attributable worker peak and output geometry measured on this Mac once a run completes.

The Swift app calls Diffusers/PyTorch MPS for SDXL and MLX-Gen/MLX for SeedVR2 over a private JSON-lines subprocess. The pinned wheels include their original package notices. See the SDXL configuration license and source information under `Worker/configs`. Juggernaut weights are user-provided. ByteDance publishes the original SeedVR2 3B and 7B weights under Apache-2.0. Model-specific terms apply separately from runtime code. In the pinned OpenCV wheel, FFmpeg reports GPLv3 or later. PyAV also includes codec libraries. A public release needs a redistribution review and the appropriate notices and source provisions.

- [Diffusers single-file loaders](https://huggingface.co/docs/diffusers/main/api/loaders/single_file)
- [MLX-Gen still-image restoration](https://github.com/lpalbou/mlx-gen/blob/main/docs/upscaling.md)
- [RunDiffusion Juggernaut XI](https://huggingface.co/RunDiffusion/Juggernaut-XI-v11)
- [ByteDance SeedVR2](https://github.com/ByteDance-Seed/SeedVR)

## CI and private releases

GitHub Actions builds and tests pull requests and pushes to `main` on the Apple Silicon Xcode 27 runner. Hardware acceptance tests use separately installed model weights and run locally.

After a passing build on `main`, GitHub Actions publishes a private release whenever `CFBundleShortVersionString` in `Resources/Info.plist` advances. It creates the version tag, packages and verifies the ad-hoc-signed app, and attaches the ZIP, SHA-256 checksum and build receipt. Model weights stay in the user’s model library.

A second workflow squash-merges clean, passing PRs from trusted same-repository contributors when all changed paths qualify for automatic merging. Changes to the UI, visual app resources, workflows or other unclassified files remain open for manual review. Version bumps in the bundle metadata are eligible for automatic merging. A successful automated merge dispatches the main build and release workflow.
