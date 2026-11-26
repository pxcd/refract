"""One JSON request per line. stdout is reserved for replies, including during imports."""

import gc
import json
import os
import sys
import traceback
from pathlib import Path

os.environ.update(
    HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", HF_HUB_DISABLE_PROGRESS_BARS="1",
    TOKENIZERS_PARALLELISM="false", PYTORCH_ENABLE_MPS_FALLBACK="0",
)


# The app and qualification tools can start the bundled worker with Python -I.
# Load adapters from the worker's own code directory in that mode.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from refract_models import ADAPTERS


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
        adapter = ADAPTERS.get((operation, variant))
        if adapter is None:
            raise ValueError(f"Unsupported {operation} model variant: {variant}")
        configuration, load_model = adapter.prepare(model_path, request)
        key = (operation, model_path, request.get("modelID"), variant, configuration)

        def progress(message, fraction=None):
            fields = {} if fraction is None else {"fraction": fraction}
            emit("progress", message=message, **fields)

        if self.key != key:
            self.clear()
            progress(f"Loading {variant}")
            self.model = load_model()
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
