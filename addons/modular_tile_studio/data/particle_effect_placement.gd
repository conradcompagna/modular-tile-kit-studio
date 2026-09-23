@tool
class_name ParticleEffectPlacement
extends Resource

## Stores one exact board-space location that references a reusable particle preset.
##
## The position is the emitter node's actual world position in metres; the
## renderer does not add an anchor offset or maintain another spatial value.
##
## An effect is either attached to the terrain or free in the world, and that is an
## authored choice rather than an inferred one. A TERRAIN effect keeps its authored
## X and Z and takes its height from the canonical heightfield every rebuild, so
## sculpting carries a campfire with the ground it sits on. A WORLD effect keeps the
## exact authored Y, which is what a hovering or airborne effect requires.

## How this effect's height is resolved against the canonical terrain.
enum Attachment {
	TERRAIN,
	WORLD,
}

@export var placement_id: String = ""
@export var preset_id: String = ""
@export var position: Vector3 = Vector3.ZERO
@export var attachment: Attachment = Attachment.TERRAIN
@export var enabled: bool = true


## Initialize this placement with the exact snapped world point shown in the viewport.
func initialize(
	p_preset_id: String,
	p_position: Vector3,
	p_attachment: Attachment = Attachment.TERRAIN
) -> void:
	placement_id = "%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	preset_id = p_preset_id
	position = p_position
	attachment = p_attachment


## Resolve the authored attachment against the same heightfield in the editor and game.
func world_position(terrain: TerrainMesh) -> Vector3:
	if attachment != Attachment.TERRAIN or terrain == null:
		return position
	var cell := Vector2i(floori(position.x), floori(position.z))
	if not terrain.is_cell_filled(cell):
		return position
	return Vector3(position.x, terrain.cell_walk_height(cell), position.z)


## Return the name persisted for one attachment mode.
static func attachment_name(value: Attachment) -> String:
	return "world" if value == Attachment.WORLD else "terrain"


## Return the attachment mode one persisted name selects.
##
## An unrecognized name is rejected by load_json rather than resolved here, so this
## never has to invent a mode for malformed data.
static func attachment_from_name(value: String) -> Attachment:
	return Attachment.WORLD if value == "world" else Attachment.TERRAIN


## Serialize this placement into the board JSON representation.
func to_json() -> Dictionary:
	return {
		"placement_id": placement_id,
		"preset_id": preset_id,
		"position": [position.x, position.y, position.z],
		"attachment": attachment_name(attachment),
		"enabled": enabled,
	}


## Load this placement from board JSON while rejecting malformed required values.
func load_json(data: Dictionary) -> bool:
	var raw_position: Variant = data.get("position", null)
	if not (raw_position is Array) or (raw_position as Array).size() < 3:
		push_error("[Tile Studio] Particle placement is missing a three-component position.")
		return false
	var preset := String(data.get("preset_id", ""))
	if preset.is_empty():
		push_error("[Tile Studio] Particle placement is missing preset_id.")
		return false
	var parts: Array = raw_position
	placement_id = String(data.get("placement_id", ""))
	if placement_id.is_empty():
		push_error("[Tile Studio] Particle placement is missing placement_id.")
		return false
	# Boards authored before effects declared an attachment recorded ground-placed
	# emitters, so an absent field means terrain rather than an error.
	var attachment_value := String(data.get("attachment", "terrain"))
	if attachment_value != "terrain" and attachment_value != "world":
		push_error(
			"[Tile Studio] Particle placement '%s' has unknown attachment '%s'."
			% [placement_id, attachment_value]
		)
		return false
	preset_id = preset
	position = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	attachment = attachment_from_name(attachment_value)
	enabled = bool(data.get("enabled", true))
	return true
