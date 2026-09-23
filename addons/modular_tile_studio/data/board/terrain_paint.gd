@tool
extends RefCounted

## Terrain paint behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Return the stable terrain paint UIDs one surface placement covers.
##
## This is the placement's complete spatial extent. Terrain owns the geometry, so
## a placement is exactly the set of terrain faces it paints.
static func surface_paint_uids(host: BoardDocument, placement: SurfacePlacement) -> PackedStringArray:
	if placement == null or placement.is_overlay():
		return PackedStringArray()
	return placement.terrain_face_uids


## Drop every authored material attachment whose terrain face no longer exists.
##
## Terrain is the single answer to where the ground is, so deleting or erasing it
## must delete what was painted on it. Without this, a placement keeps referencing
## a vanished face: the renderer silently ignores it, but the board still carries
## invisible material metadata that reappears if that cell is ever filled again.
##
## Returns the paint UIDs that were released so the caller can drop the matching
## Return whether one canonical terrain face UID belongs to the supplied cell scope.
##
## Top, side, and skirt identities all begin with their owning X,Z cell. Invalid
## identities are left untouched during a regional edit because that edit cannot
## prove where they belong; a full reset still validates them against all live UIDs.
static func _terrain_face_uid_is_in_cells(uid: String, cells: Rect2i) -> bool:
	var separator := uid.find(":")
	if separator < 0:
		return false
	var coordinates := uid.substr(separator + 1).split(",")
	if (
		coordinates.size() < 2
		or not coordinates[0].is_valid_int()
		or not coordinates[1].is_valid_int()
	):
		return false
	return cells.has_point(Vector2i(int(coordinates[0]), int(coordinates[1])))


## Remove terrain paint whose canonical face disappeared inside an optional edit scope.
##
## Sculpting passes its dirty rectangle so this compares only local face identities.
## An empty rectangle performs the complete scan required after clearing all terrain.
static func prune_orphaned_terrain_paint(host: BoardDocument,
	affected_cells: Rect2i = Rect2i()
) -> PackedStringArray:
	var scoped := affected_cells.size.x > 0 and affected_cells.size.y > 0
	var live_uids := host.terrain.face_uid_set(affected_cells)
	# Several paint placements can reference the same face, so releases are
	# collected as a set. Native decals do not own material-paint image data.
	var released_set: Dictionary = {}
	var released := PackedStringArray()
	var emptied: Array[SurfacePlacement] = []
	var changed := false
	for placement: SurfacePlacement in host.surfaces:
		var retained := PackedStringArray()
		for uid: String in placement.terrain_face_uids:
			if scoped and not BoardDocument._terrain_face_uid_is_in_cells(uid, affected_cells):
				retained.append(uid)
			elif live_uids.has(uid):
				retained.append(uid)
			elif not placement.is_decal() and not released_set.has(uid):
				released_set[uid] = true
				released.append(uid)
		if retained.size() == placement.terrain_face_uids.size():
			continue
		changed = true
		placement.terrain_face_uids = retained
		# A placement is exactly the set of terrain faces it attaches to, so one
		# whose receiver disappeared is no longer visible paint or decal state.
		if retained.is_empty():
			emptied.append(placement)
	if not emptied.is_empty():
		host.remove_surfaces_bulk(emptied)
	elif changed:
		host.rebuild_indexes()
		host.board_changed.emit()
	return released


## Remove paint only from explicitly named terrain faces that no longer exist.
##
## GLB contact patches know exactly which side bands they changed, so this path
## avoids scanning unrelated surface placements or rebuilding document indexes.
static func prune_terrain_paint_uids(host: BoardDocument,
	candidate_uids: PackedStringArray
) -> PackedStringArray:
	var candidates: Dictionary = {}
	var affected_placements: Dictionary = {}
	for uid: String in candidate_uids:
		candidates[uid] = true
		var painted := host._paint_uid_index.get(uid, null) as SurfacePlacement
		if painted != null:
			affected_placements[painted.get_instance_id()] = painted
		for value: Variant in host._shader_decal_uid_index.get(uid, []) as Array:
			var shader_decal := value as SurfacePlacement
			if shader_decal != null:
				affected_placements[shader_decal.get_instance_id()] = shader_decal
	if affected_placements.is_empty():
		return PackedStringArray()

	var live_uids_by_cell: Dictionary = {}
	var released := PackedStringArray()
	var emptied: Array[SurfacePlacement] = []
	var changed := false
	for placement_value: Variant in affected_placements.values():
		var placement := placement_value as SurfacePlacement
		if placement == null:
			continue
		var retained := PackedStringArray()
		var placement_changed := false
		for uid: String in placement.terrain_face_uids:
			if not candidates.has(uid):
				retained.append(uid)
				continue
			var separator := uid.find(":")
			var coordinates := (
				uid.substr(separator + 1).split(",")
				if separator >= 0
				else PackedStringArray()
			)
			if (
				coordinates.size() < 2
				or not coordinates[0].is_valid_int()
				or not coordinates[1].is_valid_int()
			):
				retained.append(uid)
				continue
			var cell := Vector2i(int(coordinates[0]), int(coordinates[1]))
			if not live_uids_by_cell.has(cell):
				live_uids_by_cell[cell] = host.terrain.face_uid_set(
					Rect2i(cell, Vector2i.ONE)
				)
			var live_uids: Dictionary = live_uids_by_cell[cell]
			if live_uids.has(uid):
				retained.append(uid)
				continue
			placement_changed = true
			if not placement.is_decal():
				released.append(uid)
		if not placement_changed:
			continue
		changed = true
		host._unindex_spatial_placement(placement)
		placement.terrain_face_uids = retained
		if retained.is_empty():
			emptied.append(placement)
		else:
			host._index_spatial_placement(placement)
	for placement: SurfacePlacement in emptied:
		host.surfaces.erase(placement)
	if changed:
		host.board_changed.emit()
	return released
