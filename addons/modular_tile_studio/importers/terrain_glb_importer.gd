@tool
class_name TerrainGLBImporter
extends RefCounted

## Decodes an already-authored heightfield GLB into the canonical TerrainMesh.
##
## This is a DECODER, not a reconstructor. The Blender heightfield exporter emits
## exactly the topology TerrainMesh stores:
##
##     one quad per 1 m cell        -> that cell's four top-face corner heights
##     one cell-edge wall           -> exact low/high values at both endpoints
##     boundary quads to a base Y   -> the closing skirt
##
## The two are the same structure in two serializations, so nothing here
## interpolates, resamples, averages, welds, or picks a "highest point at this
## XZ". Every one of those was a place the importer could invent data the author
## never wrote. Where the file does not match the contract this fails and says
## exactly what was wrong, rather than repairing it silently.
##
## The contract itself is carried by the file: the exporter writes hf_* node
## extras naming the grid size, the top-cell count and whether a skirt was built.
## Those are read straight out of the glTF JSON so the check does not depend on
## how a particular Godot version surfaces node metadata.

const K := preload("../utils/mts_constants.gd")
const GLBImporter := preload("glb_asset_importer.gd")

## Lattice tolerance in metres for deciding that a vertex sits on a grid corner.
##
## The exporter emits exact integers; this only absorbs float32 round-tripping
## through the glTF buffer.
const LATTICE_TOLERANCE_M: float = 0.02

## A triangle at least this vertical contributes to the walkable top surface.
## Authored slopes stay well inside it.
const WALKABLE_MIN_NORMAL_Y: float = 0.2

## A triangle at most this far from vertical is a wall or skirt face.
const VERTICAL_MAX_NORMAL_Y: float = 0.05

## The grid pitch this editor is built on. A file authored at any other pitch
## describes a different lattice and is refused rather than rescaled.
const REQUIRED_GRID_SIZE_M: float = 1.0

var _glb_importer := GLBImporter.new()


## Return one triangle's outward normal under Godot's winding, or ZERO if degenerate.
##
## Godot reverses glTF triangle winding on import (glTF is counter-clockwise
## front-facing, Godot is clockwise), so the cross product is taken in the order
## that makes an upward-facing floor report +Y. Getting this backwards makes every
## walkable face look like a ceiling and the whole import is rejected as having no
## surface.
static func _triangle_normal(
	point_a: Vector3,
	point_b: Vector3,
	point_c: Vector3
) -> Vector3:
	var normal := (point_c - point_a).cross(point_b - point_a)
	if normal.length_squared() <= 0.0:
		return Vector3.ZERO
	return normal.normalized()


## Read one authored heightfield GLB into canonical terrain.
##
## The live board is untouched; the caller commits the result.
func read(source_path: String) -> Dictionary:
	var extras := read_heightfield_extras(source_path)
	var contract_error := _contract_error(source_path, extras)
	if not contract_error.is_empty():
		return _failure(contract_error)

	var model := _glb_importer.load_model(source_path)
	if model == null:
		return _failure("Godot could not load '%s' as a GLB scene." % source_path)
	var surfaces: Array[Dictionary] = []
	_collect_surfaces(model, Transform3D.IDENTITY, surfaces)
	# The decoded scene was never added to a tree, so release it immediately.
	model.free()
	if surfaces.is_empty():
		return _failure("'%s' contains no mesh geometry." % source_path)

	var lattice_error := _lattice_error(source_path, surfaces)
	if not lattice_error.is_empty():
		return _failure(lattice_error)

	var classified := _classify_triangles(surfaces)
	var cell_quads: Dictionary = classified["cell_quads"]
	var cell_diagonals: Dictionary = classified["cell_diagonals"]
	var edge_profiles: Dictionary = classified["edge_profiles"]
	var source_face_count := int(classified["source_face_count"])
	if cell_quads.is_empty():
		return _failure(
			"'%s' has no upward-facing cell on the 1 m lattice, so it is not a heightfield."
			% source_path
		)
	return _decode(
		source_path,
		extras,
		cell_quads,
		cell_diagonals,
		edge_profiles,
		source_face_count
	)


## Read the exporter's hf_* contract straight out of the glTF JSON.
##
## Parsing the container directly rather than relying on Godot surfacing node
## extras as metadata keeps the check identical across engine versions, and it
## costs one file read of a chunk that is already on disk.
func read_heightfield_extras(source_path: String) -> Dictionary:
	var global_path := ProjectSettings.globalize_path(source_path)
	if not FileAccess.file_exists(global_path):
		global_path = source_path
	var file := FileAccess.open(global_path, FileAccess.READ)
	if file == null:
		return {}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if bytes.size() < 12:
		return {}

	var json_text := ""
	if bytes.decode_u32(0) == 0x46546C67:
		# Binary glTF: walk the chunk table for the single JSON chunk.
		var offset := 12
		var total := int(bytes.decode_u32(8))
		while offset + 8 <= mini(total, bytes.size()):
			var chunk_length := int(bytes.decode_u32(offset))
			var chunk_type := int(bytes.decode_u32(offset + 4))
			if chunk_type == 0x4E4F534A:
				json_text = bytes.slice(
					offset + 8,
					mini(offset + 8 + chunk_length, bytes.size())
				).get_string_from_utf8()
				break
			offset += 8 + chunk_length
	else:
		json_text = bytes.get_string_from_utf8()
	if json_text.is_empty():
		return {}

	var parsed: Variant = JSON.parse_string(json_text)
	if not parsed is Dictionary:
		return {}
	var nodes: Variant = (parsed as Dictionary).get("nodes", [])
	if not nodes is Array:
		return {}
	for node_value: Variant in nodes as Array:
		if not node_value is Dictionary:
			continue
		var node_extras: Variant = (node_value as Dictionary).get("extras", {})
		if node_extras is Dictionary and (node_extras as Dictionary).has("hf_grid_size_m"):
			return node_extras
	return {}


## Return why a file fails the heightfield contract, or an empty string.
##
## A GLB with no hf_* extras is an ordinary model, not a heightfield. Importing it
## as terrain would produce a plausible-looking grid from geometry that was never
## authored on a lattice, so it is refused by name instead.
func _contract_error(source_path: String, extras: Dictionary) -> String:
	if extras.is_empty():
		return (
			"'%s' carries no heightfield metadata (hf_grid_size_m). It is an ordinary "
			+ "GLB, not a terrain export from the heightfield add-on."
		) % source_path
	var grid_size := float(extras.get("hf_grid_size_m", 0.0))
	if absf(grid_size - REQUIRED_GRID_SIZE_M) > 0.0001:
		return (
			"'%s' was authored on a %.3f m grid, but this editor's lattice is %.1f m. "
			+ "Re-export it at %.1f m rather than rescaling it here."
		) % [source_path, grid_size, REQUIRED_GRID_SIZE_M, REQUIRED_GRID_SIZE_M]
	return ""


## Return why a file's vertices are off the lattice, or an empty string.
func _lattice_error(source_path: String, surfaces: Array[Dictionary]) -> String:
	for surface: Dictionary in surfaces:
		var vertices: PackedVector3Array = surface["vertices"]
		for vertex: Vector3 in vertices:
			var offset_x := absf(vertex.x - roundf(vertex.x))
			var offset_z := absf(vertex.z - roundf(vertex.z))
			if offset_x > LATTICE_TOLERANCE_M or offset_z > LATTICE_TOLERANCE_M:
				return (
					"'%s' has a vertex at (%.4f, %.4f, %.4f) which is %.4f m off the "
					+ "1 m grid. Every heightfield vertex must sit on a cell corner in XZ."
				) % [source_path, vertex.x, vertex.y, vertex.z, maxf(offset_x, offset_z)]
	return ""


## Sort every triangle into cell top quads and cell-edge vertical spans.
##
## Downward-facing triangles are an optional bottom cap some exporters add; they
## describe no terrain face and are deliberately ignored rather than treated as
## ground. Degenerate triangles carry no normal and are likewise skipped.
func _classify_triangles(surfaces: Array[Dictionary]) -> Dictionary:
	var cell_quads: Dictionary = {}
	var cell_diagonals: Dictionary = {}
	var edge_profiles: Dictionary = {}
	var source_face_count := 0
	for surface: Dictionary in surfaces:
		var vertices: PackedVector3Array = surface["vertices"]
		var indices: PackedInt32Array = surface["indices"]
		for start: int in range(0, indices.size() - 2, 3):
			var point_a := vertices[indices[start]]
			var point_b := vertices[indices[start + 1]]
			var point_c := vertices[indices[start + 2]]
			var normal := _triangle_normal(point_a, point_b, point_c)
			if normal == Vector3.ZERO:
				continue
			var points: Array[Vector3] = [point_a, point_b, point_c]
			if normal.y >= WALKABLE_MIN_NORMAL_Y:
				_record_top_triangle(cell_quads, cell_diagonals, points)
				source_face_count += 1
			elif absf(normal.y) <= VERTICAL_MAX_NORMAL_Y:
				_record_vertical_triangle(edge_profiles, points)
				source_face_count += 1
	return {
		"cell_quads": cell_quads,
		"cell_diagonals": cell_diagonals,
		"edge_profiles": edge_profiles,
		"source_face_count": source_face_count,
	}


## Record one upward triangle's corner heights against the cell it covers.
##
## A heightfield triangle lies entirely inside one cell, so the cell is simply the
## minimum lattice corner of its own vertices -- both triangles of a quad agree on
## it. Each vertex is stored under its exact lattice corner, so a cell ends up
## holding precisely the four heights the file authored.
func _record_top_triangle(
	cell_quads: Dictionary,
	cell_diagonals: Dictionary,
	points: Array[Vector3]
) -> void:
	var lowest := Vector2i(
		roundi(minf(minf(points[0].x, points[1].x), points[2].x)),
		roundi(minf(minf(points[0].z, points[1].z), points[2].z))
	)
	if not cell_quads.has(lowest):
		cell_quads[lowest] = {}
	var corners: Dictionary = cell_quads[lowest]
	var triangle_corners: Array[int] = []
	for point: Vector3 in points:
		var lattice := Vector2i(roundi(point.x), roundi(point.z))
		corners[lattice] = point.y
		var corner_index := TerrainMesh.CORNER_OFFSETS.find(lattice - lowest)
		if corner_index >= 0 and not triangle_corners.has(corner_index):
			triangle_corners.append(corner_index)

	var diagonal := -1
	if triangle_corners.has(0) and triangle_corners.has(3):
		diagonal = 0
	elif triangle_corners.has(1) and triangle_corners.has(2):
		diagonal = 1
	if diagonal < 0:
		cell_diagonals[lowest] = -1
		return
	var previous := int(cell_diagonals.get(lowest, diagonal))
	cell_diagonals[lowest] = diagonal if previous == diagonal else -1


## Record one vertical triangle's exact span at both cell-edge endpoints.
##
## A tapered wall can differ by almost two metres between its endpoints. Merging
## all four values into one minimum and maximum turns that authored trapezoid into
## a larger rectangle, so each lattice endpoint keeps its independent low/high
## pair while triangles belonging to the same source face are combined.
func _record_vertical_triangle(edge_profiles: Dictionary, points: Array[Vector3]) -> void:
	var triangle_profile: Dictionary = {}
	for point: Vector3 in points:
		var endpoint := Vector2i(roundi(point.x), roundi(point.z))
		var span: Array = triangle_profile.get(endpoint, [point.y, point.y])
		triangle_profile[endpoint] = [
			minf(float(span[0]), point.y),
			maxf(float(span[1]), point.y),
		]
	if triangle_profile.size() != 2:
		return
	var corners: Array = triangle_profile.keys()
	var key := _edge_key(corners[0], corners[1])
	if key.is_empty():
		return
	var profile: Dictionary = edge_profiles.get(key, {})
	for endpoint_value: Variant in triangle_profile.keys():
		var endpoint: Vector2i = endpoint_value
		var source_span: Array = triangle_profile[endpoint]
		var merged: Array = profile.get(endpoint, source_span)
		profile[endpoint] = [
			minf(float(merged[0]), float(source_span[0])),
			maxf(float(merged[1]), float(source_span[1])),
		]
	edge_profiles[key] = profile


## Return a canonical key for the cell edge joining two adjacent lattice corners.
##
## Both cells either side share this edge, so the key is built from the corner
## pair itself. That records the wall once no matter which side it was drawn on.
func _edge_key(corner_a: Vector2i, corner_b: Vector2i) -> String:
	var low := corner_a
	var high := corner_b
	if high.x < low.x or (high.x == low.x and high.y < low.y):
		low = corner_b
		high = corner_a
	var delta := high - low
	# Adjacent corners differ by exactly one along a single axis.
	if absi(delta.x) + absi(delta.y) != 1:
		return ""
	return "%d,%d,%d,%d" % [low.x, low.y, high.x, high.y]


## Gather every mesh surface in the scene as world-space triangles.
func _collect_surfaces(
	node: Node,
	parent_transform: Transform3D,
	surfaces: Array[Dictionary]
) -> void:
	var node_3d := node as Node3D
	var world_transform := parent_transform
	if node_3d != null:
		world_transform = parent_transform * node_3d.transform

	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		var mesh := mesh_instance.mesh
		for surface_index: int in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_index)
			if arrays.size() <= Mesh.ARRAY_VERTEX:
				continue
			var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			if vertices == null or vertices.is_empty():
				continue
			var world_vertices := PackedVector3Array()
			world_vertices.resize(vertices.size())
			for index: int in vertices.size():
				world_vertices[index] = world_transform * vertices[index]
			var indices := PackedInt32Array()
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
				indices = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
			if indices.is_empty():
				# An unindexed surface lists its triangles directly.
				indices.resize(world_vertices.size())
				for index: int in world_vertices.size():
					indices[index] = index
			surfaces.append({
				"vertices": world_vertices,
				"indices": indices,
			})

	for child: Node in node.get_children():
		_collect_surfaces(child, world_transform, surfaces)


## Turn decoded cell quads and edge spans into the canonical terrain.
func _decode(
	source_path: String,
	extras: Dictionary,
	cell_quads: Dictionary,
	cell_diagonals: Dictionary,
	edge_profiles: Dictionary,
	source_face_count: int
) -> Dictionary:
	var minimum := Vector2i(TerrainMesh.MAX_AXIS_CELLS, TerrainMesh.MAX_AXIS_CELLS)
	var maximum := Vector2i(-TerrainMesh.MAX_AXIS_CELLS, -TerrainMesh.MAX_AXIS_CELLS)
	for cell_value: Variant in cell_quads.keys():
		var cell: Vector2i = cell_value
		minimum = minimum.min(cell)
		maximum = maximum.max(cell)
	var size_cells := maximum - minimum + Vector2i.ONE
	if size_cells.x > TerrainMesh.MAX_AXIS_CELLS or size_cells.y > TerrainMesh.MAX_AXIS_CELLS:
		return _failure(
			"'%s' is %dx%d cells, which exceeds the %d cell limit."
			% [source_path, size_cells.x, size_cells.y, TerrainMesh.MAX_AXIS_CELLS]
		)

	var terrain := TerrainMesh.create(minimum, size_cells)
	var filled := 0
	for cell_value: Variant in cell_quads.keys():
		var cell: Vector2i = cell_value
		var corners: Dictionary = cell_quads[cell]
		# A complete cell quad has exactly four distinct lattice corners. Anything
		# else is not a heightfield cell, and filling in the gap is precisely the
		# invention this decoder exists to avoid.
		if corners.size() != 4:
			return _failure(
				(
					"'%s' cell (%d, %d) has %d distinct corners instead of 4, so it is "
					+ "not a complete 1 m heightfield quad."
				) % [source_path, cell.x, cell.y, corners.size()]
			)
		terrain.set_cell_filled(cell, true)
		filled += 1
		for corner_index: int in 4:
			var lattice: Vector2i = cell + TerrainMesh.CORNER_OFFSETS[corner_index]
			if not corners.has(lattice):
				return _failure(
					(
						"'%s' cell (%d, %d) is missing its corner at (%d, %d)."
					) % [source_path, cell.x, cell.y, lattice.x, lattice.y]
				)
			terrain.set_cell_corner(cell, corner_index, float(corners[lattice]))
		var diagonal := int(cell_diagonals.get(cell, -1))
		if diagonal < 0 or diagonal > 1:
			return _failure(
				"'%s' cell (%d, %d) has inconsistent top-face diagonals."
				% [source_path, cell.x, cell.y]
			)
		terrain.set_cell_top_diagonal(cell, diagonal)

	# The exporter states how many top cells it wrote. Comparing against what was
	# decoded turns a silent partial import into a named failure.
	var declared_cells := int(extras.get("hf_top_cell_count", 0))
	if declared_cells > 0 and declared_cells != filled:
		return _failure(
			(
				"'%s' declares %d top cells but %d were decoded, so the file and the "
				+ "decoder disagree about its geometry."
			) % [source_path, declared_cells, filled]
		)

	# Assigning cell corners incrementally can derive temporary walls against
	# neighbours whose four final heights have not been decoded yet. Those walls
	# are construction state, not authored GLB faces, so discard them before the
	# validated source edge profiles become the only side geometry.
	terrain.side_faces.clear()
	var assignment := _assign_vertical_faces(terrain, edge_profiles)
	var assignment_error := String(assignment.get("error", ""))
	if not assignment_error.is_empty():
		return _failure(
			"'%s' vertical topology disagrees with its authored tops: %s"
			% [source_path, assignment_error]
		)
	var wall_count := int(assignment["walls"])
	var skirt_edges := int(assignment["skirt_edges"])

	var definition_errors := terrain.validate_definition()
	if not definition_errors.is_empty():
		return _failure(
			"'%s' produced invalid terrain: %s"
			% [source_path, ", ".join(definition_errors)]
		)
	var canonical_face_count := _canonical_face_count(terrain)
	if canonical_face_count != source_face_count:
		return _failure(
			(
				"'%s' contains %d authored terrain faces, but canonical TerrainMesh "
				+ "would contain %d. The import was rejected before changing the board."
			) % [source_path, source_face_count, canonical_face_count]
		)

	var slopes := 0
	for cell_value: Variant in cell_quads.keys():
		if not terrain.is_cell_level(cell_value):
			slopes += 1

	return {
		"ok": true,
		"error": "",
		"terrain": terrain,
		"size_cells": size_cells,
		"origin_cell": minimum,
		"filled_cells": filled,
		"sloped_cells": slopes,
		"wall_count": wall_count,
		"skirt_edges": skirt_edges,
		"source_face_count": source_face_count,
		"canonical_face_count": canonical_face_count,
		"skirt_base_m": terrain.skirt_base_m,
		"extras": extras,
	}


## Count the logical triangles represented by canonical tops, walls, and skirts.
##
## Paint bands may subdivide a tall wall for authoring, but they are derived from
## these full polygons and do not alter the source-equivalent terrain face count.
func _canonical_face_count(terrain: TerrainMesh) -> int:
	var count := terrain.filled_cell_count() * 2
	# Read the derived base once. TerrainMesh.skirt_base_m rescans every cell on
	# each access, so reading it inside the boundary loop below made this count
	# scale with boundary_edges * total_cells on an imported map.
	var base_m := terrain.skirt_base_m
	for record: Dictionary in terrain.side_face_records():
		var cell: Vector2i = record["cell"]
		var edge := int(record["edge"])
		var profile := terrain.side_face(cell, edge)
		var polygon := terrain._side_polygon_for_band(
			cell,
			edge,
			profile,
			minf(float(profile[2]), float(profile[4])),
			maxf(float(profile[3]), float(profile[5]))
		)
		count += _polygon_triangle_count(polygon)
	for local_z: int in terrain.size_cells.y:
		for local_x: int in terrain.size_cells.x:
			var cell := terrain.origin_cell + Vector2i(local_x, local_z)
			if not terrain.is_cell_filled(cell):
				continue
			for edge: int in 4:
				if terrain.is_cell_filled(cell + TerrainMesh.EDGE_NEIGHBOURS[edge]):
					continue
				var profile := terrain._skirt_profile(cell, edge, base_m)
				var polygon := terrain._side_polygon_for_band(
					cell,
					edge,
					profile,
					base_m,
					maxf(float(profile[3]), float(profile[5]))
				)
				count += _polygon_triangle_count(polygon)
	return count


## Count only non-degenerate fan triangles in one canonical vertical polygon.
static func _polygon_triangle_count(polygon: PackedVector3Array) -> int:
	var count := 0
	for triangle_end: int in range(2, polygon.size()):
		if (
			(polygon[triangle_end - 1] - polygon[0])
				.cross(polygon[triangle_end] - polygon[0])
				.length_squared()
			> 0.0
		):
			count += 1
	return count


## Validate source wall profiles and convert the source skirt plane into depth.
##
## Every vertical source endpoint must agree with the top faces decoded from the
## same GLB. Only validated internal edges are rebuilt, so a malformed file fails
## instead of receiving invented geometry. The imported plane establishes the
## initial skirt depth; subsequent sculpting derives a new base from that depth.
func _assign_vertical_faces(terrain: TerrainMesh, edge_profiles: Dictionary) -> Dictionary:
	var walls := 0
	var skirt_edges := 0
	var skirt_base := INF
	var internal_keys: Dictionary = {}
	var boundary_keys: Dictionary = {}
	var wall_candidates: Array = []

	for key_value: Variant in edge_profiles.keys():
		var key := String(key_value)
		var parts := key.split(",")
		if parts.size() != 4:
			return {"error": "vertical edge '%s' has an invalid address" % key}
		var low := Vector2i(int(parts[0]), int(parts[1]))
		var high := Vector2i(int(parts[2]), int(parts[3]))
		var profile_value: Variant = edge_profiles[key_value]
		if not profile_value is Dictionary:
			return {"error": "vertical edge '%s' has no endpoint profile" % key}
		var profile: Dictionary = profile_value
		if not profile.has(low) or not profile.has(high):
			return {"error": "vertical edge '%s' is missing one endpoint span" % key}

		var delta := high - low
		var candidates: Array = []
		if delta.x == 1:
			# The edge runs along X, so it is the north edge of the cell above it
			# and the south edge of the cell below it.
			candidates = [
				[low, TerrainMesh.EDGE_NORTH],
				[low - Vector2i(0, 1), TerrainMesh.EDGE_SOUTH],
			]
		else:
			candidates = [
				[low, TerrainMesh.EDGE_WEST],
				[low - Vector2i(1, 0), TerrainMesh.EDGE_EAST],
			]

		var filled_candidates: Array = []
		for candidate: Array in candidates:
			if terrain.is_cell_filled(candidate[0]):
				filled_candidates.append(candidate)
		if filled_candidates.size() == 2:
			for endpoint: Vector2i in [low, high]:
				var source_span: Array = profile[endpoint]
				if source_span.size() != 2:
					return {"error": "vertical edge '%s' has an invalid endpoint span" % key}
				var first_height := _cell_height_at_lattice(
					terrain,
					filled_candidates[0][0],
					endpoint
				)
				var second_height := _cell_height_at_lattice(
					terrain,
					filled_candidates[1][0],
					endpoint
				)
				var expected_low := minf(first_height, second_height)
				var expected_high := maxf(first_height, second_height)
				if (
					absf(float(source_span[0]) - expected_low) > TerrainMesh.LEVEL_EPSILON_M
					or absf(float(source_span[1]) - expected_high) > TerrainMesh.LEVEL_EPSILON_M
				):
					return {
						"error": (
							"vertical edge '%s' endpoint %s stores %.6f..%.6f, "
							+ "but its authored tops require %.6f..%.6f"
						) % [
							key,
							endpoint,
							float(source_span[0]),
							float(source_span[1]),
							expected_low,
							expected_high,
						],
					}
			internal_keys[key] = true
			wall_candidates.append(filled_candidates)
			walls += 1
		elif filled_candidates.size() == 1:
			var boundary_cell: Vector2i = filled_candidates[0][0]
			for endpoint: Vector2i in [low, high]:
				var source_span: Array = profile[endpoint]
				if source_span.size() != 2:
					return {"error": "boundary edge '%s' has an invalid endpoint span" % key}
				var authored_top := _cell_height_at_lattice(
					terrain,
					boundary_cell,
					endpoint
				)
				if (
					absf(float(source_span[1]) - authored_top)
					> TerrainMesh.LEVEL_EPSILON_M
				):
					return {
						"error": (
							"boundary edge '%s' endpoint %s ends at %.6f, "
							+ "but its authored top is %.6f"
						) % [key, endpoint, float(source_span[1]), authored_top],
					}
				if skirt_base == INF:
					skirt_base = float(source_span[0])
				elif (
					absf(float(source_span[0]) - skirt_base)
					> TerrainMesh.LEVEL_EPSILON_M
				):
					return {
						"error": (
							"boundary edge '%s' starts at %.6f instead of the "
							+ "shared authored skirt base %.6f"
						) % [key, float(source_span[0]), skirt_base],
					}
			boundary_keys[key] = true
			skirt_edges += 1
		else:
			return {"error": "vertical edge '%s' touches no decoded terrain cell" % key}

	var missing_error := _missing_authored_edge_error(
		terrain,
		internal_keys,
		boundary_keys
	)
	if not missing_error.is_empty():
		return {"error": missing_error}
	if skirt_edges == 0 or skirt_base == INF:
		return {"error": "the heightfield has no authored boundary skirt plane"}

	terrain.skirt_depth_m = maxf(terrain.lowest_top_height() - skirt_base, 0.05)
	for candidates_value: Variant in wall_candidates:
		var candidates: Array = candidates_value
		for candidate: Array in candidates:
			terrain.rebuild_side_face_for_edge(candidate[0], int(candidate[1]))
	return {
		"error": "",
		"walls": walls,
		"skirt_edges": skirt_edges,
	}


## Return one cell's authored height at an absolute lattice endpoint.
##
## Callers pass an endpoint of that cell's own edge, so failure indicates corrupt
## edge addressing and returns zero only to let the explicit profile check fail.
func _cell_height_at_lattice(
	terrain: TerrainMesh,
	cell: Vector2i,
	lattice: Vector2i
) -> float:
	var corner_index := TerrainMesh.CORNER_OFFSETS.find(lattice - cell)
	if corner_index < 0:
		return 0.0
	return terrain.cell_corner(cell, corner_index)


## Return why decoded tops are missing a source wall or boundary edge.
##
## This is the no-hole-filling guard: canonical faces are emitted only when the
## GLB contains the matching vertical topology.
func _missing_authored_edge_error(
	terrain: TerrainMesh,
	internal_keys: Dictionary,
	boundary_keys: Dictionary
) -> String:
	for local_z: int in terrain.size_cells.y:
		for local_x: int in terrain.size_cells.x:
			var cell := terrain.origin_cell + Vector2i(local_x, local_z)
			if not terrain.is_cell_filled(cell):
				continue
			for edge: int in 4:
				var neighbour := cell + TerrainMesh.EDGE_NEIGHBOURS[edge]
				var corner_indices: Array = TerrainMesh.EDGE_CORNER_INDICES[edge]
				var start_lattice := cell + TerrainMesh.CORNER_OFFSETS[int(corner_indices[0])]
				var end_lattice := cell + TerrainMesh.CORNER_OFFSETS[int(corner_indices[1])]
				var key := _edge_key(start_lattice, end_lattice)
				if not terrain.is_cell_filled(neighbour):
					if not boundary_keys.has(key):
						return "boundary edge '%s' has no authored skirt face" % key
					continue
				# East and south own the one canonical check for an internal edge.
				if edge != TerrainMesh.EDGE_EAST and edge != TerrainMesh.EDGE_SOUTH:
					continue
				var opposite := (edge + 2) % 4
				var neighbour_indices: Array = TerrainMesh.EDGE_CORNER_INDICES[opposite]
				var start_gap := (
					terrain.cell_corner(cell, int(corner_indices[0]))
					- terrain.cell_corner(neighbour, int(neighbour_indices[1]))
				)
				var end_gap := (
					terrain.cell_corner(cell, int(corner_indices[1]))
					- terrain.cell_corner(neighbour, int(neighbour_indices[0]))
				)
				if (
					absf(start_gap) > TerrainMesh.LEVEL_EPSILON_M
					or absf(end_gap) > TerrainMesh.LEVEL_EPSILON_M
				):
					if not internal_keys.has(key):
						return "discontinuous top edge '%s' has no authored wall face" % key
	return ""


## Build one failure report that names the file and the exact problem.
func _failure(reason: String) -> Dictionary:
	push_error("[Tile Studio] terrain GLB import failed: %s" % reason)
	return {
		"ok": false,
		"error": reason,
		"terrain": null,
		"size_cells": Vector2i.ZERO,
		"origin_cell": Vector2i.ZERO,
		"filled_cells": 0,
		"sloped_cells": 0,
		"wall_count": 0,
		"skirt_edges": 0,
		"skirt_base_m": 0.0,
		"extras": {},
	}
