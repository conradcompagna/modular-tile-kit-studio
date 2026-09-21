@tool
class_name MTSTerrainMeshBuilder
extends RefCounted

## Builds the visible encounter mesh from the canonical TerrainMesh.
##
## Terrain is ONE continuous heightfield surface carrying both shared-corner
## slopes and true vertical walls. This builder only turns
## TerrainMesh.terrain_faces() into geometry, so the mesh, the collision, the
## paintable units and the gameplay grid cannot disagree about which faces exist.
##
## Every face is presented to the EXISTING surface pipeline exactly as a 1 m PNG
## quad was: its UV runs 0..1 across that one face, and its vertex colour carries
## its splat-array layer. Nothing about the shader, the material factory or the
## paint system had to change to render it -- the heightfield simply supplies the
## geometry those systems used to get from a generated quad.
##
## Emitted geometry, per paint chunk
## ---------------------------------
##   surface 0   every filled cell's TOP quad
##   surface 1   every SIDE band (real walls) and SKIRT band (the boundary shell)
##
## Two surfaces because each binds a different splat array, and a Texture2DArray
## requires every layer to share one resolution.

const K := preload("../utils/mts_constants.gd")

## Cell edge of one rendering chunk.
##
## Chunking is a rendering and paint-batching subdivision only: chunk-boundary
## vertices carry identical corner heights, so the surface stays unbroken. It
## exists so one Texture2DArray never has to hold every face on the board.
const DEFAULT_CHUNK_CELLS: int = 8

## Most drivers expose 2048 Texture2DArray layers. A chunk needing more faces than
## this is reported rather than silently truncated.
const MAX_BATCH_LAYERS: int = 2048
## Boundary coordinates are quantized at micrometre precision for deterministic topology.
const TOPOLOGY_EPSILON_M: float = 0.000001


## Return the chunk edge in cells. Fixed, because each face is its own paint unit
## and therefore already paints at the profile's authored texel density.
static func chunk_cells_for(_profile: MaterialBlendProfile) -> int:
	return DEFAULT_CHUNK_CELLS


## Return the absolute cell rectangle one chunk covers.
static func chunk_cell_rect(chunk: Vector2i, chunk_cells: int) -> Rect2i:
	var size := maxi(chunk_cells, 1)
	return Rect2i(chunk * size, Vector2i(size, size))


## Group every terrain face by the chunk that owns it.
##
## A side band is grouped by the chunk of the cell it stands on, so a wall is
## always rebuilt alongside the ground it belongs to.
static func group_faces_by_chunk(
	faces: Array[Dictionary],
	chunk_cells: int
) -> Dictionary:
	var grouped: Dictionary = {}
	for face: Dictionary in faces:
		var chunk: Vector2i = TerrainMesh.chunk_of_cell(face["cell"], chunk_cells)
		if not grouped.has(chunk):
			grouped[chunk] = {"top": [] as Array[Dictionary], "side": [] as Array[Dictionary]}
		var bucket: Dictionary = grouped[chunk]
		if int(face["kind"]) == TerrainMesh.FaceKind.TOP:
			(bucket["top"] as Array[Dictionary]).append(face)
		else:
			(bucket["side"] as Array[Dictionary]).append(face)
	return grouped


## Build the board-wide breakpoint arrangement for every structural face boundary.
##
## A long top edge can meet several clipped side bands, while independently
## sculpted side profiles can meet at partial vertical overlaps. Recording every
## endpoint on each infinite boundary line gives all consumers the same atomic
## segments without introducing transition-type exceptions.
static func boundary_breakpoints(faces: Array[Dictionary]) -> Dictionary:
	var buckets: Dictionary = {}
	for face: Dictionary in faces:
		var polygon := face_polygon(face)
		for edge_index: int in polygon.size():
			var point_a := polygon[edge_index]
			var point_b := polygon[(edge_index + 1) % polygon.size()]
			var direction := _canonical_line_direction(point_b - point_a)
			if direction.length_squared() <= TOPOLOGY_EPSILON_M:
				continue
			var line_key := _line_key(point_a, direction)
			if not buckets.has(line_key):
				buckets[line_key] = {
					"direction": direction,
					"reference": point_a,
					"scalars": [],
				}
			var bucket: Dictionary = buckets[line_key]
			var reference: Vector3 = bucket["reference"]
			var scalars: Array = bucket["scalars"]
			scalars.append((point_a - reference).dot(direction))
			scalars.append((point_b - reference).dot(direction))

	for line_key_value: Variant in buckets.keys():
		var bucket: Dictionary = buckets[line_key_value]
		var scalars: Array = bucket["scalars"]
		scalars.sort()
		var unique_breakpoints: Array[float] = []
		for scalar_value: Variant in scalars:
			var scalar := float(scalar_value)
			if (
				unique_breakpoints.is_empty()
				or absf(scalar - unique_breakpoints[unique_breakpoints.size() - 1])
				> TOPOLOGY_EPSILON_M
			):
				unique_breakpoints.append(scalar)
		bucket["breakpoints"] = unique_breakpoints
		bucket.erase("scalars")
	return buckets


## Return the one canonical triangulation used by rendering, collision, and picking.
##
## Each record carries its source face, world-space points, and exact per-face UVs.
## Consumers can change presentation or batching without reimplementing how a
## mixed slope/step polygon is split, which keeps every derived artifact aligned.
static func triangle_records(
	top_faces: Array[Dictionary],
	side_faces: Array[Dictionary],
	p_boundary_breakpoints: Dictionary
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	# Canonical corner order is 0=(x,z), 1=(x+1,z), 2=(x,z+1), 3=(x+1,z+1).
	const CORNER_UVS: Array[Vector2] = [
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
	]
	for face: Dictionary in top_faces:
		var quad_value: Variant = face.get("quad", PackedVector3Array())
		if not quad_value is PackedVector3Array:
			continue
		var quad: PackedVector3Array = quad_value
		if quad.size() != 4:
			continue
		# TerrainMesh stores the diagonal as canonical geometry. Manual sculpting
		# derives it after each height edit, while GLB import records the authored
		# source edge, so this renderer never invents a new saddle-cell shape.
		var diagonal := int(face.get("diagonal", -1))
		if diagonal < 0 or diagonal > 1:
			push_error(
				"[Tile Studio] terrain top face '%s' has no canonical diagonal."
				% String(face.get("paint_uid", ""))
			)
			continue
		var order: Array = (
			[0, 3, 1, 0, 2, 3]
			if diagonal == 0
			else [0, 2, 1, 1, 2, 3]
		)
		for triangle_index: int in 2:
			var a := int(order[triangle_index * 3])
			var b := int(order[triangle_index * 3 + 1])
			var triangle_c := int(order[triangle_index * 3 + 2])
			_append_conforming_triangle_records(
				records,
				face,
				PackedVector3Array([quad[a], quad[b], quad[triangle_c]]),
				PackedVector2Array([
					CORNER_UVS[a],
					CORNER_UVS[b],
					CORNER_UVS[triangle_c],
				]),
				p_boundary_breakpoints
			)
	for face: Dictionary in side_faces:
		var polygon := face_polygon(face)
		for triangle_end: int in range(2, polygon.size()):
			var points := PackedVector3Array([
				polygon[0],
				polygon[triangle_end - 1],
				polygon[triangle_end],
			])
			_append_conforming_triangle_records(
				records,
				face,
				points,
				PackedVector2Array([
					face_uv(face, points[0]),
					face_uv(face, points[1]),
					face_uv(face, points[2]),
				]),
				p_boundary_breakpoints
			)
	return records


## Split one raw triangle at every board-wide breakpoint on its structural edges.
##
## The inserted points remain collinear with the original triangle perimeter.
## Unsplit triangles retain their original topology. When splits exist,
## triangulating from an interior centroid preserves every perimeter segment;
## using a perimeter vertex as the fan root would discard splits on its closing
## edge as degenerate triangles.
static func _append_conforming_triangle_records(
	records: Array[Dictionary],
	face: Dictionary,
	points: PackedVector3Array,
	uvs: PackedVector2Array,
	p_boundary_breakpoints: Dictionary
) -> void:
	if points.size() != 3 or uvs.size() != 3:
		return
	var source_boundary_mask := _triangle_boundary_mask(face, points)
	var outline_points := PackedVector3Array()
	var outline_uvs := PackedVector2Array()
	for edge_index: int in 3:
		var next_index := (edge_index + 1) % 3
		outline_points.append(points[edge_index])
		outline_uvs.append(uvs[edge_index])
		if (source_boundary_mask & (1 << edge_index)) == 0:
			continue
		for t: float in _edge_split_parameters(
			points[edge_index],
			points[next_index],
			p_boundary_breakpoints
		):
			outline_points.append(points[edge_index].lerp(points[next_index], t))
			outline_uvs.append(uvs[edge_index].lerp(uvs[next_index], t))
	if outline_points.size() < 3:
		return
	if outline_points.size() == 3:
		_append_triangle_record(records, face, points, uvs)
		return
	var centroid := Vector3.ZERO
	var centroid_uv := Vector2.ZERO
	for outline_index: int in outline_points.size():
		centroid += outline_points[outline_index]
		centroid_uv += outline_uvs[outline_index]
	centroid /= float(outline_points.size())
	centroid_uv /= float(outline_uvs.size())
	for outline_index: int in outline_points.size():
		var next_outline_index := (outline_index + 1) % outline_points.size()
		_append_triangle_record(
			records,
			face,
			PackedVector3Array([
				centroid,
				outline_points[outline_index],
				outline_points[next_outline_index],
			]),
			PackedVector2Array([
				centroid_uv,
				outline_uvs[outline_index],
				outline_uvs[next_outline_index],
			])
		)


## Return the ordered internal split parameters for one structural edge.
static func _edge_split_parameters(
	point_a: Vector3,
	point_b: Vector3,
	p_boundary_breakpoints: Dictionary
) -> Array[float]:
	var parameters: Array[float] = []
	var delta := point_b - point_a
	if delta.length_squared() <= TOPOLOGY_EPSILON_M:
		return parameters
	var direction := _canonical_line_direction(delta)
	var line_key := _line_key(point_a, direction)
	if not p_boundary_breakpoints.has(line_key):
		return parameters
	var bucket: Dictionary = p_boundary_breakpoints[line_key]
	var reference: Vector3 = bucket["reference"]
	var denominator := delta.length_squared()
	for scalar_value: Variant in bucket["breakpoints"] as Array:
		var point := reference + direction * float(scalar_value)
		var t := (point - point_a).dot(delta) / denominator
		if t > TOPOLOGY_EPSILON_M and t < 1.0 - TOPOLOGY_EPSILON_M:
			parameters.append(t)
	parameters.sort()
	return parameters


## Append one non-degenerate triangle record while preserving its face provenance.
static func _append_triangle_record(
	records: Array[Dictionary],
	face: Dictionary,
	points: PackedVector3Array,
	uvs: PackedVector2Array
) -> void:
	if points.size() != 3 or uvs.size() != 3:
		return
	var normal := (points[1] - points[0]).cross(points[2] - points[0])
	if normal.length_squared() <= 0.0:
		return
	records.append({
		"face": face,
		"points": points,
		"uvs": uvs,
		"normal": normal.normalized(),
		"boundary_mask": _triangle_boundary_mask(face, points),
	})


## Encode which triangle edges lie on the source face's structural boundary.
##
## The terrain shader fades PNG height displacement only on these edges, keeping
## neighbouring faces welded without flattening internal triangulation diagonals.
static func _triangle_boundary_mask(
	face: Dictionary,
	points: PackedVector3Array
) -> int:
	var polygon := face_polygon(face)
	if polygon.size() < 3:
		return 0
	var mask := 0
	if _edge_is_polygon_boundary(points[0], points[1], polygon):
		mask |= 1
	if _edge_is_polygon_boundary(points[1], points[2], polygon):
		mask |= 2
	if _edge_is_polygon_boundary(points[2], points[0], polygon):
		mask |= 4
	return mask


## Return whether one undirected triangle edge lies on a canonical polygon edge.
static func _edge_is_polygon_boundary(
	point_a: Vector3,
	point_b: Vector3,
	polygon: PackedVector3Array
) -> bool:
	for index: int in polygon.size():
		var edge_a := polygon[index]
		var edge_b := polygon[(index + 1) % polygon.size()]
		if (
			_point_is_on_segment(point_a, edge_a, edge_b)
			and _point_is_on_segment(point_b, edge_a, edge_b)
		):
			return true
	return false


## Return whether one point lies on a finite canonical boundary segment.
static func _point_is_on_segment(point: Vector3, edge_a: Vector3, edge_b: Vector3) -> bool:
	var delta := edge_b - edge_a
	var length_squared := delta.length_squared()
	if length_squared <= TOPOLOGY_EPSILON_M:
		return point.distance_squared_to(edge_a) <= TOPOLOGY_EPSILON_M * TOPOLOGY_EPSILON_M
	var t := (point - edge_a).dot(delta) / length_squared
	if t < -TOPOLOGY_EPSILON_M or t > 1.0 + TOPOLOGY_EPSILON_M:
		return false
	var projected := edge_a + delta * t
	return point.distance_squared_to(projected) <= TOPOLOGY_EPSILON_M * TOPOLOGY_EPSILON_M


## Return one deterministic unit direction for an undirected terrain line.
static func _canonical_line_direction(delta: Vector3) -> Vector3:
	if delta.length_squared() <= TOPOLOGY_EPSILON_M:
		return Vector3.ZERO
	var direction := delta.normalized()
	if _vector3_less(direction, Vector3.ZERO):
		direction = -direction
	return direction


## Quantize an infinite line by its direction and invariant Plucker moment.
static func _line_key(point: Vector3, direction: Vector3) -> String:
	var moment := point.cross(direction)
	return "%d,%d,%d|%d,%d,%d" % [
		roundi(direction.x * 1000000.0),
		roundi(direction.y * 1000000.0),
		roundi(direction.z * 1000000.0),
		roundi(moment.x * 1000000.0),
		roundi(moment.y * 1000000.0),
		roundi(moment.z * 1000000.0),
	]


## Return a deterministic order for quantized terrain vectors.
static func _vector3_less(a: Vector3, b: Vector3) -> bool:
	var ax := roundi(a.x * 1000000.0)
	var ay := roundi(a.y * 1000000.0)
	var az := roundi(a.z * 1000000.0)
	var bx := roundi(b.x * 1000000.0)
	var by := roundi(b.y * 1000000.0)
	var bz := roundi(b.z * 1000000.0)
	if ax != bx:
		return ax < bx
	if ay != by:
		return ay < by
	return az < bz


## Canonicalize one undirected structural edge for cross-system lookup.
static func canonical_boundary_edge(point_a: Vector3, point_b: Vector3) -> Dictionary:
	var first := point_a
	var second := point_b
	if _vector3_less(second, first):
		first = point_b
		second = point_a
	return {
		"a": first,
		"b": second,
		"key": "%s>%s" % [boundary_vertex_key(first), boundary_vertex_key(second)],
	}


## Encode one canonical terrain point with micrometre-stable quantization.
static func boundary_vertex_key(point: Vector3) -> String:
	return "%d,%d,%d" % [
		roundi(point.x * 1000000.0),
		roundi(point.y * 1000000.0),
		roundi(point.z * 1000000.0),
	]


## Return a face's exact perimeter polygon from its canonical stored points.
##
## Top quads are stored in corner-address order 0,1,2,3 so height and UV data
## remain directly indexable. Their perimeter is 0,1,3,2; walking storage order
## would falsely classify both cross-cell diagonals as grid edges.
static func face_polygon(face: Dictionary) -> PackedVector3Array:
	var polygon_value: Variant = face.get("polygon", PackedVector3Array())
	if polygon_value is PackedVector3Array:
		var polygon: PackedVector3Array = polygon_value
		if polygon.size() >= 3:
			return polygon
	var quad_value: Variant = face.get("quad", PackedVector3Array())
	if quad_value is PackedVector3Array:
		var quad: PackedVector3Array = quad_value
		if int(face.get("kind", -1)) == TerrainMesh.FaceKind.TOP and quad.size() == 4:
			return PackedVector3Array([quad[0], quad[1], quad[3], quad[2]])
		return quad
	return PackedVector3Array()


## Map one face point into the face's UV frame, clamped to the face itself.
##
## Rendering and picking address points that already lie on the face, so the
## clamp only absorbs numerical overshoot. Painting must NOT use this: a brush
## centred on a neighbouring face would clamp onto this face's border and stamp a
## hard edge-aligned block there. That path uses face_uv_unclamped() instead.
static func face_uv(face: Dictionary, point: Vector3) -> Vector2:
	var uv := face_uv_unclamped(face, point)
	return Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))


## Map one point into a face's UV frame without confining it to that face.
##
## A world-space brush capsule crosses face seams, so each face must be able to
## say the stroke passed outside it. Returning coordinates beyond 0..1 lets the
## brush's own distance test reject or partially cover the face, which is what
## makes a stroke read as one continuous pen mark rather than filled cells.
##
## Keeping this transform beside the canonical triangulation prevents picking and
## brush stamps from acquiring a separate interpretation of clipped side bands.
static func face_uv_unclamped(face: Dictionary, point: Vector3) -> Vector2:
	var cell: Vector2i = face["cell"]
	if int(face["kind"]) == TerrainMesh.FaceKind.TOP:
		return Vector2(point.x - float(cell.x), point.z - float(cell.y))
	var edge := int(face["edge"])
	var corner_indices: Array = TerrainMesh.EDGE_CORNER_INDICES[edge]
	var edge_start := Vector2(cell + TerrainMesh.CORNER_OFFSETS[int(corner_indices[0])])
	var edge_end := Vector2(cell + TerrainMesh.CORNER_OFFSETS[int(corner_indices[1])])
	var edge_axis := edge_end - edge_start
	var point_xz := Vector2(point.x, point.z)
	var edge_t := (
		(point_xz - edge_start).dot(edge_axis) / edge_axis.length_squared()
		if edge_axis.length_squared() > 0.0
		else 0.0
	)
	var start_t := float(face.get("start_t", 0.0))
	var end_t := float(face.get("end_t", 1.0))
	var u := (
		(edge_t - start_t) / (end_t - start_t)
		if end_t - start_t > TerrainMesh.LEVEL_EPSILON_M
		else 0.0
	)
	var bottom_m := float(face["bottom_m"])
	var top_m := float(face["top_m"])
	var v := (
		(top_m - point.y) / (top_m - bottom_m)
		if top_m - bottom_m > TerrainMesh.LEVEL_EPSILON_M
		else 0.0
	)
	return Vector2(u, v)


## Build collision triangles from already-grouped canonical faces.
##
## This is the chunk-local form used by incremental sculpting, so one changed
## chunk never needs to inspect or rebuild collision for the rest of the board.
static func collision_faces_for(
	top_faces: Array[Dictionary],
	side_faces: Array[Dictionary],
	p_boundary_breakpoints: Dictionary
) -> PackedVector3Array:
	var vertices := PackedVector3Array()
	for triangle: Dictionary in triangle_records(
		top_faces,
		side_faces,
		p_boundary_breakpoints
	):
		var points: PackedVector3Array = triangle["points"]
		vertices.append_array(points)
	return vertices


## Build collision triangles for the complete terrain when explicitly requested.
##
## Full-board callers are limited to import/load and deterministic verification;
## interactive editing uses collision_faces_for() with dirty chunks only.
static func build_collision_faces(
	terrain: TerrainMesh,
	chunk_cells: int = DEFAULT_CHUNK_CELLS
) -> PackedVector3Array:
	if terrain == null or terrain.is_empty():
		return PackedVector3Array()
	var top_faces: Array[Dictionary] = []
	var side_faces: Array[Dictionary] = []
	var faces := terrain.terrain_faces(chunk_cells)
	for face: Dictionary in faces:
		if int(face["kind"]) == TerrainMesh.FaceKind.TOP:
			top_faces.append(face)
		else:
			side_faces.append(face)
	return collision_faces_for(
		top_faces,
		side_faces,
		boundary_breakpoints(faces)
	)
