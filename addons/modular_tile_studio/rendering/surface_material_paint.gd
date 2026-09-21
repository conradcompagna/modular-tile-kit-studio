@tool
class_name MTSSurfaceMaterialPaint
extends RefCounted

const PaletteFeature := preload("paint/palette.gd")
const ImagesFeature := preload("paint/images.gd")
const ClearFeature := preload("paint/clear.gd")
const BatchesFeature := preload("paint/batches.gd")
const SnapshotsFeature := preload("paint/snapshots.gd")
const SplatmapFeature := preload("paint/splatmap.gd")
const StrokesFeature := preload("paint/strokes.gd")
const BrushFeature := preload("paint/brush.gd")
const SidecarsFeature := preload("paint/sidecars.gd")
const ColorMathFeature := preload("paint/color_math.gd")

## Owns sparse, face-local RGBA material weights for the regular heightfield.
##
## One Image per painted terrain face is canonical. Derived terrain MultiMesh batches bind
## Texture2DArray layers so ImageTextureLayered.update_layer() uploads only the touched face
## without rebuilding heightfield geometry, seam corrections, collisions, or unrelated props.

signal batch_texture_changed(batch_key: String)
signal paint_changed(placement_uid: String)
## Emitted only when a face changes which palette entries its four RGBA weights represent.
signal palette_slots_changed(placement_uid: String)
## Emitted once after an operation can change which palette assets visibly affect the board.
signal palette_usage_changed()

## Version 3 adds one quarter-turn orientation for each face-local material slot.
const METADATA_VERSION: int = 3
## Values no brighter than four 8-bit steps are treated as black encoding noise.
const SPLATMAP_EMPTY_COMPONENT_THRESHOLD: float = 4.0 / 255.0
## No authored component survives the encoding-noise threshold on a base-only face.
const CONTROL_CLASS_BASE_ONLY: int = 0
## Every texel on a uniform face is fully owned by one identical RGBA slot.
const CONTROL_CLASS_UNIFORM_LAYER: int = 1
## A mixed face requires its canonical control image at fragment time.
const CONTROL_CLASS_MIXED: int = 2

var profile: MaterialBlendProfile = null

var _images_by_uid: Dictionary = {}
## Terrain face UID -> four palette indices carried by that face's RGBA components.
var _palette_slots_by_uid: Dictionary = {}
## Terrain face UID -> four clockwise PNG quarter-turns matching the local RGBA slots.
var _slot_rotations_by_uid: Dictionary = {}
var _batch_records: Dictionary = {}
var _batch_key_by_uid: Dictionary = {}
var _dirty_uids: Dictionary = {}

var _stroke_active: bool = false
var _stroke_before: Dictionary = {}
## Face-local slot assignments changed by the current stroke, captured for exact undo.
var _stroke_slots_before: Dictionary = {}
## Face-local PNG orientations changed by the current stroke, captured for exact undo.
var _stroke_rotations_before: Dictionary = {}
var _stroke_max_weights: Dictionary = {}


func bind_profile(value: MaterialBlendProfile) -> void:
	PaletteFeature.bind_profile(self, value)


func palette_slots_for_uid(placement_uid: String) -> PackedInt32Array:
	return PaletteFeature.palette_slots_for_uid(self, placement_uid)


func slot_rotations_for_uid(placement_uid: String) -> PackedInt32Array:
	return PaletteFeature.slot_rotations_for_uid(self, placement_uid)


func used_palette_indices() -> PackedInt32Array:
	return PaletteFeature.used_palette_indices(self)


func used_palette_indices_for_profile(
	candidate_profile: MaterialBlendProfile
) -> PackedInt32Array:
	return PaletteFeature.used_palette_indices_for_profile(self, candidate_profile)


func _default_palette_slots() -> PackedInt32Array:
	return PaletteFeature._default_palette_slots(self)


func _ensure_palette_slots(placement_uid: String) -> PackedInt32Array:
	return PaletteFeature._ensure_palette_slots(self, placement_uid)


func _set_slot_rotations(
	placement_uid: String,
	rotations: PackedInt32Array,
	record_stroke: bool = true
) -> bool:
	return PaletteFeature._set_slot_rotations(self, placement_uid, rotations, record_stroke)


func _set_slot_rotation(
	placement_uid: String,
	slot_index: int,
	rotation_quarters: int,
	record_stroke: bool = true
) -> bool:
	return PaletteFeature._set_slot_rotation(self, placement_uid, slot_index, rotation_quarters, record_stroke)


func register_face_palette(
	placement_uid: String,
	seed_uid: String = ""
) -> PackedInt32Array:
	return PaletteFeature.register_face_palette(self, placement_uid, seed_uid)


func palette_slots_key(placement_uid: String) -> String:
	return PaletteFeature.palette_slots_key(self, placement_uid)


func weight_slot_for_palette(placement_uid: String, palette_index: int) -> int:
	return PaletteFeature.weight_slot_for_palette(self, placement_uid, palette_index)


func _slot_has_weight(placement_uid: String, slot_index: int) -> bool:
	return PaletteFeature._slot_has_weight(self, placement_uid, slot_index)


func _available_palette_slot(
	placement_uid: String,
	slots: PackedInt32Array
) -> int:
	return PaletteFeature._available_palette_slot(self, placement_uid, slots)


func _set_palette_slots(
	placement_uid: String,
	slots: PackedInt32Array,
	record_stroke: bool = true
) -> bool:
	return PaletteFeature._set_palette_slots(self, placement_uid, slots, record_stroke)


func _ensure_palette_slot(
	placement_uid: String,
	palette_index: int,
	allow_allocate: bool
) -> int:
	return PaletteFeature._ensure_palette_slot(self, placement_uid, palette_index, allow_allocate)


func assign_palette_to_faces(
	palette_index: int,
	placement_uids: PackedStringArray
) -> Dictionary:
	return PaletteFeature.assign_palette_to_faces(self, palette_index, placement_uids)


func set_splatmap_palette_slots(
	placement_uid: String,
	slots: PackedInt32Array
) -> bool:
	return PaletteFeature.set_splatmap_palette_slots(self, placement_uid, slots)


func neutral_texture() -> Texture2DArray:
	return ImagesFeature.neutral_texture(self)


var _neutral_texture: Texture2DArray = null


func clear_all_paint() -> Dictionary:
	return ClearFeature.clear_all_paint(self)


func clear_palette_material(palette_index: int) -> Dictionary:
	return ClearFeature.clear_palette_material(self, palette_index)


func _build_clear_patches(channel: int) -> Dictionary:
	return ClearFeature._build_clear_patches(self, channel)


func _build_palette_clear_patches(palette_index: int) -> Dictionary:
	return ClearFeature._build_palette_clear_patches(self, palette_index)


func _image_has_weight(image: Image) -> bool:
	return ClearFeature._image_has_weight(self, image)


func discard_paint_for_uids(uids: PackedStringArray) -> void:
	ImagesFeature.discard_paint_for_uids(self, uids)


func register_batch(
	batch_key: String,
	face_uids: PackedStringArray,
	footprint_m: Vector2i,
	seed_uid_by_uid: Dictionary = {}
) -> void:
	BatchesFeature.register_batch(self, batch_key, face_uids, footprint_m, seed_uid_by_uid)


func unregister_batch(batch_key: String) -> void:
	BatchesFeature.unregister_batch(self, batch_key)


func batch_texture(batch_key: String) -> Texture2DArray:
	return BatchesFeature.batch_texture(self, batch_key)


func control_classification_for_uid(placement_uid: String) -> Vector2i:
	return BatchesFeature.control_classification_for_uid(self, placement_uid)


func instance_layer_color(batch_key: String, placement_uid: String) -> Color:
	return BatchesFeature.instance_layer_color(self, batch_key, placement_uid)


func bind_batch_instance_colors(
	batch_key: String,
	multimesh: MultiMesh,
	instance_indices_by_uid: Dictionary
) -> void:
	BatchesFeature.bind_batch_instance_colors(self, batch_key, multimesh, instance_indices_by_uid)


func has_any_paint() -> bool:
	return SnapshotsFeature.has_any_paint(self)


func paint_memory_bytes(target_profile: MaterialBlendProfile = null) -> Dictionary:
	return SnapshotsFeature.paint_memory_bytes(self, target_profile)


func capture_png_snapshot() -> Dictionary:
	return SnapshotsFeature.capture_png_snapshot(self)


func capture_prepared_png_snapshot(prepared: Dictionary) -> Dictionary:
	return SnapshotsFeature.capture_prepared_png_snapshot(self, prepared)


func _capture_png_snapshot_for_images(images_by_uid: Dictionary) -> Dictionary:
	return SnapshotsFeature._capture_png_snapshot_for_images(self, images_by_uid)


func splatmap_terrain_bounds(targets: Array[Dictionary]) -> Dictionary:
	return SplatmapFeature.splatmap_terrain_bounds(self, targets)


func prepare_splatmap_source(
	source_image: Image,
	active_channels: PackedByteArray,
	fill_empty_regions: bool,
	empty_region_channel: int
) -> Image:
	return SplatmapFeature.prepare_splatmap_source(self, source_image, active_channels, fill_empty_regions, empty_region_channel)


func _crop_empty_splatmap_border(
	source_image: Image,
	active_channels: PackedByteArray
) -> Image:
	return SplatmapFeature._crop_empty_splatmap_border(self, source_image, active_channels)


func _splatmap_column_is_empty(
	source_image: Image,
	column: int,
	active_channels: PackedByteArray
) -> bool:
	return SplatmapFeature._splatmap_column_is_empty(self, source_image, column, active_channels)


func _splatmap_row_is_empty(
	source_image: Image,
	row: int,
	left: int,
	right: int,
	active_channels: PackedByteArray
) -> bool:
	return SplatmapFeature._splatmap_row_is_empty(self, source_image, row, left, right, active_channels)


func _strongest_active_splat_component(
	weight: Color,
	active_channels: PackedByteArray
) -> float:
	return SplatmapFeature._strongest_active_splat_component(self, weight, active_channels)


func _fill_empty_splatmap_regions(
	source_image: Image,
	active_channels: PackedByteArray,
	empty_region_channel: int
) -> Image:
	return SplatmapFeature._fill_empty_splatmap_regions(self, source_image, active_channels, empty_region_channel)


func _normalized_splat_weight(
	weight: Color,
	active_channels: PackedByteArray
) -> Color:
	return SplatmapFeature._normalized_splat_weight(self, weight, active_channels)


func build_splatmap_tile(
	source_image: Image,
	terrain_bounds: Rect2i,
	projection_cell: Vector2i,
	active_channels: PackedByteArray
) -> Image:
	return SplatmapFeature.build_splatmap_tile(self, source_image, terrain_bounds, projection_cell, active_channels)


func prepare_resolution_rebuild(target_profile: MaterialBlendProfile) -> Dictionary:
	return SnapshotsFeature.prepare_resolution_rebuild(self, target_profile)


func prepare_png_snapshot(snapshot: Dictionary) -> Dictionary:
	return SnapshotsFeature.prepare_png_snapshot(self, snapshot)


func commit_prepared_images(prepared: Dictionary) -> bool:
	return SnapshotsFeature.commit_prepared_images(self, prepared)


func has_image(placement_uid: String) -> bool:
	return ImagesFeature.has_image(self, placement_uid)


func image_for_uid(placement_uid: String) -> Image:
	return ImagesFeature.image_for_uid(self, placement_uid)


func average_weights_for_uid(placement_uid: String) -> Color:
	return ImagesFeature.average_weights_for_uid(self, placement_uid)


func begin_stroke() -> void:
	StrokesFeature.begin_stroke(self)


func finish_stroke() -> Dictionary:
	return StrokesFeature.finish_stroke(self)


func cancel_stroke_recording() -> void:
	StrokesFeature.cancel_stroke_recording(self)


func brush_segment(
	placement_uid: String,
	footprint_m: Vector2i,
	start_uv: Vector2,
	end_uv: Vector2,
	radius_m: float,
	hardness: float,
	opacity: float,
	palette_index: int,
	rotation_quarters: int,
	erase: bool
) -> bool:
	return BrushFeature.brush_segment(self, placement_uid, footprint_m, start_uv, end_uv, radius_m, hardness, opacity, palette_index, rotation_quarters, erase)


func stamp_material_tile(
	placement_uid: String,
	palette_index: int,
	opacity: float,
	rotation_quarters: int,
	erase: bool
) -> bool:
	return BrushFeature.stamp_material_tile(self, placement_uid, palette_index, opacity, rotation_quarters, erase)


func stamp_splatmap_tile(
	placement_uid: String,
	template_image: Image,
	palette_slots: PackedInt32Array,
	erase: bool
) -> bool:
	return BrushFeature.stamp_splatmap_tile(self, placement_uid, template_image, palette_slots, erase)


func apply_patch(patches: Dictionary, value_key: String) -> void:
	StrokesFeature.apply_patch(self, patches, value_key)


func upload_dirty() -> int:
	return BatchesFeature.upload_dirty(self)


func save_sidecars(
	board_path: String,
	allowed_uids: Variant = null
) -> Dictionary:
	return SidecarsFeature.save_sidecars(self, board_path, allowed_uids)


func prepare_sidecars(board_path: String, metadata: Dictionary) -> Dictionary:
	return SidecarsFeature.prepare_sidecars(self, board_path, metadata)


func commit_prepared_sidecars(prepared: Dictionary) -> bool:
	return SidecarsFeature.commit_prepared_sidecars(self, prepared)


func _ensure_registered_batch_texture(placement_uid: String) -> bool:
	return BatchesFeature._ensure_registered_batch_texture(self, placement_uid)


func _rebuild_batch_texture(batch_key: String) -> bool:
	return BatchesFeature._rebuild_batch_texture(self, batch_key)


func _prepare_image_replacement(prepared_images: Dictionary) -> Dictionary:
	return BatchesFeature._prepare_image_replacement(self, prepared_images)


func _build_batch_texture_state(
	batch_key: String,
	images_by_uid: Dictionary
) -> Dictionary:
	return BatchesFeature._build_batch_texture_state(self, batch_key, images_by_uid)


func _apply_batch_texture_state(batch_key: String, state: Dictionary) -> void:
	BatchesFeature._apply_batch_texture_state(self, batch_key, state)


func _refresh_batch_instance_colors(batch_key: String) -> void:
	BatchesFeature._refresh_batch_instance_colors(self, batch_key)


func _refresh_instance_colors_for_uid(placement_uid: String) -> void:
	BatchesFeature._refresh_instance_colors_for_uid(self, placement_uid)


func _registered_footprint(placement_uid: String) -> Vector2i:
	return BatchesFeature._registered_footprint(self, placement_uid)


func _batch_has_authored_paint(
	uids: PackedStringArray,
	seed_uid_by_uid: Dictionary = {}
) -> bool:
	return BatchesFeature._batch_has_authored_paint(self, uids, seed_uid_by_uid)


func _batch_has_authored_paint_in(
	uids: PackedStringArray,
	images_by_uid: Dictionary,
	seed_uid_by_uid: Dictionary = {}
) -> bool:
	return BatchesFeature._batch_has_authored_paint_in(self, uids, images_by_uid, seed_uid_by_uid)


func _visible_image_for_uid(
	uid: String,
	images_by_uid: Dictionary,
	seed_uid_by_uid: Dictionary
) -> Image:
	return BatchesFeature._visible_image_for_uid(self, uid, images_by_uid, seed_uid_by_uid)


func _upload_seeded_layers(source_uid: String, source_image: Image) -> int:
	return BatchesFeature._upload_seeded_layers(self, source_uid, source_image)


func _rebuild_seeded_batches_for_source(source_uid: String) -> void:
	BatchesFeature._rebuild_seeded_batches_for_source(self, source_uid)


func _layer_has_runtime_constraint(palette_index: int) -> bool:
	return ColorMathFeature._layer_has_runtime_constraint(self, palette_index)


func _painted_layer_color(
	original: Color,
	channel: int,
	weight: float,
	erase: bool,
	normalize_before_runtime_masks: bool
) -> Color:
	return ColorMathFeature._painted_layer_color(self, original, channel, weight, erase, normalize_before_runtime_masks)


func _independent_layer_color(
	original: Color,
	channel: int,
	weight: float,
	erase: bool
) -> Color:
	return ColorMathFeature._independent_layer_color(self, original, channel, weight, erase)


func _normalized_splat_color(
	original: Color,
	channel: int,
	weight: float,
	erase: bool
) -> Color:
	return ColorMathFeature._normalized_splat_color(self, original, channel, weight, erase)


func _color_component(color: Color, component: int) -> float:
	return ColorMathFeature._color_component(self, color, component)


func _color_with_component(color: Color, component: int, value: float) -> Color:
	return ColorMathFeature._color_with_component(self, color, component, value)


func _falloff(distance_ratio: float, hardness: float) -> float:
	return ColorMathFeature._falloff(self, distance_ratio, hardness)


func _point_segment_distance_squared(
	point: Vector2,
	start: Vector2,
	finish: Vector2
) -> float:
	return ColorMathFeature._point_segment_distance_squared(self, point, start, finish)


func _sha256_bytes(bytes: PackedByteArray) -> String:
	return SidecarsFeature._sha256_bytes(self, bytes)


func _uid_is_safe(uid: String) -> bool:
	return SidecarsFeature._uid_is_safe(self, uid)
