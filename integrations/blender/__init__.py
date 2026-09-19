import bpy
import math

from bpy.types import Operator, Panel, PropertyGroup
from bpy.props import (
    BoolProperty,
    EnumProperty,
    FloatProperty,
    IntProperty,
    PointerProperty,
)
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from bpy_extras import view3d_utils

try:
    import gpu
    from gpu_extras.batch import batch_for_shader
except Exception:
    gpu = None
    batch_for_shader = None


ADDON_VERSION = (1, 2, 0)
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


def create_mesh_object(context, source_obj, name, vertices, faces, metadata):
    mesh = bpy.data.meshes.new(name + "_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()

    new_obj = bpy.data.objects.new(name, mesh)
    collection = source_obj.users_collection[0] if source_obj.users_collection else context.collection
    collection.objects.link(new_obj)

    # New Blender objects start with an identity transform, and the generated
    # vertex coordinates are already in world space.

    # Face attributes are intentionally simple and game-pipeline-friendly.
    if len(mesh.polygons) == len(metadata):
        attr_x = mesh.attributes.new("hf_grid_x", type='INT', domain='FACE')
        attr_y = mesh.attributes.new("hf_grid_y", type='INT', domain='FACE')
        attr_height = mesh.attributes.new("hf_height_m", type='FLOAT', domain='FACE')
        attr_kind = mesh.attributes.new("hf_face_kind", type='INT', domain='FACE')
        attr_band = mesh.attributes.new("hf_band_index", type='INT', domain='FACE')
        attr_smooth_e = mesh.attributes.new("hf_smooth_east", type='BOOLEAN', domain='FACE')
        attr_smooth_n = mesh.attributes.new("hf_smooth_north", type='BOOLEAN', domain='FACE')

        for i, meta in enumerate(metadata):
            attr_x.data[i].value = meta["grid_x"]
            attr_y.data[i].value = meta["grid_y"]
            attr_height.data[i].value = meta["height_m"]
            attr_kind.data[i].value = meta["kind"]
            attr_band.data[i].value = meta["band_index"]
            attr_smooth_e.data[i].value = bool(meta.get("smooth_east", False))
            attr_smooth_n.data[i].value = bool(meta.get("smooth_north", False))

    return new_obj


class HF_Settings(PropertyGroup):
    output_mode: EnumProperty(
        name="Output",
        description="How the sampled grid is turned into geometry",
        items=[
            (
                'STEPPED',
                "Stepped Tiles",
                "One flat height per grid square; adds vertical faces between different heights",
            ),
            (
                'SURFACE',
                "Connected Surface",
                "Shared grid vertices form a continuous heightfield with sloped quads",
            ),
        ],
        default='STEPPED',
    )

    grid_size_m: FloatProperty(
        name="Grid Size (m)",
        description="Horizontal square size in meters",
        default=1.0,
        min=0.001,
        soft_max=10.0,
        precision=3,
    )

    snap_height: BoolProperty(
        name="Snap Heights",
        description="Quantize sampled heights to a fixed vertical increment",
        default=True,
    )

    height_step_m: FloatProperty(
        name="Height Step (m)",
        description="Vertical quantization increment in meters",
        default=1.0,
        min=0.001,
        soft_max=10.0,
        precision=3,
    )

    height_snap_mode: EnumProperty(
        name="Height Rounding",
        description="How sampled heights are quantized",
        items=[
            ('NEAREST', "Nearest", "Snap to the nearest height step"),
            ('FLOOR', "Floor", "Always snap downward"),
            ('CEIL', "Ceiling", "Always snap upward"),
        ],
        default='NEAREST',
    )

    grid_origin_x_m: FloatProperty(
        name="Grid Origin X (m)",
        description="World-space X origin used to align the grid",
        default=0.0,
        precision=3,
    )

    grid_origin_y_m: FloatProperty(
        name="Grid Origin Y (m)",
        description="World-space Y origin used to align the grid",
        default=0.0,
        precision=3,
    )

    height_origin_m: FloatProperty(
        name="Height Origin Z (m)",
        description="World-space Z origin used for vertical snapping",
        default=0.0,
        precision=3,
    )

    include_modifiers: BoolProperty(
        name="Use Evaluated Mesh",
        description="Sample the mesh after its modifiers have been evaluated",
        default=True,
    )

    respect_scene_units: BoolProperty(
        name="Respect Scene Unit Scale",
        description="Interpret the numeric size fields as real meters using Scene Unit Scale",
        default=True,
    )

    create_step_walls: BoolProperty(
        name="Create Step Walls",
        description="Create vertical faces wherever neighboring stepped cells have different heights",
        default=True,
    )

    band_step_walls: BoolProperty(
        name="Band Step Walls",
        description="Split vertical step faces into one height-step band per quad",
        default=True,
    )

    smooth_low_transitions: BoolProperty(
        name="Smooth Low Steps",
        description=(
            "After the stepped pass, connect neighboring cells whose vertical "
            "difference is at or below the smoothing threshold"
        ),
        default=False,
    )

    smooth_threshold_m: FloatProperty(
        name="Smooth Threshold (m)",
        description=(
            "Maximum vertical difference between neighboring cells that may be "
            "converted from a hard step into a connected slope"
        ),
        default=0.5,
        min=0.0,
        soft_max=5.0,
        precision=3,
    )

    smooth_threshold_basis: EnumProperty(
        name="Threshold Basis",
        description="Which heights are compared when deciding whether an edge is gentle",
        items=[
            (
                'SOURCE',
                "Original Samples",
                "Compare the unsnapped source samples; best for removing quantization stairs",
            ),
            (
                'OUTPUT',
                "Stepped Output",
                "Compare the post-snap stepped heights; useful when processing an already-stepped mesh",
            ),
        ],
        default='SOURCE',
    )

    boundary_skirt: BoolProperty(
        name="Boundary Skirt",
        description="Create vertical faces around exposed outer edges down to a base elevation",
        default=False,
    )

    boundary_base_mode: EnumProperty(
        name="Boundary Base",
        items=[
            ('SOURCE_MIN', "Source Minimum", "Use the source mesh's lowest Z as the boundary base"),
            ('CUSTOM', "Custom", "Use a custom world-space Z base"),
        ],
        default='SOURCE_MIN',
    )

    boundary_base_m: FloatProperty(
        name="Base Z (m)",
        description="Custom world-space Z for the bottom of boundary skirts",
        default=0.0,
        precision=3,
    )

    hide_source: BoolProperty(
        name="Hide Source",
        description="Hide the source object in the viewport after a successful conversion",
        default=False,
    )

    max_cells: IntProperty(
        name="Safety Cell Limit",
        description="Abort instead of accidentally creating an enormous grid",
        default=250000,
        min=100,
        soft_max=1000000,
    )

    manual_brush_show_outline: BoolProperty(
        name="Show Brush Outline",
        description="Show the current manual brush footprint in the 3D viewport",
        default=True,
    )

    slope_brush_radius_m: FloatProperty(
        name="Slope Radius (m)",
        description="Horizontal radius used to paint hard stair edges into slopes",
        default=0.65,
        min=0.05,
        soft_max=10.0,
        precision=2,
    )

    height_brush_action: EnumProperty(
        name="Height Action",
        description="Default direction for the manual height brush",
        items=[
            ('RAISE', "Raise", "Raise touched heightfield cells"),
            ('LOWER', "Lower", "Lower touched heightfield cells"),
        ],
        default='RAISE',
    )

    height_brush_increment_m: FloatProperty(
        name="Height Nudge (m)",
        description="Amount each touched cell moves per brush stroke",
        default=0.25,
        min=0.001,
        soft_max=5.0,
        precision=3,
    )

    height_brush_radius_cells: IntProperty(
        name="Height Radius (cells)",
        description="0 edits only the clicked cell; 1 edits a 3x3 neighborhood; and so on",
        default=0,
        min=0,
        max=32,
    )


class OBJECT_OT_convert_grid_heightfield(Operator):
    bl_idname = "object.convert_grid_heightfield"
    bl_label = "Convert Selected Mesh"
    bl_description = "Sample the selected mesh from above and rebuild it on an exact XY grid"
    bl_options = {'REGISTER', 'UNDO'}

    @classmethod
    def poll(cls, context):
        obj = context.active_object
        return obj is not None and obj.type == 'MESH'

    def execute(self, context):
        source = context.active_object
        settings = context.scene.hf_settings

        if source is None or source.type != 'MESH':
            self.report({'ERROR'}, "Select one mesh object.")
            return {'CANCELLED'}

        if source.mode != 'OBJECT':
            self.report({'ERROR'}, "Switch the selected mesh to Object Mode first.")
            return {'CANCELLED'}

        scene = context.scene
        grid = meters_to_bu(scene, settings.grid_size_m, settings.respect_scene_units)
        height_step = meters_to_bu(scene, settings.height_step_m, settings.respect_scene_units)
        origin_x = meters_to_bu(scene, settings.grid_origin_x_m, settings.respect_scene_units)
        origin_y = meters_to_bu(scene, settings.grid_origin_y_m, settings.respect_scene_units)
        height_origin = meters_to_bu(scene, settings.height_origin_m, settings.respect_scene_units)

        if grid <= EPS:
            self.report({'ERROR'}, "Grid Size must be greater than zero.")
            return {'CANCELLED'}

        if settings.snap_height and height_step <= EPS:
            self.report({'ERROR'}, "Height Step must be greater than zero when height snapping is enabled.")
            return {'CANCELLED'}

        depsgraph = context.evaluated_depsgraph_get()
        cleanup = None
        wm = context.window_manager

        try:
            bvh, bounds, poly_material_indices, cleanup = build_world_bvh(
                source,
                depsgraph,
                settings.include_modifiers,
            )

            src_min_x, src_max_x, src_min_y, src_max_y, src_min_z, src_max_z = bounds

            min_x = aligned_floor(src_min_x, grid, origin_x)
            max_x = aligned_ceil(src_max_x, grid, origin_x)
            min_y = aligned_floor(src_min_y, grid, origin_y)
            max_y = aligned_ceil(src_max_y, grid, origin_y)

            nx = max(1, int(round((max_x - min_x) / grid)))
            ny = max(1, int(round((max_y - min_y) / grid)))
            cell_count = nx * ny

            if cell_count > settings.max_cells:
                self.report(
                    {'ERROR'},
                    f"Grid would contain {cell_count:,} cells "
                    f"({nx} x {ny}), above the safety limit of {settings.max_cells:,}. "
                    "Increase Grid Size or Safety Cell Limit.",
                )
                return {'CANCELLED'}

            z_span = max(src_max_z - src_min_z, grid)
            ray_pad = max(grid, z_span * 0.05, 0.1)
            ray_start_z = src_max_z + ray_pad
            ray_distance = z_span + (2.0 * ray_pad)

            if settings.output_mode == 'STEPPED':
                result = self._build_stepped(
                    context,
                    source,
                    settings,
                    bvh,
                    min_x,
                    min_y,
                    nx,
                    ny,
                    grid,
                    height_step,
                    height_origin,
                    src_min_z,
                    ray_start_z,
                    ray_distance,
                    wm,
                )
            else:
                result = self._build_surface(
                    context,
                    source,
                    settings,
                    bvh,
                    min_x,
                    min_y,
                    nx,
                    ny,
                    grid,
                    height_step,
                    height_origin,
                    ray_start_z,
                    ray_distance,
                    wm,
                )

            if result is None:
                self.report({'ERROR'}, "No downward ray samples hit the selected mesh.")
                return {'CANCELLED'}

            new_obj, top_cell_count, total_face_count = result

            new_obj["hf_source_object"] = source.name
            new_obj["hf_grid_size_m"] = settings.grid_size_m
            new_obj["hf_height_snap_enabled"] = settings.snap_height
            new_obj["hf_height_step_m"] = settings.height_step_m if settings.snap_height else 0.0
            new_obj["hf_mode"] = settings.output_mode
            new_obj["hf_world_z_up"] = True
            new_obj["hf_smooth_low_transitions"] = (
                settings.output_mode == 'STEPPED' and settings.smooth_low_transitions
            )
            new_obj["hf_smooth_threshold_m"] = (
                settings.smooth_threshold_m
                if settings.output_mode == 'STEPPED' and settings.smooth_low_transitions
                else 0.0
            )
            new_obj["hf_smooth_threshold_basis"] = (
                settings.smooth_threshold_basis
                if settings.output_mode == 'STEPPED' and settings.smooth_low_transitions
                else "NONE"
            )
            new_obj["hf_band_step_walls"] = bool(settings.band_step_walls)
            new_obj["hf_boundary_skirt"] = bool(settings.boundary_skirt)
            new_obj["hf_create_step_walls"] = bool(settings.create_step_walls)
            new_obj["hf_respect_scene_units"] = bool(settings.respect_scene_units)

            if settings.hide_source:
                source.hide_set(True)

            # Select only the result.
            for obj in context.selected_objects:
                obj.select_set(False)
            new_obj.select_set(True)
            context.view_layer.objects.active = new_obj

            self.report(
                {'INFO'},
                f"Created {new_obj.name}: {top_cell_count:,} top cells, "
                f"{total_face_count:,} total faces.",
            )
            return {'FINISHED'}

        except Exception as exc:
            self.report({'ERROR'}, f"Heightfield conversion failed: {exc}")
            return {'CANCELLED'}

        finally:
            try:
                wm.progress_end()
            except Exception:
                pass
            if cleanup is not None:
                try:
                    cleanup()
                except Exception:
                    pass

    def _sample_height(self, settings, raw_z, height_step, height_origin):
        if not settings.snap_height:
            return raw_z
        return quantize_height(
            raw_z,
            height_step,
            height_origin,
            settings.height_snap_mode,
        )

    def _build_stepped(
        self,
        context,
        source,
        settings,
        bvh,
        min_x,
        min_y,
        nx,
        ny,
        grid,
        height_step,
        height_origin,
        source_min_z,
        ray_start_z,
        ray_distance,
        wm,
    ):
        """
        Build the cell-centered stepped field.

        With Smooth Low Steps disabled this behaves like the original stepped
        converter: every cell is a flat quad and height differences become
        vertical walls.

        With Smooth Low Steps enabled, neighboring cells are classified edge by
        edge. Gentle edges become connected surface edges; hard edges remain
        discontinuities with vertical walls. This gives a hybrid heightfield:
        rolling terrain can slope while real ledges/cliffs stay stepped.
        """
        scene = context.scene
        cells = {}

        wm.progress_begin(0, ny)
        for iy in range(ny):
            y = min_y + (iy + 0.5) * grid
            for ix in range(nx):
                x = min_x + (ix + 0.5) * grid
                sample = ray_sample(bvh, x, y, ray_start_z, ray_distance)
                if sample is None:
                    continue

                raw_z, poly_index = sample
                z = self._sample_height(settings, raw_z, height_step, height_origin)
                cells[(ix, iy)] = {
                    "raw_z": raw_z,
                    "z": z,
                    "poly_index": poly_index if poly_index is not None else -1,
                }
            wm.progress_update(iy + 1)

        if not cells:
            return None

        vertices = []
        faces = []
        metadata = []

        def append_face(
            coords,
            ix,
            iy,
            height_bu,
            kind,
            band_index=0,
            smooth_east=False,
            smooth_north=False,
        ):
            start_index = len(vertices)
            vertices.extend(coords)
            faces.append(
                (
                    start_index,
                    start_index + 1,
                    start_index + 2,
                    start_index + 3,
                )
            )
            metadata.append(
                {
                    "grid_x": ix,
                    "grid_y": iy,
                    "height_m": bu_to_meters(
                        scene,
                        height_bu,
                        settings.respect_scene_units,
                    ),
                    "kind": kind,  # 0 top, 1 step wall, 2 boundary wall
                    "band_index": band_index,
                    "smooth_east": bool(smooth_east),
                    "smooth_north": bool(smooth_north),
                }
            )

        # ------------------------------------------------------------------
        # HYBRID EDGE CLASSIFICATION
        # ------------------------------------------------------------------

        smooth_enabled = settings.smooth_low_transitions
        smooth_edges = set()
        threshold_bu = meters_to_bu(
            scene,
            settings.smooth_threshold_m,
            settings.respect_scene_units,
        )

        def edge_key(a, b):
            return tuple(sorted((a, b)))

        def transition_height(cell):
            if settings.smooth_threshold_basis == 'SOURCE':
                return cell["raw_z"]
            return cell["z"]

        if smooth_enabled:
            # Only E and N are required to visit every internal edge once.
            for (ix, iy), cell in cells.items():
                for dx, dy in ((1, 0), (0, 1)):
                    npos = (ix + dx, iy + dy)
                    neighbor = cells.get(npos)
                    if neighbor is None:
                        continue

                    delta = abs(
                        transition_height(cell) -
                        transition_height(neighbor)
                    )
                    if delta <= threshold_bu + EPS:
                        smooth_edges.add(edge_key((ix, iy), npos))

        def edge_is_smooth(a, b):
            return smooth_enabled and edge_key(a, b) in smooth_edges

        # ------------------------------------------------------------------
        # TOP CORNER HEIGHTS
        # ------------------------------------------------------------------
        #
        # The stepped representation is cell-centered, while a connected
        # surface needs shared corner heights. At each grid corner we collect
        # the cells touching that corner and form local connected components
        # using ONLY edges classified as gentle. Cells in the same local
        # component share one averaged corner height. Cells separated by a
        # hard edge keep separate corner heights, allowing a vertical cliff to
        # terminate at the same XY lattice point without forcing the cliff to
        # smooth away.
        #
        # This local-component construction is what makes mixed terrain robust
        # at T-junctions where a rolling slope runs into a sharp ledge.

        corner_heights = {}

        corner_candidates = (
            (-1, -1, "NE"),
            (0, -1, "NW"),
            (-1, 0, "SE"),
            (0, 0, "SW"),
        )

        for gy in range(ny + 1):
            for gx in range(nx + 1):
                incident = []
                corner_name_for_cell = {}

                for ox, oy, corner_name in corner_candidates:
                    cell_pos = (gx + ox, gy + oy)
                    if cell_pos in cells:
                        incident.append(cell_pos)
                        corner_name_for_cell[cell_pos] = corner_name

                if not incident:
                    continue

                # Build adjacency around this particular lattice corner.
                adjacency = {cell_pos: set() for cell_pos in incident}

                if smooth_enabled:
                    incident_set = set(incident)
                    for cell_pos in incident:
                        ix, iy = cell_pos
                        for neighbor_pos in (
                            (ix - 1, iy),
                            (ix + 1, iy),
                            (ix, iy - 1),
                            (ix, iy + 1),
                        ):
                            if (
                                neighbor_pos in incident_set
                                and edge_is_smooth(cell_pos, neighbor_pos)
                            ):
                                adjacency[cell_pos].add(neighbor_pos)

                visited = set()

                for seed in incident:
                    if seed in visited:
                        continue

                    stack = [seed]
                    component = []
                    visited.add(seed)

                    while stack:
                        current = stack.pop()
                        component.append(current)
                        for neighbor_pos in adjacency[current]:
                            if neighbor_pos not in visited:
                                visited.add(neighbor_pos)
                                stack.append(neighbor_pos)

                    if len(component) >= 2:
                        # Use the same basis that decided the edge. In SOURCE
                        # mode this deliberately restores sub-step terrain that
                        # was lost to 1m vertical quantization.
                        z_corner = sum(
                            transition_height(cells[pos])
                            for pos in component
                        ) / len(component)
                    else:
                        # No gentle connection reaches this cell at this corner,
                        # so preserve its stepped/output elevation.
                        z_corner = cells[component[0]]["z"]

                    for cell_pos in component:
                        corner_name = corner_name_for_cell[cell_pos]
                        corner_heights[(cell_pos, corner_name)] = z_corner

        def cell_corners(cell_pos):
            cell = cells[cell_pos]
            if not smooth_enabled:
                z = cell["z"]
                return {
                    "SW": z,
                    "SE": z,
                    "NE": z,
                    "NW": z,
                }

            return {
                "SW": corner_heights.get((cell_pos, "SW"), cell["z"]),
                "SE": corner_heights.get((cell_pos, "SE"), cell["z"]),
                "NE": corner_heights.get((cell_pos, "NE"), cell["z"]),
                "NW": corner_heights.get((cell_pos, "NW"), cell["z"]),
            }

        all_corners = {
            cell_pos: cell_corners(cell_pos)
            for cell_pos in cells
        }

        # One top quad per cell. In pure stepped mode all four Z values are
        # identical. In hybrid mode a cell may become a sloped quad.
        for (ix, iy), cell in cells.items():
            x0 = min_x + ix * grid
            x1 = x0 + grid
            y0 = min_y + iy * grid
            y1 = y0 + grid
            c = all_corners[(ix, iy)]

            current_pos = (ix, iy)
            append_face(
                [
                    (x0, y0, c["SW"]),
                    (x1, y0, c["SE"]),
                    (x1, y1, c["NE"]),
                    (x0, y1, c["NW"]),
                ],
                ix,
                iy,
                cell["z"],
                0,
                0,
                smooth_east=(
                    (ix + 1, iy) in cells
                    and edge_key(current_pos, (ix + 1, iy)) in smooth_edges
                ),
                smooth_north=(
                    (ix, iy + 1) in cells
                    and edge_key(current_pos, (ix, iy + 1)) in smooth_edges
                ),
            )

        # ------------------------------------------------------------------
        # VERTICAL WALLS
        # ------------------------------------------------------------------

        if settings.boundary_base_mode == 'CUSTOM':
            boundary_base = meters_to_bu(
                scene,
                settings.boundary_base_m,
                settings.respect_scene_units,
            )
        else:
            boundary_base = source_min_z
            if settings.snap_height:
                boundary_base = quantize_height(
                    boundary_base,
                    height_step,
                    height_origin,
                    'FLOOR',
                )

        def edge_pair(cell_pos, direction):
            c = all_corners[cell_pos]
            if direction == 'S':
                return c["SW"], c["SE"]
            if direction == 'N':
                return c["NW"], c["NE"]
            if direction == 'W':
                return c["SW"], c["NW"]
            return c["SE"], c["NE"]  # E

        def append_wall_quad(
            ix,
            iy,
            direction,
            high_a,
            high_b,
            low_a,
            low_b,
            kind,
            band_index=0,
        ):
            x0 = min_x + ix * grid
            x1 = x0 + grid
            y0 = min_y + iy * grid
            y1 = y0 + grid

            # A/B are ordered along +X for N/S and +Y for E/W.
            if direction == 'S':
                coords = [
                    (x1, y0, high_b),
                    (x0, y0, high_a),
                    (x0, y0, low_a),
                    (x1, y0, low_b),
                ]
            elif direction == 'N':
                coords = [
                    (x0, y1, high_a),
                    (x1, y1, high_b),
                    (x1, y1, low_b),
                    (x0, y1, low_a),
                ]
            elif direction == 'W':
                coords = [
                    (x0, y0, high_a),
                    (x0, y1, high_b),
                    (x0, y1, low_b),
                    (x0, y0, low_a),
                ]
            else:  # E
                coords = [
                    (x1, y1, high_b),
                    (x1, y0, high_a),
                    (x1, y0, low_a),
                    (x1, y1, low_b),
                ]

            append_face(
                coords,
                ix,
                iy,
                (high_a + high_b) * 0.5,
                kind,
                band_index,
            )

        def add_wall(
            ix,
            iy,
            direction,
            high_pair,
            low_pair,
            kind,
        ):
            high_a, high_b = high_pair
            low_a, low_b = low_pair

            if (
                high_a - low_a <= EPS
                and high_b - low_b <= EPS
            ):
                return

            # Exact 1m wall bands are possible only when both the top and
            # bottom edge are horizontal. Once hybrid smoothing makes either
            # edge sloped, keep one clean quad rather than inventing crooked
            # pseudo-bands.
            flat_high = abs(high_a - high_b) <= EPS
            flat_low = abs(low_a - low_b) <= EPS

            if (
                settings.band_step_walls
                and settings.snap_height
                and flat_high
                and flat_low
            ):
                z_high = high_a
                z_low = low_a
                band_index = 0

                while z_high - z_low > EPS:
                    next_low = max(z_low, z_high - height_step)
                    append_wall_quad(
                        ix,
                        iy,
                        direction,
                        z_high,
                        z_high,
                        next_low,
                        next_low,
                        kind,
                        band_index,
                    )
                    z_high = next_low
                    band_index += 1
            else:
                append_wall_quad(
                    ix,
                    iy,
                    direction,
                    high_a,
                    high_b,
                    low_a,
                    low_b,
                    kind,
                    0,
                )

        if settings.create_step_walls:
            # Process each interior edge exactly once.
            for (ix, iy), cell in cells.items():
                current_pos = (ix, iy)

                # East edge.
                east_pos = (ix + 1, iy)
                east = cells.get(east_pos)
                if east is not None and not edge_is_smooth(current_pos, east_pos):
                    current_edge = edge_pair(current_pos, 'E')
                    east_edge = edge_pair(east_pos, 'W')
                    current_avg = sum(current_edge) * 0.5
                    east_avg = sum(east_edge) * 0.5

                    if current_avg > east_avg + EPS:
                        add_wall(
                            ix,
                            iy,
                            'E',
                            current_edge,
                            east_edge,
                            1,
                        )
                    elif east_avg > current_avg + EPS:
                        add_wall(
                            ix + 1,
                            iy,
                            'W',
                            east_edge,
                            current_edge,
                            1,
                        )

                # North edge.
                north_pos = (ix, iy + 1)
                north = cells.get(north_pos)
                if north is not None and not edge_is_smooth(current_pos, north_pos):
                    current_edge = edge_pair(current_pos, 'N')
                    north_edge = edge_pair(north_pos, 'S')
                    current_avg = sum(current_edge) * 0.5
                    north_avg = sum(north_edge) * 0.5

                    if current_avg > north_avg + EPS:
                        add_wall(
                            ix,
                            iy,
                            'N',
                            current_edge,
                            north_edge,
                            1,
                        )
                    elif north_avg > current_avg + EPS:
                        add_wall(
                            ix,
                            iy + 1,
                            'S',
                            north_edge,
                            current_edge,
                            1,
                        )

        if settings.boundary_skirt:
            for (ix, iy), cell in cells.items():
                current_pos = (ix, iy)
                for direction, dx, dy in (
                    ('S', 0, -1),
                    ('N', 0, 1),
                    ('W', -1, 0),
                    ('E', 1, 0),
                ):
                    if (ix + dx, iy + dy) in cells:
                        continue

                    high_pair = edge_pair(current_pos, direction)
                    low_pair = (boundary_base, boundary_base)

                    if (sum(high_pair) * 0.5) > boundary_base + EPS:
                        add_wall(
                            ix,
                            iy,
                            direction,
                            high_pair,
                            low_pair,
                            2,
                        )

        output_name = source.name + "_Heightfield"
        new_obj = create_mesh_object(
            context,
            source,
            output_name,
            vertices,
            faces,
            metadata,
        )

        # Helpful diagnostics for later export/debugging.
        new_obj["hf_smoothed_edge_count"] = len(smooth_edges)
        new_obj["hf_top_cell_count"] = len(cells)

        return new_obj, len(cells), len(faces)

    def _build_surface(
        self,
        context,
        source,
        settings,
        bvh,
        min_x,
        min_y,
        nx,
        ny,
        grid,
        height_step,
        height_origin,
        ray_start_z,
        ray_distance,
        wm,
    ):
        scene = context.scene
        sample_grid = {}
        vertices = []

        wm.progress_begin(0, ny + 1)
        for iy in range(ny + 1):
            y = min_y + iy * grid
            for ix in range(nx + 1):
                x = min_x + ix * grid
                sample = ray_sample(bvh, x, y, ray_start_z, ray_distance)
                if sample is None:
                    continue

                raw_z, poly_index = sample
                z = self._sample_height(settings, raw_z, height_step, height_origin)
                vert_index = len(vertices)
                vertices.append((x, y, z))
                sample_grid[(ix, iy)] = {
                    "vi": vert_index,
                    "z": z,
                    "poly_index": poly_index if poly_index is not None else -1,
                }
            wm.progress_update(iy + 1)

        if not sample_grid:
            return None

        faces = []
        metadata = []
        valid_cells = set()

        for iy in range(ny):
            for ix in range(nx):
                a = sample_grid.get((ix, iy))
                b = sample_grid.get((ix + 1, iy))
                c = sample_grid.get((ix + 1, iy + 1))
                d = sample_grid.get((ix, iy + 1))

                if a is not None and b is not None and c is not None and d is not None:
                    valid_cells.add((ix, iy))

        for iy in range(ny):
            for ix in range(nx):
                if (ix, iy) not in valid_cells:
                    continue

                a = sample_grid[(ix, iy)]
                b = sample_grid[(ix + 1, iy)]
                c = sample_grid[(ix + 1, iy + 1)]
                d = sample_grid[(ix, iy + 1)]

                faces.append((a["vi"], b["vi"], c["vi"], d["vi"]))
                avg_z = (a["z"] + b["z"] + c["z"] + d["z"]) * 0.25
                metadata.append(
                    {
                        "grid_x": ix,
                        "grid_y": iy,
                        "height_m": bu_to_meters(
                            scene,
                            avg_z,
                            settings.respect_scene_units,
                        ),
                        "kind": 0,
                        "band_index": 0,
                        "smooth_east": (ix + 1, iy) in valid_cells,
                        "smooth_north": (ix, iy + 1) in valid_cells,
                    }
                )

        if not faces:
            return None

        output_name = source.name + "_Heightfield"
        new_obj = create_mesh_object(
            context,
            source,
            output_name,
            vertices,
            faces,
            metadata,
        )
        return new_obj, len(faces), len(faces)


# =============================================================================
# MANUAL HEIGHTFIELD EDITING
# =============================================================================

HF_CORNER_NAMES = ("SW", "SE", "NE", "NW")


def hf_edge_key(a, b):
    return tuple(sorted((tuple(a), tuple(b))))


def hf_corner_nodes_for_cell(cell_pos):
    ix, iy = cell_pos
    return {
        "SW": (ix, iy),
        "SE": (ix + 1, iy),
        "NE": (ix + 1, iy + 1),
        "NW": (ix, iy + 1),
    }


def hf_has_edit_attributes(obj):
    if obj is None or obj.type != 'MESH':
        return False

    mesh = obj.data
    required = {
        "hf_grid_x",
        "hf_grid_y",
        "hf_height_m",
        "hf_face_kind",
        "hf_band_index",
    }
    return required.issubset(set(mesh.attributes.keys()))


def hf_cell_edge_names(direction):
    if direction == 'S':
        return ("SW", "SE")
    if direction == 'N':
        return ("NW", "NE")
    if direction == 'W':
        return ("SW", "NW")
    return ("SE", "NE")


def hf_edge_neighbor(cell_pos, direction):
    ix, iy = cell_pos
    if direction == 'S':
        return (ix, iy - 1)
    if direction == 'N':
        return (ix, iy + 1)
    if direction == 'W':
        return (ix - 1, iy)
    return (ix + 1, iy)


def hf_extract_edit_model(obj):
    """
    Read the CURRENT generated heightfield into a cell model.

    Manual tools always edit the currently selected heightfield, so a procedural
    connected pass can be followed by a hand-painted slope pass, which can then
    be followed by manual raise/lower edits.
    """
    if not hf_has_edit_attributes(obj):
        raise RuntimeError(
            "The selected mesh is not a Grid Heightfield output. "
            "Convert it with this add-on first."
        )

    mesh = obj.data

    attr_x = mesh.attributes.get("hf_grid_x")
    attr_y = mesh.attributes.get("hf_grid_y")
    attr_height = mesh.attributes.get("hf_height_m")
    attr_kind = mesh.attributes.get("hf_face_kind")
    attr_smooth_e = mesh.attributes.get("hf_smooth_east")
    attr_smooth_n = mesh.attributes.get("hf_smooth_north")

    cells = {}
    top_poly_for_cell = {}
    boundary_wall_z = []
    step_wall_count = 0
    boundary_wall_count = 0

    for poly in mesh.polygons:
        kind = int(attr_kind.data[poly.index].value)

        if kind == 1:
            step_wall_count += 1
            continue

        if kind == 2:
            boundary_wall_count += 1
            for vi in poly.vertices:
                boundary_wall_z.append(mesh.vertices[vi].co.z)
            continue

        if kind != 0:
            continue

        if len(poly.vertices) != 4:
            raise RuntimeError(
                "Manual brushes require generated top cells to remain quads. "
                "A top cell has been triangulated or otherwise retopologized."
            )

        ix = int(attr_x.data[poly.index].value)
        iy = int(attr_y.data[poly.index].value)
        cell_pos = (ix, iy)

        coords = [mesh.vertices[vi].co.copy() for vi in poly.vertices]
        min_x = min(v.x for v in coords)
        max_x = max(v.x for v in coords)
        min_y = min(v.y for v in coords)
        max_y = max(v.y for v in coords)

        corners = {}
        for co in coords:
            east = abs(co.x - max_x) <= abs(co.x - min_x)
            north = abs(co.y - max_y) <= abs(co.y - min_y)

            if north and east:
                name = "NE"
            elif north:
                name = "NW"
            elif east:
                name = "SE"
            else:
                name = "SW"

            corners[name] = co.copy()

        if set(corners.keys()) != set(HF_CORNER_NAMES):
            raise RuntimeError(
                "A top cell no longer has four distinct XY grid corners."
            )

        cells[cell_pos] = {
            "grid_x": ix,
            "grid_y": iy,
            "height_m": float(attr_height.data[poly.index].value),
            "material_index": int(poly.material_index),
            "corner_xy": {
                name: (corners[name].x, corners[name].y)
                for name in HF_CORNER_NAMES
            },
            "base_corner_z": {
                name: corners[name].z
                for name in HF_CORNER_NAMES
            },
            "stored_smooth_east": (
                bool(attr_smooth_e.data[poly.index].value)
                if attr_smooth_e is not None else False
            ),
            "stored_smooth_north": (
                bool(attr_smooth_n.data[poly.index].value)
                if attr_smooth_n is not None else False
            ),
        }
        top_poly_for_cell[cell_pos] = poly.index

    if not cells:
        raise RuntimeError("No heightfield top cells were found.")

    smooth_edges = set()

    # v1.2+ stores explicit intent. This matters because a flat seam should not
    # automatically turn into a ramp later just because one cell is raised.
    if attr_smooth_e is not None and attr_smooth_n is not None:
        for cell_pos, cell in cells.items():
            ix, iy = cell_pos

            east = (ix + 1, iy)
            if cell["stored_smooth_east"] and east in cells:
                smooth_edges.add(hf_edge_key(cell_pos, east))

            north = (ix, iy + 1)
            if cell["stored_smooth_north"] and north in cells:
                smooth_edges.add(hf_edge_key(cell_pos, north))
    else:
        # Backward-compatible fallback for v1.0/v1.1 meshes. Infer only
        # visibly sloped connected seams, not ordinary flat neighbors.
        def edge_pair(cell_pos, direction):
            names = hf_cell_edge_names(direction)
            c = cells[cell_pos]["base_corner_z"]
            return (c[names[0]], c[names[1]])

        def cell_is_sloped(cell_pos):
            values = list(cells[cell_pos]["base_corner_z"].values())
            return max(values) - min(values) > 1.0e-5

        for ix, iy in cells:
            current = (ix, iy)

            east = (ix + 1, iy)
            if east in cells:
                a = edge_pair(current, 'E')
                b = edge_pair(east, 'W')
                connected = (
                    abs(a[0] - b[0]) <= 1.0e-5
                    and abs(a[1] - b[1]) <= 1.0e-5
                )
                if connected and (cell_is_sloped(current) or cell_is_sloped(east)):
                    smooth_edges.add(hf_edge_key(current, east))

            north = (ix, iy + 1)
            if north in cells:
                a = edge_pair(current, 'N')
                b = edge_pair(north, 'S')
                connected = (
                    abs(a[0] - b[0]) <= 1.0e-5
                    and abs(a[1] - b[1]) <= 1.0e-5
                )
                if connected and (cell_is_sloped(current) or cell_is_sloped(north)):
                    smooth_edges.add(hf_edge_key(current, north))

    boundary_base_z = min(boundary_wall_z) if boundary_wall_z else None

    return {
        "cells": cells,
        "smooth_edges": smooth_edges,
        "boundary_base_z": boundary_base_z,
        "had_boundary_skirt": bool(
            obj.get("hf_boundary_skirt", boundary_wall_count > 0)
        ),
        "had_step_walls": bool(
            obj.get("hf_create_step_walls", step_wall_count > 0)
        ),
        "step_wall_count": step_wall_count,
        "boundary_wall_count": boundary_wall_count,
    }


def hf_recompute_corner_heights(model, smooth_edges):
    """
    Calculate each cell's four corner heights from its editable base corners
    plus the set of edges that are supposed to be connected.

    At a lattice point, cells linked by painted/procedural smooth edges form a
    local component and share the average of their base corner heights. Cells
    separated by hard edges retain separate heights at that same XY point.
    """
    cells = model["cells"]

    lattice = {}
    for cell_pos in cells:
        for corner_name, lattice_pos in hf_corner_nodes_for_cell(cell_pos).items():
            lattice.setdefault(lattice_pos, []).append((cell_pos, corner_name))

    result = {}

    for lattice_pos, nodes in lattice.items():
        node_set = set(nodes)
        adjacency = {node: set() for node in nodes}

        for node in nodes:
            cell_pos, corner_name = node
            ix, iy = cell_pos

            for neighbor_pos in (
                (ix - 1, iy),
                (ix + 1, iy),
                (ix, iy - 1),
                (ix, iy + 1),
            ):
                if neighbor_pos not in cells:
                    continue
                if hf_edge_key(cell_pos, neighbor_pos) not in smooth_edges:
                    continue

                for ncorner, nlattice in hf_corner_nodes_for_cell(neighbor_pos).items():
                    nnode = (neighbor_pos, ncorner)
                    if nlattice == lattice_pos and nnode in node_set:
                        adjacency[node].add(nnode)

        visited = set()

        for seed in nodes:
            if seed in visited:
                continue

            stack = [seed]
            visited.add(seed)
            component = []

            while stack:
                current = stack.pop()
                component.append(current)

                for neighbor in adjacency[current]:
                    if neighbor not in visited:
                        visited.add(neighbor)
                        stack.append(neighbor)

            z = sum(
                cells[cell_pos]["base_corner_z"][corner_name]
                for cell_pos, corner_name in component
            ) / len(component)

            for cell_pos, corner_name in component:
                result[(cell_pos, corner_name)] = z

    return result


def hf_edge_pair_from_heights(corner_heights, cell_pos, direction):
    names = hf_cell_edge_names(direction)
    return (
        corner_heights[(cell_pos, names[0])],
        corner_heights[(cell_pos, names[1])],
    )


def hf_all_adjacent_edges(model):
    cells = model["cells"]
    edges = set()

    for ix, iy in cells:
        current = (ix, iy)
        east = (ix + 1, iy)
        north = (ix, iy + 1)

        if east in cells:
            edges.add(hf_edge_key(current, east))
        if north in cells:
            edges.add(hf_edge_key(current, north))

    return edges


def hf_hard_edges(model, smooth_edges):
    """
    Return currently visible discontinuity edges. Flat seams are deliberately
    excluded so brushing near a level floor does not secretly mark it as a
    future ramp.
    """
    cells = model["cells"]
    corner_heights = hf_recompute_corner_heights(model, smooth_edges)
    result = set()

    for edge in hf_all_adjacent_edges(model):
        if edge in smooth_edges:
            continue

        a, b = edge
        ax, ay = a
        bx, by = b

        if bx > ax:
            pair_a = hf_edge_pair_from_heights(corner_heights, a, 'E')
            pair_b = hf_edge_pair_from_heights(corner_heights, b, 'W')
        else:
            lower = a if ay < by else b
            upper = b if ay < by else a
            pair_a = hf_edge_pair_from_heights(corner_heights, lower, 'N')
            pair_b = hf_edge_pair_from_heights(corner_heights, upper, 'S')

        if (
            abs(pair_a[0] - pair_b[0]) > 1.0e-5
            or abs(pair_a[1] - pair_b[1]) > 1.0e-5
        ):
            result.add(edge)

    return result


def hf_edge_segment_xy(model, edge):
    """
    Return the XY line segment of a shared grid edge.
    """
    cells = model["cells"]
    a, b = edge
    ax, ay = a
    bx, by = b

    if ax != bx:
        left = a if ax < bx else b
        cell = cells[left]
        return (
            cell["corner_xy"]["SE"],
            cell["corner_xy"]["NE"],
        )

    bottom = a if ay < by else b
    cell = cells[bottom]
    return (
        cell["corner_xy"]["NW"],
        cell["corner_xy"]["NE"],
    )


def hf_distance_point_segment_2d(px, py, ax, ay, bx, by):
    vx = bx - ax
    vy = by - ay
    wx = px - ax
    wy = py - ay

    length_sq = vx * vx + vy * vy
    if length_sq <= EPS:
        return math.hypot(px - ax, py - ay)

    t = (wx * vx + wy * vy) / length_sq
    t = max(0.0, min(1.0, t))

    cx = ax + t * vx
    cy = ay + t * vy
    return math.hypot(px - cx, py - cy)


def hf_write_mesh_attributes(mesh, metadata):
    if len(mesh.polygons) != len(metadata):
        return

    attr_x = mesh.attributes.new("hf_grid_x", type='INT', domain='FACE')
    attr_y = mesh.attributes.new("hf_grid_y", type='INT', domain='FACE')
    attr_height = mesh.attributes.new("hf_height_m", type='FLOAT', domain='FACE')
    attr_kind = mesh.attributes.new("hf_face_kind", type='INT', domain='FACE')
    attr_band = mesh.attributes.new("hf_band_index", type='INT', domain='FACE')
    attr_smooth_e = mesh.attributes.new("hf_smooth_east", type='BOOLEAN', domain='FACE')
    attr_smooth_n = mesh.attributes.new("hf_smooth_north", type='BOOLEAN', domain='FACE')

    for i, meta in enumerate(metadata):
        attr_x.data[i].value = int(meta["grid_x"])
        attr_y.data[i].value = int(meta["grid_y"])
        attr_height.data[i].value = float(meta["height_m"])
        attr_kind.data[i].value = int(meta["kind"])
        attr_band.data[i].value = int(meta["band_index"])
        attr_smooth_e.data[i].value = bool(meta.get("smooth_east", False))
        attr_smooth_n.data[i].value = bool(meta.get("smooth_north", False))


def hf_rebuild_edit_mesh(context, obj, model, smooth_edges):
    """
    Deterministically rebuild the editable heightfield.

    Rebuilding is slower than directly moving arbitrary vertices, but it keeps
    the heightfield structurally clean: top quads, intended smooth seams, hard
    step walls, and optional boundary skirts are regenerated from one model.
    """
    scene = context.scene
    settings = scene.hf_settings
    cells = model["cells"]
    corner_heights = hf_recompute_corner_heights(model, smooth_edges)

    vertices = []
    faces = []
    metadata = []
    material_indices = []

    def append_face(
        coords,
        cell_pos,
        height_m,
        kind,
        band_index,
        material_index,
        smooth_east=False,
        smooth_north=False,
    ):
        start = len(vertices)
        vertices.extend(coords)
        faces.append((start, start + 1, start + 2, start + 3))
        metadata.append(
            {
                "grid_x": cell_pos[0],
                "grid_y": cell_pos[1],
                "height_m": height_m,
                "kind": kind,
                "band_index": band_index,
                "smooth_east": smooth_east,
                "smooth_north": smooth_north,
            }
        )
        material_indices.append(material_index)

    def corner_xyz(cell_pos, corner_name):
        x, y = cells[cell_pos]["corner_xy"][corner_name]
        z = corner_heights[(cell_pos, corner_name)]
        return (x, y, z)

    # Top faces.
    for cell_pos, cell in cells.items():
        ix, iy = cell_pos
        east = (ix + 1, iy)
        north = (ix, iy + 1)

        append_face(
            [
                corner_xyz(cell_pos, "SW"),
                corner_xyz(cell_pos, "SE"),
                corner_xyz(cell_pos, "NE"),
                corner_xyz(cell_pos, "NW"),
            ],
            cell_pos,
            cell["height_m"],
            0,
            0,
            cell["material_index"],
            smooth_east=(
                east in cells
                and hf_edge_key(cell_pos, east) in smooth_edges
            ),
            smooth_north=(
                north in cells
                and hf_edge_key(cell_pos, north) in smooth_edges
            ),
        )

    respect_units = bool(
        obj.get("hf_respect_scene_units", settings.respect_scene_units)
    )
    band_step_walls = bool(
        obj.get("hf_band_step_walls", settings.band_step_walls)
    )
    height_step_m = float(
        obj.get("hf_height_step_m", settings.height_step_m)
    )
    height_step_bu = (
        meters_to_bu(scene, height_step_m, respect_units)
        if height_step_m > 0.0 else 0.0
    )

    def edge_xy(cell_pos, direction):
        names = hf_cell_edge_names(direction)
        return (
            cells[cell_pos]["corner_xy"][names[0]],
            cells[cell_pos]["corner_xy"][names[1]],
        )

    def append_wall_quad(
        owner_cell,
        direction,
        xy_pair,
        high_pair,
        low_pair,
        kind,
        band_index,
        material_index,
    ):
        (ax, ay), (bx, by) = xy_pair
        high_a, high_b = high_pair
        low_a, low_b = low_pair

        if direction == 'S':
            coords = [
                (bx, by, high_b),
                (ax, ay, high_a),
                (ax, ay, low_a),
                (bx, by, low_b),
            ]
        elif direction == 'N':
            coords = [
                (ax, ay, high_a),
                (bx, by, high_b),
                (bx, by, low_b),
                (ax, ay, low_a),
            ]
        elif direction == 'W':
            coords = [
                (ax, ay, high_a),
                (bx, by, high_b),
                (bx, by, low_b),
                (ax, ay, low_a),
            ]
        else:  # E
            coords = [
                (bx, by, high_b),
                (ax, ay, high_a),
                (ax, ay, low_a),
                (bx, by, low_b),
            ]

        append_face(
            coords,
            owner_cell,
            bu_to_meters(
                scene,
                (high_a + high_b) * 0.5,
                respect_units,
            ),
            kind,
            band_index,
            material_index,
        )

    def add_wall(
        owner_cell,
        direction,
        xy_pair,
        side_a,
        side_b,
        kind,
        material_index,
    ):
        # Use endpoint-wise envelope. This remains valid when a slope meets a
        # hard wall at a corner and the two edge profiles are not horizontal.
        top = (
            max(side_a[0], side_b[0]),
            max(side_a[1], side_b[1]),
        )
        bottom = (
            min(side_a[0], side_b[0]),
            min(side_a[1], side_b[1]),
        )

        if (
            top[0] - bottom[0] <= 1.0e-6
            and top[1] - bottom[1] <= 1.0e-6
        ):
            return

        flat_top = abs(top[0] - top[1]) <= 1.0e-6
        flat_bottom = abs(bottom[0] - bottom[1]) <= 1.0e-6

        if (
            band_step_walls
            and height_step_bu > EPS
            and flat_top
            and flat_bottom
        ):
            z_top = top[0]
            z_bottom = bottom[0]
            band_index = 0

            while z_top - z_bottom > 1.0e-6:
                next_bottom = max(z_bottom, z_top - height_step_bu)
                append_wall_quad(
                    owner_cell,
                    direction,
                    xy_pair,
                    (z_top, z_top),
                    (next_bottom, next_bottom),
                    kind,
                    band_index,
                    material_index,
                )
                z_top = next_bottom
                band_index += 1
        else:
            append_wall_quad(
                owner_cell,
                direction,
                xy_pair,
                top,
                bottom,
                kind,
                0,
                material_index,
            )

    # Internal hard walls.
    if model["had_step_walls"]:
        for ix, iy in cells:
            current = (ix, iy)

            east = (ix + 1, iy)
            if (
                east in cells
                and hf_edge_key(current, east) not in smooth_edges
            ):
                side_current = hf_edge_pair_from_heights(
                    corner_heights, current, 'E'
                )
                side_east = hf_edge_pair_from_heights(
                    corner_heights, east, 'W'
                )

                if (
                    abs(side_current[0] - side_east[0]) > 1.0e-6
                    or abs(side_current[1] - side_east[1]) > 1.0e-6
                ):
                    avg_current = sum(side_current) * 0.5
                    avg_east = sum(side_east) * 0.5

                    if avg_east > avg_current:
                        owner = east
                        direction = 'W'
                    else:
                        owner = current
                        direction = 'E'

                    add_wall(
                        owner,
                        direction,
                        edge_xy(current, 'E'),
                        side_current,
                        side_east,
                        1,
                        cells[owner]["material_index"],
                    )

            north = (ix, iy + 1)
            if (
                north in cells
                and hf_edge_key(current, north) not in smooth_edges
            ):
                side_current = hf_edge_pair_from_heights(
                    corner_heights, current, 'N'
                )
                side_north = hf_edge_pair_from_heights(
                    corner_heights, north, 'S'
                )

                if (
                    abs(side_current[0] - side_north[0]) > 1.0e-6
                    or abs(side_current[1] - side_north[1]) > 1.0e-6
                ):
                    avg_current = sum(side_current) * 0.5
                    avg_north = sum(side_north) * 0.5

                    if avg_north > avg_current:
                        owner = north
                        direction = 'S'
                    else:
                        owner = current
                        direction = 'N'

                    add_wall(
                        owner,
                        direction,
                        edge_xy(current, 'N'),
                        side_current,
                        side_north,
                        1,
                        cells[owner]["material_index"],
                    )

    # Boundary skirt.
    if (
        model["had_boundary_skirt"]
        and model["boundary_base_z"] is not None
    ):
        base_z = model["boundary_base_z"]

        for ix, iy in cells:
            current = (ix, iy)

            for direction in ('S', 'N', 'W', 'E'):
                neighbor = hf_edge_neighbor(current, direction)
                if neighbor in cells:
                    continue

                top_pair = hf_edge_pair_from_heights(
                    corner_heights,
                    current,
                    direction,
                )

                if max(top_pair) <= base_z + 1.0e-6:
                    continue

                add_wall(
                    current,
                    direction,
                    edge_xy(current, direction),
                    top_pair,
                    (base_z, base_z),
                    2,
                    cells[current]["material_index"],
                )

    old_mesh = obj.data
    old_name = old_mesh.name
    materials = list(old_mesh.materials)

    new_mesh = bpy.data.meshes.new(old_name + "_ManualEdit")
    for material in materials:
        new_mesh.materials.append(material)

    new_mesh.from_pydata(vertices, [], faces)
    new_mesh.update()
    hf_write_mesh_attributes(new_mesh, metadata)

    if len(new_mesh.polygons) == len(material_indices):
        for i, material_index in enumerate(material_indices):
            if materials:
                new_mesh.polygons[i].material_index = max(
                    0,
                    min(int(material_index), len(materials) - 1),
                )

    obj.data = new_mesh
    context.view_layer.update()

    if old_mesh.users == 0:
        bpy.data.meshes.remove(old_mesh)

    new_mesh.name = old_name
    return len(faces)


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


class OBJECT_OT_heightfield_slope_brush(Operator):
    bl_idname = "object.heightfield_slope_brush"
    bl_label = "Slope Brush"
    bl_description = (
        "Paint hard stepped transitions into connected sloped quads. "
        "Left-drag paints; Enter or right-click commits; Esc cancels"
    )
    bl_options = {'REGISTER', 'UNDO', 'BLOCKING'}

    @classmethod
    def poll(cls, context):
        obj = context.active_object
        return (
            context.area is not None
            and context.area.type == 'VIEW_3D'
            and obj is not None
            and obj.type == 'MESH'
            and obj.mode == 'OBJECT'
            and hf_has_edit_attributes(obj)
        )

    def invoke(self, context, event):
        self._obj = context.active_object

        try:
            self._model = hf_extract_edit_model(self._obj)
        except Exception as exc:
            self.report({'ERROR'}, f"Could not start Slope Brush: {exc}")
            return {'CANCELLED'}

        self._backup_mesh = self._obj.data.copy()
        self._base_smooth_edges = set(self._model["smooth_edges"])
        self._painted_edges = set()
        self._candidate_edges = hf_hard_edges(
            self._model,
            self._base_smooth_edges,
        )
        self._painting = False
        self._last_hit = None
        self._draw_handle = None

        try:
            context.window.cursor_modal_set('CROSSHAIR')
        except Exception:
            pass

        if context.scene.hf_settings.manual_brush_show_outline:
            try:
                self._draw_handle = bpy.types.SpaceView3D.draw_handler_add(
                    self._draw_callback,
                    (context,),
                    'WINDOW',
                    'POST_PIXEL',
                )
            except Exception:
                self._draw_handle = None

        context.window_manager.modal_handler_add(self)
        context.workspace.status_text_set(
            "Slope Brush: LMB drag paints slopes | Ctrl+Wheel or [ ] changes "
            "radius | MMB navigates | Enter/RMB commits | Esc cancels"
        )

        self._update_hit(context, event)
        context.area.tag_redraw()
        return {'RUNNING_MODAL'}

    def modal(self, context, event):
        if self._obj is None or self._obj.name not in bpy.data.objects:
            return self._finish(context, True)

        if event.type == 'ESC':
            return self._finish(context, True)

        if (
            event.type in {'RET', 'NUMPAD_ENTER', 'SPACE', 'RIGHTMOUSE'}
            and event.value == 'PRESS'
        ):
            return self._finish(context, False)

        if event.type == 'MIDDLEMOUSE':
            return {'PASS_THROUGH'}

        if event.type in {'WHEELUPMOUSE', 'WHEELDOWNMOUSE'}:
            if event.ctrl:
                factor = (
                    1.15
                    if event.type == 'WHEELUPMOUSE'
                    else 1.0 / 1.15
                )
                settings = context.scene.hf_settings
                settings.slope_brush_radius_m = max(
                    0.05,
                    min(100.0, settings.slope_brush_radius_m * factor),
                )
                context.area.tag_redraw()
                return {'RUNNING_MODAL'}
            return {'PASS_THROUGH'}

        if (
            event.type in {'LEFT_BRACKET', 'RIGHT_BRACKET'}
            and event.value == 'PRESS'
        ):
            factor = (
                1.15
                if event.type == 'RIGHT_BRACKET'
                else 1.0 / 1.15
            )
            settings = context.scene.hf_settings
            settings.slope_brush_radius_m = max(
                0.05,
                min(100.0, settings.slope_brush_radius_m * factor),
            )
            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        if event.type == 'LEFTMOUSE':
            if event.value == 'PRESS':
                self._painting = True
                self._update_hit(context, event)
                self._paint(context)
                context.area.tag_redraw()
                return {'RUNNING_MODAL'}

            if event.value == 'RELEASE':
                self._painting = False
                return {'RUNNING_MODAL'}

        if event.type == 'MOUSEMOVE':
            self._update_hit(context, event)

            if self._painting:
                self._paint(context)

            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        return {'RUNNING_MODAL'}

    def _update_hit(self, context, event):
        self._last_hit, face_index = hf_view_ray_hit(
            context,
            self._obj,
            event.mouse_region_x,
            event.mouse_region_y,
        )

    def _paint(self, context):
        if self._last_hit is None:
            return

        radius = hf_local_radius_from_meters(
            context,
            self._obj,
            context.scene.hf_settings.slope_brush_radius_m,
        )
        current_smooth = (
            self._base_smooth_edges
            | self._painted_edges
        )

        additions = set()

        for edge in self._candidate_edges:
            if edge in current_smooth:
                continue

            (ax, ay), (bx, by) = hf_edge_segment_xy(
                self._model,
                edge,
            )

            distance = hf_distance_point_segment_2d(
                self._last_hit.x,
                self._last_hit.y,
                ax,
                ay,
                bx,
                by,
            )

            if distance <= radius:
                additions.add(edge)

        if not additions:
            return

        self._painted_edges.update(additions)

        hf_rebuild_edit_mesh(
            context,
            self._obj,
            self._model,
            self._base_smooth_edges | self._painted_edges,
        )

    def _draw_callback(self, context):
        if self._last_hit is None or self._obj is None:
            return

        radius = hf_local_radius_from_meters(
            context,
            self._obj,
            context.scene.hf_settings.slope_brush_radius_m,
        )
        hf_draw_screen_circle(
            context,
            self._obj,
            self._last_hit,
            radius,
            (1.0, 0.55, 0.12, 0.95),
        )

    def _finish(self, context, cancelled):
        try:
            if self._draw_handle is not None:
                bpy.types.SpaceView3D.draw_handler_remove(
                    self._draw_handle,
                    'WINDOW',
                )
        except Exception:
            pass

        try:
            context.window.cursor_modal_restore()
        except Exception:
            pass

        try:
            context.workspace.status_text_set(None)
        except Exception:
            pass

        if cancelled:
            current_mesh = self._obj.data
            self._obj.data = self._backup_mesh
            context.view_layer.update()

            if current_mesh.users == 0:
                bpy.data.meshes.remove(current_mesh)

            self.report(
                {'INFO'},
                "Slope Brush cancelled; starting mesh restored.",
            )
            if context.area:
                context.area.tag_redraw()
            return {'CANCELLED'}

        if self._backup_mesh.users == 0:
            bpy.data.meshes.remove(self._backup_mesh)

        self._obj["hf_manual_slope_brush"] = True
        self._obj["hf_manual_smooth_edge_count"] = len(
            self._painted_edges
        )

        self.report(
            {'INFO'},
            f"Slope Brush committed {len(self._painted_edges):,} "
            "hard-edge conversion(s).",
        )

        if context.area:
            context.area.tag_redraw()
        return {'FINISHED'}


class OBJECT_OT_heightfield_height_brush(Operator):
    bl_idname = "object.heightfield_height_brush"
    bl_label = "Raise / Lower Brush"
    bl_description = (
        "Raise or lower whole heightfield cells. LMB uses the selected action; "
        "hold Ctrl to temporarily invert it"
    )
    bl_options = {'REGISTER', 'UNDO', 'BLOCKING'}

    @classmethod
    def poll(cls, context):
        obj = context.active_object
        return (
            context.area is not None
            and context.area.type == 'VIEW_3D'
            and obj is not None
            and obj.type == 'MESH'
            and obj.mode == 'OBJECT'
            and hf_has_edit_attributes(obj)
        )

    def invoke(self, context, event):
        self._obj = context.active_object

        try:
            self._model = hf_extract_edit_model(self._obj)
        except Exception as exc:
            self.report({'ERROR'}, f"Could not start Height Brush: {exc}")
            return {'CANCELLED'}

        self._backup_mesh = self._obj.data.copy()
        self._smooth_edges = set(self._model["smooth_edges"])
        self._painting = False
        self._stroke_cells = set()
        self._last_hit = None
        self._hover_cell = None
        self._draw_handle = None

        try:
            context.window.cursor_modal_set('CROSSHAIR')
        except Exception:
            pass

        if context.scene.hf_settings.manual_brush_show_outline:
            try:
                self._draw_handle = bpy.types.SpaceView3D.draw_handler_add(
                    self._draw_callback,
                    (context,),
                    'WINDOW',
                    'POST_PIXEL',
                )
            except Exception:
                self._draw_handle = None

        context.window_manager.modal_handler_add(self)
        context.workspace.status_text_set(
            "Height Brush: LMB = selected Raise/Lower action | Ctrl+LMB = "
            "opposite | [ ] changes cell radius | MMB navigates | "
            "Enter/RMB commits | Esc cancels"
        )

        self._update_hit(context, event)
        context.area.tag_redraw()
        return {'RUNNING_MODAL'}

    def modal(self, context, event):
        if self._obj is None or self._obj.name not in bpy.data.objects:
            return self._finish(context, True)

        if event.type == 'ESC':
            return self._finish(context, True)

        if (
            event.type in {'RET', 'NUMPAD_ENTER', 'SPACE', 'RIGHTMOUSE'}
            and event.value == 'PRESS'
        ):
            return self._finish(context, False)

        if event.type == 'MIDDLEMOUSE':
            return {'PASS_THROUGH'}

        if event.type in {'WHEELUPMOUSE', 'WHEELDOWNMOUSE'}:
            return {'PASS_THROUGH'}

        if (
            event.type in {'LEFT_BRACKET', 'RIGHT_BRACKET'}
            and event.value == 'PRESS'
        ):
            settings = context.scene.hf_settings
            if event.type == 'RIGHT_BRACKET':
                settings.height_brush_radius_cells = min(
                    32,
                    settings.height_brush_radius_cells + 1,
                )
            else:
                settings.height_brush_radius_cells = max(
                    0,
                    settings.height_brush_radius_cells - 1,
                )
            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        if event.type == 'LEFTMOUSE':
            if event.value == 'PRESS':
                self._painting = True
                self._stroke_cells.clear()
                self._update_hit(context, event)
                self._paint(context, invert=event.ctrl)
                context.area.tag_redraw()
                return {'RUNNING_MODAL'}

            if event.value == 'RELEASE':
                self._painting = False
                self._stroke_cells.clear()
                return {'RUNNING_MODAL'}

        if event.type == 'MOUSEMOVE':
            self._update_hit(context, event)

            if self._painting:
                self._paint(context, invert=event.ctrl)

            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        return {'RUNNING_MODAL'}

    def _update_hit(self, context, event):
        self._last_hit, face_index = hf_view_ray_hit(
            context,
            self._obj,
            event.mouse_region_x,
            event.mouse_region_y,
        )
        self._hover_cell = hf_face_cell(self._obj, face_index)

        if (
            self._hover_cell is not None
            and self._hover_cell not in self._model["cells"]
        ):
            self._hover_cell = None

    def _paint(self, context, invert=False):
        if self._hover_cell is None:
            return

        settings = context.scene.hf_settings
        radius = settings.height_brush_radius_cells
        cx, cy = self._hover_cell

        targets = set()
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                pos = (cx + dx, cy + dy)
                if pos in self._model["cells"]:
                    targets.add(pos)

        targets.difference_update(self._stroke_cells)
        if not targets:
            return

        action = settings.height_brush_action
        if invert:
            action = 'LOWER' if action == 'RAISE' else 'RAISE'

        sign = 1.0 if action == 'RAISE' else -1.0

        respect_units = bool(
            self._obj.get(
                "hf_respect_scene_units",
                settings.respect_scene_units,
            )
        )
        delta_bu = meters_to_bu(
            context.scene,
            settings.height_brush_increment_m * sign,
            respect_units,
        )
        delta_m = settings.height_brush_increment_m * sign

        for cell_pos in targets:
            cell = self._model["cells"][cell_pos]

            for corner_name in HF_CORNER_NAMES:
                cell["base_corner_z"][corner_name] += delta_bu

            cell["height_m"] += delta_m

        self._stroke_cells.update(targets)

        hf_rebuild_edit_mesh(
            context,
            self._obj,
            self._model,
            self._smooth_edges,
        )

    def _draw_callback(self, context):
        if self._last_hit is None or self._obj is None:
            return

        settings = context.scene.hf_settings
        grid_m = float(
            self._obj.get("hf_grid_size_m", settings.grid_size_m)
        )
        radius_m = (
            settings.height_brush_radius_cells + 0.55
        ) * grid_m

        radius_local = hf_local_radius_from_meters(
            context,
            self._obj,
            radius_m,
        )

        color = (
            (0.2, 0.9, 0.35, 0.95)
            if settings.height_brush_action == 'RAISE'
            else (0.25, 0.55, 1.0, 0.95)
        )

        hf_draw_screen_circle(
            context,
            self._obj,
            self._last_hit,
            radius_local,
            color,
        )

    def _finish(self, context, cancelled):
        try:
            if self._draw_handle is not None:
                bpy.types.SpaceView3D.draw_handler_remove(
                    self._draw_handle,
                    'WINDOW',
                )
        except Exception:
            pass

        try:
            context.window.cursor_modal_restore()
        except Exception:
            pass

        try:
            context.workspace.status_text_set(None)
        except Exception:
            pass

        if cancelled:
            current_mesh = self._obj.data
            self._obj.data = self._backup_mesh
            context.view_layer.update()

            if current_mesh.users == 0:
                bpy.data.meshes.remove(current_mesh)

            self.report(
                {'INFO'},
                "Height Brush cancelled; starting mesh restored.",
            )
            if context.area:
                context.area.tag_redraw()
            return {'CANCELLED'}

        if self._backup_mesh.users == 0:
            bpy.data.meshes.remove(self._backup_mesh)

        self._obj["hf_manual_height_brush"] = True

        self.report(
            {'INFO'},
            "Height Brush edits committed.",
        )

        if context.area:
            context.area.tag_redraw()
        return {'FINISHED'}



class VIEW3D_PT_grid_heightfield(Panel):
    bl_label = "Grid Heightfield"
    bl_idname = "VIEW3D_PT_grid_heightfield"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Heightfield"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.hf_settings
        obj = context.active_object

        if obj is None or obj.type != 'MESH':
            box = layout.box()
            box.label(text="Select a mesh object.", icon='INFO')
        else:
            box = layout.box()
            box.label(text=f"Source: {obj.name}", icon='MESH_DATA')
            box.label(text="Sampling axis: World -Z")

        layout.prop(settings, "output_mode")
        layout.prop(settings, "grid_size_m")

        snap_box = layout.box()
        snap_box.prop(settings, "snap_height")
        if settings.snap_height:
            snap_box.prop(settings, "height_step_m")
            snap_box.prop(settings, "height_snap_mode")

        if settings.output_mode == 'STEPPED':
            wall_box = layout.box()
            wall_box.label(text="Stepped Geometry")
            wall_box.prop(settings, "create_step_walls")
            if settings.create_step_walls and settings.snap_height:
                wall_box.prop(settings, "band_step_walls")

            smooth_box = layout.box()
            smooth_box.label(text="Connected Second Pass")
            smooth_box.prop(settings, "smooth_low_transitions")
            if settings.smooth_low_transitions:
                smooth_box.prop(settings, "smooth_threshold_m")
                smooth_box.prop(settings, "smooth_threshold_basis")
                if settings.snap_height and settings.smooth_threshold_basis == 'SOURCE':
                    smooth_box.label(
                        text="Original Samples can smooth below the snap step.",
                        icon='INFO',
                    )

            wall_box.prop(settings, "boundary_skirt")
            if settings.boundary_skirt:
                wall_box.prop(settings, "boundary_base_mode")
                if settings.boundary_base_mode == 'CUSTOM':
                    wall_box.prop(settings, "boundary_base_m")

        align_box = layout.box()
        align_box.label(text="Grid Alignment")
        align_box.prop(settings, "grid_origin_x_m")
        align_box.prop(settings, "grid_origin_y_m")
        if settings.snap_height:
            align_box.prop(settings, "height_origin_m")

        options = layout.box()
        options.label(text="Options")
        options.prop(settings, "include_modifiers")
        options.prop(settings, "respect_scene_units")
        options.prop(settings, "hide_source")
        options.prop(settings, "max_cells")

        scale = context.scene.unit_settings.scale_length
        options.label(text=f"Scene Unit Scale: {scale:g}")

        layout.separator()
        layout.operator(
            OBJECT_OT_convert_grid_heightfield.bl_idname,
            icon='MOD_REMESH',
        )

        manual = layout.box()
        manual.label(text="Manual Touch-up")
        manual.prop(settings, "manual_brush_show_outline")

        slope = manual.box()
        slope.label(text="Slope Brush")
        slope.prop(settings, "slope_brush_radius_m")
        slope_col = slope.column()
        slope_col.enabled = hf_has_edit_attributes(obj)
        slope_col.operator(
            OBJECT_OT_heightfield_slope_brush.bl_idname,
            icon='BRUSH_DATA',
        )
        slope.label(text="Paint stair edges into connected slopes.")

        height = manual.box()
        height.label(text="Raise / Lower Brush")
        height.prop(settings, "height_brush_action", expand=True)
        height.prop(settings, "height_brush_increment_m")
        height.prop(settings, "height_brush_radius_cells")
        height_col = height.column()
        height_col.enabled = hf_has_edit_attributes(obj)
        height_col.operator(
            OBJECT_OT_heightfield_height_brush.bl_idname,
            icon='SCULPTMODE_HLT',
        )
        height.label(text="LMB uses action; Ctrl+LMB inverts it.")

        if not hf_has_edit_attributes(obj):
            manual.label(
                text="Select a generated heightfield to enable brushes.",
                icon='INFO',
            )


classes = (
    HF_Settings,
    OBJECT_OT_convert_grid_heightfield,
    OBJECT_OT_heightfield_slope_brush,
    OBJECT_OT_heightfield_height_brush,
    VIEW3D_PT_grid_heightfield,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.hf_settings = PointerProperty(type=HF_Settings)


def unregister():
    if hasattr(bpy.types.Scene, "hf_settings"):
        del bpy.types.Scene.hf_settings
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
