@tool
class_name MTSGameplayMarkerController
extends Node3D

## Converts grid-cell clicks into canonical gameplay markers with undo support.

signal hover_changed(cell: Vector3i, valid: bool, reason: String)
signal board_mutated()
signal marker_placed(marker_id: String)

var board: BoardDocument
## The live terrain renderer, which owns the one terrain picking routine.
##
## Markers stand on the sculpted ground, so they are placed by the same pick a
## paint stroke or prop uses. Without it there is no placement surface at all,
## because a flat editing plane would put a marker underground on any slope.
var terrain_renderer: MTSTerrainRenderer = null
var undo_redo: EditorUndoRedoManager
var active: bool = false
## Editing layer retained only for the preview gizmo's fallback height.
var current_y: int = 0

var brush_marker_id: String = ""
var brush_marker_type: String = GameplayMarker.TYPE_NOTE
var brush_note: String = ""
var brush_monster_id: String = ""
var brush_pack_id: String = ""

var hovered_cell: Vector3i = Vector3i.ZERO
var hover_valid: bool = false
var hover_reason: String = ""
## Exact terrain point under the pointer, used only to seat the preview gizmo.
##
## The committed marker keeps its integer cell; this float is display state so
## the pin visibly rests on the sculpted surface instead of the cell floor.
var _hovered_point: Vector3 = Vector3.ZERO

var _preview_root: Node3D
var _preview_stem: MeshInstance3D
var _preview_head: MeshInstance3D
var _preview_label: Label3D
var _marker_script: Script = load(
	"res://addons/modular_tile_studio/data/gameplay_marker.gd"
)


## Build marker preview geometry centered inside the canonical unit grid cell.
func _ready() -> void:
	_preview_root = Node3D.new()
	_preview_root.name = "GameplayMarkerPreview"
	add_child(_preview_root)

	_preview_stem = MeshInstance3D.new()
	_preview_stem.name = "Stem"
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = 0.08
	stem_mesh.bottom_radius = 0.08
	stem_mesh.height = 0.7
	stem_mesh.radial_segments = 12
	_preview_stem.mesh = stem_mesh
	# The saved origin is the cell minimum; the visible gizmo is derived locally
	# at the unit cell's centre without moving the canonical placement root.
	_preview_stem.position = Vector3(0.5, 0.35, 0.5)
	_preview_stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_stem)

	_preview_head = MeshInstance3D.new()
	_preview_head.name = "Head"
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.26
	head_mesh.height = 0.52
	head_mesh.radial_segments = 16
	head_mesh.rings = 8
	_preview_head.mesh = head_mesh
	_preview_head.position = Vector3(0.5, 0.82, 0.5)
	_preview_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_head)

	_preview_label = Label3D.new()
	_preview_label.name = "MarkerLabel"
	_preview_label.position = Vector3(0.5, 1.28, 0.5)
	_preview_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_preview_label.fixed_size = true
	_preview_label.no_depth_test = true
	_preview_label.font_size = 16
	_preview_label.outline_size = 5
	_preview_label.pixel_size = 0.003
	_preview_root.add_child(_preview_label)

	_preview_root.visible = false
	_rebuild_preview()


## Enable or disable marker input without changing the visible brush fields.
func set_active(enabled: bool) -> void:
	active = enabled
	if _preview_root != null:
		_preview_root.visible = active and has_brush()


## Store the exact visible marker form as the next click's authored input.
func set_brush(
	marker_type: String,
	note: String,
	monster_id: String = "",
	pack_id: String = "",
	marker_id: String = ""
) -> void:
	brush_marker_type = marker_type
	brush_note = note
	brush_monster_id = monster_id
	brush_pack_id = pack_id
	brush_marker_id = marker_id
	_evaluate_hover()
	_rebuild_preview()


## Return whether the controller has a marker type selected for placement.
func has_brush() -> bool:
	return not brush_marker_type.is_empty()


## Intersect the camera ray with the canonical sculpted terrain.
##
## Markers stand on the ground characters walk on, so this uses the terrain
## renderer's one picking routine rather than a horizontal editing plane. A miss
## is reported as a miss: inventing a marker cell in empty space would bury the
## pin under a hill or float it over a valley.
func update_hover(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not active or camera == null:
		return
	if terrain_renderer == null:
		hover_valid = false
		hover_reason = "gameplay markers require the heightfield renderer"
		_preview_root.visible = false
		hover_changed.emit(hovered_cell, false, hover_reason)
		return
	var pick := terrain_renderer.pick_face(
		camera.project_ray_origin(mouse_pos),
		camera.project_ray_normal(mouse_pos)
	)
	if pick.is_empty():
		hover_valid = false
		hover_reason = "no terrain under the pointer"
		_preview_root.visible = false
		hover_changed.emit(hovered_cell, false, hover_reason)
		return
	hovered_cell = marker_cell_for_pick(pick)
	_hovered_point = pick["point"] as Vector3
	_evaluate_hover()
	_position_preview()
	_preview_root.visible = active and has_brush()
	hover_changed.emit(hovered_cell, hover_valid, hover_reason)


## Return the lattice cell a marker occupies for one terrain pick.
##
## The marker's canonical address is the cell containing the picked point, whose
## Y is the real terrain level rather than a fixed editing layer, so a marker on
## a hillside records the elevation it actually stands at.
static func marker_cell_for_pick(pick: Dictionary) -> Vector3i:
	var point: Vector3 = pick["point"]
	return Vector3i(
		floori(point.x),
		TerrainMesh.level_of_height(point.y),
		floori(point.z)
	)


## Build the exact candidate that a click would add to BoardDocument.
func candidate_at(origin: Vector3i) -> GameplayMarker:
	if board == null:
		return null
	var marker_id := brush_marker_id
	if marker_id.is_empty():
		marker_id = board.next_gameplay_marker_id(brush_marker_type)
	return _marker_script.create(
		marker_id,
		brush_marker_type,
		origin,
		brush_note,
		brush_monster_id,
		brush_pack_id
	) as GameplayMarker


## Evaluate the current preview against the board's one marker validator.
func _evaluate_hover() -> void:
	if board == null or not has_brush():
		hover_valid = false
		hover_reason = "no gameplay marker brush or board"
		return
	var candidate := candidate_at(hovered_cell)
	var result := board.validate_gameplay_marker(candidate)
	hover_valid = bool(result.get("valid", false))
	hover_reason = String(result.get("reason", ""))


## Commit one exact marker through the editor's global undo history.
func place_at_hover() -> Dictionary:
	if board == null or not has_brush():
		return {"valid": false, "reason": "no gameplay marker brush or board"}
	var marker := candidate_at(hovered_cell)
	var result := board.validate_gameplay_marker(marker)
	if not bool(result.get("valid", false)):
		hover_valid = false
		hover_reason = String(result.get("reason", "gameplay marker is invalid"))
		hover_changed.emit(hovered_cell, false, hover_reason)
		return result

	if undo_redo == null:
		result = board.add_gameplay_marker(marker)
		if bool(result.get("valid", false)):
			board_mutated.emit()
			marker_placed.emit(marker.marker_id)
		return result

	undo_redo.create_action("Place gameplay marker", UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, "add_gameplay_marker", marker)
	undo_redo.add_undo_method(board, "remove_gameplay_marker", marker)
	undo_redo.add_do_method(self, "_notify_mutated")
	undo_redo.add_undo_method(self, "_notify_mutated")
	undo_redo.commit_action()
	marker_placed.emit(marker.marker_id)
	return {"valid": true, "reason": "", "marker": marker.marker_id}


## Remove the marker in the hovered grid cell through the same undo history.
func erase_at_hover() -> bool:
	if board == null:
		return false
	var marker := board.gameplay_marker_at(hovered_cell)
	if marker == null:
		return false
	if undo_redo == null:
		board.remove_gameplay_marker(marker)
		board_mutated.emit()
		return true

	undo_redo.create_action("Erase gameplay marker", UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, "remove_gameplay_marker", marker)
	undo_redo.add_undo_method(board, "add_gameplay_marker", marker)
	undo_redo.add_do_method(self, "_notify_mutated")
	undo_redo.add_undo_method(self, "_notify_mutated")
	undo_redo.commit_action()
	return true


## Emit the one synchronization signal used after do, undo, and redo.
func _notify_mutated() -> void:
	board_mutated.emit()


## Rebuild preview text and colors from the exact brush values.
func _rebuild_preview() -> void:
	if _preview_root == null:
		return
	var color := marker_color(brush_marker_type)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(color.r, color.g, color.b, 0.72)
	material.no_depth_test = true
	material.render_priority = 5
	_preview_stem.material_override = material
	_preview_head.material_override = material
	_preview_label.modulate = color
	# Enemy previews identify their reusable monster type; other markers keep
	# their stable marker identity. All remaining metadata stays in the panel.
	var title := (
		brush_monster_id
		if brush_marker_type == GameplayMarker.TYPE_ENEMY
		else brush_marker_id
	)
	if title.is_empty():
		title = brush_marker_type.replace("_", " ").capitalize()
	_preview_label.text = title
	_position_preview()
	_preview_root.visible = active and has_brush()


## Position only the derived preview root at the authored cell-minimum coordinate.
func _position_preview() -> void:
	if _preview_root == null:
		return
	# X and Z stay on the canonical cell minimum so the gizmo agrees with the
	# saved address, while Y follows the exact picked terrain height.
	_preview_root.position = Vector3(
		float(hovered_cell.x),
		_hovered_point.y,
		float(hovered_cell.z)
	)
	var color := marker_color(brush_marker_type)
	if not hover_valid:
		color = Color(1.0, 0.2, 0.18)
	for mesh: MeshInstance3D in [_preview_stem, _preview_head]:
		var material := mesh.material_override as StandardMaterial3D
		if material != null:
			material.albedo_color = Color(color.r, color.g, color.b, 0.72)
	_preview_label.modulate = color


## Return the deterministic editor color assigned to each explicit marker type.
static func marker_color(marker_type: String) -> Color:
	match marker_type:
		GameplayMarker.TYPE_ENEMY:
			return Color(1.0, 0.22, 0.18)
		GameplayMarker.TYPE_PLAYER_SPAWN:
			return Color(0.25, 1.0, 0.4)
		GameplayMarker.TYPE_OBJECTIVE:
			return Color(1.0, 0.78, 0.12)
		GameplayMarker.TYPE_TRIGGER:
			return Color(0.82, 0.3, 1.0)
		GameplayMarker.TYPE_LOOT:
			return Color(0.12, 0.9, 1.0)
		GameplayMarker.TYPE_NOTE:
			return Color(0.45, 0.65, 1.0)
		_:
			return Color.WHITE


## Return one stable high-contrast color shared by a pack net and its list rows.
static func pack_color(pack_id: String) -> Color:
	if pack_id.is_empty():
		return Color(0.72, 0.75, 0.8)
	var hue := float(wrapi(pack_id.hash(), 0, 360)) / 360.0
	return Color.from_hsv(hue, 0.78, 1.0)
