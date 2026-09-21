@tool
extends RefCounted

## Terrain contact behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

# --- Undo/redo wrappers ---------------------------------------------------
#
# The document exposes plain mutators; the editor layer wraps them so every
# action is undoable from the first commit rather than retrofitted (spec 43).


## Return one prop's existing heightfield footprint as an absolute rectangle.
static func _prop_contact_bounds(host: MTSPlacementController,
	prop: PropPlacement,
	asset: TileAsset,
	terrain: TerrainMesh
) -> Rect2i:
	var bounds := Rect2i()
	if prop == null or asset == null or terrain == null:
		return bounds
	for cell: Vector2i in prop.footprint_cells(asset):
		if not terrain.has_cell(cell):
			continue
		var cell_rect := Rect2i(cell, Vector2i.ONE)
		bounds = cell_rect if bounds.size.x <= 0 else bounds.merge(cell_rect)
	return bounds


## Group contact instances whose local preview neighbourhoods overlap.
##
## Separate groups receive separate bounded TerrainMesh copies, so distant GLBs
## never make atomic patch calculation copy the terrain between them.
static func _prop_contact_groups(host: MTSPlacementController, props: Array[PropPlacement]) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	if host.board == null or host.board.terrain == null:
		return groups
	var terrain_rect := Rect2i(
		host.board.terrain.origin_cell,
		host.board.terrain.size_cells
	)
	for prop: PropPlacement in props:
		if prop == null or prop.support != PropPlacement.SUPPORT_FLOOR:
			continue
		var asset := host.board.resolve_prop_asset(prop)
		if asset == null or not asset.prop_contact_flatten:
			continue
		var bounds := host._prop_contact_bounds(prop, asset, host.board.terrain)
		if bounds.size.x <= 0 or bounds.size.y <= 0:
			continue
		var pending_bounds := bounds.grow(2).intersection(terrain_rect)
		var pending_props: Array[PropPlacement] = [prop]
		var group_index := 0
		while group_index < groups.size():
			var group: Dictionary = groups[group_index]
			var group_bounds: Rect2i = group["bounds"]
			if not group_bounds.grow(1).intersects(pending_bounds):
				group_index += 1
				continue
			pending_bounds = pending_bounds.merge(group_bounds)
			for value: Variant in group["props"] as Array:
				var grouped_prop := value as PropPlacement
				if grouped_prop != null and not pending_props.has(grouped_prop):
					pending_props.append(grouped_prop)
			groups.remove_at(group_index)
			group_index = 0
		groups.append({
			"bounds": pending_bounds,
			"props": pending_props,
		})
	return groups


## Return every side-face paint UID whose existence may change in one patch.
static func _terrain_paint_uids_for_patch(host: MTSPlacementController, patch: Dictionary) -> PackedStringArray:
	var side_keys: Dictionary = {}
	for state_name: String in ["before_sides", "after_sides"]:
		for key_value: Variant in (patch.get(state_name, {}) as Dictionary).keys():
			side_keys[String(key_value)] = true
	var result := PackedStringArray()
	for key_value: Variant in side_keys.keys():
		var key := String(key_value)
		var parts := key.split(",")
		if parts.size() != 3:
			continue
		var maximum_band_count := 0
		for state_name: String in ["before_sides", "after_sides"]:
			var profiles: Dictionary = patch.get(state_name, {})
			var profile: Array = profiles.get(key, [])
			if profile.size() != 6:
				continue
			var lowest := minf(float(profile[2]), float(profile[4]))
			var highest := maxf(float(profile[3]), float(profile[5]))
			maximum_band_count = maxi(
				maximum_band_count,
				TerrainMesh.bands_in_span(lowest, highest).size()
			)
		var cell := Vector2i(int(parts[0]), int(parts[1]))
		var edge := int(parts[2])
		for band: int in maximum_band_count:
			result.append(TerrainMesh.band_uid(cell, edge, band))
	return result


## Combine independent local preview patches into one atomic undo record.
static func _combine_prop_terrain_patches(host: MTSPlacementController, patches: Array[Dictionary]) -> Dictionary:
	var cells := PackedVector2Array()
	var before_tops := PackedFloat32Array()
	var after_tops := PackedFloat32Array()
	var before_sides: Dictionary = {}
	var after_sides: Dictionary = {}
	var regions: Array[Rect2i] = []
	var included_cells: Dictionary = {}
	for patch: Dictionary in patches:
		var patch_cells: PackedVector2Array = patch.get(
			"cells",
			PackedVector2Array()
		)
		for cell_value: Vector2 in patch_cells:
			var cell := Vector2i(cell_value)
			if included_cells.has(cell):
				push_error(
					"[Tile Studio] overlapping GLB contact groups produced duplicate terrain cells."
				)
				return {}
			included_cells[cell] = true
		cells.append_array(patch_cells)
		before_tops.append_array(
			patch.get("before_tops", PackedFloat32Array())
		)
		after_tops.append_array(
			patch.get("after_tops", PackedFloat32Array())
		)
		for key_value: Variant in (patch.get("before_sides", {}) as Dictionary).keys():
			var key := String(key_value)
			if before_sides.has(key):
				push_error(
					"[Tile Studio] overlapping GLB contact groups produced duplicate side faces."
				)
				return {}
			before_sides[key] = (patch["before_sides"] as Dictionary)[key]
			after_sides[key] = (patch["after_sides"] as Dictionary).get(key, [])
		for value: Variant in patch.get("terrain_regions", []) as Array:
			if value is Rect2i:
				regions.append(value as Rect2i)
	if cells.is_empty() and before_sides.is_empty():
		return {}
	var combined := {
		"cells": cells,
		"before_tops": before_tops,
		"after_tops": after_tops,
		"before_sides": before_sides,
		"after_sides": after_sides,
		"terrain_regions": regions,
	}
	combined["terrain_paint_uids"] = host._terrain_paint_uids_for_patch(combined)
	return combined


## Return the exact disjoint terrain regions stored in one contact patch.
static func _patch_terrain_regions(host: MTSPlacementController, patch: Dictionary) -> Array[Rect2i]:
	var regions: Array[Rect2i] = []
	for value: Variant in patch.get("terrain_regions", []) as Array:
		if value is Rect2i:
			regions.append(value as Rect2i)
	return regions


## Return whether at least one floor prop explicitly requests terrain flattening.
static func _props_request_contact_flatten(host: MTSPlacementController, props: Array[PropPlacement]) -> bool:
	if host.board == null:
		return false
	for prop: PropPlacement in props:
		if prop == null or prop.support != PropPlacement.SUPPORT_FLOOR:
			continue
		var asset := host.board.resolve_prop_asset(prop)
		if asset != null and asset.prop_contact_flatten:
			return true
	return false


## Apply each prop asset's selected flatten mode to one supplied terrain instance.
##
## The caller decides whether this is the live terrain or a duplicate. Ordinary
## placement runs first and decides where the GLB stands; this levels the pad to
## that answer afterwards. Reading prop_terrain_support_height from the terrain as
## it is when the prop is reached -- rather than computing a separate maximum
## corner -- is what keeps the model on its own pad: flattening every footprint
## quad to that height leaves the height unchanged when it is re-derived, so the
## operation is stable no matter how many times it runs.
static func _flatten_props_on_terrain(host: MTSPlacementController,
	target_terrain: TerrainMesh,
	props: Array[PropPlacement],
	report_messages: bool
) -> Dictionary:
	if target_terrain == null or target_terrain.is_empty():
		return {}
	var sculptor := MTSPlacementController.TerrainSculptorScript.new(target_terrain)
	var terrain_regions: Array[Rect2i] = []
	sculptor.begin_stroke()
	for prop: PropPlacement in props:
		if prop == null or prop.support != PropPlacement.SUPPORT_FLOOR:
			continue
		var asset := host.board.resolve_prop_asset(prop)
		if asset == null:
			if report_messages:
				push_error(
					"[Tile Studio] cannot flatten terrain for unresolved GLB '%s'; placement continues unchanged."
					% prop.asset_id
				)
			continue
		if not asset.prop_contact_flatten:
			continue
		var support_height_m := host.board.prop_terrain_support_height(prop, target_terrain)
		var footprint := prop.footprint_cells(asset)
		var existing_cells: Array[Vector2i] = []
		for cell: Vector2i in footprint:
			if target_terrain.is_cell_filled(cell):
				existing_cells.append(cell)
		if existing_cells.is_empty():
			if report_messages:
				push_warning(
					"[Tile Studio] GLB '%s' has no existing heightfield quads under its voxel footprint; placement continues unchanged."
					% prop.asset_id
				)
			continue
		if report_messages and existing_cells.size() != footprint.size():
			push_warning(
				"[Tile Studio] GLB '%s' overhangs the heightfield; flattened %d of %d voxel-footprint quads and kept placement."
				% [prop.asset_id, existing_cells.size(), footprint.size()]
			)
		var result: Dictionary
		if asset.prop_contact_flatten_smooth:
			result = sculptor.flatten_cells_smooth(
				existing_cells,
				support_height_m
			)
		else:
			result = sculptor.flatten_cells(existing_cells, support_height_m)
		var changed_bounds: Rect2i = result.get("bounds", Rect2i())
		if changed_bounds.size.x > 0 and changed_bounds.size.y > 0:
			# Side-face ownership can change one cell beyond the written tops.
			terrain_regions.append(changed_bounds.grow(1))
	var patch := sculptor.finish_stroke()
	if not patch.is_empty():
		patch["terrain_regions"] = terrain_regions
	return patch


## Build the exact reversible heightfield patch requested by floor GLB assets.
##
## Each overlapping instance neighbourhood is previewed on its own terrain slice,
## then the disjoint sparse patches are combined into one atomic undo record.
static func _prop_terrain_flatten_patch(host: MTSPlacementController,
	props: Array[PropPlacement],
	report_messages: bool = true
) -> Dictionary:
	if host.board == null or not host._props_request_contact_flatten(props):
		return {}
	if host.board.terrain == null or host.board.terrain.is_empty():
		if report_messages:
			push_warning(
				"[Tile Studio] GLB terrain flatten is enabled, but the board has no heightfield; placement continues unchanged."
			)
		return {}
	var local_patches: Array[Dictionary] = []
	for group: Dictionary in host._prop_contact_groups(props):
		var preview_terrain := host.board.terrain.duplicate_region(group["bounds"])
		var group_props: Array[PropPlacement] = []
		for value: Variant in group["props"] as Array:
			var prop := value as PropPlacement
			if prop != null:
				group_props.append(prop)
		var patch := host._flatten_props_on_terrain(
			preview_terrain,
			group_props,
			report_messages
		)
		if not patch.is_empty():
			local_patches.append(patch)
	return host._combine_prop_terrain_patches(local_patches)


## Return the exact world minimum corner shared by a preview's collision voxels and art.
##
## No prediction of the pending flatten happens here any more. Contact flatten now
## levels the pad to wherever ordinary placement already stands the GLB, so the
## canonical pose is unchanged by the commit and the hovering preview shows the
## height the board will actually store.
static func _prop_preview_world_origin(host: MTSPlacementController, prop: PropPlacement) -> Vector3:
	if prop == null:
		return Vector3.ZERO
	if host.board == null:
		return Vector3(prop.origin)
	return host.board.prop_world_origin(prop)


## Apply a reversible terrain-only patch and resynchronize local support props.
##
## The sparse height write is followed by targeted support reconciliation so
## observers receive only the instance neighbourhoods whose terrain changed.
static func _apply_existing_prop_contact_patch(host: MTSPlacementController,
	patch: Dictionary,
	use_after_state: bool
) -> void:
	if host.board == null or host.board.terrain == null:
		push_error("[Tile Studio] cannot apply an existing GLB flatten without a board heightfield.")
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
	host.board.board_changed.emit()
	var no_props: Array[PropPlacement] = []
	host.prop_terrain_regions_mutated.emit(
		regions,
		support_props,
		no_props,
		no_props,
		patch.get("terrain_paint_uids", PackedStringArray())
	)


## Apply this asset's enabled flatten mode to every existing floor instance.
##
## Disabling flatten changes future behavior but does not invent pre-flatten terrain
## that the board no longer stores. Enabling it, or changing its smooth mode, commits
## one undoable terrain patch covering every matching instance.
static func apply_asset_contact_flatten(host: MTSPlacementController, asset_id: String) -> int:
	if host.board == null or asset_id.is_empty():
		return 0
	var asset := host.board.resolve_asset(asset_id)
	if asset == null or not asset.is_prop():
		push_error("[Tile Studio] cannot apply flatten for unknown GLB asset '%s'." % asset_id)
		return 0
	if not asset.prop_contact_flatten:
		return 0
	var matching_props: Array[PropPlacement] = []
	for prop: PropPlacement in host.board.props:
		if prop.asset_id == asset_id and prop.support == PropPlacement.SUPPORT_FLOOR:
			matching_props.append(prop)
	if matching_props.is_empty():
		return 0
	var patch := host._prop_terrain_flatten_patch(matching_props)
	if patch.is_empty():
		return 0
	var action := "Flatten terrain under %d '%s' instance%s" % [
		matching_props.size(),
		asset.display_name if not asset.display_name.is_empty() else asset.asset_id,
		"" if matching_props.size() == 1 else "s",
	]
	if host.undo_redo == null:
		host._apply_existing_prop_contact_patch(patch, true)
	else:
		host.undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
		host.undo_redo.add_do_method(
			host,
			"_apply_existing_prop_contact_patch",
			patch,
			true
		)
		host.undo_redo.add_undo_method(
			host,
			"_apply_existing_prop_contact_patch",
			patch,
			false
		)
		host.undo_redo.commit_action()
	return matching_props.size()
