"""Extract, update and rebuild the editable heightfield topology."""
from .units import EPS
import bpy
from .units import bu_to_meters
import math
from .units import meters_to_bu

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
