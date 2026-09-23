@tool
extends RefCounted

## Asset updates behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Synchronize an externally committed board mutation through incremental derived state.
static func refresh_board_changes(host: MTSStudioViewport) -> void:
	host._sync_board_incremental()


## Refresh only placements and render batches that consume one edited asset.
##
## Geometry edits invalidate that asset's cached GLB source and mark its spatial
## roots stale. Material-only edits retain collision nodes and reconfigure only
## the matching surface or prop batches.
static func refresh_asset_instances(host: MTSStudioViewport,
	asset_id: String,
	geometry_changed: bool = false
) -> void:
	if host.board == null or host.library == null or asset_id.is_empty():
		return
	var asset := host.library.get_asset(asset_id)
	if geometry_changed and asset != null:
		# Either authored path may have been selected before this change, so invalidate
		# both exact cache entries while leaving every unrelated GLB resident.
		host._real_mesh_cache.erase(asset.source_path)
		host._real_mesh_cache.erase(asset.prop_runtime_path)
		host._prop_mesh_components_cache.clear()
		host._prop_render_mesh_cache.clear()
		host._prop_contact_polygon_cache.clear()

	var affected_prop_batch_keys: Dictionary = {}
	var stale_spatial_root := false
	var terrain_material_changed := false
	for layer_index: int in host.board.material_blend.layer_count():
		if String(host.board.material_blend.layer(layer_index).get("asset_id", "")) == asset_id:
			terrain_material_changed = true
	for surface: SurfacePlacement in host.board.surfaces:
		if surface.asset_id != asset_id:
			continue
		if not surface.terrain_face_uids.is_empty():
			terrain_material_changed = true
		var node := host._surface_nodes_by_placement_id.get(
			surface.get_instance_id(),
			null
		) as Node3D
		if geometry_changed and is_instance_valid(node):
			node.set_meta("mts_spatial_signature", "stale-asset")
			stale_spatial_root = true
		elif is_instance_valid(node) and surface.is_decal() and asset != null:
			# A native Decal holds its textures and mix values on the node itself
			# rather than reading a material, and only a geometry change rebuilds
			# that node. Without this, an edit to the asset's maps, strengths, or
			# biases would leave every placed decal showing its creation-time state.
			var projector := node.get_node_or_null("Projection") as Decal
			if projector != null:
				host._configure_native_decal(projector, surface, asset)

	for prop: PropPlacement in host.board.props:
		if prop.asset_id != asset_id:
			continue
		var node := host._prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if not is_instance_valid(node):
			continue
		for batch_key: String in (
			node.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		):
			affected_prop_batch_keys[batch_key] = true
		if geometry_changed:
			node.set_meta("mts_spatial_signature", "stale-asset")
			stale_spatial_root = true

	if stale_spatial_root:
		host._sync_board_incremental()
	if not affected_prop_batch_keys.is_empty() and not geometry_changed:
		host._sync_prop_art_batches(affected_prop_batch_keys)
	if terrain_material_changed:
		# The factory cache was invalidated before this call, so only terrain
		# surfaces that visibly consume this asset need new batch materials.
		host._refresh_terrain_materials_for_asset(asset_id)
	host._emit_status()
	host.request_render()


## Recreate only terrain batch materials that visibly consume one edited asset.
static func _refresh_terrain_materials_for_asset(host: MTSStudioViewport, asset_id: String) -> void:
	if (
		asset_id.is_empty()
		or host.terrain_renderer == null
		or host.board == null
		or host.board.material_blend == null
	):
		return
	var used_palette_indices: Dictionary = {}
	for palette_index: int in host._used_palette_indices_for_profile(host.board.material_blend):
		used_palette_indices[palette_index] = true
	for chunk_value: Variant in host.terrain_renderer.chunks():
		var chunk := chunk_value as Vector2i
		for surface: Dictionary in host.terrain_renderer.chunk_surfaces(chunk):
			if not host._terrain_surface_uses_asset(
				surface,
				asset_id,
				used_palette_indices
			):
				continue
			var material := host._terrain_surface_material(chunk, surface)
			if material == null:
				continue
			host.terrain_renderer.set_chunk_surface_material(
				chunk,
				int(surface["surface_index"]),
				material
			)


## Return whether one terrain surface visibly consumes the selected base, layer, or decal asset.
static func _terrain_surface_uses_asset(host: MTSStudioViewport,
	surface: Dictionary,
	asset_id: String,
	used_palette_indices: Dictionary
) -> bool:
	if String(surface.get("asset_id", "")) == asset_id:
		return true
	var shader_decal := surface.get("shader_decal", null) as SurfacePlacement
	if shader_decal != null and shader_decal.asset_id == asset_id:
		return true
	var slots_value: Variant = surface.get("slot_materials", PackedInt32Array())
	var slots: PackedInt32Array = (
		slots_value as PackedInt32Array
		if slots_value is PackedInt32Array
		else PackedInt32Array()
	)
	if slots.is_empty():
		for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			slots.append(slot_index)
	for palette_index: int in slots:
		if (
			not used_palette_indices.has(palette_index)
			or palette_index < 0
			or palette_index >= host.board.material_blend.layer_count()
		):
			continue
		if (
			String(host.board.material_blend.layer(palette_index).get("asset_id", ""))
			== asset_id
		):
			return true
	return false


## Apply one GLB asset's current contact setting to all of its existing instances.
static func apply_asset_contact_flatten(host: MTSStudioViewport, asset_id: String) -> int:
	if host.placement == null:
		return 0
	return host.placement.apply_asset_contact_flatten(asset_id)
