@tool
extends RefCounted

## Movement behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Return the stable serialized key for one horizontal movement cell.
static func movement_cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


## Parse one stored movement-cell key without inventing a replacement coordinate.
static func movement_cell_from_key(key: String) -> Variant:
	var components := key.split(",", false)
	if (
		components.size() != 2
		or not String(components[0]).is_valid_int()
		or not String(components[1]).is_valid_int()
	):
		return null
	return Vector2i(int(components[0]), int(components[1]))


## Return whether one horizontal address names authored terrain.
static func movement_cell_exists(host: BoardDocument, cell: Vector2i) -> bool:
	return host.terrain != null and host.terrain.is_cell_filled(cell)


## Return whether the author explicitly removed one terrain cell from movement.
static func movement_cell_is_unwalkable(host: BoardDocument, cell: Vector2i) -> bool:
	return host.movement_unwalkable_cells.has(BoardDocument.movement_cell_key(cell))


## Return the descriptive ground-effect label authored on one movement cell.
static func movement_ground_effect(host: BoardDocument, cell: Vector2i) -> String:
	return String(host.movement_ground_effects.get(BoardDocument.movement_cell_key(cell), ""))


## Return the complete editable state of one movement cell for UI and undo.
static func movement_cell_state(host: BoardDocument, cell: Vector2i) -> Dictionary:
	return {
		"exists": host.movement_cell_exists(cell),
		"unwalkable": host.movement_cell_is_unwalkable(cell),
		"ground_effect": host.movement_ground_effect(cell),
	}


## Apply one validated movement-cell state and optionally publish the board mutation.
static func apply_movement_cell_state(host: BoardDocument,
	cell: Vector2i,
	state: Dictionary,
	notify_change: bool = true
) -> bool:
	if not host.movement_cell_exists(cell):
		push_error("[Tile Studio] movement cell %s has no authored terrain." % cell)
		return false
	var effect := String(state.get("ground_effect", "")).strip_edges()
	if effect.length() > BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH:
		push_error(
			"[Tile Studio] ground-effect label at %s exceeds %d characters."
			% [cell, BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH]
		)
		return false
	var key := BoardDocument.movement_cell_key(cell)
	var unwalkable := bool(state.get("unwalkable", false))
	if (
		host.movement_unwalkable_cells.has(key) == unwalkable
		and String(host.movement_ground_effects.get(key, "")) == effect
	):
		return false
	if unwalkable:
		host.movement_unwalkable_cells[key] = true
	else:
		host.movement_unwalkable_cells.erase(key)
	if effect.is_empty():
		host.movement_ground_effects.erase(key)
	else:
		host.movement_ground_effects[key] = effect
	if notify_change:
		host.board_changed.emit()
	return true


## Set or clear the manual movement block on one authored terrain cell.
static func set_movement_cell_unwalkable(host: BoardDocument, cell: Vector2i, unwalkable: bool) -> bool:
	var state := host.movement_cell_state(cell)
	state["unwalkable"] = unwalkable
	return host.apply_movement_cell_state(cell, state)


## Set or clear one plain ground-effect label on an authored terrain cell.
static func set_movement_ground_effect(host: BoardDocument, cell: Vector2i, label: String) -> bool:
	var state := host.movement_cell_state(cell)
	state["ground_effect"] = label
	return host.apply_movement_cell_state(cell, state)


## Return movement-cell keys as coordinates in stable numeric order.
static func _sorted_movement_cells(host: BoardDocument, source: Dictionary) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for key_value: Variant in source.keys():
		var parsed: Variant = BoardDocument.movement_cell_from_key(String(key_value))
		if parsed is Vector2i:
			cells.append(parsed as Vector2i)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	return cells


## Return a runtime-safe snapshot of authored ground-effect labels by cell.
static func movement_ground_effect_snapshot(host: BoardDocument) -> Dictionary:
	var snapshot: Dictionary = {}
	for cell: Vector2i in host._sorted_movement_cells(host.movement_ground_effects):
		snapshot[cell] = host.movement_ground_effect(cell)
	return snapshot


## Remove movement annotations whose terrain cell no longer exists.
static func prune_movement_grid_cells(host: BoardDocument) -> int:
	var removed := 0
	for source: Dictionary in [host.movement_unwalkable_cells, host.movement_ground_effects]:
		var stale_keys: Array[String] = []
		for key_value: Variant in source.keys():
			var key := String(key_value)
			var parsed: Variant = BoardDocument.movement_cell_from_key(key)
			if not parsed is Vector2i or not host.movement_cell_exists(parsed as Vector2i):
				stale_keys.append(key)
		for key: String in stale_keys:
			source.erase(key)
			removed += 1
	return removed


## Preview one global collision threshold across every placed prop instance.
static func movement_collision_filter_report(host: BoardDocument,
	threshold_percent: float = -1.0
) -> Dictionary:
	var threshold := (
		host.movement_collision_min_triangle_share_percent
		if threshold_percent < 0.0
		else clampf(threshold_percent, 0.0, 100.0)
	)
	var errors := PackedStringArray()
	var missing_asset_ids := PackedStringArray()
	var placed_asset_ids: Dictionary = {}
	var raw_voxel_count := 0
	var active_voxel_count := 0
	for placement: PropPlacement in host.props:
		var asset := host.resolve_prop_asset(placement)
		if asset == null:
			errors.append("unknown prop asset '%s'" % placement.asset_id)
			continue
		placed_asset_ids[asset.asset_id] = true
		var raw_error := placement.voxel_scan_error(asset, 0.0)
		if not raw_error.is_empty():
			if not errors.has(raw_error):
				errors.append(raw_error)
			continue
		var raw_voxels := placement.oriented_voxels(asset, 0.0)
		raw_voxel_count += raw_voxels.size()
		if threshold <= 0.0:
			active_voxel_count += raw_voxels.size()
			continue
		var filter_error := placement.voxel_scan_error(asset, threshold)
		if not filter_error.is_empty():
			if not errors.has(filter_error):
				errors.append(filter_error)
			if (
				not asset.prop_collision_measurements_ready()
				and not missing_asset_ids.has(asset.asset_id)
			):
				missing_asset_ids.append(asset.asset_id)
			# An invalid preview leaves the complete currently active scan intact.
			active_voxel_count += raw_voxels.size()
			continue
		active_voxel_count += placement.oriented_voxels(asset, threshold).size()
	return {
		"valid": errors.is_empty(),
		"threshold_percent": threshold,
		"placed_asset_count": placed_asset_ids.size(),
		"placed_instance_count": host.props.size(),
		"raw_voxel_count": raw_voxel_count,
		"active_voxel_count": active_voxel_count,
		"removed_voxel_count": raw_voxel_count - active_voxel_count,
		"missing_measurement_asset_ids": missing_asset_ids,
		"errors": errors,
	}


## Commit one board-wide collision threshold only when every placed instance can use it.
static func set_movement_collision_min_triangle_share_percent(host: BoardDocument,
	threshold_percent: float
) -> Dictionary:
	var report := host.movement_collision_filter_report(threshold_percent)
	if not bool(report.get("valid", false)):
		return report
	var threshold := float(report["threshold_percent"])
	if is_equal_approx(
		host.movement_collision_min_triangle_share_percent,
		threshold
	):
		return report
	host.movement_collision_min_triangle_share_percent = threshold
	host.rebuild_indexes()
	host.board_changed.emit()
	return report
