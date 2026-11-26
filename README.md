# Refract

A local image studio for Apple Silicon Macs running macOS 27 or later. Generate supports SDXL single-file checkpoints and weighted LoRAs, plus FLUX.1 Krea Dev, Qwen Image 2512, and Z-Image Turbo on MLX. Enhance restores and upscales stills with SeedVR2. Both workspaces share a serial queue and an aligned before-and-after viewer.

## Source and personal use

You may clone, build, and run Refract for personal use under the [Refract Personal Use License](LICENSE). Third-party files, runtimes, and models have their own terms. App downloads and pull requests are restricted to maintainers and collaborators.

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

Open Models to add a local SDXL `.safetensors` checkpoint, compatible LoRAs or a supported prepared MLX package. Download curated packages from the Models catalog, or import a folder matching the pinned files by reference. The MLX generation models support text-to-image, and Qwen Image also accepts a negative prompt. Reference images and LoRAs are available with SDXL. Existing Hugging Face Juggernaut checkpoints are discovered by reference. A compatible local Diffusers configuration is used when present. The worker also includes offline SDXL configuration and tokenizer resources. Model files remain outside the app. The catalog records the source and license for each curated package.

Run a standalone enhancement by dropping images or a folder in Enhance. Use Fit and Actual Size to compare the aligned images. Choose an output folder, PNG, JPEG or TIFF in Settings. Generated originals and enhancements receive distinct names and individual JSON settings sidecars. The application records queue state and model selections under the user's Application Support/Refract directory. A failed job can retry its unfinished images.

The default SDXL sampler preset targets standard Juggernaut XI. Distilled checkpoints may need different steps and guidance. Use standard four-channel SDXL checkpoints with both text encoders and a VAE. Specialized conditioning architectures and video are outside this release. SeedVR2 reconstructs photographic detail and can change texture or lettering. Memory usage depends on the output geometry as well as model precision. For original-size restoration of images up to 256 pixels on the long edge, Refract runs one 2× restoration and downsamples to the original size to reduce changes to faces and lettering. The settings sidecar includes the internal processing size.

## Runtime and licenses

Exports use the model’s sRGB image output. The source file stays intact. The Models catalog compares this Mac’s unified memory with model recommendations based on measured runs at representative output sizes.

The Swift app calls Diffusers/PyTorch MPS for SDXL and MLX-Gen/MLX for the other generation models and SeedVR2 over a private JSON-lines subprocess. The pinned wheels include their original package notices. See the SDXL configuration license and source information under `Worker/configs`. Juggernaut weights are user-provided. ByteDance publishes the original SeedVR2 3B and 7B weights under Apache-2.0. Model-specific terms apply separately from runtime code. In the pinned OpenCV wheel, FFmpeg reports GPLv3 or later. PyAV also includes codec libraries. A public release needs a redistribution review and the appropriate notices and source provisions.

- [Diffusers single-file loaders](https://huggingface.co/docs/diffusers/main/api/loaders/single_file)
- [MLX-Gen still-image restoration](https://github.com/lpalbou/mlx-gen/blob/main/docs/upscaling.md)
- [RunDiffusion Juggernaut XI](https://huggingface.co/RunDiffusion/Juggernaut-XI-v11)
- [ByteDance SeedVR2](https://github.com/ByteDance-Seed/SeedVR)

## Adding model support

The Swift queue calls `InferenceClient` with an `InferenceRequest`. The app currently injects `WorkerClient`, which sends the request to the bundled Python process. A future native client can implement the same protocol and be selected at the app boundary.

Python routes requests by operation and model variant through `Worker/refract_models/__init__.py`. Register built-in code there. An adapter declares its variants, validates its local model in `prepare`, and returns the configuration identity and a lazy model loader. Its loaded model implements `run(request, progress)` and returns a Pillow image and optional result metadata.

For a curated download, add a matching variant and a pinned file manifest in `ModelCatalog.swift`. Set `checkpointFilename` for a single-file checkpoint. A folder package uses its revision and complete file manifest as its identity. Check supported controls, offline inference, cancellation and any generation-to-enhancement handoff before enabling a new family.

## CI and private releases

GitHub Actions builds and tests pull requests and pushes to `main` on the Apple Silicon Xcode 27 runner. Hardware acceptance tests use separately installed model weights and run locally.

After a passing build on `main`, GitHub Actions saves a restricted draft release whenever `CFBundleShortVersionString` in `Resources/Info.plist` advances. It packages and verifies the ad-hoc-signed app and attaches the ZIP, SHA-256 checksum, and a build receipt with no local paths. Model weights stay in the user’s model library.

A second workflow squash-merges clean, passing PRs from trusted same-repository contributors when all changed paths qualify for automatic merging. Changes to the UI, visual app resources, workflows or other unclassified files remain open for manual review. Version bumps in the bundle metadata are eligible for automatic merging. A successful automated merge dispatches the main build and release workflow.
