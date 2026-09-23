@tool
extends RefCounted

## Picking behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Walk from a physics collider to the placement root carrying canonical metadata.
static func _placement_root_from_collider(host: MTSStudioViewport, collider: Node) -> Node3D:
	var current := collider
	while current != null and current != host.world_root:
		if current.has_meta("mts_placement"):
			return current as Node3D
		current = current.get_parent()
	return null


## Return the nearest non-negative distance from a ray to one exact box.
##
## GLB selection calls this once per occupied voxel, so empty cells inside an
## asset's broad grid bounds never become invisible selection blockers.
static func _ray_distance_to_aabb(host: MTSStudioViewport,
	ray_origin: Vector3,
	ray_direction: Vector3,
	bounds: AABB
) -> float:
	var near_distance := -INF
	var far_distance := INF
	for axis in 3:
		var origin_component := ray_origin[axis]
		var direction_component := ray_direction[axis]
		var minimum_component := bounds.position[axis]
		var maximum_component := bounds.end[axis]
		if is_zero_approx(direction_component):
			if origin_component < minimum_component or origin_component > maximum_component:
				return INF
			continue
		var first_distance := (minimum_component - origin_component) / direction_component
		var second_distance := (maximum_component - origin_component) / direction_component
		near_distance = maxf(near_distance, minf(first_distance, second_distance))
		far_distance = minf(far_distance, maxf(first_distance, second_distance))
		if near_distance > far_distance:
			return INF
	if far_distance < 0.0:
		return INF
	return maxf(near_distance, 0.0)


## Return the nearest ray distance to a placement's voxel volume at its world pose.
##
## Voxel addresses are local to the placement and world_origin is BoardDocument's
## one canonical pose for it, so picking tests the same boxes the physics shapes
## occupy rather than an integer-height copy of them.
static func _ray_distance_to_collision_voxels(host: MTSStudioViewport,
	ray_origin: Vector3,
	ray_direction: Vector3,
	voxels: Array[Vector3i],
	world_origin: Vector3 = Vector3.ZERO
) -> float:
	var closest_distance := INF
	for cell: Vector3i in voxels:
		var distance := host._ray_distance_to_aabb(
			ray_origin,
			ray_direction,
			AABB(Vector3(cell) + world_origin, Vector3.ONE)
		)
		closest_distance = minf(closest_distance, distance)
	return closest_distance


## Return one solid placement's measured voxel volume in its own local cell space.
##
## Local rather than world: there is no separate collision address space any more.
## The volume is the asset's oriented voxel scan and its position is
## _placement_collision_origin, which is the same pose the artwork is built at.
static func _placement_collision_voxels(host: MTSStudioViewport, placement_record: Resource) -> Array[Vector3i]:
	if placement_record is PropPlacement:
		return host.board.prop_local_voxels(placement_record as PropPlacement)
	return []


## Return the world position a placement's local collision voxels are measured from.
static func _placement_collision_origin(host: MTSStudioViewport, placement_record: Resource) -> Vector3:
	if placement_record is PropPlacement:
		return host.board.prop_world_origin(placement_record as PropPlacement)
	return Vector3.ZERO


## Return exact collision vertices for marquee tests and camera framing.
##
## Solid records contribute every voxel corner at the placement's canonical world
## pose, the same pose its physics shapes stand at. PNG records contribute only
## their zero-thickness quad, matching picking instead of inventing a box.
static func _placement_collision_points(host: MTSStudioViewport, placement_record: Resource) -> PackedVector3Array:
	var points := PackedVector3Array()
	if placement_record is SurfacePlacement:
		# Terrain paint contributes the real vertices of the faces it covers, so
		# marquee tests and framing match the visible art rather than a proxy quad.
		var surface := placement_record as SurfacePlacement
		var asset := host.board.resolve_surface_asset(surface)
		if asset == null or host.terrain_renderer == null:
			return points
		var preview_geometry := host.terrain_renderer.surface_preview_meshes(surface, asset)
		var terrain_mesh := preview_geometry.get("mesh", null) as Mesh
		if terrain_mesh != null:
			for point: Vector3 in terrain_mesh.get_faces():
				if not points.has(point):
					points.append(point)
		return points

	var collision_origin := host._placement_collision_origin(placement_record)
	for cell: Vector3i in host._placement_collision_voxels(placement_record):
		var minimum := Vector3(cell) + collision_origin
		var maximum := minimum + Vector3.ONE
		for x: float in [minimum.x, maximum.x]:
			for y: float in [minimum.y, maximum.y]:
				for z: float in [minimum.z, maximum.z]:
					points.append(Vector3(x, y, z))
	return points


## Return the minimal world AABB derived from a placement's exact collision points.
static func _placement_collision_aabb(host: MTSStudioViewport, placement_record: Resource) -> AABB:
	var points := host._placement_collision_points(placement_record)
	if points.is_empty():
		return AABB()
	var minimum := points[0]
	var maximum := points[0]
	for point: Vector3 in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum)


## Return the topmost visible decal whose saved projector contains one terrain hit.
##
## Receiver UIDs establish the exact terrain attachment, while the canonical
## placement transform limits selection to the projected image footprint. Reverse
## authored order makes a later decal selectable when several native decals overlap.
static func _decal_at_terrain_hit(host: MTSStudioViewport, terrain_face: Dictionary, world_point: Vector3) -> SurfacePlacement:
	if host.board == null:
		return null
	var paint_uid := String(terrain_face.get("paint_uid", ""))
	if paint_uid.is_empty():
		return null
	for surface_index: int in range(host.board.surfaces.size() - 1, -1, -1):
		var surface := host.board.surfaces[surface_index]
		if not surface.is_overlay() or not surface.terrain_face_uids.has(paint_uid):
			continue
		var visual := host._find_visual(surface)
		if visual == null or not visual.is_visible_in_tree():
			continue
		var asset := host.board.resolve_surface_asset(surface)
		if asset == null:
			continue
		var footprint := surface.canonical_footprint(asset)
		var surface_transform := SurfacePlacement.transform_for_size(
			surface.origin,
			surface.face,
			surface.rotation_quarters,
			footprint,
			surface.grid_anchor
		)
		var local_point := surface_transform.affine_inverse() * world_point
		if (
			absf(local_point.x) <= float(footprint.x) * 0.5
			and absf(local_point.y) <= float(footprint.y) * 0.5
		):
			return surface
	return null


## Ray-pick the closest visible placement from its canonical authored geometry.
##
## Solid placements use the same occupied voxels as collision. PNG surfaces and
## decals resolve from the one terrain hit, with decals limited to their projector.
static func _placement_at_pointer(host: MTSStudioViewport, mouse_pos: Vector2) -> Resource:
	if host.camera == null or host.board == null or not Rect2(Vector2.ZERO, host.size).has_point(mouse_pos):
		return null
	var ray_origin := host.camera.project_ray_origin(mouse_pos)
	var ray_direction := host.camera.project_ray_normal(mouse_pos)
	var closest_distance := INF
	var closest_placement: Resource = null
	if host.terrain_renderer != null:
		var terrain_hit := host.terrain_renderer.pick_face(ray_origin, ray_direction)
		if not terrain_hit.is_empty():
			var terrain_face: Dictionary = terrain_hit["face"]
			var terrain_point: Vector3 = terrain_hit["point"]
			var texture_surface := host._decal_at_terrain_hit(terrain_face, terrain_point)
			if texture_surface == null:
				texture_surface = host.board.surface_at_paint_uid(
					String(terrain_face["paint_uid"])
				)
			if texture_surface != null and not texture_surface.asset_id.is_empty():
				closest_distance = ray_origin.distance_to(terrain_point)
				closest_placement = texture_surface

	for prop: PropPlacement in host.board.props:
		var visual := host._find_visual(prop)
		if visual == null or not visual.is_visible_in_tree():
			continue
		var distance := host._ray_distance_to_collision_voxels(
			ray_origin,
			ray_direction,
			host._placement_collision_voxels(prop),
			host._placement_collision_origin(prop)
		)
		if distance < closest_distance:
			closest_distance = distance
			closest_placement = prop

	# Terrain paint owns no independent ray geometry. It is selected through the
	# terrain hit resolved above, which names the exact painted face.
	return closest_placement
