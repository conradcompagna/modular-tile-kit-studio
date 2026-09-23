@tool
extends RefCounted

## Material profiles behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Assign one palette entry to every terrain face without accepting a partial pass.
static func assign_material_palette_to_all_faces(host: MTSStudioViewport, palette_index: int) -> Dictionary:
	if host.terrain_renderer == null or host.surface_material_paint == null:
		return {"error": ERR_UNCONFIGURED, "face_uid": "", "patches": {}}
	return host.surface_material_paint.assign_palette_to_faces(
		palette_index,
		host.terrain_renderer.paint_uids()
	)


## Recreate every terrain material after a level-wide material invalidation.
##
## This is intentionally the exceptional path: terrain lifecycle rebuilds and
## board-wide asset removal can invalidate every batch at once. Ordinary profile
## controls, mask choices, splatmap settings, and single-asset edits use the
## scoped functions below and preserve existing ShaderMaterial instances.
static func refresh_material_blend_materials(host: MTSStudioViewport) -> void:
	if host.surface_material_paint != null:
		host.surface_material_paint.bind_profile(
			host.board.material_blend if host.board != null else null
		)
	host._refresh_material_mask_ranges(false)
	host._apply_terrain_material()
	host.request_render()


## Apply one committed profile change with the narrowest valid live-material update.
##
## Scalar and mask edits change uniforms in place. Texture recipes are rebound only
## on batches where canonical paint actually uses the changed palette entry. The
## optional import flag preserves a source projection that was validated atomically
## before the profile was installed.
static func refresh_material_profile_change(host: MTSStudioViewport,
	before_json: Dictionary,
	splatmap_projection_already_valid: bool = false
) -> bool:
	if host.board == null or host.board.material_blend == null or host.material_factory == null:
		push_error("[Tile Studio] Cannot refresh a material profile without an active board and factory.")
		return false
	var before_profile := MaterialBlendProfile.new()
	before_profile.from_json(before_json)
	var after_profile := host.board.material_blend
	var after_json := after_profile.to_json().duplicate(true)
	if host.surface_material_paint != null:
		host.surface_material_paint.bind_profile(after_profile)

	var before_layers_value: Variant = before_json.get("layers", [])
	var after_layers_value: Variant = after_json.get("layers", [])
	var before_layers: Array = before_layers_value as Array if before_layers_value is Array else []
	var after_layers: Array = after_layers_value as Array if after_layers_value is Array else []
	var texture_rebind_candidates: Dictionary = {}
	var control_only_indices: PackedInt32Array = PackedInt32Array()
	for layer_index: int in maxi(before_layers.size(), after_layers.size()):
		var before_layer: Dictionary = (
			(before_layers[layer_index] as Dictionary)
			if layer_index < before_layers.size() and before_layers[layer_index] is Dictionary
			else {}
		)
		var after_layer: Dictionary = (
			(after_layers[layer_index] as Dictionary)
			if layer_index < after_layers.size() and after_layers[layer_index] is Dictionary
			else {}
		)
		if before_layer == after_layer:
			continue
		var introduces_world_height := (
			not MTSStudioViewport._material_layer_uses_world_height(before_layer)
			and MTSStudioViewport._material_layer_uses_world_height(after_layer)
		)
		if (
			MTSStudioViewport._material_layer_requires_texture_rebind(before_layer, after_layer)
			or introduces_world_height
		):
			texture_rebind_candidates[layer_index] = true
		else:
			control_only_indices.append(layer_index)

	var reconfigure_every_material := (
		int(before_profile.debug_view) != MaterialBlendProfile.DebugView.WORLD_HEIGHT
		and int(after_profile.debug_view) == MaterialBlendProfile.DebugView.WORLD_HEIGHT
	)
	if (
		not before_profile.uses_world_height()
		and after_profile.uses_world_height()
		and host.material_mask_preview_enabled
		and host.material_mask_preview_palette_index < after_profile.layer_count()
		and MTSStudioViewport._material_layer_uses_world_height(
			after_profile.layer(host.material_mask_preview_palette_index)
		)
	):
		reconfigure_every_material = true
	if not before_profile.enabled and after_profile.enabled:
		for used_index: int in host._used_palette_indices_for_profile(after_profile):
			texture_rebind_candidates[used_index] = true

	if reconfigure_every_material:
		host._reconfigure_existing_material_blends()
	elif not texture_rebind_candidates.is_empty():
		var used_indices: Dictionary = {}
		for used_index: int in host._used_palette_indices_for_profile(before_profile):
			used_indices[used_index] = true
		for used_index: int in host._used_palette_indices_for_profile(after_profile):
			used_indices[used_index] = true
		var indices_to_rebind := PackedInt32Array()
		var ordered_candidates := texture_rebind_candidates.keys()
		ordered_candidates.sort()
		for index_value: Variant in ordered_candidates:
			var palette_index := int(index_value)
			if used_indices.has(palette_index):
				indices_to_rebind.append(palette_index)
		if not indices_to_rebind.is_empty():
			host._reconfigure_existing_material_blends(indices_to_rebind)

	for layer_index: int in control_only_indices:
		if layer_index >= 0 and layer_index < after_profile.layer_count():
			host.refresh_material_blend_layer_controls(layer_index)

	for material: ShaderMaterial in host._all_surface_shader_materials():
		material.set_shader_parameter("material_blend_enabled", after_profile.enabled)
		material.set_shader_parameter("material_blend_mode", int(after_profile.blend_mode))
		material.set_shader_parameter("material_debug_view", int(after_profile.debug_view))
		host.material_factory.configure_splatmap_channel_strengths(material, after_profile)
		host._apply_material_mask_preview_to_material(material)

	var source_projection_changed := false
	for key: String in [
		"splatmap_source_path",
		"splatmap_palette_indices",
		"splatmap_projection",
		"splatmap_fill_empty_regions",
		"splatmap_empty_region_channel",
	]:
		if before_json.get(key, null) != after_json.get(key, null):
			source_projection_changed = true
			break
	var overlay_changed := (
		bool(before_json.get("splatmap_overlay_enabled", false))
		!= after_profile.splatmap_overlay_enabled
	)
	if source_projection_changed and not splatmap_projection_already_valid:
		host._invalidate_splatmap_projection()
		if (
			not after_profile.splatmap_source_path.is_empty()
			and not host._ensure_splatmap_projection()
		):
			return false
	if source_projection_changed or overlay_changed:
		if (
			after_profile.splatmap_overlay_enabled
			and not after_profile.splatmap_source_path.is_empty()
			and not host._ensure_splatmap_projection()
		):
			return false
		host._refresh_splatmap_material_controls()

	if (
		bool(before_json.get("auto_texture_thin_side_slivers", false))
		!= after_profile.auto_texture_thin_side_slivers
	):
		host.refresh_thin_side_texture_seeds()
	host.request_render()
	return true


## Return whether one layer edit changes textures, enablement, or application ownership.
static func _material_layer_requires_texture_rebind(
	before_layer: Dictionary,
	after_layer: Dictionary
) -> bool:
	for key: String in ["enabled", "asset_id", "application_mode"]:
		if before_layer.get(key, null) != after_layer.get(key, null):
			return true
	return false


## Return whether one stored layer recipe consumes the world-height field.
static func _material_layer_uses_world_height(material_layer: Dictionary) -> bool:
	if not bool(material_layer.get("enabled", false)):
		return false
	var rules_value: Variant = material_layer.get("masks", [])
	if not rules_value is Array:
		return false
	for rule_value: Variant in rules_value as Array:
		if (
			rule_value is Dictionary
			and int((rule_value as Dictionary).get("source", -1))
			== MaterialBlendProfile.MaskSource.WORLD_HEIGHT
		):
			return true
	return false


## Resolve visible palette entries against one candidate recipe without rebinding it globally.
static func _used_palette_indices_for_profile(host: MTSStudioViewport,
	candidate_profile: MaterialBlendProfile
) -> PackedInt32Array:
	if host.surface_material_paint == null:
		return PackedInt32Array()
	return host.surface_material_paint.used_palette_indices_for_profile(candidate_profile)


## Rebind PBR textures and shader features on existing materials that use selected palette entries.
##
## An empty filter means every live material genuinely requires a shader-feature
## transition. Material objects, terrain meshes, collision, and control images remain resident.
static func _reconfigure_existing_material_blends(host: MTSStudioViewport,
	palette_indices: PackedInt32Array = PackedInt32Array()
) -> void:
	if host.board == null or host.board.material_blend == null or host.material_factory == null:
		return
	var filter_indices: Dictionary = {}
	for palette_index: int in palette_indices:
		filter_indices[palette_index] = true
	for material: ShaderMaterial in host._all_surface_shader_materials():
		var slots_value: Variant = material.get_meta(
			SurfaceMaterialFactory.SURFACE_BLEND_SLOT_MATERIALS_META,
			PackedInt32Array()
		)
		var slots: PackedInt32Array = (
			slots_value as PackedInt32Array
			if slots_value is PackedInt32Array
			else PackedInt32Array()
		)
		if not filter_indices.is_empty():
			var matches_filter := false
			for palette_index: int in slots:
				if filter_indices.has(palette_index):
					matches_filter = true
					break
			if not matches_filter:
				continue
		var is_top := bool(material.get_shader_parameter("terrain_grid_is_top"))
		var control_texture := (
			material.get_shader_parameter("material_control_tex") as Texture2DArray
		)
		host.material_factory.configure_material_blend(
			material,
			control_texture,
			host.board.material_blend,
			host.library,
			host._material_world_height_range,
			host._material_world_elevation_range,
			slots
		)
		host._apply_material_mask_preview_to_material(material)
		host._configure_terrain_grid_material(material, is_top)


## Refresh source-overlay and strength uniforms without replacing terrain materials.
static func _refresh_splatmap_material_controls(host: MTSStudioViewport) -> void:
	if host.board == null or host.board.material_blend == null or host.material_factory == null:
		return
	for material: ShaderMaterial in host._all_surface_shader_materials():
		host.material_factory.configure_splatmap_channel_strengths(
			material,
			host.board.material_blend
		)
		host._configure_terrain_grid_material(
			material,
			bool(material.get_shader_parameter("terrain_grid_is_top"))
		)


## Re-resolve only terrain material batches after changing thin side-strip seeding.
##
## This updates direct PNG grouping and derived splat-array source links across the
## board without rebuilding canonical terrain geometry, collision, or gameplay state.
static func refresh_thin_side_texture_seeds(host: MTSStudioViewport) -> void:
	if host.board == null or host.terrain_renderer == null:
		return
	var terrain_cells := host.board.terrain.filled_bounds_cells()
	if terrain_cells.size.x <= 0 or terrain_cells.size.y <= 0:
		return
	var changed_chunks := host.terrain_renderer.refresh_paint_for_cells(
		terrain_cells,
		host.surface_material_paint,
		host.board
	)
	host._apply_terrain_material_chunks(changed_chunks)
	host.request_render()


## Update one layer's live scalar and mask uniforms without recreating batch materials or reloading PBR maps.
static func refresh_material_blend_layer_controls(host: MTSStudioViewport, layer_index: int) -> void:
	if host.board == null or host.board.material_blend == null or host.material_factory == null:
		push_error("[Tile Studio] Cannot refresh material controls without an active board and factory.")
		return
	if layer_index < 0 or layer_index >= host.board.material_blend.layer_count():
		push_error(
			"[Tile Studio] Material palette index %d is outside 0..%d."
			% [layer_index, host.board.material_blend.layer_count() - 1]
		)
		return
	if host.surface_material_paint != null:
		host.surface_material_paint.bind_profile(host.board.material_blend)
	for material: ShaderMaterial in host._all_surface_shader_materials():
		host.material_factory.configure_material_layer_controls(
			material,
			layer_index,
			host.board.material_blend,
			host.library
		)
		# The preview recipe is independent of authored face slots and must follow
		# live mask-slider edits even on faces that do not carry this palette entry.
		host._apply_material_mask_preview_to_material(material)
	host.request_render()


## Clear only authored material-control pixels and optionally register their sparse undo patch.
static func clear_surface_material_paint(host: MTSStudioViewport, record_undo: bool = false) -> void:
	if host.surface_material_paint == null:
		return
	var patches := host.surface_material_paint.clear_all_paint()
	if host.board != null:
		host.board.surface_material_paint.clear()
	host.request_render()
	if record_undo and host._height_undo_redo != null and not patches.is_empty():
		host._height_undo_redo.create_action(
			"Clear brush material paint",
			UndoRedo.MERGE_DISABLE,
			null,
			false
		)
		host._height_undo_redo.add_do_method(host, "clear_surface_material_paint", false)
		host._height_undo_redo.add_undo_method(host, "_apply_material_paint_patch", patches, "before")
		host._height_undo_redo.commit_action(false)
