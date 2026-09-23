@tool
extends RefCounted

## Splatmap import behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return or append the brush palette entry selected for one splatmap channel.
static func _palette_index_for_splat_asset(host: MTSStudioViewport,
	profile: MaterialBlendProfile,
	asset_id: String
) -> int:
	for palette_index: int in profile.layer_count():
		var layer := profile.layer(palette_index)
		if (
			String(layer.get("asset_id", "")) == asset_id
			and int(layer.get("application_mode", -1))
			== MaterialBlendProfile.ApplicationMode.BRUSH
		):
			return palette_index
	for palette_index: int in profile.layer_count():
		if String(profile.layer(palette_index).get("asset_id", "")).is_empty():
			return palette_index
	return profile.add_layer(MaterialBlendProfile.default_layer(profile.layer_count()))


## Load one directional RGBA control source and assign its four visible material slots.
##
## Loading prepares the optional base-filled source and guide texture, but deliberately leaves
## canonical terrain paint untouched until the base-coat brush or whole-terrain action runs.
static func import_terrain_splatmap(host: MTSStudioViewport,
	source_image: Image,
	slot_asset_ids: PackedStringArray,
	source_path: String
) -> Dictionary:
	if (
		host.board == null
		or host.board.material_blend == null
		or host.surface_material_paint == null
		or host.terrain_renderer == null
	):
		push_error("[Tile Studio] Cannot load a splatmap without active terrain and paint state.")
		return {"error": ERR_UNCONFIGURED}
	if slot_asset_ids.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("[Tile Studio] Splatmap loading requires exactly four visible slot assignments.")
		return {"error": ERR_INVALID_PARAMETER}
	if source_path.is_empty() or not FileAccess.file_exists(source_path):
		push_error("[Tile Studio] Splatmap loading requires its visible source image path.")
		return {"error": ERR_FILE_NOT_FOUND}
	var before_json := host.board.material_blend.to_json().duplicate(true)
	var target_profile := MaterialBlendProfile.new()
	target_profile.from_json(before_json)
	var active_channels := PackedByteArray([0, 0, 0, 0])
	var splatmap_palette_indices := PackedInt32Array([-1, -1, -1, -1])
	var has_active_splat_slot := false
	# Literal RGBA channels point into the unbounded board palette without
	# overwriting its first four entries. Painting the splatmap later installs this
	# exact mapping on each targeted face alongside the replacement RGBA weights.
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var asset_id := slot_asset_ids[channel_index]
		if asset_id.is_empty():
			continue
		var asset := host.library.get_asset(asset_id) if host.library != null else null
		if asset == null or not asset.is_surface():
			push_error(
				"[Tile Studio] Splatmap slot %d requires a valid PNG surface asset '%s'."
				% [channel_index + 1, asset_id]
			)
			return {"error": ERR_INVALID_DATA}
		var palette_index := host._palette_index_for_splat_asset(target_profile, asset_id)
		var layer := MaterialBlendProfile.default_layer(palette_index)
		layer["asset_id"] = asset_id
		layer["application_mode"] = MaterialBlendProfile.ApplicationMode.BRUSH
		layer["enabled"] = true
		layer["opacity_percent"] = 100.0
		layer["masks"] = [
			MaterialBlendProfile.default_rule(
				MaterialBlendProfile.MaskSource.PAINT,
				palette_index
			)
		]
		target_profile.set_layer(palette_index, layer)
		splatmap_palette_indices[channel_index] = palette_index
		active_channels[channel_index] = 1
		has_active_splat_slot = true
	target_profile.splatmap_palette_indices = splatmap_palette_indices
	target_profile.enabled = target_profile.has_active_layers()
	target_profile.blend_mode = MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
	target_profile.splatmap_source_path = source_path
	target_profile.splatmap_mode_enabled = true
	target_profile.splatmap_overlay_enabled = false
	target_profile.debug_view = MaterialBlendProfile.DebugView.FINAL_MATERIAL
	if not has_active_splat_slot:
		push_error("[Tile Studio] Splatmap loading needs at least one assigned material slot.")
		return {"error": ERR_INVALID_PARAMETER}
	var projection_face := MTSStudioViewport._splatmap_face_for_projection(target_profile.splatmap_projection)
	var targets := host.terrain_renderer.splatmap_targets(projection_face)
	# Validate the projection against the live terrain before the profile is replaced,
	# so a control image that cannot be projected leaves the current materials intact.
	var bounds_result := host.surface_material_paint.splatmap_terrain_bounds(targets)
	if int(bounds_result.get("error", FAILED)) != OK:
		return {"error": int(bounds_result.get("error", FAILED))}
	var prepared_source := host.surface_material_paint.prepare_splatmap_source(
		source_image,
		active_channels,
		target_profile.splatmap_fill_empty_regions,
		target_profile.splatmap_empty_region_channel
	)
	if prepared_source == null:
		return {"error": ERR_CANT_CREATE}
	var projection_cache := host._build_splatmap_projection_cache(
		prepared_source,
		targets,
		bounds_result,
		active_channels
	)
	if projection_cache.is_empty():
		return {"error": ERR_CANT_CREATE}
	var after_json := target_profile.to_json().duplicate(true)
	host.board.material_blend.from_json(after_json)
	host.surface_material_paint.bind_profile(host.board.material_blend)
	# Install the already validated cache only after the profile commit, so a failed
	# source or projection never exposes a partially changed material configuration.
	host._install_splatmap_projection_cache(projection_cache)
	if not host.refresh_material_profile_change(before_json, true):
		push_error("[Tile Studio] The validated splatmap profile could not refresh live materials.")
		host.board.material_blend.from_json(before_json)
		if not host.refresh_material_profile_change(after_json):
			push_error("[Tile Studio] The previous material profile could not be restored visibly.")
		return {"error": ERR_CANT_CREATE}
	host.material_profile_replayed.emit(after_json.duplicate(true))
	host.register_material_profile_undo(
		before_json,
		after_json,
		"Load terrain RGBA splatmap"
	)
	host.request_render()
	return {
		"error": OK,
		"terrain_bounds": host._splatmap_terrain_bounds,
		"face_count": int(bounds_result.get("face_count", 0)),
	}


## Paint every indexed face in the selected projection as one base-coat action.
##
## The action replaces all four RGBA weights only on that visible direction and uses the same
## sparse stroke history as ordinary square-brush base-coat painting.
static func paint_entire_terrain_from_splatmap(host: MTSStudioViewport) -> bool:
	if not host._ensure_splatmap_projection() or host.surface_material_paint == null:
		push_error("[Tile Studio] Load an RGBA splatmap before painting the entire terrain.")
		return false
	host._end_terrain_material_tile_stroke()
	host.surface_material_paint.begin_stroke()
	var changed := false
	for target: Dictionary in host._splatmap_targets:
		var uid := String(target.get("uid", ""))
		var projection_cell: Vector2i = target.get("projection_cell", Vector2i.ZERO)
		var weights := host._splatmap_tile_weights(projection_cell)
		if (
			weights != null
			and host.surface_material_paint.stamp_splatmap_tile(
				uid,
				weights,
				host.board.material_blend.splatmap_palette_indices,
				false
			)
		):
			changed = true
	var stroke := host.surface_material_paint.finish_stroke()
	host._register_material_paint_undo(stroke, "Paint entire terrain from RGBA splatmap")
	if changed:
		host.request_render()
	return true
