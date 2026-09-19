@tool
class_name MTSSurfaceMaterialPaint
extends RefCounted

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


## Bind the visible board profile that defines resolution and splat behavior.
func bind_profile(value: MaterialBlendProfile) -> void:
	profile = value


## Return the four palette entries represented by one terrain face's RGBA image.
##
## A face without an explicit record derives the historical identity mapping once:
## old boards stored channel N as palette entry N. Registration persists that result
## in memory, and the next explicit board save writes it into metadata version 2.
func palette_slots_for_uid(placement_uid: String) -> PackedInt32Array:
	var saved_value: Variant = _palette_slots_by_uid.get(placement_uid, null)
	if saved_value is PackedInt32Array:
		return (saved_value as PackedInt32Array).duplicate()
	return _default_palette_slots()


## Return the four clockwise PNG quarter-turns assigned to one face's local material slots.
func slot_rotations_for_uid(placement_uid: String) -> PackedInt32Array:
	if _slot_rotations_by_uid == null:
		_slot_rotations_by_uid = {}
	var saved_value: Variant = _slot_rotations_by_uid.get(placement_uid, null)
	if saved_value is PackedInt32Array:
		return (saved_value as PackedInt32Array).duplicate()
	return PackedInt32Array([0, 0, 0, 0])


## Return only palette entries that can currently affect at least one registered terrain face.
##
## Brush entries require a nonzero authored RGBA weight. Procedural entries require an
## explicit face mapping because their rules can render without any authored paint pixels.
func used_palette_indices() -> PackedInt32Array:
	return used_palette_indices_for_profile(profile)


## Return the painted or procedurally assigned palette entries for one candidate profile.
##
## Profile-change planning compares the old and new recipes against the same canonical
## paint images, so an unused material can be edited without touching any live batch.
func used_palette_indices_for_profile(
	candidate_profile: MaterialBlendProfile
) -> PackedInt32Array:
	var brush_candidates: Dictionary = {}
	var procedural_candidates: Dictionary = {}
	var used: Dictionary = {}
	if candidate_profile == null:
		return PackedInt32Array()
	candidate_profile.ensure_layers()
	for palette_index: int in candidate_profile.layer_count():
		var layer := candidate_profile.layer(palette_index)
		if not bool(layer.get("enabled", false)):
			continue
		if String(layer.get("asset_id", "")).strip_edges().is_empty():
			continue
		if (
			int(layer.get("application_mode", MaterialBlendProfile.ApplicationMode.BRUSH))
			== MaterialBlendProfile.ApplicationMode.PROCEDURAL
		):
			procedural_candidates[palette_index] = true
		else:
			brush_candidates[palette_index] = true
	for uid_value: Variant in _palette_slots_by_uid.keys():
		var uid := String(uid_value)
		if not _batch_key_by_uid.has(uid):
			continue
		var slots_value: Variant = _palette_slots_by_uid[uid_value]
		if not slots_value is PackedInt32Array:
			continue
		for palette_index: int in slots_value:
			if procedural_candidates.has(palette_index):
				used[palette_index] = true
	var remaining_brush_entries := brush_candidates.duplicate()
	for uid_value: Variant in _images_by_uid.keys():
		if remaining_brush_entries.is_empty():
			break
		var uid := String(uid_value)
		if not _batch_key_by_uid.has(uid):
			continue
		var image := image_for_uid(uid)
		if image == null or image.is_empty():
			continue
		var slots := palette_slots_for_uid(uid)
		var bytes := image.get_data()
		var byte_offset := 0
		while byte_offset + 3 < bytes.size():
			for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
				var palette_index := slots[slot_index]
				if (
					remaining_brush_entries.has(palette_index)
					and bytes[byte_offset + slot_index] > 0
				):
					used[palette_index] = true
					remaining_brush_entries.erase(palette_index)
			if remaining_brush_entries.is_empty():
				break
			byte_offset += MaterialBlendProfile.WEIGHTS_PER_TEXEL
	var ordered_indices := used.keys()
	ordered_indices.sort()
	var result := PackedInt32Array()
	for index_value: Variant in ordered_indices:
		result.append(int(index_value))
	return result


## Return the deterministic mapping that preserves version-1 paint pixels exactly.
func _default_palette_slots() -> PackedInt32Array:
	var slots := PackedInt32Array([-1, -1, -1, -1])
	if profile == null:
		return slots
	for slot_index: int in mini(
		MaterialBlendProfile.WEIGHTS_PER_TEXEL,
		profile.layer_count()
	):
		slots[slot_index] = slot_index
	return slots


## Persist one face's derived mapping in runtime state without announcing a change.
func _ensure_palette_slots(placement_uid: String) -> PackedInt32Array:
	var slots := palette_slots_for_uid(placement_uid)
	_palette_slots_by_uid[placement_uid] = slots.duplicate()
	# Existing @tool instances acquire newly declared members as null during hot reload,
	# so initialize the canonical dictionary before the editor resumes terrain rendering.
	if _slot_rotations_by_uid == null:
		_slot_rotations_by_uid = {}
	if not _slot_rotations_by_uid.has(placement_uid):
		_slot_rotations_by_uid[placement_uid] = slot_rotations_for_uid(placement_uid)
	return slots


## Replace one face's exact slot orientations and announce derived instance-data invalidation.
func _set_slot_rotations(
	placement_uid: String,
	rotations: PackedInt32Array,
	record_stroke: bool = true
) -> bool:
	if placement_uid.is_empty() or rotations.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: a face material orientation requires one UID and four quarter-turns.")
		return false
	var normalized := rotations.duplicate()
	for slot_index: int in normalized.size():
		normalized[slot_index] = posmod(normalized[slot_index], 4)
	var before := slot_rotations_for_uid(placement_uid)
	if before == normalized:
		_slot_rotations_by_uid[placement_uid] = normalized
		return false
	if _stroke_active and record_stroke and not _stroke_rotations_before.has(placement_uid):
		_stroke_rotations_before[placement_uid] = before
	_slot_rotations_by_uid[placement_uid] = normalized
	palette_slots_changed.emit(placement_uid)
	return true


## Set one face-local material slot to the selected regular PNG brush orientation.
func _set_slot_rotation(
	placement_uid: String,
	slot_index: int,
	rotation_quarters: int,
	record_stroke: bool = true
) -> bool:
	if slot_index < 0 or slot_index >= MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: material slot orientation index is invalid.")
		return false
	var rotations := slot_rotations_for_uid(placement_uid)
	rotations[slot_index] = posmod(rotation_quarters, 4)
	return _set_slot_rotations(placement_uid, rotations, record_stroke)


## Establish one rendered face's canonical mapping before the renderer chooses its batch.
##
## Thin auto-textured sides share their source face's weights and therefore share its
## palette mapping until the side receives its own manual paint image.
func register_face_palette(
	placement_uid: String,
	seed_uid: String = ""
) -> PackedInt32Array:
	if not seed_uid.is_empty() and seed_uid != placement_uid and not has_image(placement_uid):
		_palette_slots_by_uid[placement_uid] = palette_slots_for_uid(seed_uid)
		_slot_rotations_by_uid[placement_uid] = slot_rotations_for_uid(seed_uid)
	return _ensure_palette_slots(placement_uid)


## Return one stable batch-key fragment for the face's exact RGBA palette meaning.
func palette_slots_key(placement_uid: String) -> String:
	var slots := palette_slots_for_uid(placement_uid)
	return "%d:%d:%d:%d" % [slots[0], slots[1], slots[2], slots[3]]


## Return the local RGBA component already carrying one palette entry.
func weight_slot_for_palette(placement_uid: String, palette_index: int) -> int:
	if palette_index < 0:
		return -1
	return palette_slots_for_uid(placement_uid).find(palette_index)


## Return whether one face-local component contains any authored weight.
func _slot_has_weight(placement_uid: String, slot_index: int) -> bool:
	var image := image_for_uid(placement_uid)
	if image == null:
		return false
	for y: int in image.get_height():
		for x: int in image.get_width():
			if _color_component(image.get_pixel(x, y), slot_index) > 0.0:
				return true
	return false


## Return a replaceable local slot, preferring an explicitly unused one.
func _available_palette_slot(
	placement_uid: String,
	slots: PackedInt32Array
) -> int:
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		if slots[slot_index] < 0:
			return slot_index
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		if not _slot_has_weight(placement_uid, slot_index):
			return slot_index
	return -1


## Replace one face's exact four-entry mapping and announce derived batch invalidation.
func _set_palette_slots(
	placement_uid: String,
	slots: PackedInt32Array,
	record_stroke: bool = true
) -> bool:
	if placement_uid.is_empty() or slots.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: a face palette mapping requires one UID and four indices.")
		return false
	var before := palette_slots_for_uid(placement_uid)
	if before == slots:
		_palette_slots_by_uid[placement_uid] = slots.duplicate()
		return false
	if _stroke_active and record_stroke and not _stroke_slots_before.has(placement_uid):
		_stroke_slots_before[placement_uid] = before.duplicate()
	_palette_slots_by_uid[placement_uid] = slots.duplicate()
	palette_slots_changed.emit(placement_uid)
	return true


## Resolve or allocate the local RGBA slot used to paint one palette material.
##
## A face accepts a new palette entry only when one component is unused across the
## complete face image. Refusing a full face preserves its four existing materials
## and makes the actual per-cell limit visible instead of overwriting authored paint.
func _ensure_palette_slot(
	placement_uid: String,
	palette_index: int,
	allow_allocate: bool
) -> int:
	if profile == null or palette_index < 0 or palette_index >= profile.layer_count():
		push_error(
			"MTSSurfaceMaterialPaint: palette index %d is not present on the active board."
			% palette_index
		)
		return -1
	var slots := _ensure_palette_slots(placement_uid)
	var existing := slots.find(palette_index)
	if existing >= 0 or not allow_allocate:
		return existing
	var available := _available_palette_slot(placement_uid, slots)
	if available < 0:
		push_error(
			"MTSSurfaceMaterialPaint: terrain face '%s' already uses all four material slots."
			% placement_uid
		)
		return -1
	slots[available] = palette_index
	_set_palette_slots(placement_uid, slots)
	return available


## Assign one procedural palette entry to every supplied face as one preflighted change.
##
## No face is mutated unless every face has a free zero-weight slot, so a failed
## level pass cannot leave a partial material assignment behind.
func assign_palette_to_faces(
	palette_index: int,
	placement_uids: PackedStringArray
) -> Dictionary:
	var after_by_uid: Dictionary = {}
	for placement_uid: String in placement_uids:
		var slots := palette_slots_for_uid(placement_uid)
		if slots.find(palette_index) >= 0:
			continue
		var available := _available_palette_slot(placement_uid, slots)
		if available < 0:
			return {
				"error": ERR_BUSY,
				"face_uid": placement_uid,
				"patches": {},
			}
		var after := slots.duplicate()
		after[available] = palette_index
		after_by_uid[placement_uid] = after
	var patches: Dictionary = {}
	for uid_value: Variant in after_by_uid.keys():
		var placement_uid := String(uid_value)
		var before := palette_slots_for_uid(placement_uid)
		var after: PackedInt32Array = after_by_uid[uid_value]
		patches[placement_uid] = {
			"resolution": Vector2i.ZERO,
			"pixels": PackedInt32Array(),
			"before": PackedColorArray(),
			"after": PackedColorArray(),
			"slots_before": before,
			"slots_after": after,
			"rotations_before": slot_rotations_for_uid(placement_uid),
			"rotations_after": slot_rotations_for_uid(placement_uid),
		}
		_set_palette_slots(placement_uid, after, false)
	if not patches.is_empty():
		palette_usage_changed.emit()
	return {"error": OK, "face_uid": "", "patches": patches}


## Set the literal R/G/B/A palette meaning before a splatmap replaces a face's weights.
func set_splatmap_palette_slots(
	placement_uid: String,
	slots: PackedInt32Array
) -> bool:
	if profile == null or slots.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error(
			"MTSSurfaceMaterialPaint: splatmap face '%s' requires four palette mappings."
			% placement_uid
		)
		return false
	for palette_index: int in slots:
		# Minus one explicitly disables an unused RGBA component; every non-empty
		# component must name an existing entry in the board palette.
		if palette_index < -1 or palette_index >= profile.layer_count():
			push_error(
				"MTSSurfaceMaterialPaint: splatmap face '%s' has an invalid palette mapping."
				% placement_uid
			)
			return false
	_set_palette_slots(placement_uid, slots)
	return true


## Return one immutable one-layer black array used by completely unpainted batches.
func neutral_texture() -> Texture2DArray:
	if _neutral_texture == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		_neutral_texture = Texture2DArray.new()
		var error := _neutral_texture.create_from_images([image])
		if error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot create neutral control array (%s)."
				% error_string(error)
			)
			_neutral_texture = null
	return _neutral_texture


var _neutral_texture: Texture2DArray = null


## Remove every authored paint image, rebuild registered batches as neutral, and return its undo patch.
func clear_all_paint() -> Dictionary:
	var patches := _build_clear_patches(-1)
	_images_by_uid.clear()
	_stroke_before.clear()
	_stroke_slots_before.clear()
	if _stroke_rotations_before == null:
		_stroke_rotations_before = {}
	_stroke_rotations_before.clear()
	_stroke_max_weights.clear()
	_stroke_active = false
	_dirty_uids.clear()
	for key_value: Variant in _batch_records.keys():
		var key := String(key_value)
		_rebuild_batch_texture(key)
		batch_texture_changed.emit(key)
	if not patches.is_empty():
		palette_usage_changed.emit()
	return patches


## Remove one palette material from every face that carries it and return its undo patch.
##
## Each face may carry the palette entry in a different RGBA slot, so this scans the
## explicit face mappings and clears only the corresponding local component. Slot and
## pixel changes travel in one patch so undo cannot restore one without the other.
func clear_palette_material(palette_index: int) -> Dictionary:
	if profile == null or palette_index < 0 or palette_index >= profile.layer_count():
		push_error(
			"MTSSurfaceMaterialPaint: cannot clear missing palette index %d."
			% palette_index
		)
		return {}
	var patches := _build_palette_clear_patches(palette_index)
	if patches.is_empty():
		return {}
	apply_patch(patches, "after")
	var batches_to_rebuild: Dictionary = {}
	for uid_value: Variant in patches.keys():
		var uid := String(uid_value)
		var image := image_for_uid(uid)
		if image == null or _image_has_weight(image):
			continue
		_images_by_uid.erase(uid)
		_dirty_uids.erase(uid)
		var batch_key := String(_batch_key_by_uid.get(uid, ""))
		if not batch_key.is_empty():
			batches_to_rebuild[batch_key] = true
	# A removed empty image changes the GPU array back to its neutral layer; rebuild
	# only the registered batches that contained one of those images.
	for batch_value: Variant in batches_to_rebuild.keys():
		var batch_key := String(batch_value)
		_rebuild_batch_texture(batch_key)
		batch_texture_changed.emit(batch_key)
	return patches


## Build sparse before/after colors for the explicit Clear Brush Paint command.
func _build_clear_patches(channel: int) -> Dictionary:
	var patches: Dictionary = {}
	for uid_value: Variant in _images_by_uid.keys():
		var uid := String(uid_value)
		var image := image_for_uid(uid)
		if image == null:
			continue
		var pixels := PackedInt32Array()
		var before := PackedColorArray()
		var after := PackedColorArray()
		for y: int in image.get_height():
			for x: int in image.get_width():
				var current := image.get_pixel(x, y)
				var next := (
					Color(0.0, 0.0, 0.0, 0.0)
					if channel < 0
					else _color_with_component(current, channel, 0.0)
				)
				if next == current:
					continue
				pixels.append(y * image.get_width() + x)
				before.append(current)
				after.append(next)
		if not pixels.is_empty():
			patches[uid] = {
				"resolution": image.get_size(),
				"pixels": pixels,
				"before": before,
				"after": after,
			}
	return patches


## Build one atomic pixel-and-slot patch for removing a palette entry everywhere.
func _build_palette_clear_patches(palette_index: int) -> Dictionary:
	var patches: Dictionary = {}
	for uid_value: Variant in _palette_slots_by_uid.keys():
		var uid := String(uid_value)
		var slots := palette_slots_for_uid(uid)
		var slot_index := slots.find(palette_index)
		if slot_index < 0:
			continue
		var image := image_for_uid(uid)
		var pixels := PackedInt32Array()
		var before := PackedColorArray()
		var after := PackedColorArray()
		var resolution := image.get_size() if image != null else Vector2i.ZERO
		if image != null:
			for y: int in image.get_height():
				for x: int in image.get_width():
					var current := image.get_pixel(x, y)
					var next := _color_with_component(current, slot_index, 0.0)
					if next == current:
						continue
					pixels.append(y * image.get_width() + x)
					before.append(current)
					after.append(next)
		var after_slots := slots.duplicate()
		after_slots[slot_index] = -1
		var before_rotations := slot_rotations_for_uid(uid)
		var after_rotations := before_rotations.duplicate()
		after_rotations[slot_index] = 0
		patches[uid] = {
			"resolution": resolution,
			"pixels": pixels,
			"before": before,
			"after": after,
			"slots_before": slots,
			"slots_after": after_slots,
			"rotations_before": before_rotations,
			"rotations_after": after_rotations,
		}
	return patches


## Return whether one canonical image still contains any material weight after channel removal.
func _image_has_weight(image: Image) -> bool:
	for y: int in image.get_height():
		for x: int in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r > 0.0 or color.g > 0.0 or color.b > 0.0 or color.a > 0.0:
				return true
	return false


## Discard authored paint for faces the canonical terrain no longer owns.
##
## Called when terrain topology is erased. The images are dropped outright rather
## than retained for a later re-fill: the face they described is gone, so keeping
## its pixels would let deleted material reappear under a newly filled cell.
func discard_paint_for_uids(uids: PackedStringArray) -> void:
	var rebuilt_batches: Dictionary = {}
	for uid: String in uids:
		if not _images_by_uid.has(uid):
			continue
		var batch_key := String(_batch_key_by_uid.get(uid, ""))
		_images_by_uid.erase(uid)
		_palette_slots_by_uid.erase(uid)
		_slot_rotations_by_uid.erase(uid)
		_dirty_uids.erase(uid)
		_stroke_before.erase(uid)
		_stroke_slots_before.erase(uid)
		_stroke_rotations_before.erase(uid)
		_stroke_max_weights.erase(uid)
		_rebuild_seeded_batches_for_source(uid)
		if not batch_key.is_empty():
			rebuilt_batches[batch_key] = true
	for batch_value: Variant in rebuilt_batches.keys():
		var batch_key := String(batch_value)
		_rebuild_batch_texture(batch_key)
		batch_texture_changed.emit(batch_key)


## Register one derived terrain-face batch without allocating paint for it.
##
## Batches are keyed by the canonical TerrainMesh face UIDs the caller is drawing,
## so paint identity is the terrain's own identity and no placement record stands
## between the two. A Texture2DArray is created only when this batch already has
## authored paint.
func register_batch(
	batch_key: String,
	face_uids: PackedStringArray,
	footprint_m: Vector2i,
	seed_uid_by_uid: Dictionary = {}
) -> void:
	if batch_key.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot register an empty batch key.")
		return
	var uids := PackedStringArray()
	var valid_seeds: Dictionary = {}
	for uid: String in face_uids:
		if uid.is_empty():
			continue
		uids.append(uid)
		var seed_uid := String(seed_uid_by_uid.get(uid, ""))
		if not seed_uid.is_empty() and seed_uid != uid:
			valid_seeds[uid] = seed_uid
		register_face_palette(uid, seed_uid)
		_batch_key_by_uid[uid] = batch_key
	_batch_records[batch_key] = {
		"uids": uids,
		"footprint_m": footprint_m,
		"seed_uid_by_uid": valid_seeds,
		"texture": null,
		"layer_by_uid": {},
		"resolution": Vector2i.ZERO,
		"multimesh": null,
		"instance_indices_by_uid": {},
	}
	if _batch_has_authored_paint(uids, valid_seeds):
		_rebuild_batch_texture(batch_key)


## Unregister a removed derived batch while retaining paint for undo or movement.
func unregister_batch(batch_key: String) -> void:
	if not _batch_records.has(batch_key):
		return
	var record: Dictionary = _batch_records[batch_key]
	var uids: PackedStringArray = record.get("uids", PackedStringArray())
	for uid: String in uids:
		if String(_batch_key_by_uid.get(uid, "")) == batch_key:
			_batch_key_by_uid.erase(uid)
	_batch_records.erase(batch_key)


## Return the current array texture for one batch or the exact neutral array.
func batch_texture(batch_key: String) -> Texture2DArray:
	var record: Dictionary = _batch_records.get(batch_key, {})
	var texture := record.get("texture", null) as Texture2DArray
	return texture if texture != null else neutral_texture()


## Classify one face's complete control image without changing its canonical pixels.
##
## The result is `(class, uniform_slot)`. A uniform layer is reported only when
## every texel has the same component at least `1 - 4/255` and all competing
## components are encoding noise. Any partial coverage remains mixed so the
## shader continues to sample the exact authored control image.
func control_classification_for_uid(placement_uid: String) -> Vector2i:
	var batch_key := String(_batch_key_by_uid.get(placement_uid, ""))
	var record: Dictionary = _batch_records.get(batch_key, {})
	var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
	var image := _visible_image_for_uid(placement_uid, _images_by_uid, seed_uid_by_uid)
	if image == null or image.is_empty():
		return Vector2i(CONTROL_CLASS_BASE_ONLY, -1)
	var uniform_slot := -1
	var saw_empty_texel := false
	for y: int in image.get_height():
		for x: int in image.get_width():
			var pixel := image.get_pixel(x, y)
			var active_slot := -1
			for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
				var weight := _color_component(pixel, slot_index)
				if weight <= SPLATMAP_EMPTY_COMPONENT_THRESHOLD:
					continue
				if active_slot >= 0 or weight < 1.0 - SPLATMAP_EMPTY_COMPONENT_THRESHOLD:
					return Vector2i(CONTROL_CLASS_MIXED, -1)
				active_slot = slot_index
			if active_slot < 0:
				saw_empty_texel = true
				if uniform_slot >= 0:
					return Vector2i(CONTROL_CLASS_MIXED, -1)
				continue
			if saw_empty_texel:
				return Vector2i(CONTROL_CLASS_MIXED, -1)
			if uniform_slot < 0:
				uniform_slot = active_slot
			elif uniform_slot != active_slot:
				return Vector2i(CONTROL_CLASS_MIXED, -1)
	if uniform_slot < 0:
		return Vector2i(CONTROL_CLASS_BASE_ONLY, -1)
	return Vector2i(CONTROL_CLASS_UNIFORM_LAYER, uniform_slot)


## Encode the control-array layer, fast-path class, and uniform slot in MultiMesh COLOR.
##
## Red and green retain the existing 16-bit array layer. Blue stores the class in
## three exact normalized states, while alpha stores the uniform RGBA slot. Every
## triangle of one face receives identical values, so the shader reads them flat.
func instance_layer_color(batch_key: String, placement_uid: String) -> Color:
	var record: Dictionary = _batch_records.get(batch_key, {})
	var layer_by_uid: Dictionary = record.get("layer_by_uid", {})
	var layer := int(layer_by_uid.get(placement_uid, 0))
	var classification := control_classification_for_uid(placement_uid)
	var uniform_slot := maxi(classification.y, 0)
	return Color(
		float(layer & 255) / 255.0,
		float((layer >> 8) & 255) / 255.0,
		float(classification.x) / 2.0,
		float(uniform_slot) / 3.0
	)


## Bind one derived MultiMesh to its face UIDs so paint edits refresh fast-path metadata in place.
func bind_batch_instance_colors(
	batch_key: String,
	multimesh: MultiMesh,
	instance_indices_by_uid: Dictionary
) -> void:
	if not _batch_records.has(batch_key):
		push_error("MTSSurfaceMaterialPaint: cannot bind instance colors for unknown batch '%s'." % batch_key)
		return
	var record: Dictionary = _batch_records[batch_key]
	record["multimesh"] = multimesh
	record["instance_indices_by_uid"] = instance_indices_by_uid
	_batch_records[batch_key] = record
	_refresh_batch_instance_colors(batch_key)


## Return whether any regular-heightfield face currently owns authored RGBA pixels.
func has_any_paint() -> bool:
	return not _images_by_uid.is_empty()


## Estimate canonical CPU pixels and derived GPU array pixels for current or requested settings.
##
## Driver allocation overhead is intentionally excluded; the reported RGBA8 texel bytes are the
## inspectable portion controlled directly by the two resolution settings.
func paint_memory_bytes(target_profile: MaterialBlendProfile = null) -> Dictionary:
	var cpu_bytes: int = 0
	var gpu_bytes: int = 0
	for uid_value: Variant in _images_by_uid.keys():
		var uid := String(uid_value)
		var image := image_for_uid(uid)
		if image == null:
			continue
		var resolution := image.get_size()
		if target_profile != null:
			var footprint := _registered_footprint(uid)
			if footprint == Vector2i.ZERO:
				push_error(
					"MTSSurfaceMaterialPaint: painted placement '%s' has no registered footprint."
					% uid
				)
				return {"error": ERR_DOES_NOT_EXIST}
			resolution = target_profile.paint_resolution(footprint)
		cpu_bytes += resolution.x * resolution.y * 4
	for record_value: Variant in _batch_records.values():
		var record: Dictionary = record_value
		var uids: PackedStringArray = record.get("uids", PackedStringArray())
		var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
		if not _batch_has_authored_paint_in(uids, _images_by_uid, seed_uid_by_uid):
			continue
		var resolution := Vector2i.ZERO
		if target_profile != null:
			var footprint: Vector2i = record.get("footprint_m", Vector2i.ZERO)
			if footprint == Vector2i.ZERO:
				push_error("MTSSurfaceMaterialPaint: a painted batch has no footprint.")
				return {"error": ERR_INVALID_DATA}
			resolution = target_profile.paint_resolution(footprint)
		else:
			for uid: String in uids:
				var image := image_for_uid(uid)
				if image != null:
					resolution = image.get_size()
					break
		if resolution == Vector2i.ZERO:
			push_error("MTSSurfaceMaterialPaint: a painted batch has no image resolution.")
			return {"error": ERR_INVALID_DATA}
		gpu_bytes += resolution.x * resolution.y * uids.size() * 4
	var palette_slot_bytes := _palette_slots_by_uid.size() * MaterialBlendProfile.WEIGHTS_PER_TEXEL * 4
	return {
		"error": OK,
		"cpu_bytes": cpu_bytes,
		"gpu_bytes": gpu_bytes,
		"palette_slot_bytes": palette_slot_bytes,
		"total_bytes": cpu_bytes + gpu_bytes + palette_slot_bytes,
		"painted_surfaces": _images_by_uid.size(),
		"mapped_surfaces": _palette_slots_by_uid.size(),
	}


## Encode the exact canonical images for one resolution-change undo record.
##
## PNG compression keeps the temporary undo snapshot smaller than duplicate live Images while
## preserving every RGBA8 weight exactly.
func capture_png_snapshot() -> Dictionary:
	if _stroke_active:
		push_error("MTSSurfaceMaterialPaint: cannot snapshot paint during an active stroke.")
		return {"error": ERR_BUSY}
	return _capture_png_snapshot_for_images(_images_by_uid)


## Encode one already-prepared replacement so redo data is validated before live state changes.
func capture_prepared_png_snapshot(prepared: Dictionary) -> Dictionary:
	if int(prepared.get("error", FAILED)) != OK:
		push_error("MTSSurfaceMaterialPaint: cannot snapshot an invalid prepared replacement.")
		return {"error": ERR_INVALID_DATA}
	var images_value: Variant = prepared.get("images", null)
	if not images_value is Dictionary:
		push_error("MTSSurfaceMaterialPaint: prepared replacement has no canonical image set.")
		return {"error": ERR_INVALID_DATA}
	return _capture_png_snapshot_for_images(images_value as Dictionary)


## Encode one canonical image dictionary without consulting or changing live paint state.
func _capture_png_snapshot_for_images(images_by_uid: Dictionary) -> Dictionary:
	var pngs: Dictionary = {}
	for uid_value: Variant in images_by_uid.keys():
		var uid := String(uid_value)
		var image := images_by_uid.get(uid) as Image
		if image == null:
			continue
		var bytes := image.save_png_to_buffer()
		if bytes.is_empty():
			push_error("MTSSurfaceMaterialPaint: cannot encode paint snapshot '%s'." % uid)
			return {"error": ERR_CANT_CREATE}
		pngs[uid] = bytes
	return {"error": OK, "pngs": pngs}


## Return the canonical two-dimensional rectangle for one validated directional face set.
##
## This resolves only the explicit projection lattice the control image is stretched across;
## it reads no pixels and allocates no images. Individual face weights are sampled later.
func splatmap_terrain_bounds(targets: Array[Dictionary]) -> Dictionary:
	if profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot resolve splatmap bounds without a profile.")
		return {"error": ERR_UNCONFIGURED}
	if targets.is_empty():
		push_error("MTSSurfaceMaterialPaint: the selected projection has no terrain faces.")
		return {"error": ERR_DOES_NOT_EXIST}
	var minimum_cell := Vector2i(2147483647, 2147483647)
	var maximum_cell := Vector2i(-2147483648, -2147483648)
	for target: Dictionary in targets:
		var uid := String(target.get("uid", ""))
		var cell_value: Variant = target.get("projection_cell", null)
		if uid.is_empty() or not cell_value is Vector2i or not _batch_key_by_uid.has(uid):
			push_error("MTSSurfaceMaterialPaint: splatmap target is not a registered projected face.")
			return {"error": ERR_INVALID_DATA}
		var cell := cell_value as Vector2i
		minimum_cell = minimum_cell.min(cell)
		maximum_cell = maximum_cell.max(cell)
	var terrain_size := maximum_cell - minimum_cell + Vector2i.ONE
	if terrain_size.x <= 0 or terrain_size.y <= 0:
		return {"error": ERR_INVALID_DATA}
	return {
		"error": OK,
		"terrain_bounds": Rect2i(minimum_cell, terrain_size),
		"face_count": targets.size(),
	}


## Return one readable RGBA8 control source with the requested empty-region policy applied.
##
## When extension is enabled, a deterministic eight-neighbour wavefront copies each nearest
## valid source texel into zero-weight regions. Live channel strengths remain shader state and
## therefore never change which source pixels count as authored colour.
func prepare_splatmap_source(
	source_image: Image,
	active_channels: PackedByteArray,
	fill_empty_regions: bool,
	empty_region_channel: int
) -> Image:
	if source_image == null or source_image.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot prepare an empty splatmap image.")
		return null
	if active_channels.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: splatmap preparation requires four channel states.")
		return null
	var readable := source_image.duplicate() as Image
	if readable == null:
		return null
	if readable.is_compressed():
		var decompress_error := readable.decompress()
		if decompress_error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot decompress splatmap (%s)."
				% error_string(decompress_error)
			)
			return null
	if readable.get_format() != Image.FORMAT_RGBA8:
		readable.convert(Image.FORMAT_RGBA8)
	var fitted_source := _crop_empty_splatmap_border(readable, active_channels)
	if fitted_source == null:
		return null
	if not fill_empty_regions:
		return fitted_source
	return _fill_empty_splatmap_regions(
		fitted_source,
		active_channels,
		empty_region_channel
	)


## Crop only the fully empty outer frame so source content meets the terrain footprint exactly.
##
## Internal black regions remain canonical native weights. The crop uses the same explicit
## active-channel threshold as optional base filling, so preview and authored tiles stay aligned.
func _crop_empty_splatmap_border(
	source_image: Image,
	active_channels: PackedByteArray
) -> Image:
	var left := 0
	var right := source_image.get_width() - 1
	var top := 0
	var bottom := source_image.get_height() - 1
	while left <= right and _splatmap_column_is_empty(source_image, left, active_channels):
		left += 1
	while right >= left and _splatmap_column_is_empty(source_image, right, active_channels):
		right -= 1
	if left > right:
		push_error(
			"MTSSurfaceMaterialPaint: splatmap has no visible weights in its assigned channels."
		)
		return null
	while top <= bottom and _splatmap_row_is_empty(
		source_image,
		top,
		left,
		right,
		active_channels
	):
		top += 1
	while bottom >= top and _splatmap_row_is_empty(
		source_image,
		bottom,
		left,
		right,
		active_channels
	):
		bottom -= 1
	var occupied_region := Rect2i(
		Vector2i(left, top),
		Vector2i(right - left + 1, bottom - top + 1)
	)
	if occupied_region.position == Vector2i.ZERO and occupied_region.size == source_image.get_size():
		return source_image
	var cropped := source_image.get_region(occupied_region)
	if cropped == null or cropped.is_empty():
		push_error("MTSSurfaceMaterialPaint: occupied splatmap border crop is empty.")
		return null
	return cropped


## Return whether one source column contains no visible assigned-channel weight.
func _splatmap_column_is_empty(
	source_image: Image,
	column: int,
	active_channels: PackedByteArray
) -> bool:
	for pixel_y: int in source_image.get_height():
		if (
			_strongest_active_splat_component(
				source_image.get_pixel(column, pixel_y),
				active_channels
			)
			> SPLATMAP_EMPTY_COMPONENT_THRESHOLD
		):
			return false
	return true


## Return whether one fitted source row contains no visible assigned-channel weight.
func _splatmap_row_is_empty(
	source_image: Image,
	row: int,
	left: int,
	right: int,
	active_channels: PackedByteArray
) -> bool:
	for pixel_x: int in range(left, right + 1):
		if (
			_strongest_active_splat_component(
				source_image.get_pixel(pixel_x, row),
				active_channels
			)
			> SPLATMAP_EMPTY_COMPONENT_THRESHOLD
		):
			return false
	return true


## Return the strongest assigned component used by border fitting and empty-region filling.
func _strongest_active_splat_component(
	weight: Color,
	active_channels: PackedByteArray
) -> float:
	var strongest := 0.0
	if active_channels[0] != 0:
		strongest = maxf(strongest, weight.r)
	if active_channels[1] != 0:
		strongest = maxf(strongest, weight.g)
	if active_channels[2] != 0:
		strongest = maxf(strongest, weight.b)
	if active_channels[3] != 0:
		strongest = maxf(strongest, weight.a)
	return strongest


## Replace every effectively black source texel with one explicit base channel.
##
## A small per-component threshold treats PNG encoding noise as black while preserving all
## visibly weighted pixels. Direct assignment avoids the seams produced by nearest-seed waves.
func _fill_empty_splatmap_regions(
	source_image: Image,
	active_channels: PackedByteArray,
	empty_region_channel: int
) -> Image:
	if empty_region_channel < 0 or empty_region_channel >= MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: empty-region base channel is outside R/G/B/A.")
		return null
	if active_channels[empty_region_channel] == 0:
		push_error(
			"MTSSurfaceMaterialPaint: empty-region base channel %d has no assigned material."
			% empty_region_channel
		)
		return null
	var base_weight := Color(0.0, 0.0, 0.0, 0.0)
	match empty_region_channel:
		0:
			base_weight.r = 1.0
		1:
			base_weight.g = 1.0
		2:
			base_weight.b = 1.0
		3:
			base_weight.a = 1.0
	for pixel_y: int in source_image.get_height():
		for pixel_x: int in source_image.get_width():
			var weight := source_image.get_pixel(pixel_x, pixel_y)
			if (
				_strongest_active_splat_component(weight, active_channels)
				<= SPLATMAP_EMPTY_COMPONENT_THRESHOLD
			):
				source_image.set_pixel(pixel_x, pixel_y, base_weight)
	return source_image


## Return one native source weight after explicit channel masking and normalization.
func _normalized_splat_weight(
	weight: Color,
	active_channels: PackedByteArray
) -> Color:
	weight.r *= float(active_channels[0])
	weight.g *= float(active_channels[1])
	weight.b *= float(active_channels[2])
	weight.a *= float(active_channels[3])
	var total := weight.r + weight.g + weight.b + weight.a
	if total <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	return Color(
		weight.r / total,
		weight.g / total,
		weight.b / total,
		weight.a / total
	)


## Return the RGBA weights one terrain cell covers inside the stretched control image.
##
## The control image is stretched across the terrain's whole cell rectangle, so a cell
## owns exactly its proportional sub-rectangle of source pixels. Cropping that region
## and letting Image.resize() filter it keeps the work in engine code: one tile costs
## two native calls instead of the per-pixel script loop this replaces.
func build_splatmap_tile(
	source_image: Image,
	terrain_bounds: Rect2i,
	projection_cell: Vector2i,
	active_channels: PackedByteArray
) -> Image:
	if profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot build a splat tile without a profile.")
		return null
	if active_channels.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: a splat tile requires four explicit channel states.")
		return null
	if source_image == null or source_image.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot build a splat tile from an empty source.")
		return null
	if terrain_bounds.size.x <= 0 or terrain_bounds.size.y <= 0:
		push_error("MTSSurfaceMaterialPaint: splat tile bounds are empty.")
		return null
	var cell_index := projection_cell - terrain_bounds.position
	if (
		cell_index.x < 0
		or cell_index.y < 0
		or cell_index.x >= terrain_bounds.size.x
		or cell_index.y >= terrain_bounds.size.y
	):
		push_error(
			"MTSSurfaceMaterialPaint: projection cell %s is outside splatmap bounds %s."
			% [projection_cell, terrain_bounds]
		)
		return null
	var source_size := source_image.get_size()
	var start := Vector2i(
		floori(float(cell_index.x) / float(terrain_bounds.size.x) * float(source_size.x)),
		floori(float(cell_index.y) / float(terrain_bounds.size.y) * float(source_size.y))
	)
	var end := Vector2i(
		ceili(float(cell_index.x + 1) / float(terrain_bounds.size.x) * float(source_size.x)),
		ceili(float(cell_index.y + 1) / float(terrain_bounds.size.y) * float(source_size.y))
	)
	# A control image coarser than the terrain can map a whole cell inside one source
	# texel, so the region is widened to a single pixel rather than becoming empty.
	start.x = clampi(start.x, 0, maxi(source_size.x - 1, 0))
	start.y = clampi(start.y, 0, maxi(source_size.y - 1, 0))
	end.x = clampi(maxi(end.x, start.x + 1), start.x + 1, source_size.x)
	end.y = clampi(maxi(end.y, start.y + 1), start.y + 1, source_size.y)
	var tile := source_image.get_region(Rect2i(start, end - start))
	if tile == null or tile.is_empty():
		push_error(
			"MTSSurfaceMaterialPaint: splat tile region for projection cell %s is empty."
			% projection_cell
		)
		return null
	var resolution := profile.paint_resolution(Vector2i.ONE)
	if tile.get_size() != resolution:
		tile.resize(resolution.x, resolution.y, Image.INTERPOLATE_BILINEAR)
	if tile.get_format() != Image.FORMAT_RGBA8:
		tile.convert(Image.FORMAT_RGBA8)
	# Store normalized native source ratios. The shader applies visible strength
	# controls at draw time so existing brush strokes respond immediately to slider changes.
	for pixel_y: int in resolution.y:
		for pixel_x: int in resolution.x:
			tile.set_pixel(
				pixel_x,
				pixel_y,
				_normalized_splat_weight(
					tile.get_pixel(pixel_x, pixel_y),
					active_channels
				)
			)
	return tile


## Prepare bilinearly resampled canonical images and every affected GPU array before committing.
##
## Preparation is atomic: a failed image or Texture2DArray allocation leaves the current profile,
## canonical images, and batch textures untouched.
func prepare_resolution_rebuild(target_profile: MaterialBlendProfile) -> Dictionary:
	if target_profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot rebuild resolution without a profile.")
		return {"error": ERR_INVALID_PARAMETER}
	if _stroke_active:
		push_error("MTSSurfaceMaterialPaint: cannot rebuild resolution during an active stroke.")
		return {"error": ERR_BUSY}
	var prepared_images: Dictionary = {}
	for uid_value: Variant in _images_by_uid.keys():
		var uid := String(uid_value)
		var source := image_for_uid(uid)
		if source == null:
			continue
		var footprint := _registered_footprint(uid)
		if footprint == Vector2i.ZERO:
			push_error(
				"MTSSurfaceMaterialPaint: cannot resize unregistered painted placement '%s'."
				% uid
			)
			return {"error": ERR_DOES_NOT_EXIST}
		var resolution := target_profile.paint_resolution(footprint)
		var resized := source.duplicate() as Image
		if resized == null:
			push_error("MTSSurfaceMaterialPaint: cannot duplicate paint image '%s'." % uid)
			return {"error": ERR_CANT_CREATE}
		if resized.get_size() != resolution:
			resized.resize(resolution.x, resolution.y, Image.INTERPOLATE_BILINEAR)
		prepared_images[uid] = resized
	return _prepare_image_replacement(prepared_images)


## Decode an exact undo snapshot and prepare all derived arrays before restoring it.
func prepare_png_snapshot(snapshot: Dictionary) -> Dictionary:
	if _stroke_active:
		push_error("MTSSurfaceMaterialPaint: cannot restore paint during an active stroke.")
		return {"error": ERR_BUSY}
	var pngs_value: Variant = snapshot.get("pngs", {})
	if int(snapshot.get("error", FAILED)) != OK or not pngs_value is Dictionary:
		push_error("MTSSurfaceMaterialPaint: cannot restore an invalid paint snapshot.")
		return {"error": ERR_INVALID_DATA}
	var prepared_images: Dictionary = {}
	for uid_value: Variant in (pngs_value as Dictionary).keys():
		var uid := String(uid_value)
		var bytes_value: Variant = (pngs_value as Dictionary)[uid_value]
		if not bytes_value is PackedByteArray:
			push_error("MTSSurfaceMaterialPaint: snapshot '%s' is not PNG bytes." % uid)
			return {"error": ERR_INVALID_DATA}
		var image := Image.new()
		var load_error := image.load_png_from_buffer(bytes_value as PackedByteArray)
		if load_error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot decode paint snapshot '%s' (%s)."
				% [uid, error_string(load_error)]
			)
			return {"error": load_error}
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		prepared_images[uid] = image
	return _prepare_image_replacement(prepared_images)


## Commit one fully prepared canonical image set and its already-created GPU arrays.
func commit_prepared_images(prepared: Dictionary) -> bool:
	if int(prepared.get("error", FAILED)) != OK:
		push_error("MTSSurfaceMaterialPaint: cannot commit an invalid image replacement.")
		return false
	var images_value: Variant = prepared.get("images", {})
	var states_value: Variant = prepared.get("batch_states", {})
	if not images_value is Dictionary or not states_value is Dictionary:
		push_error("MTSSurfaceMaterialPaint: prepared image replacement is incomplete.")
		return false
	if (states_value as Dictionary).size() != _batch_records.size():
		push_error("MTSSurfaceMaterialPaint: prepared batch state count is incomplete.")
		return false
	for key_value: Variant in (states_value as Dictionary).keys():
		var batch_key := String(key_value)
		var state_value: Variant = (states_value as Dictionary)[key_value]
		if not state_value is Dictionary or not _batch_records.has(batch_key):
			push_error(
				"MTSSurfaceMaterialPaint: prepared batch state '%s' is invalid."
				% batch_key
			)
			return false
	_images_by_uid = (images_value as Dictionary).duplicate()
	for key_value: Variant in (states_value as Dictionary).keys():
		var batch_key := String(key_value)
		var state: Dictionary = (states_value as Dictionary)[key_value]
		_apply_batch_texture_state(batch_key, state)
	_dirty_uids.clear()
	_stroke_before.clear()
	_stroke_slots_before.clear()
	if _stroke_rotations_before == null:
		_stroke_rotations_before = {}
	_stroke_rotations_before.clear()
	_stroke_max_weights.clear()
	_stroke_active = false
	for key_value: Variant in _batch_records.keys():
		batch_texture_changed.emit(String(key_value))
	palette_usage_changed.emit()
	return true


## Return whether one placement currently owns authored RGBA pixels.
func has_image(placement_uid: String) -> bool:
	return _images_by_uid.has(placement_uid)


## Return the canonical paint image without exposing a duplicate representation.
func image_for_uid(placement_uid: String) -> Image:
	return _images_by_uid.get(placement_uid, null) as Image


## Return the mean authored RGBA layer weights for one receiving terrain face.
##
## Palette analysis uses this derived summary to include splat-painted material
## albedos without creating a second stored representation of the paint image.
func average_weights_for_uid(placement_uid: String) -> Color:
	var image := image_for_uid(placement_uid)
	if image == null or image.is_empty():
		return Color(0.0, 0.0, 0.0, 0.0)
	var sum := Color(0.0, 0.0, 0.0, 0.0)
	for y: int in image.get_height():
		for x: int in image.get_width():
			sum += image.get_pixel(x, y)
	var pixel_count := maxi(image.get_width() * image.get_height(), 1)
	return sum / float(pixel_count)


## Begin one event-rate-independent sparse paint transaction.
func begin_stroke() -> void:
	if _stroke_active:
		push_error("MTSSurfaceMaterialPaint: a paint stroke is already active.")
		return
	_stroke_active = true
	_stroke_before.clear()
	_stroke_slots_before.clear()
	if _stroke_rotations_before == null:
		_stroke_rotations_before = {}
	_stroke_rotations_before.clear()
	_stroke_max_weights.clear()


## Finish one stroke and return its exact sparse pixel-and-slot undo patches.
func finish_stroke() -> Dictionary:
	if not _stroke_active:
		return {}
	var patches: Dictionary = {}
	var changed_uids: Dictionary = {}
	for uid_value: Variant in _stroke_before.keys():
		changed_uids[uid_value] = true
	for uid_value: Variant in _stroke_slots_before.keys():
		changed_uids[uid_value] = true
	for uid_value: Variant in _stroke_rotations_before.keys():
		changed_uids[uid_value] = true
	for uid_value: Variant in changed_uids.keys():
		var uid := String(uid_value)
		var image := image_for_uid(uid)
		var before_by_pixel: Dictionary = _stroke_before.get(uid, {})
		var encoded_pixels := before_by_pixel.keys()
		encoded_pixels.sort()
		var pixels := PackedInt32Array()
		var before := PackedColorArray()
		var after := PackedColorArray()
		if image != null:
			for encoded_value: Variant in encoded_pixels:
				var encoded := int(encoded_value)
				var pixel := Vector2i(
					encoded % image.get_width(),
					floori(float(encoded) / float(image.get_width()))
				)
				pixels.append(encoded)
				before.append(before_by_pixel[encoded_value])
				after.append(image.get_pixel(pixel.x, pixel.y))
		var slots_before: PackedInt32Array = _stroke_slots_before.get(
			uid,
			palette_slots_for_uid(uid)
		)
		var rotations_before: PackedInt32Array = _stroke_rotations_before.get(
			uid,
			slot_rotations_for_uid(uid)
		)
		patches[uid] = {
			"resolution": image.get_size() if image != null else Vector2i.ZERO,
			"pixels": pixels,
			"before": before,
			"after": after,
			"slots_before": slots_before,
			"slots_after": palette_slots_for_uid(uid),
			"rotations_before": rotations_before,
			"rotations_after": slot_rotations_for_uid(uid),
		}
	_stroke_active = false
	_stroke_before.clear()
	_stroke_slots_before.clear()
	_stroke_rotations_before.clear()
	_stroke_max_weights.clear()
	if not patches.is_empty():
		palette_usage_changed.emit()
	return {"patches": patches} if not patches.is_empty() else {}


## Cancel the recorder without changing pixels when an external owner aborts input.
func cancel_stroke_recording() -> void:
	_stroke_active = false
	_stroke_before.clear()
	_stroke_slots_before.clear()
	_stroke_rotations_before.clear()
	_stroke_max_weights.clear()


## Apply one continuous circular brush segment in a placement's local metric plane.
##
## UV endpoints may remain outside this placement so one world-space stroke can cross tile
## seams without clamping into square edge stamps. The hot loop retains stroke dictionaries
## locally and skips pixels whose strongest influence did not increase.
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
	if profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot paint without a bound profile.")
		return false
	if (
		placement_uid.is_empty()
		or radius_m <= 0.0
		or opacity <= 0.0
		or not start_uv.is_finite()
		or not end_uv.is_finite()
	):
		return false
	var image := image_for_uid(placement_uid)
	var resolution := (
		image.get_size()
		if image != null
		else profile.paint_resolution(footprint_m)
	)
	if resolution.x <= 0 or resolution.y <= 0:
		push_error("MTSSurfaceMaterialPaint: invalid paint resolution for '%s'." % placement_uid)
		return false
	var width := resolution.x
	var height := resolution.y
	var footprint := Vector2(maxi(1, footprint_m.x), maxi(1, footprint_m.y))
	var start_m := start_uv * footprint
	var end_m := end_uv * footprint
	var minimum_m := start_m.min(end_m) - Vector2.ONE * radius_m
	var maximum_m := start_m.max(end_m) + Vector2.ONE * radius_m
	var x0 := clampi(floori(minimum_m.x / footprint.x * width), 0, width)
	var y0 := clampi(floori(minimum_m.y / footprint.y * height), 0, height)
	var x1 := clampi(ceili(maximum_m.x / footprint.x * width) + 1, 0, width)
	var y1 := clampi(ceili(maximum_m.y / footprint.y * height) + 1, 0, height)
	if x0 >= x1 or y0 >= y1:
		return false
	var slot_index := _ensure_palette_slot(placement_uid, palette_index, not erase)
	if slot_index < 0:
		return false
	var normalize_before_runtime_masks := not _layer_has_runtime_constraint(palette_index)
	var before_by_pixel: Dictionary = _stroke_before.get(placement_uid, {})
	var maximum_weights: Dictionary = _stroke_max_weights.get(placement_uid, {})
	var radius_squared := radius_m * radius_m
	var image_created := false
	var paint_reached_pixel := false
	var changed := false
	for y: int in range(y0, y1):
		for x: int in range(x0, x1):
			var point_m := Vector2(
				(float(x) + 0.5) / float(width) * footprint.x,
				(float(y) + 0.5) / float(height) * footprint.y
			)
			var distance_squared := _point_segment_distance_squared(
				point_m,
				start_m,
				end_m
			)
			if distance_squared >= radius_squared:
				continue
			var distance_ratio := sqrt(distance_squared) / maxf(radius_m, 0.0001)
			var weight := _falloff(distance_ratio, hardness) * clampf(opacity, 0.0, 1.0)
			if weight <= 0.0:
				continue
			paint_reached_pixel = true
			var encoded := y * width + x
			var maximum_weight := weight
			if _stroke_active:
				var previous_weight := float(maximum_weights.get(encoded, 0.0))
				if weight <= previous_weight:
					continue
				maximum_weights[encoded] = weight
			var current := (
				image.get_pixel(x, y)
				if image != null
				else Color(0.0, 0.0, 0.0, 0.0)
			)
			var original := current
			if _stroke_active:
				if before_by_pixel.has(encoded):
					original = before_by_pixel[encoded]
				else:
					before_by_pixel[encoded] = current
				maximum_weight = float(maximum_weights[encoded])
			var next := _painted_layer_color(
				original,
				slot_index,
				maximum_weight,
				erase,
				normalize_before_runtime_masks
			)
			if next == current:
				continue
			if image == null:
				image = Image.create(width, height, false, Image.FORMAT_RGBA8)
				image.fill(Color(0.0, 0.0, 0.0, 0.0))
				_images_by_uid[placement_uid] = image
				image_created = true
			image.set_pixel(x, y, next)
			changed = true
	if _stroke_active:
		if not before_by_pixel.is_empty():
			_stroke_before[placement_uid] = before_by_pixel
		if not maximum_weights.is_empty():
			_stroke_max_weights[placement_uid] = maximum_weights
	var rotation_changed := (
		_set_slot_rotation(placement_uid, slot_index, rotation_quarters)
		if paint_reached_pixel and not erase
		else false
	)
	if changed:
		var batch_texture_created := false
		if image_created:
			batch_texture_created = _ensure_registered_batch_texture(placement_uid)
		if not batch_texture_created:
			_dirty_uids[placement_uid] = true
		paint_changed.emit(placement_uid)
	return changed or rotation_changed


## Fill one selected material channel across a complete targeted terrain face.
##
## This writes only the structural painted gate. The material shader samples the selected
## layer's height, cavity, curvature, slope, and other world-space mask rules from their
## canonical fields, so tile targeting does not duplicate or bake the mask calculation.
func stamp_material_tile(
	placement_uid: String,
	palette_index: int,
	opacity: float,
	rotation_quarters: int,
	erase: bool
) -> bool:
	if profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot stamp a material tile without a profile.")
		return false
	if placement_uid.is_empty() or not _batch_key_by_uid.has(placement_uid):
		push_error(
			"MTSSurfaceMaterialPaint: material tile '%s' is not a registered terrain face."
			% placement_uid
		)
		return false
	var weight := clampf(opacity, 0.0, 1.0)
	if weight <= 0.0:
		return false
	var footprint := _registered_footprint(placement_uid)
	var image := image_for_uid(placement_uid)
	var resolution := (
		image.get_size()
		if image != null
		else profile.paint_resolution(footprint)
	)
	if resolution.x <= 0 or resolution.y <= 0:
		push_error(
			"MTSSurfaceMaterialPaint: material tile '%s' has an invalid resolution."
			% placement_uid
		)
		return false
	var selected_channel := _ensure_palette_slot(placement_uid, palette_index, not erase)
	if selected_channel < 0:
		return false
	var normalize_before_runtime_masks := not _layer_has_runtime_constraint(palette_index)
	var before_by_pixel: Dictionary = _stroke_before.get(placement_uid, {})
	var maximum_weights: Dictionary = _stroke_max_weights.get(placement_uid, {})
	var image_created := false
	var changed := false
	for y: int in resolution.y:
		for x: int in resolution.x:
			var encoded := y * resolution.x + x
			var maximum_weight := weight
			if _stroke_active:
				var previous_weight := float(maximum_weights.get(encoded, 0.0))
				if weight <= previous_weight:
					continue
				maximum_weights[encoded] = weight
			var current := (
				image.get_pixel(x, y)
				if image != null
				else Color(0.0, 0.0, 0.0, 0.0)
			)
			var original := current
			if _stroke_active:
				if before_by_pixel.has(encoded):
					original = before_by_pixel[encoded]
				else:
					before_by_pixel[encoded] = current
				maximum_weight = float(maximum_weights[encoded])
			var next := _painted_layer_color(
				original,
				selected_channel,
				maximum_weight,
				erase,
				normalize_before_runtime_masks
			)
			if next == current:
				continue
			if image == null:
				image = Image.create(
					resolution.x,
					resolution.y,
					false,
					Image.FORMAT_RGBA8
				)
				image.fill(Color(0.0, 0.0, 0.0, 0.0))
				_images_by_uid[placement_uid] = image
				image_created = true
			image.set_pixel(x, y, next)
			changed = true
	if _stroke_active:
		if not before_by_pixel.is_empty():
			_stroke_before[placement_uid] = before_by_pixel
		if not maximum_weights.is_empty():
			_stroke_max_weights[placement_uid] = maximum_weights
	var rotation_changed := (
		_set_slot_rotation(placement_uid, selected_channel, rotation_quarters)
		if not erase
		else false
	)
	if changed:
		var batch_texture_created := false
		if image_created:
			batch_texture_created = _ensure_registered_batch_texture(placement_uid)
		if not batch_texture_created:
			_dirty_uids[placement_uid] = true
		paint_changed.emit(placement_uid)
	return changed or rotation_changed


## Stamp one whole terrain tile with every RGBA weight from the loaded control-map template.
##
## The template contains only blend weights; every PBR texture and tiling value remains
## live on its assigned TileAsset, so asset-panel edits update existing splat paint.
func stamp_splatmap_tile(
	placement_uid: String,
	template_image: Image,
	palette_slots: PackedInt32Array,
	erase: bool
) -> bool:
	if profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot stamp a splat tile without a profile.")
		return false
	if placement_uid.is_empty() or not _batch_key_by_uid.has(placement_uid):
		push_error(
			"MTSSurfaceMaterialPaint: splat tile '%s' is not a registered terrain face."
			% placement_uid
		)
		return false
	if not erase and not set_splatmap_palette_slots(placement_uid, palette_slots):
		return false
	var image := image_for_uid(placement_uid)
	if erase and image == null:
		return false
	var resolution := (
		image.get_size()
		if image != null
		else template_image.get_size()
		if template_image != null
		else profile.paint_resolution(Vector2i.ONE)
	)
	if resolution.x <= 0 or resolution.y <= 0:
		push_error(
			"MTSSurfaceMaterialPaint: splat tile '%s' has an invalid resolution."
			% placement_uid
		)
		return false
	if template_image != null and template_image.get_size() != resolution:
		push_error(
			"MTSSurfaceMaterialPaint: splat template resolution %s does not match tile '%s' resolution %s."
			% [template_image.get_size(), placement_uid, resolution]
		)
		return false
	var before_by_pixel: Dictionary = _stroke_before.get(placement_uid, {})
	var image_created := false
	var changed := false
	for y: int in resolution.y:
		for x: int in resolution.x:
			var current := (
				image.get_pixel(x, y)
				if image != null
				else Color(0.0, 0.0, 0.0, 0.0)
			)
			var next := (
				Color(0.0, 0.0, 0.0, 0.0)
				if erase or template_image == null
				else template_image.get_pixel(x, y)
			)
			if next == current:
				continue
			var encoded := y * resolution.x + x
			if _stroke_active and not before_by_pixel.has(encoded):
				before_by_pixel[encoded] = current
			if image == null:
				image = Image.create(
					resolution.x,
					resolution.y,
					false,
					Image.FORMAT_RGBA8
				)
				image.fill(Color(0.0, 0.0, 0.0, 0.0))
				_images_by_uid[placement_uid] = image
				image_created = true
			image.set_pixel(x, y, next)
			changed = true
	if _stroke_active and not before_by_pixel.is_empty():
		_stroke_before[placement_uid] = before_by_pixel
	if changed:
		var batch_texture_created := false
		if image_created:
			batch_texture_created = _ensure_registered_batch_texture(placement_uid)
		if not batch_texture_created:
			_dirty_uids[placement_uid] = true
		paint_changed.emit(placement_uid)
	return changed


## Apply one sparse undo/redo payload and queue only affected pixels and batches.
func apply_patch(patches: Dictionary, value_key: String) -> void:
	if value_key != "before" and value_key != "after":
		push_error("MTSSurfaceMaterialPaint: patch value key must be 'before' or 'after'.")
		return
	for uid_value: Variant in patches.keys():
		var uid := String(uid_value)
		var patch: Dictionary = patches[uid_value]
		var resolution_value: Variant = patch.get("resolution", Vector2i.ZERO)
		var pixels_value: Variant = patch.get("pixels", PackedInt32Array())
		var colors_value: Variant = patch.get(value_key, PackedColorArray())
		var slots_value: Variant = patch.get(
			"slots_%s" % value_key,
			palette_slots_for_uid(uid)
		)
		var rotations_value: Variant = patch.get(
			"rotations_%s" % value_key,
			slot_rotations_for_uid(uid)
		)
		if (
			not resolution_value is Vector2i
			or not pixels_value is PackedInt32Array
			or not colors_value is PackedColorArray
			or not slots_value is PackedInt32Array
			or not rotations_value is PackedInt32Array
		):
			push_error("MTSSurfaceMaterialPaint: invalid sparse patch for '%s'." % uid)
			continue
		var slots: PackedInt32Array = slots_value
		var rotations: PackedInt32Array = rotations_value
		if (
			slots.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
			or rotations.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
		):
			push_error("MTSSurfaceMaterialPaint: undo material mapping is invalid for '%s'." % uid)
			continue
		_set_palette_slots(uid, slots, false)
		_set_slot_rotations(uid, rotations, false)
		var resolution: Vector2i = resolution_value
		var pixels: PackedInt32Array = pixels_value
		var colors: PackedColorArray = colors_value
		if pixels.size() != colors.size() or pixels.is_empty():
			continue
		var image := image_for_uid(uid)
		var batch_texture_created := false
		if image == null:
			image = Image.create(
				resolution.x,
				resolution.y,
				false,
				Image.FORMAT_RGBA8
			)
			image.fill(Color(0.0, 0.0, 0.0, 0.0))
			_images_by_uid[uid] = image
			batch_texture_created = _ensure_registered_batch_texture(uid)
		if image.get_size() != resolution:
			push_error("MTSSurfaceMaterialPaint: undo resolution does not match '%s'." % uid)
			continue
		for index: int in pixels.size():
			var encoded := pixels[index]
			var pixel := Vector2i(
				encoded % resolution.x,
				floori(float(encoded) / float(resolution.x))
			)
			image.set_pixel(pixel.x, pixel.y, colors[index])
		if value_key == "after" and not _image_has_weight(image):
			_images_by_uid.erase(uid)
			_dirty_uids.erase(uid)
			var batch_key := String(_batch_key_by_uid.get(uid, ""))
			if not batch_key.is_empty():
				_rebuild_batch_texture(batch_key)
				batch_texture_changed.emit(batch_key)
		else:
			if not batch_texture_created:
				_dirty_uids[uid] = true
		paint_changed.emit(uid)
	if not patches.is_empty():
		palette_usage_changed.emit()


## Upload every touched placement once for the current frame and nothing else.
func upload_dirty() -> int:
	var uploaded := 0
	var dirty := _dirty_uids.keys()
	_dirty_uids.clear()
	for uid_value: Variant in dirty:
		var uid := String(uid_value)
		var batch_key := String(_batch_key_by_uid.get(uid, ""))
		if batch_key.is_empty():
			continue
		var record: Dictionary = _batch_records.get(batch_key, {})
		var texture := record.get("texture", null) as Texture2DArray
		var layer_by_uid: Dictionary = record.get("layer_by_uid", {})
		var layer := int(layer_by_uid.get(uid, -1))
		var image := image_for_uid(uid)
		if texture == null or layer < 0 or image == null:
			continue
		texture.update_layer(image, layer)
		_refresh_instance_colors_for_uid(uid)
		uploaded += 1
		uploaded += _upload_seeded_layers(uid, image)
	return uploaded


## Save each authored placement image as an immutable checksummed PNG sidecar.
func save_sidecars(
	board_path: String,
	allowed_uids: Variant = null
) -> Dictionary:
	if board_path.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot save paint without a board path.")
		return {"error": ERR_INVALID_PARAMETER, "metadata": {}}
	var board_directory := board_path.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(board_directory)
	)
	if directory_error != OK:
		push_error(
			"MTSSurfaceMaterialPaint: cannot create paint sidecar directory '%s' (%s)."
			% [board_directory, error_string(directory_error)]
		)
		return {"error": directory_error, "metadata": {}}
	var entries: Array = []
	var uids := _images_by_uid.keys()
	uids.sort()
	var board_stem := board_path.get_file().get_basename()
	for uid_value: Variant in uids:
		var uid := String(uid_value)
		if allowed_uids is Dictionary and not (allowed_uids as Dictionary).has(uid):
			continue
		if not _uid_is_safe(uid):
			push_error("MTSSurfaceMaterialPaint: unsafe placement uid '%s'." % uid)
			return {"error": ERR_INVALID_DATA, "metadata": {}}
		var image := image_for_uid(uid)
		if image == null or image.is_empty():
			continue
		var png_bytes := image.save_png_to_buffer()
		if png_bytes.is_empty():
			push_error("MTSSurfaceMaterialPaint: cannot encode paint for '%s'." % uid)
			return {"error": ERR_CANT_CREATE, "metadata": {}}
		var checksum := _sha256_bytes(png_bytes)
		# The canonical face UID ("t:4,8") contains characters no filesystem accepts,
		# so the file is named by a hash of that identity while the metadata entry
		# below keeps the real UID. The identity hash makes the name stable per face
		# and the content hash keeps immutable pixels at a distinct path.
		var filename := "%s.paint.%s.%s.png" % [
			board_stem,
			_sha256_bytes(uid.to_utf8_buffer()).substr(0, 16),
			checksum.substr(0, 16),
		]
		var sidecar_path := board_directory.path_join(filename)
		if not FileAccess.file_exists(sidecar_path):
			var file := FileAccess.open(sidecar_path, FileAccess.WRITE)
			if file == null:
				var open_error := FileAccess.get_open_error()
				push_error(
					"MTSSurfaceMaterialPaint: cannot write '%s' (%s)."
					% [sidecar_path, error_string(open_error)]
				)
				return {"error": open_error, "metadata": {}}
			file.store_buffer(png_bytes)
			file.flush()
			var write_error := file.get_error()
			file.close()
			if write_error != OK:
				push_error(
					"MTSSurfaceMaterialPaint: cannot finish '%s' (%s)."
					% [sidecar_path, error_string(write_error)]
				)
				return {"error": write_error, "metadata": {}}
		var verification_bytes := FileAccess.get_file_as_bytes(sidecar_path)
		if _sha256_bytes(verification_bytes) != checksum:
			push_error("MTSSurfaceMaterialPaint: paint sidecar checksum failed for '%s'." % uid)
			return {"error": ERR_FILE_CORRUPT, "metadata": {}}
		entries.append({
			"uid": uid,
			"file": filename,
			"file_sha256": checksum,
			"resolution": [image.get_width(), image.get_height()],
		})
	var slot_entries: Array = []
	var mapped_uids := _palette_slots_by_uid.keys()
	mapped_uids.sort()
	for uid_value: Variant in mapped_uids:
		var uid := String(uid_value)
		if allowed_uids is Dictionary and not (allowed_uids as Dictionary).has(uid):
			continue
		if not _uid_is_safe(uid):
			push_error("MTSSurfaceMaterialPaint: unsafe palette-mapping uid '%s'." % uid)
			return {"error": ERR_INVALID_DATA, "metadata": {}}
		slot_entries.append({
			"uid": uid,
			"palette_indices": Array(palette_slots_for_uid(uid)),
			"rotation_quarters": Array(slot_rotations_for_uid(uid)),
		})
	return {
		"error": OK,
		"metadata": {
			"version": METADATA_VERSION,
			"surfaces": entries,
			"material_slots": slot_entries,
		},
	}


## Validate every saved paint image before any live authored pixels are replaced.
func prepare_sidecars(board_path: String, metadata: Dictionary) -> Dictionary:
	if metadata.is_empty():
		return {"error": OK, "images": {}, "palette_slots": {}, "slot_rotations": {}}
	var surfaces_value: Variant = metadata.get("surfaces", [])
	if not surfaces_value is Array:
		push_error("MTSSurfaceMaterialPaint: sidecar surfaces must be an array.")
		return {"error": ERR_INVALID_DATA}
	var prepared_images: Dictionary = {}
	for entry_value: Variant in (surfaces_value as Array):
		if not entry_value is Dictionary:
			push_error("MTSSurfaceMaterialPaint: sidecar entry must be an object.")
			return {"error": ERR_INVALID_DATA}
		var entry: Dictionary = entry_value
		var uid := String(entry.get("uid", ""))
		var filename := String(entry.get("file", ""))
		var expected_hash := String(entry.get("file_sha256", ""))
		var resolution_value: Variant = entry.get("resolution", [])
		if (
			not _uid_is_safe(uid)
			or filename.is_empty()
			or filename != filename.get_file()
			or expected_hash.is_empty()
			or not resolution_value is Array
			or (resolution_value as Array).size() != 2
			or prepared_images.has(uid)
		):
			push_error("MTSSurfaceMaterialPaint: invalid or duplicate sidecar entry '%s'." % uid)
			return {"error": ERR_INVALID_DATA}
		var sidecar_path := board_path.get_base_dir().path_join(filename)
		if not FileAccess.file_exists(sidecar_path):
			push_error("MTSSurfaceMaterialPaint: required sidecar '%s' is missing." % sidecar_path)
			return {"error": ERR_FILE_NOT_FOUND}
		var bytes := FileAccess.get_file_as_bytes(sidecar_path)
		if _sha256_bytes(bytes) != expected_hash:
			push_error("MTSSurfaceMaterialPaint: sidecar checksum failed for '%s'." % uid)
			return {"error": ERR_FILE_CORRUPT}
		var image := Image.new()
		var load_error := image.load_png_from_buffer(bytes)
		if load_error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot decode '%s' (%s)."
				% [sidecar_path, error_string(load_error)]
			)
			return {"error": load_error}
		var saved_resolution: Array = resolution_value
		if image.get_size() != Vector2i(
			int(saved_resolution[0]),
			int(saved_resolution[1])
		):
			push_error("MTSSurfaceMaterialPaint: sidecar resolution mismatch for '%s'." % uid)
			return {"error": ERR_INVALID_DATA}
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		prepared_images[uid] = image
	var material_slots_value: Variant = metadata.get("material_slots", [])
	if not material_slots_value is Array:
		push_error("MTSSurfaceMaterialPaint: material_slots must be an array.")
		return {"error": ERR_INVALID_DATA}
	var prepared_slots: Dictionary = {}
	var prepared_rotations: Dictionary = {}
	for entry_value: Variant in material_slots_value as Array:
		if not entry_value is Dictionary:
			push_error("MTSSurfaceMaterialPaint: material slot entry must be an object.")
			return {"error": ERR_INVALID_DATA}
		var entry: Dictionary = entry_value
		var uid := String(entry.get("uid", ""))
		var indices_value: Variant = entry.get("palette_indices", [])
		var rotations_value: Variant = entry.get("rotation_quarters", [0, 0, 0, 0])
		if (
			not _uid_is_safe(uid)
			or prepared_slots.has(uid)
			or not indices_value is Array
			or (indices_value as Array).size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
			or not rotations_value is Array
			or (rotations_value as Array).size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
		):
			push_error("MTSSurfaceMaterialPaint: invalid material slot entry '%s'." % uid)
			return {"error": ERR_INVALID_DATA}
		var slots := PackedInt32Array()
		for palette_value: Variant in indices_value as Array:
			var palette_index := int(palette_value)
			if palette_index < -1:
				push_error("MTSSurfaceMaterialPaint: invalid palette index on face '%s'." % uid)
				return {"error": ERR_INVALID_DATA}
			slots.append(palette_index)
		var rotations := PackedInt32Array()
		for rotation_value: Variant in rotations_value as Array:
			var rotation_quarters := int(rotation_value)
			if rotation_quarters < 0 or rotation_quarters > 3:
				push_error("MTSSurfaceMaterialPaint: invalid material orientation on face '%s'." % uid)
				return {"error": ERR_INVALID_DATA}
			rotations.append(rotation_quarters)
		prepared_slots[uid] = slots
		prepared_rotations[uid] = rotations
	return {
		"error": OK,
		"images": prepared_images,
		"palette_slots": prepared_slots,
		"slot_rotations": prepared_rotations,
	}


## Atomically replace authored paint after every referenced PNG passed validation.
func commit_prepared_sidecars(prepared: Dictionary) -> bool:
	if int(prepared.get("error", FAILED)) != OK:
		push_error("MTSSurfaceMaterialPaint: cannot commit invalid prepared paint.")
		return false
	var images_value: Variant = prepared.get("images", {})
	var palette_slots_value: Variant = prepared.get("palette_slots", {})
	var slot_rotations_value: Variant = prepared.get("slot_rotations", {})
	if (
		not images_value is Dictionary
		or not palette_slots_value is Dictionary
		or not slot_rotations_value is Dictionary
	):
		push_error("MTSSurfaceMaterialPaint: prepared paint images or material slots are invalid.")
		return false
	_images_by_uid = (images_value as Dictionary).duplicate()
	_palette_slots_by_uid = (palette_slots_value as Dictionary).duplicate(true)
	_slot_rotations_by_uid = (slot_rotations_value as Dictionary).duplicate(true)
	_dirty_uids.clear()
	_stroke_before.clear()
	_stroke_slots_before.clear()
	if _stroke_rotations_before == null:
		_stroke_rotations_before = {}
	_stroke_rotations_before.clear()
	_stroke_max_weights.clear()
	_stroke_active = false
	for key_value: Variant in _batch_records.keys():
		var key := String(key_value)
		_rebuild_batch_texture(key)
		batch_texture_changed.emit(key)
	palette_usage_changed.emit()
	return true




## Allocate a batch array when its first placement becomes painted and report whether it already contains the new pixels.
func _ensure_registered_batch_texture(placement_uid: String) -> bool:
	var batch_key := String(_batch_key_by_uid.get(placement_uid, ""))
	if batch_key.is_empty():
		return false
	var record: Dictionary = _batch_records.get(batch_key, {})
	if record.get("texture", null) != null:
		return false
	if not _rebuild_batch_texture(batch_key):
		return false
	batch_texture_changed.emit(batch_key)
	return true


## Rebuild one derived array after load or structural membership changes.
func _rebuild_batch_texture(batch_key: String) -> bool:
	var state := _build_batch_texture_state(batch_key, _images_by_uid)
	if int(state.get("error", FAILED)) != OK:
		return false
	_apply_batch_texture_state(batch_key, state)
	_refresh_batch_instance_colors(batch_key)
	return true


## Prepare every registered batch texture against one candidate canonical image dictionary.
func _prepare_image_replacement(prepared_images: Dictionary) -> Dictionary:
	for uid_value: Variant in prepared_images.keys():
		var uid := String(uid_value)
		if not _batch_key_by_uid.has(uid):
			push_error(
				"MTSSurfaceMaterialPaint: replacement contains unregistered placement '%s'."
				% uid
			)
			return {"error": ERR_DOES_NOT_EXIST}
	var batch_states: Dictionary = {}
	for key_value: Variant in _batch_records.keys():
		var batch_key := String(key_value)
		var state := _build_batch_texture_state(batch_key, prepared_images)
		if int(state.get("error", FAILED)) != OK:
			return {"error": int(state.get("error", FAILED))}
		batch_states[batch_key] = state
	return {
		"error": OK,
		"images": prepared_images,
		"batch_states": batch_states,
	}


## Build one Texture2DArray state without mutating its live batch record.
func _build_batch_texture_state(
	batch_key: String,
	images_by_uid: Dictionary
) -> Dictionary:
	if not _batch_records.has(batch_key):
		push_error("MTSSurfaceMaterialPaint: batch '%s' is not registered." % batch_key)
		return {"error": ERR_DOES_NOT_EXIST}
	var record: Dictionary = _batch_records[batch_key]
	var uids: PackedStringArray = record.get("uids", PackedStringArray())
	var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
	if not _batch_has_authored_paint_in(uids, images_by_uid, seed_uid_by_uid):
		return {
			"error": OK,
			"texture": null,
			"layer_by_uid": {},
			"resolution": Vector2i.ZERO,
		}
	var resolution := Vector2i.ZERO
	for uid: String in uids:
		var existing := _visible_image_for_uid(uid, images_by_uid, seed_uid_by_uid)
		if existing != null:
			resolution = existing.get_size()
			break
	if resolution.x <= 0 or resolution.y <= 0:
		push_error("MTSSurfaceMaterialPaint: batch '%s' has no valid paint resolution." % batch_key)
		return {"error": ERR_INVALID_DATA}
	var images: Array[Image] = []
	var layer_by_uid: Dictionary = {}
	for index: int in uids.size():
		var uid := uids[index]
		var image := _visible_image_for_uid(uid, images_by_uid, seed_uid_by_uid)
		if image == null:
			image = Image.create(
				resolution.x,
				resolution.y,
				false,
				Image.FORMAT_RGBA8
			)
			image.fill(Color(0.0, 0.0, 0.0, 0.0))
		elif image.get_size() != resolution:
			push_error(
				(
					"MTSSurfaceMaterialPaint: batch '%s' contains mixed paint resolutions; "
					+ "use the visible resolution rebuild before painting."
				) % batch_key
			)
			return {"error": ERR_INVALID_DATA}
		images.append(image)
		layer_by_uid[uid] = index
	var texture := Texture2DArray.new()
	var create_error := texture.create_from_images(images)
	if create_error != OK:
		push_error(
			"MTSSurfaceMaterialPaint: cannot create batch array '%s' (%s)."
			% [batch_key, error_string(create_error)]
		)
		return {"error": create_error}
	return {
		"error": OK,
		"texture": texture,
		"layer_by_uid": layer_by_uid,
		"resolution": resolution,
	}


## Replace only derived texture fields in one already-registered batch record.
func _apply_batch_texture_state(batch_key: String, state: Dictionary) -> void:
	var record: Dictionary = _batch_records[batch_key]
	record["texture"] = state.get("texture", null)
	record["layer_by_uid"] = state.get("layer_by_uid", {})
	record["resolution"] = state.get("resolution", Vector2i.ZERO)
	_batch_records[batch_key] = record


## Refresh every triangle's control fast-path metadata after a structural batch change.
func _refresh_batch_instance_colors(batch_key: String) -> void:
	var record: Dictionary = _batch_records.get(batch_key, {})
	var multimesh := record.get("multimesh", null) as MultiMesh
	if multimesh == null:
		return
	var indices_by_uid: Dictionary = record.get("instance_indices_by_uid", {})
	for uid_value: Variant in indices_by_uid.keys():
		_refresh_instance_colors_for_uid(String(uid_value))


## Refresh only the triangles owned by one changed face after a paint upload.
func _refresh_instance_colors_for_uid(placement_uid: String) -> void:
	var batch_key := String(_batch_key_by_uid.get(placement_uid, ""))
	var record: Dictionary = _batch_records.get(batch_key, {})
	var multimesh := record.get("multimesh", null) as MultiMesh
	if multimesh == null:
		return
	var indices_by_uid: Dictionary = record.get("instance_indices_by_uid", {})
	var indices_value: Variant = indices_by_uid.get(placement_uid, PackedInt32Array())
	if not indices_value is PackedInt32Array:
		return
	var color := instance_layer_color(batch_key, placement_uid)
	for instance_index: int in indices_value as PackedInt32Array:
		if instance_index >= 0 and instance_index < multimesh.instance_count:
			multimesh.set_instance_color(instance_index, color)


## Return the canonical metric footprint registered for one placement.
func _registered_footprint(placement_uid: String) -> Vector2i:
	var batch_key := String(_batch_key_by_uid.get(placement_uid, ""))
	if batch_key.is_empty() or not _batch_records.has(batch_key):
		return Vector2i.ZERO
	var record: Dictionary = _batch_records[batch_key]
	return record.get("footprint_m", Vector2i.ZERO) as Vector2i


## Return whether one registered batch has direct paint or an enabled derived side seed.
func _batch_has_authored_paint(
	uids: PackedStringArray,
	seed_uid_by_uid: Dictionary = {}
) -> bool:
	return _batch_has_authored_paint_in(uids, _images_by_uid, seed_uid_by_uid)


## Return whether the supplied image dictionary can visibly paint any batch placement.
func _batch_has_authored_paint_in(
	uids: PackedStringArray,
	images_by_uid: Dictionary,
	seed_uid_by_uid: Dictionary = {}
) -> bool:
	for uid: String in uids:
		if _visible_image_for_uid(uid, images_by_uid, seed_uid_by_uid) != null:
			return true
	return false


## Return a face's manual paint first, otherwise its explicit thin-side source image.
##
## The caller supplies seed mappings only while the visible board option is enabled.
## This keeps the full square canonical, lets manual sliver paint override it, and
## avoids copying another independent paint image into the board.
func _visible_image_for_uid(
	uid: String,
	images_by_uid: Dictionary,
	seed_uid_by_uid: Dictionary
) -> Image:
	var manual_image := images_by_uid.get(uid, null) as Image
	if manual_image != null:
		return manual_image
	var seed_uid := String(seed_uid_by_uid.get(uid, ""))
	return images_by_uid.get(seed_uid, null) as Image if not seed_uid.is_empty() else null


## Upload every unpainted thin-side layer that visibly resolves from one changed source image.
func _upload_seeded_layers(source_uid: String, source_image: Image) -> int:
	var uploaded := 0
	for record_value: Variant in _batch_records.values():
		var record: Dictionary = record_value
		var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
		var texture := record.get("texture", null) as Texture2DArray
		var layer_by_uid: Dictionary = record.get("layer_by_uid", {})
		if texture == null:
			continue
		for target_value: Variant in seed_uid_by_uid.keys():
			var target_uid := String(target_value)
			if (
				String(seed_uid_by_uid[target_value]) != source_uid
				or _images_by_uid.has(target_uid)
			):
				continue
			var layer := int(layer_by_uid.get(target_uid, -1))
			if layer < 0:
				continue
			texture.update_layer(source_image, layer)
			_refresh_instance_colors_for_uid(target_uid)
			uploaded += 1
	return uploaded


## Rebuild every derived batch that loses an explicit thin-side source image.
func _rebuild_seeded_batches_for_source(source_uid: String) -> void:
	for batch_key_value: Variant in _batch_records.keys():
		var batch_key := String(batch_key_value)
		var record: Dictionary = _batch_records[batch_key]
		var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
		for target_value: Variant in seed_uid_by_uid.keys():
			if String(seed_uid_by_uid[target_value]) != source_uid:
				continue
			_rebuild_batch_texture(batch_key)
			batch_texture_changed.emit(batch_key)
			break




## Report whether this layer has a shader-evaluated constraint beyond its paint gate.
##
## Such a constraint is only known per rendered texel, so changing competing paint
## channels here would destroy their authored weights before that mask is evaluated.
func _layer_has_runtime_constraint(palette_index: int) -> bool:
	if profile == null:
		return false
	for rule_value: Variant in profile.layer_masks(palette_index):
		if not rule_value is Dictionary:
			continue
		var rule: Dictionary = rule_value
		if int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT)) != MaterialBlendProfile.MaskSource.PAINT:
			return true
	return false


## Choose whether normalization is safe before the shader evaluates runtime masks.
func _painted_layer_color(
	original: Color,
	channel: int,
	weight: float,
	erase: bool,
	normalize_before_runtime_masks: bool
) -> Color:
	if (
		profile != null
		and profile.blend_mode == MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
		and normalize_before_runtime_masks
	):
		return _normalized_splat_color(original, channel, weight, erase)
	return _independent_layer_color(original, channel, weight, erase)


## Blend one independent channel toward paint or erase using the original pixel.
func _independent_layer_color(
	original: Color,
	channel: int,
	weight: float,
	erase: bool
) -> Color:
	var target := 0.0 if erase else 1.0
	return _color_with_component(
		original,
		clampi(channel, 0, 3),
		lerpf(_color_component(original, channel), target, clampf(weight, 0.0, 1.0))
	)


## Rebalance all competing weights while leaving the base material as implicit remainder.
func _normalized_splat_color(
	original: Color,
	channel: int,
	weight: float,
	erase: bool
) -> Color:
	var selected := clampi(channel, 0, 3)
	var values := [
		clampf(original.r, 0.0, 1.0),
		clampf(original.g, 0.0, 1.0),
		clampf(original.b, 0.0, 1.0),
		clampf(original.a, 0.0, 1.0),
	]
	var original_selected := float(values[selected])
	var next_selected := lerpf(
		original_selected,
		0.0 if erase else 1.0,
		clampf(weight, 0.0, 1.0)
	)
	if erase:
		values[selected] = next_selected
		return Color(values[0], values[1], values[2], values[3])
	var other_total := 0.0
	for index: int in values.size():
		if index != selected:
			other_total += float(values[index])
	var base_weight := maxf(0.0, 1.0 - original_selected - other_total)
	var remaining := maxf(0.0, 1.0 - next_selected)
	var previous_remaining := other_total + base_weight
	var ratio := remaining / previous_remaining if previous_remaining > 0.000001 else 0.0
	for index: int in values.size():
		if index != selected:
			values[index] = float(values[index]) * ratio
	values[selected] = next_selected
	return Color(values[0], values[1], values[2], values[3])


## Return one Color component selected by the visible RGBA palette slot.
func _color_component(color: Color, component: int) -> float:
	match clampi(component, 0, 3):
		0:
			return color.r
		1:
			return color.g
		2:
			return color.b
		_:
			return color.a


## Return a Color with exactly one RGBA component replaced.
func _color_with_component(color: Color, component: int, value: float) -> Color:
	match clampi(component, 0, 3):
		0:
			color.r = value
		1:
			color.g = value
		2:
			color.b = value
		_:
			color.a = value
	return color


## Convert a normalized brush distance into one continuous hardness falloff.
func _falloff(distance_ratio: float, hardness: float) -> float:
	if distance_ratio >= 1.0:
		return 0.0
	var clamped_hardness := clampf(hardness, 0.0, 1.0)
	var soft_start := lerpf(0.0, 0.92, clamped_hardness)
	if distance_ratio <= soft_start:
		return 1.0
	var edge_ratio := (
		(distance_ratio - soft_start)
		/ maxf(1.0 - soft_start, 0.0001)
	)
	return 1.0 - edge_ratio * edge_ratio * (3.0 - 2.0 * edge_ratio)


## Return squared metric distance from one point to a finite stroke segment.
##
## The hot loop rejects pixels outside the exact capsule before paying for a square root.
func _point_segment_distance_squared(
	point: Vector2,
	start: Vector2,
	finish: Vector2
) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0000001:
		return point.distance_squared_to(start)
	var ratio := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * ratio)


## Return the SHA-256 checksum that binds immutable PNG bytes to board JSON.
func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	var start_error := context.start(HashingContext.HASH_SHA256)
	if start_error != OK:
		push_error("MTSSurfaceMaterialPaint: cannot initialize SHA-256.")
		return ""
	var update_error := context.update(bytes)
	if update_error != OK:
		push_error("MTSSurfaceMaterialPaint: cannot hash paint bytes.")
		return ""
	return context.finish().hex_encode()


## Accept exactly the canonical TerrainMesh face identities and reject anything else.
##
## Paint is keyed by the sculpt-stable face UIDs minted in TerrainMesh: "t:X,Z" for a
## cell top, "s:X,Z,edge,band" for an internal side band, and "k:X,Z,edge,band" for a
## boundary-skirt band. Those identities contain ':' and ',' which can never appear in a
## filename, so sidecars are named by checksum and this check validates identity only.
func _uid_is_safe(uid: String) -> bool:
	if uid.is_empty():
		return false
	var parts := uid.split(":")
	if parts.size() != 2:
		return false
	var fields := parts[1].split(",")
	match parts[0]:
		"t":
			if fields.size() != 2:
				return false
		"s", "k":
			if fields.size() != 4:
				return false
		_:
			return false
	for field: String in fields:
		if field.is_empty():
			return false
		# Cell coordinates are signed because the authored footprint may extend
		# into negative lattice space; band and edge indices are never negative.
		var digits := field.substr(1) if field.begins_with("-") else field
		if digits.is_empty() or not digits.is_valid_int():
			return false
	return true
