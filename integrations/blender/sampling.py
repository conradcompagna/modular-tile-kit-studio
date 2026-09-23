"""Evaluated mesh sampling with explicit temporary-mesh cleanup."""
from mathutils.bvhtree import BVHTree
from mathutils import Vector

def build_world_bvh(obj, depsgraph, include_modifiers):
    """
    Return:
        bvh,
        world-space source bounds,
        polygon material indices,
        cleanup callback
    """
    if include_modifiers:
        owner = obj.evaluated_get(depsgraph)
    else:
        owner = obj

    temp_mesh = owner.to_mesh()
    if temp_mesh is None or len(temp_mesh.vertices) == 0 or len(temp_mesh.polygons) == 0:
        try:
            owner.to_mesh_clear()
        except Exception:
            pass
        raise RuntimeError("The evaluated object has no polygon mesh to sample.")

    matrix_world = owner.matrix_world.copy()
    verts_world = [matrix_world @ v.co for v in temp_mesh.vertices]
    polygons = [tuple(p.vertices) for p in temp_mesh.polygons]
    poly_material_indices = [p.material_index for p in temp_mesh.polygons]

    bvh = BVHTree.FromPolygons(
        verts_world,
        polygons,
        all_triangles=False,
        epsilon=1.0e-7,
    )

    xs = [v.x for v in verts_world]
    ys = [v.y for v in verts_world]
    zs = [v.z for v in verts_world]
    bounds = (
        min(xs), max(xs),
        min(ys), max(ys),
        min(zs), max(zs),
    )

    def cleanup():
        owner.to_mesh_clear()

    return bvh, bounds, poly_material_indices, cleanup


def ray_sample(bvh, x, y, ray_start_z, ray_distance):
    hit, normal, poly_index, distance = bvh.ray_cast(
        Vector((x, y, ray_start_z)),
        Vector((0.0, 0.0, -1.0)),
        ray_distance,
    )
    if hit is None:
        return None
    return hit.z, poly_index
