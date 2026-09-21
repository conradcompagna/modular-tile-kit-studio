@tool
extends RefCounted

## Transactions behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Apply one atomic placement-and-terrain state for do, undo, and redo.
##
## Terrain changes are installed before the placement set changes, so the single
## regional notification exposes a consistent final state to viewport observers.
static func _apply_prop_terrain_transaction(host: MTSPlacementController,
	removed_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	patch: Dictionary,
	use_after_state: bool
) -> void:
	if host.board == null or host.board.terrain == null:
		push_error("[Tile Studio] cannot apply a GLB terrain transaction without a board heightfield.")
		return
	var regions := host._patch_terrain_regions(patch)
	var support_snapshot := host.board.capture_prop_support_state(regions)
	var cells: PackedVector2Array = patch.get("cells", PackedVector2Array())
	var tops: PackedFloat32Array = patch.get(
		"after_tops" if use_after_state else "before_tops",
		PackedFloat32Array()
	)
	var sides: Dictionary = patch.get(
		"after_sides" if use_after_state else "before_sides",
		{}
	)
	var sculptor := MTSPlacementController.TerrainSculptorScript.new(host.board.terrain)
	sculptor.apply_patch(cells, tops, sides)
	var support_props := host.board.reconcile_prop_support_state(support_snapshot)
	if removed_props.is_empty():
		host.board.add_props_bulk(added_props)
	elif added_props.is_empty():
		host.board.remove_props_bulk(removed_props)
	else:
		host.board.replace_props_bulk(removed_props, added_props)
	host.prop_terrain_regions_mutated.emit(
		regions,
		support_props,
		added_props,
		removed_props,
		patch.get("terrain_paint_uids", PackedStringArray())
	)


## Commit a native terrain flatten in the same history action as its GLB placement.
static func _commit_prop_terrain_transaction(host: MTSPlacementController,
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	action: String
) -> bool:
	var patch := host._prop_terrain_flatten_patch(added_props)
	if patch.is_empty():
		return false
	if host.undo_redo == null:
		host._apply_prop_terrain_transaction(removed_props, added_props, patch, true)
		return true
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(
		host,
		"_apply_prop_terrain_transaction",
		removed_props,
		added_props,
		patch,
		true
	)
	host.undo_redo.add_undo_method(
		host,
		"_apply_prop_terrain_transaction",
		added_props,
		removed_props,
		patch,
		false
	)
	host.undo_redo.commit_action()
	return true


## Commit validated surface or prop placements through one bulk undo path.
##
## Typed arrays are created only at the BoardDocument boundary; every caller uses
## the same Resource batch, whether it contains one Paint stamp or a large Fill.
static func _commit_placements_bulk(host: MTSPlacementController, placements: Array[Resource], action: String) -> void:
	if placements.is_empty() or host.board == null:
		return
	var mutation_mask := host._mutation_mask_for_resources(placements)

	var do_method := ""
	var undo_method := ""
	var typed_placements: Array
	var prop_placements: Array[PropPlacement] = []
	if placements[0] is SurfacePlacement:
		var surfaces: Array[SurfacePlacement] = []
		for placement: Resource in placements:
			surfaces.append(placement as SurfacePlacement)
		typed_placements = surfaces
		do_method = "add_surfaces_bulk"
		undo_method = "remove_surfaces_bulk"
	elif placements[0] is PropPlacement:
		for placement: Resource in placements:
			prop_placements.append(placement as PropPlacement)
		typed_placements = prop_placements
		do_method = "add_props_bulk"
		undo_method = "remove_props_bulk"
	else:
		push_error("[Tile Studio] cannot commit an unsupported placement batch.")
		return

	var no_removed_props: Array[PropPlacement] = []
	if (
		not prop_placements.is_empty()
		and host._commit_prop_terrain_transaction(
			prop_placements,
			no_removed_props,
			action
		)
	):
		return

	if host.undo_redo == null:
		host.board.call(do_method, typed_placements)
		host.board_mutated.emit(mutation_mask)
		return

	# Board mutation precedes refresh in both directions, so observers always
	# synchronize from the state that the undo history has just established.
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host.board, do_method, typed_placements)
	host.undo_redo.add_undo_method(host.board, undo_method, typed_placements)
	host.undo_redo.add_do_method(host, "_notify_mutated", mutation_mask)
	host.undo_redo.add_undo_method(host, "_notify_mutated", mutation_mask)
	host.undo_redo.commit_action()


## Build preserved face-level remnants for displaced direct terrain textures.
##
## A placement may span many heightfield faces, so replacing one brush footprint
## must not delete the untouched faces that happen to share that placement Resource.
static func _surface_replacement_residuals(host: MTSPlacementController,
	replacements: Array[SurfacePlacement],
	displaced: Array[SurfacePlacement]
) -> Array[SurfacePlacement]:
	var residuals: Array[SurfacePlacement] = []
	var replaced_keys: Dictionary = {}
	for replacement: SurfacePlacement in replacements:
		if replacement.asset_id.is_empty():
			continue
		for uid: String in replacement.terrain_face_uids:
			replaced_keys[uid] = true
	for original: SurfacePlacement in displaced:
		if original.asset_id.is_empty() or original.is_overlay():
			# A decal is one authored stamp. Visible-pixel replacement removes that
			# exact prior stamp rather than inventing face-clipped residual copies.
			continue
		var remaining_uids := PackedStringArray()
		for uid: String in original.terrain_face_uids:
			if not replaced_keys.has(uid):
				remaining_uids.append(uid)
		if remaining_uids.is_empty():
			continue
		var residual := original.duplicate() as SurfacePlacement
		residual.terrain_face_uids = remaining_uids
		residuals.append(residual)
	return residuals


## Atomically replace conflicting placements through the same document undo history.
##
## A replacement first removes only the canonical conflicts discovered during
## validation, then adds the new placement batch. Undo executes the inverse
## atomically, so it restores the displaced resources rather than approximating
## their old geometry from the newly painted brush.
static func _commit_replacements(host: MTSPlacementController,
	placements: Array[Resource],
	displaced: Array[Resource],
	action: String
) -> void:
	if placements.is_empty() or displaced.is_empty() or host.board == null:
		host._commit_placements_bulk(placements, action)
		return
	var mutation_mask := host._mutation_mask_for_resources(placements)

	var replace_method := ""
	var new_typed: Array
	var displaced_typed: Array
	if placements[0] is SurfacePlacement:
		var new_surfaces: Array[SurfacePlacement] = []
		var displaced_surfaces: Array[SurfacePlacement] = []
		for placement: Resource in placements:
			if not placement is SurfacePlacement:
				push_error("[Tile Studio] replacement mixes surface and prop placements.")
				return
			new_surfaces.append(placement as SurfacePlacement)
		for placement: Resource in displaced:
			if not placement is SurfacePlacement:
				push_error("[Tile Studio] surface replacement cannot remove a prop.")
				return
			displaced_surfaces.append(placement as SurfacePlacement)
		new_surfaces.append_array(host._surface_replacement_residuals(
			new_surfaces,
			displaced_surfaces
		))
		replace_method = "replace_surfaces_bulk"
		new_typed = new_surfaces
		displaced_typed = displaced_surfaces
	elif placements[0] is PropPlacement:
		var new_props: Array[PropPlacement] = []
		var displaced_props: Array[PropPlacement] = []
		for placement: Resource in placements:
			if not placement is PropPlacement:
				push_error("[Tile Studio] replacement mixes surface and prop placements.")
				return
			new_props.append(placement as PropPlacement)
		for placement: Resource in displaced:
			if not placement is PropPlacement:
				push_error("[Tile Studio] prop replacement cannot remove a surface.")
				return
			displaced_props.append(placement as PropPlacement)
		if host._commit_prop_terrain_transaction(new_props, displaced_props, action):
			return
		replace_method = "replace_props_bulk"
		new_typed = new_props
		displaced_typed = displaced_props
	else:
		push_error("[Tile Studio] cannot replace with an unsupported placement type.")
		return

	if host.undo_redo == null:
		host.board.call(replace_method, displaced_typed, new_typed)
		host.board_mutated.emit(mutation_mask)
		return

	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host.board, replace_method, displaced_typed, new_typed)
	# Undo methods run in reverse registration order. Register notification
	# first so observers see the restored board after the inverse replacement.
	host.undo_redo.add_undo_method(host, "_notify_mutated", mutation_mask)
	host.undo_redo.add_undo_method(host.board, replace_method, new_typed, displaced_typed)
	host.undo_redo.add_do_method(host, "_notify_mutated", mutation_mask)
	host.undo_redo.commit_action()


## Remove one surface placement through the global document undo history.
static func _commit_remove_surface(host: MTSPlacementController, placement: SurfacePlacement, action: String) -> void:
	if host.undo_redo == null:
		host.board.remove_surface(placement)
		host.board_mutated.emit(MTSPlacementController.BoardMutation.SURFACES)
		return
	# Pin to the GLOBAL history explicitly.
	#
	# Without a target object EditorUndoRedoManager guesses which history an
	# action belongs to, and board edits are not tied to any scene node -- so they
	# landed in whichever scene history happened to be active and were discarded
	# when the editor switched away from it. That is what made undo appear to only
	# go back a step or two. The board is a document of its own, so its history is
	# the global one.
	# Keep undo replay in insertion order so the board changes before observers rebuild.
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host.board, "remove_surface", placement)
	host.undo_redo.add_undo_method(host.board, "add_surface", placement)
	host.undo_redo.add_do_method(host, "_notify_mutated", MTSPlacementController.BoardMutation.SURFACES)
	host.undo_redo.add_undo_method(host, "_notify_mutated", MTSPlacementController.BoardMutation.SURFACES)
	host.undo_redo.commit_action()


static func _commit_remove_prop(host: MTSPlacementController, placement: PropPlacement, action: String) -> void:
	if host.undo_redo == null:
		host.board.remove_prop(placement)
		host.board_mutated.emit(MTSPlacementController.BoardMutation.PROPS)
		return
	# Pin to the GLOBAL history explicitly.
	#
	# Without a target object EditorUndoRedoManager guesses which history an
	# action belongs to, and board edits are not tied to any scene node -- so they
	# landed in whichever scene history happened to be active and were discarded
	# when the editor switched away from it. That is what made undo appear to only
	# go back a step or two. The board is a document of its own, so its history is
	# the global one.
	# Keep undo replay in insertion order so the board changes before observers rebuild.
	host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	host.undo_redo.add_do_method(host.board, "remove_prop", placement)
	host.undo_redo.add_undo_method(host.board, "add_prop", placement)
	host.undo_redo.add_do_method(host, "_notify_mutated", MTSPlacementController.BoardMutation.PROPS)
	host.undo_redo.add_undo_method(host, "_notify_mutated", MTSPlacementController.BoardMutation.PROPS)
	host.undo_redo.commit_action()


## Emit one already-classified mutation after its document method completes.
static func _notify_mutated(host: MTSPlacementController, mutation_mask: int) -> void:
	host.board_mutated.emit(mutation_mask)
