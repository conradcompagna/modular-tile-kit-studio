@tool
extends RefCounted

## Document loading behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Save immutable sparse PNG paint sidecars for the active board path.
static func save_surface_material_paint(host: MTSStudioViewport, board_path: String) -> Dictionary:
	if host.surface_material_paint == null:
		return {"error": ERR_UNAVAILABLE}
	var active_uids: Dictionary = {}
	if host.board != null:
		for surface: SurfacePlacement in host.board.surfaces:
			active_uids[surface.ensure_uid()] = true
	if host.terrain_renderer != null:
		for terrain_uid: String in host.terrain_renderer.paint_uids():
			active_uids[terrain_uid] = true
	return host.surface_material_paint.save_sidecars(board_path, active_uids)


## Validate paint sidecars without mutating the currently visible board.
static func prepare_surface_material_paint(host: MTSStudioViewport,
	board_path: String,
	metadata: Dictionary
) -> Dictionary:
	if host.surface_material_paint == null:
		return {"error": ERR_UNAVAILABLE}
	return host.surface_material_paint.prepare_sidecars(board_path, metadata)


## Commit already-validated paint images before the derived batch rebuild.
static func commit_prepared_surface_material_paint(host: MTSStudioViewport, prepared: Dictionary) -> bool:
	if host.surface_material_paint == null:
		return false
	return host.surface_material_paint.commit_prepared_sidecars(prepared)


## Commit one validated board and its detached resources, then manifest it exactly once.
static func commit_prepared_board_load(host: MTSStudioViewport,
	prepared_board: BoardDocument,
	prepared_paint: Dictionary,
	apply_prepared_look: bool = true
) -> bool:
	if host.board == null or prepared_board == null:
		push_error("[Tile Studio] Cannot commit a board load without both documents.")
		return false
	if int(prepared_paint.get("error", FAILED)) != OK:
		push_error("[Tile Studio] Cannot commit a board load with invalid prepared resources.")
		return false

	# The height field is derived, so a loading board allocates a clean one sized
	# to hold both its placements and its authored terrain, then projects the
	# terrain into it once the document is live.
	var next_world_fields := MTSStudioViewport.WorldSurfaceFields.new(false) as MTSWorldSurfaceFields
	var required_rect := Rect2(
		MTSStudioViewport.WorldSurfaceFields.DEFAULT_ORIGIN,
		MTSStudioViewport.WorldSurfaceFields.DEFAULT_SIZE
	)
	if not prepared_board.is_empty():
		required_rect = host._world_surface_field_rect_for_bounds(prepared_board.compute_bounds())
	if not prepared_board.terrain.is_empty():
		required_rect = required_rect.merge(prepared_board.terrain.world_rect())
	var required_resolution := Vector2i(
		ceili(required_rect.size.x * MTSStudioViewport.WORLD_HEIGHT_TEXELS_PER_METER) + 1,
		ceili(required_rect.size.y * MTSStudioViewport.WORLD_HEIGHT_TEXELS_PER_METER) + 1
	)
	next_world_fields.configure(
		required_rect.position,
		required_rect.size,
		required_resolution,
		false
	)

	var next_surface_paint := (
		host._surface_material_paint_script.new()
		as MTSSurfaceMaterialPaint
	)
	next_surface_paint.bind_profile(prepared_board.material_blend)
	if not next_surface_paint.commit_prepared_sidecars(prepared_paint):
		return false
	if not host.board.commit_prepared_load(prepared_board):
		return false

	if (
		host.world_surface_fields != null
		and host.world_surface_fields.fields_changed.is_connected(
			host._on_world_surface_fields_changed
		)
	):
		host.world_surface_fields.fields_changed.disconnect(host._on_world_surface_fields_changed)
	if (
		host.surface_material_paint != null
		and host.surface_material_paint.batch_texture_changed.is_connected(
			host._refresh_material_paint_batch
		)
	):
		host.surface_material_paint.batch_texture_changed.disconnect(
			host._refresh_material_paint_batch
		)
	if (
		host.surface_material_paint != null
		and host.surface_material_paint.palette_slots_changed.is_connected(
			host._on_material_palette_slots_changed
		)
	):
		host.surface_material_paint.palette_slots_changed.disconnect(
			host._on_material_palette_slots_changed
		)
	host.world_surface_fields = next_world_fields
	host.surface_material_paint = next_surface_paint
	host.world_surface_fields.fields_changed.connect(host._on_world_surface_fields_changed)
	host.surface_material_paint.batch_texture_changed.connect(host._refresh_material_paint_batch)
	host.surface_material_paint.palette_slots_changed.connect(host._on_material_palette_slots_changed)

	if host.material_factory != null:
		host.material_factory.aesthetics = host.board.aesthetics
		host.material_factory.world_fields = host.world_surface_fields
		host.material_factory.clear_cache()
		if apply_prepared_look:
			host.material_factory.apply_global_effects(host.board.aesthetics)
	host._renderer_settings_signature = host._current_renderer_settings_signature()

	if apply_prepared_look:
		host._defer_reflection_probe_rebuild = true
		host.apply_lighting_profile()
		host._defer_reflection_probe_rebuild = false
		host.apply_grade()
	host._full_rebuild_bounds = AABB() if host.board.is_empty() else host.board.compute_bounds()
	host._full_rebuild_has_bounds = true
	# The loaded terrain is canonical, so its mesh, collision, projected fields,
	# and terrain-shader grid state are ready before the board is announced.
	host._bind_terrain_sculptor()
	host.refresh_terrain()
	host.rebuild_board(true)

	host._skip_next_look_apply = true
	host.board.announce_loaded_state(apply_prepared_look)
	host._skip_next_look_apply = false
	return true
