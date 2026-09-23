"""Convert source geometry into an editable grid heightfield."""
from .units import EPS
from bpy.types import Operator
from .units import aligned_ceil
from .units import aligned_floor
from .units import bu_to_meters
from .sampling import build_world_bvh
from .mesh_builder import create_mesh_object
from .units import meters_to_bu
from .units import quantize_height
from .sampling import ray_sample

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
