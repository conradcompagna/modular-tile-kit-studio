@tool
class_name TileStudioMain
extends Control

## The Tile Studio main-screen workspace (spec 3).
##
## Three columns -- library, isometric viewport, inspector -- over a status bar,
## with a flat toolbar. Deliberately not nested menus: the strength of the tool
## is constraint and speed (spec 42).

const K := preload("../utils/mts_constants.gd")
const StudioViewport := preload("../viewport/studio_viewport.gd")
const LibraryPanel := preload("asset_library_panel.gd")
const InspectorPanel := preload("asset_inspector_panel.gd")
const ImageDialog := preload("import_image_dialog.gd")
const GLBDialog := preload("import_glb_dialog.gd")
const NameDialog := preload("board_name_dialog.gd")
const OccupancyOverlay := preload("../viewport/occupancy_overlay.gd")
const MovementGridPanelScene := preload("movement_grid_panel.gd")
const AestheticsPanelScene := preload("aesthetics_panel.gd")
const LightingPanelScene := preload("lighting_panel.gd")

signal import_image_selected(path: String)
signal import_glb_selected(path: String)
## One already-authored 1 m heightfield GLB chosen as the board terrain.
signal import_terrain_glb_selected(path: String)
signal new_board_requested()
signal open_board_requested()
signal save_board_requested()
signal export_json_requested()
signal comfy_reconnect_requested()
## Request explicit raw collision measurement for placed GLBs missing triangle shares.
signal movement_collision_measure_requested()
## User asked to rename the current board. The panel does not rename it itself:
## the board is the plugin's document, and the name also decides the save path.
signal rename_board_requested()
signal gameplay_marker_update_requested(
	marker_id: String,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
)
signal gameplay_marker_delete_requested(marker_id: String)
signal enemy_pack_create_requested(pack_id: String, note: String)
signal enemy_pack_update_requested(pack_id: String, note: String)
signal enemy_pack_delete_requested(pack_id: String)
signal enemy_pack_assign_requested(
	marker_ids: PackedStringArray,
	pack_id: String
)
signal monster_visual_assign_requested(monster_id: String, asset_id: String)
signal monster_visual_clear_requested(monster_id: String)
signal monster_glb_selected(path: String, monster_id: String)

var viewport: MTSStudioViewport
var library_panel: AssetLibraryPanel
## Terrain authoring: footprint, sculpt, skirt and heightfield import.
var terrain_panel: TerrainPanel
var gameplay_panel: GameplayMarkersPanel
var particle_effects_panel: ParticleEffectsPanel
var material_paint_panel: Variant
var inspector: AssetInspectorPanel
var _asset_library: AssetLibrary

var image_dialog: ImportImageDialog
var glb_dialog: ImportGLBDialog
## Shared by New Board, the first Save of an untitled board, and Rename.
var name_dialog: BoardNameDialog

var _status_label: Label
var _hover_label: Label
var _comfy_label: Label
var _brush_label: Label
## This visible diagnostic toggle shows the current globally filtered GLB voxels.
var _glb_voxels_check: CheckButton
var _erase_button: Button
## The toolbar toggle mirrors the viewport's explicit selection mode.
var _select_button: Button
var _replace_button: Button
var _fill_button: Button
var _fill_shape_option: OptionButton
## The one top-level square brush width in whole grid metres.
##
## Consumed by direct-texture stamping, Fill, and every terrain brush, so the
## Terrain panel deliberately has no size control of its own.
var _surface_grid_stroke_size_spin: SpinBox
var _prop_support_option: OptionButton
var _left_tabs: TabContainer
var _board_label: Label
var _grid_check: CheckButton
var _lattice_check: CheckButton
## The visible controller for the viewport's transient, editor-only camera behavior.
var _camera_mode_option: OptionButton
var _file_dialog: FileDialog
## Context exists only while the shared file picker is assigning a GLB to one Monster ID.
var _pending_monster_import_id: String = ""
## True while the file dialog is choosing terrain rather than a prop.
var _pending_terrain_import: bool = false

# Board movement, rendering, and lighting are separate top-level windows so
# each task remains visible beside the map without becoming a hidden nested tab.
var movement_grid_panel: MovementGridPanel
var aesthetics_panel: AestheticsPanel
var lighting_panel: LightingPanel
var _movement_grid_window: Window
var _aesthetics_window: Window
var _lighting_window: Window

## path|mtime|size -> Texture2D, so scrolling a large folder does not re-decode.
const THUMBNAIL_CACHE_LIMIT: int = 400
const FILE_THUMBNAIL_SIZE: int = 128
var _thumbnail_cache: Dictionary = {}
## Placeholders still awaiting a worker decode: key -> ImageTexture.
var _thumbnail_pending: Dictionary = {}
const THUMBNAIL_EXTENSIONS: Array = [
	"png", "jpg", "jpeg", "webp", "bmp", "tga", "exr"
]

## Last browsed folder per import kind, so the dialog reopens where you were.
var _last_dir_image: String = ""
var _last_dir_glb: String = ""


func _ready() -> void:
	name = "Tile Studio"
	# The editor main-screen host is a container: it sizes children by their size
	# flags, not by anchors. Without EXPAND_FILL on both axes this Control
	# collapses to its minimum height and the workspace shows as a thin sliver.
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, 480)

	var root := VBoxContainer.new()
	# Anchored to this Control (which is not itself a container), so the column
	# layout tracks the full workspace rect as it resizes.
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# The toolbar holds more controls than a narrow workspace can show, and an
	# HBoxContainer simply overflows -- the right-hand buttons end up past the
	# window edge, unreachable. Scrolling it horizontally keeps every control
	# available at any dock width, and the fixed height stops it stealing
	# vertical space from the viewport.
	var toolbar_scroll := ScrollContainer.new()
	toolbar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	toolbar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar_scroll.custom_minimum_size = Vector2(0, 40)
	toolbar_scroll.add_child(_build_toolbar())
	root.add_child(toolbar_scroll)

	var columns := HSplitContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(columns)

	_left_tabs = TabContainer.new()
	_left_tabs.custom_minimum_size = Vector2(280, 0)
	_left_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_tabs.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	columns.add_child(_left_tabs)

	library_panel = LibraryPanel.new()
	library_panel.name = "Assets"
	library_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	library_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_tabs.add_child(library_panel)

	# Panels are loaded at runtime so editor reloads never hold a stale preloaded
	# script resource. Terrain is the ground everything else is authored on, so
	# its panel sits immediately after the asset library and before the systems
	# that build on it.
	var terrain_panel_script: Script = load(
		"res://addons/modular_tile_studio/ui/terrain_panel.gd"
	)
	terrain_panel = terrain_panel_script.new() as TerrainPanel
	terrain_panel.name = "Terrain"
	terrain_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	terrain_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_tabs.add_child(terrain_panel)

	var gameplay_panel_script: Script = load(
		"res://addons/modular_tile_studio/ui/gameplay_markers_panel.gd"
	)
	gameplay_panel = gameplay_panel_script.new() as GameplayMarkersPanel
	gameplay_panel.name = "Gameplay"
	gameplay_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gameplay_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_tabs.add_child(gameplay_panel)

	var particle_panel_script: Script = load(
		"res://addons/modular_tile_studio/ui/particle_effects_panel.gd"
	)
	particle_effects_panel = particle_panel_script.new() as ParticleEffectsPanel
	particle_effects_panel.name = "Particles"
	particle_effects_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	particle_effects_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_tabs.add_child(particle_effects_panel)

	var material_paint_panel_script: Script = load(
		"res://addons/modular_tile_studio/ui/material_paint_panel.gd"
	)
	material_paint_panel = material_paint_panel_script.new()
	material_paint_panel.name = "Materials"
	material_paint_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	material_paint_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_tabs.add_child(material_paint_panel)
	# The visible top bar changes ownership immediately when Materials switches
	# between its circular pen and either use of the shared tile targeter.
	material_paint_panel.tile_brush_mode_changed.connect(_on_tile_brush_mode_changed)
	_left_tabs.tab_changed.connect(_on_left_tab_changed)

	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(right_split)

	viewport = StudioViewport.new()
	viewport.set_surface_grid_stroke_size(_surface_grid_stroke_size_spin.value)
	viewport.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_split.add_child(viewport)

	inspector = InspectorPanel.new()
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Never expands into the viewport: the split gives the inspector its
	# minimum and hands the rest to the map, so the panel cannot drift off
	# the right edge as the dock narrows.
	inspector.size_flags_horizontal = Control.SIZE_SHRINK_END
	right_split.add_child(inspector)

	root.add_child(_build_status_bar())

	_build_dialogs()

	viewport.status_changed.connect(func(text: String) -> void:
		_status_label.text = text
	)
	viewport.hover_changed.connect(_on_hover_changed)
	viewport.particle_hover_changed.connect(_on_particle_hover_changed)
	particle_effects_panel.preset_selected.connect(
		viewport.set_particle_effect_preset
	)
	particle_effects_panel.authoring_mode_changed.connect(
		func(_enabled: bool, erase_mode: bool) -> void:
			viewport.set_particle_effect_erase_mode(erase_mode)
			viewport.set_particle_effect_mode(_particle_mode_active())
	)
	particle_effects_panel.preset_changed.connect(
		func(_preset_id: String) -> void:
			viewport.refresh_particle_effects()
	)
	particle_effects_panel.attachment_changed.connect(
		viewport.set_particle_effect_attachment
	)
	particle_effects_panel.status_message.connect(
		func(message: String) -> void:
			_status_label.text = message
	)
	# The mode also changes from the E key and from picking a brush, so the
	# button follows the viewport rather than being the only thing that knows.
	# set_pressed_no_signal, or toggling it here would call straight back into
	# set_tool and fight whatever just changed it.
	viewport.tool_changed.connect(func(tool: int) -> void:
		if _erase_button != null:
			_erase_button.set_pressed_no_signal(tool == MTSPlacementController.Tool.ERASE)
		if _select_button != null:
			_select_button.set_pressed_no_signal(tool == MTSPlacementController.Tool.SELECT)
		if _fill_button != null:
			_fill_button.set_pressed_no_signal(tool == MTSPlacementController.Tool.FILL)
		if _fill_shape_option != null:
			_fill_shape_option.disabled = tool != MTSPlacementController.Tool.FILL
	)
	viewport.placement.replace_mode_changed.connect(func(enabled: bool) -> void:
		if _replace_button != null:
			_replace_button.set_pressed_no_signal(enabled)
	)
	# Fill is deliberately left armed when a terrain tool is selected: the two are
	# meant to combine, so Fill draws the shape and the terrain tool decides what
	# committing it does. Erase and Select still clear, because those genuinely
	# compete with terrain for the same drag.
	viewport.height_sculpt_tool_changed.connect(func(tool: int) -> void:
		if tool != MTSStudioViewport.HeightSculptTool.NONE:
			_erase_button.set_pressed_no_signal(false)
			_select_button.set_pressed_no_signal(false)
		_refresh_terrain_status()
	)
	viewport.footprint_tool_changed.connect(func(tool: int) -> void:
		if tool != MTSStudioViewport.FootprintTool.NONE:
			_erase_button.set_pressed_no_signal(false)
			_select_button.set_pressed_no_signal(false)
		_refresh_terrain_status()
	)
	# The terrain summary reports the derived cell counts, so the panel shows the
	# same state the gameplay grid will read rather than a separate tally.
	viewport.terrain_changed.connect(_refresh_terrain_status)
	terrain_panel.bind_viewport(viewport)
	# The visible skirt control edits the canonical TerrainMesh value consumed by
	# boundary geometry; the viewport owns the exact chunk-local derived refresh.
	terrain_panel.skirt_depth_changed.connect(viewport.set_terrain_skirt_depth)
	terrain_panel.import_terrain_glb_requested.connect(
		func() -> void: _open_file_dialog(true, "", true)
	)
	terrain_panel.clear_terrain_requested.connect(
		func() -> void: viewport.clear_terrain()
	)
	library_panel.asset_selected.connect(_on_asset_selected)
	library_panel.import_image_requested.connect(func() -> void: _open_file_dialog(false))
	library_panel.import_glb_requested.connect(func() -> void: _open_file_dialog(true))
	gameplay_panel.marker_brush_requested.connect(
		_on_gameplay_marker_brush_requested
	)
	gameplay_panel.marker_update_requested.connect(
		func(
			marker_id: String,
			marker_type: String,
			note: String,
			monster_id: String,
			pack_id: String
		) -> void:
			gameplay_marker_update_requested.emit(
				marker_id,
				marker_type,
				note,
				monster_id,
				pack_id
			)
	)
	gameplay_panel.marker_delete_requested.connect(
		func(marker_id: String) -> void:
			gameplay_marker_delete_requested.emit(marker_id)
	)
	gameplay_panel.enemy_pack_create_requested.connect(
		func(pack_id: String, note: String) -> void:
			enemy_pack_create_requested.emit(pack_id, note)
	)
	gameplay_panel.enemy_pack_update_requested.connect(
		func(pack_id: String, note: String) -> void:
			enemy_pack_update_requested.emit(pack_id, note)
	)
	gameplay_panel.enemy_pack_delete_requested.connect(
		func(pack_id: String) -> void:
			enemy_pack_delete_requested.emit(pack_id)
	)
	gameplay_panel.enemy_pack_assign_requested.connect(
		func(marker_ids: PackedStringArray, pack_id: String) -> void:
			enemy_pack_assign_requested.emit(marker_ids, pack_id)
	)
	gameplay_panel.monster_visual_assign_requested.connect(
		func(monster_id: String, asset_id: String) -> void:
			monster_visual_assign_requested.emit(monster_id, asset_id)
	)
	gameplay_panel.monster_visual_clear_requested.connect(
		func(monster_id: String) -> void:
			monster_visual_clear_requested.emit(monster_id)
	)
	gameplay_panel.monster_glb_import_requested.connect(
		func(monster_id: String) -> void:
			_open_file_dialog(true, monster_id)
	)
	gameplay_panel.placement_enabled_requested.connect(
		_on_gameplay_placement_enabled_requested
	)
	viewport.gameplay_markers.marker_placed.connect(
		func(marker_id: String) -> void:
			gameplay_panel.select_marker_id(marker_id)
	)


## Build the single top-level authoring bar and connect each visible value directly.
func _build_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)

	_add_button(bar, "New Board", func() -> void: new_board_requested.emit())
	_add_button(bar, "Open Board", func() -> void: open_board_requested.emit())
	_add_button(bar, "Save", func() -> void: save_board_requested.emit())
	_add_button(bar, "Rename", func() -> void: rename_board_requested.emit()).tooltip_text = 		"Change this level's name. The name is what the board is saved as and what it is called when it is opened again."
	_board_label = Label.new()
	_board_label.text = "Untitled Board"
	_board_label.custom_minimum_size = Vector2(180, 0)
	_board_label.clip_text = true
	_board_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_board_label.tooltip_text = "Current level name"
	bar.add_child(_board_label)
	_add_button(bar, "Export JSON", func() -> void: export_json_requested.emit())

	bar.add_child(VSeparator.new())

	_add_button(bar, "Import Image", func() -> void: _open_file_dialog(false))
	_add_button(bar, "Import GLB", func() -> void: _open_file_dialog(true))
	bar.add_child(VSeparator.new())

	# Fill is a visible, latching multi-placement mode. Clicked points define
	# a line or polygon, while the selected asset's actual oriented footprint
	# controls whole-stamp spacing for terrain paint and GLB props.
	_fill_button = Button.new()
	_fill_button.text = "Fill (G)"
	_fill_button.toggle_mode = true
	_fill_button.tooltip_text = "Place many copies of the active surface or GLB. Choose Path for an open multi-segment wall, road, or fence; choose Polygon to flood a closed boundary. Enter commits the preview as one undo step. Right-click or Backspace removes the last point, Escape cancels the shape, G toggles Fill, and B returns to Paint."
	_fill_button.toggled.connect(func(pressed: bool) -> void:
		viewport.set_tool(
			MTSPlacementController.Tool.FILL if pressed
			else MTSPlacementController.Tool.PAINT
		))
	bar.add_child(_fill_button)

	# This visible control determines whether the same clicked points are an open
	# route or a closed flooded boundary; the backend consumes this exact value.
	_fill_shape_option = OptionButton.new()
	_fill_shape_option.add_item(
		"Path",
		MTSPlacementController.FillShape.PATH
	)
	_fill_shape_option.add_item(
		"Polygon",
		MTSPlacementController.FillShape.POLYGON
	)
	_fill_shape_option.tooltip_text = "Path follows every clicked point as an open grid-snapped route. Polygon closes the points and fills only complete asset footprints inside the boundary."
	_fill_shape_option.disabled = true
	_fill_shape_option.item_selected.connect(func(index: int) -> void:
		viewport.set_fill_shape(_fill_shape_option.get_item_id(index))
	)
	bar.add_child(_fill_shape_option)

	# This integer width belongs only to direct tile-based texture placement.
	# The circular touch-up pen has its own independent control inside Materials.
	var grid_stroke_label := Label.new()
	grid_stroke_label.text = "Brush width"
	grid_stroke_label.tooltip_text = "Square brush width on the 1 m tile grid, shared by direct-texture stamping, Fill, and every terrain brush. 1 m covers one cell; a 2 m width covers an exact 2 x 2 square. Texture repeat size is unchanged."
	bar.add_child(grid_stroke_label)
	_surface_grid_stroke_size_spin = SpinBox.new()
	_surface_grid_stroke_size_spin.min_value = 1.0
	_surface_grid_stroke_size_spin.max_value = 100.0
	_surface_grid_stroke_size_spin.step = 1.0
	_surface_grid_stroke_size_spin.value = 1.0
	_surface_grid_stroke_size_spin.suffix = " m"
	_surface_grid_stroke_size_spin.custom_minimum_size = Vector2(92, 0)
	_surface_grid_stroke_size_spin.tooltip_text = grid_stroke_label.tooltip_text
	_surface_grid_stroke_size_spin.value_changed.connect(func(value: float) -> void:
		if viewport != null:
			viewport.set_surface_grid_stroke_size(value))
	bar.add_child(_surface_grid_stroke_size_spin)

	# Select has its own mode so pointer drags cannot accidentally paint,
	# erase, or alter terrain while the user is inspecting existing placements.
	_select_button = Button.new()
	_select_button.text = "Select (V)"
	_select_button.toggle_mode = true
	_select_button.tooltip_text = "Select mode: click an item to select it, drag a selected GLB or terrain paint region to move the selected group on the grid, and drag empty space to marquee-select multiple placements. Hold Ctrl to add or remove items from the group."
	_select_button.toggled.connect(func(pressed: bool) -> void:
		viewport.set_tool(
			MTSPlacementController.Tool.SELECT if pressed
			else MTSPlacementController.Tool.PAINT
		))
	bar.add_child(_select_button)

	# Erase as a visible, latching mode. Right-click has always erased, but an
	# unlabelled gesture is not something a user can discover -- "how do I delete
	# this" needs an answer on screen. Toggle rather than momentary so a whole
	# area can be cleared by dragging.
	_erase_button = Button.new()
	_erase_button.text = "Erase (E)"
	_erase_button.toggle_mode = true
	_erase_button.tooltip_text = "Erase mode: left-click and drag removes surfaces and props under the cursor.

Right-click erases at any time without switching modes, and Delete removes the current selection. Press E to toggle, or B to go back to painting."
	_erase_button.toggled.connect(func(pressed: bool) -> void:
		viewport.set_tool(
			MTSPlacementController.Tool.ERASE if pressed
			else MTSPlacementController.Tool.PAINT
		))
	bar.add_child(_erase_button)

	# Replace is separate from Paint, Fill, and Erase because it changes whether
	# occupied canonical space is rejected or atomically displaced. Its pressed
	# state mirrors the exact boolean that PlacementController consumes.
	_replace_button = Button.new()
	_replace_button.text = "Replace"
	_replace_button.toggle_mode = true
	_replace_button.tooltip_text = "When enabled, paint and Fill replace occupied surfaces or props of the same kind. The displaced placements and new brush stroke are one undo step."
	_replace_button.toggled.connect(func(pressed: bool) -> void:
		viewport.placement.set_replace_enabled(pressed)
	)
	bar.add_child(_replace_button)

	_prop_support_option = OptionButton.new()
	_prop_support_option.add_item("Prop: Floor", 0)
	_prop_support_option.add_item("Prop: Wall", 1)
	_prop_support_option.disabled = true
	_prop_support_option.tooltip_text = (
		"Whether a newly placed GLB prop stands on terrain ground or mounts on a "
		+ "terrain wall. Saved on the placement itself."
	)
	_prop_support_option.item_selected.connect(func(index: int) -> void:
		viewport.placement.set_prop_support(
			PropPlacement.SUPPORT_FLOOR
			if _prop_support_option.get_item_id(index) == 0
			else PropPlacement.SUPPORT_WALL
		)
	)
	bar.add_child(_prop_support_option)

	bar.add_child(VSeparator.new())

	# Terrain authoring lives in its own side panel beside Assets and Blockout:
	# footprint, sculpt, skirt and import are one workflow, and spreading them
	# across the toolbar hid that order behind unrelated tools.

	bar.add_child(VSeparator.new())

	_grid_check = CheckButton.new()
	_grid_check.text = "Top Grid"
	_grid_check.tooltip_text = "Show the dark 1 m grid drawn directly on the canonical heightfield top faces."
	_grid_check.button_pressed = true
	_grid_check.toggled.connect(func(pressed: bool) -> void: viewport.set_grid_visible(pressed))
	bar.add_child(_grid_check)

	_lattice_check = CheckButton.new()
	_lattice_check.text = "Side Grid"
	_lattice_check.tooltip_text = "Show the dark 1 m grid drawn directly on the canonical heightfield wall and skirt faces."
	_lattice_check.toggled.connect(func(pressed: bool) -> void: viewport.set_lattice_visible(pressed))
	bar.add_child(_lattice_check)

	# The camera mode is explicit because all options are orthographic editor
	# views: four snapped fixed directions, one orbitable angle, and one direct plan view.
	_camera_mode_option = OptionButton.new()
	_camera_mode_option.add_item("Camera: Fixed Isometric", MTSCameraController.Mode.ISOMETRIC)
	_camera_mode_option.add_item("Camera: Rotatable Isometric", MTSCameraController.Mode.ROTATABLE_ISOMETRIC)
	_camera_mode_option.add_item("Camera: Top Down", MTSCameraController.Mode.TOP_DOWN)
	_camera_mode_option.tooltip_text = "Choose the viewport camera.

Fixed Isometric: Q/E turns through four exact 90-degree directions around the current editing target. Direction 1 is the original fixed authoring view; pitch, framing, and zoom stay unchanged.

Rotatable Isometric: hold Q/E to orbit continuously around the current editing target; + / - and the mouse wheel zoom; WASD and middle-drag pan across the map. The camera keeps its fixed RPG top-down tilt.

Top Down: a direct plan view; + / - and the mouse wheel zoom; WASD and middle-drag pan across the map.

Every editor tool remains active: left-click paints or selects, right-click erases, and Fill, Height, rotation, layer, and toolbar controls work normally."
	_camera_mode_option.item_selected.connect(func(index: int) -> void:
		viewport.set_camera_mode(_camera_mode_option.get_item_id(index))
	)
	bar.add_child(_camera_mode_option)

	# The height-layer spinbox and slice modes are gone: terrain is the ground, so
	# a placement takes its height from the surface under the cursor rather than
	# from a separately chosen editing layer.
	bar.add_child(VSeparator.new())

	# GLB collision visibility is an explicit toggle over the live artwork.
	# Its red cells are the exact asset voxels used by collision and ray selection.
	_glb_voxels_check = CheckButton.new()
	_glb_voxels_check.text = "GLB Voxels"
	_glb_voxels_check.tooltip_text = (
		"Overlay every GLB's actual collision and ray-selection voxels."
	)
	_glb_voxels_check.toggled.connect(func(pressed: bool) -> void:
		if pressed and _movement_grid_window != null and _movement_grid_window.visible:
			_movement_grid_window.hide()
		viewport.set_occupancy_mode(
			OccupancyOverlay.Mode.SOLID
			if pressed
			else OccupancyOverlay.Mode.OFF
		)
	)
	bar.add_child(_glb_voxels_check)

	_add_button(bar, "Frame (Home)", func() -> void: viewport.frame_board())

	_add_button(bar, "Movement Grid", _open_movement_grid_panel).tooltip_text = "Edit global GLB collision filtering, manual walkability, and ground-effect labels."
	_add_button(bar, "Rendering", _open_aesthetics_panel).tooltip_text = "GPU surface effects for this board."
	_add_button(bar, "Lighting", _open_lighting_panel).tooltip_text = "Ambient, key and local lights, tonemapping, and colour grade for this board."

	var zoom_out := _add_button(bar, "-", func() -> void: viewport.camera.zoom_out())
	zoom_out.tooltip_text = "Zoom out in any camera view. Also use - or the mouse wheel."
	var zoom_in := _add_button(bar, "+", func() -> void: viewport.camera.zoom_in())
	zoom_in.tooltip_text = "Zoom in in any camera view. Also use + or the mouse wheel."

	return bar


func _add_button(parent: Control, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _build_status_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)

	# Every status field is fixed-width and clipped: the bar must never change
	# layout as its text changes, or the viewport above it shifts.
	_status_label = Label.new()
	_status_label.text = "Y=0 | slice ALL | NORMAL | 0 surfaces / 0 props"
	_status_label.custom_minimum_size = Vector2(320, 0)
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_status_label)

	bar.add_child(VSeparator.new())

	_brush_label = Label.new()
	_brush_label.text = "Brush: none"
	_brush_label.custom_minimum_size = Vector2(170, 0)
	_brush_label.clip_text = true
	_brush_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_brush_label)

	bar.add_child(VSeparator.new())

	_hover_label = Label.new()
	_hover_label.text = "Cell: -"
	_hover_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Validation messages vary a lot in length. Without clipping, a long
	# "occupied surface face at ..." grows the label, which resizes the status
	# bar and shoves the viewport -- the whole board appears to jerk while you
	# move the mouse. Clip instead of reflowing.
	_hover_label.clip_text = true
	_hover_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hover_label.custom_minimum_size = Vector2(240, 0)
	bar.add_child(_hover_label)

	_comfy_label = Label.new()
	_comfy_label.text = "ComfyUI: checking..."
	# Job progress messages change length constantly while analysis runs.
	_comfy_label.custom_minimum_size = Vector2(230, 0)
	_comfy_label.clip_text = true
	_comfy_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_comfy_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_comfy_label.tooltip_text = "Click to re-check the ComfyUI connection."
	_comfy_label.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			comfy_reconnect_requested.emit())
	bar.add_child(_comfy_label)

	return bar


## Build every modal used by the workspace, including the explicit destructive height-clear confirmation.
func _build_dialogs() -> void:
	image_dialog = ImageDialog.new()
	add_child(image_dialog)

	name_dialog = NameDialog.new()
	add_child(name_dialog)

	glb_dialog = GLBDialog.new()
	add_child(glb_dialog)


	# Plain FileDialog, deliberately NOT EditorFileDialog.
	#
	# EditorFileDialog drives its display mode from editor settings and renders
	# previews through the editor's own previewer, which only knows about files
	# already imported into the project. Browsing an external folder there gives
	# generic icons and ignores a supplied thumbnail callback. FileDialog honours
	# both display_mode and set_get_thumbnail_callback, which is what lets us
	# show real previews of arbitrary files on disk.
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# ACCESS_FILESYSTEM so PNGs and GLBs can be pulled in from anywhere, e.g.
	# straight out of a Meshy or ChatGPT download folder.
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = false
	_file_dialog.display_mode = FileDialog.DISPLAY_THUMBNAILS
	_file_dialog.add_theme_constant_override(
		"thumbnail_size",
		FILE_THUMBNAIL_SIZE
	)
	# NOTE: this setter is static, so it applies to every FileDialog in the
	# editor, not just ours, and the callable keeps this node alive. _exit_tree
	# clears it again so a plugin reload does not leave the editor calling into
	# a freed panel.
	FileDialog.set_get_thumbnail_callback(_thumbnail_for)
	_file_dialog.canceled.connect(func() -> void:
		_pending_monster_import_id = ""
	)
	add_child(_file_dialog)


func _exit_tree() -> void:
	# Drop the global callback we installed in _build_dialogs.
	FileDialog.set_get_thumbnail_callback(Callable())
	# Any in-flight worker would call_deferred onto a node that is going away.
	_thumbnail_pending.clear()
	_thumbnail_cache.clear()


## Thumbnail provider for the import file dialog.
##
## FileDialog calls this on the main thread while it is laying out the file
## grid, so anything slow in here stalls the whole editor. Decoding and scaling
## a folder of 4K PNGs synchronously is what froze Godot: image.load() decodes
## the file at full resolution before we ever get a chance to shrink it.
##
## So this returns an empty ImageTexture straight away and fills it in from a
## worker thread. This is the pattern the FileDialog docs prescribe.
func _thumbnail_for(path: String) -> Texture2D:
	if path.is_empty() or path.ends_with("/"):
		return null
	var extension := path.get_extension().to_lower()
	if not extension in THUMBNAIL_EXTENSIONS:
		return null

	var modified := FileAccess.get_modified_time(path)
	var key := "%s|%d" % [path, modified]
	if _thumbnail_cache.has(key):
		return _thumbnail_cache[key]

	# Handed back this frame, still blank. The worker fills its image in later
	# and the dialog repaints itself when it does.
	var texture := ImageTexture.new()
	# Bound the cache: a big Downloads folder would otherwise pin every preview
	# in memory for the rest of the session.
	if _thumbnail_cache.size() >= THUMBNAIL_CACHE_LIMIT:
		_thumbnail_cache.clear()
		_thumbnail_pending.clear()
	_thumbnail_cache[key] = texture
	_thumbnail_pending[key] = texture

	# WorkerThreadPool rather than a raw Thread: one dialog can ask for dozens of
	# thumbnails at once, and the pool bounds how many decodes run concurrently
	# instead of spawning a thread per file.
	WorkerThreadPool.add_task(
		_decode_thumbnail.bind(path, key),
		true,
		"tile_studio_thumbnail"
	)
	return texture


## Runs on a pool thread. Decodes and scales, then hands the finished image back
## to the main thread; ImageTexture.set_image() is not safe to call from here.
func _decode_thumbnail(path: String, key: String) -> void:
	var image := Image.new()
	var error := image.load(path)
	if error != OK or image.is_empty():
		return

	# Fit inside the requested box, preserving aspect so tall doorway art is not
	# squashed into a square.
	var longest := maxi(image.get_width(), image.get_height())
	if longest > FILE_THUMBNAIL_SIZE:
		var factor := float(FILE_THUMBNAIL_SIZE) / float(longest)
		# INTERPOLATE_BILINEAR, not LANCZOS: Lanczos over a full-resolution 4K
		# source is far more expensive than the result is worth at 128px.
		image.resize(
			maxi(1, roundi(image.get_width() * factor)),
			maxi(1, roundi(image.get_height() * factor)),
			Image.INTERPOLATE_BILINEAR
		)

	# EXR and similar come back in formats ImageTexture will not take directly.
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	_apply_thumbnail.call_deferred(key, image)


## Main thread. Fills in the placeholder handed out earlier, if it is still live.
func _apply_thumbnail(key: String, image: Image) -> void:
	var texture: ImageTexture = _thumbnail_pending.get(key)
	if texture == null:
		# Cache was cleared out from under us while the worker was decoding.
		return
	_thumbnail_pending.erase(key)
	texture.set_image(image)


func _open_file_dialog(
	is_glb: bool,
	monster_id: String = "",
	is_terrain: bool = false
) -> void:
	_pending_monster_import_id = monster_id if is_glb else ""
	_pending_terrain_import = is_terrain
	_file_dialog.clear_filters()
	if is_glb:
		_file_dialog.add_filter("*.glb", "GLB models")
		_file_dialog.add_filter("*.gltf", "glTF models")
		_file_dialog.title = (
			"Select a heightfield GLB" if is_terrain else "Select a GLB prop"
		)
	else:
		_file_dialog.add_filter("*.png", "PNG images")
		_file_dialog.add_filter("*.jpg,*.jpeg", "JPEG images")
		_file_dialog.title = "Select a surface image"

	# Thumbnails only mean something for images; GLBs have no previewable file
	# content, so a flat list shows more of their names per screen.
	_file_dialog.display_mode = (
		FileDialog.DISPLAY_LIST if is_glb else FileDialog.DISPLAY_THUMBNAILS
	)

	# Reopen where the user last was, per kind: images and GLBs usually live in
	# different folders.
	var remembered: String = _last_dir_glb if is_glb else _last_dir_image
	if not remembered.is_empty() and DirAccess.dir_exists_absolute(remembered):
		_file_dialog.current_dir = remembered

	# Reconnect fresh each time so the previous mode's handler does not fire.
	for connection in _file_dialog.file_selected.get_connections():
		_file_dialog.file_selected.disconnect(connection["callable"])
	if is_glb:
		_file_dialog.file_selected.connect(func(path: String) -> void:
			_last_dir_glb = path.get_base_dir()
			if _pending_terrain_import:
				import_terrain_glb_selected.emit(path)
			elif _pending_monster_import_id.is_empty():
				import_glb_selected.emit(path)
			else:
				monster_glb_selected.emit(path, _pending_monster_import_id)
			_pending_monster_import_id = ""
			_pending_terrain_import = false
		)
	else:
		_file_dialog.file_selected.connect(func(path: String) -> void:
			_last_dir_image = path.get_base_dir()
			import_image_selected.emit(path))
	_file_dialog.popup_centered_ratio(0.75)


## Open the first top-level board panel for collision and movement-cell authoring.
func _open_movement_grid_panel() -> void:
	if _movement_grid_window == null:
		movement_grid_panel = MovementGridPanelScene.new()
		movement_grid_panel.collision_threshold_apply_requested.connect(
			_on_movement_collision_threshold_requested
		)
		movement_grid_panel.collision_measurement_requested.connect(
			_on_movement_collision_measurement_requested
		)
		movement_grid_panel.editing_tool_changed.connect(
			viewport.set_movement_grid_tool
		)
		movement_grid_panel.ground_effect_label_changed.connect(
			viewport.set_movement_ground_effect_label
		)
		viewport.movement_grid_cell_changed.connect(
			_on_movement_grid_cell_changed
		)
		_movement_grid_window = _make_panel_window(
			"Movement Grid",
			Vector2i(560, 650),
			movement_grid_panel
		)
		_movement_grid_window.min_size = Vector2i(480, 460)
		_movement_grid_window.visibility_changed.connect(
			_sync_movement_grid_visibility
		)
		movement_grid_panel.bind(viewport.board)
	_show_panel_window(_movement_grid_window)
	_sync_movement_grid_visibility()


## Keep movement shading and cell input alive exactly while its panel is visible.
func _sync_movement_grid_visibility() -> void:
	if viewport == null:
		return
	var active := (
		_movement_grid_window != null
		and _movement_grid_window.visible
	)
	if active:
		_glb_voxels_check.set_pressed_no_signal(false)
		viewport.set_gameplay_marker_mode(false)
		viewport.set_particle_effect_mode(false)
		viewport.set_material_paint_tool(
			MTSStudioViewport.MaterialPaintTool.NONE
		)
		viewport.set_movement_grid_tool(movement_grid_panel.editing_tool())
		viewport.set_movement_ground_effect_label(
			movement_grid_panel.ground_effect_label()
		)
		_set_exclusive_authoring_toolbar_state(true)
		_brush_label.text = "Movement Grid: left-click applies the selected cell action"
	else:
		_on_left_tab_changed(_left_tabs.current_tab)
	viewport.set_movement_grid_mode(active)


## Apply the staged board-wide collision rule and report the exact voxel delta.
func _on_movement_collision_threshold_requested(threshold_percent: float) -> void:
	var report := viewport.apply_movement_collision_threshold(threshold_percent)
	if movement_grid_panel != null:
		movement_grid_panel.show_collision_result(report)


## Forward explicit legacy-GLB measurement to the plugin that owns asset resources.
func _on_movement_collision_measurement_requested() -> void:
	movement_collision_measure_requested.emit()


## Mirror one saved cell edit in the open movement panel.
func _on_movement_grid_cell_changed(
	cell: Vector2i,
	state: Dictionary
) -> void:
	if movement_grid_panel != null:
		movement_grid_panel.show_cell_feedback(cell, state)


## Rendering and Lighting are independent top-level board panels.
##
## Each lives in its own floating, resizable Window rather than an AcceptDialog
## so it can stay open while the board is worked on.
func _open_aesthetics_panel() -> void:
	if _aesthetics_window == null:
		aesthetics_panel = AestheticsPanelScene.new()
		# GPU surface controls need a wide first-open size. The user can still
		# resize it, while the minimum preserves a full slider/value row.
		_aesthetics_window = _make_panel_window("Rendering Settings", Vector2i(600, 760), aesthetics_panel)
		_aesthetics_window.min_size = Vector2i(520, 420)
		aesthetics_panel.bind(viewport.board)
	else:
		aesthetics_panel.rebuild()

	# Existing editor sessions can still hold the pre-GPU 420 px window. Grow
	# only undersized instances so the new rows are reachable without discarding
	# a user's larger custom window size.
	var rendering_minimum := Vector2i(520, 420)
	if _aesthetics_window.size.x < rendering_minimum.x or _aesthetics_window.size.y < rendering_minimum.y:
		_aesthetics_window.size = Vector2i(
			maxi(_aesthetics_window.size.x, rendering_minimum.x),
			maxi(_aesthetics_window.size.y, rendering_minimum.y)
		)
	_show_panel_window(_aesthetics_window)


## Open the board lighting editor and wire its surface-placement controls to the viewport.
func _open_lighting_panel() -> void:
	if _lighting_window == null:
		lighting_panel = LightingPanelScene.new()
		# This editor-session signal only changes the viewport preview; it never touches BoardDocument.
		lighting_panel.painting_light_override_changed.connect(
			viewport.set_painting_light_override_enabled
		)
		lighting_panel.local_light_selected.connect(
			viewport.select_local_light_handle
		)
		lighting_panel.local_light_create_requested.connect(
			viewport.begin_local_light_placement
		)
		viewport.local_light_handle_selected.connect(
			lighting_panel.select_local_light
		)
		viewport.local_light_handle_changed.connect(
			lighting_panel.refresh_local_light_transform
		)
		_lighting_window = _make_panel_window("Lighting", Vector2i(620, 820), lighting_panel)
		_lighting_window.min_size = Vector2i(520, 480)
		_lighting_window.visibility_changed.connect(
			_sync_lighting_handle_visibility
		)
		lighting_panel.bind(viewport.board)
	else:
		lighting_panel.rebuild()
	_show_panel_window(_lighting_window)
	_sync_lighting_handle_visibility()


## Keep positional light globs alive exactly while the Lighting window is visible.
func _sync_lighting_handle_visibility() -> void:
	if viewport == null:
		return
	var handles_visible := (
		_lighting_window != null
		and _lighting_window.visible
	)
	viewport.set_light_handles_visible(handles_visible)
	if handles_visible and lighting_panel != null:
		viewport.select_local_light_handle(
			lighting_panel.selected_local_light()
		)


func _make_panel_window(title: String, size: Vector2i, panel: Control) -> Window:
	var window := Window.new()
	window.title = title
	window.size = size
	window.min_size = Vector2i(340, 300)
	window.wrap_controls = false
	window.transient = true
	window.unresizable = false
	# Hide rather than free, so a panel keeps its scroll position and selected
	# light across closes, and its board binding survives.
	window.close_requested.connect(window.hide)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	window.add_child(margin)

	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(panel)

	add_child(window)
	return window


func _show_panel_window(window: Window) -> void:
	if window.visible:
		window.grab_focus()
		return
	window.popup_centered(window.size)


## Point every board-bound panel at the current document.
##
## Called on New Board and Open Board so no open panel can keep editing the
## document that was just replaced.
func bind_look_panels(board: BoardDocument) -> void:
	if movement_grid_panel != null:
		movement_grid_panel.bind(board)
	if aesthetics_panel != null:
		aesthetics_panel.bind(board)
	if lighting_panel != null:
		lighting_panel.bind(board)
	if material_paint_panel != null and _asset_library != null:
		material_paint_panel.bind(board, _asset_library, viewport)
	# The terrain panel reports the live footprint, walls and derived paint units,
	# so it must follow the document exactly as the look panels do.
	if terrain_panel != null:
		terrain_panel.bind_board(board)


## Bind the board and PNG asset vocabulary to the material paint tab.
func bind_material_paint(
	board: BoardDocument,
	asset_library: AssetLibrary
) -> void:
	_asset_library = asset_library
	if material_paint_panel != null:
		material_paint_panel.bind(board, asset_library, viewport)


## Bind the canonical gameplay records to their visible editor panel.
func bind_gameplay(board: BoardDocument, library: AssetLibrary = null) -> void:
	gameplay_panel.bind(board, library)


## Bind the current board and reusable custom particle-preset library to their panel.
func bind_particles(
	board: BoardDocument,
	library: ParticleEffectLibrary
) -> void:
	particle_effects_panel.bind(board, library)


## Display one marker or pack operation result in the Gameplay tab.
func show_gameplay_result(result: Dictionary) -> void:
	gameplay_panel.show_result(result)


## Select one gameplay marker after editor or API mutation.
func select_gameplay_marker(marker_id: String) -> void:
	gameplay_panel.select_marker_id(marker_id)


## Select a direct asset brush only while the visible Assets tab owns authoring.
func _on_asset_selected(asset: TileAsset) -> void:
	if _gameplay_mode_active():
		return
	inspector.set_asset(asset)
	viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
	viewport.placement.set_brush(asset)
	# The placement controller keeps Fill active for both surfaces and GLBs;
	# selecting a new brush clears only the unfinished transient shape.
	_brush_label.text = "Brush: %s" % asset.asset_id
	_brush_label.tooltip_text = asset.asset_id
	# Support is a GLB-only contract, so the control is live exactly when a prop
	# brush is active and disabled for terrain paint.
	_prop_support_option.disabled = not asset.is_prop()
	if asset.is_prop():
		_prop_support_option.select(0)
		viewport.placement.set_prop_support(PropPlacement.SUPPORT_FLOOR)


## Apply the visible Gameplay form as the exact marker brush used by grid clicks.
func _on_gameplay_marker_brush_requested(
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> void:
	viewport.set_gameplay_marker_brush(
		marker_type,
		note,
		monster_id,
		pack_id
	)
	_brush_label.text = "Marker: %s" % marker_type
	_brush_label.tooltip_text = note


## Apply the active Gameplay sub-tab's placement ownership without hiding marker visuals.
func _on_gameplay_placement_enabled_requested(enabled: bool) -> void:
	if _gameplay_mode_active() and viewport != null:
		viewport.gameplay_markers.set_active(enabled)


## Return whether the visible left tab owns gameplay marker authoring.
func _gameplay_mode_active() -> bool:
	if _left_tabs == null or gameplay_panel == null:
		return false
	return (
		_left_tabs.current_tab
		== _left_tabs.get_tab_idx_from_control(gameplay_panel)
	)


## Return whether the visible left tab owns custom particle-effect placement.
func _particle_mode_active() -> bool:
	if _left_tabs == null or particle_effects_panel == null:
		return false
	return (
		_left_tabs.current_tab
		== _left_tabs.get_tab_idx_from_control(particle_effects_panel)
	)


## Return whether the visible left tab owns direct PNG material painting.
func _material_mode_active() -> bool:
	if _left_tabs == null or material_paint_panel == null:
		return false
	return (
		_left_tabs.current_tab
		== _left_tabs.get_tab_idx_from_control(material_paint_panel)
	)


## Give the top bar to the active authoring path while material Tile brush keeps its controls.
func _set_exclusive_authoring_toolbar_state(
	exclusive_mode: bool,
	material_tile_brush: bool = false
) -> void:
	var base_coat_controls_available := not exclusive_mode or material_tile_brush
	_fill_button.disabled = not base_coat_controls_available
	_fill_shape_option.disabled = (
		not base_coat_controls_available
		or not _fill_button.button_pressed
	)
	_select_button.disabled = exclusive_mode
	_erase_button.disabled = not base_coat_controls_available
	_replace_button.disabled = not base_coat_controls_available
	if exclusive_mode:
		_select_button.set_pressed_no_signal(false)
		_prop_support_option.disabled = true
	if exclusive_mode and not material_tile_brush:
		_fill_button.set_pressed_no_signal(false)
		_erase_button.set_pressed_no_signal(false)
		_replace_button.set_pressed_no_signal(false)


## Switch viewport-input ownership to the exact visible authoring tab.
func _on_left_tab_changed(_tab_index: int) -> void:
	if viewport == null or viewport.placement == null or inspector == null:
		return
	if _movement_grid_window != null and _movement_grid_window.visible:
		viewport.set_gameplay_marker_mode(false)
		viewport.set_particle_effect_mode(false)
		viewport.set_material_paint_tool(
			MTSStudioViewport.MaterialPaintTool.NONE
		)
		_set_exclusive_authoring_toolbar_state(true)
		return
	var gameplay_mode := _gameplay_mode_active()
	var particle_mode := _particle_mode_active()
	var material_mode := _material_mode_active()
	var material_tile_brush: bool = (
		material_mode
		and material_paint_panel.uses_tile_brush()
	)
	inspector.visible = (
		not gameplay_mode
		and not particle_mode
		and not material_mode
	)
	viewport.set_gameplay_marker_mode(gameplay_mode)
	viewport.set_particle_effect_mode(particle_mode)
	if not material_mode:
		viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
		viewport.set_splatmap_tile_paint_enabled(false)
		viewport.set_material_tile_paint_enabled(false)
	_set_exclusive_authoring_toolbar_state(
		gameplay_mode or particle_mode or material_mode,
		material_tile_brush
	)
	if gameplay_mode:
		gameplay_panel.activate_current_workspace()
	elif particle_mode:
		_brush_label.text = "Particles mode: left place / right erase"
	elif material_mode:
		material_paint_panel.activate()
		if material_tile_brush:
			_brush_label.text = (
				"Splatmap base coat: tile Paint / Replace / Erase / Fill"
				if viewport.splatmap_tile_paint_enabled
				else "Masked material: tile Paint / Replace / Erase / Fill"
			)
		else:
			_brush_label.text = "Materials mode: left paint / right or inverted pen erase"
	else:
		_brush_label.text = "Assets mode: select an asset"


## Refresh toolbar ownership as soon as the visible Materials targeting mode changes.
func _on_tile_brush_mode_changed(_enabled: bool) -> void:
	if _material_mode_active():
		_on_left_tab_changed(_left_tabs.current_tab)


## Present one ordinary grid hover result from the active non-particle authoring tool.
func _on_hover_changed(cell: Vector3i, valid: bool, reason: String) -> void:
	var text := "Cell: %d, %d, %d" % [cell.x, cell.y, cell.z]
	if viewport.movement_grid_mode_active():
		text += "   MOVEMENT GRID   %s   left: apply" % reason
	elif _gameplay_mode_active():
		text += "   GAMEPLAY %s   left: place   right: erase" % viewport.gameplay_markers.brush_marker_type
	elif viewport.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
		text += "   TERRAIN %s   %s" % [viewport.height_sculpt_tool_name(), reason]
	elif viewport.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
		text += "   FOOTPRINT %s   left: draw   right: erase" % viewport.footprint_tool_name()
	elif viewport.placement.has_brush():
		if viewport.placement.brush_is_surface():
			text += "   face %s   rot %d" % [
				K.face_name(viewport.placement.brush_face),
				viewport.placement.brush_quarters * 90
			]
		else:
			text += "   front %s   roll %d   yaw %d" % [
				K.face_name(viewport.placement.brush_prop_forward_face),
				viewport.placement.brush_prop_roll_quarters * 90,
				viewport.placement.brush_prop_yaw_eighths * 45,
			]
		text += "   left/right: turn   up/down: flip   shift-left/right: roll"
	text += "   VALID" if valid else "   INVALID: %s" % reason
	_hover_label.text = text
	# Full message on hover, since the label itself is clipped to keep the
	# status bar a fixed size.
	_hover_label.tooltip_text = text
	_hover_label.modulate = Color(1, 1, 1) if valid else Color(1, 0.65, 0.6)


## Present the exact world-space particle emitter position under the pointer.
func _on_particle_hover_changed(
	position: Vector3,
	valid: bool,
	reason: String
) -> void:
	var text := "Particle: %.2f, %.2f, %.2f   left: place   right: erase" % [
		position.x,
		position.y,
		position.z,
	]
	text += "   VALID" if valid else "   INVALID: %s" % reason
	_hover_label.text = text
	_hover_label.tooltip_text = text
	_hover_label.modulate = Color(1, 1, 1) if valid else Color(1, 0.65, 0.6)


func set_comfy_status(available: bool, detail: String) -> void:
	_comfy_label.text = "ComfyUI: %s" % detail
	_comfy_label.modulate = Color(0.55, 0.9, 0.6) if available else Color(0.9, 0.65, 0.45)


func set_board_name(board_name: String) -> void:
	if _board_label != null:
		_board_label.text = board_name
		_board_label.tooltip_text = board_name


## Show one explicit status message from a plugin-side action.
func set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


## Report the live terrain tally in the status bar.
##
## The Terrain panel owns every terrain CONTROL; this only keeps the status bar's
## one-line summary honest, because that line is visible whichever tab is open.
func _refresh_terrain_status() -> void:
	if terrain_panel != null:
		terrain_panel.refresh()
	if viewport == null or _brush_label == null or viewport.board == null:
		return
	var terrain: TerrainMesh = viewport.board.terrain
	var sculpting := viewport.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE
	var drawing := viewport.footprint_tool != MTSStudioViewport.FootprintTool.NONE
	if terrain.is_empty():
		if drawing:
			_brush_label.text = "Footprint: draw the encounter boundary to begin"
		return
	if not (sculpting or drawing):
		return
	var levels: Dictionary = {}
	var ramps := 0
	for entry: Dictionary in viewport.board.gameplay_grid():
		if int(entry["form"]) == TerrainMesh.CellForm.RAMP:
			ramps += 1
		levels[snappedf(float(entry["walk_height_m"]), 0.01)] = true
	_brush_label.text = "Terrain: %d cells   %d levels   %d ramps   %d walls" % [
		terrain.filled_cell_count(),
		levels.size(),
		ramps,
		terrain.side_faces.size(),
	]
