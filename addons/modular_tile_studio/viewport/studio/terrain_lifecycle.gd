@tool
extends RefCounted

## Terrain lifecycle behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return the paint chunk edge in cells the board's profile implies.
##
## Derived from the visible paint resolution so a chunk's ground image is exactly
## as large as the profile allows without being downscaled, which is what keeps
## terrain painting at the authored texel density. The Terrain panel shows it.
static func terrain_chunk_cells(host: MTSStudioViewport) -> int:
	return MTSTerrainMeshBuilder.chunk_cells_for(
		host.board.material_blend if host.board != null else null
	)


## Return cached renderer counts for the Terrain panel's inexpensive readout.
static func terrain_summary_counts(host: MTSStudioViewport) -> Dictionary:
	return host.terrain_renderer.summary_counts() if host.terrain_renderer != null else {}


## Return the cached projected terrain height range without scanning every cell.
static func terrain_cached_height_range(host: MTSStudioViewport) -> Vector2:
	return (
		host.world_surface_fields.height_value_range()
		if host.world_surface_fields != null
		else Vector2.ZERO
	)


## Replace the board's terrain with one imported from a heightfield GLB.
##
## The imported grid is already canonical terrain, so it is adopted whole and
## every sculpt brush and paint tool applies to it immediately. The replacement
## is one undo step, and the previous terrain is restored exactly on undo.
static func adopt_imported_terrain(host: MTSStudioViewport, imported: TerrainMesh) -> bool:
	if host.board == null:
		push_error("[Tile Studio] Cannot import terrain without a bound board.")
		return false
	if imported == null or imported.is_empty():
		push_error("[Tile Studio] Imported terrain is empty.")
		return false
	var previous := host.board.terrain.duplicate_terrain()
	host._apply_terrain_grid(imported.duplicate_terrain())
	if host._height_undo_redo == null:
		return true
	host._height_undo_redo.create_action(
		"Import terrain heightfield",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	host._height_undo_redo.add_do_method(
		host,
		"_apply_terrain_grid",
		imported.duplicate_terrain()
	)
	host._height_undo_redo.add_undo_method(
		host,
		"_apply_terrain_grid",
		previous
	)
	# The import is already applied, so committing without execution avoids
	# decoding and rebuilding the same GLB twice.
	host._height_undo_redo.commit_action(false)
	return true


## Adopt one complete canonical terrain grid.
static func _apply_terrain_grid(host: MTSStudioViewport, grid: TerrainMesh) -> void:
	if host.board == null or grid == null:
		return
	host.board.terrain = grid
	host._bind_terrain_sculptor()
	host.refresh_terrain()


## Erase all authored terrain, leaving the board with no encounter footprint.
##
## This is destructive and undoable: the caller registers the history action.
static func clear_terrain(host: MTSStudioViewport) -> void:
	if host.board == null:
		return
	if host._terrain_sculptor != null and host._terrain_sculptor.is_stroke_active():
		host._terrain_sculptor.cancel_stroke()
	host._height_sculpting = false
	host._height_pending_motion = false
	host.board.terrain = TerrainMesh.new()
	# Every face is gone, so every material authored on terrain is released with it
	# rather than surviving as metadata that would reappear under new footprint.
	host._reconcile_terrain_paint()
	host._bind_terrain_sculptor()
	host.refresh_terrain()


## Reset to a clean field derived only from the currently loaded board's bounds.
static func reset_world_heightfield(host: MTSStudioViewport) -> void:
	if host.world_surface_fields == null:
		return
	host.world_surface_fields.configure(
		MTSStudioViewport.WorldSurfaceFields.DEFAULT_ORIGIN,
		MTSStudioViewport.WorldSurfaceFields.DEFAULT_SIZE,
		MTSStudioViewport.WorldSurfaceFields.DEFAULT_RESOLUTION,
		false
	)
	host._reset_world_surface_field_coverage()
