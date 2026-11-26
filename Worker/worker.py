"""One JSON request per line. stdout is reserved for replies, including during imports."""

import gc
import io
import json
import os
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

os.environ.update(
    HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", HF_HUB_DISABLE_PROGRESS_BARS="1",
    TOKENIZERS_PARALLELISM="false", PYTORCH_ENABLE_MPS_FALLBACK="0",
)


def input_image(path):
    from PIL import Image, ImageCms, ImageOps, UnidentifiedImageError

    def normalize(source):
        oriented = ImageOps.exif_transpose(source)
        if profile := source.info.get("icc_profile"):
            color = oriented if oriented.mode in ("RGB", "CMYK", "L", "LAB") else oriented.convert("RGB")
            return ImageCms.profileToProfile(
                color, ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile("sRGB"),
                outputMode="RGB",
            )
        return oriented.convert("RGB")

    try:
        with Image.open(path) as source:
            return normalize(source)
    except UnidentifiedImageError:
        # ImageIO also accepts Mac-native inputs such as HEIC. Decode them without bundling another codec.
        with tempfile.TemporaryDirectory() as directory:
            decoded = Path(directory) / "decoded.tiff"
            subprocess.run(["/usr/bin/sips", "-s", "format", "tiff", str(path), "--out", str(decoded)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            with Image.open(decoded) as source:
                return normalize(source)


def scheduler_for(config, sampler, schedule, prediction=None, zero_snr=None):
    from diffusers import DDIMScheduler, DPMSolverMultistepScheduler, EulerAncestralDiscreteScheduler, EulerDiscreteScheduler

    classes = {
        "DPM++ 2M": DPMSolverMultistepScheduler, "Euler": EulerDiscreteScheduler,
        "Euler a": EulerAncestralDiscreteScheduler, "DDIM": DDIMScheduler,
    }
    if sampler not in classes or schedule not in ("Default", "Karras"):
        raise ValueError(f"Unsupported sampler or schedule: {sampler} / {schedule}")
    options = {}
    if prediction is not None:
        if prediction not in ("epsilon", "v_prediction"):
            raise ValueError(f"Unsupported SDXL prediction type: {prediction}")
        options["prediction_type"] = prediction
    if zero_snr is not None:
        if not isinstance(zero_snr, bool):
            raise ValueError("Zero-terminal SNR must be a boolean")
        options["rescale_betas_zero_snr"] = zero_snr
    if sampler in ("DPM++ 2M", "Euler"):
        options["use_karras_sigmas"] = schedule == "Karras"
    elif schedule == "Karras":
        raise ValueError(f"Karras scheduling is unavailable for {sampler}")
    if sampler == "DPM++ 2M":
        options.update(algorithm_type="dpmsolver++", solver_order=2)
    return classes[sampler].from_config(config, **options)


class SDXL:
    def __init__(self, checkpoint, config):
        import torch
        from diffusers import StableDiffusionXLPipeline

        if not torch.backends.mps.is_available():
            raise RuntimeError("Apple Metal (MPS) is unavailable to the inference worker")
        self.text = StableDiffusionXLPipeline.from_single_file(
            str(checkpoint), config=str(config), dtype=torch.float16,
            local_files_only=True, add_watermarker=False,
        ).to("mps")
        self.text.set_progress_bar_config(disable=True)
        self.scheduler_config = self.text.scheduler.config
        self.adapter_identity = ()
        self.image = None

    def configure_loras(self, adapters):
        paths = tuple(str(Path(item["path"]).absolute()) for item in adapters)
        names = [f"adapter_{i}" for i in range(len(paths))]
        identity = tuple((path, item.get("id")) for path, item in zip(paths, adapters))
        if identity != self.adapter_identity:
            if self.adapter_identity:
                self.text.unload_lora_weights()
            for filename, name in zip(paths, names):
                path = Path(filename)
                if not path.is_file() or path.suffix.lower() != ".safetensors":
                    raise ValueError("SDXL LoRA imports must use safetensors")
                self.text.load_lora_weights(str(path.parent), weight_name=path.name, adapter_name=name,
                                            local_files_only=True, use_safetensors=True)
            self.adapter_identity = identity
        if names:
            self.text.set_adapters(names, adapter_weights=[float(item["scale"]) for item in adapters])

    def run(self, request, progress):
        import torch
        from diffusers import StableDiffusionXLImg2ImgPipeline
        from PIL import Image, ImageOps

        self.configure_loras(request.get("loras", []))
        size = request["width"], request["height"]
        if any(value <= 0 or value % 8 for value in size):
            raise ValueError("SDXL dimensions must be positive multiples of eight")
        steps = int(request["steps"])
        if steps < 1:
            raise ValueError("SDXL requires at least one denoising step")
        if source := request.get("inputPath"):
            strength = float(request["strength"])
            if not 0 < strength <= 1 or int(steps * strength) < 1:
                raise ValueError("The reference strength and step count must allow at least one denoising step")
            if self.image is None:
                self.image = StableDiffusionXLImg2ImgPipeline.from_pipe(self.text, add_watermarker=False)
                self.image.set_progress_bar_config(disable=True)
            pipeline = self.image
            # Keep reference framing proportional when the requested canvas has a different aspect ratio.
            reference = ImageOps.fit(input_image(source), size, method=Image.Resampling.LANCZOS)
            arguments = dict(image=reference, strength=strength, original_size=size[::-1], target_size=size[::-1])
        else:
            pipeline = self.text
            arguments = dict(width=size[0], height=size[1])
        pipeline.scheduler = scheduler_for(self.scheduler_config, request["sampler"], request["scheduler"],
                                           request.get("predictionType"), request.get("zeroTerminalSNR"))

        def step_finished(pipe, index, timestep, state):
            count = pipe.num_timesteps
            completed = index + 1
            # MPS queues work asynchronously. Fence groups of steps before reporting them to the UI.
            if completed == 1 or completed % 4 == 0 or completed == count:
                torch.mps.synchronize()
                progress(f"Denoising {completed}/{count}", completed / count)
                if completed == count:
                    progress("Decoding image")
            return state

        with torch.inference_mode():
            result = pipeline(prompt=request["prompt"], negative_prompt=request.get("negativePrompt", ""),
                              num_inference_steps=steps, guidance_scale=float(request["guidance"]),
                              generator=torch.Generator(device="cpu").manual_seed(int(request["seed"])),
                              callback_on_step_end=step_finished, **arguments)
        return result.images[0], {}


def load_sharp_int8(package, config):
    """benc0's flat files are already in MLX layout. Load their quantized tensors directly."""
    import mlx.core as mx
    from mlx import nn
    from mflux.models.seedvr2.seedvr2_initializer import SeedVR2Initializer
    from mflux.models.seedvr2.variants.upscale.seedvr2 import SeedVR2
    from mflux.models.seedvr2.weights.seedvr2_weight_definition import SeedVR2WeightDefinition
    from mflux.utils.runtime_memory import RuntimeMemory

    spec = json.loads((package / "config.json").read_text())
    overrides = spec.get("transformer_overrides", {})
    expected = config.transformer_overrides
    # The older exporter predates MLX-Gen's explicit global-text attention switch for 7B.
    if (spec.get("variant") != "seedvr2-7b-sharp" or spec.get("model_type") != "seedvr2"
            or spec.get("quantization") != {"bits": 8, "group_size": 64}
            or overrides != {k: v for k, v in expected.items() if k != "text_attention_mode"}):
        raise ValueError("Expected benc0's SeedVR2 7B Sharp INT8 package (8 bits, group size 64)")

    class FlatSharp(SeedVR2):
        def __init__(self):
            nn.Module.__init__(self)
            SeedVR2Initializer._init_config(self, config)
            SeedVR2Initializer._init_models(self, config)
            nn.quantize(self.transformer, group_size=64, bits=8,
                        class_predicate=SeedVR2WeightDefinition.quantization_predicate)
            self.transformer.load_weights(str(package / "transformer.safetensors"), strict=True)
            self.vae.load_weights(str(package / "vae.safetensors"), strict=True)
            self.text_embedding = mx.load(str(package / "pos_emb.safetensors"))["embedding"]
            if self.text_embedding.shape != (58, 5120):
                raise ValueError("Unexpected SeedVR2 Sharp text embedding shape")
            self.bits = 8
            self.seedvr2_checkpoint_variant = "7b-sharp"
            self.seedvr2_source_layout = "mlx-flat-int8"

    # Flat weights bypass MLX-Gen's WeightLoader, which normally sets this budget.
    RuntimeMemory.apply_default_cache_limit_once()
    return FlatSharp()


class SeedVR:
    def __init__(self, package, variant):
        import mlx.core as mx
        from mflux.models.common.config.model_config import ModelConfig
        from mflux.models.seedvr2.variants.upscale.seedvr2 import SeedVR2

        configs = {"seedvr2-3b": ModelConfig.seedvr2_3b, "seedvr2-7b": ModelConfig.seedvr2_7b,
                   "seedvr2-7b-sharp": ModelConfig.seedvr2_7b_sharp}
        if variant not in configs:
            raise ValueError(f"Unsupported SeedVR2 variant: {variant}")
        if not mx.metal.is_available():
            raise RuntimeError("Apple Metal is unavailable to the MLX inference worker")
        config = configs[variant]()
        if variant == "seedvr2-7b-sharp" and (package / "transformer.safetensors").is_file():
            self.model = load_sharp_int8(package, config)
        else:
            self.model = SeedVR2(model_path=str(package), model_config=config)

    def run(self, request, progress):
        from PIL import Image
        from mflux.models.common.vae.tiling_config import TilingConfig
        from mflux.utils.scale_factor import ScaleFactor

        target = request["width"], request["height"]
        if min(target) < 2:
            raise ValueError("SeedVR2 requires at least two pixels on each side")
        source = input_image(request["inputPath"])
        # Swift rounds to the nearest pixel. Accept at most that rounding difference.
        if abs(target[0] * source.height - target[1] * source.width) > max(source.size):
            raise ValueError("SeedVR2 output must preserve the input aspect ratio")
        softness = float(request.get("softness", 0))
        if not 0 <= softness <= 1:
            raise ValueError("SeedVR2 softness must be between 0 and 1")
        processing_size = target
        if target == source.size and max(target) <= 256:
            # A 2× pass preserves small faces and lettering better when returned to native size.
            processing_size = source.width * 2, source.height * 2
        scale = ScaleFactor(max(processing_size) / max(source.size))
        self.model.tiling_config = TilingConfig(vae_encode_tiled=max(processing_size) > 1024,
                                                vae_encode_tile_size=768, vae_encode_tile_overlap=128)

        class RestoreProgress:
            def call_in_loop(self, *, latents, **_):
                import mlx.core as mx
                # MLX-Gen calls this hook before its own lazy evaluation boundary.
                mx.eval(latents)
                progress("Decoding restored image")

        reporter = RestoreProgress()
        self.model.callbacks.register(reporter)
        try:
            with tempfile.TemporaryDirectory(dir=Path(request["outputPath"]).parent) as temp:
                normalized = Path(temp) / "source.png"
                source.save(normalized, format="PNG", icc_profile=None, exif=b"")
                generated = self.model.generate_image(seed=int(request["seed"]), image_path=normalized,
                                                      resolution=scale, softness=softness,
                                                      num_inference_steps=1)
        finally:
            self.model.callbacks.in_loop_callbacks().remove(reporter)
        result = generated.image
        actual_size = result.size
        # Allow the one-pixel rounding difference between Python and Swift.
        if max(abs(result.width - processing_size[0]), abs(result.height - processing_size[1])) > 1:
            raise ValueError(f"SeedVR2 returned {result.size} for a requested {processing_size} model pass")
        if result.size != target:
            result = result.resize(target, Image.Resampling.LANCZOS)
        return result, {"processingWidth": actual_size[0], "processingHeight": actual_size[1]}


class Worker:
    def __init__(self):
        self.key = None
        self.model = None

    def clear(self):
        self.key = self.model = None
        gc.collect()
        if torch := sys.modules.get("torch"):
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        if mx := sys.modules.get("mlx.core"):
            mx.clear_cache()

    def run(self, request, emit):
        from PIL import ImageCms

        operation = request["operation"]
        if operation not in ("generate", "enhance"):
            raise ValueError(f"Unknown operation: {operation}")
        output = Path(request["outputPath"])
        if output.exists():
            raise FileExistsError(f"Output already exists: {output.name}")
        model_path = Path(request["modelPath"]).absolute()
        if not model_path.exists():
            raise FileNotFoundError(f"Model file or directory is missing: {model_path}")
        variant = request["modelVariant"]
        config = None
        if operation == "generate":
            if variant != "sdxl" or model_path.suffix.lower() != ".safetensors" or not model_path.is_file():
                raise ValueError("Generation requires an SDXL safetensors checkpoint")
            config = Path(request.get("configPath") or Path(__file__).parent / "configs" / "sdxl").resolve(strict=True)
        elif not model_path.is_dir():
            raise ValueError("Enhancement requires a complete SeedVR2 model directory")
        key = (operation, model_path, request.get("modelID"), variant, config)

        def progress(message, fraction=None):
            fields = {} if fraction is None else {"fraction": fraction}
            emit("progress", message=message, **fields)

        if self.key != key:
            self.clear()
            progress(f"Loading {variant}")
            self.model = SDXL(model_path, config) if operation == "generate" else SeedVR(model_path, variant)
            self.key = key
        progress("Generating image" if operation == "generate" else "Enhancing image")
        image, details = self.model.run(request, progress)
        progress("Encoding PNG")
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        # The host owns staging and exports the requested file format only after this frame is complete.
        with output.open("xb") as handle:
            try:
                image.save(handle, format="PNG", icc_profile=profile)
            except BaseException:
                output.unlink(missing_ok=True)
                raise
        emit("done", path=str(output), **details)


def main():
    output = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    worker = Worker()
    for line in sys.stdin:
        job_id = ""

        def emit(kind, **fields):
            print(json.dumps({"id": job_id, "type": kind, **fields}, allow_nan=False), file=output, flush=True)

        try:
            request = json.loads(line)
            job_id = request["id"]
            worker.run(request, emit)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            worker.clear()
            emit("error", message=str(error) or type(error).__name__)


if __name__ == "__main__":
    main()
