"""SDXL single-file checkpoints and weighted LoRAs through Diffusers."""

from functools import partial
from pathlib import Path

from .image_input import input_image, validate_dimensions


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
    operation = "generate"
    variants = ("sdxl",)

    @classmethod
    def prepare(cls, path, request):
        if path.suffix.lower() != ".safetensors" or not path.is_file():
            raise ValueError("Generation requires an SDXL safetensors checkpoint")
        bundled = Path(__file__).resolve().parents[1] / "configs" / "sdxl"
        # Only Refract's installed component configuration may select Python loader classes.
        config = bundled.resolve(strict=True)
        return config, partial(cls, path, config)

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
        source = request.get("inputPath")
        preserve = bool(source and request.get("preserveReferenceSize"))
        if any(value <= 0 or (not preserve and value % 8) for value in size):
            raise ValueError("SDXL dimensions must be positive multiples of eight")
        steps = int(request["steps"])
        if steps < 1:
            raise ValueError("SDXL requires at least one denoising step")
        crop = None
        if source:
            strength = float(request["strength"])
            if not 0 < strength <= 1 or int(steps * strength) < 1:
                raise ValueError("The reference strength and step count must allow at least one denoising step")
            if self.image is None:
                self.image = StableDiffusionXLImg2ImgPipeline.from_pipe(self.text, add_watermarker=False)
                self.image.set_progress_bar_config(disable=True)
            pipeline = self.image
            reference = input_image(source)
            processing_size = size
            if preserve:
                if reference.size != size:
                    raise ValueError("The reference image resolution has changed since the job was queued")
                processing_size = tuple(max(64, ((edge + 7) // 8) * 8) for edge in size)
                validate_dimensions(*processing_size)
                if processing_size != size:
                    import numpy as np

                    extra_width, extra_height = (padded - edge for padded, edge in zip(processing_size, size))
                    left, top = extra_width // 2, extra_height // 2
                    # Extend edge pixels into the padding so the original framing stays intact.
                    pad = ((top, extra_height - top), (left, extra_width - left), (0, 0))
                    reference = Image.fromarray(np.pad(np.asarray(reference), pad, mode="edge"))
                    crop = (left, top, left + size[0], top + size[1])
            else:
                reference = ImageOps.fit(reference, size, method=Image.Resampling.LANCZOS)
            arguments = dict(image=reference, strength=strength, original_size=size[::-1], target_size=processing_size[::-1])
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
        image = result.images[0]
        if crop is not None:
            if image.size != processing_size:
                raise ValueError(f"SDXL returned {image.size} for a requested {processing_size} model pass")
            return image.crop(crop), {"processingWidth": processing_size[0], "processingHeight": processing_size[1]}
        return image, {}
