"""Map viewport brush hits to local heightfield cells."""
from .units import EPS
from .units import meters_to_bu
from bpy_extras import view3d_utils

def hf_face_cell(obj, face_index):
    if (
        face_index is None
        or face_index < 0
        or face_index >= len(obj.data.polygons)
    ):
        return None

    mesh = obj.data
    attr_x = mesh.attributes.get("hf_grid_x")
    attr_y = mesh.attributes.get("hf_grid_y")
    if attr_x is None or attr_y is None:
        return None

    return (
        int(attr_x.data[face_index].value),
        int(attr_y.data[face_index].value),
    )


def hf_view_ray_hit(context, obj, mouse_x, mouse_y):
    region = context.region
    rv3d = context.space_data.region_3d
    coord = (mouse_x, mouse_y)

    origin_world = view3d_utils.region_2d_to_origin_3d(
        region,
        rv3d,
        coord,
        clamp=1000000.0,
    )
    direction_world = view3d_utils.region_2d_to_vector_3d(
        region,
        rv3d,
        coord,
    )

    inv = obj.matrix_world.inverted()
    origin_local = inv @ origin_world
    direction_local = inv.to_3x3() @ direction_world

    if direction_local.length <= EPS:
        return None, -1

    direction_local.normalize()

    hit, location, normal, face_index = obj.ray_cast(
        origin_local,
        direction_local,
        distance=1.0e12,
        depsgraph=context.evaluated_depsgraph_get(),
    )

    if not hit:
        return None, -1

    return location.copy(), int(face_index)


def hf_local_radius_from_meters(context, obj, meters):
    respect_units = bool(
        obj.get(
            "hf_respect_scene_units",
            context.scene.hf_settings.respect_scene_units,
        )
    )
    radius_bu = meters_to_bu(
        context.scene,
        meters,
        respect_units,
    )

    # The generated mesh starts at scale 1. If it was subsequently scaled in
    # object mode, compensate approximately in XY so the UI still reads meters.
    xy_scale = max(abs(obj.scale.x), abs(obj.scale.y), EPS)
    return radius_bu / xy_scale
