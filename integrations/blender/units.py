"""World-unit conversion and grid quantization."""
import math

EPS = 1.0e-7


def meters_to_bu(scene, meters, respect_scene_units=True):
    """Convert real-world meters to Blender Units."""
    if not respect_scene_units:
        return meters
    scale = scene.unit_settings.scale_length
    if abs(scale) < EPS:
        scale = 1.0
    return meters / scale


def bu_to_meters(scene, blender_units, respect_scene_units=True):
    """Convert Blender Units to real-world meters."""
    if not respect_scene_units:
        return blender_units
    scale = scene.unit_settings.scale_length
    if abs(scale) < EPS:
        scale = 1.0
    return blender_units * scale


def aligned_floor(value, step, origin):
    return math.floor(((value - origin) / step) + 1.0e-10) * step + origin


def aligned_ceil(value, step, origin):
    return math.ceil(((value - origin) / step) - 1.0e-10) * step + origin


def quantize_height(value, step, origin, mode):
    q = (value - origin) / step

    if mode == 'FLOOR':
        n = math.floor(q + 1.0e-10)
    elif mode == 'CEIL':
        n = math.ceil(q - 1.0e-10)
    else:
        # Round half away from zero instead of Python's banker rounding.
        if q >= 0.0:
            n = math.floor(q + 0.5)
        else:
            n = math.ceil(q - 0.5)

    return origin + n * step
