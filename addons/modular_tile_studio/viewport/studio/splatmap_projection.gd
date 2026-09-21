@tool
extends RefCounted

## Splatmap projection behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return the currently stored projection face used by preview, brush sampling, and overlay.
static func _splatmap_projection_face(host: MTSStudioViewport) -> int:
	if host.board == null or host.board.material_blend == null:
		return MTSStudioViewport.K.Face.POS_Y
	return MTSStudioViewport._splatmap_face_for_projection(host.board.material_blend.splatmap_projection)


## Return whether the live terrain contains at least one face in a proposed visible direction.
static func splatmap_projection_available(host: MTSStudioViewport, projection: int) -> bool:
	if host.terrain_renderer == null:
		return false
	return not host.terrain_renderer.splatmap_targets(
		MTSStudioViewport._splatmap_face_for_projection(projection)
	).is_empty()


## Rebuild the source cache and update only overlay uniforms after projection changes.
static func refresh_splatmap_projection(host: MTSStudioViewport) -> bool:
	host._end_terrain_material_tile_stroke()
	host._invalidate_splatmap_projection()
	var projected := host._ensure_splatmap_projection()
	if host.splatmap_tile_paint_enabled:
		host._refresh_terrain_material_tile_targeter()
	if projected:
		host._refresh_splatmap_material_controls()
	host.request_render()
	return projected


## Apply main-panel splatmap controls immediately without rebuilding canonical paint images.
##
## Empty-region extension rebuilds only the active source guide and future brush sampler.
## Strength changes update shader uniforms in place, so already-painted terrain responds live.
static func refresh_splatmap_live_settings(host: MTSStudioViewport, rebuild_source: bool) -> bool:
	if (
		host.board == null
		or host.board.material_blend == null
		or host.material_factory == null
		or host.surface_material_paint == null
	):
		return false
	host.surface_material_paint.bind_profile(host.board.material_blend)
	if rebuild_source:
		host._invalidate_splatmap_projection()
		if (
			not host.board.material_blend.splatmap_source_path.is_empty()
			and not host._ensure_splatmap_projection()
		):
			return false
	host._refresh_splatmap_material_controls()
	host.request_render()
	return true


## Discard the cached control projection after the terrain or its visible inputs change.
static func _invalidate_splatmap_projection(host: MTSStudioViewport) -> void:
	host._splatmap_source_image = null
	host._splatmap_source_texture = null
	host._splatmap_targets.clear()
	host._splatmap_target_by_uid.clear()
	host._splatmap_terrain_bounds = Rect2i()
	host._splatmap_channel_mask = Vector4.ONE
	host._splatmap_source_valid = false


## Return which of the four channels currently own an assigned, enabled material.
##
## Painting and the guide overlay both read this, so an unassigned slot can never
## contribute weight in one of them while staying visible in the other.
static func _splatmap_active_channels(host: MTSStudioViewport) -> PackedByteArray:
	var active_channels := PackedByteArray([0, 0, 0, 0])
	if host.board == null or host.board.material_blend == null:
		return active_channels
	# Splatmap mode alone has literal R/G/B/A identities; each channel names the
	# palette entry selected in its visible setup dialog.
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var palette_index := host.board.material_blend.splatmap_palette_indices[channel_index]
		if palette_index < 0 or palette_index >= host.board.material_blend.layer_count():
			continue
		var layer := host.board.material_blend.layer(palette_index)
		if (
			bool(layer.get("enabled", false))
			and not String(layer.get("asset_id", "")).is_empty()
		):
			active_channels[channel_index] = 1
	return active_channels


## Build a complete directional projection cache without mutating the live board state.
##
## Import uses this before committing its material profile so invalid faces or a failed guide
## texture leave the previous authored setup intact.
static func _build_splatmap_projection_cache(host: MTSStudioViewport,
	prepared_source: Image,
	targets: Array[Dictionary],
	bounds_result: Dictionary,
	active_channels: PackedByteArray
) -> Dictionary:
	var bounds_value: Variant = bounds_result.get("terrain_bounds", null)
	if (
		int(bounds_result.get("error", FAILED)) != OK
		or not bounds_value is Rect2i
		or active_channels.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
	):
		return {}
	var indexed_targets: Array[Dictionary] = []
	var target_by_uid: Dictionary = {}
	for target: Dictionary in targets:
		var uid := String(target.get("uid", ""))
		var cell_value: Variant = target.get("projection_cell", null)
		var grid_value: Variant = target.get("grid_cell", null)
		if uid.is_empty() or not cell_value is Vector2i or not grid_value is Vector3i:
			push_error("[Tile Studio] Splatmap projection has an invalid terrain target.")
			return {}
		var indexed_target := target.duplicate(true)
		indexed_targets.append(indexed_target)
		target_by_uid[uid] = indexed_target
	# The guide samples the same prepared image as authored strokes, so preview and paint
	# cannot disagree about empty-region extension or source texel weights.
	var source_texture := ImageTexture.create_from_image(prepared_source)
	if source_texture == null:
		push_error("[Tile Studio] The prepared splatmap guide texture could not be created.")
		return {}
	return {
		"source_image": prepared_source,
		"source_texture": source_texture,
		"terrain_bounds": bounds_value,
		"targets": indexed_targets,
		"target_by_uid": target_by_uid,
		"channel_mask": Vector4(
			float(active_channels[0]),
			float(active_channels[1]),
			float(active_channels[2]),
			float(active_channels[3])
		),
	}


## Install one previously validated projection cache as the active preview and brush source.
static func _install_splatmap_projection_cache(host: MTSStudioViewport, cache: Dictionary) -> void:
	host._invalidate_splatmap_projection()
	host._splatmap_source_image = cache["source_image"]
	host._splatmap_source_texture = cache["source_texture"]
	host._splatmap_terrain_bounds = cache["terrain_bounds"]
	host._splatmap_targets.assign(cache["targets"])
	host._splatmap_target_by_uid = cache["target_by_uid"]
	host._splatmap_channel_mask = cache["channel_mask"]
	host._splatmap_source_valid = true


## Project the saved control image across the current terrain's directional face rectangle.
##
## This resolves the prepared source, its exact directional bounds, and stable face-UID
## records. It produces no tile weights, so arming scales only with matching terrain faces.
static func _ensure_splatmap_projection(host: MTSStudioViewport) -> bool:
	if host._splatmap_source_valid:
		return true
	if (
		host.board == null
		or host.board.material_blend == null
		or host.terrain_renderer == null
		or host.surface_material_paint == null
	):
		return false
	var source_path := host.board.material_blend.splatmap_source_path
	if source_path.is_empty():
		return false
	if not FileAccess.file_exists(source_path):
		push_error(
			"[Tile Studio] Splatmap control image is missing: '%s'." % source_path
		)
		return false
	var source := Image.new()
	var load_error := source.load(source_path)
	if load_error != OK:
		push_error(
			"[Tile Studio] Splatmap control image '%s' could not be loaded (%s)."
			% [source_path, error_string(load_error)]
		)
		return false
	var active_channels := host._splatmap_active_channels()
	var prepared_source := host.surface_material_paint.prepare_splatmap_source(
		source,
		active_channels,
		host.board.material_blend.splatmap_fill_empty_regions,
		host.board.material_blend.splatmap_empty_region_channel
	)
	if prepared_source == null:
		host._invalidate_splatmap_projection()
		return false
	var projection_face := host._splatmap_projection_face()
	var targets := host.terrain_renderer.splatmap_targets(projection_face)
	var bounds_result := host.surface_material_paint.splatmap_terrain_bounds(targets)
	var projection_cache := host._build_splatmap_projection_cache(
		prepared_source,
		targets,
		bounds_result,
		active_channels
	)
	if projection_cache.is_empty():
		host._invalidate_splatmap_projection()
		return false
	host._install_splatmap_projection_cache(projection_cache)
	return true


## Return the RGBA weights one directional projection cell takes from the control image.
static func _splatmap_tile_weights(host: MTSStudioViewport, projection_cell: Vector2i) -> Image:
	if not host._splatmap_source_valid or host.surface_material_paint == null:
		return null
	return host.surface_material_paint.build_splatmap_tile(
		host._splatmap_source_image,
		host._splatmap_terrain_bounds,
		projection_cell,
		host._splatmap_active_channels()
	)
