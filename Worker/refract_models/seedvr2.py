"""SeedVR2 still-image restoration through MLX-Gen."""

import json
import tempfile
from functools import partial
from pathlib import Path

from .image_input import input_image


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
    operation = "enhance"
    variants = ("seedvr2-3b", "seedvr2-7b", "seedvr2-7b-sharp")

    @classmethod
    def prepare(cls, path, request):
        if not path.is_dir():
            raise ValueError("Enhancement requires a complete SeedVR2 model directory")
        return None, partial(cls, path, request["modelVariant"])

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
