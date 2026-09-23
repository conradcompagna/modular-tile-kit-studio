@tool
extends RefCounted

## Selection orientation behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Build rotated duplicates from the selected canonical placement records.
##
## These records are validation candidates only; they are never inserted into
## BoardDocument or rendered as a second placement representation.
static func _rotated_selection_candidates(host: MTSPlacementController, axis: Vector3i, positive: bool) -> Dictionary:
	var candidates: Dictionary = {}
	for placement_record: Resource in host.selected_placements:
		if placement_record is SurfacePlacement:
			var surface := (placement_record as SurfacePlacement).duplicate() as SurfacePlacement
			var surface_orientation := MTSPlacementController.K.rotate_surface_orientation(
				surface.face,
				surface.rotation_quarters,
				axis,
				positive
			)
			surface.face = int(surface_orientation["face"])
			surface.rotation_quarters = int(surface_orientation["rotation_quarters"])
			candidates[placement_record.get_instance_id()] = surface
		elif placement_record is PropPlacement:
			var prop := (placement_record as PropPlacement).duplicate() as PropPlacement
			var prop_orientation := MTSPlacementController.K.rotate_prop_orientation(
				prop.forward_face,
				prop.roll_quarters,
				axis,
				positive,
				prop.yaw_eighths
			)
			prop.forward_face = int(prop_orientation["forward_face"])
			prop.roll_quarters = int(prop_orientation["roll_quarters"])
			prop.yaw_eighths = int(prop_orientation["yaw_eighths"])
			candidates[placement_record.get_instance_id()] = prop
	return candidates


## Build one atomic upside-down flip candidate for every selected placement.
##
## A GLB's horizontal diagonal yaw is preserved while its orthogonal base pose
## turns 180 degrees around the base X axis. This makes imported upside-down art
## correctable without committing or collision-testing an intermediate 90-degree
## pose, and without storing a second transform.
static func _flipped_selection_candidates(host: MTSPlacementController) -> Dictionary:
	var candidates: Dictionary = {}
	for placement_record: Resource in host.selected_placements:
		if placement_record is SurfacePlacement:
			var surface := (placement_record as SurfacePlacement).duplicate() as SurfacePlacement
			for _step in 2:
				var surface_orientation := MTSPlacementController.K.rotate_surface_orientation(
					surface.face,
					surface.rotation_quarters,
					MTSPlacementController.K.DIR_EAST,
					true
				)
				surface.face = int(surface_orientation["face"])
				surface.rotation_quarters = int(surface_orientation["rotation_quarters"])
			candidates[placement_record.get_instance_id()] = surface
		elif placement_record is PropPlacement:
			var prop := (placement_record as PropPlacement).duplicate() as PropPlacement
			var preserved_yaw := prop.yaw_eighths
			# Flip the orthogonal base pose, then restore the same explicit yaw.
			# The final transform remains one canonical forward/roll/yaw record.
			prop.yaw_eighths = 0
			for _step in 2:
				var prop_orientation := MTSPlacementController.K.rotate_prop_orientation(
					prop.forward_face,
					prop.roll_quarters,
					MTSPlacementController.K.DIR_EAST,
					true,
					0
				)
				prop.forward_face = int(prop_orientation["forward_face"])
				prop.roll_quarters = int(prop_orientation["roll_quarters"])
			prop.yaw_eighths = preserved_yaw
			candidates[placement_record.get_instance_id()] = prop
	return candidates


## Capture only the orientation fields consumed by each selected placement type.
static func _selection_orientation_states(host: MTSPlacementController,
	targets: Array[Resource],
	candidate_overrides: Dictionary
) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for target: Resource in targets:
		var source := candidate_overrides.get(target.get_instance_id(), target) as Resource
		if source is SurfacePlacement:
			states.append({
				"face": (source as SurfacePlacement).face,
				"rotation_quarters": (source as SurfacePlacement).rotation_quarters,
				"terrain_face_uids": Array((source as SurfacePlacement).terrain_face_uids),
			})
		elif source is PropPlacement:
			states.append({
				"forward_face": (source as PropPlacement).forward_face,
				"roll_quarters": (source as PropPlacement).roll_quarters,
				"yaw_eighths": (source as PropPlacement).yaw_eighths,
			})
		else:
			states.append({})
	return states


## Apply prevalidated orientation state through the document's scoped spatial path.
static func _apply_selection_orientations(host: MTSPlacementController,
	targets: Array[Resource],
	states: Array[Dictionary]
) -> void:
	if host.board == null or not host.board.apply_placement_spatial_states(targets, states):
		push_error("[Tile Studio] could not apply selection orientation state.")
		return
	# Rotation leaves palette and non-spatial board data unchanged, so this one
	# spatial notification is the complete observer surface for the action.
	host.board_mutated.emit(host._mutation_mask_for_resources(targets))


## Commit orientation candidates through the one shared collision and undo path.
static func _commit_selection_orientation_candidates(host: MTSPlacementController,
	candidates: Dictionary,
	action_verb: String
) -> bool:
	if host.selected_placements.is_empty() or host.board == null:
		return false
	var error := host._selection_spatial_error(candidates)
	if not error.is_empty():
		host.last_rejection = error
		push_error("[Tile Studio] selection %s rejected: %s." % [action_verb.to_lower(), error])
		return false

	var targets := host.selected_resources()
	var old_states := host._selection_orientation_states(targets, {})
	var new_states := host._selection_orientation_states(targets, candidates)
	host.last_rejection = ""
	var action := "%s %d placement%s" % [
		action_verb,
		targets.size(),
		"" if targets.size() == 1 else "s",
	]
	if host.undo_redo == null:
		host._apply_selection_orientations(targets, new_states)
		return true
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host, "_apply_selection_orientations", targets, new_states)
	host.undo_redo.add_undo_method(host, "_apply_selection_orientations", targets, old_states)
	host.undo_redo.commit_action()
	return true


## Rotate all selected placements in place through the shared collision validator.
static func rotate_selection(host: MTSPlacementController, axis: Vector3i, positive: bool) -> bool:
	return host._commit_selection_orientation_candidates(
		host._rotated_selection_candidates(axis, positive),
		"Rotate"
	)


## Flip all selected placements upside down as one validated undoable operation.
static func flip_selection(host: MTSPlacementController) -> bool:
	return host._commit_selection_orientation_candidates(
		host._flipped_selection_candidates(),
		"Flip"
	)
