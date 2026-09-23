@tool
extends RefCounted

## Lifecycle behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Clear all authored board state, including terrain and derived indexes.
static func clear(host: BoardDocument) -> void:
	host._clear_state()
	host.board_changed.emit()


## Clear canonical and derived state without exposing a transient empty document.
##
## Detached loading uses this path so listeners observe only the final prepared
## board, while the explicit New Board action continues through clear().
static func _clear_state(host: BoardDocument) -> void:
	host.surfaces.clear()
	host.props.clear()
	host.enemy_packs.clear()
	host.gameplay_markers.clear()
	host.particle_effects.clear()
	host.monster_visual_assets.clear()
	host.imported_asset_ids.clear()
	# Replace canonical movement and terrain state together so New Board cannot
	# inherit collision rules or annotations from the level that was just closed.
	host.terrain = TerrainMesh.new()
	host.movement_collision_min_triangle_share_percent = 0.0
	host.movement_unwalkable_cells.clear()
	host.movement_ground_effects.clear()
	host.surface_material_paint.clear()
	host.material_blend = MaterialBlendProfile.new()
	host._paint_uid_index.clear()
	host._solid_index.clear()
	host._prop_footprint_index.clear()
	host._enemy_pack_index.clear()
	host._gameplay_marker_index.clear()
	host._gameplay_marker_cell_index.clear()


## Notify look consumers after an in-place profile edit.
static func notify_look_changed(host: BoardDocument) -> void:
	host.look_changed.emit()


## Reset only the board's aesthetics profile to documented defaults.
static func reset_aesthetics(host: BoardDocument) -> void:
	host.aesthetics.reset_to_defaults()
	host.look_changed.emit()


## Reset only the board's lighting profile to documented defaults.
static func reset_lighting(host: BoardDocument) -> void:
	host.lighting.reset_to_defaults()
	host.look_changed.emit()


## Reset both saved look profiles to documented defaults.
static func reset_look(host: BoardDocument) -> void:
	host.aesthetics.reset_to_defaults()
	host.lighting.reset_to_defaults()
	host.look_changed.emit()


## Return whether the board contains no authored terrain and no placements.
##
## Terrain is counted because a sculpted heightfield with nothing on it is a real
## authored board; treating it as empty would misreport framing, world-field
## coverage, and the empty-board state to the user.
static func is_empty(host: BoardDocument) -> bool:
	return (
		(host.terrain == null or host.terrain.is_empty())
		and host.surfaces.is_empty()
		and host.props.is_empty()
		and host.gameplay_markers.is_empty()
		and host.particle_effects.is_empty()
	)


## Announce that the authored terrain changed so derived state can rebuild.
##
## Terrain is board geometry rather than a look setting, so it emits
## board_changed: the visible mesh, prop supports, and collision all follow it.
static func notify_terrain_changed(host: BoardDocument) -> void:
	host.prune_movement_grid_cells()
	host.board_changed.emit()


## Return the gameplay grid derived from the current authored terrain.
##
## This is the tactical surface characters walk on. Every entry is computed from
## the frozen corner heights at call time, so it can never drift from the terrain
## the user sculpted and the renderer draws. It is a read-only projection and is
## deliberately not stored on the board.
##
## Each cell reports its integer coordinate, its derived form, the height a token
## stands at, the vertical relief across the cell, and the XZ gradient used to
## orient tokens and judge whether a ramp is climbable.
static func gameplay_grid(host: BoardDocument) -> Array[Dictionary]:
	var cells: Array[Dictionary] = []
	if host.terrain == null or host.terrain.is_empty():
		return cells
	for local_z: int in host.terrain.size_cells.y:
		for local_x: int in host.terrain.size_cells.x:
			var cell := host.terrain.origin_cell + Vector2i(local_x, local_z)
			if not host.terrain.is_cell_filled(cell):
				continue
			cells.append({
				"cell": cell,
				"form": host.terrain.classify_cell(cell),
				"form_name": host.terrain.cell_form_name(host.terrain.classify_cell(cell)),
				"walk_height_m": host.terrain.cell_walk_height(cell),
				"relief_m": host.terrain.cell_relief(cell),
				"gradient": host.terrain.cell_gradient(cell),
				"manually_unwalkable": host.movement_cell_is_unwalkable(cell),
				"ground_effect": host.movement_ground_effect(cell),
			})
	return cells


## Return the inclusive world bounds of the terrain and every placement.
##
## The terrain footprint and its real height range are included because terrain
## is the board's primary geometry; camera framing, world fields, and lighting
## bounds all read this one result.
static func compute_bounds(host: BoardDocument) -> AABB:
	if host.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)

	if host.terrain != null and not host.terrain.is_empty():
		var footprint := host.terrain.filled_bounds_cells()
		if footprint.size.x > 0 and footprint.size.y > 0:
			# Terrain spans its filled cell rectangle in XZ and its real sculpted
			# elevation range in Y, including the skirt hanging below the lowest top.
			minimum = minimum.min(Vector3(
				float(footprint.position.x),
				host.terrain.lowest_top_height() - host.terrain.skirt_depth_m,
				float(footprint.position.y)
			))
			maximum = maximum.max(Vector3(
				float(footprint.position.x + footprint.size.x),
				host.terrain.highest_top_height(),
				float(footprint.position.y + footprint.size.y)
			))

	for marker: GameplayMarker in host.gameplay_markers:
		minimum = minimum.min(Vector3(marker.origin))
		maximum = maximum.max(Vector3(marker.origin) + Vector3.ONE)

	for effect: ParticleEffectPlacement in host.particle_effects:
		minimum = minimum.min(effect.position - Vector3.ONE * 0.5)
		maximum = maximum.max(effect.position + Vector3.ONE * 0.5)

	for placement: PropPlacement in host.props:
		var cells := host.prop_occupied_cells(placement)
		if cells.is_empty():
			cells = [placement.origin]
		for cell: Vector3i in cells:
			minimum = minimum.min(Vector3(cell))
			maximum = maximum.max(Vector3(cell) + Vector3.ONE)

	if minimum.x == INF:
		return AABB(Vector3.ZERO, Vector3.ONE)
	return AABB(minimum, (maximum - minimum).max(Vector3.ONE))
