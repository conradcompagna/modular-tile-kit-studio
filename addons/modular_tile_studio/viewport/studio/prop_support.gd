@tool
extends RefCounted

## Prop support behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Load and cache the prop GLB explicitly selected by its persistent optimization settings.
##
## TileAsset owns the source-versus-optimized decision; the viewport must not repeat that
## decision or silently substitute the source when a required optimized artifact is missing.
static func _prop_model_for_asset(host: MTSStudioViewport, asset: TileAsset) -> Node3D:
	if asset == null:
		push_error("[Tile Studio] Cannot load a prop model for a null asset.")
		return null
	var model_path := asset.prop_model_path()
	if model_path.is_empty():
		push_error("[Tile Studio] '%s' has no selected render GLB on disk." % asset.asset_id)
		return null
	var prop_model: Node3D = host._real_mesh_cache.get(model_path, null)
	if prop_model != null:
		return prop_model
	prop_model = MTSStudioViewport.GLBImporter.new().load_model(model_path)
	if prop_model == null:
		push_error("[Tile Studio] '%s' selected render GLB failed to load: %s" % [asset.asset_id, model_path])
		return null
	host._real_mesh_cache[model_path] = prop_model
	return prop_model


## Return the exact canonical world position of one prop placement.
##
## BoardDocument owns the support calculation. The editor root consumes that answer
## directly so artwork, voxel proxy, physics, picking, and bounds have no second pose.
static func _prop_placement_base_position(host: MTSStudioViewport, prop: PropPlacement) -> Vector3:
	if prop == null or host.board == null:
		return Vector3.ZERO
	return host.board.prop_world_origin(prop)


## Return the exact canonical world position of one existing prop root.
static func _prop_base_position(host: MTSStudioViewport, root: Node3D) -> Vector3:
	if root == null or host.board == null:
		return Vector3.ZERO
	var prop := root.get_meta("mts_placement", null) as PropPlacement
	if prop == null:
		return root.position
	return host._prop_placement_base_position(prop)


## Return the editor slice containing a prop's exact world origin.
##
## This integer is only a visibility and batching address; it never positions the
## prop artwork, collision, proxy, selection bounds, or gameplay obstruction.
static func _prop_slice_level(host: MTSStudioViewport, prop: PropPlacement) -> int:
	if prop == null or host.board == null:
		return 0
	return TerrainMesh.level_of_height(host.board.prop_world_origin(prop).y)


## Apply one prop's exact canonical floor-or-wall world position.
##
## The placement root carries the complete world translation. TerrainSupport remains
## an identity grouping node for the proxy and physics children and never contributes
## another placement offset.
static func _apply_prop_support_offset(host: MTSStudioViewport, root: Node3D) -> bool:
	if root == null:
		return false
	var support_root := root.get_node_or_null("TerrainSupport") as Node3D
	if not is_instance_valid(support_root):
		push_error("[Tile Studio] prop root '%s' has no TerrainSupport child." % root.name)
		return false
	var world_position := host._prop_base_position(root)
	if (
		root.position.is_equal_approx(world_position)
		and support_root.position.is_equal_approx(Vector3.ZERO)
	):
		return false
	root.position = world_position
	support_root.position = Vector3.ZERO
	# Slice metadata is an integer lookup derived from the exact physical position.
	root.set_meta("mts_layer_y", TerrainMesh.level_of_height(world_position.y))
	host._apply_slice_to_node(root)
	var bounds_value: Variant = root.get_meta("mts_bounds", null)
	if bounds_value is AABB:
		var bounds := bounds_value as AABB
		bounds.position = world_position
		root.set_meta("mts_bounds", bounds)
	return true


## Synchronize every existing prop after terrain or derived contact inputs change.
static func _sync_prop_support_offsets(host: MTSStudioViewport) -> void:
	var affected_batch_keys: Dictionary = {}
	for root_value: Variant in host._prop_nodes_by_placement_id.values():
		var root := root_value as Node3D
		if not is_instance_valid(root):
			continue
		# Read BEFORE the pose is applied. A batch key embeds the prop's derived slice,
		# so ground that carries a prop across a slice boundary changes which batch its
		# artwork belongs to; both the old and new groups must be resynchronized.
		var previous_keys: Variant = root.get_meta("mts_batch_keys", PackedStringArray())
		if not host._apply_prop_support_offset(root):
			continue
		if previous_keys is PackedStringArray:
			for batch_key: String in previous_keys as PackedStringArray:
				affected_batch_keys[batch_key] = true
		var prop := root.get_meta("mts_placement", null) as PropPlacement
		if prop == null:
			continue
		var asset := host.board.resolve_prop_asset(prop)
		if asset == null:
			continue
		var current_keys := host._prop_batch_keys(prop, asset)
		root.set_meta("mts_batch_keys", current_keys)
		for batch_key: String in current_keys:
			affected_batch_keys[batch_key] = true
		# The node now matches the reconciled record, so refresh the snapshot the
		# incremental sync compares against instead of leaving it looking edited.
		root.set_meta("mts_spatial_signature", host._placement_spatial_signature(prop))
	if not affected_batch_keys.is_empty():
		host._sync_prop_art_batches(affected_batch_keys)
