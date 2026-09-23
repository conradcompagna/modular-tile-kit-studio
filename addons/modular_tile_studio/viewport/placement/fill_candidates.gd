@tool
extends RefCounted

## Fill candidates behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Rebuild the active origins, validation groups, and MultiMesh preview.
static func _refresh_fill_candidates(host: MTSPlacementController) -> void:
	if host.fill_vertices.is_empty() or not host._fill_is_armed() or host.board == null:
		host._fill_active_origins.clear()
		host._fill_active_valid_origins.clear()
		host._fill_active_blocked_origins.clear()
		host._fill_first_rejection = ""
		host._fill_preview_vertices.clear()
		host._fill_preview_origins.clear()
		host._fill_preview_valid_origins.clear()
		host._fill_preview_blocked_origins.clear()
		host._clear_fill_preview()
		return

	host._fill_active_origins = host._generate_fill_origins(host.fill_vertices)
	var evaluated := (
		host._evaluate_terrain_fill_candidates(host._fill_active_origins)
		if host._fill_targets_terrain()
		else host._evaluate_placement_candidates(host._fill_active_origins)
	)
	host._fill_active_valid_origins = evaluated["valid_origins"]
	host._fill_active_blocked_origins = evaluated["blocked_origins"]
	host._fill_first_rejection = String(evaluated["first_rejection"])
	host._refresh_fill_preview_from_hover()


## Classify terrain Fill origins into cells this terrain tool can actually edit.
##
## Sculpting and Footprint Erase can only act on cells that already exist, so an
## origin outside the drawn footprint is reported blocked rather than silently
## skipped. Footprint Draw is the one terrain operation that may create cells, so
## for it every origin inside the addressable lattice is valid.
##
## The returned keys deliberately match _evaluate_placement_candidates() so the
## preview and commit paths need no branch beyond choosing the evaluator.
static func _evaluate_terrain_fill_candidates(host: MTSPlacementController, origins: Array[Vector3i]) -> Dictionary:
	var valid_origins: Array[Vector3i] = []
	var blocked_origins: Array[Vector3i] = []
	var first_rejection := ""
	var terrain: TerrainMesh = host.board.terrain if host.board != null else null
	for origin: Vector3i in origins:
		if host.terrain_splat_paint_enabled:
			var splat_result := host._validate_terrain_splat_origin(
				origin,
				false,
				host.replace_enabled
			)
			if bool(splat_result.get("valid", false)):
				valid_origins.append(origin)
			else:
				blocked_origins.append(origin)
				if first_rejection.is_empty():
					first_rejection = String(splat_result.get(
						"reason",
						"splatmap tile is blocked"
					))
			continue
		var cell := Vector2i(origin.x, origin.z)
		var accepted := false
		if host.terrain_fill_allows_new_cells:
			# Draw may grow the lattice, so the only limit is the authored maximum.
			accepted = (
				absi(cell.x) < TerrainMesh.MAX_AXIS_CELLS
				and absi(cell.y) < TerrainMesh.MAX_AXIS_CELLS
			)
			if not accepted and first_rejection.is_empty():
				first_rejection = (
					"Cell %s is outside the %d cell authoring limit."
					% [cell, TerrainMesh.MAX_AXIS_CELLS]
				)
		else:
			accepted = terrain != null and terrain.is_cell_filled(cell)
			if not accepted and first_rejection.is_empty():
				first_rejection = (
					"Cell %s is not part of the drawn footprint." % cell
				)
		if accepted:
			valid_origins.append(origin)
		else:
			blocked_origins.append(origin)
	return {
		"valid_origins": valid_origins,
		"blocked_origins": blocked_origins,
		"first_rejection": first_rejection,
	}


## Rebuild every pending preview stamp through the current hovered endpoint.
##
## The hovered point is a visible tentative endpoint. Clicking makes it authored;
## until then it affects only these derived preview arrays, never the commit batch.
static func _refresh_fill_preview_from_hover(host: MTSPlacementController) -> void:
	host._fill_preview_vertices.clear()
	host._fill_preview_vertices.assign(host.fill_vertices)
	if host._fill_preview_vertices.is_empty():
		if host._fill_targets_terrain():
			# This is derived hover state only; Enter still commits clicked vertices.
			host._fill_preview_vertices.append(host.hovered_cell)
	elif host.hovered_cell != host._fill_preview_vertices[-1]:
		host._fill_preview_vertices.append(host.hovered_cell)

	host._fill_preview_origins = host._generate_fill_origins(host._fill_preview_vertices)
	var evaluated := (
		host._evaluate_terrain_fill_candidates(host._fill_preview_origins)
		if host._fill_targets_terrain()
		else host._evaluate_placement_candidates(host._fill_preview_origins)
	)
	host._fill_preview_valid_origins = evaluated["valid_origins"]
	host._fill_preview_blocked_origins = evaluated["blocked_origins"]
	host._fill_preview_texture_placement = evaluated.get("preview_placement", null) as SurfacePlacement
	host._update_fill_preview()
