@tool
class_name MTSParticleEffectController
extends Node3D

## Converts snapped grid-plane clicks into canonical particle effect placements with undo support.

signal hover_changed(position: Vector3, valid: bool, reason: String)
signal board_mutated()
signal effect_placed(placement_id: String)

var board: BoardDocument
var library: ParticleEffectLibrary
## The live terrain renderer, which owns the one terrain picking routine.
##
## Ground-attached effects -- smoke vents, campfires, puddles, dust -- must sit
## on the sculpted surface, so emitters are placed by the same pick paint and
## props use rather than by a horizontal editing plane.
var terrain_renderer: MTSTerrainRenderer = null
var undo_redo: EditorUndoRedoManager
var active: bool = false
var erase_mode: bool = false
## Editing layer retained only as the fallback height for free emitters.
var current_y: int = 0
var preset_id: String = ""
## How the next placed emitter resolves its height, chosen in the particle panel.
var attachment: ParticleEffectPlacement.Attachment = ParticleEffectPlacement.Attachment.TERRAIN

var hovered_position: Vector3 = Vector3.ZERO
var hover_valid: bool = false
var hover_reason: String = ""

var _preview: MeshInstance3D
var _placement_script: Script = load(
	"res://addons/modular_tile_studio/data/particle_effect_placement.gd"
)


## Build the derived emitter-volume preview shown under the pointer.
func _ready() -> void:
	_preview = MeshInstance3D.new()
	_preview.name = "ParticleEmitterPreview"
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.25, 0.75, 1.0, 0.18)
	material.no_depth_test = true
	material.render_priority = 8
	_preview.material_override = material
	add_child(_preview)
	_preview.visible = false


## Enable or disable this input path without changing the selected preset.
func set_active(enabled: bool) -> void:
	active = enabled
	_preview.visible = active and not preset_id.is_empty()


## Select whether left click places or erases particle emitters.
func set_erase_mode(enabled: bool) -> void:
	erase_mode = enabled
	_evaluate_hover()
	_update_preview()


## Select whether the next placed emitter follows the terrain or stays in world space.
##
## This only affects placements made from now on. Changing it never rewrites the
## attachment of effects already authored on the board.
func set_attachment(p_attachment: int) -> void:
	attachment = p_attachment as ParticleEffectPlacement.Attachment


## Store the stable reusable preset ID consumed by the next placement.
func set_preset(p_selected_preset_id: String) -> void:
	preset_id = p_selected_preset_id
	_evaluate_hover()
	_update_preview()


## Intersect the camera ray with the canonical terrain and show the exact emitter point.
##
## A miss is reported as a miss rather than falling back to a flat plane, which
## would place a ground effect at an elevation the terrain does not have.
func update_hover(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not active or camera == null:
		return
	if terrain_renderer == null:
		_set_invalid("particle placement requires the heightfield renderer")
		return
	var pick := terrain_renderer.pick_face(
		camera.project_ray_origin(mouse_pos),
		camera.project_ray_normal(mouse_pos)
	)
	if pick.is_empty():
		_set_invalid("no terrain under the pointer")
		return
	hovered_position = snapped_emitter_position(pick["point"] as Vector3)
	_evaluate_hover()
	_update_preview()
	hover_changed.emit(hovered_position, hover_valid, hover_reason)


## Snap an emitter to its grid cell centre while keeping the exact terrain height.
##
## X and Z snap so repeated emitters line up on the tactical grid; Y is the real
## sampled surface elevation, because an emitter that ignored it would hover
## above a hill or sink into a slope.
static func snapped_emitter_position(point: Vector3) -> Vector3:
	return Vector3(floorf(point.x) + 0.5, point.y, floorf(point.z) + 0.5)


## Commit one reusable preset reference at the exact previewed world position.
func place_at_hover() -> bool:
	if board == null or library == null or erase_mode:
		return false
	_evaluate_hover()
	if not hover_valid:
		hover_changed.emit(hovered_position, false, hover_reason)
		return false
	var placement := _placement_script.new() as ParticleEffectPlacement
	placement.initialize(preset_id, hovered_position, attachment)

	if undo_redo == null:
		if board.add_particle_effect(placement):
			board_mutated.emit()
			effect_placed.emit(placement.placement_id)
			return true
		return false

	undo_redo.create_action("Place particle effect", UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, "add_particle_effect", placement)
	undo_redo.add_undo_method(board, "remove_particle_effect", placement)
	undo_redo.add_do_method(self, "_notify_mutated")
	undo_redo.add_undo_method(self, "_notify_mutated")
	undo_redo.commit_action()
	effect_placed.emit(placement.placement_id)
	return true


## Remove the nearest emitter within the visible snapped cell radius.
func erase_at_hover() -> bool:
	if board == null:
		return false
	var placement := board.particle_effect_near(hovered_position, 0.75)
	if placement == null:
		return false
	if undo_redo == null:
		if board.remove_particle_effect(placement):
			board_mutated.emit()
			return true
		return false

	undo_redo.create_action("Erase particle effect", UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, "remove_particle_effect", placement)
	undo_redo.add_undo_method(board, "add_particle_effect", placement)
	undo_redo.add_do_method(self, "_notify_mutated")
	undo_redo.add_undo_method(self, "_notify_mutated")
	undo_redo.commit_action()
	return true


## Emit the one synchronization signal shared by direct edits, undo, and redo.
func _notify_mutated() -> void:
	board_mutated.emit()


## Evaluate the exact preset or erase target currently under the pointer.
func _evaluate_hover() -> void:
	if board == null or library == null:
		hover_valid = false
		hover_reason = "no particle board or preset library"
		return
	if erase_mode:
		hover_valid = board.particle_effect_near(hovered_position, 0.75) != null
		hover_reason = "" if hover_valid else "no particle emitter in this grid cell"
		return
	var preset := library.preset_by_id(preset_id)
	if preset == null:
		hover_valid = false
		hover_reason = "no particle preset selected"
		return
	hover_valid = preset.is_valid()
	hover_reason = "" if hover_valid else "selected particle preset is incomplete"


## Update preview size, position, and validity colour from the exact selected preset.
func _update_preview() -> void:
	if _preview == null:
		return
	_preview.position = hovered_position
	var box := BoxMesh.new()
	var preset := library.preset_by_id(preset_id) if library != null else null
	box.size = preset.emission_box_size_m if preset != null else Vector3.ONE
	_preview.mesh = box
	var color := Color(1.0, 0.35, 0.22, 0.18) if erase_mode else Color(0.25, 0.75, 1.0, 0.18)
	if not hover_valid:
		color = Color(1.0, 0.15, 0.12, 0.18)
	var material := _preview.material_override as StandardMaterial3D
	if material != null:
		material.albedo_color = color
	_preview.visible = active and (erase_mode or not preset_id.is_empty())


## Mark hover invalid and hide the preview when the editing plane cannot be reached.
func _set_invalid(reason: String) -> void:
	hover_valid = false
	hover_reason = reason
	_preview.visible = false
	hover_changed.emit(hovered_position, false, hover_reason)
