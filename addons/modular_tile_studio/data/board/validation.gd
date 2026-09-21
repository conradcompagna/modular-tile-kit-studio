@tool
extends RefCounted

## Validation behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Return every surface displaced by a candidate painting the same terrain faces.
##
## Conflicts come straight from the canonical paint index, so replacement never
## guesses from art bounds or maintains a second spatial map.
static func surface_conflicting_placements(host: BoardDocument,
	placement: SurfacePlacement
) -> Array[SurfacePlacement]:
	var conflicts: Array[SurfacePlacement] = []
	# Native decals layer over terrain paint, so they claim no paint occupancy.
	if placement == null or placement.is_overlay():
		return conflicts
	for uid: String in placement.terrain_face_uids:
		var occupant := host.surface_at_paint_uid(uid)
		if occupant != null and occupant != placement and not conflicts.has(occupant):
			conflicts.append(occupant)
	return conflicts


## Return every prop displaced by a candidate claiming its solid voxels.
static func prop_conflicting_placements(host: BoardDocument,
	placement: PropPlacement
) -> Array[PropPlacement]:
	var conflicts: Array[PropPlacement] = []
	if placement == null:
		return conflicts
	for cell: Vector3i in host.prop_occupied_cells(placement):
		var occupant := host.prop_at(cell)
		if occupant != null and not conflicts.has(occupant):
			conflicts.append(occupant)
	return conflicts


## Validate one surface against its reference contract and current terrain paint.
static func validate_surface(host: BoardDocument,
	placement: SurfacePlacement,
	ignore: SurfacePlacement = null
) -> Dictionary:
	var reference_error := host._validate_surface_reference(placement)
	if not reference_error.is_empty():
		return {"valid": false, "reason": reference_error, "conflicts": []}

	if host.terrain == null or host.terrain.is_empty():
		return {
			"valid": false,
			"reason": "surface stamping requires a heightfield",
			"conflicts": [],
		}
	if placement.terrain_face_uids.is_empty():
		return {
			"valid": false,
			"reason": "surface stamp has no canonical heightfield faces",
			"conflicts": [],
		}
	# Native decals claim no document occupancy, so overlapping stamps remain
	# separate authored placements that can be selected and deleted independently.
	if placement.is_decal():
		return {"valid": true, "reason": "", "conflicts": []}
	# A shader decal becomes one direct PBR layer on the receiving terrain
	# material. Rejecting overlap keeps that material representation exact and
	# avoids silently hiding or flattening either authored decal.
	if placement.is_shader_decal():
		var decal_conflicts: Array = []
		for uid: String in placement.terrain_face_uids:
			for existing: SurfacePlacement in host.shader_decals_at_paint_uid(uid):
				if existing != ignore and existing != placement:
					decal_conflicts.append(uid)
					break
		if not decal_conflicts.is_empty():
			return {
				"valid": false,
				"reason": "shader decals overlap at %s" % ", ".join(decal_conflicts.slice(0, 3)),
				"conflicts": decal_conflicts,
			}
		return {"valid": true, "reason": "", "conflicts": []}

	var conflicts: Array = []
	for uid: String in placement.terrain_face_uids:
		var occupant := host.surface_at_paint_uid(uid)
		if occupant != null and occupant != ignore and occupant != placement:
			conflicts.append(uid)

	if not conflicts.is_empty():
		return {
			"valid": false,
			"reason": "occupied surface area at %s" % ", ".join(conflicts.slice(0, 3)),
			"conflicts": conflicts,
		}
	return {"valid": true, "reason": "", "conflicts": []}


## Validate one prop against its reference, terrain support, and solid occupancy.
static func validate_prop(host: BoardDocument,
	placement: PropPlacement,
	ignore: PropPlacement = null
) -> Dictionary:
	var reference_error := host._validate_prop_reference(placement)
	if not reference_error.is_empty():
		return {"valid": false, "reason": reference_error, "conflicts": []}

	var conflicts: Array = []
	for cell: Vector3i in host.prop_occupied_cells(placement):
		var key := BoardDocument.K.voxel_key(cell)
		var occupant := host._solid_index.get(key, null) as Resource
		if occupant != null and occupant != ignore and occupant != placement:
			conflicts.append(key)

	if conflicts.is_empty():
		return {"valid": true, "reason": "", "conflicts": []}
	return {
		"valid": false,
		"reason": "occupied prop volume at %s" % ", ".join(conflicts.slice(0, 3)),
		"conflicts": conflicts,
	}


## Return the exact terrain elevation a floor prop's base rests at.
##
## The unique XZ projection of the prop's canonical voxels is the only footprint
## consulted, so holes and irregular outlines are preserved. The highest cell under
## that footprint wins: a prop bridging a step rests on the step instead of sinking
## into it.
##
## This is the one elevation answer for a floor prop. Every world-space consumer
## applies this exact value, while lattice indexes derive only the integer cells
## overlapped by the resulting boxes.
##
## A supplied terrain is used only to predict an explicit pending flatten before
## commit. Omitting it reads the board's canonical terrain.
static func prop_terrain_support_height(host: BoardDocument,
	placement: PropPlacement,
	support_terrain: TerrainMesh = null
) -> float:
	var sampled_terrain := support_terrain if support_terrain != null else host.terrain
	if placement == null or sampled_terrain == null or sampled_terrain.is_empty():
		return float(placement.origin.y) if placement != null else 0.0
	var asset := host.resolve_prop_asset(placement)
	var highest := -INF
	for cell: Vector2i in placement.footprint_cells(asset):
		if sampled_terrain.is_cell_filled(cell):
			highest = maxf(highest, sampled_terrain.cell_walk_height(cell))
	if highest == -INF:
		return float(placement.origin.y)
	return highest


## Return every canonical surface placement that renders.
static func renderable_surfaces(host: BoardDocument) -> Array[SurfacePlacement]:
	var result: Array[SurfacePlacement] = []
	result.append_array(host.surfaces)
	return result


## Validate one surface's asset reference and its type.
static func _validate_surface_reference(host: BoardDocument, placement: SurfacePlacement) -> String:
	if placement == null:
		return "surface placement is null"
	var reference_error := placement.reference_error()
	if not reference_error.is_empty():
		return reference_error
	var asset := host.resolve_surface_asset(placement)
	if asset == null:
		return "unknown asset '%s'" % placement.asset_id
	if not asset.is_surface():
		return "'%s' is not a surface asset" % placement.asset_id
	return ""


## Validate one prop's asset reference, type, and exact measured occupancy.
static func _validate_prop_reference(host: BoardDocument, placement: PropPlacement) -> String:
	if placement == null:
		return "prop placement is null"
	var reference_error := placement.reference_error()
	if not reference_error.is_empty():
		return reference_error
	var asset := host.resolve_prop_asset(placement)
	if asset == null:
		return "unknown asset '%s'" % placement.asset_id
	if not asset.is_prop():
		return "'%s' is not a prop asset" % placement.asset_id
	var voxel_scan_error := placement.voxel_scan_error(
		asset,
		host.movement_collision_min_triangle_share_percent
	)
	if not voxel_scan_error.is_empty():
		return voxel_scan_error
	return ""


## Validate the complete document against its canonical terrain and occupancy.
static func validate_all(host: BoardDocument) -> Dictionary:
	var errors := PackedStringArray()
	var missing_assets := PackedStringArray()
	var seen_paint_uids: Dictionary = {}
	var seen_voxels: Dictionary = {}
	var seen_pack_ids: Dictionary = {}
	var seen_marker_ids: Dictionary = {}
	var seen_marker_cells: Dictionary = {}

	for terrain_error in host.terrain.validate_definition():
		errors.append(terrain_error)

	for key_value: Variant in host.movement_unwalkable_cells.keys():
		var blocked_key := String(key_value)
		var blocked_cell: Variant = BoardDocument.movement_cell_from_key(blocked_key)
		if not blocked_cell is Vector2i:
			errors.append("invalid movement-cell key '%s'" % blocked_key)
		elif not host.movement_cell_exists(blocked_cell as Vector2i):
			errors.append("manual movement block %s has no authored terrain" % blocked_cell)
	for key_value: Variant in host.movement_ground_effects.keys():
		var effect_key := String(key_value)
		var effect_cell: Variant = BoardDocument.movement_cell_from_key(effect_key)
		var effect_label := String(host.movement_ground_effects[key_value]).strip_edges()
		if not effect_cell is Vector2i:
			errors.append("invalid ground-effect cell key '%s'" % effect_key)
		elif not host.movement_cell_exists(effect_cell as Vector2i):
			errors.append("ground effect %s has no authored terrain" % effect_cell)
		if effect_label.is_empty():
			errors.append("ground effect '%s' has an empty label" % effect_key)
		elif effect_label.length() > BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH:
			errors.append(
				"ground effect '%s' exceeds %d characters"
				% [effect_key, BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH]
			)

	for pack: EnemyPack in host.enemy_packs:
		if pack == null:
			errors.append("enemy pack record is null")
			continue
		for pack_error in pack.validate_definition():
			errors.append(pack_error)
		if seen_pack_ids.has(pack.pack_id):
			errors.append("duplicate enemy pack id '%s'" % pack.pack_id)
		seen_pack_ids[pack.pack_id] = true

	for monster_value: Variant in host.monster_visual_assets.keys():
		if not (monster_value is String):
			errors.append("monster visual id must be a string")
			continue
		var monster_id: String = monster_value
		var asset_value: Variant = host.monster_visual_assets[monster_value]
		if not (asset_value is String):
			errors.append("monster visual '%s' asset id must be a string" % monster_id)
			continue
		var asset_id: String = asset_value
		var assignment_report := host.validate_monster_visual_assignment(monster_id, asset_id)
		if not bool(assignment_report.get("valid", false)):
			errors.append(String(assignment_report.get("reason", "invalid monster visual")))
			if host._library == null or host._library.get_asset(asset_id) == null:
				if not missing_assets.has(asset_id):
					missing_assets.append(asset_id)

	for marker: GameplayMarker in host.gameplay_markers:
		if marker == null:
			errors.append("gameplay marker record is null")
			continue
		for marker_error in marker.validate_definition():
			errors.append(marker_error)
		if seen_marker_ids.has(marker.marker_id):
			errors.append("duplicate gameplay marker id '%s'" % marker.marker_id)
		seen_marker_ids[marker.marker_id] = true
		var marker_cell_key := BoardDocument.K.voxel_key(marker.origin)
		if seen_marker_cells.has(marker_cell_key):
			errors.append("duplicate gameplay marker cell %s" % marker_cell_key)
		seen_marker_cells[marker_cell_key] = true
		if marker.marker_type == GameplayMarker.TYPE_ENEMY:
			if not marker.pack_id.is_empty() and not seen_pack_ids.has(marker.pack_id):
				errors.append(
					"enemy marker '%s' references unknown pack '%s'"
					% [marker.marker_id, marker.pack_id]
				)

	for placement: SurfacePlacement in host.surfaces:
		var reference_error := host._validate_surface_reference(placement)
		if not reference_error.is_empty():
			errors.append(reference_error)
			if (
				not placement.asset_id.is_empty()
				and not missing_assets.has(placement.asset_id)
			):
				missing_assets.append(placement.asset_id)
			continue
		if placement.terrain_face_uids.is_empty():
			errors.append("surface at %s has no terrain faces" % placement.origin)
			continue
		# Decals intentionally overlap painted terrain and claim no paint UID.
		# Colored-pixel decal conflicts are resolved atomically before board mutation.
		if placement.is_overlay():
			continue
		for uid: String in placement.terrain_face_uids:
			if seen_paint_uids.has(uid):
				errors.append("duplicate terrain paint on face %s" % uid)
			seen_paint_uids[uid] = true

	for placement: PropPlacement in host.props:
		var prop_reference_error := host._validate_prop_reference(placement)
		if not prop_reference_error.is_empty():
			errors.append(prop_reference_error)
			if (
				not placement.asset_id.is_empty()
				and not missing_assets.has(placement.asset_id)
			):
				missing_assets.append(placement.asset_id)
			continue
		for key in host.prop_solid_keys(placement):
			if seen_voxels.has(key):
				errors.append("overlapping solid volume %s" % key)
			seen_voxels[key] = placement

	return {
		"valid": errors.is_empty() and missing_assets.is_empty(),
		"errors": errors,
		"missing_assets": missing_assets,
		"surface_count": host.surfaces.size(),
		"prop_count": host.props.size(),
		"enemy_pack_count": host.enemy_packs.size(),
		"gameplay_marker_count": host.gameplay_markers.size(),
		"monster_visual_count": host.monster_visual_assets.size(),
	}
