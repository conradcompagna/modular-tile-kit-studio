@tool
class_name BoardDocument
extends Resource

## Authoritative board state for one authored encounter.
##
## Terrain, placements, and look settings are canonical data. Viewport nodes,
## occupancy maps, contact fields, and highlights are deterministic derivatives.
## The terrain heightfield is the single answer to "where is the ground"; every
## other spatial system derives from it rather than describing it a second time.

const K := preload("../utils/mts_constants.gd")
const FORMAT_VERSION: int = 13
const MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH: int = 128

const SAVE_STAGING_SUFFIX: String = ".saving-"
const SAVE_BACKUP_SUFFIX: String = ".backup-"

signal board_changed()
## Look changes remain separate so visual tuning never rebuilds placement geometry.
signal look_changed()

@export var version: int = FORMAT_VERSION
@export var board_name: String = "Untitled Board"
@export var biome: String = ""
@export var surfaces: Array[SurfacePlacement] = []
@export var props: Array[PropPlacement] = []
@export var enemy_packs: Array[EnemyPack] = []
@export var gameplay_markers: Array[GameplayMarker] = []
@export var particle_effects: Array[ParticleEffectPlacement] = []
## Monster id -> project-owned GLB TileAsset id; placements continue to store only the monster id.
@export var monster_visual_assets: Dictionary = {}
## Asset ids that entered the library while this board was the open level.
##
## Placement is the only record of what a board *uses*; this is the separate
## record of what was brought in *for* it, so the library's level view can still
## show an import the author has not placed yet. Ids are kept in import order and
## are authoritative for nothing: an id whose asset was deleted simply resolves to
## no asset and drops out of the view.
@export var imported_asset_ids: PackedStringArray = PackedStringArray()
## The canonical tactical encounter surface: one drawn footprint and its corner
## height lattice. This is the authored ground the board is built on and the
## source the gameplay grid is derived from, so it is board state rather than a
## look setting. An empty grid means no encounter footprint has been drawn yet.
@export var terrain: TerrainMesh = TerrainMesh.new()
## One board-wide collision rule applied to every GLB prop and every instance.
##
## Assets retain raw measured scans; this board value is the sole authored filter
## consumed by editor collision, movement preview, saved JSON, and game runtime.
@export_range(0.0, 100.0, 0.001) var movement_collision_min_triangle_share_percent: float = 0.0
## Stable "x,z" cell keys manually excluded from the derived tactical surface.
@export var movement_unwalkable_cells: Dictionary = {}
## Stable "x,z" cell keys mapped to authored descriptive ground-effect labels.
@export var movement_ground_effects: Dictionary = {}
## Immutable PNG sidecar metadata for sparse per-surface RGBA material weights.
@export var surface_material_paint: Dictionary = {}
## The visible palette, mask recipes, blend mode, and paint-resolution contract.
@export var material_blend: MaterialBlendProfile = MaterialBlendProfile.new()
@export var aesthetics: AestheticProfile = AestheticProfile.new()
@export var lighting: LightingProfile = LightingProfile.new()

## Stable terrain paint UID -> SurfacePlacement covering that face.
##
## Terrain paint is addressed by TerrainMesh identity, so this index survives
## sculpting exactly as the authored paint does.
var _paint_uid_index: Dictionary = {}
## Stable terrain paint UID -> Array[SurfacePlacement] containing its shader decal.
##
## Direct shader decals share the receiving terrain material rather than a second
## render pass, so one face has at most one such placement.
var _shader_decal_uid_index: Dictionary = {}
## Voxel key -> canonical PropPlacement.
var _solid_index: Dictionary = {}
## Horizontal footprint cell -> Array[PropPlacement] touching that terrain cell.
##
## This derived index lets a local terrain edit find only props whose support may
## have changed, without scanning every placement on the board.
var _prop_footprint_index: Dictionary = {}
## Exact enemy pack id -> EnemyPack.
var _enemy_pack_index: Dictionary = {}
## Exact gameplay marker id -> GameplayMarker.
var _gameplay_marker_index: Dictionary = {}
## Exact gameplay marker cell minimum -> GameplayMarker.
var _gameplay_marker_cell_index: Dictionary = {}
## The document borrows the library for bindings and direct-asset references.
var _library: AssetLibrary = null


## Bind the authoritative asset library used to resolve placement references.
func bind_library(library: AssetLibrary) -> void:
	_library = library
	rebuild_indexes()


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
func movement_cell_exists(cell: Vector2i) -> bool:
	return terrain != null and terrain.is_cell_filled(cell)


## Return whether the author explicitly removed one terrain cell from movement.
func movement_cell_is_unwalkable(cell: Vector2i) -> bool:
	return movement_unwalkable_cells.has(movement_cell_key(cell))


## Return the descriptive ground-effect label authored on one movement cell.
func movement_ground_effect(cell: Vector2i) -> String:
	return String(movement_ground_effects.get(movement_cell_key(cell), ""))


## Return the complete editable state of one movement cell for UI and undo.
func movement_cell_state(cell: Vector2i) -> Dictionary:
	return {
		"exists": movement_cell_exists(cell),
		"unwalkable": movement_cell_is_unwalkable(cell),
		"ground_effect": movement_ground_effect(cell),
	}


## Apply one validated movement-cell state and optionally publish the board mutation.
func apply_movement_cell_state(
	cell: Vector2i,
	state: Dictionary,
	notify_change: bool = true
) -> bool:
	if not movement_cell_exists(cell):
		push_error("[Tile Studio] movement cell %s has no authored terrain." % cell)
		return false
	var effect := String(state.get("ground_effect", "")).strip_edges()
	if effect.length() > MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH:
		push_error(
			"[Tile Studio] ground-effect label at %s exceeds %d characters."
			% [cell, MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH]
		)
		return false
	var key := movement_cell_key(cell)
	var unwalkable := bool(state.get("unwalkable", false))
	if (
		movement_unwalkable_cells.has(key) == unwalkable
		and String(movement_ground_effects.get(key, "")) == effect
	):
		return false
	if unwalkable:
		movement_unwalkable_cells[key] = true
	else:
		movement_unwalkable_cells.erase(key)
	if effect.is_empty():
		movement_ground_effects.erase(key)
	else:
		movement_ground_effects[key] = effect
	if notify_change:
		board_changed.emit()
	return true


## Set or clear the manual movement block on one authored terrain cell.
func set_movement_cell_unwalkable(cell: Vector2i, unwalkable: bool) -> bool:
	var state := movement_cell_state(cell)
	state["unwalkable"] = unwalkable
	return apply_movement_cell_state(cell, state)


## Set or clear one plain ground-effect label on an authored terrain cell.
func set_movement_ground_effect(cell: Vector2i, label: String) -> bool:
	var state := movement_cell_state(cell)
	state["ground_effect"] = label
	return apply_movement_cell_state(cell, state)


## Return movement-cell keys as coordinates in stable numeric order.
func _sorted_movement_cells(source: Dictionary) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for key_value: Variant in source.keys():
		var parsed: Variant = movement_cell_from_key(String(key_value))
		if parsed is Vector2i:
			cells.append(parsed as Vector2i)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	return cells


## Return a runtime-safe snapshot of authored ground-effect labels by cell.
func movement_ground_effect_snapshot() -> Dictionary:
	var snapshot: Dictionary = {}
	for cell: Vector2i in _sorted_movement_cells(movement_ground_effects):
		snapshot[cell] = movement_ground_effect(cell)
	return snapshot


## Remove movement annotations whose terrain cell no longer exists.
func prune_movement_grid_cells() -> int:
	var removed := 0
	for source: Dictionary in [movement_unwalkable_cells, movement_ground_effects]:
		var stale_keys: Array[String] = []
		for key_value: Variant in source.keys():
			var key := String(key_value)
			var parsed: Variant = movement_cell_from_key(key)
			if not parsed is Vector2i or not movement_cell_exists(parsed as Vector2i):
				stale_keys.append(key)
		for key: String in stale_keys:
			source.erase(key)
			removed += 1
	return removed


## Preview one global collision threshold across every placed prop instance.
func movement_collision_filter_report(
	threshold_percent: float = -1.0
) -> Dictionary:
	var threshold := (
		movement_collision_min_triangle_share_percent
		if threshold_percent < 0.0
		else clampf(threshold_percent, 0.0, 100.0)
	)
	var errors := PackedStringArray()
	var missing_asset_ids := PackedStringArray()
	var placed_asset_ids: Dictionary = {}
	var raw_voxel_count := 0
	var active_voxel_count := 0
	for placement: PropPlacement in props:
		var asset := resolve_prop_asset(placement)
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
		"placed_instance_count": props.size(),
		"raw_voxel_count": raw_voxel_count,
		"active_voxel_count": active_voxel_count,
		"removed_voxel_count": raw_voxel_count - active_voxel_count,
		"missing_measurement_asset_ids": missing_asset_ids,
		"errors": errors,
	}


## Commit one board-wide collision threshold only when every placed instance can use it.
func set_movement_collision_min_triangle_share_percent(
	threshold_percent: float
) -> Dictionary:
	var report := movement_collision_filter_report(threshold_percent)
	if not bool(report.get("valid", false)):
		return report
	var threshold := float(report["threshold_percent"])
	if is_equal_approx(
		movement_collision_min_triangle_share_percent,
		threshold
	):
		return report
	movement_collision_min_triangle_share_percent = threshold
	rebuild_indexes()
	board_changed.emit()
	return report



## Rebuild gameplay pack, marker-id, and marker-cell indexes from canonical records.
func rebuild_gameplay_indexes() -> void:
	_enemy_pack_index.clear()
	_gameplay_marker_index.clear()
	_gameplay_marker_cell_index.clear()
	for pack: EnemyPack in enemy_packs:
		if pack == null or pack.pack_id.is_empty():
			continue
		if _enemy_pack_index.has(pack.pack_id):
			push_error("[Tile Studio] duplicate enemy pack id '%s'." % pack.pack_id)
			continue
		_enemy_pack_index[pack.pack_id] = pack
	for marker: GameplayMarker in gameplay_markers:
		if marker == null or marker.marker_id.is_empty():
			continue
		if _gameplay_marker_index.has(marker.marker_id):
			push_error("[Tile Studio] duplicate gameplay marker id '%s'." % marker.marker_id)
			continue
		_gameplay_marker_index[marker.marker_id] = marker
		var cell_key := K.voxel_key(marker.origin)
		if _gameplay_marker_cell_index.has(cell_key):
			push_error("[Tile Studio] duplicate gameplay marker cell %s." % cell_key)
			continue
		_gameplay_marker_cell_index[cell_key] = marker


## Return the exact saved enemy pack with the requested id.
func get_enemy_pack(pack_id: String) -> EnemyPack:
	return _enemy_pack_index.get(pack_id, null) as EnemyPack


## Return the exact saved gameplay marker with the requested id.
func get_gameplay_marker(marker_id: String) -> GameplayMarker:
	return _gameplay_marker_index.get(marker_id, null) as GameplayMarker


## Return the gameplay marker occupying one exact grid cell.
func gameplay_marker_at(origin: Vector3i) -> GameplayMarker:
	return _gameplay_marker_cell_index.get(K.voxel_key(origin), null) as GameplayMarker


## Return the particle placement with one exact stable placement ID.
func get_particle_effect(placement_id: String) -> ParticleEffectPlacement:
	for placement: ParticleEffectPlacement in particle_effects:
		if placement != null and placement.placement_id == placement_id:
			return placement
	return null


## Return the most recently added particle placement within the requested world-space radius.
func particle_effect_near(position: Vector3, radius: float = 0.75) -> ParticleEffectPlacement:
	for index in range(particle_effects.size() - 1, -1, -1):
		var placement: ParticleEffectPlacement = particle_effects[index]
		if placement != null and placement.position.distance_to(position) <= radius:
			return placement
	return null


## Add one valid particle placement and announce the canonical board mutation.
func add_particle_effect(placement: ParticleEffectPlacement) -> bool:
	if placement == null or placement.placement_id.is_empty() or placement.preset_id.is_empty():
		push_error("[Tile Studio] Cannot add an incomplete particle effect placement.")
		return false
	if get_particle_effect(placement.placement_id) != null:
		push_error("[Tile Studio] Duplicate particle placement ID '%s'." % placement.placement_id)
		return false
	particle_effects.append(placement)
	board_changed.emit()
	return true


## Remove one existing particle placement and announce the canonical board mutation.
func remove_particle_effect(placement: ParticleEffectPlacement) -> bool:
	if placement == null or not particle_effects.has(placement):
		push_error("[Tile Studio] Cannot remove a particle placement that is not on this board.")
		return false
	particle_effects.erase(placement)
	board_changed.emit()
	return true


## Return the exact GLB asset id assigned to one monster id, or empty when it has no visual.
func monster_visual_asset_id(monster_id: String) -> String:
	var value: Variant = monster_visual_assets.get(monster_id, "")
	if value is String:
		return value
	push_error("[Tile Studio] monster visual '%s' has a non-string asset id." % monster_id)
	return ""


## Return every authored monster id from placements and visual bindings in stable order.
func known_monster_ids() -> PackedStringArray:
	var seen: Dictionary = {}
	for marker: GameplayMarker in gameplay_markers:
		if marker != null and marker.marker_type == GameplayMarker.TYPE_ENEMY:
			seen[marker.monster_id] = true
	for monster_value: Variant in monster_visual_assets.keys():
		if monster_value is String:
			seen[monster_value] = true
	var ids := PackedStringArray()
	for monster_value: Variant in seen.keys():
		ids.append(String(monster_value))
	ids.sort()
	return ids


## Record that one asset entered the library while this board was the open level.
##
## Deliberately silent: the import record only feeds the library panel's level
## view, so announcing board_changed here would rebuild every placement, mesh and
## collider for a change that moved nothing. The importer refreshes the library
## panel in the same step, which is where the new entry becomes visible.
func note_imported_asset(asset_id: String) -> void:
	if asset_id.is_empty():
		push_error("[Tile Studio] cannot record an import with no asset id.")
		return
	if imported_asset_ids.has(asset_id):
		return
	imported_asset_ids.append(asset_id)


## Drop one asset id from this board's import record.
##
## Called when the asset itself is deleted, so a saved board stops naming files
## that no longer exist.
func forget_imported_asset(asset_id: String) -> void:
	var index := imported_asset_ids.find(asset_id)
	if index >= 0:
		imported_asset_ids.remove_at(index)


## Return every asset id this board actually uses, in no particular order.
##
## Structural references are owned here. The paint owner supplies palette indices
## that truly affect a face, so merely configuring or clicking a material never
## causes it to appear as a used level asset.
func used_asset_ids(
	active_material_palette_indices: PackedInt32Array = PackedInt32Array()
) -> PackedStringArray:
	var seen: Dictionary = {}
	for placement: SurfacePlacement in surfaces:
		if placement != null and not placement.asset_id.is_empty():
			seen[placement.asset_id] = true
	for placement: PropPlacement in props:
		if placement != null and not placement.asset_id.is_empty():
			seen[placement.asset_id] = true
	for monster_value: Variant in monster_visual_assets.keys():
		var visual_id := monster_visual_asset_id(String(monster_value))
		if not visual_id.is_empty():
			seen[visual_id] = true
	material_blend.ensure_layers()
	for index: int in active_material_palette_indices:
		if index < 0 or index >= material_blend.layer_count():
			push_error("BoardDocument: active material palette index %d is invalid." % index)
			continue
		var layer_id := String(material_blend.layer(index).get("asset_id", ""))
		if not layer_id.is_empty():
			seen[layer_id] = true
	var used := PackedStringArray()
	for used_value: Variant in seen.keys():
		used.append(String(used_value))
	return used


## Validate one explicit monster-to-GLB assignment against the bound project library.
func validate_monster_visual_assignment(
	monster_id: String,
	asset_id: String
) -> Dictionary:
	if monster_id.is_empty() or monster_id != monster_id.strip_edges():
		return {"valid": false, "reason": "monster id must be a trimmed non-empty string"}
	if asset_id.is_empty() or asset_id != asset_id.strip_edges():
		return {"valid": false, "reason": "monster visual asset id must be a trimmed non-empty string"}
	if _library == null:
		return {"valid": false, "reason": "asset library is not bound"}
	var asset := _library.get_asset(asset_id)
	if asset == null:
		return {"valid": false, "reason": "unknown monster visual asset '%s'" % asset_id}
	if not asset.is_prop():
		return {"valid": false, "reason": "monster visual '%s' must be a GLB asset" % asset_id}
	return {"valid": true, "reason": ""}


## Assign one imported GLB to every placement that references the exact monster id.
func set_monster_visual_asset(monster_id: String, asset_id: String) -> Dictionary:
	var result := validate_monster_visual_assignment(monster_id, asset_id)
	if not bool(result.get("valid", false)):
		return result
	monster_visual_assets[monster_id] = asset_id
	board_changed.emit()
	return {
		"valid": true,
		"reason": "",
		"monster": monster_id,
		"asset": asset_id,
	}


## Remove one monster's visual assignment without changing any enemy placements.
func clear_monster_visual_asset(monster_id: String) -> Dictionary:
	if not monster_visual_assets.has(monster_id):
		return {"valid": false, "reason": "monster '%s' has no visual asset" % monster_id}
	monster_visual_assets.erase(monster_id)
	board_changed.emit()
	return {"valid": true, "reason": "", "monster": monster_id, "asset": ""}


## Resolve one assigned monster GLB while reporting invalid saved references locally.
func resolve_monster_visual_asset(monster_id: String) -> TileAsset:
	var asset_id := monster_visual_asset_id(monster_id)
	if asset_id.is_empty():
		return null
	if _library == null:
		push_error("[Tile Studio] cannot resolve monster '%s' without an asset library." % monster_id)
		return null
	var asset := _library.get_asset(asset_id)
	if asset == null or not asset.is_prop():
		push_error("[Tile Studio] monster '%s' references invalid GLB asset '%s'." % [monster_id, asset_id])
		return null
	return asset


## Count enemy markers whose one canonical pack reference matches the requested id.
func enemy_pack_member_count(pack_id: String) -> int:
	var count: int = 0
	for marker: GameplayMarker in gameplay_markers:
		if marker != null and marker.marker_type == GameplayMarker.TYPE_ENEMY:
			if marker.pack_id == pack_id:
				count += 1
	return count


## Return the next visible marker id without storing a second hidden counter.
func next_gameplay_marker_id(marker_type: String) -> String:
	var suffix: int = 1
	while true:
		var candidate := "%s_%03d" % [marker_type, suffix]
		if get_gameplay_marker(candidate) == null:
			return candidate
		suffix += 1
	return ""


## Validate one pack record against the board's exact pack-id namespace.
func validate_enemy_pack(pack: EnemyPack, ignore: EnemyPack = null) -> Dictionary:
	if pack == null:
		return {"valid": false, "reason": "enemy pack is null"}
	var definition_errors := pack.validate_definition()
	if not definition_errors.is_empty():
		return {"valid": false, "reason": String(definition_errors[0])}
	var existing := get_enemy_pack(pack.pack_id)
	if existing != null and existing != ignore and existing != pack:
		return {
			"valid": false,
			"reason": "duplicate enemy pack id '%s'" % pack.pack_id,
		}
	return {"valid": true, "reason": ""}


## Add one validated enemy pack without changing any marker membership.
func add_enemy_pack(pack: EnemyPack) -> Dictionary:
	var result := validate_enemy_pack(pack)
	if not bool(result.get("valid", false)):
		return result
	enemy_packs.append(pack)
	_enemy_pack_index[pack.pack_id] = pack
	board_changed.emit()
	return {"valid": true, "reason": "", "pack": pack.pack_id}


## Update one pack note only after the complete replacement record validates.
func update_enemy_pack(pack_id: String, note: String) -> Dictionary:
	var pack := get_enemy_pack(pack_id)
	if pack == null:
		return {"valid": false, "reason": "unknown enemy pack '%s'" % pack_id}
	var candidate := EnemyPack.create(pack_id, note)
	var result := validate_enemy_pack(candidate, pack)
	if not bool(result.get("valid", false)):
		return result
	pack.note = note
	board_changed.emit()
	return {"valid": true, "reason": "", "pack": pack_id}


## Remove an unused pack and reject deletion while enemy markers still reference it.
func remove_enemy_pack(pack_id: String) -> Dictionary:
	var pack := get_enemy_pack(pack_id)
	if pack == null:
		return {"valid": false, "reason": "unknown enemy pack '%s'" % pack_id}
	var member_count := enemy_pack_member_count(pack_id)
	if member_count > 0:
		return {
			"valid": false,
			"reason": "enemy pack '%s' still contains %d marker%s"
				% [pack_id, member_count, "" if member_count == 1 else "s"],
		}
	enemy_packs.erase(pack)
	_enemy_pack_index.erase(pack_id)
	board_changed.emit()
	return {"valid": true, "reason": "", "pack": pack_id}


## Validate one marker against exact ids, pack references, and cell occupancy.
func validate_gameplay_marker(
	marker: GameplayMarker,
	ignore: GameplayMarker = null
) -> Dictionary:
	if marker == null:
		return {"valid": false, "reason": "gameplay marker is null"}
	var definition_errors := marker.validate_definition()
	if not definition_errors.is_empty():
		return {"valid": false, "reason": String(definition_errors[0])}
	var existing_id := get_gameplay_marker(marker.marker_id)
	if existing_id != null and existing_id != ignore and existing_id != marker:
		return {
			"valid": false,
			"reason": "duplicate gameplay marker id '%s'" % marker.marker_id,
		}
	var existing_cell_marker := gameplay_marker_at(marker.origin)
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
		if not marker.pack_id.is_empty() and get_enemy_pack(marker.pack_id) == null:
			return {
				"valid": false,
				"reason": "enemy marker '%s' references unknown pack '%s'"
					% [marker.marker_id, marker.pack_id],
			}
	return {"valid": true, "reason": ""}


## Add one validated gameplay marker at its exact authored grid cell.
func add_gameplay_marker(marker: GameplayMarker) -> Dictionary:
	var result := validate_gameplay_marker(marker)
	if not bool(result.get("valid", false)):
		return result
	gameplay_markers.append(marker)
	_gameplay_marker_index[marker.marker_id] = marker
	_gameplay_marker_cell_index[K.voxel_key(marker.origin)] = marker
	board_changed.emit()
	return {"valid": true, "reason": "", "marker": marker.marker_id}


## Update visible marker fields atomically while preserving its exact grid cell and identity.
func update_gameplay_marker(
	marker_id: String,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> Dictionary:
	var marker := get_gameplay_marker(marker_id)
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
	var result := validate_gameplay_marker(candidate, marker)
	if not bool(result.get("valid", false)):
		return result
	marker.marker_type = marker_type
	marker.note = note
	marker.monster_id = monster_id
	marker.pack_id = pack_id
	board_changed.emit()
	return {"valid": true, "reason": "", "marker": marker_id}


## Assign one validated enemy selection to one pack as a single atomic edit.
##
## Every candidate is checked before any membership changes, so a stale drag
## cannot partially reorganize a pack.
func assign_enemy_markers_to_pack(
	marker_ids: PackedStringArray,
	pack_id: String
) -> Dictionary:
	if marker_ids.is_empty():
		return {"valid": false, "reason": "select at least one enemy to move"}
	if not pack_id.is_empty() and get_enemy_pack(pack_id) == null:
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
		var marker := get_gameplay_marker(marker_id)
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
		var result := validate_gameplay_marker(candidate, marker)
		if not bool(result.get("valid", false)):
			return result
		targets.append(marker)
	for marker: GameplayMarker in targets:
		marker.pack_id = pack_id
	board_changed.emit()
	return {
		"valid": true,
		"reason": "",
		"pack": pack_id,
		"marker_count": targets.size(),
	}


## Remove one exact gameplay marker while leaving unrelated packs and cells intact.
func remove_gameplay_marker(marker: GameplayMarker) -> void:
	if marker == null or not gameplay_markers.has(marker):
		return
	gameplay_markers.erase(marker)
	_gameplay_marker_index.erase(marker.marker_id)
	var cell_key := K.voxel_key(marker.origin)
	if _gameplay_marker_cell_index.get(cell_key, null) == marker:
		_gameplay_marker_cell_index.erase(cell_key)
	board_changed.emit()


## Resolve the visible asset for one direct asset reference.
##
## A missing asset returns null so callers report the unbound state rather than
## substituting a stand-in.
func resolve_asset(asset_id: String) -> TileAsset:
	if _library == null or asset_id.is_empty():
		return null
	return _library.get_asset(asset_id)


## Resolve the visible asset for one surface placement.
func resolve_surface_asset(placement: SurfacePlacement) -> TileAsset:
	if placement == null:
		return null
	return resolve_asset(placement.asset_id)


## Resolve the visible asset for one prop placement.
func resolve_prop_asset(placement: PropPlacement) -> TileAsset:
	if placement == null:
		return null
	return resolve_asset(placement.asset_id)


## Return the stable terrain paint UIDs one surface placement covers.
##
## This is the placement's complete spatial extent. Terrain owns the geometry, so
## a placement is exactly the set of terrain faces it paints.
func surface_paint_uids(placement: SurfacePlacement) -> PackedStringArray:
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
func prune_orphaned_terrain_paint(
	affected_cells: Rect2i = Rect2i()
) -> PackedStringArray:
	var scoped := affected_cells.size.x > 0 and affected_cells.size.y > 0
	var live_uids := terrain.face_uid_set(affected_cells)
	# Several paint placements can reference the same face, so releases are
	# collected as a set. Native decals do not own material-paint image data.
	var released_set: Dictionary = {}
	var released := PackedStringArray()
	var emptied: Array[SurfacePlacement] = []
	var changed := false
	for placement: SurfacePlacement in surfaces:
		var retained := PackedStringArray()
		for uid: String in placement.terrain_face_uids:
			if scoped and not _terrain_face_uid_is_in_cells(uid, affected_cells):
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
		remove_surfaces_bulk(emptied)
	elif changed:
		rebuild_indexes()
		board_changed.emit()
	return released


## Remove paint only from explicitly named terrain faces that no longer exist.
##
## GLB contact patches know exactly which side bands they changed, so this path
## avoids scanning unrelated surface placements or rebuilding document indexes.
func prune_terrain_paint_uids(
	candidate_uids: PackedStringArray
) -> PackedStringArray:
	var candidates: Dictionary = {}
	var affected_placements: Dictionary = {}
	for uid: String in candidate_uids:
		candidates[uid] = true
		var painted := _paint_uid_index.get(uid, null) as SurfacePlacement
		if painted != null:
			affected_placements[painted.get_instance_id()] = painted
		for value: Variant in _shader_decal_uid_index.get(uid, []) as Array:
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
				live_uids_by_cell[cell] = terrain.face_uid_set(
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
		_unindex_spatial_placement(placement)
		placement.terrain_face_uids = retained
		if retained.is_empty():
			emptied.append(placement)
		else:
			_index_spatial_placement(placement)
	for placement: SurfacePlacement in emptied:
		surfaces.erase(placement)
	if changed:
		board_changed.emit()
	return released


## Return the exact world position one prop's artwork and voxel volume both stand at.
##
## X and Z are the authored address and Y is the exact canonical support height.
## Physical placement is never quantized. The gameplay grid and solid index derive
## integer lookup keys from overlaps with the resulting world boxes, but those keys
## are not another pose. Anything that is drawn, collided with, or picked -- the
## artwork, physics shapes, occupancy overlay, and selection volume -- reads this
## one answer, so a pad flattened to 2.9 m cannot leave its blocker at 2 m.
func prop_world_origin(placement: PropPlacement) -> Vector3:
	if placement == null:
		return Vector3.ZERO
	if placement.support == PropPlacement.SUPPORT_WALL:
		var asset := resolve_prop_asset(placement)
		if asset == null:
			push_error(
				"[Tile Studio] cannot pose unresolved wall prop '%s'." % placement.asset_id
			)
			return Vector3(placement.origin)
		return Vector3(placement.origin) + placement.wall_mount_offset(asset)
	return Vector3(
		float(placement.origin.x),
		prop_terrain_support_height(placement),
		float(placement.origin.z)
	)


## Return one prop's measured voxel volume as offsets from prop_world_origin.
##
## These are the same oriented voxels the collision shapes and the spatial proxy
## are built from, handed out unshifted so every consumer applies the one world
## pose above instead of baking an integer level into the addresses.
func prop_local_voxels(placement: PropPlacement) -> Array[Vector3i]:
	if placement == null:
		return []
	return placement.oriented_voxels(
		resolve_prop_asset(placement),
		movement_collision_min_triangle_share_percent
	)


## Return the exact world-space boxes occupied by one prop's measured voxel scan.
##
## Every box is the local scan translated by prop_world_origin, which is the same
## placement used by the GLB artwork and editor physics. Integer gameplay cells
## may be derived from these boxes, but they never become a second physical pose.
func prop_world_voxel_boxes(placement: PropPlacement) -> Array[AABB]:
	var boxes: Array[AABB] = []
	if placement == null:
		return boxes
	var world_origin := prop_world_origin(placement)
	for voxel: Vector3i in prop_local_voxels(placement):
		boxes.append(AABB(world_origin + Vector3(voxel), Vector3.ONE))
	return boxes


## Return the integer lattice cells intersected by one prop's real world voxel boxes.
##
## Tactical lookups remain cell-addressed, but their cells are derived from the
## physical boxes after the exact GLB translation is applied. A fractionally lifted
## one-metre box therefore intersects both levels it actually crosses instead of
## being moved wholesale to the floored support level.
func prop_occupied_cells(placement: PropPlacement) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var included: Dictionary = {}
	for box: AABB in prop_world_voxel_boxes(placement):
		var box_end := box.position + box.size
		var minimum_cell := Vector3i(
			floori(box.position.x + TerrainMesh.LEVEL_EPSILON_M),
			floori(box.position.y + TerrainMesh.LEVEL_EPSILON_M),
			floori(box.position.z + TerrainMesh.LEVEL_EPSILON_M)
		)
		var maximum_cell := Vector3i(
			floori(box_end.x - TerrainMesh.LEVEL_EPSILON_M),
			floori(box_end.y - TerrainMesh.LEVEL_EPSILON_M),
			floori(box_end.z - TerrainMesh.LEVEL_EPSILON_M)
		)
		for cell_x: int in range(minimum_cell.x, maximum_cell.x + 1):
			for cell_y: int in range(minimum_cell.y, maximum_cell.y + 1):
				for cell_z: int in range(minimum_cell.z, maximum_cell.z + 1):
					var cell := Vector3i(cell_x, cell_y, cell_z)
					if included.has(cell):
						continue
					included[cell] = true
					cells.append(cell)
	return cells


## Return stable solid keys derived from one prop's exact world voxel boxes.
func prop_solid_keys(placement: PropPlacement) -> PackedStringArray:
	var keys := PackedStringArray()
	for cell: Vector3i in prop_occupied_cells(placement):
		keys.append(K.voxel_key(cell))
	return keys


## Add one prop to the derived horizontal footprint index.
func _index_prop_footprint(placement: PropPlacement) -> void:
	if placement == null:
		return
	for cell: Vector2i in placement.footprint_cells(resolve_prop_asset(placement)):
		var indexed: Array[PropPlacement] = []
		for value: Variant in _prop_footprint_index.get(cell, []) as Array:
			var existing := value as PropPlacement
			if existing != null:
				indexed.append(existing)
		if not indexed.has(placement):
			indexed.append(placement)
		_prop_footprint_index[cell] = indexed


## Remove one prop from the derived horizontal footprint index.
func _unindex_prop_footprint(placement: PropPlacement) -> void:
	if placement == null:
		return
	for cell: Vector2i in placement.footprint_cells(resolve_prop_asset(placement)):
		var indexed: Array[PropPlacement] = []
		for value: Variant in _prop_footprint_index.get(cell, []) as Array:
			var existing := value as PropPlacement
			if existing != null and existing != placement:
				indexed.append(existing)
		if indexed.is_empty():
			_prop_footprint_index.erase(cell)
		else:
			_prop_footprint_index[cell] = indexed


## Return only floor props whose horizontal footprints touch the supplied regions.
func props_touching_terrain_regions(
	regions: Array[Rect2i]
) -> Array[PropPlacement]:
	var result: Array[PropPlacement] = []
	var included: Dictionary = {}
	for region: Rect2i in regions:
		if region.size.x <= 0 or region.size.y <= 0:
			continue
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				var cell := region.position + Vector2i(local_x, local_z)
				for value: Variant in _prop_footprint_index.get(cell, []) as Array:
					var placement := value as PropPlacement
					if (
						placement == null
						or placement.support != PropPlacement.SUPPORT_FLOOR
						or included.has(placement.get_instance_id())
					):
						continue
					included[placement.get_instance_id()] = true
					result.append(placement)
	return result


## Snapshot old occupancy keys for props supported by terrain about to change.
##
## Terrain owns support height, so the old keys must be captured before the
## canonical height write; deriving them afterwards would leave stale voxels at
## the previous level.
func capture_prop_support_state(regions: Array[Rect2i]) -> Dictionary:
	var placements := props_touching_terrain_regions(regions)
	var solid_keys_by_id: Dictionary = {}
	for placement: PropPlacement in placements:
		solid_keys_by_id[placement.get_instance_id()] = prop_solid_keys(placement)
	return {
		"placements": placements,
		"solid_keys_by_id": solid_keys_by_id,
	}


## Reconcile only the prop supports captured before one regional terrain write.
func reconcile_prop_support_state(snapshot: Dictionary) -> Array[PropPlacement]:
	var reconciled: Array[PropPlacement] = []
	var solid_keys_by_id: Dictionary = snapshot.get("solid_keys_by_id", {})
	for value: Variant in snapshot.get("placements", []) as Array:
		var placement := value as PropPlacement
		if placement == null:
			continue
		var previous_keys: PackedStringArray = solid_keys_by_id.get(
			placement.get_instance_id(),
			PackedStringArray()
		)
		for key: String in previous_keys:
			if _solid_index.get(key, null) == placement:
				_solid_index.erase(key)
		for key: String in prop_solid_keys(placement):
			_solid_index[key] = placement
		reconciled.append(placement)
	return reconciled



## Rebuild every derived occupancy index from canonical placements.
##
## Terrain paint is indexed by stable TerrainMesh UID rather than by lattice
## address, so an authored material stays attached to the face it was painted on
## no matter how the heightfield beneath it is later sculpted.
func rebuild_indexes() -> void:
	rebuild_gameplay_indexes()
	_paint_uid_index.clear()
	_solid_index.clear()
	_prop_footprint_index.clear()

	_shader_decal_uid_index.clear()
	for placement: SurfacePlacement in surfaces:
		# Only material paint owns a terrain paint UID. Native decals remain
		# independent projector nodes; one shader decal may share each receiving
		# terrain face through its ordinary material.
		if placement.is_overlay():
			if placement.is_shader_decal():
				_index_shader_decal(placement)
			continue
		for uid: String in placement.terrain_face_uids:
			_paint_uid_index[uid] = placement

	# Spatial lookup keys are rebuilt from each prop's exact world voxel boxes.
	for placement: PropPlacement in props:
		_index_spatial_placement(placement)

## Return whether one spatial placement resource belongs to this document.
func _placement_belongs_to_board(placement: Resource) -> bool:
	if placement is SurfacePlacement:
		return surfaces.has(placement as SurfacePlacement)
	if placement is PropPlacement:
		return props.has(placement as PropPlacement)
	return false


## Validate one partial transform state before any canonical record is mutated.
func _spatial_state_is_valid(placement: Resource, state: Dictionary) -> bool:
	var allowed_keys: PackedStringArray
	if placement is SurfacePlacement:
		allowed_keys = PackedStringArray([
			"origin",
			"face",
			"rotation_quarters",
			"terrain_face_uids",
		])
	elif placement is PropPlacement:
		allowed_keys = PackedStringArray([
			"origin",
			"forward_face",
			"roll_quarters",
			"yaw_eighths",
		])
	else:
		push_error("[Tile Studio] cannot transform an unsupported placement resource.")
		return false

	for key_value: Variant in state.keys():
		var key := String(key_value)
		if key not in allowed_keys:
			push_error("[Tile Studio] unsupported spatial state key '%s'." % key)
			return false
	if state.has("origin") and typeof(state["origin"]) != TYPE_VECTOR3I:
		push_error("[Tile Studio] placement origin must be a Vector3i.")
		return false
	for key: String in ["face", "forward_face", "rotation_quarters", "roll_quarters", "yaw_eighths"]:
		if state.has(key) and typeof(state[key]) != TYPE_INT:
			push_error("[Tile Studio] placement orientation '%s' must be an integer." % key)
			return false
	if state.has("face") and not K.FACE_NORMALS.has(int(state["face"])):
		push_error("[Tile Studio] surface face is outside the canonical face set.")
		return false
	if state.has("forward_face") and not K.FACE_NORMALS.has(int(state["forward_face"])):
		push_error("[Tile Studio] placement forward face is outside the canonical face set.")
		return false
	if state.has("rotation_quarters") and int(state["rotation_quarters"]) not in range(4):
		push_error("[Tile Studio] surface rotation must be between 0 and 3 quarter turns.")
		return false
	if state.has("roll_quarters") and int(state["roll_quarters"]) not in range(4):
		push_error("[Tile Studio] placement roll must be between 0 and 3 quarter turns.")
		return false
	if state.has("yaw_eighths") and int(state["yaw_eighths"]) not in range(8):
		push_error("[Tile Studio] prop yaw must be between 0 and 7 eighth turns.")
		return false
	return true


## Remove only one placement's current entries from the derived spatial indexes.
func _unindex_spatial_placement(placement: Resource) -> void:
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		if surface.is_overlay():
			# Shader decals own no face but ARE drawn, so their own index has to
			# follow every move; native decals are drawn as their own nodes.
			if surface.is_shader_decal():
				_unindex_shader_decal(surface)
			return
		for uid: String in surface.terrain_face_uids:
			if _paint_uid_index.get(uid, null) == surface:
				_paint_uid_index.erase(uid)
		return
	if placement is PropPlacement:
		var prop := placement as PropPlacement
		for key: String in prop_solid_keys(prop):
			if _solid_index.get(key, null) == placement:
				_solid_index.erase(key)
		_unindex_prop_footprint(prop)

## Apply one already validated partial transform state to its canonical resource.
func _apply_spatial_state(placement: Resource, state: Dictionary) -> void:
	if state.has("origin"):
		placement.set("origin", state["origin"])
	if placement is SurfacePlacement:
		if state.has("face"):
			(placement as SurfacePlacement).face = int(state["face"])
		if state.has("rotation_quarters"):
			(placement as SurfacePlacement).rotation_quarters = int(state["rotation_quarters"])
		if state.has("terrain_face_uids"):
			var face_uids := PackedStringArray()
			for uid_value: Variant in state["terrain_face_uids"] as Array:
				face_uids.append(String(uid_value))
			(placement as SurfacePlacement).terrain_face_uids = face_uids
	elif placement is PropPlacement:
		if state.has("forward_face"):
			(placement as PropPlacement).forward_face = int(state["forward_face"])
		if state.has("roll_quarters"):
			(placement as PropPlacement).roll_quarters = int(state["roll_quarters"])
		if state.has("yaw_eighths"):
			(placement as PropPlacement).yaw_eighths = int(state["yaw_eighths"])


## Add only one placement's current entries to the derived spatial indexes.
func _index_spatial_placement(placement: Resource) -> void:
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		if surface.is_overlay():
			if surface.is_shader_decal():
				_index_shader_decal(surface)
			return
		for uid: String in surface.terrain_face_uids:
			_paint_uid_index[uid] = surface
		return
	if placement is PropPlacement:
		var prop := placement as PropPlacement
		for key: String in prop_solid_keys(prop):
			_solid_index[key] = placement
		_index_prop_footprint(prop)

## Apply placement transforms while reindexing only the records that changed.
##
## Every old entry is removed before any record changes, so grouped moves remain
## atomic even when selected placements exchange cells. The caller owns the one
## scoped editor notification after this canonical mutation succeeds.
func apply_placement_spatial_states(
	targets: Array[Resource],
	states: Array[Dictionary]
) -> bool:
	if targets.size() != states.size():
		push_error("[Tile Studio] cannot apply mismatched placement transform state.")
		return false
	var seen_ids: Dictionary = {}
	for index: int in targets.size():
		var target := targets[index]
		if target == null or not _placement_belongs_to_board(target):
			push_error("[Tile Studio] cannot transform a placement outside this board.")
			return false
		var instance_id := target.get_instance_id()
		if seen_ids.has(instance_id):
			push_error("[Tile Studio] cannot transform one placement twice in a single action.")
			return false
		seen_ids[instance_id] = true
		if not _spatial_state_is_valid(target, states[index]):
			return false

	for target: Resource in targets:
		_unindex_spatial_placement(target)
	for index: int in targets.size():
		_apply_spatial_state(targets[index], states[index])
	for target: Resource in targets:
		_index_spatial_placement(target)
	return true


## Return the surface placement painting one stable terrain face.
func surface_at_paint_uid(paint_uid: String) -> SurfacePlacement:
	return _paint_uid_index.get(paint_uid, null) as SurfacePlacement



## Return the shader decal assigned to one terrain face as a typed array.
##
## The array shape keeps indexing code uniform, while validation enforces the
## direct-material invariant that at most one shader decal covers a face.
func shader_decals_at_paint_uid(paint_uid: String) -> Array[SurfacePlacement]:
	var found: Array[SurfacePlacement] = []
	var stored: Variant = _shader_decal_uid_index.get(paint_uid, null)
	if stored is Array:
		for placement_value: Variant in stored as Array:
			var placement := placement_value as SurfacePlacement
			if placement != null:
				found.append(placement)
	return found


## Return whether any shader decal is currently attached to terrain.
##
## The renderer uses this index to group only affected faces into direct-material
## batches; no image or texture-array artifact is allocated.
func has_shader_decals() -> bool:
	return not _shader_decal_uid_index.is_empty()


## Record one shader decal against every terrain face it covers.
func _index_shader_decal(placement: SurfacePlacement) -> void:
	for uid: String in placement.terrain_face_uids:
		var stored: Variant = _shader_decal_uid_index.get(uid, null)
		var bucket: Array = stored if stored is Array else []
		if not bucket.has(placement):
			bucket.append(placement)
		_shader_decal_uid_index[uid] = bucket


## Remove one shader decal from every terrain face it covered.
func _unindex_shader_decal(placement: SurfacePlacement) -> void:
	for uid: String in placement.terrain_face_uids:
		var stored: Variant = _shader_decal_uid_index.get(uid, null)
		if not stored is Array:
			continue
		var bucket: Array = stored
		bucket.erase(placement)
		if bucket.is_empty():
			_shader_decal_uid_index.erase(uid)
		else:
			_shader_decal_uid_index[uid] = bucket


## Return the canonical solid placement occupying one voxel.
func solid_placement_at(cell: Vector3i) -> Resource:
	return _solid_index.get(K.voxel_key(cell), null) as Resource


## Return the prop claiming one solid voxel.
func prop_at(cell: Vector3i) -> PropPlacement:
	return solid_placement_at(cell) as PropPlacement


## Return every surface displaced by a candidate painting the same terrain faces.
##
## Conflicts come straight from the canonical paint index, so replacement never
## guesses from art bounds or maintains a second spatial map.
func surface_conflicting_placements(
	placement: SurfacePlacement
) -> Array[SurfacePlacement]:
	var conflicts: Array[SurfacePlacement] = []
	# Native decals layer over terrain paint, so they claim no paint occupancy.
	if placement == null or placement.is_overlay():
		return conflicts
	for uid: String in placement.terrain_face_uids:
		var occupant := surface_at_paint_uid(uid)
		if occupant != null and occupant != placement and not conflicts.has(occupant):
			conflicts.append(occupant)
	return conflicts


## Return every prop displaced by a candidate claiming its solid voxels.
func prop_conflicting_placements(
	placement: PropPlacement
) -> Array[PropPlacement]:
	var conflicts: Array[PropPlacement] = []
	if placement == null:
		return conflicts
	for cell: Vector3i in prop_occupied_cells(placement):
		var occupant := prop_at(cell)
		if occupant != null and not conflicts.has(occupant):
			conflicts.append(occupant)
	return conflicts


## Validate one surface against its reference contract and current terrain paint.
func validate_surface(
	placement: SurfacePlacement,
	ignore: SurfacePlacement = null
) -> Dictionary:
	var reference_error := _validate_surface_reference(placement)
	if not reference_error.is_empty():
		return {"valid": false, "reason": reference_error, "conflicts": []}

	if terrain == null or terrain.is_empty():
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
			for existing: SurfacePlacement in shader_decals_at_paint_uid(uid):
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
		var occupant := surface_at_paint_uid(uid)
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
func validate_prop(
	placement: PropPlacement,
	ignore: PropPlacement = null
) -> Dictionary:
	var reference_error := _validate_prop_reference(placement)
	if not reference_error.is_empty():
		return {"valid": false, "reason": reference_error, "conflicts": []}

	var conflicts: Array = []
	for cell: Vector3i in prop_occupied_cells(placement):
		var key := K.voxel_key(cell)
		var occupant := _solid_index.get(key, null) as Resource
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
func prop_terrain_support_height(
	placement: PropPlacement,
	support_terrain: TerrainMesh = null
) -> float:
	var sampled_terrain := support_terrain if support_terrain != null else terrain
	if placement == null or sampled_terrain == null or sampled_terrain.is_empty():
		return float(placement.origin.y) if placement != null else 0.0
	var asset := resolve_prop_asset(placement)
	var highest := -INF
	for cell: Vector2i in placement.footprint_cells(asset):
		if sampled_terrain.is_cell_filled(cell):
			highest = maxf(highest, sampled_terrain.cell_walk_height(cell))
	if highest == -INF:
		return float(placement.origin.y)
	return highest


## Return every canonical surface placement that renders.
func renderable_surfaces() -> Array[SurfacePlacement]:
	var result: Array[SurfacePlacement] = []
	result.append_array(surfaces)
	return result



## Validate one surface's asset reference and its type.
func _validate_surface_reference(placement: SurfacePlacement) -> String:
	if placement == null:
		return "surface placement is null"
	var reference_error := placement.reference_error()
	if not reference_error.is_empty():
		return reference_error
	var asset := resolve_surface_asset(placement)
	if asset == null:
		return "unknown asset '%s'" % placement.asset_id
	if not asset.is_surface():
		return "'%s' is not a surface asset" % placement.asset_id
	return ""


## Validate one prop's asset reference, type, and exact measured occupancy.
func _validate_prop_reference(placement: PropPlacement) -> String:
	if placement == null:
		return "prop placement is null"
	var reference_error := placement.reference_error()
	if not reference_error.is_empty():
		return reference_error
	var asset := resolve_prop_asset(placement)
	if asset == null:
		return "unknown asset '%s'" % placement.asset_id
	if not asset.is_prop():
		return "'%s' is not a prop asset" % placement.asset_id
	var voxel_scan_error := placement.voxel_scan_error(
		asset,
		movement_collision_min_triangle_share_percent
	)
	if not voxel_scan_error.is_empty():
		return voxel_scan_error
	return ""


## Validate the complete document against its canonical terrain and occupancy.
func validate_all() -> Dictionary:
	var errors := PackedStringArray()
	var missing_assets := PackedStringArray()
	var seen_paint_uids: Dictionary = {}
	var seen_voxels: Dictionary = {}
	var seen_pack_ids: Dictionary = {}
	var seen_marker_ids: Dictionary = {}
	var seen_marker_cells: Dictionary = {}

	for terrain_error in terrain.validate_definition():
		errors.append(terrain_error)

	for key_value: Variant in movement_unwalkable_cells.keys():
		var blocked_key := String(key_value)
		var blocked_cell: Variant = movement_cell_from_key(blocked_key)
		if not blocked_cell is Vector2i:
			errors.append("invalid movement-cell key '%s'" % blocked_key)
		elif not movement_cell_exists(blocked_cell as Vector2i):
			errors.append("manual movement block %s has no authored terrain" % blocked_cell)
	for key_value: Variant in movement_ground_effects.keys():
		var effect_key := String(key_value)
		var effect_cell: Variant = movement_cell_from_key(effect_key)
		var effect_label := String(movement_ground_effects[key_value]).strip_edges()
		if not effect_cell is Vector2i:
			errors.append("invalid ground-effect cell key '%s'" % effect_key)
		elif not movement_cell_exists(effect_cell as Vector2i):
			errors.append("ground effect %s has no authored terrain" % effect_cell)
		if effect_label.is_empty():
			errors.append("ground effect '%s' has an empty label" % effect_key)
		elif effect_label.length() > MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH:
			errors.append(
				"ground effect '%s' exceeds %d characters"
				% [effect_key, MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH]
			)

	for pack: EnemyPack in enemy_packs:
		if pack == null:
			errors.append("enemy pack record is null")
			continue
		for pack_error in pack.validate_definition():
			errors.append(pack_error)
		if seen_pack_ids.has(pack.pack_id):
			errors.append("duplicate enemy pack id '%s'" % pack.pack_id)
		seen_pack_ids[pack.pack_id] = true

	for monster_value: Variant in monster_visual_assets.keys():
		if not (monster_value is String):
			errors.append("monster visual id must be a string")
			continue
		var monster_id: String = monster_value
		var asset_value: Variant = monster_visual_assets[monster_value]
		if not (asset_value is String):
			errors.append("monster visual '%s' asset id must be a string" % monster_id)
			continue
		var asset_id: String = asset_value
		var assignment_report := validate_monster_visual_assignment(monster_id, asset_id)
		if not bool(assignment_report.get("valid", false)):
			errors.append(String(assignment_report.get("reason", "invalid monster visual")))
			if _library == null or _library.get_asset(asset_id) == null:
				if not missing_assets.has(asset_id):
					missing_assets.append(asset_id)

	for marker: GameplayMarker in gameplay_markers:
		if marker == null:
			errors.append("gameplay marker record is null")
			continue
		for marker_error in marker.validate_definition():
			errors.append(marker_error)
		if seen_marker_ids.has(marker.marker_id):
			errors.append("duplicate gameplay marker id '%s'" % marker.marker_id)
		seen_marker_ids[marker.marker_id] = true
		var marker_cell_key := K.voxel_key(marker.origin)
		if seen_marker_cells.has(marker_cell_key):
			errors.append("duplicate gameplay marker cell %s" % marker_cell_key)
		seen_marker_cells[marker_cell_key] = true
		if marker.marker_type == GameplayMarker.TYPE_ENEMY:
			if not marker.pack_id.is_empty() and not seen_pack_ids.has(marker.pack_id):
				errors.append(
					"enemy marker '%s' references unknown pack '%s'"
					% [marker.marker_id, marker.pack_id]
				)

	for placement: SurfacePlacement in surfaces:
		var reference_error := _validate_surface_reference(placement)
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

	for placement: PropPlacement in props:
		var prop_reference_error := _validate_prop_reference(placement)
		if not prop_reference_error.is_empty():
			errors.append(prop_reference_error)
			if (
				not placement.asset_id.is_empty()
				and not missing_assets.has(placement.asset_id)
			):
				missing_assets.append(placement.asset_id)
			continue
		for key in prop_solid_keys(placement):
			if seen_voxels.has(key):
				errors.append("overlapping solid volume %s" % key)
			seen_voxels[key] = placement

	return {
		"valid": errors.is_empty() and missing_assets.is_empty(),
		"errors": errors,
		"missing_assets": missing_assets,
		"surface_count": surfaces.size(),
		"prop_count": props.size(),
		"enemy_pack_count": enemy_packs.size(),
		"gameplay_marker_count": gameplay_markers.size(),
		"monster_visual_count": monster_visual_assets.size(),
	}


## Add one surface placement and index it according to its render role.
##
## Indexing is delegated so terrain paint, native decals, and shader decals are
## each recorded exactly once, in one place. These paths previously inlined the
## paint index themselves, which is how a second placement kind would silently
## have gone unindexed.
func add_surface(placement: SurfacePlacement) -> void:
	surfaces.append(placement)
	_index_spatial_placement(placement)
	board_changed.emit()


## Remove one surface placement and release whatever index it held.
func remove_surface(placement: SurfacePlacement) -> void:
	var index := surfaces.find(placement)
	if index < 0:
		return
	surfaces.remove_at(index)
	_unindex_spatial_placement(placement)
	board_changed.emit()


## Add multiple surfaces while updating indexes and emitting once.
func add_surfaces_bulk(placements: Array[SurfacePlacement]) -> void:
	if placements.is_empty():
		return
	for placement: SurfacePlacement in placements:
		surfaces.append(placement)
		_index_spatial_placement(placement)
	board_changed.emit()


## Remove multiple surfaces while updating indexes and emitting once.
func remove_surfaces_bulk(placements: Array[SurfacePlacement]) -> void:
	if placements.is_empty():
		return
	var changed := false
	for placement: SurfacePlacement in placements:
		var index := surfaces.find(placement)
		if index < 0:
			continue
		changed = true
		surfaces.remove_at(index)
		_unindex_spatial_placement(placement)
	if changed:
		board_changed.emit()



## Atomically replace selected structural surfaces with new surface placements.
##
## The next surface list is assembled and indexed before observers are notified,
## so the viewport never rebuilds from the temporary state with its conflicts
## removed but no replacement surfaces added.
func replace_surfaces_bulk(
	displaced: Array[SurfacePlacement],
	replacements: Array[SurfacePlacement]
) -> void:
	if displaced.is_empty() and replacements.is_empty():
		return
	for placement: SurfacePlacement in displaced:
		if not surfaces.has(placement):
			push_error(
				"[Tile Studio] cannot replace a surface that is no longer on the board."
			)
			return
	var next_surfaces: Array[SurfacePlacement] = []
	next_surfaces.append_array(surfaces)
	for placement: SurfacePlacement in displaced:
		next_surfaces.erase(placement)
	next_surfaces.append_array(replacements)
	surfaces = next_surfaces
	rebuild_indexes()
	board_changed.emit()


## Add one prop and update its canonical solid occupancy.
func add_prop(placement: PropPlacement) -> void:
	props.append(placement)
	_index_spatial_placement(placement)
	board_changed.emit()


## Remove one prop and release its canonical solid occupancy.
func remove_prop(placement: PropPlacement) -> void:
	var index := props.find(placement)
	if index < 0:
		return
	_unindex_spatial_placement(placement)
	props.remove_at(index)
	board_changed.emit()


## Add multiple props while updating canonical occupancy and emitting once.
##
## Fill commits use this path so placing hundreds of GLBs produces one document
## notification and one viewport synchronization rather than one rebuild per prop.
func add_props_bulk(placements: Array[PropPlacement]) -> void:
	if placements.is_empty():
		return
	for placement: PropPlacement in placements:
		props.append(placement)
		_index_spatial_placement(placement)
	board_changed.emit()


## Remove multiple props while releasing canonical occupancy and emitting once.
##
## Undo uses the identical placement resources added by add_props_bulk, which
## keeps resource identity and occupancy provenance explicit.
func remove_props_bulk(placements: Array[PropPlacement]) -> void:
	if placements.is_empty():
		return
	var changed := false
	for placement: PropPlacement in placements:
		var index := props.find(placement)
		if index < 0:
			continue
		changed = true
		_unindex_spatial_placement(placement)
		props.remove_at(index)
	if changed:
		board_changed.emit()


## Atomically replace selected props with new prop placements.
##
## Rebuilding indexes from the completed next list prevents observers from ever
## seeing a half-replaced prop volume or a stale occupancy entry.
func replace_props_bulk(
	displaced: Array[PropPlacement],
	replacements: Array[PropPlacement]
) -> void:
	if displaced.is_empty() and replacements.is_empty():
		return
	for placement: PropPlacement in displaced:
		if not props.has(placement):
			push_error(
				"[Tile Studio] cannot replace a prop that is no longer on the board."
			)
			return
	for placement: PropPlacement in displaced:
		_unindex_spatial_placement(placement)
		props.erase(placement)
	for placement: PropPlacement in replacements:
		props.append(placement)
		_index_spatial_placement(placement)
	board_changed.emit()


## Clear all authored board state, including terrain and derived indexes.
func clear() -> void:
	_clear_state()
	board_changed.emit()


## Clear canonical and derived state without exposing a transient empty document.
##
## Detached loading uses this path so listeners observe only the final prepared
## board, while the explicit New Board action continues through clear().
func _clear_state() -> void:
	surfaces.clear()
	props.clear()
	enemy_packs.clear()
	gameplay_markers.clear()
	particle_effects.clear()
	monster_visual_assets.clear()
	imported_asset_ids.clear()
	# Replace canonical movement and terrain state together so New Board cannot
	# inherit collision rules or annotations from the level that was just closed.
	terrain = TerrainMesh.new()
	movement_collision_min_triangle_share_percent = 0.0
	movement_unwalkable_cells.clear()
	movement_ground_effects.clear()
	surface_material_paint.clear()
	material_blend = MaterialBlendProfile.new()
	_paint_uid_index.clear()
	_solid_index.clear()
	_prop_footprint_index.clear()
	_enemy_pack_index.clear()
	_gameplay_marker_index.clear()
	_gameplay_marker_cell_index.clear()



## Notify look consumers after an in-place profile edit.
func notify_look_changed() -> void:
	look_changed.emit()


## Reset only the board's aesthetics profile to documented defaults.
func reset_aesthetics() -> void:
	aesthetics.reset_to_defaults()
	look_changed.emit()


## Reset only the board's lighting profile to documented defaults.
func reset_lighting() -> void:
	lighting.reset_to_defaults()
	look_changed.emit()


## Reset both saved look profiles to documented defaults.
func reset_look() -> void:
	aesthetics.reset_to_defaults()
	lighting.reset_to_defaults()
	look_changed.emit()


## Return whether the board contains no authored terrain and no placements.
##
## Terrain is counted because a sculpted heightfield with nothing on it is a real
## authored board; treating it as empty would misreport framing, world-field
## coverage, and the empty-board state to the user.
func is_empty() -> bool:
	return (
		(terrain == null or terrain.is_empty())
		and surfaces.is_empty()
		and props.is_empty()
		and gameplay_markers.is_empty()
		and particle_effects.is_empty()
	)



## Announce that the authored terrain changed so derived state can rebuild.
##
## Terrain is board geometry rather than a look setting, so it emits
## board_changed: the visible mesh, prop supports, and collision all follow it.
func notify_terrain_changed() -> void:
	prune_movement_grid_cells()
	board_changed.emit()


## Return the gameplay grid derived from the current authored terrain.
##
## This is the tactical surface characters walk on. Every entry is computed from
## the frozen corner heights at call time, so it can never drift from the terrain
## the user sculpted and the renderer draws. It is a read-only projection and is
## deliberately not stored on the board.
##
## Each cell reports its integer coordinate, its derived form, the height a token
## stands at, the vertical relief across the cell, and the XZ gradient used to
## orient tokens and judge whether a ramp is climbable.
func gameplay_grid() -> Array[Dictionary]:
	var cells: Array[Dictionary] = []
	if terrain == null or terrain.is_empty():
		return cells
	for local_z: int in terrain.size_cells.y:
		for local_x: int in terrain.size_cells.x:
			var cell := terrain.origin_cell + Vector2i(local_x, local_z)
			if not terrain.is_cell_filled(cell):
				continue
			cells.append({
				"cell": cell,
				"form": terrain.classify_cell(cell),
				"form_name": terrain.cell_form_name(terrain.classify_cell(cell)),
				"walk_height_m": terrain.cell_walk_height(cell),
				"relief_m": terrain.cell_relief(cell),
				"gradient": terrain.cell_gradient(cell),
				"manually_unwalkable": movement_cell_is_unwalkable(cell),
				"ground_effect": movement_ground_effect(cell),
			})
	return cells


## Return the inclusive world bounds of the terrain and every placement.
##
## The terrain footprint and its real height range are included because terrain
## is the board's primary geometry; camera framing, world fields, and lighting
## bounds all read this one result.
func compute_bounds() -> AABB:
	if is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)

	if terrain != null and not terrain.is_empty():
		var footprint := terrain.filled_bounds_cells()
		if footprint.size.x > 0 and footprint.size.y > 0:
			# Terrain spans its filled cell rectangle in XZ and its real sculpted
			# elevation range in Y, including the skirt hanging below the lowest top.
			minimum = minimum.min(Vector3(
				float(footprint.position.x),
				terrain.lowest_top_height() - terrain.skirt_depth_m,
				float(footprint.position.y)
			))
			maximum = maximum.max(Vector3(
				float(footprint.position.x + footprint.size.x),
				terrain.highest_top_height(),
				float(footprint.position.y + footprint.size.y)
			))

	for marker: GameplayMarker in gameplay_markers:
		minimum = minimum.min(Vector3(marker.origin))
		maximum = maximum.max(Vector3(marker.origin) + Vector3.ONE)

	for effect: ParticleEffectPlacement in particle_effects:
		minimum = minimum.min(effect.position - Vector3.ONE * 0.5)
		maximum = maximum.max(effect.position + Vector3.ONE * 0.5)

	for placement: PropPlacement in props:
		var cells := prop_occupied_cells(placement)
		if cells.is_empty():
			cells = [placement.origin]
		for cell: Vector3i in cells:
			minimum = minimum.min(Vector3(cell))
			maximum = maximum.max(Vector3(cell) + Vector3.ONE)

	if minimum.x == INF:
		return AABB(Vector3.ZERO, Vector3.ONE)
	return AABB(minimum, (maximum - minimum).max(Vector3.ONE))



## Serialize board-owned movement rules in stable coordinate order.
func movement_grid_to_json() -> Dictionary:
	var unwalkable_records: Array = []
	for cell: Vector2i in _sorted_movement_cells(movement_unwalkable_cells):
		unwalkable_records.append([cell.x, cell.y])
	var effect_records: Array = []
	for cell: Vector2i in _sorted_movement_cells(movement_ground_effects):
		effect_records.append({
			"cell": [cell.x, cell.y],
			"label": movement_ground_effect(cell),
		})
	return {
		"collision_min_triangle_share_percent": (
			movement_collision_min_triangle_share_percent
		),
		"unwalkable_cells": unwalkable_records,
		"ground_effects": effect_records,
	}


## Serialize the complete portable board with one canonical reference per placement.
func to_json() -> Dictionary:
	var surface_list: Array = []
	for placement: SurfacePlacement in surfaces:
		surface_list.append(placement.to_json())
	var prop_list: Array = []
	for placement: PropPlacement in props:
		prop_list.append(placement.to_json())
	var pack_list: Array = []
	for pack: EnemyPack in enemy_packs:
		pack_list.append(pack.to_json())
	var marker_list: Array = []
	for marker: GameplayMarker in gameplay_markers:
		marker_list.append(marker.to_json())
	var particle_effect_list: Array = []
	for effect: ParticleEffectPlacement in particle_effects:
		particle_effect_list.append(effect.to_json())
	var monster_visual_list: Array = []
	var monster_ids: Array = monster_visual_assets.keys()
	monster_ids.sort()
	for monster_value: Variant in monster_ids:
		monster_visual_list.append({
			"monster": monster_value,
			"asset": monster_visual_assets[monster_value],
		})
	# Written out as a plain JSON array of ids, in import order, so the record is
	# readable by anything that parses the board format rather than only by Godot.
	var imported_asset_list: Array = []
	for imported_id: String in imported_asset_ids:
		imported_asset_list.append(imported_id)
	return {
		"version": FORMAT_VERSION,
		"name": board_name,
		"biome": biome,
		"surfaces": surface_list,
		"props": prop_list,
		"enemy_packs": pack_list,
		"gameplay_markers": marker_list,
		"particle_effects": particle_effect_list,
		"monster_visuals": monster_visual_list,
		"imported_assets": imported_asset_list,
		"terrain": terrain.to_json(),
		"movement_grid": movement_grid_to_json(),
		"surface_material_paint": surface_material_paint.duplicate(true),
		"material_blend": material_blend.to_json(),
		"aesthetics": aesthetics.to_json(),
		"lighting": lighting.to_json(),
	}


## Return whether one required saved string exists and is non-empty.
static func _serialized_string_is_present(record: Dictionary, field: String) -> bool:
	var value: Variant = record.get(field, null)
	return value is String and not String(value).is_empty()


## Return whether one saved vector contains exactly the required numeric components.
static func _serialized_vector_is_valid(
	record: Dictionary,
	field: String,
	component_count: int
) -> bool:
	var value: Variant = record.get(field, null)
	if not (value is Array) or (value as Array).size() != component_count:
		return false
	for component: Variant in value:
		if not (component is int) and not (component is float):
			return false
	return true


## Report structural persistence errors before saved data can mutate a board or replace a file.
##
## This deliberately validates identities and coordinates without resolving library
## assets, because a missing asset is a reportable board error while an empty
## placement object is a destructive serialization failure.
static func serialized_data_errors(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var array_names: Array[String] = [
		"surfaces",
		"props",
		"enemy_packs",
		"gameplay_markers",
		"particle_effects",
		"monster_visuals",
	]
	for array_name: String in array_names:
		var records_value: Variant = data.get(array_name, [])
		if not (records_value is Array):
			errors.append("'%s' must be an array" % array_name)
			continue
		var records: Array = records_value
		for index: int in records.size():
			var entry_value: Variant = records[index]
			if not (entry_value is Dictionary):
				errors.append("%s[%d] must be an object" % [array_name, index])
				continue
			var entry: Dictionary = entry_value
			if entry.is_empty():
				errors.append("%s[%d] is empty" % [array_name, index])

	# A board written before the import record existed simply has no key here, which
	# reads as "no imports were noted" rather than as malformed data.
	var imported_assets_value: Variant = data.get("imported_assets", [])
	if not (imported_assets_value is Array):
		errors.append("'imported_assets' must be an array")
	else:
		var imported_records: Array = imported_assets_value
		for index: int in imported_records.size():
			var imported_value: Variant = imported_records[index]
			if not (imported_value is String) or String(imported_value).is_empty():
				errors.append("imported_assets[%d] must be a non-empty asset id" % index)

	var surface_records_value: Variant = data.get("surfaces", [])
	var serialized_surface_uids: Dictionary = {}
	if surface_records_value is Array:
		var surface_records: Array = surface_records_value
		for index: int in surface_records.size():
			if not (surface_records[index] is Dictionary):
				continue
			var surface_record: Dictionary = surface_records[index]
			if not _serialized_string_is_present(surface_record, "asset"):
				errors.append("surfaces[%d] has no asset" % index)
			if not _serialized_vector_is_valid(surface_record, "origin", 3):
				errors.append("surfaces[%d] has no three-component origin" % index)
			if not _serialized_string_is_present(surface_record, "face"):
				errors.append("surfaces[%d] has no face" % index)
			var surface_uid := String(surface_record.get("uid", ""))
			if int(data.get("version", 1)) >= 7 and surface_uid.is_empty():
				errors.append("surfaces[%d] has no uid" % index)
			elif not surface_uid.is_empty():
				if serialized_surface_uids.has(surface_uid):
					errors.append("surfaces[%d] duplicates uid '%s'" % [index, surface_uid])
				serialized_surface_uids[surface_uid] = true

	var prop_records_value: Variant = data.get("props", [])
	if prop_records_value is Array:
		var prop_records: Array = prop_records_value
		for index: int in prop_records.size():
			if not (prop_records[index] is Dictionary):
				continue
			var prop_record: Dictionary = prop_records[index]
			if not _serialized_string_is_present(prop_record, "asset"):
				errors.append("props[%d] has no asset" % index)
			if not _serialized_vector_is_valid(prop_record, "origin", 3):
				errors.append("props[%d] has no three-component origin" % index)
			var has_forward := _serialized_string_is_present(prop_record, "forward")
			var has_legacy_facing := _serialized_string_is_present(prop_record, "facing")
			if not has_forward and not has_legacy_facing:
				errors.append("props[%d] has no forward or legacy facing" % index)

	var enemy_pack_records_value: Variant = data.get("enemy_packs", [])
	if enemy_pack_records_value is Array:
		var enemy_pack_records: Array = enemy_pack_records_value
		for index: int in enemy_pack_records.size():
			if enemy_pack_records[index] is Dictionary:
				if not _serialized_string_is_present(enemy_pack_records[index], "id"):
					errors.append("enemy_packs[%d] has no id" % index)

	var marker_records_value: Variant = data.get("gameplay_markers", [])
	if marker_records_value is Array:
		var marker_records: Array = marker_records_value
		for index: int in marker_records.size():
			if not (marker_records[index] is Dictionary):
				continue
			var marker_record: Dictionary = marker_records[index]
			if not _serialized_string_is_present(marker_record, "id"):
				errors.append("gameplay_markers[%d] has no id" % index)
			if not _serialized_string_is_present(marker_record, "type"):
				errors.append("gameplay_markers[%d] has no type" % index)
			if not _serialized_vector_is_valid(marker_record, "origin", 3):
				errors.append("gameplay_markers[%d] has no three-component origin" % index)

	var particle_records_value: Variant = data.get("particle_effects", [])
	if particle_records_value is Array:
		var particle_records: Array = particle_records_value
		for index: int in particle_records.size():
			if not (particle_records[index] is Dictionary):
				continue
			var particle_record: Dictionary = particle_records[index]
			if not _serialized_string_is_present(particle_record, "placement_id"):
				errors.append("particle_effects[%d] has no placement_id" % index)
			if not _serialized_string_is_present(particle_record, "preset_id"):
				errors.append("particle_effects[%d] has no preset_id" % index)
			if not _serialized_vector_is_valid(particle_record, "position", 3):
				errors.append("particle_effects[%d] has no three-component position" % index)

	var monster_visual_records_value: Variant = data.get("monster_visuals", [])
	if monster_visual_records_value is Array:
		var monster_visual_records: Array = monster_visual_records_value
		for index: int in monster_visual_records.size():
			if not (monster_visual_records[index] is Dictionary):
				continue
			var monster_visual_record: Dictionary = monster_visual_records[index]
			if not _serialized_string_is_present(monster_visual_record, "monster"):
				errors.append("monster_visuals[%d] has no monster id" % index)
			if not _serialized_string_is_present(monster_visual_record, "asset"):
				errors.append("monster_visuals[%d] has no asset id" % index)

	var paint_value: Variant = data.get("surface_material_paint", {})
	if not paint_value is Dictionary:
		errors.append("'surface_material_paint' must be an object")
	else:
		var paint_metadata: Dictionary = paint_value
		var painted_surfaces_value: Variant = paint_metadata.get("surfaces", [])
		if not painted_surfaces_value is Array:
			errors.append("surface_material_paint.surfaces must be an array")
		else:
			# Material paint is keyed by canonical TerrainMesh face UIDs, so the
			# terrain travelling in this same document is what decides whether a
			# painted face exists. Surface placement identities are a different
			# namespace entirely and are never valid paint keys.
			var terrain_uids: Dictionary = {}
			var validated_terrain_value: Variant = data.get("terrain", null)
			if validated_terrain_value is Dictionary:
				terrain_uids = TerrainMesh.from_json(validated_terrain_value).face_uid_set()
			var painted_uids: Dictionary = {}
			for index: int in (painted_surfaces_value as Array).size():
				var entry_value: Variant = (painted_surfaces_value as Array)[index]
				if not entry_value is Dictionary:
					errors.append("surface_material_paint.surfaces[%d] must be an object" % index)
					continue
				var entry: Dictionary = entry_value
				var uid := String(entry.get("uid", ""))
				if uid.is_empty() or not terrain_uids.has(uid):
					errors.append("surface material paint entry '%s' has no matching terrain face" % uid)
				elif painted_uids.has(uid):
					errors.append("surface material paint duplicates uid '%s'" % uid)
				painted_uids[uid] = true
				if not _serialized_string_is_present(entry, "file"):
					errors.append("surface material paint '%s' has no file" % uid)
				if not _serialized_string_is_present(entry, "file_sha256"):
					errors.append("surface material paint '%s' has no checksum" % uid)
				if not _serialized_vector_is_valid(entry, "resolution", 2):
					errors.append("surface material paint '%s' has no resolution" % uid)

		var material_slots_value: Variant = paint_metadata.get("material_slots", [])
		if not material_slots_value is Array:
			errors.append("surface_material_paint.material_slots must be an array")
		else:
			var slot_terrain_uids: Dictionary = {}
			var slot_terrain_value: Variant = data.get("terrain", null)
			if slot_terrain_value is Dictionary:
				slot_terrain_uids = TerrainMesh.from_json(slot_terrain_value).face_uid_set()
			var palette_layers_value: Variant = (
				(data.get("material_blend", {}) as Dictionary).get("layers", [])
				if data.get("material_blend", {}) is Dictionary
				else []
			)
			var palette_size := (
				(palette_layers_value as Array).size()
				if palette_layers_value is Array
				else 0
			)
			var mapped_uids: Dictionary = {}
			for index: int in (material_slots_value as Array).size():
				var slot_entry_value: Variant = (material_slots_value as Array)[index]
				if not slot_entry_value is Dictionary:
					errors.append("surface_material_paint.material_slots[%d] must be an object" % index)
					continue
				var slot_entry: Dictionary = slot_entry_value
				var uid := String(slot_entry.get("uid", ""))
				if uid.is_empty() or not slot_terrain_uids.has(uid):
					errors.append("surface material slots entry '%s' has no matching terrain face" % uid)
				elif mapped_uids.has(uid):
					errors.append("surface material slots duplicate uid '%s'" % uid)
				mapped_uids[uid] = true
				var indices_value: Variant = slot_entry.get("palette_indices", [])
				if (
					not indices_value is Array
					or (indices_value as Array).size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
				):
					errors.append("surface material slots '%s' must contain four palette indices" % uid)
					continue
				for palette_value: Variant in indices_value as Array:
					var palette_index := int(palette_value)
					if palette_index < -1 or palette_index >= palette_size:
						errors.append(
							"surface material slots '%s' references palette index %d of %d"
							% [uid, palette_index, palette_size]
						)
			if int(data.get("version", 1)) >= FORMAT_VERSION:
				for terrain_uid_value: Variant in slot_terrain_uids.keys():
					var terrain_uid := String(terrain_uid_value)
					if not mapped_uids.has(terrain_uid):
						errors.append(
							"surface material slots omit terrain face '%s'" % terrain_uid
						)

	var movement_value: Variant = data.get("movement_grid", {})
	if not movement_value is Dictionary:
		errors.append("'movement_grid' must be an object")
	else:
		var movement_data := movement_value as Dictionary
		var threshold_value: Variant = movement_data.get(
			"collision_min_triangle_share_percent",
			0.0
		)
		if (
			not threshold_value is int
			and not threshold_value is float
		):
			errors.append(
				"movement_grid.collision_min_triangle_share_percent must be numeric"
			)
		elif float(threshold_value) < 0.0 or float(threshold_value) > 100.0:
			errors.append(
				"movement_grid.collision_min_triangle_share_percent must be 0..100"
			)

		var unwalkable_value: Variant = movement_data.get("unwalkable_cells", [])
		var seen_unwalkable: Dictionary = {}
		if not unwalkable_value is Array:
			errors.append("movement_grid.unwalkable_cells must be an array")
		else:
			for index: int in (unwalkable_value as Array).size():
				var blocked_cell_value: Variant = (unwalkable_value as Array)[index]
				if (
					not blocked_cell_value is Array
					or (blocked_cell_value as Array).size() != 2
					or not (
						(blocked_cell_value as Array)[0] is int
						or (blocked_cell_value as Array)[0] is float
					)
					or not (
						(blocked_cell_value as Array)[1] is int
						or (blocked_cell_value as Array)[1] is float
					)
				):
					errors.append(
						"movement_grid.unwalkable_cells[%d] must be [x,z]"
						% index
					)
					continue
				var blocked_key := "%d,%d" % [
					int((blocked_cell_value as Array)[0]),
					int((blocked_cell_value as Array)[1]),
				]
				if seen_unwalkable.has(blocked_key):
					errors.append(
						"movement_grid.unwalkable_cells duplicates %s"
						% blocked_key
					)
				seen_unwalkable[blocked_key] = true

		var effects_value: Variant = movement_data.get("ground_effects", [])
		var seen_effects: Dictionary = {}
		if not effects_value is Array:
			errors.append("movement_grid.ground_effects must be an array")
		else:
			for index: int in (effects_value as Array).size():
				var effect_value: Variant = (effects_value as Array)[index]
				if not effect_value is Dictionary:
					errors.append(
						"movement_grid.ground_effects[%d] must be an object"
						% index
					)
					continue
				var effect_record := effect_value as Dictionary
				if not _serialized_vector_is_valid(effect_record, "cell", 2):
					errors.append(
						"movement_grid.ground_effects[%d] has no [x,z] cell"
						% index
					)
					continue
				var effect_cell: Array = effect_record["cell"]
				var effect_key := "%d,%d" % [
					int(effect_cell[0]),
					int(effect_cell[1]),
				]
				if seen_effects.has(effect_key):
					errors.append(
						"movement_grid.ground_effects duplicates %s"
						% effect_key
					)
				seen_effects[effect_key] = true
				var effect_label_value: Variant = effect_record.get("label", null)
				if (
					not effect_label_value is String
					or String(effect_label_value).strip_edges().is_empty()
				):
					errors.append(
						"movement_grid.ground_effects[%d] needs a label"
						% index
					)
				elif (
					String(effect_label_value).strip_edges().length()
					> MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH
				):
					errors.append(
						"movement_grid.ground_effects[%d] label exceeds %d characters"
						% [index, MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH]
					)

	for profile_name: String in ["material_blend", "aesthetics", "lighting"]:
		if data.has(profile_name) and not (data[profile_name] is Dictionary):
			errors.append("'%s' must be an object" % profile_name)
	return errors


## Report any authored-array count changed by serialization before the staged write begins.
func _serialized_count_errors(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var expected_counts := {
		"surfaces": surfaces.size(),
		"props": props.size(),
		"enemy_packs": enemy_packs.size(),
		"gameplay_markers": gameplay_markers.size(),
		"particle_effects": particle_effects.size(),
		"monster_visuals": monster_visual_assets.size(),
	}
	for array_name: String in expected_counts:
		var records_value: Variant = data.get(array_name, null)
		var actual_count := (records_value as Array).size() if records_value is Array else -1
		var expected_count := int(expected_counts[array_name])
		if actual_count != expected_count:
			errors.append(
				"'%s' serialized %d records but the board owns %d"
				% [array_name, actual_count, expected_count]
			)
	return errors


## Replace the document from structurally valid saved JSON.
##
## Validation occurs before clear(), so malformed data can never erase the
## currently valid in-memory board.
func from_json(data: Dictionary) -> Error:
	return _replace_from_json(data, true)


## Replace this document from parsed JSON with optional final notifications.
##
## Validation precedes every mutation, and detached candidates disable signals so
## no UI or viewport work occurs while a selected board is still being prepared.
func _replace_from_json(data: Dictionary, notify_change: bool) -> Error:
	var persistence_errors := serialized_data_errors(data)
	if not persistence_errors.is_empty():
		push_error(
			"BoardDocument: refusing invalid board data; live board preserved: %s"
			% "; ".join(persistence_errors)
		)
		return ERR_INVALID_DATA
	_clear_state()
	var loaded_version := int(data.get("version", 1))
	version = loaded_version
	board_name = String(data.get("name", "Untitled Board"))
	biome = String(data.get("biome", ""))
	var movement_value: Variant = data.get("movement_grid", {})
	if movement_value is Dictionary:
		var movement_data := movement_value as Dictionary
		movement_collision_min_triangle_share_percent = float(
			movement_data.get("collision_min_triangle_share_percent", 0.0)
		)
		for cell_value: Variant in movement_data.get("unwalkable_cells", []):
			var cell_array := cell_value as Array
			var cell := Vector2i(int(cell_array[0]), int(cell_array[1]))
			movement_unwalkable_cells[movement_cell_key(cell)] = true
		for effect_value: Variant in movement_data.get("ground_effects", []):
			var effect_record := effect_value as Dictionary
			var effect_cell_array := effect_record["cell"] as Array
			var effect_cell := Vector2i(
				int(effect_cell_array[0]),
				int(effect_cell_array[1])
			)
			movement_ground_effects[movement_cell_key(effect_cell)] = (
				String(effect_record["label"]).strip_edges()
			)
	var paint_value: Variant = data.get("surface_material_paint", {})
	if paint_value is Dictionary:
		surface_material_paint = (paint_value as Dictionary).duplicate(true)
	var material_blend_value: Variant = data.get("material_blend", {})
	material_blend.from_json(
		material_blend_value if material_blend_value is Dictionary else {}
	)

	for entry: Variant in data.get("surfaces", []):
		if entry is Dictionary:
			surfaces.append(SurfacePlacement.from_json(entry))
	for entry: Variant in data.get("props", []):
		if entry is Dictionary:
			props.append(PropPlacement.from_json(entry))
	var enemy_pack_script: Script = load(
		"res://addons/modular_tile_studio/data/enemy_pack.gd"
	)
	for entry: Variant in data.get("enemy_packs", []):
		if entry is Dictionary:
			enemy_packs.append(enemy_pack_script.from_json(entry) as EnemyPack)
	var gameplay_marker_script: Script = load(
		"res://addons/modular_tile_studio/data/gameplay_marker.gd"
	)
	for entry: Variant in data.get("gameplay_markers", []):
		if entry is Dictionary:
			gameplay_markers.append(
				gameplay_marker_script.from_json(entry) as GameplayMarker
			)
	var particle_placement_script: Script = load(
		"res://addons/modular_tile_studio/data/particle_effect_placement.gd"
	)
	for entry: Variant in data.get("particle_effects", []):
		if entry is Dictionary:
			var effect := particle_placement_script.new() as ParticleEffectPlacement
			if effect.load_json(entry):
				particle_effects.append(effect)
	for entry: Variant in data.get("monster_visuals", []):
		if not (entry is Dictionary):
			push_error("BoardDocument: monster_visuals entries must be objects")
			continue
		var visual_data: Dictionary = entry
		if not (visual_data.get("monster", null) is String):
			push_error("BoardDocument: monster visual monster must be a string")
			continue
		if not (visual_data.get("asset", null) is String):
			push_error("BoardDocument: monster visual asset must be a string")
			continue
		monster_visual_assets[visual_data["monster"]] = visual_data["asset"]
	for entry: Variant in data.get("imported_assets", []):
		# Ids are recorded, never resolved here: an import whose asset has since been
		# deleted must load quietly and disappear from the level view rather than
		# fail a board that is otherwise intact.
		imported_asset_ids.append(String(entry))

	# A board saved before the tactical terrain rework simply has no footprint
	# drawn yet. That is a valid empty encounter surface, not a missing file.
	var terrain_data: Variant = data.get("terrain", null)
	if terrain_data is Dictionary:
		terrain = TerrainMesh.from_json(terrain_data)
		var terrain_errors := terrain.validate_definition()
		if not terrain_errors.is_empty():
			for terrain_error: String in terrain_errors:
				push_error("BoardDocument: terrain %s" % terrain_error)
			return ERR_INVALID_DATA
	else:
		terrain = TerrainMesh.new()
	var aesthetics_data: Variant = data.get("aesthetics", {})
	aesthetics.from_json(aesthetics_data if aesthetics_data is Dictionary else {})
	var lighting_data: Variant = data.get("lighting", {})
	lighting.from_json(lighting_data if lighting_data is Dictionary else {})

	version = FORMAT_VERSION
	rebuild_indexes()
	if notify_change:
		board_changed.emit()
		look_changed.emit()
	return OK


## Parse and validate one ordinary board into detached state without touching the live document.
func prepare_json(data: Dictionary) -> Dictionary:
	var candidate := BoardDocument.new()
	candidate._library = _library
	var load_error := candidate._replace_from_json(data, false)
	if load_error != OK:
		return {
			"error": load_error,
			"board": null,
			"report": {},
		}
	return {
		"error": OK,
		"board": candidate,
		"report": candidate.validate_all(),
	}


## Adopt one detached, fully prepared board without repeating parsing or validation.
##
## Parsing and validation already happened on the detached candidate, so only the
## derived indexes are rebuilt here -- from the canonical records this adopts.
##
## The caller commits prepared renderer state next, performs one viewport rebuild,
## and only then calls announce_loaded_state() to expose the replacement.
func commit_prepared_load(source: BoardDocument) -> bool:
	if source == null:
		push_error("BoardDocument: cannot commit a null prepared board.")
		return false
	if source._library != _library:
		push_error("BoardDocument: prepared board belongs to a different asset library.")
		return false

	version = source.version
	board_name = source.board_name
	biome = source.biome
	surfaces = source.surfaces
	props = source.props
	enemy_packs = source.enemy_packs
	gameplay_markers = source.gameplay_markers
	particle_effects = source.particle_effects
	monster_visual_assets = source.monster_visual_assets
	imported_asset_ids = source.imported_asset_ids
	terrain = source.terrain
	movement_collision_min_triangle_share_percent = (
		source.movement_collision_min_triangle_share_percent
	)
	movement_unwalkable_cells = source.movement_unwalkable_cells
	movement_ground_effects = source.movement_ground_effects
	surface_material_paint = source.surface_material_paint
	material_blend = source.material_blend
	aesthetics = source.aesthetics
	lighting = source.lighting

	# Derive every index from the canonical records just adopted instead of copying
	# them across one field at a time. The enumerated copy this replaces silently
	# omitted _shader_decal_uid_index when that index was introduced, so every shader
	# decal loaded from disk resolved to no face and rendered as bare terrain, while
	# decals placed by hand -- indexed incrementally on add -- kept working. Rebuilding
	# is proportional to the placement count and cannot fall behind a new index the
	# way an enumerated copy can.
	rebuild_indexes()
	return true


## Announce one completed board replacement after every live derivative is ready.
func announce_loaded_state(include_look: bool = true) -> void:
	board_changed.emit()
	if include_look:
		look_changed.emit()

## Read one board JSON object for staged verification or an explicit load.
static func _read_board_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": ERR_FILE_NOT_FOUND, "data": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": FileAccess.get_open_error(), "data": {}}
	var text := file.get_as_text()
	var read_error := file.get_error()
	file.close()
	if read_error != OK:
		return {"error": read_error, "data": {}}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"error": ERR_PARSE_ERROR, "data": {}}
	return {"error": OK, "data": parsed}


## Return a unique timestamped backup path beside the board being replaced.
static func _next_backup_path(path: String) -> String:
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var base_path := "%s%s%s" % [path, SAVE_BACKUP_SUFFIX, timestamp]
	var candidate := base_path
	var suffix: int = 2
	while FileAccess.file_exists(candidate):
		candidate = "%s-%d" % [base_path, suffix]
		suffix += 1
	return candidate


## Remove one exact staging file after a failed save attempt.
static func _remove_staging_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if remove_error != OK:
		push_error(
			"BoardDocument: could not remove staging file '%s' (%s)"
			% [path, error_string(remove_error)]
		)


## Commit one verified staging file while retaining the previous board as a backup.
##
## The old file is moved first and restored if the final rename fails, so there
## is never a point where a failed commit silently destroys the last valid board.
static func _commit_staged_board(staging_path: String, target_path: String) -> Error:
	var staging_absolute := ProjectSettings.globalize_path(staging_path)
	var target_absolute := ProjectSettings.globalize_path(target_path)
	var backup_path := ""
	if FileAccess.file_exists(target_path):
		backup_path = _next_backup_path(target_path)
		var backup_error := DirAccess.rename_absolute(
			target_absolute,
			ProjectSettings.globalize_path(backup_path)
		)
		if backup_error != OK:
			_remove_staging_file(staging_path)
			push_error(
				"BoardDocument: cannot preserve '%s' before saving (%s)"
				% [target_path, error_string(backup_error)]
			)
			return backup_error

	var commit_error := DirAccess.rename_absolute(staging_absolute, target_absolute)
	if commit_error == OK:
		if not backup_path.is_empty():
			print("[Tile Studio] Previous board preserved at %s" % backup_path)
		return OK

	if not backup_path.is_empty():
		var restore_error := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(backup_path),
			target_absolute
		)
		if restore_error != OK:
			push_error(
				"BoardDocument: commit failed and previous board remains at '%s' (%s)"
				% [backup_path, error_string(restore_error)]
			)
	_remove_staging_file(staging_path)
	push_error(
		"BoardDocument: cannot commit staged save '%s' (%s)"
		% [target_path, error_string(commit_error)]
	)
	return commit_error


## Save validated portable board JSON through a verified atomic staging file.
func save_json(path: String) -> Error:
	var data := to_json()
	var persistence_errors := serialized_data_errors(data)
	persistence_errors.append_array(_serialized_count_errors(data))
	if not persistence_errors.is_empty():
		push_error(
			"BoardDocument: refusing destructive save to '%s'; existing file preserved: %s"
			% [path, "; ".join(persistence_errors)]
		)
		return ERR_INVALID_DATA

	var staging_path := "%s%s%d" % [path, SAVE_STAGING_SUFFIX, Time.get_ticks_usec()]
	var file := FileAccess.open(staging_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error(
			"BoardDocument: cannot stage '%s' (%s)" % [path, error_string(open_error)]
		)
		return open_error
	file.store_string(JSON.stringify(data, "	"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_remove_staging_file(staging_path)
		push_error(
			"BoardDocument: cannot finish staged save '%s' (%s)"
			% [path, error_string(write_error)]
		)
		return write_error

	var staged_result := _read_board_json(staging_path)
	var staged_error := int(staged_result.get("error", FAILED))
	if staged_error != OK:
		_remove_staging_file(staging_path)
		push_error(
			"BoardDocument: staged save for '%s' could not be read back (%s)"
			% [path, error_string(staged_error)]
		)
		return staged_error
	var staged_data: Dictionary = staged_result.get("data", {})
	var staged_errors := serialized_data_errors(staged_data)
	if not staged_errors.is_empty():
		_remove_staging_file(staging_path)
		push_error(
			"BoardDocument: staged save verification failed for '%s'; existing file preserved"
			% path
		)
		return ERR_INVALID_DATA
	return _commit_staged_board(staging_path, path)


## Load one fully valid board JSON object without mutating this document on failure.
func load_json(path: String) -> Error:
	var read_result := _read_board_json(path)
	var read_error := int(read_result.get("error", FAILED))
	if read_error != OK:
		push_error(
			"BoardDocument: cannot load '%s' (%s); live board preserved"
			% [path, error_string(read_error)]
		)
		return read_error
	var parsed: Dictionary = read_result.get("data", {})
	var load_error := from_json(parsed)
	if load_error != OK:
		push_error("BoardDocument: '%s' was rejected; live board preserved" % path)
	return load_error
