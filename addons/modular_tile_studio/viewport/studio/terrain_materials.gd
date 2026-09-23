@tool
extends RefCounted

## Terrain materials behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

# --- Live board-wide surface fields ---------------------------------------

## Rebuild every derived artifact after the canonical terrain changed.
##
## This explicit whole-board path is reserved for load/import/clear so the
## visible mesh, GPU material projection, and collision begin from one snapshot.
static func refresh_terrain(host: MTSStudioViewport) -> void:
	if host.board == null:
		return
	host._invalidate_splatmap_projection()
	if host.terrain_renderer != null:
		# Geometry, collision and the paintable 1 m units are rebuilt together from
		# the same faces, so the surface on screen, the surface a token collides
		# with and the surface a brush writes into cannot diverge.
		host.terrain_renderer.rebuild(
			host.board.terrain,
			host.terrain_chunk_cells(),
			host.surface_material_paint,
			host.board
		)
		host._apply_terrain_material()
	if host.world_surface_fields != null:
		# Material percentage masks consume the same projected corners used by the
		# visible terrain mesh.
		host.world_surface_fields.project_terrain(host.board.terrain)
	host._sync_prop_support_offsets()
	host._refresh_material_mask_ranges(true)
	host.terrain_changed.emit()
	host.request_render()


## Change the authored skirt depth and rebuild only chunks that own boundary shell faces.
##
## The absolute base remains derived from the live lowest terrain point, so this
## control changes shell thickness without creating a second spatial truth.
static func set_terrain_skirt_depth(host: MTSStudioViewport, depth_m: float) -> void:
	if host.board == null or host.board.terrain == null:
		return
	if not is_finite(depth_m) or depth_m <= 0.0:
		push_error("Terrain skirt depth must be a positive finite distance.")
		return
	if is_equal_approx(host.board.terrain.skirt_depth_m, depth_m):
		return
	host.board.terrain.skirt_depth_m = depth_m
	if host.terrain_renderer != null:
		var changed_chunks := host.terrain_renderer.refresh_visual_chunks(
			host.board.terrain,
			host.terrain_renderer.boundary_chunks(),
			host.surface_material_paint,
			host.board
		)
		host.terrain_renderer.finalize_collision_chunks(changed_chunks)
		host._apply_terrain_material_chunks(changed_chunks)
	host.board.board_changed.emit()
	host.terrain_changed.emit()
	host.request_render()


## Apply the board's chosen ground material to the terrain surface.
##
## The terrain deliberately resolves its material through the same factory every
## PNG surface uses, so it inherits the project's one visible material pipeline.
static func _apply_terrain_material(host: MTSStudioViewport) -> void:
	if host.terrain_renderer == null:
		return
	var all_chunks: Array[Vector2i] = []
	for chunk_value: Variant in host.terrain_renderer.chunks():
		all_chunks.append(chunk_value as Vector2i)
	host._apply_terrain_material_chunks(all_chunks)


## Return whether the visible profile explicitly requests the source-map guide.
static func _splatmap_source_overlay_requested(host: MTSStudioViewport) -> bool:
	return (
		host.board != null
		and host.board.material_blend != null
		and host.board.material_blend.splatmap_overlay_enabled
	)


## Apply terrain materials only to the visual chunks one scoped edit changed.
static func _apply_terrain_material_chunks(host: MTSStudioViewport, chunks_to_apply: Array[Vector2i]) -> void:
	if host.terrain_renderer == null or host.material_factory == null or host.board == null:
		return
	if host._splatmap_source_overlay_requested() and not host._ensure_splatmap_projection():
		push_error(
			"[Tile Studio] The requested splatmap overlay could not load; current terrain materials were preserved."
		)
		return
	for chunk: Vector2i in chunks_to_apply:
		for surface: Dictionary in host.terrain_renderer.chunk_surfaces(chunk):
			var material := host._terrain_surface_material(chunk, surface)
			if material == null:
				continue
			host.terrain_renderer.set_chunk_surface_material(
				chunk,
				int(surface["surface_index"]),
				material
			)


## Build one ordinary terrain batch and bind its optional direct shader-decal layer.
##
## The decal is not rasterized or composited into another image. Its original PBR
## textures, authored transform, and Asset UI footprint are bound to the same
## ShaderMaterial that already renders the base coat and painted material layers.
static func _terrain_surface_material(host: MTSStudioViewport,
	chunk: Vector2i,
	surface: Dictionary
) -> Material:
	var material := host._terrain_chunk_material(
		String(surface["key"]),
		String(surface["asset_id"]),
		surface["is_top"] == true,
		surface["slot_materials"] as PackedInt32Array
	)
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return material
	var shader_decal := surface.get("shader_decal", null) as SurfacePlacement
	if shader_decal == null:
		if not host.material_factory.configure_shader_decal(shader_material, null, null, {}):
			return null
		return material
	if host.library == null:
		push_error(
			"[Tile Studio] chunk %s cannot resolve shader decal '%s' without the asset library."
			% [chunk, shader_decal.asset_id]
		)
		return null
	var decal_asset := host.library.get_asset(shader_decal.asset_id)
	if decal_asset == null or not decal_asset.is_surface():
		push_error(
			"[Tile Studio] chunk %s shader decal asset '%s' is missing or is not a surface asset."
			% [chunk, shader_decal.asset_id]
		)
		return null
	var palette_adjustment: Dictionary = {}
	if shader_decal.match_underlying_palette:
		palette_adjustment = host._shader_decal_palette_adjustment(shader_decal)
		if palette_adjustment.is_empty():
			return null
	if not host.material_factory.configure_shader_decal(
		shader_material,
		shader_decal,
		decal_asset,
		palette_adjustment
	):
		return null
	return material


## Build one terrain chunk surface's ordinary material, bound to that chunk's weights.
##
## Every terrain batch follows this one base-material path. The optional one-shot
## shader decal is subsequently bound as one more layer on this same ShaderMaterial.
static func _terrain_chunk_material(host: MTSStudioViewport,
	batch_key: String,
	asset_id: String,
	is_top: bool,
	slot_materials: PackedInt32Array
) -> Material:
	if host.material_factory == null or host.board == null:
		return null
	# A face-local Terrain Paint PNG is produced only by authored painting. There
	# is no separate board-wide base texture to override or fill in this result.
	if not asset_id.is_empty():
		if host.library == null:
			push_error(
				"[Tile Studio] terrain material '%s' cannot resolve without the asset library."
				% asset_id
			)
			return null
		var asset := host.library.get_asset(asset_id)
		if asset == null:
			push_error(
				"[Tile Studio] terrain material asset '%s' is missing from the library."
				% asset_id
			)
			return null
		var control_texture: Texture2DArray = (
			host.surface_material_paint.batch_texture(batch_key)
			if host.surface_material_paint != null
			else null
		)
		var asset_material := host.material_factory.get_asset_material_for_terrain_batch(
			asset,
			control_texture,
			host.board.material_blend,
			host.library,
			host._material_world_height_range,
			host._material_world_elevation_range,
			slot_materials
		)
		host._apply_material_mask_preview_to_material(asset_material as ShaderMaterial)
		return host._configure_terrain_grid_material(asset_material, is_top)

	# An unpainted batch keeps a neutral material because the top/side grid
	# classification is presentation state on this exact terrain surface.
	var control_texture: Texture2DArray = (
		host.surface_material_paint.batch_texture(batch_key)
		if (
			host.board.material_blend != null
			and host.board.material_blend.enabled
			and host.surface_material_paint != null
		)
		else null
	)
	var neutral_material := host.material_factory.get_material_for_terrain_batch(
		control_texture,
		host.board.material_blend,
		host.library,
		host._material_world_height_range,
		host._material_world_elevation_range,
		slot_materials
	)
	host._apply_material_mask_preview_to_material(neutral_material as ShaderMaterial)
	return host._configure_terrain_grid_material(neutral_material, is_top)


## Bind grid presentation to one exact terrain batch without creating geometry.
static func _configure_terrain_grid_material(host: MTSStudioViewport, material: Material, is_top: bool) -> Material:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return material
	shader_material.set_shader_parameter("terrain_grid_is_top", is_top)
	shader_material.set_shader_parameter(
		"terrain_show_top_grid",
		host._terrain_top_grid_visible
	)
	shader_material.set_shader_parameter(
		"terrain_show_side_grid",
		host._terrain_side_grid_visible
	)
	var projection_is_top := host._splatmap_projection_face() == MTSStudioViewport.K.Face.POS_Y
	var source_overlay_enabled := (
		is_top == projection_is_top
		and host._splatmap_source_overlay_requested()
		and host._splatmap_source_texture != null
		and host._splatmap_terrain_bounds.size.x > 0
		and host._splatmap_terrain_bounds.size.y > 0
	)
	shader_material.set_shader_parameter(
		"splatmap_source_overlay_enabled",
		source_overlay_enabled
	)
	if source_overlay_enabled:
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_tex",
			host._splatmap_source_texture
		)
		# One projected cell is one metre in the selected face plane, so these
		# coordinates are the exact two-dimensional rectangle sampled by the brush.
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_rect",
			Vector4(
				float(host._splatmap_terrain_bounds.position.x),
				float(host._splatmap_terrain_bounds.position.y),
				float(host._splatmap_terrain_bounds.size.x),
				float(host._splatmap_terrain_bounds.size.y)
			)
		)
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_channel_mask",
			host._splatmap_channel_mask
		)
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_projection",
			int(host.board.material_blend.splatmap_projection)
		)
	return shader_material
