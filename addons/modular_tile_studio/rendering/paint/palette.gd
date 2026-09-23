@tool
extends RefCounted

## Palette behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Bind the visible board profile that defines resolution and splat behavior.
static func bind_profile(host: MTSSurfaceMaterialPaint, value: MaterialBlendProfile) -> void:
	host.profile = value


## Return the four palette entries represented by one terrain face's RGBA image.
##
## A face without an explicit record derives the historical identity mapping once:
## old boards stored channel N as palette entry N. Registration persists that result
## in memory, and the next explicit board save writes it into metadata version 2.
static func palette_slots_for_uid(host: MTSSurfaceMaterialPaint, placement_uid: String) -> PackedInt32Array:
	var saved_value: Variant = host._palette_slots_by_uid.get(placement_uid, null)
	if saved_value is PackedInt32Array:
		return (saved_value as PackedInt32Array).duplicate()
	return host._default_palette_slots()


## Return the four clockwise PNG quarter-turns assigned to one face's local material slots.
static func slot_rotations_for_uid(host: MTSSurfaceMaterialPaint, placement_uid: String) -> PackedInt32Array:
	if host._slot_rotations_by_uid == null:
		host._slot_rotations_by_uid = {}
	var saved_value: Variant = host._slot_rotations_by_uid.get(placement_uid, null)
	if saved_value is PackedInt32Array:
		return (saved_value as PackedInt32Array).duplicate()
	return PackedInt32Array([0, 0, 0, 0])


## Return only palette entries that can currently affect at least one registered terrain face.
##
## Brush entries require a nonzero authored RGBA weight. Procedural entries require an
## explicit face mapping because their rules can render without any authored paint pixels.
static func used_palette_indices(host: MTSSurfaceMaterialPaint) -> PackedInt32Array:
	return host.used_palette_indices_for_profile(host.profile)


## Return the painted or procedurally assigned palette entries for one candidate profile.
##
## Profile-change planning compares the old and new recipes against the same canonical
## paint images, so an unused material can be edited without touching any live batch.
static func used_palette_indices_for_profile(host: MTSSurfaceMaterialPaint,
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
	for uid_value: Variant in host._palette_slots_by_uid.keys():
		var uid := String(uid_value)
		if not host._batch_key_by_uid.has(uid):
			continue
		var slots_value: Variant = host._palette_slots_by_uid[uid_value]
		if not slots_value is PackedInt32Array:
			continue
		for palette_index: int in slots_value:
			if procedural_candidates.has(palette_index):
				used[palette_index] = true
	var remaining_brush_entries := brush_candidates.duplicate()
	for uid_value: Variant in host._images_by_uid.keys():
		if remaining_brush_entries.is_empty():
			break
		var uid := String(uid_value)
		if not host._batch_key_by_uid.has(uid):
			continue
		var image := host.image_for_uid(uid)
		if image == null or image.is_empty():
			continue
		var slots := host.palette_slots_for_uid(uid)
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
static func _default_palette_slots(host: MTSSurfaceMaterialPaint) -> PackedInt32Array:
	var slots := PackedInt32Array([-1, -1, -1, -1])
	if host.profile == null:
		return slots
	for slot_index: int in mini(
		MaterialBlendProfile.WEIGHTS_PER_TEXEL,
		host.profile.layer_count()
	):
		slots[slot_index] = slot_index
	return slots


## Persist one face's derived mapping in runtime state without announcing a change.
static func _ensure_palette_slots(host: MTSSurfaceMaterialPaint, placement_uid: String) -> PackedInt32Array:
	var slots := host.palette_slots_for_uid(placement_uid)
	host._palette_slots_by_uid[placement_uid] = slots.duplicate()
	# Existing @tool instances acquire newly declared members as null during hot reload,
	# so initialize the canonical dictionary before the editor resumes terrain rendering.
	if host._slot_rotations_by_uid == null:
		host._slot_rotations_by_uid = {}
	if not host._slot_rotations_by_uid.has(placement_uid):
		host._slot_rotations_by_uid[placement_uid] = host.slot_rotations_for_uid(placement_uid)
	return slots


## Replace one face's exact slot orientations and announce derived instance-data invalidation.
static func _set_slot_rotations(host: MTSSurfaceMaterialPaint,
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
	var before := host.slot_rotations_for_uid(placement_uid)
	if before == normalized:
		host._slot_rotations_by_uid[placement_uid] = normalized
		return false
	if host._stroke_active and record_stroke and not host._stroke_rotations_before.has(placement_uid):
		host._stroke_rotations_before[placement_uid] = before
	host._slot_rotations_by_uid[placement_uid] = normalized
	host.palette_slots_changed.emit(placement_uid)
	return true


## Set one face-local material slot to the selected regular PNG brush orientation.
static func _set_slot_rotation(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	slot_index: int,
	rotation_quarters: int,
	record_stroke: bool = true
) -> bool:
	if slot_index < 0 or slot_index >= MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: material slot orientation index is invalid.")
		return false
	var rotations := host.slot_rotations_for_uid(placement_uid)
	rotations[slot_index] = posmod(rotation_quarters, 4)
	return host._set_slot_rotations(placement_uid, rotations, record_stroke)


## Establish one rendered face's canonical mapping before the renderer chooses its batch.
##
## Thin auto-textured sides share their source face's weights and therefore share its
## palette mapping until the side receives its own manual paint image.
static func register_face_palette(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	seed_uid: String = ""
) -> PackedInt32Array:
	if not seed_uid.is_empty() and seed_uid != placement_uid and not host.has_image(placement_uid):
		host._palette_slots_by_uid[placement_uid] = host.palette_slots_for_uid(seed_uid)
		host._slot_rotations_by_uid[placement_uid] = host.slot_rotations_for_uid(seed_uid)
	return host._ensure_palette_slots(placement_uid)


## Return one stable batch-key fragment for the face's exact RGBA palette meaning.
static func palette_slots_key(host: MTSSurfaceMaterialPaint, placement_uid: String) -> String:
	var slots := host.palette_slots_for_uid(placement_uid)
	return "%d:%d:%d:%d" % [slots[0], slots[1], slots[2], slots[3]]


## Return the local RGBA component already carrying one palette entry.
static func weight_slot_for_palette(host: MTSSurfaceMaterialPaint, placement_uid: String, palette_index: int) -> int:
	if palette_index < 0:
		return -1
	return host.palette_slots_for_uid(placement_uid).find(palette_index)


## Return whether one face-local component contains any authored weight.
static func _slot_has_weight(host: MTSSurfaceMaterialPaint, placement_uid: String, slot_index: int) -> bool:
	var image := host.image_for_uid(placement_uid)
	if image == null:
		return false
	for y: int in image.get_height():
		for x: int in image.get_width():
			if host._color_component(image.get_pixel(x, y), slot_index) > 0.0:
				return true
	return false


## Return a replaceable local slot, preferring an explicitly unused one.
static func _available_palette_slot(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	slots: PackedInt32Array
) -> int:
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		if slots[slot_index] < 0:
			return slot_index
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		if not host._slot_has_weight(placement_uid, slot_index):
			return slot_index
	return -1


## Replace one face's exact four-entry mapping and announce derived batch invalidation.
static func _set_palette_slots(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	slots: PackedInt32Array,
	record_stroke: bool = true
) -> bool:
	if placement_uid.is_empty() or slots.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: a face palette mapping requires one UID and four indices.")
		return false
	var before := host.palette_slots_for_uid(placement_uid)
	if before == slots:
		host._palette_slots_by_uid[placement_uid] = slots.duplicate()
		return false
	if host._stroke_active and record_stroke and not host._stroke_slots_before.has(placement_uid):
		host._stroke_slots_before[placement_uid] = before.duplicate()
	host._palette_slots_by_uid[placement_uid] = slots.duplicate()
	host.palette_slots_changed.emit(placement_uid)
	return true


## Resolve or allocate the local RGBA slot used to paint one palette material.
##
## A face accepts a new palette entry only when one component is unused across the
## complete face image. Refusing a full face preserves its four existing materials
## and makes the actual per-cell limit visible instead of overwriting authored paint.
static func _ensure_palette_slot(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	palette_index: int,
	allow_allocate: bool
) -> int:
	if host.profile == null or palette_index < 0 or palette_index >= host.profile.layer_count():
		push_error(
			"MTSSurfaceMaterialPaint: palette index %d is not present on the active board."
			% palette_index
		)
		return -1
	var slots := host._ensure_palette_slots(placement_uid)
	var existing := slots.find(palette_index)
	if existing >= 0 or not allow_allocate:
		return existing
	var available := host._available_palette_slot(placement_uid, slots)
	if available < 0:
		push_error(
			"MTSSurfaceMaterialPaint: terrain face '%s' already uses all four material slots."
			% placement_uid
		)
		return -1
	slots[available] = palette_index
	host._set_palette_slots(placement_uid, slots)
	return available


## Assign one procedural palette entry to every supplied face as one preflighted change.
##
## No face is mutated unless every face has a free zero-weight slot, so a failed
## level pass cannot leave a partial material assignment behind.
static func assign_palette_to_faces(host: MTSSurfaceMaterialPaint,
	palette_index: int,
	placement_uids: PackedStringArray
) -> Dictionary:
	var after_by_uid: Dictionary = {}
	for placement_uid: String in placement_uids:
		var slots := host.palette_slots_for_uid(placement_uid)
		if slots.find(palette_index) >= 0:
			continue
		var available := host._available_palette_slot(placement_uid, slots)
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
		var before := host.palette_slots_for_uid(placement_uid)
		var after: PackedInt32Array = after_by_uid[uid_value]
		patches[placement_uid] = {
			"resolution": Vector2i.ZERO,
			"pixels": PackedInt32Array(),
			"before": PackedColorArray(),
			"after": PackedColorArray(),
			"slots_before": before,
			"slots_after": after,
			"rotations_before": host.slot_rotations_for_uid(placement_uid),
			"rotations_after": host.slot_rotations_for_uid(placement_uid),
		}
		host._set_palette_slots(placement_uid, after, false)
	if not patches.is_empty():
		host.palette_usage_changed.emit()
	return {"error": OK, "face_uid": "", "patches": patches}


## Set the literal R/G/B/A palette meaning before a splatmap replaces a face's weights.
static func set_splatmap_palette_slots(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	slots: PackedInt32Array
) -> bool:
	if host.profile == null or slots.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error(
			"MTSSurfaceMaterialPaint: splatmap face '%s' requires four palette mappings."
			% placement_uid
		)
		return false
	for palette_index: int in slots:
		# Minus one explicitly disables an unused RGBA component; every non-empty
		# component must name an existing entry in the board palette.
		if palette_index < -1 or palette_index >= host.profile.layer_count():
			push_error(
				"MTSSurfaceMaterialPaint: splatmap face '%s' has an invalid palette mapping."
				% placement_uid
			)
			return false
	host._set_palette_slots(placement_uid, slots)
	return true
