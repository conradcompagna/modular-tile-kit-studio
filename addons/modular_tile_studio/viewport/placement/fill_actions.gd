@tool
extends RefCounted

## Fill actions behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

# --- Fill -----------------------------------------------------------------

## Clear the transient point-defined Fill shape without changing the active brush.
##
## Vertices and preview candidates belong only to this controller. BoardDocument
## remains the one authoritative source for placements and changes only on Enter.
static func _reset_fill_state(host: MTSPlacementController) -> void:
	host.fill_vertices.clear()
	host._fill_active_origins.clear()
	host._fill_active_valid_origins.clear()
	host._fill_active_blocked_origins.clear()
	host._fill_first_rejection = ""
	host._fill_preview_vertices.clear()
	host._fill_preview_origins.clear()
	host._fill_preview_valid_origins.clear()
	host._fill_preview_blocked_origins.clear()
	host._clear_fill_preview()


## Return whether Fill currently has at least one authored point.
static func has_fill_vertices(host: MTSPlacementController) -> bool:
	return not host.fill_vertices.is_empty()


## Return the number of points defining the current line or polygon.
static func fill_vertex_count(host: MTSPlacementController) -> int:
	return host.fill_vertices.size()


## Return the number of valid placement stamps in the current Fill preview.
static func fill_valid_count(host: MTSPlacementController) -> int:
	return host._fill_active_valid_origins.size()


## Return the number of blocked placement stamps in the current Fill preview.
static func fill_blocked_count(host: MTSPlacementController) -> int:
	return host._fill_active_blocked_origins.size()


## Add the hovered cell as the next Fill point and rebuild the complete preview.
##
## One point previews one stamp, two points define a line, and three or more
## points define a closed polygon that is committed only when the user presses Enter.
static func add_fill_vertex_at_hover(host: MTSPlacementController) -> bool:
	if host.tool != MTSPlacementController.Tool.FILL or not host._fill_is_armed() or host.board == null:
		return false
	if host.fill_vertices.has(host.hovered_cell):
		return false

	host.fill_vertices.append(host.hovered_cell)
	host._refresh_fill_candidates()
	host.update_preview_visibility()
	return true


## Remove the newest Fill point so the polygon can be corrected before commit.
static func remove_last_fill_vertex(host: MTSPlacementController) -> bool:
	if host.fill_vertices.is_empty():
		return false
	host.fill_vertices.pop_back()
	host._refresh_fill_candidates()
	host.update_preview_visibility()
	return true


## Cancel the current Fill shape without mutating BoardDocument.
static func cancel_fill(host: MTSPlacementController) -> void:
	host._reset_fill_state()
	host.update_preview_visibility()


## Commit every valid stamp in the current Fill shape as one undoable action.
##
## Blocked stamps are shown in red before commit and are omitted explicitly; if
## every stamp is blocked, the shape remains available for correction.
static func commit_fill(host: MTSPlacementController) -> bool:
	if host.fill_vertices.is_empty() or not host._fill_is_armed() or host.board == null:
		return false

	if host._fill_targets_terrain():
		# Terrain mutation and its undo entry belong to the viewport, so the shape
		# is handed over rather than applied here. Only the cells this terrain tool
		# can actually edit travel with it; blocked cells were already shown red.
		var terrain_evaluated := host._evaluate_terrain_fill_candidates(host._fill_active_origins)
		var terrain_origins: Array[Vector3i] = terrain_evaluated["valid_origins"]
		if terrain_origins.is_empty():
			var terrain_reason := String(terrain_evaluated.get("first_rejection", ""))
			if terrain_reason.is_empty():
				terrain_reason = "Fill shape does not contain one editable terrain cell."
			host._reject(terrain_reason)
			return false
		if host.terrain_splat_paint_enabled:
			host.terrain_material_tile_paint_requested.emit(
				host.terrain_material_target_uids_for_origins(
					terrain_origins,
					host._terrain_splat_face
				),
				false,
				host.replace_enabled,
				true
			)
		else:
			host.terrain_fill_committed.emit(terrain_origins)
		host._reset_fill_state()
		host.update_preview_visibility()
		return true

	var evaluated := host._evaluate_placement_candidates(host._fill_active_origins)
	var placements: Array[Resource] = evaluated["placements"]
	var displaced: Array[Resource] = evaluated["replacements"]
	if placements.is_empty():
		var reason := String(evaluated.get(
			"first_rejection",
			"Fill shape does not contain one complete stamp."
		))
		if reason.is_empty():
			reason = "Fill shape does not contain one complete stamp."
		host._reject(reason)
		return false

	var noun := "surfaces" if host.brush_is_surface() else "props"
	if displaced.is_empty():
		host._commit_placements_bulk(
			placements,
			"Fill %d %s" % [placements.size(), noun]
		)
	else:
		host._commit_replacements(
			placements,
			displaced,
			"Replace %d %s with Fill" % [displaced.size(), noun]
		)
	host._reset_fill_state()
	host.update_preview_visibility()
	return true
