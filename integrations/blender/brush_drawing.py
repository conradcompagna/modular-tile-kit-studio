"""Draw transient brush outlines in the viewport."""
from mathutils import Vector
from .gpu_support import batch_for_shader
from .gpu_support import gpu
import math
from bpy_extras import view3d_utils

def hf_draw_screen_circle(context, obj, hit_local, radius_local, color):
    if (
        gpu is None
        or batch_for_shader is None
        or hit_local is None
        or radius_local <= 0.0
    ):
        return

    region = context.region
    rv3d = context.space_data.region_3d
    points = []
    segments = 48

    for i in range(segments + 1):
        angle = math.tau * i / segments
        local = Vector(
            (
                hit_local.x + math.cos(angle) * radius_local,
                hit_local.y + math.sin(angle) * radius_local,
                hit_local.z,
            )
        )
        world = obj.matrix_world @ local
        p = view3d_utils.location_3d_to_region_2d(
            region,
            rv3d,
            world,
            default=None,
        )
        if p is not None:
            points.append((p.x, p.y, 0.0))

    if len(points) < 3:
        return

    try:
        shader = gpu.shader.from_builtin('UNIFORM_COLOR')
        batch = batch_for_shader(shader, 'LINE_STRIP', {"pos": points})
        gpu.state.blend_set('ALPHA')
        try:
            gpu.state.line_width_set(2.0)
        except Exception:
            pass
        shader.bind()
        shader.uniform_float("color", color)
        batch.draw(shader)
    except Exception:
        pass
    finally:
        try:
            gpu.state.line_width_set(1.0)
            gpu.state.blend_set('NONE')
        except Exception:
            pass
