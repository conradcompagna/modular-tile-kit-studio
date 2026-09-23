@tool
extends RefCounted

## Prop nodes behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return the world bounds occupied by one terrain surface placement.
static func _surface_bounds(host: MTSStudioViewport, surface: SurfacePlacement, _asset: TileAsset) -> AABB:
	# Bounds come from the same terrain faces the paint renders on, so selection
	# framing follows sloped and stepped ground instead of a flat rectangle.
	var terrain_points := host._placement_collision_points(surface)
	if terrain_points.is_empty():
		return AABB(Vector3(surface.origin), Vector3.ZERO)
	var terrain_bounds := AABB(terrain_points[0], Vector3.ZERO)
	for point_index: int in range(1, terrain_points.size()):
		terrain_bounds = terrain_bounds.expand(terrain_points[point_index])
	return terrain_bounds


## A prop is placed as its OWN real source mesh: no rendered card, no
## decimated shell, no separate shadow stand-in (AGENTS.md 1.2). It renders
## with its own imported GLB materials and casts/receives real Godot shadows
## from its own triangles. Visibility is determined by Godot's normal depth
## buffer. The invisible voxel proxy remains
## collision/navigation-only, where a blocky approximation is the correct
## answer. Every displayed pose is the same source mesh and the same canonical
## voxel set transformed by PropPlacement's explicit cube orientation, so turning,
## flipping, and rolling never create competing asset representations.
## Build one placement-owned spatial root while shared MultiMesh batches render the asset artwork.
static func _build_prop_node(host: MTSStudioViewport,
	prop: PropPlacement,
	asset: TileAsset
) -> Node3D:
	var root := Node3D.new()
	var reference_id := prop.asset_id
	root.name = "Prop_%s" % reference_id
	root.set_meta("mts_placement", prop)
	# The root itself owns the complete physical pose shared by every representation.
	var world_origin := host.board.prop_world_origin(prop)
	root.position = world_origin
	root.set_meta("mts_spatial_signature", host._placement_spatial_signature(prop))

	# This identity child groups proxy and physics nodes without changing their pose.
	var support_root := Node3D.new()
	support_root.name = "TerrainSupport"
	root.add_child(support_root)

	var grid_bounds := prop.oriented_bounds(asset)
	var voxels := host.board.prop_local_voxels(prop)
	var orientation_transform := prop.orientation_transform(asset)
	var generation_id := String(asset.processing.get("generation_id", ""))
	var cache_key := "%s|%s|%s|%.6f" % [
		reference_id,
		prop.orientation_key(),
		generation_id,
		host.board.movement_collision_min_triangle_share_percent,
	]

	var voxel_mesh: Mesh = host._voxel_mesh_cache.get(cache_key, null)
	if voxel_mesh == null:
		voxel_mesh = MTSStudioViewport.ProxyMeshBuilder.voxel_mesh(voxels)
		host._voxel_mesh_cache[cache_key] = voxel_mesh

	var proxy := MeshInstance3D.new()
	proxy.name = "SpatialProxy"
	proxy.mesh = voxel_mesh
	proxy.visible = false
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	support_root.add_child(proxy)

	# Real GLB artwork is emitted into shared MultiMesh batches from this same
	# exact root transform; collision, proxy, and bounds remain coincident with it.
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.set_meta("mts_placement", prop)
	for voxel in voxels:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3.ONE
		collision.shape = shape
		collision.position = Vector3(voxel) + Vector3(0.5, 0.5, 0.5)
		body.add_child(collision)
	support_root.add_child(body)

	root.set_meta("mts_layer_y", host._prop_slice_level(prop))
	root.set_meta("mts_bounds", AABB(
		root.position,
		Vector3(grid_bounds)
	))
	root.set_meta("mts_batch_keys", host._prop_batch_keys(prop, asset))
	root.set_meta(
		"mts_contact_id",
		host._prop_contact_id(prop)
		if asset != null and prop.support != PropPlacement.SUPPORT_WALL
		else ""
	)
	return root
