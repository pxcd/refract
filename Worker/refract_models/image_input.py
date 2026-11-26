"""Decode source images into the sRGB orientation shared by model adapters."""

import io
import subprocess
import tempfile
from pathlib import Path


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
