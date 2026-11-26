"""Built-in adapters. Model weights never determine which Python code is imported."""

from .mlx_generation import MLXGeneration
from .sdxl import SDXL
from .seedvr2 import SeedVR


ADAPTERS = {
    (adapter.operation, variant): adapter
    for adapter in (SDXL, MLXGeneration, SeedVR)
    for variant in adapter.variants
}
