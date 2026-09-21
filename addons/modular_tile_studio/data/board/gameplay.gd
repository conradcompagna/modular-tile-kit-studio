@tool
extends RefCounted

## Gameplay behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Rebuild gameplay pack, marker-id, and marker-cell indexes from canonical records.
static func rebuild_gameplay_indexes(host: BoardDocument) -> void:
	host._enemy_pack_index.clear()
	host._gameplay_marker_index.clear()
	host._gameplay_marker_cell_index.clear()
	for pack: EnemyPack in host.enemy_packs:
		if pack == null or pack.pack_id.is_empty():
			continue
		if host._enemy_pack_index.has(pack.pack_id):
			push_error("[Tile Studio] duplicate enemy pack id '%s'." % pack.pack_id)
			continue
		host._enemy_pack_index[pack.pack_id] = pack
	for marker: GameplayMarker in host.gameplay_markers:
		if marker == null or marker.marker_id.is_empty():
			continue
		if host._gameplay_marker_index.has(marker.marker_id):
			push_error("[Tile Studio] duplicate gameplay marker id '%s'." % marker.marker_id)
			continue
		host._gameplay_marker_index[marker.marker_id] = marker
		var cell_key := BoardDocument.K.voxel_key(marker.origin)
		if host._gameplay_marker_cell_index.has(cell_key):
			push_error("[Tile Studio] duplicate gameplay marker cell %s." % cell_key)
			continue
		host._gameplay_marker_cell_index[cell_key] = marker


## Return the exact saved enemy pack with the requested id.
static func get_enemy_pack(host: BoardDocument, pack_id: String) -> EnemyPack:
	return host._enemy_pack_index.get(pack_id, null) as EnemyPack


## Return the exact saved gameplay marker with the requested id.
static func get_gameplay_marker(host: BoardDocument, marker_id: String) -> GameplayMarker:
	return host._gameplay_marker_index.get(marker_id, null) as GameplayMarker


## Return the gameplay marker occupying one exact grid cell.
static func gameplay_marker_at(host: BoardDocument, origin: Vector3i) -> GameplayMarker:
	return host._gameplay_marker_cell_index.get(BoardDocument.K.voxel_key(origin), null) as GameplayMarker


## Return the particle placement with one exact stable placement ID.
static func get_particle_effect(host: BoardDocument, placement_id: String) -> ParticleEffectPlacement:
	for placement: ParticleEffectPlacement in host.particle_effects:
		if placement != null and placement.placement_id == placement_id:
			return placement
	return null


## Return the most recently added particle placement within the requested world-space radius.
static func particle_effect_near(host: BoardDocument, position: Vector3, radius: float = 0.75) -> ParticleEffectPlacement:
	for index in range(host.particle_effects.size() - 1, -1, -1):
		var placement: ParticleEffectPlacement = host.particle_effects[index]
		if placement != null and placement.position.distance_to(position) <= radius:
			return placement
	return null


## Add one valid particle placement and announce the canonical board mutation.
static func add_particle_effect(host: BoardDocument, placement: ParticleEffectPlacement) -> bool:
	if placement == null or placement.placement_id.is_empty() or placement.preset_id.is_empty():
		push_error("[Tile Studio] Cannot add an incomplete particle effect placement.")
		return false
	if host.get_particle_effect(placement.placement_id) != null:
		push_error("[Tile Studio] Duplicate particle placement ID '%s'." % placement.placement_id)
		return false
	host.particle_effects.append(placement)
	host.board_changed.emit()
	return true


## Remove one existing particle placement and announce the canonical board mutation.
static func remove_particle_effect(host: BoardDocument, placement: ParticleEffectPlacement) -> bool:
	if placement == null or not host.particle_effects.has(placement):
		push_error("[Tile Studio] Cannot remove a particle placement that is not on this board.")
		return false
	host.particle_effects.erase(placement)
	host.board_changed.emit()
	return true


## Return the exact GLB asset id assigned to one monster id, or empty when it has no visual.
static func monster_visual_asset_id(host: BoardDocument, monster_id: String) -> String:
	var value: Variant = host.monster_visual_assets.get(monster_id, "")
	if value is String:
		return value
	push_error("[Tile Studio] monster visual '%s' has a non-string asset id." % monster_id)
	return ""


## Return every authored monster id from placements and visual bindings in stable order.
static func known_monster_ids(host: BoardDocument) -> PackedStringArray:
	var seen: Dictionary = {}
	for marker: GameplayMarker in host.gameplay_markers:
		if marker != null and marker.marker_type == GameplayMarker.TYPE_ENEMY:
			seen[marker.monster_id] = true
	for monster_value: Variant in host.monster_visual_assets.keys():
		if monster_value is String:
			seen[monster_value] = true
	var ids := PackedStringArray()
	for monster_value: Variant in seen.keys():
		ids.append(String(monster_value))
	ids.sort()
	return ids


## Count enemy markers whose one canonical pack reference matches the requested id.
static func enemy_pack_member_count(host: BoardDocument, pack_id: String) -> int:
	var count: int = 0
	for marker: GameplayMarker in host.gameplay_markers:
		if marker != null and marker.marker_type == GameplayMarker.TYPE_ENEMY:
			if marker.pack_id == pack_id:
				count += 1
	return count


## Return the next visible marker id without storing a second hidden counter.
static func next_gameplay_marker_id(host: BoardDocument, marker_type: String) -> String:
	var suffix: int = 1
	while true:
		var candidate := "%s_%03d" % [marker_type, suffix]
		if host.get_gameplay_marker(candidate) == null:
			return candidate
		suffix += 1
	return ""


## Validate one pack record against the board's exact pack-id namespace.
static func validate_enemy_pack(host: BoardDocument, pack: EnemyPack, ignore: EnemyPack = null) -> Dictionary:
	if pack == null:
		return {"valid": false, "reason": "enemy pack is null"}
	var definition_errors := pack.validate_definition()
	if not definition_errors.is_empty():
		return {"valid": false, "reason": String(definition_errors[0])}
	var existing := host.get_enemy_pack(pack.pack_id)
	if existing != null and existing != ignore and existing != pack:
		return {
			"valid": false,
			"reason": "duplicate enemy pack id '%s'" % pack.pack_id,
		}
	return {"valid": true, "reason": ""}


## Add one validated enemy pack without changing any marker membership.
static func add_enemy_pack(host: BoardDocument, pack: EnemyPack) -> Dictionary:
	var result := host.validate_enemy_pack(pack)
	if not bool(result.get("valid", false)):
		return result
	host.enemy_packs.append(pack)
	host._enemy_pack_index[pack.pack_id] = pack
	host.board_changed.emit()
	return {"valid": true, "reason": "", "pack": pack.pack_id}


## Update one pack note only after the complete replacement record validates.
static func update_enemy_pack(host: BoardDocument, pack_id: String, note: String) -> Dictionary:
	var pack := host.get_enemy_pack(pack_id)
	if pack == null:
		return {"valid": false, "reason": "unknown enemy pack '%s'" % pack_id}
	var candidate := EnemyPack.create(pack_id, note)
	var result := host.validate_enemy_pack(candidate, pack)
	if not bool(result.get("valid", false)):
		return result
	pack.note = note
	host.board_changed.emit()
	return {"valid": true, "reason": "", "pack": pack_id}


## Remove an unused pack and reject deletion while enemy markers still reference it.
static func remove_enemy_pack(host: BoardDocument, pack_id: String) -> Dictionary:
	var pack := host.get_enemy_pack(pack_id)
	if pack == null:
		return {"valid": false, "reason": "unknown enemy pack '%s'" % pack_id}
	var member_count := host.enemy_pack_member_count(pack_id)
	if member_count > 0:
		return {
			"valid": false,
			"reason": "enemy pack '%s' still contains %d marker%s"
				% [pack_id, member_count, "" if member_count == 1 else "s"],
		}
	host.enemy_packs.erase(pack)
	host._enemy_pack_index.erase(pack_id)
	host.board_changed.emit()
	return {"valid": true, "reason": "", "pack": pack_id}


## Validate one marker against exact ids, pack references, and cell occupancy.
static func validate_gameplay_marker(host: BoardDocument,
	marker: GameplayMarker,
	ignore: GameplayMarker = null
) -> Dictionary:
	if marker == null:
		return {"valid": false, "reason": "gameplay marker is null"}
	var definition_errors := marker.validate_definition()
	if not definition_errors.is_empty():
		return {"valid": false, "reason": String(definition_errors[0])}
	var existing_id := host.get_gameplay_marker(marker.marker_id)
	if existing_id != null and existing_id != ignore and existing_id != marker:
		return {
			"valid": false,
			"reason": "duplicate gameplay marker id '%s'" % marker.marker_id,
		}
	var existing_cell_marker := host.gameplay_marker_at(marker.origin)
	if (
		existing_cell_marker != null
		and existing_cell_marker != ignore
		and existing_cell_marker != marker
	):
		return {
			"valid": false,
			"reason": "gameplay cell %s already contains marker '%s'"
				% [marker.origin, existing_cell_marker.marker_id],
		}
	if marker.marker_type == GameplayMarker.TYPE_ENEMY:
		if not marker.pack_id.is_empty() and host.get_enemy_pack(marker.pack_id) == null:
			return {
				"valid": false,
				"reason": "enemy marker '%s' references unknown pack '%s'"
					% [marker.marker_id, marker.pack_id],
			}
	return {"valid": true, "reason": ""}


## Add one validated gameplay marker at its exact authored grid cell.
static func add_gameplay_marker(host: BoardDocument, marker: GameplayMarker) -> Dictionary:
	var result := host.validate_gameplay_marker(marker)
	if not bool(result.get("valid", false)):
		return result
	host.gameplay_markers.append(marker)
	host._gameplay_marker_index[marker.marker_id] = marker
	host._gameplay_marker_cell_index[BoardDocument.K.voxel_key(marker.origin)] = marker
	host.board_changed.emit()
	return {"valid": true, "reason": "", "marker": marker.marker_id}


## Update visible marker fields atomically while preserving its exact grid cell and identity.
static func update_gameplay_marker(host: BoardDocument,
	marker_id: String,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> Dictionary:
	var marker := host.get_gameplay_marker(marker_id)
	if marker == null:
		return {"valid": false, "reason": "unknown gameplay marker '%s'" % marker_id}
	var candidate := GameplayMarker.create(
		marker_id,
		marker_type,
		marker.origin,
		note,
		monster_id,
		pack_id
	)
	var result := host.validate_gameplay_marker(candidate, marker)
	if not bool(result.get("valid", false)):
		return result
	marker.marker_type = marker_type
	marker.note = note
	marker.monster_id = monster_id
	marker.pack_id = pack_id
	host.board_changed.emit()
	return {"valid": true, "reason": "", "marker": marker_id}


## Assign one validated enemy selection to one pack as a single atomic edit.
##
## Every candidate is checked before any membership changes, so a stale drag
## cannot partially reorganize a pack.
static func assign_enemy_markers_to_pack(host: BoardDocument,
	marker_ids: PackedStringArray,
	pack_id: String
) -> Dictionary:
	if marker_ids.is_empty():
		return {"valid": false, "reason": "select at least one enemy to move"}
	if not pack_id.is_empty() and host.get_enemy_pack(pack_id) == null:
		return {"valid": false, "reason": "unknown enemy pack '%s'" % pack_id}
	var targets: Array[GameplayMarker] = []
	var seen_ids: Dictionary = {}
	for marker_id: String in marker_ids:
		if seen_ids.has(marker_id):
			return {
				"valid": false,
				"reason": "enemy selection repeats marker '%s'" % marker_id,
			}
		seen_ids[marker_id] = true
		var marker := host.get_gameplay_marker(marker_id)
		if marker == null:
			return {
				"valid": false,
				"reason": "unknown gameplay marker '%s'" % marker_id,
			}
		if marker.marker_type != GameplayMarker.TYPE_ENEMY:
			return {
				"valid": false,
				"reason": "gameplay marker '%s' is not an enemy" % marker_id,
			}
		var candidate := GameplayMarker.create(
			marker.marker_id,
			marker.marker_type,
			marker.origin,
			marker.note,
			marker.monster_id,
			pack_id
		)
		var result := host.validate_gameplay_marker(candidate, marker)
		if not bool(result.get("valid", false)):
			return result
		targets.append(marker)
	for marker: GameplayMarker in targets:
		marker.pack_id = pack_id
	host.board_changed.emit()
	return {
		"valid": true,
		"reason": "",
		"pack": pack_id,
		"marker_count": targets.size(),
	}


## Remove one exact gameplay marker while leaving unrelated packs and cells intact.
static func remove_gameplay_marker(host: BoardDocument, marker: GameplayMarker) -> void:
	if marker == null or not host.gameplay_markers.has(marker):
		return
	host.gameplay_markers.erase(marker)
	host._gameplay_marker_index.erase(marker.marker_id)
	var cell_key := BoardDocument.K.voxel_key(marker.origin)
	if host._gameplay_marker_cell_index.get(cell_key, null) == marker:
		host._gameplay_marker_cell_index.erase(cell_key)
	host.board_changed.emit()
