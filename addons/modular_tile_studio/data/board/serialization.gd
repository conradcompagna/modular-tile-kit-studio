@tool
extends RefCounted

## Serialization behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Serialize board-owned movement rules in stable coordinate order.
static func movement_grid_to_json(host: BoardDocument) -> Dictionary:
	var unwalkable_records: Array = []
	for cell: Vector2i in host._sorted_movement_cells(host.movement_unwalkable_cells):
		unwalkable_records.append([cell.x, cell.y])
	var effect_records: Array = []
	for cell: Vector2i in host._sorted_movement_cells(host.movement_ground_effects):
		effect_records.append({
			"cell": [cell.x, cell.y],
			"label": host.movement_ground_effect(cell),
		})
	return {
		"collision_min_triangle_share_percent": (
			host.movement_collision_min_triangle_share_percent
		),
		"unwalkable_cells": unwalkable_records,
		"ground_effects": effect_records,
	}


## Serialize the complete portable board with one canonical reference per placement.
static func to_json(host: BoardDocument) -> Dictionary:
	var surface_list: Array = []
	for placement: SurfacePlacement in host.surfaces:
		surface_list.append(placement.to_json())
	var prop_list: Array = []
	for placement: PropPlacement in host.props:
		prop_list.append(placement.to_json())
	var pack_list: Array = []
	for pack: EnemyPack in host.enemy_packs:
		pack_list.append(pack.to_json())
	var marker_list: Array = []
	for marker: GameplayMarker in host.gameplay_markers:
		marker_list.append(marker.to_json())
	var particle_effect_list: Array = []
	for effect: ParticleEffectPlacement in host.particle_effects:
		particle_effect_list.append(effect.to_json())
	var monster_visual_list: Array = []
	var monster_ids: Array = host.monster_visual_assets.keys()
	monster_ids.sort()
	for monster_value: Variant in monster_ids:
		monster_visual_list.append({
			"monster": monster_value,
			"asset": host.monster_visual_assets[monster_value],
		})
	# Written out as a plain JSON array of ids, in import order, so the record is
	# readable by anything that parses the board format rather than only by Godot.
	var imported_asset_list: Array = []
	for imported_id: String in host.imported_asset_ids:
		imported_asset_list.append(imported_id)
	return {
		"version": BoardDocument.FORMAT_VERSION,
		"name": host.board_name,
		"biome": host.biome,
		"surfaces": surface_list,
		"props": prop_list,
		"enemy_packs": pack_list,
		"gameplay_markers": marker_list,
		"particle_effects": particle_effect_list,
		"monster_visuals": monster_visual_list,
		"imported_assets": imported_asset_list,
		"terrain": host.terrain.to_json(),
		"movement_grid": host.movement_grid_to_json(),
		"surface_material_paint": host.surface_material_paint.duplicate(true),
		"material_blend": host.material_blend.to_json(),
		"aesthetics": host.aesthetics.to_json(),
		"lighting": host.lighting.to_json(),
	}


## Report any authored-array count changed by serialization before the staged write begins.
static func _serialized_count_errors(host: BoardDocument, data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var expected_counts := {
		"surfaces": host.surfaces.size(),
		"props": host.props.size(),
		"enemy_packs": host.enemy_packs.size(),
		"gameplay_markers": host.gameplay_markers.size(),
		"particle_effects": host.particle_effects.size(),
		"monster_visuals": host.monster_visual_assets.size(),
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
static func from_json(host: BoardDocument, data: Dictionary) -> Error:
	return host._replace_from_json(data, true)


## Replace this document from parsed JSON with optional final notifications.
##
## Validation precedes every mutation, and detached candidates disable signals so
## no UI or viewport work occurs while a selected board is still being prepared.
static func _replace_from_json(host: BoardDocument, data: Dictionary, notify_change: bool) -> Error:
	var persistence_errors := BoardDocument.serialized_data_errors(data)
	if not persistence_errors.is_empty():
		push_error(
			"BoardDocument: refusing invalid board data; live board preserved: %s"
			% "; ".join(persistence_errors)
		)
		return ERR_INVALID_DATA
	host._clear_state()
	var loaded_version := int(data.get("version", 1))
	host.version = loaded_version
	host.board_name = String(data.get("name", "Untitled Board"))
	host.biome = String(data.get("biome", ""))
	var movement_value: Variant = data.get("movement_grid", {})
	if movement_value is Dictionary:
		var movement_data := movement_value as Dictionary
		host.movement_collision_min_triangle_share_percent = float(
			movement_data.get("collision_min_triangle_share_percent", 0.0)
		)
		for cell_value: Variant in movement_data.get("unwalkable_cells", []):
			var cell_array := cell_value as Array
			var cell := Vector2i(int(cell_array[0]), int(cell_array[1]))
			host.movement_unwalkable_cells[BoardDocument.movement_cell_key(cell)] = true
		for effect_value: Variant in movement_data.get("ground_effects", []):
			var effect_record := effect_value as Dictionary
			var effect_cell_array := effect_record["cell"] as Array
			var effect_cell := Vector2i(
				int(effect_cell_array[0]),
				int(effect_cell_array[1])
			)
			host.movement_ground_effects[BoardDocument.movement_cell_key(effect_cell)] = (
				String(effect_record["label"]).strip_edges()
			)
	var paint_value: Variant = data.get("surface_material_paint", {})
	if paint_value is Dictionary:
		host.surface_material_paint = (paint_value as Dictionary).duplicate(true)
	var material_blend_value: Variant = data.get("material_blend", {})
	host.material_blend.from_json(
		material_blend_value if material_blend_value is Dictionary else {}
	)

	for entry: Variant in data.get("surfaces", []):
		if entry is Dictionary:
			host.surfaces.append(SurfacePlacement.from_json(entry))
	for entry: Variant in data.get("props", []):
		if entry is Dictionary:
			host.props.append(PropPlacement.from_json(entry))
	var enemy_pack_script: Script = load(
		"res://addons/modular_tile_studio/data/enemy_pack.gd"
	)
	for entry: Variant in data.get("enemy_packs", []):
		if entry is Dictionary:
			host.enemy_packs.append(enemy_pack_script.from_json(entry) as EnemyPack)
	var gameplay_marker_script: Script = load(
		"res://addons/modular_tile_studio/data/gameplay_marker.gd"
	)
	for entry: Variant in data.get("gameplay_markers", []):
		if entry is Dictionary:
			host.gameplay_markers.append(
				gameplay_marker_script.from_json(entry) as GameplayMarker
			)
	var particle_placement_script: Script = load(
		"res://addons/modular_tile_studio/data/particle_effect_placement.gd"
	)
	for entry: Variant in data.get("particle_effects", []):
		if entry is Dictionary:
			var effect := particle_placement_script.new() as ParticleEffectPlacement
			if effect.load_json(entry):
				host.particle_effects.append(effect)
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
		host.monster_visual_assets[visual_data["monster"]] = visual_data["asset"]
	for entry: Variant in data.get("imported_assets", []):
		# Ids are recorded, never resolved here: an import whose asset has since been
		# deleted must load quietly and disappear from the level view rather than
		# fail a board that is otherwise intact.
		host.imported_asset_ids.append(String(entry))

	# A board saved before the tactical terrain rework simply has no footprint
	# drawn yet. That is a valid empty encounter surface, not a missing file.
	var terrain_data: Variant = data.get("terrain", null)
	if terrain_data is Dictionary:
		host.terrain = TerrainMesh.from_json(terrain_data)
		var terrain_errors := host.terrain.validate_definition()
		if not terrain_errors.is_empty():
			for terrain_error: String in terrain_errors:
				push_error("BoardDocument: terrain %s" % terrain_error)
			return ERR_INVALID_DATA
	else:
		host.terrain = TerrainMesh.new()
	var aesthetics_data: Variant = data.get("aesthetics", {})
	host.aesthetics.from_json(aesthetics_data if aesthetics_data is Dictionary else {})
	var lighting_data: Variant = data.get("lighting", {})
	host.lighting.from_json(lighting_data if lighting_data is Dictionary else {})

	host.version = BoardDocument.FORMAT_VERSION
	host.rebuild_indexes()
	if notify_change:
		host.board_changed.emit()
		host.look_changed.emit()
	return OK


## Parse and validate one ordinary board into detached state without touching the live document.
static func prepare_json(host: BoardDocument, data: Dictionary) -> Dictionary:
	var candidate := BoardDocument.new()
	candidate._library = host._library
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
static func commit_prepared_load(host: BoardDocument, source: BoardDocument) -> bool:
	if source == null:
		push_error("BoardDocument: cannot commit a null prepared board.")
		return false
	if source._library != host._library:
		push_error("BoardDocument: prepared board belongs to a different asset library.")
		return false

	host.version = source.version
	host.board_name = source.board_name
	host.biome = source.biome
	host.surfaces = source.surfaces
	host.props = source.props
	host.enemy_packs = source.enemy_packs
	host.gameplay_markers = source.gameplay_markers
	host.particle_effects = source.particle_effects
	host.monster_visual_assets = source.monster_visual_assets
	host.imported_asset_ids = source.imported_asset_ids
	host.terrain = source.terrain
	host.movement_collision_min_triangle_share_percent = (
		source.movement_collision_min_triangle_share_percent
	)
	host.movement_unwalkable_cells = source.movement_unwalkable_cells
	host.movement_ground_effects = source.movement_ground_effects
	host.surface_material_paint = source.surface_material_paint
	host.material_blend = source.material_blend
	host.aesthetics = source.aesthetics
	host.lighting = source.lighting

	# Derive every index from the canonical records just adopted instead of copying
	# them across one field at a time. The enumerated copy this replaces silently
	# omitted _shader_decal_uid_index when that index was introduced, so every shader
	# decal loaded from disk resolved to no face and rendered as bare terrain, while
	# decals placed by hand -- indexed incrementally on add -- kept working. Rebuilding
	# is proportional to the placement count and cannot fall behind a new index the
	# way an enumerated copy can.
	host.rebuild_indexes()
	return true


## Announce one completed board replacement after every live derivative is ready.
static func announce_loaded_state(host: BoardDocument, include_look: bool = true) -> void:
	host.board_changed.emit()
	if include_look:
		host.look_changed.emit()
