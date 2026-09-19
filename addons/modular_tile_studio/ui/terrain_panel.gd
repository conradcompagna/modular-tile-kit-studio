@tool
class_name TerrainPanel
extends VBoxContainer

## The terrain authoring panel: one tool selector edits one canonical terrain.
##
## Terrain is the ground the whole board is built on, so its controls live in
## their own side panel beside Assets and Blockout rather than scattered across
## the top toolbar where they competed for space with unrelated tools.
##
## The panel keeps the ordinary path compact: one mutually exclusive terrain tool,
## then boundary and import operations.
##
## Brush width is deliberately NOT here. The toolbar's Brush width is the one
## canonical square width for terrain brushes and direct-texture stamping alike,
## so this panel owning a second size control would have meant two values for one
## authored result.
##
## The readout at the bottom reports what the backend actually derived -- cell
## counts, wall and band counts, the chunk size the paint resolution implies --
## so no value that changes the authored result is left invisible.

const K := preload("../utils/mts_constants.gd")

## One already-authored 1 m heightfield GLB chosen as the board terrain.
signal import_terrain_glb_requested()
## The user confirmed erasing the whole encounter footprint.
signal clear_terrain_requested()
## The user changed the visible depth of the terrain boundary shell.
signal skirt_depth_changed(depth_m: float)

var viewport: MTSStudioViewport = null
var board: BoardDocument = null

var _terrain_tool: OptionButton
var _action: OptionButton
var _step_height: SpinBox
var _strength: SpinBox
var _protect_walls: CheckBox
var _skirt_depth: SpinBox
var _summary: RichTextLabel
var _clear_dialog: ConfirmationDialog
## True while the panel is writing its own controls, so echoing viewport state
## back does not re-enter the viewport and fight whatever just changed it.
var _syncing: bool = false

## Tool selects the terrain representation; Action selects what both brushes do.
enum Tool { OFF, FOOTPRINT, ERASE_FOOTPRINT, FLATTEN_FOOTPRINT, STEPPED, SMOOTH }
enum Action { RAISE, LOWER, FLATTEN, SMOOTH }


## Build the panel once; bind_viewport() then connects it to a live board.
func _ready() -> void:
	name = "Terrain"
	add_theme_constant_override("separation", 8)
	_build_tool_section()
	_build_boundary_section()
	_build_import_section()
	_build_summary_section()
	_build_dialogs()
	_sync_controls()


## Bind the live viewport and follow its terrain and tool changes.
func bind_viewport(p_viewport: MTSStudioViewport) -> void:
	viewport = p_viewport
	if viewport == null:
		return
	viewport.terrain_changed.connect(refresh)
	viewport.height_sculpt_tool_changed.connect(func(_tool: int) -> void:
		if not _syncing:
			_sync_controls())
	viewport.footprint_tool_changed.connect(func(_tool: int) -> void:
		if not _syncing:
			_sync_controls())
	refresh()


## Bind the board whose terrain this panel reports and edits.
func bind_board(p_board: BoardDocument) -> void:
	board = p_board
	refresh()


## Add one titled group so each authoring step reads as its own step.
func _add_section(title: String) -> VBoxContainer:
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 12)
	add_child(label)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	add_child(body)
	return body


## Add one labelled row so a control and its name cannot drift apart.
func _add_row(parent: Control, text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(96, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)


## Build one terrain tool selector and one action selector shared by both brushes.
##
## Footprint operations remain direct tools. Stepped and Smooth select how terrain
## is represented, while both expose the same Raise, Lower, Flatten, and Smooth actions.
func _build_tool_section() -> void:
	var body := _add_section("1. Tool")
	_terrain_tool = OptionButton.new()
	_terrain_tool.add_item("Off", Tool.OFF)
	_terrain_tool.add_item("Footprint", Tool.FOOTPRINT)
	_terrain_tool.add_item("Erase footprint", Tool.ERASE_FOOTPRINT)
	_terrain_tool.add_item("Flatten footprint", Tool.FLATTEN_FOOTPRINT)
	_terrain_tool.add_item("Stepped", Tool.STEPPED)
	_terrain_tool.add_item("Smooth", Tool.SMOOTH)
	_terrain_tool.tooltip_text = "Choose footprint creation, erasure, exact zero flattening, or a Stepped/Smooth terrain brush."
	_terrain_tool.item_selected.connect(func(_index: int) -> void:
		if not _syncing:
			_commit_terrain_tool())
	_add_row(body, "Tool", _terrain_tool)

	_action = OptionButton.new()
	_action.add_item("Raise", Action.RAISE)
	_action.add_item("Lower", Action.LOWER)
	_action.add_item("Flatten", Action.FLATTEN)
	_action.add_item("Smooth", Action.SMOOTH)
	_action.tooltip_text = "Raise, Lower, Flatten, and Smooth are available to both Stepped and Smooth terrain brushes."
	_action.item_selected.connect(func(_index: int) -> void:
		if not _syncing:
			_commit_terrain_tool())
	_add_row(body, "Action", _action)

	_step_height = _make_spin(0.05, 8.0, 0.05, 0.5, " m")
	_step_height.tooltip_text = "Level increment used by every Stepped action."
	_step_height.value_changed.connect(func(value: float) -> void:
		if not _syncing and viewport != null:
			viewport.set_terrain_step(value))
	_add_row(body, "Step height", _step_height)

	_strength = _make_spin(0.01, 1.0, 0.01, 0.5, "")
	_strength.tooltip_text = "Blend amount used by the Smooth brush representation."
	_strength.value_changed.connect(func(value: float) -> void:
		if not _syncing and viewport != null:
			viewport.set_height_brush_strength(value))
	_add_row(body, "Strength", _strength)

	# Only the Smooth brushes move shared grid corners, which is the single
	# operation that can close a vertical drop. Stepped brushes create walls
	# rather than removing them, so this control is shown disabled for them
	# instead of silently having no effect.
	_protect_walls = CheckBox.new()
	_protect_walls.text = "Protect walls"
	_protect_walls.tooltip_text = (
		"Stop the Smooth brushes from moving any grid corner that a real vertical "
		+ "wall stands on. The stroke flows around existing walls instead of "
		+ "flattening them. Stepped brushes are unaffected: they create walls."
	)
	_protect_walls.toggled.connect(func(pressed: bool) -> void:
		if not _syncing and viewport != null:
			viewport.set_terrain_protect_walls(pressed))
	_add_row(body, "Walls", _protect_walls)


## Expose the depth that keeps the boundary below the live terrain.
func _build_boundary_section() -> void:
	var body := _add_section("3. Boundary")
	_skirt_depth = _make_spin(0.05, 256.0, 0.05, 1.0, " m")
	_skirt_depth.tooltip_text = (
		"Distance from the current lowest terrain point to the boundary shell's "
		+ "lower edge. Lowering terrain moves the derived base automatically."
	)
	_skirt_depth.value_changed.connect(func(value: float) -> void:
		if not _syncing:
			skirt_depth_changed.emit(value))
	_add_row(body, "Skirt depth", _skirt_depth)


## Adopt an already-authored heightfield, and expose the destructive reset.
func _build_import_section() -> void:
	var body := _add_section("4. Import")
	var import_button := Button.new()
	import_button.text = "Import Terrain GLB..."
	import_button.tooltip_text = "Adopt a finished 1 m heightfield GLB as ordinary terrain. Its exact cell tops, slopes, walls, and skirt become paintable and available to props and gameplay data."
	import_button.pressed.connect(func() -> void: import_terrain_glb_requested.emit())
	body.add_child(import_button)

	var clear_button := Button.new()
	clear_button.text = "Clear Terrain..."
	clear_button.tooltip_text = "Erase the entire encounter footprint and everything sculpted into it."
	clear_button.pressed.connect(func() -> void:
		if _clear_dialog != null:
			_clear_dialog.popup_centered())
	body.add_child(clear_button)


## The derived readout: what the backend actually built from the authored data.
func _build_summary_section() -> void:
	_add_section("Terrain")
	_summary = RichTextLabel.new()
	_summary.bbcode_enabled = false
	_summary.fit_content = true
	_summary.custom_minimum_size = Vector2(0, 96)
	_summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_summary)


## Create the destructive-action confirmation once.
func _build_dialogs() -> void:
	_clear_dialog = ConfirmationDialog.new()
	_clear_dialog.title = "Clear Terrain"
	_clear_dialog.dialog_text = "Erase the entire encounter footprint and its sculpted height?"
	_clear_dialog.confirmed.connect(func() -> void: clear_terrain_requested.emit())
	add_child(_clear_dialog)


## Build one spin box with an explicit visible range and unit.
func _make_spin(
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	suffix: String
) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.suffix = suffix
	return spin


## Push the selected brush representation and shared action into the viewport.
func _commit_terrain_tool() -> void:
	if viewport == null or _terrain_tool == null or _action == null:
		return
	var tool := _terrain_tool.get_item_id(_terrain_tool.selected)
	var action := _action.get_item_id(_action.selected)
	_syncing = true
	viewport.set_footprint_tool(MTSStudioViewport.FootprintTool.NONE)
	viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
	match tool:
		Tool.FOOTPRINT:
			viewport.set_footprint_tool(MTSStudioViewport.FootprintTool.DRAW)
		Tool.ERASE_FOOTPRINT:
			viewport.set_footprint_tool(MTSStudioViewport.FootprintTool.ERASE)
		Tool.FLATTEN_FOOTPRINT:
			viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT)
		Tool.STEPPED:
			match action:
				Action.RAISE:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.STEP_UP)
				Action.LOWER:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.STEP_DOWN)
				Action.FLATTEN:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.STEP_FLATTEN)
				Action.SMOOTH:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.STEP_SMOOTH)
		Tool.SMOOTH:
			match action:
				Action.RAISE:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.RAISE)
				Action.LOWER:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.LOWER)
				Action.FLATTEN:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.FLATTEN)
				Action.SMOOTH:
					viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.SMOOTH)
	_syncing = false
	_sync_controls()


## Mirror the viewport's live brush representation and action into both selectors.
func _sync_controls() -> void:
	_syncing = true
	if _skirt_depth != null:
		var has_terrain := (
			board != null
			and board.terrain != null
			and not board.terrain.is_empty()
		)
		_skirt_depth.editable = has_terrain
		if has_terrain:
			_skirt_depth.value = board.terrain.skirt_depth_m
	if viewport == null:
		_syncing = false
		return

	var tool := Tool.OFF
	var action := Action.RAISE
	if viewport.footprint_tool == MTSStudioViewport.FootprintTool.DRAW:
		tool = Tool.FOOTPRINT
	elif viewport.footprint_tool == MTSStudioViewport.FootprintTool.ERASE:
		tool = Tool.ERASE_FOOTPRINT
	else:
		match viewport.height_sculpt_tool:
			MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT:
				tool = Tool.FLATTEN_FOOTPRINT
			MTSStudioViewport.HeightSculptTool.STEP_UP:
				tool = Tool.STEPPED
				action = Action.RAISE
			MTSStudioViewport.HeightSculptTool.STEP_DOWN:
				tool = Tool.STEPPED
				action = Action.LOWER
			MTSStudioViewport.HeightSculptTool.STEP_FLATTEN:
				tool = Tool.STEPPED
				action = Action.FLATTEN
			MTSStudioViewport.HeightSculptTool.STEP_SMOOTH:
				tool = Tool.STEPPED
				action = Action.SMOOTH
			MTSStudioViewport.HeightSculptTool.RAISE:
				tool = Tool.SMOOTH
				action = Action.RAISE
			MTSStudioViewport.HeightSculptTool.LOWER:
				tool = Tool.SMOOTH
				action = Action.LOWER
			MTSStudioViewport.HeightSculptTool.FLATTEN:
				tool = Tool.SMOOTH
				action = Action.FLATTEN
			MTSStudioViewport.HeightSculptTool.SMOOTH:
				tool = Tool.SMOOTH
				action = Action.SMOOTH
	if _terrain_tool != null:
		var tool_index := _terrain_tool.get_item_index(tool)
		if tool_index >= 0:
			_terrain_tool.select(tool_index)
	if _action != null:
		var action_index := _action.get_item_index(action)
		if action_index >= 0:
			_action.select(action_index)
		_action.disabled = tool != Tool.STEPPED and tool != Tool.SMOOTH

	if _step_height != null:
		_step_height.value = viewport.terrain_step_m
		_step_height.editable = tool == Tool.STEPPED
	if _strength != null:
		_strength.value = viewport.height_brush_strength
		_strength.editable = tool == Tool.SMOOTH
	if _protect_walls != null:
		_protect_walls.set_pressed_no_signal(viewport.terrain_protect_walls)
		_protect_walls.disabled = tool != Tool.SMOOTH

	_syncing = false


## Refresh the derived readout and the controls after the terrain changed.
func refresh() -> void:
	_sync_controls()
	if _summary == null:
		return
	if board == null or board.terrain == null or board.terrain.is_empty():
		_summary.text = "No terrain.\n\nDraw a footprint to begin, or import an authored heightfield GLB."
		return

	var terrain: TerrainMesh = board.terrain
	var chunk_cells := (
		viewport.terrain_chunk_cells()
		if viewport != null
		else MTSTerrainMeshBuilder.DEFAULT_CHUNK_CELLS
	)
	var texels := (
		board.material_blend.paint_texels_per_metre
		if board.material_blend != null
		else 0
	)
	var counts := (
		viewport.terrain_summary_counts()
		if viewport != null
		else {}
	)
	var height_range := (
		viewport.terrain_cached_height_range()
		if viewport != null
		else Vector2.ZERO
	)
	var top_count := int(counts.get("top", 0))
	var side_count := int(counts.get("side", 0))
	var skirt_count := int(counts.get("skirt", 0))
	var chunk_count := int(counts.get("chunks", 0))

	_summary.text = "\n".join([
		"Footprint     %d x %d cells  -  %d filled" % [
			terrain.size_cells.x,
			terrain.size_cells.y,
			top_count,
		],
		"Elevation     %.2f m to %.2f m" % [
			height_range.x,
			height_range.y,
		],
		"Walls         %d paintable bands" % side_count,
		"Skirt         %.2f m deep  -  base %.2f m  -  %d bands" % [
			terrain.skirt_depth_m,
			terrain.skirt_base_m,
			skirt_count,
		],
		"Paint chunks  %d m (%d px @ %d texels/m)  -  %d chunks" % [
			chunk_cells,
			chunk_cells * texels,
			texels,
			chunk_count,
		],
		"Paint units   %d ground  +  %d band" % [
			top_count,
			side_count + skirt_count,
		],
	])
