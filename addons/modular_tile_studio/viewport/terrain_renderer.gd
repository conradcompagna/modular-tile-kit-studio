@tool
class_name MTSTerrainRenderer
extends Node3D

## Presents the canonical TerrainMesh through persistent chunk-local resources.
##
## Terrain topology, collision, primary PNG assignment, and secondary material
## weights have separate update paths. Sculpting replaces only dirty chunks;
## primary Terrain Paint replaces only the affected chunks' MultiMesh instance
## buffers; secondary paint updates its Texture2DArray in place. No interactive
## path is allowed to rebuild unrelated terrain chunks.

const K := preload("../utils/mts_constants.gd")

## Terrain paint batches use this prefix so material updates can route locally.
const BATCH_PREFIX: String = "terrain:"
## Six float texels store one triangle's UV transform, boundary mask, canonical
## world vertices, and four face-local overlay-material PNG orientations.
const INSTANCE_DATA_TEXELS_PER_TRIANGLE: int = 6
## A bounded row width keeps large cliff batches within portable texture dimensions.
const INSTANCE_DATA_ROW_WIDTH: int = 2048

## The canonical terrain chunk edge used by geometry, collision, paint, and picking.
var chunk_cells: int = MTSTerrainMeshBuilder.DEFAULT_CHUNK_CELLS

## Each chunk stores persistent collision plus asset-local triangle MultiMeshes.
var _chunks: Dictionary = {}
## Boundary chunks are cached from canonical filled-cell adjacency during normal chunk builds.
##
## A skirt-base edit can therefore touch only chunks that can own skirt geometry,
## even when the previous base clipped every visible skirt face out of a chunk.
var _boundary_chunks: Dictionary = {}
## Exact grid addresses index faces without scanning the complete terrain.
var _face_by_address: Dictionary = {}
## Stable paint UID -> current lattice address of that same face.
##
## Authored paint stores UIDs, while picking and triangle lookup are addressed by
## lattice position. This derived index is the one bridge between them and is
## rebuilt with the faces themselves, so it can never describe stale geometry.
var _address_by_paint_uid: Dictionary = {}
## Exact triangle records index each face for picking without retriangulation.
var _triangles_by_address: Dictionary = {}
## Geometry versions increment only when sculpting or footprint topology changes.
var _geometry_versions: Dictionary = {}
## Paint versions increment only when primary PNG batch membership changes.
var _paint_versions: Dictionary = {}
## Collision versions increment only when a dirty edit is finalized.
var _collision_versions: Dictionary = {}
## The last scoped operation reports exactly how much derived state it touched.
var _last_update_stats: Dictionary = {}
## One canonical triangle mesh is shared by every terrain face instance.
var _shared_triangle: ArrayMesh = null
## Board-wide structural endpoints used to conform every rendered triangle edge.
##
## This is derived afresh from TerrainMesh after geometry edits; it is never
## authored state and cannot drift independently from the heightfield.
var _boundary_breakpoints: Dictionary = {}


## Name the renderer so its derived resources remain easy to inspect.
func _init() -> void:
	name = "TacticalTerrain"


## Return every chunk that currently holds canonical terrain faces.
func chunks() -> Array:
	return _chunks.keys()


## Return the cached chunks whose filled cells meet the empty exterior.
func boundary_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for chunk_value: Variant in _boundary_chunks.keys():
		result.append(chunk_value as Vector2i)
	return result


## Cache whether one chunk owns any canonical footprint boundary cell.
func _update_boundary_chunk_cache(
	terrain: TerrainMesh,
	chunk: Vector2i,
	top_faces: Array[Dictionary]
) -> void:
	for face: Dictionary in top_faces:
		var cell: Vector2i = face["cell"]
		for neighbour: Vector2i in TerrainMesh.EDGE_NEIGHBOURS:
			if not terrain.is_cell_filled(cell + neighbour):
				_boundary_chunks[chunk] = true
				return
	_boundary_chunks.erase(chunk)


## Return the splat batch key for one chunk, face class, and primary asset.
static func batch_key(chunk: Vector2i, is_top: bool, asset_id: String) -> String:
	return "%s%d,%d,%s,%s" % [
		BATCH_PREFIX, chunk.x, chunk.y, ("t" if is_top else "s"), asset_id
	]


## Return whether one material batch belongs to canonical terrain.
static func is_terrain_batch_key(key: String) -> bool:
	return key.begins_with(BATCH_PREFIX)


## Return the chunk addressed by one terrain material batch key.
static func chunk_from_batch_key(key: String) -> Vector2i:
	var parts := key.trim_prefix(BATCH_PREFIX).split(",")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## Return whether canonical terrain owns one exact grid face.
func has_face_at(cell: Vector3i, face: int) -> bool:
	return _face_by_address.has(K.face_key(cell, face))


## Return the terrain cell one stable paint UID currently occupies.
##
## Returns an empty dictionary when that face no longer exists, which is how a
## caller distinguishes "paint attached to removed terrain" from a real cell
## rather than receiving a coordinate that means nothing.
func cell_for_paint_uid(paint_uid: String) -> Dictionary:
	var address := String(_address_by_paint_uid.get(paint_uid, ""))
	if address.is_empty():
		return {}
	var record: Dictionary = _face_by_address.get(address, {})
	if record.is_empty():
		return {}
	var cell: Vector2i = record["cell"]
	return {"cell": cell}


## Return the stable paint UID of the terrain face at one lattice address.
##
## Editor actions still pick by lattice address, while authored paint is stored
## by UID. This is the single conversion between the two, so no caller has to
## reconstruct a paint identity from coordinates itself.
func paint_uid_at(cell: Vector3i, face: int) -> String:
	var record: Dictionary = _face_by_address.get(K.face_key(cell, face), {})
	if record.is_empty():
		return ""
	return String(record["paint_uid"])


## Return the stable terrain paint UIDs inside one square grid stroke.
##
## The integer metre width is tile-placement state, not the circular pen radius
## used by Materials. Texture dimensions remain only the visible repeat scale.
## Paint UIDs are returned rather than lattice addresses because a face's UID
## survives sculpting, so authored paint stays attached when terrain moves.
func surface_face_uids_for_placement(
	placement: SurfacePlacement,
	asset: TileAsset,
	grid_stroke_size_m: int = 1
) -> PackedStringArray:
	var uids := PackedStringArray()
	if placement == null or asset == null or _face_by_address.is_empty():
		return uids
	# The rotated footprint is the one that matches world space. transform_for_size()
	# swaps the axes for an odd quarter turn, so a rotated decal's visible projector
	# already covers the swapped rectangle; its receivers must span the same cells.
	var texture_footprint := placement.rotated_footprint(asset)
	if texture_footprint.x <= 0 or texture_footprint.y <= 0:
		return uids
	if not placement.is_overlay():
		return surface_face_uids_for_grid_stroke(
			placement.origin,
			placement.face,
			grid_stroke_size_m
		)
	# Cell decals retain their footprint-minimum rectangle. Junction decals collect
	# every terrain receiver touched around their exact centre; these UIDs restrict
	# projection/material receivers and never enlarge the decal's authored size.
	var minimum_u := 0
	var maximum_u := texture_footprint.x - 1
	var minimum_v := 0
	var maximum_v := texture_footprint.y - 1
	if placement.grid_anchor == SurfacePlacement.GridAnchor.JUNCTION:
		minimum_u = floori(-float(texture_footprint.x) * 0.5)
		maximum_u = ceili(float(texture_footprint.x) * 0.5) - 1
		minimum_v = floori(-float(texture_footprint.y) * 0.5)
		maximum_v = ceili(float(texture_footprint.y) * 0.5) - 1
	return _surface_face_uids_in_rectangle(
		placement.origin,
		placement.face,
		minimum_u,
		maximum_u,
		minimum_v,
		maximum_v
	)


## Return the exact terrain faces selected by the established square tile targeter.
##
## Splat painting calls this public route directly so vertical strokes remain on the clicked
## wall plane and never collapse separate walls into one two-dimensional projection cell.
func surface_face_uids_for_grid_stroke(
	origin: Vector3i,
	face: int,
	grid_stroke_size_m: int = 1
) -> PackedStringArray:
	var stroke_size := clampi(grid_stroke_size_m, 1, 100)
	# Odd widths centre on the clicked cell. Even widths use that cell as the
	# lower-left member of the central pair, avoiding a hidden half-cell offset.
	var minimum := -floori(float(stroke_size - 1) * 0.5)
	var maximum := minimum + stroke_size - 1
	return _surface_face_uids_in_rectangle(
		origin,
		face,
		minimum,
		maximum,
		minimum,
		maximum
	)


## Resolve one face-plane rectangle through the canonical terrain face index.
##
## This is the single tile-target implementation shared by direct texture placements,
## splatmap strokes, and overlays; callers only supply their visible rectangle dimensions.
func _surface_face_uids_in_rectangle(
	origin: Vector3i,
	face: int,
	minimum_u: int,
	maximum_u: int,
	minimum_v: int,
	maximum_v: int
) -> PackedStringArray:
	var uids := PackedStringArray()
	if _face_by_address.is_empty():
		return uids
	var axes := SurfacePlacement.footprint_axes(face)
	var axis_u: Vector3i = axes[0]
	var axis_v: Vector3i = axes[1]
	var face_normal := K.face_normal(face)
	var uids_by_key: Dictionary = {}
	for face_value: Variant in _face_by_address.values():
		var face_record: Dictionary = face_value
		if int(face_record["face"]) != face:
			continue
		var grid_cell: Vector3i = face_record["grid_cell"]
		var delta := grid_cell - origin
		# Vertical strokes remain on the exact wall plane that was clicked. Top
		# strokes may cross height bands so sloped terrain stays paintable.
		if not K.is_horizontal_face(face) and Vector3(face_normal).dot(Vector3(delta)) != 0.0:
			continue
		var offset_u := roundi(Vector3(axis_u).dot(Vector3(delta)))
		var offset_v := roundi(Vector3(axis_v).dot(Vector3(delta)))
		if (
			offset_u < minimum_u
			or offset_u > maximum_u
			or offset_v < minimum_v
			or offset_v > maximum_v
		):
			continue
		var address := K.face_key(grid_cell, face)
		uids_by_key[address] = String(face_record["paint_uid"])
	var ordered_keys: Array = uids_by_key.keys()
	ordered_keys.sort()
	for address_value: Variant in ordered_keys:
		uids.append(String(uids_by_key[address_value]))
	return uids


## Build preview triangles and grid contours from the canonical rendered-face records.
##
## A direct texture supplies an asset so this route also calculates its authored UVs.
## Material Tile and RGBA splatmap modes pass no asset because they need only the
## same immutable target geometry; presentation never edits the stored face polygon.
func surface_preview_meshes(
	placement: SurfacePlacement,
	asset: TileAsset
) -> Dictionary:
	var empty := {"mesh": null, "outline": null}
	if placement == null or placement.terrain_face_uids.is_empty():
		return empty
	var textured_preview := asset != null
	var footprint := Vector2i.ONE
	var inverse_transform := Transform3D.IDENTITY
	if textured_preview:
		footprint = placement.canonical_footprint(asset)
		if footprint.x <= 0 or footprint.y <= 0:
			return empty
		var surface_transform := SurfacePlacement.transform_for_size(
			placement.origin,
			placement.face,
			placement.rotation_quarters,
			footprint,
			placement.grid_anchor
		)
		inverse_transform = surface_transform.affine_inverse()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var line_vertices := PackedVector3Array()
	var line_keys: Dictionary = {}
	for uid: String in placement.terrain_face_uids:
		var address := String(_address_by_paint_uid.get(uid, ""))
		if address.is_empty():
			continue
		for triangle: Dictionary in _triangles_by_address.get(address, [] as Array[Dictionary]):
			var points: PackedVector3Array = triangle["points"]
			var normal: Vector3 = triangle["normal"]
			for point: Vector3 in points:
				vertices.append(point)
				normals.append(normal)
				if textured_preview:
					var local_point := inverse_transform * point
					uvs.append(Vector2(
						local_point.x / float(footprint.x) + 0.5,
						0.5 - local_point.y / float(footprint.y)
					))
			var boundary_mask := int(triangle.get("boundary_mask", 0))
			for edge_index: int in 3:
				if (boundary_mask & (1 << edge_index)) == 0:
					continue
				var point_a: Vector3 = points[edge_index]
				var point_b: Vector3 = points[(edge_index + 1) % 3]
				var key_a := _preview_point_key(point_a)
				var key_b := _preview_point_key(point_b)
				var edge_key := "%s>%s" % [key_a, key_b] if key_a < key_b else "%s>%s" % [key_b, key_a]
				if line_keys.has(edge_key):
					continue
				line_keys[edge_key] = true
				line_vertices.append(point_a)
				line_vertices.append(point_b)
	if vertices.is_empty():
		return empty
	var triangle_arrays: Array = []
	triangle_arrays.resize(Mesh.ARRAY_MAX)
	triangle_arrays[Mesh.ARRAY_VERTEX] = vertices
	triangle_arrays[Mesh.ARRAY_NORMAL] = normals
	if textured_preview:
		triangle_arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, triangle_arrays)
	var outline: ArrayMesh = null
	if not line_vertices.is_empty():
		var line_arrays: Array = []
		line_arrays.resize(Mesh.ARRAY_MAX)
		line_arrays[Mesh.ARRAY_VERTEX] = line_vertices
		outline = ArrayMesh.new()
		outline.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	return {"mesh": mesh, "outline": outline}


## Quantize one preview point only for deterministic duplicate-edge removal.
func _preview_point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [
		roundi(point.x * 1000000.0),
		roundi(point.y * 1000000.0),
		roundi(point.z * 1000000.0),
	]


## Return how far one placement's receiver faces reach along a projection axis.
##
## Returned as (minimum, maximum) signed distance from `plane_point` measured
## along `axis`, in metres. A native Decal only affects fragments INSIDE its box,
## so a projector sized from the authored footprint alone stops at whatever depth
## was assumed flat: on sloped or stepped ground the surface leaves that slab and
## the stamp simply vanishes. This reports the real relief so the projection depth
## can be derived from the terrain it is actually being projected onto.
##
## An empty result means none of the receivers are currently indexed, which the
## caller must treat as "unknown" rather than "flat".
func receiver_extent_along_axis(
	paint_uids: PackedStringArray,
	plane_point: Vector3,
	axis: Vector3
) -> Dictionary:
	if axis.length_squared() <= 0.0:
		push_error("[Tile Studio] receiver extent requires a non-zero projection axis.")
		return {}
	var direction := axis.normalized()
	var lowest := INF
	var highest := -INF
	for uid: String in paint_uids:
		var address := String(_address_by_paint_uid.get(uid, ""))
		if address.is_empty():
			continue
		var record: Dictionary = _face_by_address.get(address, {})
		if record.is_empty():
			continue
		for point: Vector3 in MTSTerrainMeshBuilder.face_polygon(record):
			var distance := (point - plane_point).dot(direction)
			lowest = minf(lowest, distance)
			highest = maxf(highest, distance)
	if lowest == INF:
		return {}
	return {"minimum": lowest, "maximum": highest}


## Return the stable paint identity of every currently indexed terrain face.
func paint_uids() -> PackedStringArray:
	var uids := PackedStringArray()
	for face_value: Variant in _face_by_address.values():
		var face_record: Dictionary = face_value
		uids.append(String(face_record["paint_uid"]))
	uids.sort()
	return uids


## Project one terrain lattice cell into the selected control image's explicit 2D plane.
##
## Image rows run downward, so vertical projections negate world Y: the top image row
## addresses the highest wall band. Horizontal image coordinates follow the same positive
## lattice axes used by terrain surface placement: +X for north/south and +Z for east/west.
static func splatmap_projection_cell(grid_cell: Vector3i, face: int) -> Vector2i:
	match face:
		K.Face.POS_Y:
			return Vector2i(grid_cell.x, grid_cell.z)
		K.Face.NEG_Z, K.Face.POS_Z:
			return Vector2i(grid_cell.x, -grid_cell.y)
		K.Face.POS_X, K.Face.NEG_X:
			return Vector2i(grid_cell.z, -grid_cell.y)
	push_error("MTSTerrainRenderer: splatmap projection requires Top, North, South, East, or West.")
	return Vector2i.ZERO


## Return paint identities and projection cells for one explicit directional splat import.
##
## Only faces matching the visible direction are included, so changing projection cannot
## accidentally paint the opposite wall or a top face through a hidden secondary mapping.
func splatmap_targets(face: int) -> Array[Dictionary]:
	var targets_by_address: Dictionary = {}
	for face_value: Variant in _face_by_address.values():
		var face_record: Dictionary = face_value
		if int(face_record.get("face", -1)) != face:
			continue
		var grid_cell: Vector3i = face_record["grid_cell"]
		targets_by_address[K.face_key(grid_cell, face)] = {
			"uid": String(face_record["paint_uid"]),
			"grid_cell": grid_cell,
			"projection_cell": splatmap_projection_cell(grid_cell, face),
			"face": face,
		}
	var ordered_addresses: Array = targets_by_address.keys()
	ordered_addresses.sort()
	var targets: Array[Dictionary] = []
	for address_value: Variant in ordered_addresses:
		targets.append(targets_by_address[address_value] as Dictionary)
	return targets


## Return one face's canonical polygon so directional brush previews draw their real geometry.
func face_polygon_for_paint_uid(uid: String) -> PackedVector3Array:
	var address := String(_address_by_paint_uid.get(uid, ""))
	if address.is_empty():
		return PackedVector3Array()
	var record: Dictionary = _face_by_address.get(address, {})
	return (
		MTSTerrainMeshBuilder.face_polygon(record)
		if not record.is_empty()
		else PackedVector3Array()
	)


## Every terrain paint unit is one square metre in its face-local UV space.
func paint_footprint_for_uid(_uid: String) -> Vector2i:
	return Vector2i.ONE


## Build all chunks for an explicit board load, import, or chunk-model change.
##
## Interactive sculpting and painting must use rebuild_dirty() or
## refresh_paint_for_cells() so this full-board operation stays off drag paths.
func rebuild(
	terrain: TerrainMesh,
	p_chunk_cells: int,
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument = null
) -> bool:
	chunk_cells = maxi(p_chunk_cells, 1)
	_release_all_chunks(paint)
	if terrain == null or terrain.is_empty():
		return false
	var faces := terrain.terrain_faces(chunk_cells)
	_boundary_breakpoints = MTSTerrainMeshBuilder.boundary_breakpoints(faces)
	var grouped := MTSTerrainMeshBuilder.group_faces_by_chunk(faces, chunk_cells)
	for chunk_value: Variant in grouped.keys():
		var chunk: Vector2i = chunk_value
		var bucket: Dictionary = grouped[chunk]
		_update_boundary_chunk_cache(
			terrain,
			chunk,
			bucket["top"] as Array[Dictionary]
		)
		_build_chunk(
			chunk,
			bucket["top"] as Array[Dictionary],
			bucket["side"] as Array[Dictionary],
			paint,
			board
		)
	_last_update_stats = {
		"visual_chunks": _chunks.size(),
		"collision_chunks": _chunks.size(),
		"paint_chunks": _chunks.size(),
		"faces_scanned": faces.size(),
	}
	return not _chunks.is_empty()


## Update visible geometry and picking only for already-haloed affected cells.
##
## TerrainSculptor returns the exact changed cells plus its one-cell seam halo.
## Passing that rectangle through unchanged avoids accidentally expanding a
## boundary edit to a full chunk halo.
func refresh_visual_region(
	terrain: TerrainMesh,
	affected_cells: Rect2i,
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument = null
) -> Array[Vector2i]:
	if terrain == null or affected_cells.size.x <= 0 or affected_cells.size.y <= 0:
		_last_update_stats = {
			"visual_chunks": 0,
			"collision_chunks": 0,
			"paint_chunks": 0,
			"faces_scanned": 0,
		}
		return []
	return refresh_visual_chunks(
		terrain,
		_chunks_for_cell_rect(affected_cells),
		paint,
		board
	)


## Update visible geometry for disjoint cell regions without merging their span.
func refresh_visual_regions(
	terrain: TerrainMesh,
	affected_regions: Array[Rect2i],
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument = null
) -> Array[Vector2i]:
	var included_chunks: Dictionary = {}
	var chunks_to_refresh: Array[Vector2i] = []
	for region: Rect2i in affected_regions:
		for chunk: Vector2i in _chunks_for_cell_rect(region):
			if included_chunks.has(chunk):
				continue
			included_chunks[chunk] = true
			chunks_to_refresh.append(chunk)
	chunks_to_refresh.sort_custom(func(first: Vector2i, second: Vector2i) -> bool:
		return first.y < second.y or (first.y == second.y and first.x < second.x))
	return refresh_visual_chunks(terrain, chunks_to_refresh, paint, board)


## Update visible geometry and picking for an exact caller-supplied chunk set.
func refresh_visual_chunks(
	terrain: TerrainMesh,
	chunks_to_refresh: Array[Vector2i],
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument = null
) -> Array[Vector2i]:
	var changed: Array[Vector2i] = []
	var faces_scanned := 0
	if terrain == null:
		return changed
	for chunk: Vector2i in chunks_to_refresh:
		var cell_rect := MTSTerrainMeshBuilder.chunk_cell_rect(chunk, chunk_cells)
		# One-cell halo contains every face that can share a one-metre structural
		# edge with this chunk. Distant collinear faces cannot split its triangles,
		# so they are deliberately excluded from the breakpoint calculation.
		var breakpoint_faces := terrain.terrain_faces(
			chunk_cells,
			cell_rect.grow(1)
		)
		var local_breakpoints := MTSTerrainMeshBuilder.boundary_breakpoints(
			breakpoint_faces
		)
		faces_scanned += breakpoint_faces.size()
		var top_faces: Array[Dictionary] = []
		var side_faces: Array[Dictionary] = []
		for face: Dictionary in terrain.terrain_faces(chunk_cells, cell_rect):
			faces_scanned += 1
			if int(face["kind"]) == TerrainMesh.FaceKind.TOP:
				top_faces.append(face)
			else:
				side_faces.append(face)
		_update_boundary_chunk_cache(terrain, chunk, top_faces)
		_refresh_chunk_visual_geometry(
			chunk,
			top_faces,
			side_faces,
			local_breakpoints,
			paint,
			board
		)
		changed.append(chunk)
	_last_update_stats = {
		"visual_chunks": changed.size(),
		"collision_chunks": 0,
		"paint_chunks": 0,
		"faces_scanned": faces_scanned,
	}
	return changed

## Finalize collision only for chunks whose visible preview already changed.
##
## Keeping this out of pointer samples lets one stroke reuse stale physics safely
## during drag and pay collision construction exactly once when it ends.
func finalize_collision_chunks(chunks_to_finalize: Array[Vector2i]) -> void:
	var collision_count := 0
	for chunk: Vector2i in chunks_to_finalize:
		var record: Dictionary = _chunks.get(chunk, {})
		if record.is_empty():
			continue
		_build_chunk_collision(chunk, record)
		_collision_versions[chunk] = int(_collision_versions.get(chunk, 0)) + 1
		collision_count += 1
		if (
			(record["top_faces"] as Array).is_empty()
			and (record["side_faces"] as Array).is_empty()
		):
			_chunks.erase(chunk)
	var stats := _last_update_stats.duplicate()
	stats["collision_chunks"] = collision_count
	_last_update_stats = stats


## Apply one non-interactive dirty edit and finalize its local collision immediately.
func rebuild_dirty(
	terrain: TerrainMesh,
	affected_cells: Rect2i,
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument = null
) -> Array[Vector2i]:
	var changed := refresh_visual_region(terrain, affected_cells, paint, board)
	finalize_collision_chunks(changed)
	return changed

## Rebuild only primary-material instance buffers for the addressed terrain cells.
##
## Collision, face topology, picking records, and unrelated visual chunks remain
## untouched. Secondary paint does not call this method because its array changes
## in place without changing batch membership.
func refresh_paint_for_cells(
	dirty_cells: Rect2i,
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument
) -> Array[Vector2i]:
	var changed: Array[Vector2i] = []
	if dirty_cells.size.x <= 0 or dirty_cells.size.y <= 0:
		return changed
	for chunk: Vector2i in _chunks_for_cell_rect(dirty_cells):
		var record: Dictionary = _chunks.get(chunk, {})
		if record.is_empty():
			continue
		_release_chunk_visuals(record, paint)
		_build_chunk_visuals(
			chunk,
			record["top_faces"] as Array[Dictionary],
			record["side_faces"] as Array[Dictionary],
			record,
			paint,
			board
		)
		_paint_versions[chunk] = int(_paint_versions.get(chunk, 0)) + 1
		changed.append(chunk)
	_last_update_stats = {
		"visual_chunks": 0,
		"collision_chunks": 0,
		"paint_chunks": changed.size(),
		"faces_scanned": 0,
	}
	return changed


## Return every chunk intersected by one absolute cell rectangle.
func _chunks_for_cell_rect(cell_rect: Rect2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if cell_rect.size.x <= 0 or cell_rect.size.y <= 0:
		return result
	var first := TerrainMesh.chunk_of_cell(cell_rect.position, chunk_cells)
	var last := TerrainMesh.chunk_of_cell(cell_rect.end - Vector2i.ONE, chunk_cells)
	for chunk_z: int in range(first.y, last.y + 1):
		for chunk_x: int in range(first.x, last.x + 1):
			result.append(Vector2i(chunk_x, chunk_z))
	return result


## Replace one chunk's visible geometry and pick index while preserving collision.
func _refresh_chunk_visual_geometry(
	chunk: Vector2i,
	top_faces: Array[Dictionary],
	side_faces: Array[Dictionary],
	p_boundary_breakpoints: Dictionary,
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument
) -> void:
	var record: Dictionary = _chunks.get(chunk, _empty_chunk_record())
	if _chunks.has(chunk):
		_release_chunk_visuals(record, paint)
		_unindex_chunk_faces(record)
	record["top_faces"] = top_faces
	record["side_faces"] = side_faces
	record["boundary_breakpoints"] = p_boundary_breakpoints
	_update_record_face_counts(record)
	var triangles := MTSTerrainMeshBuilder.triangle_records(
		top_faces,
		side_faces,
		p_boundary_breakpoints
	)
	record["aabb"] = (
		_aabb_for_triangles(triangles)
		if not triangles.is_empty()
		else _empty_chunk_aabb(chunk)
	)
	_chunks[chunk] = record
	if not triangles.is_empty():
		_index_chunk_faces(top_faces, side_faces, triangles)
		_build_chunk_visuals(chunk, top_faces, side_faces, record, paint, board)
	_geometry_versions[chunk] = int(_geometry_versions.get(chunk, 0)) + 1


## Build one complete chunk during an explicit full-board operation.
func _build_chunk(
	chunk: Vector2i,
	top_faces: Array[Dictionary],
	side_faces: Array[Dictionary],
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument
) -> void:
	var triangles := MTSTerrainMeshBuilder.triangle_records(
		top_faces,
		side_faces,
		_boundary_breakpoints
	)
	if triangles.is_empty():
		return
	var record := _empty_chunk_record()
	record["top_faces"] = top_faces
	record["side_faces"] = side_faces
	record["boundary_breakpoints"] = _boundary_breakpoints
	_update_record_face_counts(record)
	record["aabb"] = _aabb_for_triangles(triangles)
	_chunks[chunk] = record
	_index_chunk_faces(top_faces, side_faces, triangles)
	_build_chunk_collision(chunk, record)
	_build_chunk_visuals(chunk, top_faces, side_faces, record, paint, board)
	_geometry_versions[chunk] = int(_geometry_versions.get(chunk, 0)) + 1
	_collision_versions[chunk] = int(_collision_versions.get(chunk, 0)) + 1
	if not _paint_versions.has(chunk):
		_paint_versions[chunk] = 1


## Return one empty derived chunk record with explicit resource ownership.
func _empty_chunk_record() -> Dictionary:
	return {
		"body": null,
		"shape": null,
		"visuals": [] as Array[MultiMeshInstance3D],
		"groups": [] as Array[Dictionary],
		"top_faces": [] as Array[Dictionary],
		"side_faces": [] as Array[Dictionary],
		"boundary_breakpoints": {},
		"top_count": 0,
		"side_count": 0,
		"skirt_count": 0,
		"aabb": AABB(),
	}


## Cache one chunk's face counts so UI readouts never rescan terrain geometry.
func _update_record_face_counts(record: Dictionary) -> void:
	record["top_count"] = (record["top_faces"] as Array).size()
	var side_count := 0
	var skirt_count := 0
	for face: Dictionary in record["side_faces"] as Array:
		if int(face["kind"]) == TerrainMesh.FaceKind.SKIRT:
			skirt_count += 1
		else:
			side_count += 1
	record["side_count"] = side_count
	record["skirt_count"] = skirt_count


## Replace collision for one chunk from its current canonical triangle records.
func _build_chunk_collision(chunk: Vector2i, record: Dictionary) -> void:
	_dispose_child(record.get("body", null) as Node)
	record["body"] = null
	record["shape"] = null
	var top_faces: Array[Dictionary] = record["top_faces"]
	var side_faces: Array[Dictionary] = record["side_faces"]
	if top_faces.is_empty() and side_faces.is_empty():
		return
	var collision_faces := MTSTerrainMeshBuilder.collision_faces_for(
		top_faces,
		side_faces,
		record.get("boundary_breakpoints", {})
	)
	if collision_faces.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "TerrainCollision_%d_%d" % [chunk.x, chunk.y]
	var shape_node := CollisionShape3D.new()
	shape_node.name = "TerrainShape"
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(collision_faces)
	shape_node.shape = shape
	body.add_child(shape_node)
	add_child(body)
	record["body"] = body
	record["shape"] = shape_node


## Return a harmless broad-phase box for an emptied preview chunk.
func _empty_chunk_aabb(chunk: Vector2i) -> AABB:
	var cell_rect := MTSTerrainMeshBuilder.chunk_cell_rect(chunk, chunk_cells)
	return AABB(
		Vector3(cell_rect.position.x, 0.0, cell_rect.position.y),
		Vector3(cell_rect.size.x, 0.0001, cell_rect.size.y)
	)

## Group one chunk's triangles by primary PNG, face-local palette, and shader decal.
##
## RGBA weights have one meaning per face. Faces can share a draw only when their
## four palette indices match, which keeps the shader at four slots while allowing
## unrelated cells on the same board to use different materials.
func _build_chunk_visuals(
	chunk: Vector2i,
	top_faces: Array[Dictionary],
	side_faces: Array[Dictionary],
	record: Dictionary,
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument
) -> void:
	var groups: Dictionary = {}
	for entry: Array in [[top_faces, true], [side_faces, false]]:
		for face: Dictionary in entry[0] as Array:
			var is_top: bool = entry[1]
			var asset_id := _asset_id_for_face(face, board)
			var paint_uid := String(face["paint_uid"])
			var texture_seed_uid := String(face.get("texture_seed_uid", ""))
			var slot_materials := (
				paint.register_face_palette(paint_uid, texture_seed_uid)
				if paint != null
				else PackedInt32Array([-1, -1, -1, -1])
			)
			var slot_key := "%d:%d:%d:%d" % [
				slot_materials[0],
				slot_materials[1],
				slot_materials[2],
				slot_materials[3],
			]
			var shader_decal := _shader_decal_for_face(face, board)
			var shader_decal_uid := (
				shader_decal.ensure_uid() if shader_decal != null else ""
			)
			# The suffixes separate faces that require different palette bindings or
			# a different directly bound decal. The canonical prefix remains intact
			# for paint lookup and chunk parsing.
			var key := "%s,slots=%s,decal=%s" % [
				batch_key(chunk, is_top, asset_id),
				slot_key,
				shader_decal_uid,
			]
			if not groups.has(key):
				groups[key] = {
					"is_top": is_top,
					"asset_id": asset_id,
					"slot_materials": slot_materials,
					"shader_decal": shader_decal,
					"faces": [] as Array[Dictionary],
				}
			(groups[key]["faces"] as Array[Dictionary]).append(face)

	var visuals: Array[MultiMeshInstance3D] = record["visuals"]
	var ordered: Array[Dictionary] = record["groups"]
	for key_value: Variant in groups.keys():
		var key := String(key_value)
		var group: Dictionary = groups[key]
		var faces: Array[Dictionary] = group["faces"]
		if faces.size() > MTSTerrainMeshBuilder.MAX_BATCH_LAYERS:
			push_error(
				"[Tile Studio] terrain batch '%s' needs %d paint layers; maximum is %d."
				% [key, faces.size(), MTSTerrainMeshBuilder.MAX_BATCH_LAYERS]
			)
			continue
		var layers := _register_group_paint(key, faces, paint, board)
		var no_faces: Array[Dictionary] = []
		var triangles: Array[Dictionary] = (
			MTSTerrainMeshBuilder.triangle_records(
				faces,
				no_faces,
				_boundary_breakpoints
			)
			if bool(group["is_top"])
			else MTSTerrainMeshBuilder.triangle_records(
				no_faces,
				faces,
				_boundary_breakpoints
			)
		)
		var visual := _build_visual_batch(
			chunk,
			key,
			triangles,
			layers,
			board,
			paint
		)
		if visual == null:
			if paint != null:
				paint.unregister_batch(key)
			continue
		add_child(visual)
		visuals.append(visual)
		ordered.append({
			"key": key,
			"asset_id": String(group["asset_id"]),
			"slot_materials": (group["slot_materials"] as PackedInt32Array).duplicate(),
			"is_top": group["is_top"] == true,
			"shader_decal": group.get("shader_decal", null),
		})

## Return the direct PNG material placement painted on one terrain face.
##
## Faces are resolved by their sculpt-stable paint UID rather than their lattice
## address, so raising or lowering terrain under authored paint keeps the same
## material attached instead of dropping it when the cell crosses a metre.
func _paint_placement_for_face(
	face: Dictionary,
	board: BoardDocument
) -> SurfacePlacement:
	if board == null:
		return null
	var placement := board.surface_at_paint_uid(String(face["paint_uid"]))
	if placement != null and not placement.asset_id.is_empty():
		return placement
	if (
		board.material_blend == null
		or not board.material_blend.auto_texture_thin_side_slivers
	):
		return null
	# TerrainMesh supplies a source only for residual side bands below 0.1 m.
	# Resolving it here makes the full 1 m square the sole authored PNG source;
	# any direct sliver paint above remains an explicit override.
	var seed_uid := String(face.get("texture_seed_uid", ""))
	if seed_uid.is_empty():
		return null
	var seed_placement := board.surface_at_paint_uid(seed_uid)
	return (
		seed_placement
		if seed_placement != null and not seed_placement.asset_id.is_empty()
		else null
	)


## Return the primary asset painted on one face, or neutral ground when absent.
func _asset_id_for_face(face: Dictionary, board: BoardDocument) -> String:
	var placement := _paint_placement_for_face(face, board)
	return placement.asset_id if placement != null else ""


## Return the direct shader decal assigned to one face, or null when absent.
##
## Overlap is rejected by BoardDocument validation. A loaded legacy overlap is
## reported and left as ordinary terrain rather than choosing a hidden winner.
func _shader_decal_for_face(
	face: Dictionary,
	board: BoardDocument
) -> SurfacePlacement:
	if board == null:
		return null
	var paint_uid := String(face.get("paint_uid", ""))
	if paint_uid.is_empty():
		return null
	var decals := board.shader_decals_at_paint_uid(paint_uid)
	if decals.size() > 1:
		push_error(
			"[Tile Studio] Terrain face '%s' has overlapping shader decals; no decal was bound."
			% paint_uid
		)
		return null
	return decals[0] as SurfacePlacement if decals.size() == 1 else null


## Build one MultiMesh whose instances map the shared triangle onto exact faces.
##
## A shader decal is a directly sampled material layer on this same batch, so no
## alternate geometry, render priority, or coplanar surface exists.
func _build_visual_batch(
	chunk: Vector2i,
	key: String,
	triangles: Array[Dictionary],
	layer_by_uid: Dictionary,
	board: BoardDocument,
	paint: MTSSurfaceMaterialPaint
) -> MultiMeshInstance3D:
	if triangles.is_empty():
		return null
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = false
	multimesh.mesh = _shared_triangle_mesh()
	multimesh.instance_count = triangles.size()

	var data_texel_count := triangles.size() * INSTANCE_DATA_TEXELS_PER_TRIANGLE
	var data_width := mini(INSTANCE_DATA_ROW_WIDTH, maxi(data_texel_count, 1))
	var data_height := ceili(float(data_texel_count) / float(data_width))
	var data_image := Image.create(data_width, maxi(data_height, 1), false, Image.FORMAT_RGBAF)
	data_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var instance_indices_by_uid: Dictionary = {}

	for index: int in triangles.size():
		var triangle: Dictionary = triangles[index]
		var points: PackedVector3Array = triangle["points"]
		var uvs: PackedVector2Array = triangle["uvs"]
		var normal: Vector3 = triangle["normal"]
		var face: Dictionary = triangle["face"]
		var placement := _paint_placement_for_face(face, board)
		# v_surface_uv addresses this face's own paint-control layer, which is a
		# per-face image the pen writes in face-local coordinates. It must stay the
		# face's canonical 0..1 UV. Re-mapping it into the owning placement's
		# multi-metre footprint gave each face a narrow slice of its own control
		# image, and clamped every face outside that footprint onto one constant
		# texel -- which is what made pen strokes read as filled grid cells.
		# Visible material channels do not use this coordinate; they project from
		# the canonical world position.
		multimesh.set_instance_transform(
			index,
			Transform3D(
				Basis(points[1] - points[0], points[2] - points[0], normal),
				points[0]
			)
		)
		var paint_uid := String(face["paint_uid"])
		var layer := int(layer_by_uid.get(paint_uid, 0))
		multimesh.set_instance_color(
			index,
			paint.instance_layer_color(key, paint_uid)
			if paint != null
			else _layer_colour(layer)
		)
		var uid_indices := instance_indices_by_uid.get(paint_uid, PackedInt32Array()) as PackedInt32Array
		uid_indices.append(index)
		instance_indices_by_uid[paint_uid] = uid_indices
		var uv_delta_1 := uvs[1] - uvs[0]
		var uv_delta_2 := uvs[2] - uvs[0]
		var boundary_mask := int(triangle.get("boundary_mask", 0))
		# The painting placement's authored quarter turn orients this face's
		# texture projection. An unpainted face has no placement and no rotation.
		var texture_quarters := (
			K.normalized_quarters(placement.rotation_quarters)
			if placement != null
			else 0
		)
		var data_base := index * INSTANCE_DATA_TEXELS_PER_TRIANGLE
		_set_instance_data_texel(
			data_image,
			data_width,
			data_base,
			Color(uvs[0].x, uvs[0].y, uv_delta_1.x, uv_delta_1.y)
		)
		_set_instance_data_texel(
			data_image,
			data_width,
			data_base + 1,
			Color(uv_delta_2.x, uv_delta_2.y, float(boundary_mask), float(texture_quarters))
		)
		# These canonical metric coordinates project texture density independently
		# of MultiMesh transform semantics, without changing the triangle mesh.
		for point_index: int in 3:
			var world_point := points[point_index]
			_set_instance_data_texel(
				data_image,
				data_width,
				data_base + 2 + point_index,
				Color(
					world_point.x,
					world_point.y,
					world_point.z,
					0.0
				)
			)
		# Each RGBA paint component names a different layered PNG, so its quarter-turn
		# travels beside the face instead of inheriting the base coat's orientation.
		var material_rotations := (
			paint.slot_rotations_for_uid(paint_uid)
			if paint != null
			else PackedInt32Array([0, 0, 0, 0])
		)
		_set_instance_data_texel(
			data_image,
			data_width,
			data_base + 5,
			Color(
				float(material_rotations[0]),
				float(material_rotations[1]),
				float(material_rotations[2]),
				float(material_rotations[3])
			)
		)

	if paint != null:
		paint.bind_batch_instance_colors(key, multimesh, instance_indices_by_uid)
	var data_texture := ImageTexture.create_from_image(data_image)
	var instance := MultiMeshInstance3D.new()
	instance.name = "TerrainVisual_%d_%d_%d" % [chunk.x, chunk.y, absi(key.hash())]
	instance.multimesh = multimesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	instance.set_meta("mts_batch_key", key)
	instance.set_meta("mts_terrain_instance_data", data_texture)
	instance.set_meta("mts_terrain_instance_data_width", data_width)
	var ao_light_affect := 0.25
	if board != null and board.lighting != null:
		ao_light_affect = clampf(board.lighting.material_ao_light_affect, 0.0, 1.0)
	instance.set_meta("mts_material_ao_light_affect", ao_light_affect)
	return instance


## Write one linear terrain-instance datum into its bounded two-dimensional image.
func _set_instance_data_texel(
	image: Image,
	row_width: int,
	linear_index: int,
	value: Color
) -> void:
	image.set_pixel(linear_index % row_width, linear_index / row_width, value)


## Return the one canonical barycentric triangle mesh shared by all terrain batches.
##
## Every instance maps this unit triangle directly onto canonical TerrainMesh points;
## direct shader-decal layers therefore change only material inputs, never topology.
func _shared_triangle_mesh() -> ArrayMesh:
	if _shared_triangle != null:
		return _shared_triangle
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
	])
	arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([
		1.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 0.0, 1.0,
		1.0, 0.0, 0.0, 1.0,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 1.0),
	])
	_shared_triangle = ArrayMesh.new()
	_shared_triangle.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _shared_triangle

## Encode an unpainted array layer and the base-only fast-path class.
func _layer_colour(layer: int) -> Color:
	return Color(
		float(layer & 255) / 255.0,
		float((layer >> 8) & 255) / 255.0,
		0.0,
		0.0
	)


## Register one group's stable face placements and return their array layers.
func _register_group_paint(
	key: String,
	faces: Array[Dictionary],
	paint: MTSSurfaceMaterialPaint,
	board: BoardDocument
) -> Dictionary:
	var layers: Dictionary = {}
	if paint == null:
		return layers
	var face_uids := PackedStringArray()
	var seed_uid_by_uid: Dictionary = {}
	var seed_enabled := (
		board != null
		and board.material_blend != null
		and board.material_blend.auto_texture_thin_side_slivers
	)
	for face: Dictionary in faces:
		var paint_uid := String(face["paint_uid"])
		face_uids.append(paint_uid)
		if not seed_enabled:
			continue
		var seed_uid := String(face.get("texture_seed_uid", ""))
		if not seed_uid.is_empty():
			seed_uid_by_uid[paint_uid] = seed_uid
	if face_uids.is_empty():
		return layers
	paint.register_batch(key, face_uids, Vector2i.ONE, seed_uid_by_uid)
	for index: int in face_uids.size():
		layers[face_uids[index]] = index
	return layers


## Index one chunk's faces and triangle records for local picking and painting.
func _index_chunk_faces(
	top_faces: Array[Dictionary],
	side_faces: Array[Dictionary],
	triangles: Array[Dictionary]
) -> void:
	for face: Dictionary in top_faces + side_faces:
		var address := K.face_key(face["grid_cell"], int(face["face"]))
		_face_by_address[address] = face
		# Authored paint addresses faces by their sculpt-stable UID, so the same
		# records are indexed under both identities: the lattice address for
		# picking and the paint UID for resolving what a placement covers.
		_address_by_paint_uid[String(face["paint_uid"])] = address
		_triangles_by_address[address] = [] as Array[Dictionary]
	for triangle: Dictionary in triangles:
		var face: Dictionary = triangle["face"]
		var address := K.face_key(face["grid_cell"], int(face["face"]))
		(_triangles_by_address[address] as Array[Dictionary]).append(triangle)


## Remove one chunk's derived index entries.
func _unindex_chunk_faces(record: Dictionary) -> void:
	for face: Dictionary in (
		(record.get("top_faces", []) as Array)
		+ (record.get("side_faces", []) as Array)
	):
		var address := K.face_key(face["grid_cell"], int(face["face"]))
		_face_by_address.erase(address)
		_address_by_paint_uid.erase(String(face["paint_uid"]))
		_triangles_by_address.erase(address)


## Release only visual batches and paint bindings while preserving collision.
func _release_chunk_visuals(record: Dictionary, paint: MTSSurfaceMaterialPaint) -> void:
	if paint != null:
		for group: Dictionary in record.get("groups", []) as Array:
			paint.unregister_batch(String(group["key"]))
	for visual_value: Variant in record.get("visuals", []) as Array:
		_dispose_child(visual_value as Node)
	record["visuals"] = [] as Array[MultiMeshInstance3D]
	record["groups"] = [] as Array[Dictionary]


## Release one chunk without touching unrelated derived resources.
func _release_chunk(chunk: Vector2i, paint: MTSSurfaceMaterialPaint) -> void:
	var record: Dictionary = _chunks.get(chunk, {})
	if record.is_empty():
		return
	_release_chunk_visuals(record, paint)
	_unindex_chunk_faces(record)
	_dispose_child(record.get("body", null) as Node)
	_chunks.erase(chunk)


## Release every chunk for an explicit full-board replacement.
func _release_all_chunks(paint: MTSSurfaceMaterialPaint) -> void:
	for chunk_value: Variant in _chunks.keys():
		_release_chunk(chunk_value as Vector2i, paint)
	_boundary_chunks.clear()
	_face_by_address.clear()
	_address_by_paint_uid.clear()
	_triangles_by_address.clear()
	_boundary_breakpoints.clear()


## Detach one derived child immediately and defer only its memory reclamation.
func _dispose_child(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.get_parent() == self:
		remove_child(node)
	node.queue_free()


## Return one chunk's material batches as stable local indices.
func chunk_surfaces(chunk: Vector2i) -> Array:
	var record: Dictionary = _chunks.get(chunk, {})
	var groups: Array = record.get("groups", [])
	var out: Array = []
	for index: int in groups.size():
		var group: Dictionary = groups[index]
		out.append({
			"surface_index": index,
			"key": String(group["key"]),
			"asset_id": String(group["asset_id"]),
			"slot_materials": (group["slot_materials"] as PackedInt32Array).duplicate(),
			"is_top": group["is_top"] == true,
			"shader_decal": group.get("shader_decal", null),
		})
	return out


## Apply one already-built material to one chunk-local visual batch.
func set_chunk_surface_material(
	chunk: Vector2i,
	surface_index: int,
	material: Material
) -> void:
	var record: Dictionary = _chunks.get(chunk, {})
	var visuals: Array = record.get("visuals", [])
	if surface_index < 0 or surface_index >= visuals.size():
		return
	var visual := visuals[surface_index] as MultiMeshInstance3D
	if not is_instance_valid(visual):
		return
	visual.material_override = material
	if material is ShaderMaterial:
		var data_texture := visual.get_meta(
			"mts_terrain_instance_data",
			null
		) as Texture2D
		if data_texture == null:
			push_error(
				"[Tile Studio] terrain batch '%s' has no per-instance UV data texture."
				% String(visual.get_meta("mts_batch_key", ""))
			)
			return
		var shader_material := material as ShaderMaterial
		shader_material.set_shader_parameter(
			"terrain_instance_data_tex",
			data_texture
		)
		shader_material.set_shader_parameter(
			"terrain_instance_data_width",
			int(visual.get_meta("mts_terrain_instance_data_width", 1))
		)
		shader_material.set_shader_parameter(
			"material_ao_light_affect",
			clampf(float(visual.get_meta("mts_material_ao_light_affect", 0.25)), 0.0, 1.0)
		)


## Return every live terrain visual instance for renderer-state updates.
func chunk_instances() -> Array:
	var instances: Array = []
	for chunk_value: Variant in _chunks.keys():
		var record: Dictionary = _chunks[chunk_value]
		instances.append_array(record.get("visuals", []) as Array)
	return instances


## Return all live terrain shader materials without scanning unrelated scene nodes.
func terrain_shader_materials() -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = []
	for instance_value: Variant in chunk_instances():
		var instance := instance_value as MultiMeshInstance3D
		if not is_instance_valid(instance):
			continue
		var material := instance.material_override as ShaderMaterial
		if material != null:
			materials.append(material)
	return materials


## Return the exact scope of the most recent derived terrain update.
func last_update_stats() -> Dictionary:
	return _last_update_stats.duplicate()


## Return cached terrain counts without regenerating or scanning canonical faces.
func summary_counts() -> Dictionary:
	var result := {
		"top": 0,
		"side": 0,
		"skirt": 0,
		"chunks": _chunks.size(),
	}
	for record_value: Variant in _chunks.values():
		var record: Dictionary = record_value
		result["top"] += int(record.get("top_count", 0))
		result["side"] += int(record.get("side_count", 0))
		result["skirt"] += int(record.get("skirt_count", 0))
	return result


## Return one chunk's collision-node identity for incremental regression tests.
func chunk_collision_instance_id(chunk: Vector2i) -> int:
	var record: Dictionary = _chunks.get(chunk, {})
	var body := record.get("body", null) as StaticBody3D
	return body.get_instance_id() if is_instance_valid(body) else 0


## Return one chunk's visual identities for paint-only regression tests.
func chunk_visual_instance_ids(chunk: Vector2i) -> PackedInt64Array:
	var ids := PackedInt64Array()
	var record: Dictionary = _chunks.get(chunk, {})
	for visual_value: Variant in record.get("visuals", []) as Array:
		var visual := visual_value as MultiMeshInstance3D
		if is_instance_valid(visual):
			ids.append(visual.get_instance_id())
	return ids


## Return one chunk's geometry revision for inspectable dirty-scope assertions.
func chunk_geometry_version(chunk: Vector2i) -> int:
	return int(_geometry_versions.get(chunk, 0))


## Return one chunk's primary-paint revision for inspectable dirty-scope assertions.
func chunk_paint_version(chunk: Vector2i) -> int:
	return int(_paint_versions.get(chunk, 0))


## Return one chunk's collision revision for stroke-finalization assertions.
func chunk_collision_version(chunk: Vector2i) -> int:
	return int(_collision_versions.get(chunk, 0))


## Intersect one ray with canonical triangles in only broad-phase hit chunks.
func pick_face(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if ray_direction.length_squared() <= 0.0:
		return {}
	var direction := ray_direction.normalized()
	var nearest_distance := INF
	var nearest: Dictionary = {}
	for chunk_value: Variant in _chunks.keys():
		var record: Dictionary = _chunks[chunk_value]
		if not _ray_intersects_aabb(ray_origin, direction, record["aabb"] as AABB):
			continue
		for face: Dictionary in (
			(record["top_faces"] as Array)
			+ (record["side_faces"] as Array)
		):
			var address := K.face_key(face["grid_cell"], int(face["face"]))
			for triangle: Dictionary in _triangles_by_address.get(address, []) as Array:
				var points: PackedVector3Array = triangle["points"]
				var result: Variant = Geometry3D.ray_intersects_triangle(
					ray_origin,
					direction,
					points[0],
					points[1],
					points[2]
				)
				if result == null:
					continue
				var point: Vector3 = result
				var distance := ray_origin.distance_squared_to(point)
				if distance >= nearest_distance:
					continue
				nearest_distance = distance
				nearest = {
					"face": face,
					"point": point,
					"normal": triangle["normal"],
					"uid": String(face["paint_uid"]),
					"local_uv": MTSTerrainMeshBuilder.face_uv(face, point),
					"is_wall": int(face["kind"]) != TerrainMesh.FaceKind.TOP,
				}
	return nearest


## Intersect one ray with terrain and resolve the nearest canonical grid junction.
##
## Edge placement owns this target primitive and never passes through the cell
## picker. The exact triangle hit supplies only the supporting face and pointer
## position; grid_edge_target_for_face() returns the nearest shared lattice vertex.
func pick_grid_edge(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var surface_pick := pick_face(ray_origin, ray_direction)
	if surface_pick.is_empty():
		return {}
	return grid_edge_target_for_face(
		surface_pick["face"],
		surface_pick["point"],
		surface_pick["normal"]
	)


## Convert one exact terrain hit into the nearest four-cell grid junction.
##
## Rounding independently along the two face axes selects the shared lattice
## vertex under the pointer, without routing through cell ownership or adding size.
static func grid_edge_target_for_face(
	face: Dictionary,
	hit_point: Vector3,
	hit_normal: Vector3
) -> Dictionary:
	if not face.has("grid_cell") or not face.has("face"):
		push_error("[Tile Studio] grid-junction targeting requires a canonical terrain face.")
		return {}
	var grid_cell: Vector3i = face["grid_cell"]
	var face_id := int(face["face"])
	var axes := SurfacePlacement.footprint_axes(face_id)
	var axis_u: Vector3i = axes[0]
	var axis_v: Vector3i = axes[1]
	var local_point := hit_point - Vector3(grid_cell)
	var local_u := Vector3(axis_u).dot(local_point)
	var local_v := Vector3(axis_v).dot(local_point)
	var junction_origin := (
		grid_cell
		+ axis_u * roundi(local_u)
		+ axis_v * roundi(local_v)
	)

	var world_junction := Vector3(junction_origin)
	var face_normal := Vector3(K.face_normal(face_id))
	if face_id == K.Face.NEG_Y:
		world_junction += Vector3.UP
	elif face_id == K.Face.POS_X or face_id == K.Face.POS_Z:
		world_junction += face_normal.abs()
	return {
		"hit": true,
		"cell": junction_origin,
		"edge_origin": junction_origin,
		"grid_anchor": SurfacePlacement.GridAnchor.JUNCTION,
		"point": world_junction,
		"normal": hit_normal,
		"terrain_face": face,
		"support": null,
		"terrain": true,
		"grid_edge": true,
	}


## Return whether a forward ray intersects one chunk's world-space bounds.
func _ray_intersects_aabb(origin: Vector3, direction: Vector3, bounds: AABB) -> bool:
	var t_min := 0.0
	var t_max := INF
	for axis: int in 3:
		var low := bounds.position[axis]
		var high := bounds.end[axis]
		if absf(direction[axis]) <= 0.000001:
			if origin[axis] < low or origin[axis] > high:
				return false
			continue
		var first := (low - origin[axis]) / direction[axis]
		var second := (high - origin[axis]) / direction[axis]
		if first > second:
			var swap := first
			first = second
			second = swap
		t_min = maxf(t_min, first)
		t_max = minf(t_max, second)
		if t_max < t_min:
			return false
	return t_max >= 0.0


## Return the exact face-local UV used by both shader and brush sampling.
func local_uv_for_face(face: Dictionary, world_point: Vector3) -> Vector2:
	# Unclamped: a brush capsule centred on a neighbouring face must report as
	# outside this one so the stroke's own distance test decides the coverage.
	# Clamping here pinned those endpoints to the border and stamped hard edges.
	return MTSTerrainMeshBuilder.face_uv_unclamped(face, world_point)


## Return nearby faces by consulting only chunks reached by the stroke capsule.
func faces_near_segment(
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var cell_low := Vector2i(
		floori(minf(start_world.x, end_world.x) - radius_m),
		floori(minf(start_world.z, end_world.z) - radius_m)
	)
	var cell_high := Vector2i(
		ceili(maxf(start_world.x, end_world.x) + radius_m),
		ceili(maxf(start_world.z, end_world.z) + radius_m)
	)
	var low_y := minf(start_world.y, end_world.y) - radius_m
	var high_y := maxf(start_world.y, end_world.y) + radius_m
	var candidate_rect := Rect2i(cell_low, cell_high - cell_low + Vector2i.ONE)
	for chunk: Vector2i in _chunks_for_cell_rect(candidate_rect):
		var record: Dictionary = _chunks.get(chunk, {})
		if record.is_empty():
			continue
		for face: Dictionary in (
			(record["top_faces"] as Array)
			+ (record["side_faces"] as Array)
		):
			var cell: Vector2i = face["cell"]
			if (
				cell.x < cell_low.x - 1
				or cell.y < cell_low.y - 1
				or cell.x > cell_high.x
				or cell.y > cell_high.y
			):
				continue
			if int(face["kind"]) != TerrainMesh.FaceKind.TOP:
				if float(face["bottom_m"]) > high_y or float(face["top_m"]) < low_y:
					continue
			if not _face_within_capsule(face, start_world, end_world, radius_m):
				continue
			found.append(face)
	return found


## Return whether a face's real geometry lies inside one world-space brush capsule.
##
## A face's UV frame describes only its two in-plane axes: a TOP face drops world
## Y and a SIDE band drops its distance out from the wall plane. A point metres
## away therefore still resolves to a perfectly valid UV on that face. Without
## this third-dimension test the brush paints stacked floors above and below the
## stroke, and any wall the stroke merely lines up with.
func _face_within_capsule(
	face: Dictionary,
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> bool:
	var polygon := MTSTerrainMeshBuilder.face_polygon(face)
	if polygon.is_empty():
		return false
	var bounds := AABB(polygon[0], Vector3.ZERO)
	for point: Vector3 in polygon:
		bounds = bounds.expand(point)
	# Growing by the radius turns the segment test into the capsule test. The
	# corners overstate the capsule slightly; the brush's own per-pixel distance
	# check then rejects anything the rounded sweep does not actually cover.
	bounds = bounds.grow(radius_m)
	if bounds.has_point(start_world) or bounds.has_point(end_world):
		return true
	return bounds.intersects_segment(start_world, end_world) != null


## Return world bounds containing one non-empty triangle collection.
func _aabb_for_triangles(triangles: Array[Dictionary]) -> AABB:
	var first_points: PackedVector3Array = triangles[0]["points"]
	var bounds := AABB(first_points[0], Vector3.ZERO)
	for triangle: Dictionary in triangles:
		var points: PackedVector3Array = triangle["points"]
		for point: Vector3 in points:
			bounds = bounds.expand(point)
	# A zero-thickness axis would reject a numerically coplanar ray, so only the
	# broad-phase bounds receive an epsilon; authored geometry remains unchanged.
	return bounds.grow(0.0001)
