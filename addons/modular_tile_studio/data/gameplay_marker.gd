@tool
class_name GameplayMarker
extends Resource

## Canonical cell marker used for authored gameplay intent on the board grid.

const TYPE_ENEMY: String = "enemy"
const TYPE_PLAYER_SPAWN: String = "player_spawn"
const TYPE_OBJECTIVE: String = "objective"
const TYPE_TRIGGER: String = "trigger"
const TYPE_LOOT: String = "loot"
const TYPE_NOTE: String = "note"
const TYPES: PackedStringArray = [
	TYPE_ENEMY,
	TYPE_PLAYER_SPAWN,
	TYPE_OBJECTIVE,
	TYPE_TRIGGER,
	TYPE_LOOT,
	TYPE_NOTE,
]

@export var marker_id: String = ""
@export_enum("enemy", "player_spawn", "objective", "trigger", "loot", "note")
var marker_type: String = TYPE_NOTE
@export var origin: Vector3i = Vector3i.ZERO
@export_multiline var note: String = ""
@export var monster_id: String = ""
@export var pack_id: String = ""


## Create one exact marker record from visible editor or API values.
static func create(
	id: String,
	type: String,
	grid_origin: Vector3i,
	description: String,
	monster: String = "",
	pack: String = ""
) -> GameplayMarker:
	var marker := GameplayMarker.new()
	marker.marker_id = id
	marker.marker_type = type
	marker.origin = grid_origin
	marker.note = description
	marker.monster_id = monster
	marker.pack_id = pack
	return marker


## Validate fields that do not depend on the containing board's pack index.
func validate_definition() -> PackedStringArray:
	var errors := PackedStringArray()
	if marker_id.is_empty():
		errors.append("gameplay marker id must be a non-empty string")
	elif marker_id != marker_id.strip_edges():
		errors.append("gameplay marker id '%s' must not begin or end with whitespace" % marker_id)
	if not TYPES.has(marker_type):
		errors.append(
			"gameplay marker '%s' type must be one of %s"
			% [marker_id, ", ".join(TYPES)]
		)
	if marker_type == TYPE_ENEMY:
		if monster_id.is_empty():
			errors.append("enemy marker '%s' must specify a monster id" % marker_id)
		elif monster_id != monster_id.strip_edges():
			errors.append("enemy marker '%s' monster id must not begin or end with whitespace" % marker_id)
		if pack_id != pack_id.strip_edges():
			errors.append("enemy marker '%s' pack id must not begin or end with whitespace" % marker_id)
	elif not monster_id.is_empty() or not pack_id.is_empty():
		errors.append(
			"non-enemy marker '%s' cannot specify monster or pack data"
			% marker_id
		)
	for api_error in validate_api_contract():
		errors.append(api_error)
	return errors


## Validate the exact primitive record consumed by the blockout and inspection APIs.
##
## This guards serialization drift: a marker is not placeable if its exported
## record omits monster or pack data, changes the integer origin shape, or adds
## an undocumented field that WebGPT cannot safely reproduce.
func validate_api_contract() -> PackedStringArray:
	var errors := PackedStringArray()
	var record := to_json()
	var required_fields := PackedStringArray([
		"id",
		"type",
		"origin",
		"note",
		"monster",
		"pack",
	])
	if record.size() != required_fields.size():
		errors.append(
			"gameplay marker '%s' API record must contain exactly %s"
			% [marker_id, ", ".join(required_fields)]
		)
	for field: String in ["id", "type", "note", "monster", "pack"]:
		if not record.has(field) or not (record[field] is String):
			errors.append(
				"gameplay marker '%s' API field '%s' must be a string"
				% [marker_id, field]
			)
	var origin_value: Variant = record.get("origin", null)
	if not (origin_value is Array) or (origin_value as Array).size() != 3:
		errors.append(
			"gameplay marker '%s' API origin must contain exactly three integers"
			% marker_id
		)
	else:
		for component: Variant in origin_value:
			if not (component is int):
				errors.append(
					"gameplay marker '%s' API origin must contain exactly three integers"
					% marker_id
				)
				break
	return errors


## Return the concise visible title used by viewport labels and editor lists.
func display_title() -> String:
	if marker_type != TYPE_ENEMY:
		return "%s | %s" % [marker_type, marker_id]
	var pack_text := "solo" if pack_id.is_empty() else "pack %s" % pack_id
	return "%s | %s | %s" % [monster_id, marker_id, pack_text]


## Serialize the exact canonical marker fields without derived display text.
func to_json() -> Dictionary:
	return {
		"id": marker_id,
		"type": marker_type,
		"origin": [origin.x, origin.y, origin.z],
		"note": note,
		"monster": monster_id,
		"pack": pack_id,
	}


## Reconstruct one marker from the exact JSON fields used by the blockout API.
static func from_json(data: Dictionary) -> GameplayMarker:
	var origin_value: Variant = data.get("origin", [])
	var parsed_origin := Vector3i.ZERO
	if origin_value is Array and (origin_value as Array).size() == 3:
		var values: Array = origin_value
		parsed_origin = Vector3i(
			int(values[0]),
			int(values[1]),
			int(values[2])
		)
	return GameplayMarker.create(
		String(data.get("id", "")),
		String(data.get("type", "")),
		parsed_origin,
		String(data.get("note", "")),
		String(data.get("monster", "")),
		String(data.get("pack", ""))
	)
