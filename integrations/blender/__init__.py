"""Grid Heightfield Tools: Blender extension entrypoint.

Geometry, operators, settings and UI are separate modules; registration owns
the scene property and class lifecycle.
"""
from .registration import register, unregister
ADDON_VERSION = (1, 2, 0)

__all__ = ["register", "unregister", "ADDON_VERSION"]
