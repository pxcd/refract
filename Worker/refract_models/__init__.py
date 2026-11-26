"""Built-in adapters. Model weights never determine which Python code is imported."""

from .sdxl import SDXL
from .seedvr2 import SeedVR


ADAPTERS = {
    (adapter.operation, variant): adapter
    for adapter in (SDXL, SeedVR)
    for variant in adapter.variants
}
