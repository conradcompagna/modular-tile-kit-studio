@tool
class_name BoardDocument
extends Resource

const BindingFeature := preload("board/binding.gd")
const MovementFeature := preload("board/movement.gd")
const GameplayFeature := preload("board/gameplay.gd")
const AssetReferencesFeature := preload("board/asset_references.gd")
const TerrainPaintFeature := preload("board/terrain_paint.gd")
const PropSpatialFeature := preload("board/prop_spatial.gd")
const SpatialIndexesFeature := preload("board/spatial_indexes.gd")
const SurfaceIndexesFeature := preload("board/surface_indexes.gd")
const ValidationFeature := preload("board/validation.gd")
const MutationsFeature := preload("board/mutations.gd")
const LifecycleFeature := preload("board/lifecycle.gd")
const SerializationFeature := preload("board/serialization.gd")
const SerializedValidationFeature := preload("board/serialized_validation.gd")
const FileIoFeature := preload("board/file_io.gd")

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


func bind_library(library: AssetLibrary) -> void:
	BindingFeature.bind_library(self, library)


static func movement_cell_key(cell: Vector2i) -> String:
	return MovementFeature.movement_cell_key(cell)


static func movement_cell_from_key(key: String) -> Variant:
	return MovementFeature.movement_cell_from_key(key)


func movement_cell_exists(cell: Vector2i) -> bool:
	return MovementFeature.movement_cell_exists(self, cell)


func movement_cell_is_unwalkable(cell: Vector2i) -> bool:
	return MovementFeature.movement_cell_is_unwalkable(self, cell)


func movement_ground_effect(cell: Vector2i) -> String:
	return MovementFeature.movement_ground_effect(self, cell)


func movement_cell_state(cell: Vector2i) -> Dictionary:
	return MovementFeature.movement_cell_state(self, cell)


func apply_movement_cell_state(
	cell: Vector2i,
	state: Dictionary,
	notify_change: bool = true
) -> bool:
	return MovementFeature.apply_movement_cell_state(self, cell, state, notify_change)


func set_movement_cell_unwalkable(cell: Vector2i, unwalkable: bool) -> bool:
	return MovementFeature.set_movement_cell_unwalkable(self, cell, unwalkable)


func set_movement_ground_effect(cell: Vector2i, label: String) -> bool:
	return MovementFeature.set_movement_ground_effect(self, cell, label)


func _sorted_movement_cells(source: Dictionary) -> Array[Vector2i]:
	return MovementFeature._sorted_movement_cells(self, source)


func movement_ground_effect_snapshot() -> Dictionary:
	return MovementFeature.movement_ground_effect_snapshot(self)


func prune_movement_grid_cells() -> int:
	return MovementFeature.prune_movement_grid_cells(self)


func movement_collision_filter_report(
	threshold_percent: float = -1.0
) -> Dictionary:
	return MovementFeature.movement_collision_filter_report(self, threshold_percent)


func set_movement_collision_min_triangle_share_percent(
	threshold_percent: float
) -> Dictionary:
	return MovementFeature.set_movement_collision_min_triangle_share_percent(self, threshold_percent)


func rebuild_gameplay_indexes() -> void:
	GameplayFeature.rebuild_gameplay_indexes(self)


func get_enemy_pack(pack_id: String) -> EnemyPack:
	return GameplayFeature.get_enemy_pack(self, pack_id)


func get_gameplay_marker(marker_id: String) -> GameplayMarker:
	return GameplayFeature.get_gameplay_marker(self, marker_id)


func gameplay_marker_at(origin: Vector3i) -> GameplayMarker:
	return GameplayFeature.gameplay_marker_at(self, origin)


func get_particle_effect(placement_id: String) -> ParticleEffectPlacement:
	return GameplayFeature.get_particle_effect(self, placement_id)


func particle_effect_near(position: Vector3, radius: float = 0.75) -> ParticleEffectPlacement:
	return GameplayFeature.particle_effect_near(self, position, radius)


func add_particle_effect(placement: ParticleEffectPlacement) -> bool:
	return GameplayFeature.add_particle_effect(self, placement)


func remove_particle_effect(placement: ParticleEffectPlacement) -> bool:
	return GameplayFeature.remove_particle_effect(self, placement)


func monster_visual_asset_id(monster_id: String) -> String:
	return GameplayFeature.monster_visual_asset_id(self, monster_id)


func known_monster_ids() -> PackedStringArray:
	return GameplayFeature.known_monster_ids(self)


func note_imported_asset(asset_id: String) -> void:
	AssetReferencesFeature.note_imported_asset(self, asset_id)


func forget_imported_asset(asset_id: String) -> void:
	AssetReferencesFeature.forget_imported_asset(self, asset_id)


func used_asset_ids(
	active_material_palette_indices: PackedInt32Array = PackedInt32Array()
) -> PackedStringArray:
	return AssetReferencesFeature.used_asset_ids(self, active_material_palette_indices)


func validate_monster_visual_assignment(
	monster_id: String,
	asset_id: String
) -> Dictionary:
	return AssetReferencesFeature.validate_monster_visual_assignment(self, monster_id, asset_id)


func set_monster_visual_asset(monster_id: String, asset_id: String) -> Dictionary:
	return AssetReferencesFeature.set_monster_visual_asset(self, monster_id, asset_id)


func clear_monster_visual_asset(monster_id: String) -> Dictionary:
	return AssetReferencesFeature.clear_monster_visual_asset(self, monster_id)


func resolve_monster_visual_asset(monster_id: String) -> TileAsset:
	return AssetReferencesFeature.resolve_monster_visual_asset(self, monster_id)


func enemy_pack_member_count(pack_id: String) -> int:
	return GameplayFeature.enemy_pack_member_count(self, pack_id)


func next_gameplay_marker_id(marker_type: String) -> String:
	return GameplayFeature.next_gameplay_marker_id(self, marker_type)


func validate_enemy_pack(pack: EnemyPack, ignore: EnemyPack = null) -> Dictionary:
	return GameplayFeature.validate_enemy_pack(self, pack, ignore)


func add_enemy_pack(pack: EnemyPack) -> Dictionary:
	return GameplayFeature.add_enemy_pack(self, pack)


func update_enemy_pack(pack_id: String, note: String) -> Dictionary:
	return GameplayFeature.update_enemy_pack(self, pack_id, note)


func remove_enemy_pack(pack_id: String) -> Dictionary:
	return GameplayFeature.remove_enemy_pack(self, pack_id)


func validate_gameplay_marker(
	marker: GameplayMarker,
	ignore: GameplayMarker = null
) -> Dictionary:
	return GameplayFeature.validate_gameplay_marker(self, marker, ignore)


func add_gameplay_marker(marker: GameplayMarker) -> Dictionary:
	return GameplayFeature.add_gameplay_marker(self, marker)


func update_gameplay_marker(
	marker_id: String,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> Dictionary:
	return GameplayFeature.update_gameplay_marker(self, marker_id, marker_type, note, monster_id, pack_id)


func assign_enemy_markers_to_pack(
	marker_ids: PackedStringArray,
	pack_id: String
) -> Dictionary:
	return GameplayFeature.assign_enemy_markers_to_pack(self, marker_ids, pack_id)


func remove_gameplay_marker(marker: GameplayMarker) -> void:
	GameplayFeature.remove_gameplay_marker(self, marker)


func resolve_asset(asset_id: String) -> TileAsset:
	return AssetReferencesFeature.resolve_asset(self, asset_id)


func resolve_surface_asset(placement: SurfacePlacement) -> TileAsset:
	return AssetReferencesFeature.resolve_surface_asset(self, placement)


func resolve_prop_asset(placement: PropPlacement) -> TileAsset:
	return AssetReferencesFeature.resolve_prop_asset(self, placement)


func surface_paint_uids(placement: SurfacePlacement) -> PackedStringArray:
	return TerrainPaintFeature.surface_paint_uids(self, placement)


static func _terrain_face_uid_is_in_cells(uid: String, cells: Rect2i) -> bool:
	return TerrainPaintFeature._terrain_face_uid_is_in_cells(uid, cells)


func prune_orphaned_terrain_paint(
	affected_cells: Rect2i = Rect2i()
) -> PackedStringArray:
	return TerrainPaintFeature.prune_orphaned_terrain_paint(self, affected_cells)


func prune_terrain_paint_uids(
	candidate_uids: PackedStringArray
) -> PackedStringArray:
	return TerrainPaintFeature.prune_terrain_paint_uids(self, candidate_uids)


func prop_world_origin(placement: PropPlacement) -> Vector3:
	return PropSpatialFeature.prop_world_origin(self, placement)


func prop_local_voxels(placement: PropPlacement) -> Array[Vector3i]:
	return PropSpatialFeature.prop_local_voxels(self, placement)


func prop_world_voxel_boxes(placement: PropPlacement) -> Array[AABB]:
	return PropSpatialFeature.prop_world_voxel_boxes(self, placement)


func prop_occupied_cells(placement: PropPlacement) -> Array[Vector3i]:
	return PropSpatialFeature.prop_occupied_cells(self, placement)


func prop_solid_keys(placement: PropPlacement) -> PackedStringArray:
	return PropSpatialFeature.prop_solid_keys(self, placement)


func _index_prop_footprint(placement: PropPlacement) -> void:
	PropSpatialFeature._index_prop_footprint(self, placement)


func _unindex_prop_footprint(placement: PropPlacement) -> void:
	PropSpatialFeature._unindex_prop_footprint(self, placement)


func props_touching_terrain_regions(
	regions: Array[Rect2i]
) -> Array[PropPlacement]:
	return PropSpatialFeature.props_touching_terrain_regions(self, regions)


func capture_prop_support_state(regions: Array[Rect2i]) -> Dictionary:
	return PropSpatialFeature.capture_prop_support_state(self, regions)


func reconcile_prop_support_state(snapshot: Dictionary) -> Array[PropPlacement]:
	return PropSpatialFeature.reconcile_prop_support_state(self, snapshot)


func rebuild_indexes() -> void:
	SpatialIndexesFeature.rebuild_indexes(self)

func _placement_belongs_to_board(placement: Resource) -> bool:
	return SpatialIndexesFeature._placement_belongs_to_board(self, placement)


func _spatial_state_is_valid(placement: Resource, state: Dictionary) -> bool:
	return SpatialIndexesFeature._spatial_state_is_valid(self, placement, state)


func _unindex_spatial_placement(placement: Resource) -> void:
	SpatialIndexesFeature._unindex_spatial_placement(self, placement)

func _apply_spatial_state(placement: Resource, state: Dictionary) -> void:
	SpatialIndexesFeature._apply_spatial_state(self, placement, state)


func _index_spatial_placement(placement: Resource) -> void:
	SpatialIndexesFeature._index_spatial_placement(self, placement)

func apply_placement_spatial_states(
	targets: Array[Resource],
	states: Array[Dictionary]
) -> bool:
	return SpatialIndexesFeature.apply_placement_spatial_states(self, targets, states)


func surface_at_paint_uid(paint_uid: String) -> SurfacePlacement:
	return SurfaceIndexesFeature.surface_at_paint_uid(self, paint_uid)


func shader_decals_at_paint_uid(paint_uid: String) -> Array[SurfacePlacement]:
	return SurfaceIndexesFeature.shader_decals_at_paint_uid(self, paint_uid)


func has_shader_decals() -> bool:
	return SurfaceIndexesFeature.has_shader_decals(self)


func _index_shader_decal(placement: SurfacePlacement) -> void:
	SurfaceIndexesFeature._index_shader_decal(self, placement)


func _unindex_shader_decal(placement: SurfacePlacement) -> void:
	SurfaceIndexesFeature._unindex_shader_decal(self, placement)


func solid_placement_at(cell: Vector3i) -> Resource:
	return SurfaceIndexesFeature.solid_placement_at(self, cell)


func prop_at(cell: Vector3i) -> PropPlacement:
	return SurfaceIndexesFeature.prop_at(self, cell)


func surface_conflicting_placements(
	placement: SurfacePlacement
) -> Array[SurfacePlacement]:
	return ValidationFeature.surface_conflicting_placements(self, placement)


func prop_conflicting_placements(
	placement: PropPlacement
) -> Array[PropPlacement]:
	return ValidationFeature.prop_conflicting_placements(self, placement)


func validate_surface(
	placement: SurfacePlacement,
	ignore: SurfacePlacement = null
) -> Dictionary:
	return ValidationFeature.validate_surface(self, placement, ignore)


func validate_prop(
	placement: PropPlacement,
	ignore: PropPlacement = null
) -> Dictionary:
	return ValidationFeature.validate_prop(self, placement, ignore)


func prop_terrain_support_height(
	placement: PropPlacement,
	support_terrain: TerrainMesh = null
) -> float:
	return ValidationFeature.prop_terrain_support_height(self, placement, support_terrain)


func renderable_surfaces() -> Array[SurfacePlacement]:
	return ValidationFeature.renderable_surfaces(self)


func _validate_surface_reference(placement: SurfacePlacement) -> String:
	return ValidationFeature._validate_surface_reference(self, placement)


func _validate_prop_reference(placement: PropPlacement) -> String:
	return ValidationFeature._validate_prop_reference(self, placement)


func validate_all() -> Dictionary:
	return ValidationFeature.validate_all(self)


func add_surface(placement: SurfacePlacement) -> void:
	MutationsFeature.add_surface(self, placement)


func remove_surface(placement: SurfacePlacement) -> void:
	MutationsFeature.remove_surface(self, placement)


func add_surfaces_bulk(placements: Array[SurfacePlacement]) -> void:
	MutationsFeature.add_surfaces_bulk(self, placements)


func remove_surfaces_bulk(placements: Array[SurfacePlacement]) -> void:
	MutationsFeature.remove_surfaces_bulk(self, placements)


func replace_surfaces_bulk(
	displaced: Array[SurfacePlacement],
	replacements: Array[SurfacePlacement]
) -> void:
	MutationsFeature.replace_surfaces_bulk(self, displaced, replacements)


func add_prop(placement: PropPlacement) -> void:
	MutationsFeature.add_prop(self, placement)


func remove_prop(placement: PropPlacement) -> void:
	MutationsFeature.remove_prop(self, placement)


func add_props_bulk(placements: Array[PropPlacement]) -> void:
	MutationsFeature.add_props_bulk(self, placements)


func remove_props_bulk(placements: Array[PropPlacement]) -> void:
	MutationsFeature.remove_props_bulk(self, placements)


func replace_props_bulk(
	displaced: Array[PropPlacement],
	replacements: Array[PropPlacement]
) -> void:
	MutationsFeature.replace_props_bulk(self, displaced, replacements)


func clear() -> void:
	LifecycleFeature.clear(self)


func _clear_state() -> void:
	LifecycleFeature._clear_state(self)


func notify_look_changed() -> void:
	LifecycleFeature.notify_look_changed(self)


func reset_aesthetics() -> void:
	LifecycleFeature.reset_aesthetics(self)


func reset_lighting() -> void:
	LifecycleFeature.reset_lighting(self)


func reset_look() -> void:
	LifecycleFeature.reset_look(self)


func is_empty() -> bool:
	return LifecycleFeature.is_empty(self)


func notify_terrain_changed() -> void:
	LifecycleFeature.notify_terrain_changed(self)


func gameplay_grid() -> Array[Dictionary]:
	return LifecycleFeature.gameplay_grid(self)


func compute_bounds() -> AABB:
	return LifecycleFeature.compute_bounds(self)


func movement_grid_to_json() -> Dictionary:
	return SerializationFeature.movement_grid_to_json(self)


func to_json() -> Dictionary:
	return SerializationFeature.to_json(self)


static func _serialized_string_is_present(record: Dictionary, field: String) -> bool:
	return SerializedValidationFeature._serialized_string_is_present(record, field)


static func _serialized_vector_is_valid(
	record: Dictionary,
	field: String,
	component_count: int
) -> bool:
	return SerializedValidationFeature._serialized_vector_is_valid(record, field, component_count)


static func serialized_data_errors(data: Dictionary) -> PackedStringArray:
	return SerializedValidationFeature.serialized_data_errors(data)


func _serialized_count_errors(data: Dictionary) -> PackedStringArray:
	return SerializationFeature._serialized_count_errors(self, data)


func from_json(data: Dictionary) -> Error:
	return SerializationFeature.from_json(self, data)


func _replace_from_json(data: Dictionary, notify_change: bool) -> Error:
	return SerializationFeature._replace_from_json(self, data, notify_change)


func prepare_json(data: Dictionary) -> Dictionary:
	return SerializationFeature.prepare_json(self, data)


func commit_prepared_load(source: BoardDocument) -> bool:
	return SerializationFeature.commit_prepared_load(self, source)


func announce_loaded_state(include_look: bool = true) -> void:
	SerializationFeature.announce_loaded_state(self, include_look)

static func _read_board_json(path: String) -> Dictionary:
	return FileIoFeature._read_board_json(path)


static func _next_backup_path(path: String) -> String:
	return FileIoFeature._next_backup_path(path)


static func _remove_staging_file(path: String) -> void:
	FileIoFeature._remove_staging_file(path)


static func _commit_staged_board(staging_path: String, target_path: String) -> Error:
	return FileIoFeature._commit_staged_board(staging_path, target_path)


func save_json(path: String) -> Error:
	return FileIoFeature.save_json(self, path)


func load_json(path: String) -> Error:
	return FileIoFeature.load_json(self, path)
