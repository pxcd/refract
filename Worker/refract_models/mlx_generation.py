"""Text-to-image from verified, locally stored MLX packages."""

from functools import partial


class MLXGeneration:
    operation = "generate"
    model_names = {
        "flux1-krea-dev": "krea-dev",
        "qwen-image-2512": "Qwen/Qwen-Image-2512",
        "z-image-turbo": "z-image-turbo",
    }
    variants = tuple(model_names)

    @classmethod
    def prepare(cls, path, request):
        if not path.is_dir():
            raise ValueError("MLX generation requires a complete model package folder")
        if request.get("inputPath") or request.get("loras"):
            raise ValueError("This Refract model route supports text-to-image only")
        width, height = request["width"], request["height"]
        if any(edge < 64 or edge % 16 for edge in (width, height)):
            raise ValueError("Enter dimensions of at least 64 pixels, in multiples of 16")
        model_name = cls.model_names[request["modelVariant"]]
        return model_name, partial(cls, path, request["modelVariant"])

    def __init__(self, path, variant):
        from mlxgen import load_generation_model
        from mflux.models.common.config.config import Config

        Config.set_progress_enabled(False)

        if variant == "flux1-krea-dev":
            from mflux.models.common.config import ModelConfig
            from mflux.models.flux.variants.txt2img.flux import Flux1

            # The unified API excludes FLUX.1, which has a dedicated runtime in the same package.
            self.model = Flux1(model_path=str(path), model_config=ModelConfig.krea_dev())
        else:
            self.model = load_generation_model(
                model=self.model_names[variant], model_path=str(path), task="text-to-image",
            ).model

    def run(self, request, progress):
        from PIL import Image

        def report(event):
            if event.phase == "denoise" and event.total_steps:
                progress(f"Denoising {event.step}/{event.total_steps}", event.step_progress)

        options = {}
        if request["modelVariant"] != "z-image-turbo":
            options["guidance"] = request["guidance"]
        if request["modelVariant"] == "qwen-image-2512":
            options["negative_prompt"] = request.get("negativePrompt") or None

        unsubscribe = self.model.callbacks.subscribe_progress(report)
        try:
            image = self.model.generate_image(
                seed=request["seed"], prompt=request["prompt"],
                width=request["width"], height=request["height"],
                num_inference_steps=request["steps"], **options,
            )
        finally:
            unsubscribe()
        if not isinstance(image, Image.Image):
            image = image.image
        return image.convert("RGB"), {}
