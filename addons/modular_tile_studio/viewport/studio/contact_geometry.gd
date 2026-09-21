@tool
extends RefCounted

## Contact geometry behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return the stable cache key for one prop's visual contact silhouette.
static func _prop_contact_cache_key(host: MTSStudioViewport, prop: PropPlacement, asset: TileAsset) -> String:
	return "%s|%s|%s|field=%.6f" % [
		asset.asset_id,
		prop.orientation_key(),
		String(asset.processing.get("generation_id", "")),
		host._contact_polygon_quantum_m(),
	]


## Return cached local contact polygons translated to this placement's canonical XZ origin.
static func _prop_contact_polygons(host: MTSStudioViewport, prop: PropPlacement, asset: TileAsset) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	if prop == null or asset == null:
		return out
	var cache_key := host._prop_contact_cache_key(prop, asset)
	var local_polygons: Array[PackedVector2Array] = []
	var cached_value: Variant = host._prop_contact_polygon_cache.get(cache_key, null)
	if cached_value != null:
		for cached_polygon: PackedVector2Array in cached_value:
			local_polygons.append(cached_polygon)
	else:
		local_polygons = host._build_local_prop_contact_polygons(prop, asset)
		if not local_polygons.is_empty():
			host._prop_contact_polygon_cache[cache_key] = local_polygons

	var translation := Vector2(float(prop.origin.x), float(prop.origin.z))
	for local_polygon: PackedVector2Array in local_polygons:
		var world_polygon := PackedVector2Array()
		for point: Vector2 in local_polygon:
			world_polygon.append(point + translation)
		out.append(world_polygon)
	return out


## Derive the visual base-contact triangles from one oriented source GLB.
static func _build_local_prop_contact_polygons(host: MTSStudioViewport,
	prop: PropPlacement,
	asset: TileAsset
) -> Array[PackedVector2Array]:
	var polygons: Array[PackedVector2Array] = []
	if prop == null:
		return polygons
	var source_model := host._prop_model_for_asset(asset)
	if source_model == null:
		return polygons
	var prop_pose := prop.orientation_transform(asset) * asset.prop_pose_transform
	var triangles: Array[PackedVector3Array] = []
	host._collect_transformed_mesh_triangles(source_model, prop_pose, triangles)
	if triangles.is_empty():
		push_error("[Tile Studio] '%s' source GLB contains no readable mesh triangles." % asset.asset_id)
		return polygons

	var lowest_y := INF
	for triangle: PackedVector3Array in triangles:
		for vertex: Vector3 in triangle:
			lowest_y = minf(lowest_y, vertex.y)
	var quantum_m := host._contact_polygon_quantum_m()
	var cutoff_y := lowest_y + MTSStudioViewport.PROP_CONTACT_BAND_M
	for triangle: PackedVector3Array in triangles:
		var clipped := host._clip_triangle_below_y(triangle, cutoff_y)
		if clipped.size() < 3:
			continue
		for index in range(1, clipped.size() - 1):
			polygons.append(PackedVector2Array([
				Vector2(clipped[0].x, clipped[0].z),
				Vector2(clipped[index].x, clipped[index].z),
				Vector2(clipped[index + 1].x, clipped[index + 1].z),
			]))
	return host._compact_contact_polygons(polygons, quantum_m)


## Return the smallest world-space contact texel used to preserve a GLB silhouette.
static func _contact_polygon_quantum_m(host: MTSStudioViewport) -> float:
	if host.world_surface_fields == null:
		return 1.0 / 16.0
	var pixel_counts := host.world_surface_fields.resolution - Vector2i.ONE
	if pixel_counts.x <= 0 or pixel_counts.y <= 0:
		push_error("[Tile Studio] contact texture resolution must exceed one pixel per axis.")
		return 1.0 / 16.0
	var pixel_size := host.world_surface_fields.world_size_xz / Vector2(pixel_counts)
	return minf(pixel_size.x, pixel_size.y)


## Merge only sub-texel source triangles into occupied contact cells before caching.
##
## Large triangles stay exact. Tiny triangles contribute their vertices and
## centroid to texel cells, so the union keeps holes and concave boundaries at
## the contact texture's actual resolution without retaining hundreds of
## thousands of distinctions the shader cannot display.
static func _compact_contact_polygons(host: MTSStudioViewport,
	polygons: Array[PackedVector2Array],
	quantum_m: float
) -> Array[PackedVector2Array]:
	var compacted: Array[PackedVector2Array] = []
	if quantum_m <= 0.0:
		push_error("[Tile Studio] contact polygon quantum must be positive.")
		return compacted
	var occupied_cells: Dictionary = {}
	for polygon: PackedVector2Array in polygons:
		if polygon.is_empty():
			continue
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		var centroid := Vector2.ZERO
		for point: Vector2 in polygon:
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.y)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.y)
			centroid += point
		if maximum.x - minimum.x > quantum_m or maximum.y - minimum.y > quantum_m:
			compacted.append(polygon)
			continue
		for point: Vector2 in polygon:
			var cell := Vector2i(
				floori(point.x / quantum_m),
				floori(point.y / quantum_m)
			)
			occupied_cells[cell] = true
		centroid /= float(polygon.size())
		occupied_cells[Vector2i(
			floori(centroid.x / quantum_m),
			floori(centroid.y / quantum_m)
		)] = true

	for cell_value: Variant in occupied_cells.keys():
		var cell: Vector2i = cell_value
		var minimum := Vector2(cell) * quantum_m
		var maximum := minimum + Vector2.ONE * quantum_m
		compacted.append(PackedVector2Array([
			minimum,
			Vector2(maximum.x, minimum.y),
			maximum,
			Vector2(minimum.x, maximum.y),
		]))
	return compacted


## Collect triangle vertices after applying the same source hierarchy and canonical prop pose used by rendering.
static func _collect_transformed_mesh_triangles(host: MTSStudioViewport,
	node: Node,
	parent_transform: Transform3D,
	out_triangles: Array[PackedVector3Array]
) -> void:
	var current_transform := parent_transform
	var spatial := node as Node3D
	if spatial != null:
		current_transform = parent_transform * spatial.transform

	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		var mesh := mesh_instance.mesh
		for surface_index in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
				push_error(
					"[Tile Studio] contact extraction requires triangle surfaces; '%s' surface %d is unsupported."
					% [mesh_instance.name, surface_index]
				)
				continue
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices_value: Variant = arrays[Mesh.ARRAY_VERTEX]
			if not vertices_value is PackedVector3Array:
				push_error(
					"[Tile Studio] contact extraction found no vertex array on '%s' surface %d."
					% [mesh_instance.name, surface_index]
				)
				continue
			var vertices: PackedVector3Array = vertices_value
			var indices := PackedInt32Array()
			var indices_value: Variant = arrays[Mesh.ARRAY_INDEX]
			if indices_value is PackedInt32Array:
				indices = indices_value
			elif indices_value != null:
				push_error(
					"[Tile Studio] contact extraction found an invalid index array on '%s' surface %d."
					% [mesh_instance.name, surface_index]
				)
				continue
			if indices.is_empty():
				for vertex_index in range(0, vertices.size() - 2, 3):
					out_triangles.append(PackedVector3Array([
						current_transform * vertices[vertex_index],
						current_transform * vertices[vertex_index + 1],
						current_transform * vertices[vertex_index + 2],
					]))
			else:
				for index_offset in range(0, indices.size() - 2, 3):
					out_triangles.append(PackedVector3Array([
						current_transform * vertices[indices[index_offset]],
						current_transform * vertices[indices[index_offset + 1]],
						current_transform * vertices[indices[index_offset + 2]],
					]))

	for child: Node in node.get_children():
		host._collect_transformed_mesh_triangles(child, current_transform, out_triangles)


## Clip one triangle against the horizontal contact-band ceiling without inventing geometry.
static func _clip_triangle_below_y(host: MTSStudioViewport, triangle: PackedVector3Array, maximum_y: float) -> PackedVector3Array:
	var output := PackedVector3Array()
	if triangle.is_empty():
		return output
	var previous := triangle[triangle.size() - 1]
	var previous_inside := previous.y <= maximum_y
	for current: Vector3 in triangle:
		var current_inside := current.y <= maximum_y
		if current_inside != previous_inside:
			var denominator := current.y - previous.y
			if not is_zero_approx(denominator):
				var ratio := (maximum_y - previous.y) / denominator
				output.append(previous.lerp(current, ratio))
		if current_inside:
			output.append(current)
		previous = current
		previous_inside = current_inside
	return output
