@tool
class_name EnemyPack
extends Resource

## Saved enemy-pack metadata shared by the editor, board JSON, and blockout API.

@export var pack_id: String = ""
@export_multiline var note: String = ""


## Create one exact pack record without normalizing user-authored identifiers.
static func create(id: String, description: String) -> EnemyPack:
	var pack := EnemyPack.new()
	pack.pack_id = id
	pack.note = description
	return pack


## Validate the complete pack record before it enters an authoritative board.
func validate_definition() -> PackedStringArray:
	var errors := PackedStringArray()
	if pack_id.is_empty():
		errors.append("enemy pack id must be a non-empty string")
	elif pack_id != pack_id.strip_edges():
		errors.append("enemy pack id '%s' must not begin or end with whitespace" % pack_id)
	if note.strip_edges().is_empty():
		errors.append("enemy pack '%s' must include a note explaining the encounter group" % pack_id)
	return errors


## Serialize the exact fields consumed by both saved boards and generated blockouts.
func to_json() -> Dictionary:
	return {
		"id": pack_id,
		"note": note,
	}


## Reconstruct one pack record from its canonical JSON fields.
static func from_json(data: Dictionary) -> EnemyPack:
	return EnemyPack.create(
		String(data.get("id", "")),
		String(data.get("note", ""))
	)
