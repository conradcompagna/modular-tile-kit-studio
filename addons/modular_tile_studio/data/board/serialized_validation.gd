@tool
extends RefCounted

## Serialized validation behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

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
			if not BoardDocument._serialized_string_is_present(surface_record, "asset"):
				errors.append("surfaces[%d] has no asset" % index)
			if not BoardDocument._serialized_vector_is_valid(surface_record, "origin", 3):
				errors.append("surfaces[%d] has no three-component origin" % index)
			if not BoardDocument._serialized_string_is_present(surface_record, "face"):
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
			if not BoardDocument._serialized_string_is_present(prop_record, "asset"):
				errors.append("props[%d] has no asset" % index)
			if not BoardDocument._serialized_vector_is_valid(prop_record, "origin", 3):
				errors.append("props[%d] has no three-component origin" % index)
			var has_forward := BoardDocument._serialized_string_is_present(prop_record, "forward")
			var has_legacy_facing := BoardDocument._serialized_string_is_present(prop_record, "facing")
			if not has_forward and not has_legacy_facing:
				errors.append("props[%d] has no forward or legacy facing" % index)

	var enemy_pack_records_value: Variant = data.get("enemy_packs", [])
	if enemy_pack_records_value is Array:
		var enemy_pack_records: Array = enemy_pack_records_value
		for index: int in enemy_pack_records.size():
			if enemy_pack_records[index] is Dictionary:
				if not BoardDocument._serialized_string_is_present(enemy_pack_records[index], "id"):
					errors.append("enemy_packs[%d] has no id" % index)

	var marker_records_value: Variant = data.get("gameplay_markers", [])
	if marker_records_value is Array:
		var marker_records: Array = marker_records_value
		for index: int in marker_records.size():
			if not (marker_records[index] is Dictionary):
				continue
			var marker_record: Dictionary = marker_records[index]
			if not BoardDocument._serialized_string_is_present(marker_record, "id"):
				errors.append("gameplay_markers[%d] has no id" % index)
			if not BoardDocument._serialized_string_is_present(marker_record, "type"):
				errors.append("gameplay_markers[%d] has no type" % index)
			if not BoardDocument._serialized_vector_is_valid(marker_record, "origin", 3):
				errors.append("gameplay_markers[%d] has no three-component origin" % index)

	var particle_records_value: Variant = data.get("particle_effects", [])
	if particle_records_value is Array:
		var particle_records: Array = particle_records_value
		for index: int in particle_records.size():
			if not (particle_records[index] is Dictionary):
				continue
			var particle_record: Dictionary = particle_records[index]
			if not BoardDocument._serialized_string_is_present(particle_record, "placement_id"):
				errors.append("particle_effects[%d] has no placement_id" % index)
			if not BoardDocument._serialized_string_is_present(particle_record, "preset_id"):
				errors.append("particle_effects[%d] has no preset_id" % index)
			if not BoardDocument._serialized_vector_is_valid(particle_record, "position", 3):
				errors.append("particle_effects[%d] has no three-component position" % index)

	var monster_visual_records_value: Variant = data.get("monster_visuals", [])
	if monster_visual_records_value is Array:
		var monster_visual_records: Array = monster_visual_records_value
		for index: int in monster_visual_records.size():
			if not (monster_visual_records[index] is Dictionary):
				continue
			var monster_visual_record: Dictionary = monster_visual_records[index]
			if not BoardDocument._serialized_string_is_present(monster_visual_record, "monster"):
				errors.append("monster_visuals[%d] has no monster id" % index)
			if not BoardDocument._serialized_string_is_present(monster_visual_record, "asset"):
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
				if not BoardDocument._serialized_string_is_present(entry, "file"):
					errors.append("surface material paint '%s' has no file" % uid)
				if not BoardDocument._serialized_string_is_present(entry, "file_sha256"):
					errors.append("surface material paint '%s' has no checksum" % uid)
				if not BoardDocument._serialized_vector_is_valid(entry, "resolution", 2):
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
			if int(data.get("version", 1)) >= BoardDocument.FORMAT_VERSION:
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
				if not BoardDocument._serialized_vector_is_valid(effect_record, "cell", 2):
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
					> BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH
				):
					errors.append(
						"movement_grid.ground_effects[%d] label exceeds %d characters"
						% [index, BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH]
					)

	for profile_name: String in ["material_blend", "aesthetics", "lighting"]:
		if data.has(profile_name) and not (data[profile_name] is Dictionary):
			errors.append("'%s' must be an object" % profile_name)
	return errors
