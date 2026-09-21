@tool
extends RefCounted

## Selection behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Add or remove a complete mixed selection with one index rebuild and one board notification.
##
## This is the shared do/undo boundary for Delete, so the visible selection and
## the saved BoardDocument cannot diverge even when several placement types are selected.
static func _apply_selection_presence(host: MTSPlacementController, targets: Array[Resource], present: bool) -> void:
	if host.board == null:
		return
	for target: Resource in targets:
		if target is SurfacePlacement:
			if present and not host.board.surfaces.has(target):
				host.board.surfaces.append(target)
			elif not present:
				host.board.surfaces.erase(target)
		elif target is PropPlacement:
			if present and not host.board.props.has(target):
				host.board.props.append(target)
			elif not present:
				host.board.props.erase(target)
		else:
			push_error("[Tile Studio] selection delete contains an unsupported placement resource.")
			return
	host.board.rebuild_indexes()
	host.board.board_changed.emit()
	host.board_mutated.emit(host._mutation_mask_for_resources(targets))


## Delete every selected canonical placement as one undoable editor action.
static func delete_selection(host: MTSPlacementController) -> void:
	var targets := host.selected_resources()
	if targets.is_empty():
		return
	# Clear the transient highlight before the document notification rebuilds its
	# derived nodes, so a deleted Resource is never displayed as still selected.
	host.selected = null
	host.selected_placements.clear()
	host.selection_changed.emit(null)

	if host.undo_redo == null:
		host._apply_selection_presence(targets, false)
		return
	var action := "Delete %d placement%s" % [
		targets.size(),
		"" if targets.size() == 1 else "s",
	]
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host, "_apply_selection_presence", targets, false)
	host.undo_redo.add_undo_method(host, "_apply_selection_presence", targets, true)
	host.undo_redo.commit_action()


## Select the terrain-paint placement or solid at the hovered canonical address.
static func select_at_hover(host: MTSPlacementController) -> void:
	if host.board == null:
		return
	var found: Resource = host._surface_at_address(host.hovered_cell, host.brush_face)
	if found == null:
		for face: int in MTSPlacementController.K.FACE_NORMALS:
			found = host._surface_at_address(host.hovered_cell, face)
			if found != null:
				break
	if found == null:
		found = host.board.solid_placement_at(host.hovered_cell)
	var next_selection: Array[Resource] = []
	if found != null:
		next_selection.append(found)
	host.set_selected_placements(next_selection)


## Return whether one placement is part of the current explicit group selection.
static func is_selected(host: MTSPlacementController, placement: Resource) -> bool:
	return placement != null and host.selected_placements.has(placement)


## Return a copy so callers can inspect the current group without owning it.
static func selected_resources(host: MTSPlacementController) -> Array[Resource]:
	return host.selected_placements.duplicate()


## Replace the group selection with valid board placements and retain one primary item.
##
## The resource records themselves are canonical, so this stores their identities
## rather than a duplicate list of origins or renderer nodes.
static func set_selected_placements(host: MTSPlacementController, placements: Array[Resource], primary: Resource = null) -> void:
	var next_selection: Array[Resource] = []
	for placement_record: Resource in placements:
		if placement_record == null or next_selection.has(placement_record):
			continue
		if placement_record is SurfacePlacement and host.board != null and host.board.surfaces.has(placement_record):
			next_selection.append(placement_record)
		elif placement_record is PropPlacement and host.board != null and host.board.props.has(placement_record):
			next_selection.append(placement_record)

	host.selected_placements = next_selection
	host.selected = primary if primary != null and next_selection.has(primary) else null
	if host.selected == null and not host.selected_placements.is_empty():
		host.selected = host.selected_placements[0]
	host.selection_changed.emit(host.selected)


## Add or remove one placement without changing the remaining group members.
static func toggle_selected_placement(host: MTSPlacementController, placement_record: Resource) -> void:
	if placement_record == null:
		return
	var next_selection := host.selected_resources()
	if next_selection.has(placement_record):
		next_selection.erase(placement_record)
		host.set_selected_placements(next_selection)
	else:
		next_selection.append(placement_record)
		host.set_selected_placements(next_selection, placement_record)


## Clear every selected placement while updating the existing inspector signal.
static func clear_selection(host: MTSPlacementController) -> void:
	var empty_selection: Array[Resource] = []
	host.set_selected_placements(empty_selection)


## Validate only changed selection candidates against canonical occupancy indexes.
##
## Selected originals are ignored because the whole group moves atomically.
## Candidate-to-candidate dictionaries catch overlaps inside the moved group
## without scanning or reconstructing any unchanged board occupancy.
static func _selection_spatial_error(host: MTSPlacementController, candidate_overrides: Dictionary) -> String:
	if host.board == null or host.selected_placements.is_empty():
		return "no selected placement or board"

	var selected_ids: Dictionary = {}
	for selected: Resource in host.selected_placements:
		selected_ids[selected.get_instance_id()] = true
	var candidate_surface_faces: Dictionary = {}
	var candidate_solid_cells: Dictionary = {}

	for original: Resource in host.selected_placements:
		var candidate := candidate_overrides.get(
			original.get_instance_id(),
			original
		) as Resource
		if candidate is SurfacePlacement:
			var candidate_surface := candidate as SurfacePlacement
			var terrain_error := host._conform_texture_surface_to_terrain(candidate_surface)
			if not terrain_error.is_empty():
				return terrain_error
			for conflict: SurfacePlacement in host.board.surface_conflicting_placements(
				candidate_surface
			):
				if not selected_ids.has(conflict.get_instance_id()):
					return "selection would overlap an existing surface"
			for uid: String in candidate_surface.terrain_face_uids:
				if candidate_surface_faces.has(uid):
					return "selection would overlap a surface at %s" % uid
				candidate_surface_faces[uid] = true
		elif candidate is PropPlacement:
			for cell: Vector3i in host.board.prop_occupied_cells(candidate as PropPlacement):
				var solid_key := MTSPlacementController.K.voxel_key(cell)
				var occupant := host.board.solid_placement_at(cell)
				if occupant != null and not selected_ids.has(occupant.get_instance_id()):
					return "selection would overlap a solid at %s" % solid_key
				if candidate_solid_cells.has(solid_key):
					return "selection would overlap a solid at %s" % solid_key
				candidate_solid_cells[solid_key] = true
		else:
			return "selection contains an unsupported placement resource"
	return ""


## Validate a proposed whole-selection translation through canonical collision occupancy.
static func selection_move_error(host: MTSPlacementController, delta: Vector3i) -> String:
	var candidates: Dictionary = {}
	for placement_record: Resource in host.selected_placements:
		var candidate := placement_record.duplicate() as Resource
		if candidate is SurfacePlacement:
			(candidate as SurfacePlacement).origin += delta
		elif candidate is PropPlacement:
			(candidate as PropPlacement).origin += delta
		else:
			return "selection contains an unsupported placement resource"
		candidates[placement_record.get_instance_id()] = candidate
	return host._selection_spatial_error(candidates)


## Apply selection origins while deriving texture coverage from canonical terrain.
static func _apply_selection_origins(host: MTSPlacementController,
	targets: Array[Resource], origins: Array[Vector3i]
) -> void:
	if host.board == null or targets.size() != origins.size():
		push_error("[Tile Studio] cannot apply a selection move with mismatched targets and origins.")
		return
	var states: Array[Dictionary] = []
	for index: int in origins.size():
		var state := {"origin": origins[index]}
		var target := targets[index]
		if target is SurfacePlacement:
			var candidate := target.duplicate() as SurfacePlacement
			candidate.origin = origins[index]
			var terrain_error := host._conform_texture_surface_to_terrain(candidate)
			if not terrain_error.is_empty():
				push_error("[Tile Studio] cannot move terrain paint: %s." % terrain_error)
				return
			state["terrain_face_uids"] = Array(candidate.terrain_face_uids)
		states.append(state)
	if not host.board.apply_placement_spatial_states(targets, states):
		push_error("[Tile Studio] could not apply selection origins.")
		return
	# Moving records cannot affect palette definitions or usage counts, so one
	# viewport spatial notification is sufficient after the canonical mutation.
	host.board_mutated.emit(host._mutation_mask_for_resources(targets))


## Move the entire current group by one integer grid delta as a single undo step.
static func move_selection_by(host: MTSPlacementController, delta: Vector3i) -> bool:
	if delta == Vector3i.ZERO:
		return false
	var error := host.selection_move_error(delta)
	if not error.is_empty():
		host.last_rejection = error
		push_error("[Tile Studio] selection move rejected: %s." % error)
		return false

	var targets := host.selected_resources()
	var old_origins: Array[Vector3i] = []
	var new_origins: Array[Vector3i] = []
	for target: Resource in targets:
		var origin := Vector3i.ZERO
		if target is SurfacePlacement:
			origin = (target as SurfacePlacement).origin
		elif target is PropPlacement:
			origin = (target as PropPlacement).origin
		else:
			push_error("[Tile Studio] selection move contains an unsupported placement resource.")
			return false
		old_origins.append(origin)
		new_origins.append(origin + delta)

	var action := "Move %d placement%s" % [targets.size(), "" if targets.size() == 1 else "s"]
	if host.undo_redo == null:
		host._apply_selection_origins(targets, new_origins)
		return true
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host, "_apply_selection_origins", targets, new_origins)
	host.undo_redo.add_undo_method(host, "_apply_selection_origins", targets, old_origins)
	host.undo_redo.commit_action()
	return true
