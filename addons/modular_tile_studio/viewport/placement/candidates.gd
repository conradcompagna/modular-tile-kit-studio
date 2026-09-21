@tool
extends RefCounted

## Candidates behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Build one placement Resource from the active asset-or-slot brush source.
static func _placement_for_origin(host: MTSPlacementController, origin: Vector3i) -> Resource:
	if host.brush_is_surface():
		return host._surface_placement_for_origin(origin)
	return host._prop_placement_for_origin(origin)


## Return canonical occupancy keys for one surface, prop, or surfaced-box candidate.
static func _placement_occupancy_keys(host: MTSPlacementController, placement: Resource) -> PackedStringArray:
	if placement is SurfacePlacement:
		return (placement as SurfacePlacement).terrain_face_uids
	if placement is PropPlacement:
		return host.board.prop_solid_keys(placement as PropPlacement)
	return PackedStringArray()


## Return the existing same-kind placements this candidate would displace.
##
## Direct terrain textures deliberately exclude the same asset: repainting a
## texture over itself is a no-op, while different texture assets may be replaced.
static func _replacement_conflicts_for(host: MTSPlacementController, placement: Resource) -> Array[Resource]:
	var displaced: Array[Resource] = []
	if host.board == null:
		return displaced
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		for conflicting_surface: SurfacePlacement in host.board.surface_conflicting_placements(
			surface
		):
			if (
				not surface.asset_id.is_empty()
				and conflicting_surface.asset_id == surface.asset_id
			):
				continue
			displaced.append(conflicting_surface)
	elif placement is PropPlacement:
		for conflicting_prop: PropPlacement in host.board.prop_conflicting_placements(
			placement as PropPlacement
		):
			displaced.append(conflicting_prop)
	return displaced


## Retain only unpainted terrain faces of one non-replacing surface stamp.
##
## The placement keeps its asset and UV frame while dropping the faces another
## placement already owns, so a partially blocked stroke paints what it can
## instead of being rejected wholesale.
static func _retain_available_surface_faces(host: MTSPlacementController, placement: SurfacePlacement) -> Dictionary:
	var full_result := host.board.validate_surface(placement)
	if bool(full_result["valid"]) or (full_result["conflicts"] as Array).is_empty():
		return full_result

	var available_uids := PackedStringArray()
	for uid: String in placement.terrain_face_uids:
		var occupant := host.board.surface_at_paint_uid(uid)
		if occupant == null or occupant == placement:
			available_uids.append(uid)
	if available_uids.is_empty():
		return {
			"valid": false,
			"reason": "",
			"conflicts": [],
			"occupied_surface_no_op": true,
		}
	placement.terrain_face_uids = available_uids
	return host.board.validate_surface(placement)


## Remove candidate faces that already use the selected direct texture.
##
## Replace mode means "replace other textures"; same-texture faces remain owned by
## their existing placement and are never removed and recreated by the stroke.
static func _retain_faces_not_using_brush_asset(host: MTSPlacementController, placement: SurfacePlacement) -> bool:
	if placement.asset_id.is_empty():
		return true
	var retained_uids := PackedStringArray()
	for uid: String in placement.terrain_face_uids:
		var occupant := host.board.surface_at_paint_uid(uid)
		if occupant == null or occupant.asset_id != placement.asset_id:
			retained_uids.append(uid)
	placement.terrain_face_uids = retained_uids
	return not retained_uids.is_empty()


## Validate one placement candidate against the current BoardDocument.
static func _validate_placement(host: MTSPlacementController, placement: Resource) -> Dictionary:
	var result: Dictionary
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		# A Fill candidate already owns its union of exact heightfield faces, and
		# single-click candidates are conformed at construction. Anything still
		# unconformed is resolved here so validation never sees empty coverage.
		if not surface.asset_id.is_empty() and surface.terrain_face_uids.is_empty():
			var terrain_error := host._conform_texture_surface_to_terrain(surface)
			if not terrain_error.is_empty():
				return {
					"valid": false,
					"reason": terrain_error,
					"conflicts": [],
				}
		if surface.is_overlay():
			# Native decals claim no occupancy, so every stamp remains independently
			# selectable even when its visible pixels overlap another decal.
			return host.board.validate_surface(surface)
		if not host.replace_enabled:
			result = host._retain_available_surface_faces(surface)
		else:
			if not host._retain_faces_not_using_brush_asset(surface):
				return {
					"valid": false,
					"reason": "",
					"conflicts": [],
					"occupied_surface_no_op": true,
				}
			result = host.board.validate_surface(surface)
	elif placement is PropPlacement:
		result = host.board.validate_prop(placement as PropPlacement)
	else:
		return {
			"valid": false,
			"reason": "Fill produced an unsupported placement type.",
			"conflicts": [],
		}

	if bool(result["valid"]) or not host.replace_enabled:
		return result

	var displaced := host._replacement_conflicts_for(placement)
	if displaced.is_empty():
		return result
	var noun := "surface"
	if placement is PropPlacement:
		noun = "prop"
	return {
		"valid": true,
		"reason": "will replace %d existing %s%s" % [
			displaced.size(),
			noun,
			"" if displaced.size() == 1 else "s",
		],
		"conflicts": result["conflicts"],
		"replacement_conflicts": displaced,
	}


## Merge every direct-texture Fill stamp into one canonical heightfield placement.
##
## Each toolbar-sized grid origin resolves through TerrainRenderer first, so the
## resulting cell union follows real slope triangles and vertical wall bands.
static func _build_texture_fill_candidate(host: MTSPlacementController, origins: Array[Vector3i]) -> Dictionary:
	if origins.is_empty():
		return {"placement": null, "covered_origins": [], "missed_origins": origins, "error": "Fill contains no grid cells."}
	var combined := SurfacePlacement.create(
		host.brush_asset.asset_id,
		origins[0],
		host.brush_face,
		host.brush_quarters
	)
	var cells_by_key: Dictionary = {}
	var covered_origins: Array[Vector3i] = []
	var missed_origins: Array[Vector3i] = []
	var first_error := ""
	for origin: Vector3i in origins:
		var stamp := SurfacePlacement.create(
			host.brush_asset.asset_id,
			origin,
			host.brush_face,
			host.brush_quarters
		)
		var terrain_error := host._conform_texture_surface_to_terrain(stamp)
		if not terrain_error.is_empty():
			missed_origins.append(origin)
			if first_error.is_empty():
				first_error = terrain_error
			continue
		covered_origins.append(origin)
		for uid: String in stamp.terrain_face_uids:
			cells_by_key[uid] = true
	var combined_uids := PackedStringArray()
	for value: Variant in cells_by_key.keys():
		combined_uids.append(String(value))
	combined.terrain_face_uids = combined_uids
	if combined_uids.is_empty():
		return {
			"placement": combined,
			"covered_origins": covered_origins,
			"missed_origins": missed_origins,
			"error": first_error if not first_error.is_empty() else "Fill touches no heightfield faces.",
		}
	return {
		"placement": combined,
		"covered_origins": covered_origins,
		"missed_origins": missed_origins,
		"error": first_error,
	}


## Validate one merged direct-texture Fill placement without quad or per-stamp occupancy paths.
static func _evaluate_direct_texture_fill(host: MTSPlacementController, origins: Array[Vector3i]) -> Dictionary:
	var placements: Array[Resource] = []
	var displaced: Array[Resource] = []
	var built := host._build_texture_fill_candidate(origins)
	var candidate := built.get("placement", null) as SurfacePlacement
	var covered_origins: Array[Vector3i] = []
	covered_origins.assign(built.get("covered_origins", []))
	var missed_origins: Array[Vector3i] = []
	missed_origins.assign(built.get("missed_origins", []))
	var first_rejection := String(built.get("error", ""))
	if candidate == null or candidate.terrain_face_uids.is_empty():
		return {
			"placements": placements,
			"replacements": displaced,
			"valid_origins": [],
			"blocked_origins": origins,
			"first_rejection": first_rejection,
			"occupied_surface_no_op": false,
			"preview_placement": candidate,
		}

	var result := host._validate_placement(candidate)
	var candidate_valid := bool(result.get("valid", false))
	if candidate_valid:
		placements.append(candidate)
		var reported_replacements: Variant = result.get("replacement_conflicts", [])
		if reported_replacements is Array:
			for reported_placement: Variant in reported_replacements:
				if reported_placement is Resource and not displaced.has(reported_placement):
					displaced.append(reported_placement as Resource)
	elif first_rejection.is_empty():
		first_rejection = String(result.get("reason", "placement is blocked"))
	return {
		"placements": placements,
		"replacements": displaced,
		"valid_origins": covered_origins if candidate_valid else [],
		"blocked_origins": missed_origins if candidate_valid else origins,
		"first_rejection": first_rejection,
		"occupied_surface_no_op": bool(result.get("occupied_surface_no_op", false)),
		"preview_placement": candidate,
	}


## Validate every generated Fill origin, using one explicit face-cell union for direct textures.
static func _evaluate_placement_candidates(host: MTSPlacementController, origins: Array[Vector3i]) -> Dictionary:
	if host.tool == MTSPlacementController.Tool.FILL and host.brush_is_surface() and host.brush_asset != null:
		return host._evaluate_direct_texture_fill(origins)
	var placements: Array[Resource] = []
	var displaced: Array[Resource] = []
	var valid_origins: Array[Vector3i] = []
	var blocked_origins: Array[Vector3i] = []
	var reserved: Dictionary = {}
	var first_rejection := ""
	var occupied_surface_no_op := false

	if not host.has_brush() or host.board == null:
		return {
			"placements": placements,
			"replacements": displaced,
			"valid_origins": valid_origins,
			"blocked_origins": blocked_origins,
			"first_rejection": "no brush or board",
			"occupied_surface_no_op": false,
		}

	for origin: Vector3i in origins:
		var candidate := host._placement_for_origin(origin)
		var result := host._validate_placement(candidate)
		var candidate_valid := bool(result["valid"])
		var keys := host._placement_occupancy_keys(candidate)
		# Dictionary values are Variant. Copying resource entries avoids treating
		# the ordinary untyped empty fallback as an Array[Resource] at runtime.
		var replacement_conflicts: Array[Resource] = []
		var reported_replacements: Variant = result.get(
			"replacement_conflicts",
			[]
		)
		if reported_replacements is Array:
			for reported_placement: Variant in reported_replacements:
				if reported_placement is Resource:
					replacement_conflicts.append(reported_placement as Resource)

		if candidate_valid:
			for key: String in keys:
				if reserved.has(key):
					candidate_valid = false
					if first_rejection.is_empty():
						first_rejection = "placement overlaps another stamp in this Fill shape"
					break

		if not candidate_valid:
			if bool(result.get("occupied_surface_no_op", false)):
				occupied_surface_no_op = true
				continue
			blocked_origins.append(origin)
			if first_rejection.is_empty():
				first_rejection = String(result.get("reason", "placement is blocked"))
			continue

		for key: String in keys:
			reserved[key] = candidate
		for conflicting_placement: Resource in replacement_conflicts:
			if not displaced.has(conflicting_placement):
				displaced.append(conflicting_placement)
		placements.append(candidate)
		valid_origins.append(origin)

	return {
		"placements": placements,
		"replacements": displaced,
		"valid_origins": valid_origins,
		"blocked_origins": blocked_origins,
		"first_rejection": first_rejection,
		"occupied_surface_no_op": occupied_surface_no_op,
	}
