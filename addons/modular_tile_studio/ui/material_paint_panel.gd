@tool
class_name MaterialPaintPanel
extends VBoxContainer

## Announce when the visible mode changes which top-toolbar tools own viewport input.
signal tile_brush_mode_changed(enabled: bool)

## Presents one visual material-and-mask setup for local brush work and explicit level passes.
##
## Selecting a thumbnail is deliberately non-mutating: a brush layer is created only after the
## user chooses a mask, and a procedural layer changes only through the bottom action button.

enum Workflow {
	PAINT,
	PROCEDURAL,
}

## Select which visible targeting shape owns local mask-blended material strokes.
enum PaintTarget {
	CIRCULAR_PEN,
	TILE_BRUSH,
}

enum MaskPreset {
	NONE,
	BASE_HEIGHT_LOW,
	BASE_HEIGHT_HIGH,
	WORLD_HEIGHT_LOW,
	WORLD_HEIGHT_HIGH,
	BASE_CAVITY_LOW,
	BASE_CAVITY_HIGH,
	BASE_CURVATURE_LOW,
	BASE_CURVATURE_HIGH,
	BASE_AO_LOW,
	BASE_AO_HIGH,
	BASE_ROUGHNESS_LOW,
	BASE_ROUGHNESS_HIGH,
	BASE_METALLIC_LOW,
	BASE_METALLIC_HIGH,
	BASE_LUMINANCE_LOW,
	BASE_LUMINANCE_HIGH,
	BASE_MATERIAL_ID_LOW,
	BASE_MATERIAL_ID_HIGH,
	ABSOLUTE_ELEVATION_LOW,
	ABSOLUTE_ELEVATION_HIGH,
	SURFACE_UP_LOW,
	SURFACE_UP_HIGH,
	SURFACE_SLOPE_LOW,
	SURFACE_SLOPE_HIGH,
	SURFACE_BOTTOM,
	SURFACE_TOP,
	CONTACT_LOW,
	CONTACT_HIGH,
	SMOOTH_NOISE_LOW,
	SMOOTH_NOISE_HIGH,
	RIDGED_NOISE_LOW,
	RIDGED_NOISE_HIGH,
	CELLULAR_NOISE_LOW,
	CELLULAR_NOISE_HIGH,
	DIRECTIONAL_BANDS_LOW,
	DIRECTIONAL_BANDS_HIGH,
	CUSTOM,
}

enum MoreAction {
	MATERIAL_APPEARANCE,
	MASK_STACK,
	PAINT_SYSTEM,
	REMOVE_MATERIAL,
	REMOVE_LEVEL_PASS,
	CLEAR_BRUSH_PAINT,
}

const MASK_SELECTION_REQUIRED: int = 1000
const MATERIAL_THUMBNAIL_SIZE: Vector2i = Vector2i(72, 72)
const MASK_PRESET_NAMES: PackedStringArray = [
	"",
	"Texture height — bottom",
	"Texture height — top",
	"Level height — bottom",
	"Level height — top",
	"Cavity — recessed",
	"Cavity — exposed",
	"Curvature — concave",
	"Curvature — convex",
	"Ambient occlusion — dark",
	"Ambient occlusion — exposed",
	"Roughness — smooth",
	"Roughness — rough",
	"Metallic — nonmetal",
	"Metallic — metal",
	"Albedo — dark",
	"Albedo — light",
	"Material ID — lower values",
	"Material ID — higher values",
	"Absolute elevation — below",
	"Absolute elevation — above",
	"Surface facing — vertical",
	"Surface facing — upward",
	"Slope — gentle",
	"Slope — steep",
	"Surface-local bottom",
	"Surface-local top",
	"Contact — away",
	"Contact — near",
	"Smooth noise — lower values",
	"Smooth noise — higher values",
	"Ridged noise — valleys",
	"Ridged noise — ridges",
	"Cellular noise — cell centres",
	"Cellular noise — cell borders",
	"Directional bands — troughs",
	"Directional bands — crests",
	"Custom mask stack…",
]
const MASK_SOURCE_NAMES: PackedStringArray = [
	"Painted material weight",
	"Base height",
	"Base cavity",
	"Base curvature",
	"Base ambient occlusion",
	"Base roughness",
	"Base metallic",
	"Base albedo luminance",
	"Base material ID",
	"Map-wide height",
	"Absolute elevation",
	"Surface upwardness",
	"Surface slope",
	"Surface bottom",
	"Surface top",
	"Contact field",
	"Smooth noise",
	"Ridged noise",
	"Cellular noise",
	"Directional bands",
]
const COMBINE_NAMES: PackedStringArray = [
	"Multiply",
	"Add",
	"Subtract",
	"Maximum",
	"Minimum",
]
const DEBUG_NAMES: PackedStringArray = [
	"Final material",
	"Layer 1 mask",
	"Layer 2 mask",
	"Layer 3 mask",
	"Layer 4 mask",
	"Painted RGBA",
	"Base height",
	"Map-wide height",
]
const SPLATMAP_PROJECTION_NAMES: PackedStringArray = [
	"Top",
	"North",
	"South",
	"East",
	"West",
]
const SPLATMAP_CHANNEL_NAMES: PackedStringArray = ["R", "G", "B", "A"]
const PAINT_TARGET_NAMES: PackedStringArray = ["Circular pen", "Tile brush"]
## The one description of what the mask preview does, shared by the control and by
## _mask_preview_tooltip() so the enabled wording never drifts from the disabled wording.
const MASK_PREVIEW_TOOLTIP: String = (
	"Tint every location accepted by the selected mask neon green without "
	+ "creating brush paint or changing the board."
)

var board: BoardDocument
var library: AssetLibrary
var viewport: MTSStudioViewport
var _draft: MaterialBlendProfile
var _updating: bool = false
var _selected_layers: PackedInt32Array = PackedInt32Array([-1, -1])
var _pending_assets: PackedStringArray = PackedStringArray(["", ""])
var _selected_rule: int = 0
var _pending_remove_layer: int = -1

var _more_menu: MenuButton
## Explicitly grants one unconstrained overlay layer ownership of terrain-paint input.
var _no_constraint_mode: CheckButton
## Explicitly grants the selected mask layer ownership of terrain-paint input.
var _mask_paint_mode: CheckButton
var _mask_preview: CheckButton
var _splatmap_mode: CheckButton
var _splatmap_projection: OptionButton
var _splatmap_overlay: CheckButton
var _splatmap_live_controls_box: VBoxContainer
var _splatmap_setup_button: Button
var _splatmap_workflow_box: VBoxContainer
var _splatmap_channel_gallery: ItemList
var _material_gallery_label: Label
var _material_gallery: ItemList
var _material_asset_ids: PackedStringArray = PackedStringArray()
## Enables one-click native Decal stamping instead of material-layer painting.
var _decal_mode: CheckButton
## Enables one-click material stamping through the ordinary terrain shader.
##
## Mutually exclusive with the native decal toggle, because a placement has one
## render role and showing two armed stamp modes would not say which one commits.
var _shader_decal_mode: CheckButton
## Enables nearest-grid-edge targeting for either decal presentation.
var _decal_edge_mode: CheckButton
## Enables explicit albedo palette matching for either decal presentation.
var _match_underlying_palette: CheckButton
var _mask_row: HBoxContainer
var _mask: OptionButton
var _range_low_row: HBoxContainer
var _range_low: HSlider
var _range_high_row: HBoxContainer
var _range_high: HSlider
var _fade_row: HBoxContainer
var _fade: HSlider
var _influence_row: HBoxContainer
var _influence: HSlider
var _invert: CheckButton
var _noise_scale_row: HBoxContainer
var _noise_scale: HSlider
var _noise_seed_row: HBoxContainer
var _noise_seed: SpinBox
var _noise_angle_row: HBoxContainer
var _noise_angle: SpinBox
var _brush_box: VBoxContainer
var _paint_target: OptionButton
var _brush_radius_row: HBoxContainer
var _brush_radius: SpinBox
var _brush_opacity: HSlider
var _hardness_row: HBoxContainer
var _hardness: HSlider
var _status: Label
var _procedural_button: Button
var _slider_labels: Dictionary = {}

var _material_dialog: AcceptDialog
var _material_scale: HSlider
var _material_height_blend: HSlider

var _mask_dialog: AcceptDialog
var _rule_select: OptionButton
var _add_rule_button: Button
var _remove_rule_button: Button
var _rule_source: OptionButton
var _rule_combine: OptionButton
var _rule_channel: OptionButton
var _rule_low: SpinBox
var _rule_high: SpinBox
var _rule_fade: SpinBox
var _rule_strength: SpinBox
var _rule_invert: CheckButton
var _rule_noise_scale: SpinBox
var _rule_noise_seed: SpinBox
var _rule_noise_angle: SpinBox

var _splatmap_dialog: AcceptDialog
var _splatmap_file_dialog: FileDialog
var _splatmap_path: LineEdit
var _splatmap_slots: Array[Button] = []
var _splatmap_slot_previews: Array[TextureRect] = []
var _splatmap_slot_labels: Array[Label] = []
var _splatmap_slot_asset_state: PackedStringArray = PackedStringArray(["", "", "", ""])
var _splatmap_picker_popup: PopupPanel
var _splatmap_picker_title: Label
var _splatmap_picker_gallery: ItemList
var _splatmap_picker_asset_ids: PackedStringArray = PackedStringArray()
var _active_splatmap_slot: int = -1
var _splatmap_fill_empty_regions: CheckButton
var _splatmap_empty_region_channel: OptionButton
var _splatmap_channel_strengths_enabled: CheckButton
var _splatmap_channel_strength_sliders: Array[HSlider] = []
var _splatmap_summary: Label

var _settings_dialog: AcceptDialog
var _blend_mode: OptionButton
var _debug_view: OptionButton
var _paint_detail: SpinBox
var _maximum_edge: SpinBox
var _paint_memory_summary: Label
var _apply_resolution_button: Button
var _pressure_size: CheckButton
var _pressure_opacity: CheckButton
## Controls the optional derived seed for tiny top and bottom side-grid residuals.
var _auto_texture_thin_side_slivers: CheckButton

var _remove_dialog: ConfirmationDialog
var _clear_dialog: ConfirmationDialog
var _resolution_dialog: ConfirmationDialog


## Build the compact workflow and its contextual editors once when the panel enters the tree.
func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(form)

	var title_row := HBoxContainer.new()
	form.add_child(title_row)
	var title := Label.new()
	title.text = "Surface Materials"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	_more_menu = MenuButton.new()
	_more_menu.text = "More…"
	_more_menu.tooltip_text = "Open the less-frequent appearance, mask-stack, paint-system, removal, and clearing actions."
	var more_popup := _more_menu.get_popup()
	more_popup.add_item("Material Appearance…", MoreAction.MATERIAL_APPEARANCE)
	more_popup.add_item("Full Mask Stack…", MoreAction.MASK_STACK)
	more_popup.add_item("Paint System…", MoreAction.PAINT_SYSTEM)
	more_popup.add_separator()
	more_popup.add_item("Remove Current Material…", MoreAction.REMOVE_MATERIAL)
	more_popup.add_item("Remove Procedural Level Pass…", MoreAction.REMOVE_LEVEL_PASS)
	more_popup.add_item("Clear Brush Paint…", MoreAction.CLEAR_BRUSH_PAINT)
	more_popup.set_item_tooltip(more_popup.get_item_index(MoreAction.MATERIAL_APPEARANCE), "Change the selected material's texture scale and height-aware blending.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MoreAction.MASK_STACK), "Build up to four ordered mask conditions for the selected brush material.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MoreAction.PAINT_SYSTEM), "Choose the splat algorithm, debug preview, paint resolution, and stylus-pressure behavior.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MoreAction.REMOVE_MATERIAL), "Remove the selected brush material and clear only its face-local weights; this is undoable.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MoreAction.REMOVE_LEVEL_PASS), "Remove the level-wide pass for the selected PNG without removing local brush strokes; this is undoable.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MoreAction.CLEAR_BRUSH_PAINT), "Clear all local material strokes while preserving procedural level passes; this is undoable.")
	more_popup.id_pressed.connect(_on_more_action_selected)
	title_row.add_child(_more_menu)

	_no_constraint_mode = CheckButton.new()
	_no_constraint_mode.text = "No Constraint"
	_no_constraint_mode.tooltip_text = (
		"Paint the selected PNG over the base coat through a face-local RGBA layer. "
		+ "Pen and Tile both use the regular PNG brush orientation controlled by the arrow keys."
	)
	_no_constraint_mode.toggled.connect(_on_no_constraint_mode_toggled)
	form.add_child(_no_constraint_mode)

	_mask_paint_mode = CheckButton.new()
	_mask_paint_mode.text = "Mask-based terrain painting"
	_mask_paint_mode.tooltip_text = (
		"Enable the selected PNG and mask to paint terrain with the chosen circular pen "
		+ "or tile brush. Turn this off to release viewport input for other paint tools."
	)
	_mask_paint_mode.toggled.connect(_on_mask_paint_mode_toggled)
	form.add_child(_mask_paint_mode)

	_mask_preview = CheckButton.new()
	_mask_preview.text = "Preview mask reach"
	_mask_preview.tooltip_text = MASK_PREVIEW_TOOLTIP
	_mask_preview.toggled.connect(_on_mask_preview_toggled)
	form.add_child(_mask_preview)

	_splatmap_mode = CheckButton.new()
	_splatmap_mode.text = "Splatmap terrain mode"
	_splatmap_mode.tooltip_text = (
		"Give the ordinary square base-coat brush ownership of terrain painting. Each stamp "
		+ "writes all assigned R/G/B/A materials from the loaded terrain-wide control map."
	)
	_splatmap_mode.toggled.connect(_on_splatmap_mode_toggled)
	form.add_child(_splatmap_mode)
	_splatmap_projection = _add_option(
		form,
		"Projection",
		SPLATMAP_PROJECTION_NAMES,
		"Choose the one terrain face direction sampled by the uploaded map. Changing it rebuilds the guide and brush lookup without clearing paint already stamped in any direction."
	)
	_splatmap_projection.item_selected.connect(_on_splatmap_projection_selected)
	_splatmap_overlay = CheckButton.new()
	_splatmap_overlay.text = "Show splatmap overlay"
	_splatmap_overlay.tooltip_text = (
		"Show or hide the loaded RGBA source as a terrain-wide guide. This display-only "
		+ "overlay never creates paint and does not control whether the tile brush works."
	)
	_splatmap_overlay.toggled.connect(_on_splatmap_overlay_toggled)
	form.add_child(_splatmap_overlay)
	_splatmap_live_controls_box = VBoxContainer.new()
	_splatmap_fill_empty_regions = CheckButton.new()
	_splatmap_fill_empty_regions.text = "Fill empty regions with a base channel"
	_splatmap_fill_empty_regions.tooltip_text = (
		"Replace black and near-black source pixels with the selected R, G, B, or A "
		+ "material. Off preserves the source's native RGBA weights."
	)
	_splatmap_fill_empty_regions.toggled.connect(_on_splatmap_live_option_changed)
	_splatmap_live_controls_box.add_child(_splatmap_fill_empty_regions)
	var empty_region_row := HBoxContainer.new()
	var empty_region_label := Label.new()
	empty_region_label.text = "Empty-region base"
	empty_region_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	empty_region_row.add_child(empty_region_label)
	_splatmap_empty_region_channel = OptionButton.new()
	_splatmap_empty_region_channel.tooltip_text = (
		"Choose which assigned splat material completely fills every empty source pixel."
	)
	for channel_index: int in SPLATMAP_CHANNEL_NAMES.size():
		_splatmap_empty_region_channel.add_item(
			SPLATMAP_CHANNEL_NAMES[channel_index],
			channel_index
		)
	_splatmap_empty_region_channel.item_selected.connect(_on_splatmap_live_option_changed)
	empty_region_row.add_child(_splatmap_empty_region_channel)
	_splatmap_live_controls_box.add_child(empty_region_row)
	_splatmap_channel_strengths_enabled = CheckButton.new()
	_splatmap_channel_strengths_enabled.text = "Adjust channel strengths"
	_splatmap_channel_strengths_enabled.tooltip_text = (
		"Multiply the visible R/G/B/A blend dynamically. Off preserves native source weights."
	)
	_splatmap_channel_strengths_enabled.toggled.connect(_on_splatmap_live_option_changed)
	_splatmap_live_controls_box.add_child(_splatmap_channel_strengths_enabled)
	_splatmap_channel_strength_sliders.clear()
	for channel_name: String in ["R strength", "G strength", "B strength", "A strength"]:
		var strength_slider := _add_slider(
			_splatmap_live_controls_box,
			channel_name,
			0.0,
			400.0,
			1.0,
			100.0,
			"%",
			false,
			"Scale this channel at draw time while preserving the painted pixel's total coverage."
		)
		strength_slider.editable = false
		strength_slider.value_changed.connect(_on_splatmap_live_option_changed)
		_splatmap_channel_strength_sliders.append(strength_slider)
	form.add_child(_splatmap_live_controls_box)
	_splatmap_setup_button = Button.new()
	_splatmap_setup_button.text = "LOAD / ASSIGN RGBA SPLATMAP…"
	_splatmap_setup_button.tooltip_text = (
		"Load one terrain-wide control image and assign PNG materials to its R/G/B/A channels. "
		+ "A fully empty outer image frame is fitted to the terrain footprint automatically; "
		+ "the dialog otherwise only loads canonical inputs, and painting remains explicit."
	)
	_splatmap_setup_button.pressed.connect(_open_splatmap_import)
	form.add_child(_splatmap_setup_button)
	_splatmap_workflow_box = VBoxContainer.new()
	var splatmap_channels_label := Label.new()
	splatmap_channels_label.text = "Active RGBA material channel"
	splatmap_channels_label.tooltip_text = (
		"Inspect the four assigned materials. Every tile-brush stamp writes all channels together."
	)
	_splatmap_workflow_box.add_child(splatmap_channels_label)
	_splatmap_channel_gallery = ItemList.new()
	_splatmap_channel_gallery.custom_minimum_size = Vector2(0.0, 116.0)
	_splatmap_channel_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_splatmap_channel_gallery.max_columns = 4
	_splatmap_channel_gallery.icon_mode = ItemList.ICON_MODE_TOP
	_splatmap_channel_gallery.fixed_icon_size = MATERIAL_THUMBNAIL_SIZE
	_splatmap_channel_gallery.fixed_column_width = 104
	_splatmap_channel_gallery.same_column_width = true
	_splatmap_channel_gallery.allow_reselect = true
	_splatmap_channel_gallery.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_splatmap_channel_gallery.tooltip_text = (
		"These are the R/G/B/A materials painted together by the base-coat tile brush. "
		+ "Selecting a thumbnail only chooses which layer's procedural-mask controls are shown."
	)
	_splatmap_channel_gallery.item_selected.connect(_on_splatmap_channel_selected)
	_splatmap_workflow_box.add_child(_splatmap_channel_gallery)
	form.add_child(_splatmap_workflow_box)

	_add_separator(form)
	_material_gallery_label = Label.new()
	_material_gallery_label.text = "1  Paint PNG"
	_material_gallery_label.tooltip_text = "Choose the PNG material visually. Selection alone never changes the map."
	form.add_child(_material_gallery_label)
	_material_gallery = ItemList.new()
	_material_gallery.custom_minimum_size = Vector2(0.0, 116.0)
	_material_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_material_gallery.max_columns = 0
	_material_gallery.icon_mode = ItemList.ICON_MODE_TOP
	_material_gallery.fixed_icon_size = MATERIAL_THUMBNAIL_SIZE
	_material_gallery.fixed_column_width = 104
	_material_gallery.same_column_width = true
	_material_gallery.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_material_gallery.tooltip_text = "Select a PNG thumbnail. It paints only after you enable No Constraint, choose a mask, or arm a decal mode."
	_material_gallery.item_selected.connect(_on_material_selected)
	form.add_child(_material_gallery)

	_decal_mode = CheckButton.new()
	_decal_mode.text = "Stamp as native decal"
	_decal_mode.tooltip_text = (
		"Place the selected PNG as a Godot Decal with its albedo, normal, packed "
		+ "ORM, and emission maps. Native Decal has no height/parallax input."
	)
	_decal_mode.toggled.connect(_on_decal_mode_toggled)
	form.add_child(_decal_mode)

	_shader_decal_mode = CheckButton.new()
	_shader_decal_mode.text = "Stamp into terrain material"
	_shader_decal_mode.tooltip_text = (
		"Stamp the selected PNG and its original PBR maps once at the asset footprint. "
		+ "Opaque pixels replace the underlying coat, transparent pixels leave it visible, "
		+ "and the same terrain shader supplies lighting, parallax, fog, and grid rendering."
	)
	_shader_decal_mode.toggled.connect(_on_shader_decal_mode_toggled)
	form.add_child(_shader_decal_mode)

	_decal_edge_mode = CheckButton.new()
	_decal_edge_mode.text = "Edge placement"
	_decal_edge_mode.tooltip_text = (
		"Snap the decal centre to the nearest grid junction shared by four cells. "
		+ "The junction is saved without changing the decal's authored size."
	)
	_decal_edge_mode.toggled.connect(_on_decal_edge_mode_toggled)
	form.add_child(_decal_edge_mode)

	_match_underlying_palette = CheckButton.new()
	_match_underlying_palette.text = "Match underlying albedo palette"
	_match_underlying_palette.tooltip_text = (
		"Analyze the authored albedo beneath the decal footprint and remap the decal's "
		+ "opaque pixels to comparable colour mean and contrast. Alpha and all non-albedo "
		+ "material maps are preserved. The choice is saved on each placement."
	)
	_match_underlying_palette.toggled.connect(_on_palette_match_toggled)
	form.add_child(_match_underlying_palette)

	_mask_row = _row(
		form,
		"2  Mask",
		"Restrict local brush strokes and the optional procedural pass by material data, level height, slope, contact, or noise."
	)
	_mask = OptionButton.new()
	_mask.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mask.tooltip_text = "Choose where this material is allowed to appear; choosing a mask arms the brush."
	_mask.item_selected.connect(_on_mask_selected)
	_mask_row.add_child(_mask)

	_range_low = _add_slider(form, "Range low", 0.0, 100.0, 1.0, 0.0, "%", false, "Set the lowest mask value accepted by this material.")
	_range_low_row = _range_low.get_parent() as HBoxContainer
	_range_low.value_changed.connect(_on_range_low_changed)
	_range_high = _add_slider(form, "Range high", 0.0, 100.0, 1.0, 100.0, "%", false, "Set the highest mask value accepted by this material.")
	_range_high_row = _range_high.get_parent() as HBoxContainer
	_range_high.value_changed.connect(_on_range_high_changed)
	_fade = _add_slider(form, "Edge fade", 0.0, 100.0, 1.0, 10.0, "%", false, "Soften the mask boundary to fade naturally into the material underneath.")
	_fade_row = _fade.get_parent() as HBoxContainer
	_fade.value_changed.connect(_on_simple_mask_value_changed)
	_influence = _add_slider(form, "Influence", 0.0, 100.0, 1.0, 100.0, "%", false, "Scale the mask's final contribution without changing its selected range.")
	_influence_row = _influence.get_parent() as HBoxContainer
	_influence.value_changed.connect(_on_simple_mask_value_changed)
	_invert = CheckButton.new()
	_invert.text = "Invert mask"
	_invert.tooltip_text = "Swap the mask's accepted and rejected regions after range and fade are evaluated."
	_invert.toggled.connect(_on_simple_mask_value_changed)
	form.add_child(_invert)
	_noise_scale = _add_slider(form, "Noise scale", 0.01, 1000.0, 0.01, 2.0, " m", true, "Set the world-space size of noise features; larger values make broader patches.")
	_noise_scale_row = _noise_scale.get_parent() as HBoxContainer
	_noise_scale.value_changed.connect(_on_simple_mask_value_changed)
	_noise_seed = _add_spin(form, "Noise seed", -100000.0, 100000.0, 1.0, 0.0, "Choose a deterministic alternate noise pattern without changing its scale.")
	_noise_seed_row = _noise_seed.get_parent() as HBoxContainer
	_noise_seed.value_changed.connect(_on_simple_mask_value_changed)
	_noise_angle = _add_spin(form, "Band angle", 0.0, 360.0, 1.0, 0.0, "Set the world-space direction of directional bands explicitly.")
	_noise_angle.suffix = "°"
	_noise_angle_row = _noise_angle.get_parent() as HBoxContainer
	_noise_angle.value_changed.connect(_on_simple_mask_value_changed)

	_brush_box = VBoxContainer.new()
	form.add_child(_brush_box)
	_paint_target = _add_option(
		_brush_box,
		"Paint target",
		PAINT_TARGET_NAMES,
		"Choose a continuous metric pen or the regular textured square Tile targeter. Both work on top and side faces and use the same arrow-key PNG orientation."
	)
	_paint_target.item_selected.connect(_on_paint_target_selected)
	_brush_radius = _add_spin(_brush_box, "Pen radius", 0.01, 100.0, 0.01, 0.5, "Set the circular pen radius in world-space metres on either top or side faces.")
	_brush_radius_row = _brush_radius.get_parent() as HBoxContainer
	_brush_radius.suffix = " m"
	_brush_radius.value_changed.connect(_on_brush_radius_changed)
	_brush_opacity = _add_slider(_brush_box, "Brush strength", 0.0, 100.0, 1.0, 100.0, "%", false, "Set how much selected-channel weight one circular or tile stroke adds or removes; lower values build up gradually.")
	_brush_opacity.value_changed.connect(_on_brush_opacity_changed)
	_hardness = _add_slider(_brush_box, "Brush edge", 0.0, 100.0, 1.0, 75.0, "%", false, "Control circular-pen falloff: 100% is a hard edge and lower values create a softer feather.")
	_hardness_row = _hardness.get_parent() as HBoxContainer
	_hardness.value_changed.connect(_on_brush_hardness_changed)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.tooltip_text = "Shows the next required action and whether a level-wide pass already exists for the selected PNG."
	form.add_child(_status)

	_add_separator(form)
	_procedural_button = Button.new()
	_procedural_button.text = "PROCEDURALLY PAINT LEVEL"
	_procedural_button.tooltip_text = "Apply the currently visible PNG and mask across every matching PNG surface as one explicit undoable action. Local brush strokes are preserved."
	_procedural_button.pressed.connect(_apply_procedural_level)
	form.add_child(_procedural_button)

	_build_material_dialog()
	_build_mask_dialog()
	_build_splatmap_dialog()
	_build_settings_dialog()
	_build_confirmation_dialogs()
	_populate_materials()
	_refresh_main_controls()


## Add one labeled row so every compact control names and explains the exact value it edits.
func _row(parent: Control, label_text: String, tooltip: String = "") -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 104.0
	row.tooltip_text = tooltip
	label.tooltip_text = tooltip
	row.add_child(label)
	parent.add_child(row)
	return row


## Add one horizontal separator without spending vertical space on another heading.
func _add_separator(parent: Control) -> void:
	parent.add_child(HSeparator.new())


## Add one percentage-style slider with a live numeric readout and return its editable range.
func _add_slider(
	parent: Control,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	suffix: String,
	exponential: bool = false,
	tooltip: String = ""
) -> HSlider:
	var row := _row(parent, label_text, tooltip)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.exp_edit = exponential
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.tooltip_text = tooltip
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 58.0
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.tooltip_text = tooltip
	row.add_child(value_label)
	_slider_labels[slider] = {"label": value_label, "suffix": suffix}
	_update_slider_label(slider)
	return slider


## Add one exact numeric field for values that are awkward to manipulate as a slider.
func _add_spin(
	parent: Control,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	tooltip: String = ""
) -> SpinBox:
	var row := _row(parent, label_text, tooltip)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.tooltip_text = tooltip
	row.add_child(spin)
	return spin


## Add one labeled option list and populate IDs in the same order as its visible names.
func _add_option(
	parent: Control,
	label_text: String,
	names: PackedStringArray,
	tooltip: String = ""
) -> OptionButton:
	var row := _row(parent, label_text, tooltip)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.tooltip_text = tooltip
	for index: int in names.size():
		option.add_item(names[index], index)
	row.add_child(option)
	return option


## Refresh one slider's readout so compact sliders never hide their exact authored value.
func _update_slider_label(slider: HSlider) -> void:
	var record: Dictionary = _slider_labels.get(slider, {})
	var label := record.get("label", null) as Label
	if label == null:
		return
	var decimals := 2 if slider.step < 0.1 else 0
	label.text = ("%.*f%s" % [decimals, slider.value, String(record.get("suffix", ""))])


## Build the focused material dialog for the two non-overlapping layer appearance controls.
func _build_material_dialog() -> void:
	_material_dialog = AcceptDialog.new()
	_material_dialog.title = "Material Appearance"
	_material_dialog.dialog_text = ""
	add_child(_material_dialog)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(430.0, 120.0)
	_material_dialog.add_child(content)
	_material_scale = _add_slider(content, "Texture scale", 1.0, 800.0, 1.0, 100.0, "%", true, "Scale this material's texture repetition without changing the geometry or source PNG.")
	_material_scale.value_changed.connect(_on_material_settings_changed)
	_material_height_blend = _add_slider(content, "Height blend", 0.0, 100.0, 1.0, 0.0, "%", false, "Bias transitions using the incoming material's height channel so raised details overlap naturally.")
	_material_height_blend.value_changed.connect(_on_material_settings_changed)


## Build the complete mask-stack editor so every existing mask kernel remains directly controllable.
func _build_mask_dialog() -> void:
	_mask_dialog = AcceptDialog.new()
	_mask_dialog.title = "Mask Stack"
	add_child(_mask_dialog)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(480.0, 470.0)
	_mask_dialog.add_child(content)
	_rule_select = _add_option(content, "Condition", PackedStringArray(["Condition 1"]), "Select which ordered mask condition the fields below edit.")
	_rule_select.item_selected.connect(_on_rule_selected)
	var buttons := HBoxContainer.new()
	_add_rule_button = Button.new()
	_add_rule_button.text = "Add condition"
	_add_rule_button.tooltip_text = "Append another mask condition; up to four conditions are evaluated in order."
	_add_rule_button.pressed.connect(_add_mask_rule)
	buttons.add_child(_add_rule_button)
	_remove_rule_button = Button.new()
	_remove_rule_button.text = "Remove condition"
	_remove_rule_button.tooltip_text = "Remove the selected condition while keeping the remaining condition order intact."
	_remove_rule_button.pressed.connect(_remove_mask_rule)
	buttons.add_child(_remove_rule_button)
	content.add_child(buttons)
	_rule_source = _add_option(content, "Source", MASK_SOURCE_NAMES, "Choose the stored or derived channel sampled by this condition.")
	_rule_source.item_selected.connect(_on_rule_value_changed)
	_rule_combine = _add_option(content, "Combine", COMBINE_NAMES, "Choose how this condition combines with the accumulated mask above it.")
	_rule_combine.item_selected.connect(_on_rule_value_changed)
	_rule_channel = _add_option(content, "Channel", PackedStringArray(["R", "G", "B", "A"]), "Choose the sampled component when the selected source contains multiple channels.")
	_rule_channel.item_selected.connect(_on_rule_value_changed)
	_rule_low = _add_spin(content, "Range low %", 0.0, 100.0, 1.0, 0.0, "Set the lowest source percentage accepted by this condition.")
	_rule_low.value_changed.connect(_on_rule_value_changed)
	_rule_high = _add_spin(content, "Range high %", 0.0, 100.0, 1.0, 100.0, "Set the highest source percentage accepted by this condition.")
	_rule_high.value_changed.connect(_on_rule_value_changed)
	_rule_fade = _add_spin(content, "Edge fade %", 0.0, 100.0, 1.0, 10.0, "Feather both ends of this condition's accepted range.")
	_rule_fade.value_changed.connect(_on_rule_value_changed)
	_rule_strength = _add_spin(content, "Influence %", 0.0, 100.0, 1.0, 100.0, "Scale this condition's contribution before it combines with the accumulated mask.")
	_rule_strength.value_changed.connect(_on_rule_value_changed)
	_rule_invert = CheckButton.new()
	_rule_invert.text = "Invert this condition"
	_rule_invert.tooltip_text = "Swap accepted and rejected portions of this condition before combining it."
	_rule_invert.toggled.connect(_on_rule_value_changed)
	content.add_child(_rule_invert)
	_rule_noise_scale = _add_spin(content, "Noise scale m", 0.01, 10000.0, 0.01, 2.0, "Set the world-space feature size for any of the four noise sources.")
	_rule_noise_scale.value_changed.connect(_on_rule_value_changed)
	_rule_noise_seed = _add_spin(content, "Noise seed", -100000.0, 100000.0, 1.0, 0.0, "Choose a deterministic alternate pattern for any of the four noise sources.")
	_rule_noise_seed.value_changed.connect(_on_rule_value_changed)
	_rule_noise_angle = _add_spin(content, "Band angle", 0.0, 360.0, 1.0, 0.0, "Set the explicit world-space direction used only by Directional Bands.")
	_rule_noise_angle.suffix = "°"
	_rule_noise_angle.value_changed.connect(_on_rule_value_changed)


## Build the focused RGBA import dialog that maps visible assets directly to four paint slots.
##
## Import is an explicit expensive action; choosing a path or slot changes no board state until
## the user presses Load, and the displayed orientation is the one the backend consumes.
func _build_splatmap_dialog() -> void:
	_splatmap_dialog = AcceptDialog.new()
	_splatmap_dialog.title = "Load RGBA Terrain Splatmap"
	_splatmap_dialog.get_ok_button().text = "LOAD SPLATMAP"
	_splatmap_dialog.confirmed.connect(_apply_splatmap_import)
	add_child(_splatmap_dialog)
	var content_scroll := ScrollContainer.new()
	content_scroll.custom_minimum_size = Vector2(520.0, 340.0)
	content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_splatmap_dialog.add_child(content_scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(content)
	var note := Label.new()
	note.text = (
		"R/G/B/A become material slots 1/2/3/4. Projection is selected in the main panel. "
		+ "Top uses +X/+Z; North and South use +X/high-to-low Y; East and West use "
		+ "+Z/high-to-low Y. Leave A unused for an opaque RGB image."
	)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(note)
	var path_row := _row(content, "Control map", "Choose one PNG, JPEG, or WebP RGBA weight field.")
	_splatmap_path = LineEdit.new()
	_splatmap_path.editable = false
	_splatmap_path.placeholder_text = "Choose an RGBA splatmap image…"
	_splatmap_path.tooltip_text = "The external RGBA image sampled over the selected direction's complete terrain-face bounds."
	_splatmap_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(_splatmap_path)
	var browse := Button.new()
	browse.text = "Browse…"
	browse.pressed.connect(_browse_splatmap)
	path_row.add_child(browse)
	_splatmap_slots.clear()
	_splatmap_slot_previews.clear()
	_splatmap_slot_labels.clear()
	var channel_names := PackedStringArray(["R · Layer 1", "G · Layer 2", "B · Layer 3", "A · Layer 4"])
	for layer_index: int in channel_names.size():
		var slot_row := _row(
			content,
			channel_names[layer_index],
			"Choose the PNG material rendered wherever this control-map channel has weight."
		)
		var slot := Button.new()
		slot.custom_minimum_size.y = 54.0
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.tooltip_text = "Open the newest-first thumbnail library for this RGBA channel."
		slot.pressed.connect(_open_splatmap_slot_picker.bind(layer_index))
		slot_row.add_child(slot)
		var slot_content := HBoxContainer.new()
		slot_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot_content.offset_left = 8.0
		slot_content.offset_top = 5.0
		slot_content.offset_right = -8.0
		slot_content.offset_bottom = -5.0
		slot_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(slot_content)
		var preview := TextureRect.new()
		preview.custom_minimum_size = Vector2(44.0, 44.0)
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_content.add_child(preview)
		var selected_label := Label.new()
		selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		selected_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		selected_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		selected_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_content.add_child(selected_label)
		var disclosure := Label.new()
		disclosure.text = "▾"
		disclosure.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		disclosure.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_content.add_child(disclosure)
		_splatmap_slots.append(slot)
		_splatmap_slot_previews.append(preview)
		_splatmap_slot_labels.append(selected_label)
	_splatmap_summary = Label.new()
	_splatmap_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_splatmap_summary)
	_splatmap_picker_popup = PopupPanel.new()
	add_child(_splatmap_picker_popup)
	var picker_content := VBoxContainer.new()
	picker_content.custom_minimum_size = Vector2(650.0, 450.0)
	_splatmap_picker_popup.add_child(picker_content)
	_splatmap_picker_title = Label.new()
	_splatmap_picker_title.text = "Choose material — newest first"
	picker_content.add_child(_splatmap_picker_title)
	_splatmap_picker_gallery = ItemList.new()
	_splatmap_picker_gallery.custom_minimum_size = Vector2(650.0, 420.0)
	_splatmap_picker_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_splatmap_picker_gallery.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_splatmap_picker_gallery.icon_mode = ItemList.ICON_MODE_TOP
	_splatmap_picker_gallery.fixed_icon_size = MATERIAL_THUMBNAIL_SIZE
	_splatmap_picker_gallery.fixed_column_width = 112
	_splatmap_picker_gallery.same_column_width = true
	_splatmap_picker_gallery.max_columns = 5
	_splatmap_picker_gallery.allow_reselect = true
	_splatmap_picker_gallery.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_splatmap_picker_gallery.tooltip_text = "Choose by thumbnail; materials are ordered from newest import to oldest."
	_splatmap_picker_gallery.item_selected.connect(_on_splatmap_picker_selected)
	picker_content.add_child(_splatmap_picker_gallery)
	_splatmap_file_dialog = FileDialog.new()
	_splatmap_file_dialog.title = "Choose RGBA Splatmap"
	_splatmap_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_splatmap_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# The native Windows browser generates bounded shell thumbnails instead of asking
	# Godot to decode every unrelated image in the current filesystem directory.
	_splatmap_file_dialog.use_native_dialog = true
	_splatmap_file_dialog.display_mode = FileDialog.DISPLAY_THUMBNAILS
	_splatmap_file_dialog.add_filter("*.png, *.jpg, *.jpeg, *.webp", "Image files")
	_splatmap_file_dialog.file_selected.connect(_on_splatmap_file_selected)
	_splatmap_file_dialog.canceled.connect(_on_splatmap_file_dialog_canceled)
	add_child(_splatmap_file_dialog)


## Build one compact system dialog for global algorithms that do not belong in either workflow.
func _build_settings_dialog() -> void:
	_settings_dialog = AcceptDialog.new()
	_settings_dialog.title = "Paint System"
	add_child(_settings_dialog)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(450.0, 405.0)
	_settings_dialog.add_child(content)
	_blend_mode = _add_option(
		content,
		"Splat algorithm",
		PackedStringArray(["Independent layers", "True normalized splat"]),
		"Independent layers overlap in order; normalized splat shares one total weight among the base and painted materials."
	)
	_blend_mode.item_selected.connect(_on_system_settings_changed)
	_debug_view = _add_option(content, "Debug preview", DEBUG_NAMES, "Replace the beauty view with one exact mask or source channel for diagnosis; Final Material restores normal rendering.")
	_debug_view.item_selected.connect(_on_system_settings_changed)
	_paint_detail = _add_spin(
		content,
		"Paint texels / metre",
		float(MaterialBlendProfile.MIN_TEXELS_PER_METRE),
		float(MaterialBlendProfile.MAX_TEXELS_PER_METRE),
		4.0,
		64.0,
		"Set canonical brush-mask detail per world metre. Low values save CPU and GPU memory but make mask edges coarser."
	)
	_paint_detail.value_changed.connect(_on_resolution_settings_changed)
	_maximum_edge = _add_spin(
		content,
		"Maximum edge px",
		float(MaterialBlendProfile.MIN_SURFACE_EDGE_PX),
		float(MaterialBlendProfile.MAX_SURFACE_EDGE_PX),
		16.0,
		512.0,
		"Cap either dimension of each placement mask. This is the strongest memory limit for large surfaces."
	)
	_maximum_edge.value_changed.connect(_on_resolution_settings_changed)
	_paint_memory_summary = Label.new()
	_paint_memory_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_paint_memory_summary.tooltip_text = "Shows canonical CPU RGBA8 bytes plus derived GPU Texture2DArray RGBA8 texel bytes; graphics-driver overhead is excluded."
	content.add_child(_paint_memory_summary)
	_apply_resolution_button = Button.new()
	_apply_resolution_button.text = "APPLY PAINT MASK RESOLUTION"
	_apply_resolution_button.tooltip_text = "Atomically resample existing canonical masks and rebuild only their derived texture arrays; the operation has an exact compressed undo snapshot."
	_apply_resolution_button.pressed.connect(_request_resolution_rebuild)
	content.add_child(_apply_resolution_button)
	_pressure_size = CheckButton.new()
	_pressure_size.text = "Stylus pressure controls brush size"
	_pressure_size.tooltip_text = "When enabled, pen pressure multiplies the visible brush radius for each pointer sample."
	_pressure_size.toggled.connect(_on_system_settings_changed)
	content.add_child(_pressure_size)
	_pressure_opacity = CheckButton.new()
	_pressure_opacity.text = "Stylus pressure controls brush strength"
	_pressure_opacity.tooltip_text = "When enabled, pen pressure multiplies how strongly each stroke changes splat weight."
	_pressure_opacity.toggled.connect(_on_system_settings_changed)
	content.add_child(_pressure_opacity)
	_auto_texture_thin_side_slivers = CheckButton.new()
	_auto_texture_thin_side_slivers.text = "Auto-texture <0.1 m side slivers"
	_auto_texture_thin_side_slivers.tooltip_text = (
		"When enabled, an unpainted side strip shorter than 0.1 m at a wall's top or "
		+ "bottom uses the nearest complete 1 m square on that same side grid. "
		+ "Direct paint on the strip always overrides this derived seed."
	)
	_auto_texture_thin_side_slivers.toggled.connect(_on_auto_texture_thin_side_slivers_toggled)
	content.add_child(_auto_texture_thin_side_slivers)


## Build explicit confirmations for operations that remove or resample canonical authored weights.
func _build_confirmation_dialogs() -> void:
	_remove_dialog = ConfirmationDialog.new()
	_remove_dialog.title = "Remove Paint Material"
	_remove_dialog.dialog_text = "Remove this material and clear its face-local weights from every painted PNG surface?"
	_remove_dialog.confirmed.connect(_remove_current_material)
	add_child(_remove_dialog)
	_clear_dialog = ConfirmationDialog.new()
	_clear_dialog.title = "Clear Brush Paint"
	_clear_dialog.dialog_text = "Clear every authored brush stroke while preserving procedural material rules?"
	_clear_dialog.confirmed.connect(_clear_brush_paint)
	add_child(_clear_dialog)
	_resolution_dialog = ConfirmationDialog.new()
	_resolution_dialog.title = "Rebuild Paint Mask Resolution"
	_resolution_dialog.confirmed.connect(_apply_resolution_rebuild)
	add_child(_resolution_dialog)


## Bind the board's one profile, the PNG asset library, and the viewport's one sparse painter.
func bind(
	p_board: BoardDocument,
	p_library: AssetLibrary,
	p_viewport: MTSStudioViewport
) -> void:
	if viewport != null and viewport.material_profile_replayed.is_connected(_on_material_profile_replayed):
		viewport.material_profile_replayed.disconnect(_on_material_profile_replayed)
	# Detach from the outgoing library before rebinding, or a replaced library
	# would leave this panel still rebuilding from the previous one.
	if library != null and library.library_changed.is_connected(_on_library_changed):
		library.library_changed.disconnect(_on_library_changed)
	board = p_board
	library = p_library
	viewport = p_viewport
	if viewport != null and not viewport.material_profile_replayed.is_connected(_on_material_profile_replayed):
		viewport.material_profile_replayed.connect(_on_material_profile_replayed)
	if library != null and not library.library_changed.is_connected(_on_library_changed):
		library.library_changed.connect(_on_library_changed)
	_draft = MaterialBlendProfile.new()
	if board != null and board.material_blend != null:
		_draft.from_json(board.material_blend.to_json())
	_selected_layers[Workflow.PAINT] = _find_first_layer(Workflow.PAINT)
	_selected_layers[Workflow.PROCEDURAL] = _find_first_layer(Workflow.PROCEDURAL)
	_pending_assets[Workflow.PAINT] = ""
	_pending_assets[Workflow.PROCEDURAL] = ""
	if _no_constraint_mode != null:
		_no_constraint_mode.set_pressed_no_signal(false)
	_populate_materials()
	_refresh_main_controls()
	if viewport != null and _brush_radius != null:
		viewport.set_material_brush_radius(_brush_radius.value)
	if viewport != null and _draft != null:
		viewport.set_material_pressure_controls(
			_draft.pressure_controls_size,
			_draft.pressure_controls_opacity
		)


## Rebuild the PNG gallery whenever the asset library's contents change.
##
## The gallery is a VIEW of AssetLibrary, never a snapshot of it. It was
## previously built only by bind(), so a PNG imported while the editor was open
## stayed invisible here until something happened to rebind the panel.
##
## The current choice is stored as an asset id in the draft profile rather than as
## a row index, so _refresh_main_controls() restores the highlight afterwards even
## though repopulating renumbers every row.
func _on_library_changed() -> void:
	_populate_materials()
	_refresh_main_controls()


## Resynchronize the compact controls after global undo or redo restores a stored material profile.
func _on_material_profile_replayed(profile_json: Dictionary) -> void:
	if _draft == null:
		_draft = MaterialBlendProfile.new()
	_draft.from_json(profile_json)
	_selected_layers[Workflow.PAINT] = _find_first_layer(Workflow.PAINT)
	_selected_layers[Workflow.PROCEDURAL] = _find_first_layer(Workflow.PROCEDURAL)
	_pending_assets[Workflow.PAINT] = ""
	_pending_assets[Workflow.PROCEDURAL] = ""
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Return whether either visible material workflow delegates input to the tile targeter.
func uses_tile_brush() -> bool:
	return _splatmap_mode_enabled() or _uses_mask_tile_brush()


## Return whether the visible top-level unconstrained layer mode owns paint input.
func _no_constraint_mode_enabled() -> bool:
	return _no_constraint_mode != null and _no_constraint_mode.button_pressed


## Return the transient local targeting choice shown by the Paint target control.
func _paint_target_mode() -> int:
	if _paint_target == null or _paint_target.selected < 0:
		return PaintTarget.CIRCULAR_PEN
	return _paint_target.get_selected_id()


## Restore brush ownership only when the compact workflow is currently in Brush Paint mode.
func activate() -> void:
	_update_viewport_tool()


## Return the one visible local-paint workflow; procedural work is now an explicit bottom action.
func _workflow() -> int:
	return Workflow.PAINT


## Return the selected palette channel for the visible workflow or negative one when incomplete.
func _current_layer_index() -> int:
	return _selected_layers[_workflow()]


## Return the PNG represented by the visible thumbnail whether it is pending or already authored.
func _current_asset_id() -> String:
	var layer_index := _selected_layers[Workflow.PAINT]
	if _draft != null and layer_index >= 0:
		return String(_draft.layer(layer_index).get("asset_id", ""))
	return _pending_assets[Workflow.PAINT]


## Return whether one stored layer belongs to the local brush or explicit level action.
func _layer_matches_workflow(layer: Dictionary, workflow: int, _layer_index: int) -> bool:
	var expected_mode := (
		MaterialBlendProfile.ApplicationMode.BRUSH
		if workflow == Workflow.PAINT
		else MaterialBlendProfile.ApplicationMode.PROCEDURAL
	)
	return int(layer.get("application_mode", expected_mode)) == expected_mode


## Find the first inspectable layer for one workflow so saved boards reopen on real stored state.
func _find_first_layer(workflow: int) -> int:
	if _draft == null:
		return -1
	var first_disabled := -1
	for index: int in _draft.layer_count():
		var layer := _draft.layer(index)
		if String(layer.get("asset_id", "")).is_empty() or not _layer_matches_workflow(layer, workflow, index):
			continue
		if bool(layer.get("enabled", false)):
			return index
		if first_disabled < 0:
			first_disabled = index
	return first_disabled


## Find the palette channel already assigned to one PNG and one workflow.
func _find_layer_for_asset(asset_id: String, workflow: int) -> int:
	if _draft == null or asset_id.is_empty():
		return -1
	for index: int in _draft.layer_count():
		var layer := _draft.layer(index)
		if String(layer.get("asset_id", "")) == asset_id and _layer_matches_workflow(layer, workflow, index):
			return index
	return -1


## Find one reusable empty palette entry without shifting any saved face indices.
func _find_empty_layer() -> int:
	if _draft == null:
		return -1
	for index: int in _draft.layer_count():
		if String(_draft.layer(index).get("asset_id", "")).is_empty():
			return index
	return -1


## Populate a directly visible PNG thumbnail gallery with no GLB or decal entries.
func _populate_materials() -> void:
	if _material_gallery == null:
		return
	_material_gallery.clear()
	_material_asset_ids.clear()
	if library == null:
		_material_gallery.add_item("No PNG library")
		_material_gallery.set_item_disabled(0, true)
		return
	var choices := _surface_assets_newest_first()
	for asset: TileAsset in choices:
		var display := asset.display_name if not asset.display_name.is_empty() else asset.asset_id
		var index := _material_gallery.add_item(display)
		_material_asset_ids.append(asset.asset_id)
		var thumbnail := _load_asset_thumbnail(asset)
		if thumbnail != null:
			_material_gallery.set_item_icon(index, thumbnail)
		_material_gallery.set_item_tooltip(index, "%s\n%s" % [display, asset.asset_id])
	if _material_asset_ids.is_empty():
		_material_gallery.add_item("No paintable PNGs")
		_material_gallery.set_item_disabled(0, true)
		_material_gallery.set_item_tooltip(
			0,
			"Import a direct non-decal PNG surface to make it available for material painting."
		)


## Load the same saved thumbnail or direct PNG preview used by the asset and Block Out panels.
func _load_asset_thumbnail(asset: TileAsset) -> Texture2D:
	if asset == null:
		return null
	for path: String in [asset.thumbnail_path, asset.source_path]:
		if path.is_empty():
			continue
		if ResourceLoader.exists(path):
			var cached := ResourceLoader.load(path) as Texture2D
			if cached != null:
				return cached
		var global_path := ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(global_path):
			continue
		var image := Image.new()
		if image.load(global_path) == OK:
			return ImageTexture.create_from_image(image)
	return null


## Return every paintable PNG ordered by its canonical import timestamp, newest first.
func _surface_assets_newest_first() -> Array[TileAsset]:
	var choices: Array[TileAsset] = []
	if library == null:
		return choices
	for asset: TileAsset in library.assets:
		if asset != null and asset.is_surface():
			choices.append(asset)
	choices.sort_custom(_sort_assets_by_newest)
	return choices


## Compare canonical ISO import timestamps and use the stable asset id only to break exact ties.
func _sort_assets_by_newest(left: TileAsset, right: TileAsset) -> bool:
	var left_imported_at := String(left.processing.get("imported_at", ""))
	var right_imported_at := String(right.processing.get("imported_at", ""))
	if left_imported_at != right_imported_at:
		return left_imported_at > right_imported_at
	return left.asset_id.naturalnocasecmp_to(right.asset_id) < 0


## Select the PNG thumbnail whose parallel stable-id array matches canonical state.
func _select_material(asset_id: String) -> void:
	_material_gallery.deselect_all()
	var index := _material_asset_ids.find(asset_id)
	if index >= 0:
		_material_gallery.select(index)
		_material_gallery.ensure_current_is_visible()


## Return whether the top-level workflow delegates terrain input to the square base-coat brush.
func _splatmap_mode_enabled() -> bool:
	return _draft != null and _draft.splatmap_mode_enabled


## Return the visible transient switch that explicitly grants mask painting viewport input.
func _mask_paint_mode_enabled() -> bool:
	return _mask_paint_mode != null and _mask_paint_mode.button_pressed


## Return whether a complete local mask layer visibly delegates input to the tile targeter.
func _uses_mask_tile_brush() -> bool:
	if (
		not (_mask_paint_mode_enabled() or _no_constraint_mode_enabled())
		or _splatmap_mode_enabled()
		or _paint_target_mode() != PaintTarget.TILE_BRUSH
		or _stamp_mode_active()
	):
		return false
	return _selected_layers[Workflow.PAINT] >= 0


## Rebuild the four top-level RGBA channel thumbnails from the canonical material profile.
func _populate_splatmap_channel_gallery() -> void:
	if _splatmap_channel_gallery == null:
		return
	_splatmap_channel_gallery.clear()
	var channel_names := PackedStringArray(["R", "G", "B", "A"])
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var palette_index := (
			_draft.splatmap_palette_indices[channel_index]
			if _draft != null
			else -1
		)
		var mapping_valid := (
			_draft != null
			and palette_index >= 0
			and palette_index < _draft.layer_count()
		)
		var layer := _draft.layer(palette_index) if mapping_valid else {}
		var asset_id := String(layer.get("asset_id", ""))
		var display := "Unassigned"
		var thumbnail: Texture2D = null
		var asset := library.get_asset(asset_id) if library != null and not asset_id.is_empty() else null
		if asset != null and asset.is_surface():
			display = asset.display_name if not asset.display_name.is_empty() else asset.asset_id
			thumbnail = _load_asset_thumbnail(asset)
		var item_index := _splatmap_channel_gallery.add_item(
			"%s · %s" % [channel_names[channel_index], display],
			thumbnail
		)
		_splatmap_channel_gallery.set_item_metadata(item_index, palette_index)
		var brush_authored := (
			mapping_valid
			and not asset_id.is_empty()
			and _layer_matches_workflow(layer, Workflow.PAINT, palette_index)
		)
		_splatmap_channel_gallery.set_item_disabled(item_index, not brush_authored)
		_splatmap_channel_gallery.set_item_tooltip(
			item_index,
			(
				"%s channel → %s\n%s\nSelect this material for pen and procedural-mask controls."
				% [channel_names[channel_index], display, asset_id]
				if brush_authored
				else "%s channel is unassigned; use Load / Assign to configure it."
				% channel_names[channel_index]
			)
		)
		if brush_authored and palette_index == _selected_layers[Workflow.PAINT]:
			_splatmap_channel_gallery.select(item_index)


## Select one canonical RGBA layer from its top-level thumbnail without reallocating any slot.
func _on_splatmap_channel_selected(item_index: int) -> void:
	if _updating or _draft == null or item_index < 0:
		return
	var layer_index := int(_splatmap_channel_gallery.get_item_metadata(item_index))
	if layer_index < 0 or layer_index >= _draft.layer_count():
		return
	var layer := _draft.layer(layer_index)
	if not _layer_matches_workflow(layer, Workflow.PAINT, layer_index):
		return
	_selected_layers[Workflow.PAINT] = layer_index
	_pending_assets[Workflow.PAINT] = ""
	_refresh_main_controls()


## Toggle splatmap paint ownership independently from the optional source overlay.
func _on_splatmap_mode_toggled(enabled: bool) -> void:
	if _updating or _draft == null:
		return
	_draft.splatmap_mode_enabled = enabled
	if enabled:
		_no_constraint_mode.set_pressed_no_signal(false)
		_mask_paint_mode.set_pressed_no_signal(false)
		_decal_mode.set_pressed_no_signal(false)
		_shader_decal_mode.set_pressed_no_signal(false)
		_mask_preview.set_pressed_no_signal(false)
		_selected_layers[Workflow.PAINT] = _find_first_layer(Workflow.PAINT)
		_pending_assets[Workflow.PAINT] = ""
	else:
		_draft.splatmap_overlay_enabled = false
		_splatmap_overlay.set_pressed_no_signal(false)
	_commit_profile(
		"Enable splatmap terrain mode" if enabled else "Disable splatmap terrain mode"
	)
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Explicitly arm or disarm mask-based terrain painting without changing its material recipe.
func _on_mask_paint_mode_toggled(enabled: bool) -> void:
	if _updating:
		return
	if enabled:
		_clear_other_paint_modes(_mask_paint_mode)
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Arm or release unconstrained layered PNG painting without changing the base coat.
func _on_no_constraint_mode_toggled(enabled: bool) -> void:
	if _updating or _draft == null:
		return
	if enabled:
		_clear_other_paint_modes(_no_constraint_mode)
		var asset_id := _current_asset_id()
		if not asset_id.is_empty():
			_ensure_no_constraint_layer(asset_id)
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Switch the local mask workflow between the existing circular pen and tile targeter.
func _on_paint_target_selected(_index: int) -> void:
	if _updating:
		return
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Change the one visible source projection and rebuild preview and brush lookup immediately.
func _on_splatmap_projection_selected(_index: int) -> void:
	if _updating or _draft == null or _splatmap_projection == null:
		return
	var projection := _splatmap_projection.get_selected_id()
	var previous_projection := int(_draft.splatmap_projection)
	if (
		viewport != null
		and not _draft.splatmap_source_path.is_empty()
		and not viewport.splatmap_projection_available(projection)
	):
		_splatmap_projection.select(
			_splatmap_projection.get_item_index(previous_projection)
		)
		_status.text = (
			"The terrain has no %s-facing surfaces; the previous projection is unchanged."
			% SPLATMAP_PROJECTION_NAMES[projection]
		)
		return
	_draft.splatmap_projection = projection as MaterialBlendProfile.SplatmapProjection
	if not _commit_profile("Change splatmap projection"):
		_status.text = "The selected splatmap projection could not be rebuilt."
		return
	_refresh_main_controls()


## Toggle only the optional source-map guide while leaving paint ownership and weights unchanged.
func _on_splatmap_overlay_toggled(enabled: bool) -> void:
	if _updating or _draft == null:
		return
	if enabled and _draft.splatmap_source_path.is_empty():
		_splatmap_overlay.set_pressed_no_signal(false)
		_status.text = "Load an RGBA splatmap before showing its source overlay."
		return
	_draft.splatmap_overlay_enabled = enabled
	_commit_profile(
		"Show splatmap source overlay" if enabled else "Hide splatmap source overlay"
	)
	_refresh_main_controls()


## Populate one explicit mask picker for both local strokes and the bottom procedural action.
func _populate_mask_presets(_workflow: int) -> void:
	_mask.clear()
	_mask.add_item("Choose a mask…", MASK_SELECTION_REQUIRED)
	_mask.set_item_disabled(0, true)
	_mask.set_item_tooltip(
		0,
		"Choose one of the enabled masks below before any painting can begin."
	)
	for preset: int in range(MaskPreset.BASE_HEIGHT_LOW, MASK_PRESET_NAMES.size()):
		_mask.add_item(MASK_PRESET_NAMES[preset], preset)
		_mask.set_item_tooltip(_mask.item_count - 1, _mask_preset_tooltip(preset))


## Explain every compact mask option without adding permanent instructional controls.
func _mask_preset_tooltip(preset: int) -> String:
	match preset:
		MaskPreset.NONE:
			return "Allow the material everywhere the brush touches; the procedural button deliberately covers the whole level."
		MaskPreset.BASE_HEIGHT_LOW, MaskPreset.BASE_HEIGHT_HIGH:
			return "Use the selected PNG surface's own height channel, choosing its lower or upper percentage range."
		MaskPreset.WORLD_HEIGHT_LOW, MaskPreset.WORLD_HEIGHT_HIGH:
			return "Use the complete map-wide height field, choosing the bottom or top percentage of the level."
		MaskPreset.BASE_CAVITY_LOW, MaskPreset.BASE_CAVITY_HIGH:
			return "Use the PNG material's cavity channel to target recessed or exposed detail."
		MaskPreset.BASE_CURVATURE_LOW, MaskPreset.BASE_CURVATURE_HIGH:
			return "Use the PNG material's curvature channel to target concave or convex detail."
		MaskPreset.BASE_AO_LOW, MaskPreset.BASE_AO_HIGH:
			return "Use the PNG material's ambient-occlusion channel to target dark or exposed areas."
		MaskPreset.BASE_ROUGHNESS_LOW, MaskPreset.BASE_ROUGHNESS_HIGH:
			return "Use the PNG material's roughness channel to target smooth or rough areas."
		MaskPreset.BASE_METALLIC_LOW, MaskPreset.BASE_METALLIC_HIGH:
			return "Use the PNG material's metallic channel to target nonmetal or metal areas."
		MaskPreset.BASE_LUMINANCE_LOW, MaskPreset.BASE_LUMINANCE_HIGH:
			return "Use albedo brightness to target dark or light parts of the PNG surface."
		MaskPreset.BASE_MATERIAL_ID_LOW, MaskPreset.BASE_MATERIAL_ID_HIGH:
			return "Use the material-ID channel's lower or higher encoded percentage range."
		MaskPreset.ABSOLUTE_ELEVATION_LOW, MaskPreset.ABSOLUTE_ELEVATION_HIGH:
			return "Use absolute world elevation rather than the map-normalized height range."
		MaskPreset.SURFACE_UP_LOW, MaskPreset.SURFACE_UP_HIGH:
			return "Use surface orientation to target vertical faces or upward-facing surfaces."
		MaskPreset.SURFACE_SLOPE_LOW, MaskPreset.SURFACE_SLOPE_HIGH:
			return "Use derived slope to target gentle or steep terrain."
		MaskPreset.SURFACE_BOTTOM, MaskPreset.SURFACE_TOP:
			return "Use normalized height within each PNG surface to target its bottom or top."
		MaskPreset.CONTACT_LOW, MaskPreset.CONTACT_HIGH:
			return "Use the prop-contact field to target areas away from or near GLB footprints."
		MaskPreset.SMOOTH_NOISE_LOW, MaskPreset.SMOOTH_NOISE_HIGH:
			return "Use continuous multi-octave world noise for broad organic patches without square grid cells."
		MaskPreset.RIDGED_NOISE_LOW, MaskPreset.RIDGED_NOISE_HIGH:
			return "Use folded multi-octave noise for branching valleys or narrow ridges."
		MaskPreset.CELLULAR_NOISE_LOW, MaskPreset.CELLULAR_NOISE_HIGH:
			return "Use distance to irregular seeded points for rounded cell centres or broken borders."
		MaskPreset.DIRECTIONAL_BANDS_LOW, MaskPreset.DIRECTIONAL_BANDS_HIGH:
			return "Use noise-warped world-space bands with an explicit direction angle."
		MaskPreset.CUSTOM:
			return "Open the complete ordered stack with every source, combine, channel, range, fade, influence, inversion, and noise control."
	return "Choose where this material may appear."


## Refresh the one visible local setup and the explicit procedural action from canonical state.
func _refresh_main_controls() -> void:
	if _material_gallery == null or _procedural_button == null:
		return
	_updating = true
	var workflow := Workflow.PAINT
	var splatmap_mode := _splatmap_mode_enabled()
	var has_splatmap_source := (
		_draft != null and not _draft.splatmap_source_path.is_empty()
	)
	var has_splatmap_layers := _draft != null and _find_first_layer(Workflow.PAINT) >= 0
	_splatmap_mode.disabled = _draft == null
	_splatmap_mode.set_pressed_no_signal(splatmap_mode)
	_splatmap_projection.get_parent().visible = splatmap_mode
	_splatmap_projection.disabled = _draft == null
	var projection := (
		int(_draft.splatmap_projection)
		if _draft != null
		else MaterialBlendProfile.SplatmapProjection.TOP
	)
	_splatmap_projection.select(_splatmap_projection.get_item_index(projection))
	_splatmap_overlay.visible = splatmap_mode
	_splatmap_overlay.disabled = not has_splatmap_source
	_splatmap_overlay.set_pressed_no_signal(
		_draft.splatmap_overlay_enabled if _draft != null else false
	)
	_splatmap_live_controls_box.visible = splatmap_mode
	_splatmap_fill_empty_regions.disabled = _draft == null
	_splatmap_fill_empty_regions.set_pressed_no_signal(
		_draft.splatmap_fill_empty_regions if _draft != null else false
	)
	_splatmap_empty_region_channel.disabled = _draft == null
	_splatmap_empty_region_channel.select(
		_splatmap_empty_region_channel.get_item_index(
			_draft.splatmap_empty_region_channel if _draft != null else 0
		)
	)
	_splatmap_channel_strengths_enabled.disabled = _draft == null
	_splatmap_channel_strengths_enabled.set_pressed_no_signal(
		_draft.splatmap_channel_strengths_enabled if _draft != null else false
	)
	var visible_strengths := (
		_draft.splatmap_channel_strengths
		if _draft != null
		else Vector4.ONE
	)
	var visible_strength_values := [
		visible_strengths.x,
		visible_strengths.y,
		visible_strengths.z,
		visible_strengths.w,
	]
	for channel_index: int in _splatmap_channel_strength_sliders.size():
		_splatmap_channel_strength_sliders[channel_index].set_value_no_signal(
			float(visible_strength_values[channel_index]) * 100.0
		)
	_update_splatmap_live_controls()
	_splatmap_setup_button.disabled = _draft == null
	_splatmap_workflow_box.visible = splatmap_mode
	_material_gallery_label.visible = not splatmap_mode
	_material_gallery.visible = not splatmap_mode
	_no_constraint_mode.visible = not splatmap_mode
	_mask_paint_mode.visible = not splatmap_mode
	_mask_preview.visible = not splatmap_mode
	_decal_mode.visible = not splatmap_mode
	_shader_decal_mode.visible = not splatmap_mode
	_decal_edge_mode.visible = _stamp_mode_active() and not splatmap_mode
	_decal_edge_mode.disabled = false
	_populate_splatmap_channel_gallery()
	var layer_index := _selected_layers[workflow]
	var pending_asset := _pending_assets[workflow]
	var layer := _draft.layer(layer_index) if _draft != null and layer_index >= 0 else {}
	var asset_id := String(layer.get("asset_id", pending_asset))
	_select_material(asset_id)
	_populate_mask_presets(workflow)
	var preset := MASK_SELECTION_REQUIRED
	if layer_index >= 0:
		preset = _infer_mask_preset(layer, workflow, layer_index)
	var preset_item := _mask.get_item_index(preset)
	if preset_item >= 0:
		_mask.select(preset_item)
	_refresh_simple_mask_values(layer, workflow, preset)
	var has_layer := layer_index >= 0
	var has_material := not asset_id.is_empty()
	# Stamp modes commit placements rather than editing face-local material weights, so the
	# main RGBA workflow hides and disarms them while it owns the base-coat brush.
	var decal_mode := _stamp_mode_active()
	# This explicit ownership switch remains user-controlled even while its material setup is
	# incomplete. The status text exposes missing setup, and choosing another mode turns it off.
	var no_constraint_mode := _no_constraint_mode_enabled()
	if no_constraint_mode and has_layer and preset != MaskPreset.NONE:
		_no_constraint_mode.set_pressed_no_signal(false)
		no_constraint_mode = false
	var has_mask_constraint := has_layer and preset != MaskPreset.NONE
	if not has_mask_constraint:
		_mask_paint_mode.set_pressed_no_signal(false)
	var mask_paint_mode := _mask_paint_mode_enabled()
	_no_constraint_mode.disabled = _draft == null
	_no_constraint_mode.set_pressed_no_signal(no_constraint_mode)
	_mask_paint_mode.disabled = not has_mask_constraint or no_constraint_mode
	_mask_row.visible = not no_constraint_mode and not splatmap_mode
	_mask.disabled = not has_material or decal_mode or no_constraint_mode
	if not has_layer or decal_mode or splatmap_mode or no_constraint_mode:
		_mask_preview.set_pressed_no_signal(false)
	_mask_preview.visible = not splatmap_mode and not no_constraint_mode
	_mask_preview.disabled = not has_layer or decal_mode or splatmap_mode or no_constraint_mode
	# The preview evaluates one stored layer's mask stack, so a PNG holding no splat
	# channel has nothing to show. Name that on the control itself rather than leaving a
	# greyed checkbox whose reason is only reachable through the status line.
	_mask_preview.tooltip_text = _mask_preview_tooltip(has_layer, decal_mode)
	var tile_target_selected := _paint_target_mode() == PaintTarget.TILE_BRUSH
	var local_layer_mode := mask_paint_mode or no_constraint_mode
	_brush_box.visible = has_layer and local_layer_mode and not decal_mode and not splatmap_mode
	_paint_target.disabled = not has_layer or not local_layer_mode or decal_mode or splatmap_mode
	if _brush_radius_row != null:
		_brush_radius_row.visible = not tile_target_selected
	if _hardness_row != null:
		_hardness_row.visible = not tile_target_selected
	# Palette matching is meaningful for either explicit decal presentation.
	if _match_underlying_palette != null:
		_match_underlying_palette.visible = decal_mode and not splatmap_mode
	var procedural_layer := _find_layer_for_asset(asset_id, Workflow.PROCEDURAL)
	if splatmap_mode:
		_procedural_button.disabled = not has_splatmap_source or not has_splatmap_layers
		_procedural_button.text = "PAINT ENTIRE TERRAIN FROM SPLATMAP"
	else:
		_procedural_button.disabled = not has_layer or decal_mode
		_procedural_button.text = (
			"UPDATE PROCEDURAL LEVEL PASS"
			if procedural_layer >= 0
			else "PROCEDURALLY PAINT LEVEL"
		)
	_refresh_more_menu(has_layer and not decal_mode)
	_updating = false
	_update_viewport_tool()
	_update_status()


## Describe either what the mask preview does or the exact reason it is unavailable.
##
## The checkbox reads one stored layer's mask stack, so it stays greyed while the selected
## PNG has no palette entry. Which of the two blocking states applies decides what the
## user has to do next, so the tooltip names the state instead of only the requirement.
func _mask_preview_tooltip(has_layer: bool, decal_mode: bool) -> String:
	if decal_mode:
		return (
			"Unavailable while a decal stamp owns the brush, because a stamp commits a "
			+ "placement instead of painting into a layer mask. Turn the stamp mode off to "
			+ "preview a mask."
		)
	if not has_layer:
		return (
			"Unavailable until the selected PNG is added to the board palette. Choose a "
			+ "mask to create its inspectable material entry."
		)
	return MASK_PREVIEW_TOOLTIP


## Enable only the overflow actions that have a selected material to operate on.
func _refresh_more_menu(has_layer: bool) -> void:
	if _more_menu == null:
		return
	var popup := _more_menu.get_popup()
	for action: int in [
		MoreAction.MATERIAL_APPEARANCE,
		MoreAction.MASK_STACK,
		MoreAction.REMOVE_MATERIAL,
	]:
		var item_index := popup.get_item_index(action)
		if item_index >= 0:
			popup.set_item_disabled(item_index, not has_layer)
	var remove_level_index := popup.get_item_index(MoreAction.REMOVE_LEVEL_PASS)
	if remove_level_index >= 0:
		var asset_id := _current_asset_id()
		popup.set_item_disabled(
			remove_level_index,
			_find_layer_for_asset(asset_id, Workflow.PROCEDURAL) < 0
		)


## Route the one compact overflow menu to focused non-overlapping editors or destructive actions.
func _on_more_action_selected(action: int) -> void:
	match action:
		MoreAction.MATERIAL_APPEARANCE:
			_open_material_settings()
		MoreAction.MASK_STACK:
			_open_mask_stack()
		MoreAction.PAINT_SYSTEM:
			_open_system_settings()
		MoreAction.REMOVE_MATERIAL:
			_request_remove_material()
		MoreAction.REMOVE_LEVEL_PASS:
			_request_remove_level_pass()
		MoreAction.CLEAR_BRUSH_PAINT:
			_request_clear_paint()


## Open the splatmap importer with the current four layer assignments made fully visible.
##
## Empty initial slots are suggested from distinct PNG assets, but suggestions stay inside this
## unapplied dialog and therefore cannot silently change the board.
func _open_splatmap_import() -> void:
	if _splatmap_dialog == null:
		return
	var choices := _surface_assets_newest_first()
	# Preserve a valid pending selection after a rejected assignment so reopening the
	# upload dialog does not force the user through the filesystem browser again.
	if (
		_draft != null
		and _splatmap_path.text.is_empty()
	):
		_splatmap_path.text = _draft.splatmap_source_path
	var desired_ids := PackedStringArray(["", "", "", ""])
	var claimed: Dictionary = {}
	if _draft != null:
		for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			var palette_index := _draft.splatmap_palette_indices[channel_index]
			if palette_index < 0 or palette_index >= _draft.layer_count():
				continue
			var current_id := String(_draft.layer(palette_index).get("asset_id", ""))
			desired_ids[channel_index] = current_id
			if not current_id.is_empty():
				claimed[current_id] = true
	for channel_index: int in mini(3, MaterialBlendProfile.WEIGHTS_PER_TEXEL):
		if not desired_ids[channel_index].is_empty():
			continue
		for asset: TileAsset in choices:
			if not claimed.has(asset.asset_id):
				desired_ids[channel_index] = asset.asset_id
				claimed[asset.asset_id] = true
				break
	_splatmap_slot_asset_state = desired_ids
	_populate_splatmap_picker(choices)
	for layer_index: int in _splatmap_slots.size():
		_refresh_splatmap_slot_button(layer_index)
	_update_splatmap_summary()
	_splatmap_dialog.popup_centered_clamped(Vector2i(560, 500), 0.85)


## Open the native file picker without mutating the pending import.
func _browse_splatmap() -> void:
	if _splatmap_file_dialog == null or _splatmap_dialog == null:
		return
	_splatmap_dialog.hide()
	call_deferred("_show_splatmap_file_dialog")


## Show the file picker only after the exclusive setup dialog has fully closed.
func _show_splatmap_file_dialog() -> void:
	_splatmap_file_dialog.popup_centered_ratio(0.75)


## Store the exact chosen source path and return to the visible loading dialog.
func _on_splatmap_file_selected(path: String) -> void:
	_splatmap_path.text = path
	_update_splatmap_summary()
	call_deferred("_reopen_splatmap_dialog")


## Return to the loading dialog when the native file picker is cancelled.
func _on_splatmap_file_dialog_canceled() -> void:
	call_deferred("_reopen_splatmap_dialog")


## Reopen the clamped setup dialog so its Load button remains on screen.
func _reopen_splatmap_dialog() -> void:
	if _splatmap_dialog != null:
		_splatmap_dialog.popup_centered_clamped(Vector2i(560, 500), 0.85)


## Populate the shared RGBA thumbnail grid from the same newest-first asset sequence as painting.
func _populate_splatmap_picker(choices: Array[TileAsset]) -> void:
	_splatmap_picker_gallery.clear()
	_splatmap_picker_asset_ids.clear()
	var unused_index := _splatmap_picker_gallery.add_item("Unused")
	_splatmap_picker_gallery.set_item_tooltip(
		unused_index,
		"Do not import this RGBA channel or allocate a material layer for it."
	)
	_splatmap_picker_asset_ids.append("")
	for asset: TileAsset in choices:
		var display := asset.display_name if not asset.display_name.is_empty() else asset.asset_id
		var thumbnail := _load_asset_thumbnail(asset)
		var item_index := _splatmap_picker_gallery.add_item(display, thumbnail)
		_splatmap_picker_gallery.set_item_metadata(item_index, asset.asset_id)
		_splatmap_picker_gallery.set_item_tooltip(
			item_index,
			"%s\n%s\nImported %s"
			% [display, asset.asset_id, String(asset.processing.get("imported_at", ""))]
		)
		_splatmap_picker_asset_ids.append(asset.asset_id)


## Open the thumbnail selector for one explicit RGBA channel without changing its assignment.
func _open_splatmap_slot_picker(layer_index: int) -> void:
	if (
		_splatmap_picker_popup == null
		or layer_index < 0
		or layer_index >= _splatmap_slots.size()
	):
		return
	_active_splatmap_slot = layer_index
	var channel_names := PackedStringArray(["R · Layer 1", "G · Layer 2", "B · Layer 3", "A · Layer 4"])
	_splatmap_picker_title.text = "Choose %s material — newest first" % channel_names[layer_index]
	_splatmap_picker_gallery.deselect_all()
	var selected_item := _splatmap_picker_asset_ids.find(_splatmap_slot_asset_state[layer_index])
	if selected_item < 0:
		selected_item = 0
	_splatmap_picker_gallery.select(selected_item)
	_splatmap_picker_gallery.ensure_current_is_visible()
	_splatmap_picker_popup.popup_centered_clamped(Vector2i(680, 500), 0.85)


## Store one thumbnail choice into its visible RGBA slot and close the shared picker.
func _on_splatmap_picker_selected(item_index: int) -> void:
	if (
		_active_splatmap_slot < 0
		or _active_splatmap_slot >= _splatmap_slot_asset_state.size()
		or item_index < 0
		or item_index >= _splatmap_picker_asset_ids.size()
	):
		return
	_splatmap_slot_asset_state[_active_splatmap_slot] = _splatmap_picker_asset_ids[item_index]
	_refresh_splatmap_slot_button(_active_splatmap_slot)
	_update_splatmap_summary()
	_splatmap_picker_popup.hide()


## Refresh one compact channel button from the exact stable asset id it currently represents.
func _refresh_splatmap_slot_button(layer_index: int) -> void:
	if layer_index < 0 or layer_index >= _splatmap_slots.size():
		return
	var asset_id := _splatmap_slot_asset_state[layer_index]
	var display := "Unused — choose a material…"
	var thumbnail: Texture2D = null
	if not asset_id.is_empty():
		var asset := library.get_asset(asset_id) if library != null else null
		if asset == null or not asset.is_surface():
			push_error("MaterialPaintPanel: RGBA slot references unavailable surface asset '%s'." % asset_id)
			display = "%s — unavailable" % asset_id
		else:
			display = asset.display_name if not asset.display_name.is_empty() else asset.asset_id
			thumbnail = _load_asset_thumbnail(asset)
	_splatmap_slot_previews[layer_index].texture = thumbnail
	_splatmap_slot_labels[layer_index].text = display
	_splatmap_slots[layer_index].tooltip_text = (
		"Selected: %s. Open the newest-first thumbnail library for this RGBA channel."
		% display
	)


## Return the four stable asset ids represented by the visible RGBA thumbnail buttons.
func _splatmap_slot_asset_ids() -> PackedStringArray:
	var asset_ids := PackedStringArray()
	for asset_id: String in _splatmap_slot_asset_state:
		asset_ids.append(asset_id)
	return asset_ids


## Return the four main-panel channel-strength sliders as normalized multipliers.
func _visible_splatmap_strengths() -> Vector4:
	if _splatmap_channel_strength_sliders.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		return Vector4.ONE
	return Vector4(
		_splatmap_channel_strength_sliders[0].value / 100.0,
		_splatmap_channel_strength_sliders[1].value / 100.0,
		_splatmap_channel_strength_sliders[2].value / 100.0,
		_splatmap_channel_strength_sliders[3].value / 100.0
	)


## Enable the four main-panel strength sliders only when adjustment is visibly armed.
func _update_splatmap_live_controls() -> void:
	if _splatmap_empty_region_channel != null:
		_splatmap_empty_region_channel.disabled = _draft == null
		for channel_index: int in SPLATMAP_CHANNEL_NAMES.size():
			var asset_id := ""
			var assigned := false
			if _draft != null:
				var layer := _draft.layer(channel_index)
				asset_id = String(layer.get("asset_id", ""))
				assigned = bool(layer.get("enabled", false)) and not asset_id.is_empty()
			_splatmap_empty_region_channel.set_item_text(
				channel_index,
				"%s — %s" % [
					SPLATMAP_CHANNEL_NAMES[channel_index],
					asset_id if assigned else "Unassigned",
				]
			)
			_splatmap_empty_region_channel.set_item_disabled(channel_index, not assigned)
	var strengths_enabled := (
		_splatmap_channel_strengths_enabled != null
		and _splatmap_channel_strengths_enabled.button_pressed
	)
	for slider: HSlider in _splatmap_channel_strength_sliders:
		slider.editable = strengths_enabled
		_update_slider_label(slider)


## Return whether one visible RGBA input maps to an enabled palette material.
func _splatmap_channel_assigned(channel: int) -> bool:
	if _draft == null or channel < 0 or channel >= MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		return false
	var palette_index := _draft.splatmap_palette_indices[channel]
	if palette_index < 0 or palette_index >= _draft.layer_count():
		return false
	var layer := _draft.layer(palette_index)
	return (
		bool(layer.get("enabled", false))
		and not String(layer.get("asset_id", "")).is_empty()
	)


## Commit one main-panel source option through the shared scoped refresh planner.
func _on_splatmap_live_option_changed(_value: Variant) -> void:
	if _updating or _draft == null or board == null or viewport == null:
		return
	var selected_base_channel := _splatmap_empty_region_channel.get_selected_id()
	if (
		_splatmap_fill_empty_regions.button_pressed
		and not _splatmap_channel_assigned(selected_base_channel)
	):
		_refresh_main_controls()
		_status.text = "Assign a material to the selected empty-region base channel first."
		return
	var previous_fill := _draft.splatmap_fill_empty_regions
	var previous_base_channel := _draft.splatmap_empty_region_channel
	_draft.splatmap_fill_empty_regions = _splatmap_fill_empty_regions.button_pressed
	_draft.splatmap_empty_region_channel = selected_base_channel
	_draft.splatmap_channel_strengths_enabled = (
		_splatmap_channel_strengths_enabled.button_pressed
	)
	_draft.splatmap_channel_strengths = _visible_splatmap_strengths()
	var rebuild_source := (
		previous_fill != _draft.splatmap_fill_empty_regions
		or previous_base_channel != _draft.splatmap_empty_region_channel
	)
	if not _commit_profile(
		(
			"Change splatmap empty-region base fill"
			if rebuild_source
			else "Adjust splatmap channel strengths"
		),
		UndoRedo.MERGE_ENDS
	):
		_refresh_main_controls()
		_status.text = "Splatmap settings could not be applied; the previous state was restored."
		return
	_update_splatmap_live_controls()
	_update_status()


## Show the exact channel mapping and whether the explicit import action is ready.
func _update_splatmap_summary() -> void:
	if _splatmap_summary == null or _splatmap_dialog == null:
		return
	var asset_ids := _splatmap_slot_asset_ids()
	var mappings := PackedStringArray()
	var channel_names := PackedStringArray(["R", "G", "B", "A"])
	var active_count := 0
	for layer_index: int in asset_ids.size():
		var asset_id := asset_ids[layer_index]
		var display := "Unused"
		if not asset_id.is_empty():
			active_count += 1
			var asset := library.get_asset(asset_id) if library != null else null
			display = (
				asset.display_name
				if asset != null and not asset.display_name.is_empty()
				else asset_id
			)
		mappings.append("%s → %s" % [channel_names[layer_index], display])
	var has_path := _splatmap_path != null and not _splatmap_path.text.is_empty()
	_splatmap_summary.text = (
		" · ".join(mappings)
		+ "\nLoad this source and its four material assignments. Main-panel projection, "
		+ "empty-region extension, and channel strengths remain unchanged. Reassigning a "
		+ "channel affects future stamps; existing faces keep their recorded local slots."
	)
	_splatmap_dialog.get_ok_button().disabled = not has_path or active_count == 0


## Load the visible source and slot mapping without changing canonical terrain paint.
func _apply_splatmap_import() -> void:
	if viewport == null or _splatmap_path == null:
		return
	var source := Image.new()
	var load_error := source.load(_splatmap_path.text)
	if load_error != OK:
		_status.text = "Splatmap could not be loaded: %s." % error_string(load_error)
		return
	var result := viewport.import_terrain_splatmap(
		source,
		_splatmap_slot_asset_ids(),
		_splatmap_path.text
	)
	if int(result.get("error", FAILED)) != OK:
		_status.text = String(result.get(
			"message",
			"Splatmap load failed; the previous materials and paint are unchanged."
		))
		return
	if _draft == null:
		_draft = MaterialBlendProfile.new()
	_draft.from_json(board.material_blend.to_json())
	_selected_layers[Workflow.PAINT] = _find_first_layer(Workflow.PAINT)
	_selected_layers[Workflow.PROCEDURAL] = _find_first_layer(Workflow.PROCEDURAL)
	_pending_assets[Workflow.PAINT] = ""
	_pending_assets[Workflow.PROCEDURAL] = ""
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())
	var bounds: Rect2i = result.get("terrain_bounds", Rect2i())
	_status.text = (
		"Loaded the RGBA source over %d %s-projection faces at bounds %s. Terrain paint "
		+ "is unchanged, the square face brush is active, and the overlay is off."
	) % [
		int(result.get("face_count", 0)),
		SPLATMAP_PROJECTION_NAMES[int(_draft.splatmap_projection)],
		str(bounds),
	]


## Show and restore the direct result controls consumed by one simple mask preset.
func _refresh_simple_mask_values(layer: Dictionary, workflow: int, preset: int) -> void:
	var simple := (
		preset >= MaskPreset.BASE_HEIGHT_LOW
		and preset <= MaskPreset.DIRECTIONAL_BANDS_HIGH
	)
	_range_low_row.visible = simple
	_range_high_row.visible = simple
	_fade_row.visible = simple
	_influence_row.visible = simple
	_invert.visible = simple
	var uses_noise := _preset_uses_noise(preset)
	_noise_scale_row.visible = uses_noise
	_noise_seed_row.visible = uses_noise
	_noise_angle_row.visible = _preset_uses_directional_bands(preset)
	if not simple or layer.is_empty():
		return
	var masks_value: Variant = layer.get("masks", [])
	if not (masks_value is Array):
		return
	var masks: Array = masks_value
	var rule_index := 1 if workflow == Workflow.PAINT else 0
	if rule_index >= masks.size() or not (masks[rule_index] is Dictionary):
		return
	var rule: Dictionary = masks[rule_index]
	_range_low.set_value_no_signal(float(rule.get("range_low_percent", 0.0)))
	_range_high.set_value_no_signal(float(rule.get("range_high_percent", 100.0)))
	_fade.set_value_no_signal(float(rule.get("softness_percent", 10.0)))
	_influence.set_value_no_signal(float(rule.get("strength_percent", 100.0)))
	_invert.set_pressed_no_signal(bool(rule.get("invert", false)))
	_noise_scale.set_value_no_signal(float(rule.get("noise_scale_m", 2.0)))
	_noise_seed.set_value_no_signal(float(rule.get("noise_seed", 0)))
	_noise_angle.set_value_no_signal(float(rule.get("noise_angle_degrees", 0.0)))
	for slider: HSlider in [
		_range_low,
		_range_high,
		_fade,
		_influence,
		_noise_scale,
	]:
		_update_slider_label(slider)


## Infer whether a stored mask stack maps exactly to a compact preset or needs the full editor.
func _infer_mask_preset(layer: Dictionary, workflow: int, layer_index: int) -> int:
	var masks_value: Variant = layer.get("masks", [])
	if not (masks_value is Array):
		return MaskPreset.CUSTOM
	var masks: Array = masks_value
	var rule_index := 0
	if workflow == Workflow.PAINT:
		if masks.is_empty() or not _is_default_paint_rule(masks[0], layer_index):
			return MaskPreset.CUSTOM
		if masks.size() == 1:
			return MaskPreset.NONE
		if masks.size() != 2:
			return MaskPreset.CUSTOM
		rule_index = 1
	elif masks.size() != 1:
		return MaskPreset.CUSTOM
	var rule_value: Variant = masks[rule_index]
	if not (rule_value is Dictionary):
		return MaskPreset.CUSTOM
	var rule: Dictionary = rule_value
	if (
		int(rule.get("combine", -1)) != MaterialBlendProfile.CombineOperation.MULTIPLY
		or int(rule.get("channel", 0)) != 0
	):
		return MaskPreset.CUSTOM
	var low := float(rule.get("range_low_percent", 0.0))
	var high := float(rule.get("range_high_percent", 100.0))
	var uses_high_end := low + high > 100.0
	return _preset_for_source(int(rule.get("source", -1)), uses_high_end)


## Return whether one paint rule is the automatic bridge between the brush and its palette channel.
func _is_default_paint_rule(value: Variant, layer_index: int) -> bool:
	if not (value is Dictionary):
		return false
	var rule: Dictionary = value
	return (
		int(rule.get("source", -1)) == MaterialBlendProfile.MaskSource.PAINT
		and int(rule.get("paint_channel", -1)) == layer_index
		and int(rule.get("combine", -1)) == MaterialBlendProfile.CombineOperation.MULTIPLY
		and is_equal_approx(float(rule.get("range_low_percent", -1.0)), 0.0)
		and is_equal_approx(float(rule.get("range_high_percent", -1.0)), 100.0)
		and is_equal_approx(float(rule.get("softness_percent", -1.0)), 10.0)
		and is_equal_approx(float(rule.get("strength_percent", -1.0)), 100.0)
		and not bool(rule.get("invert", false))
	)


## Return whether a compact preset is one of the four continuous world-space noises.
func _preset_uses_noise(preset: int) -> bool:
	return (
		preset >= MaskPreset.SMOOTH_NOISE_LOW
		and preset <= MaskPreset.DIRECTIONAL_BANDS_HIGH
	)


## Return whether a compact preset needs the explicit directional-band angle.
func _preset_uses_directional_bands(preset: int) -> bool:
	return preset in [
		MaskPreset.DIRECTIONAL_BANDS_LOW,
		MaskPreset.DIRECTIONAL_BANDS_HIGH,
	]


## Return whether one stored mask source consumes noise scale and seed controls.
func _mask_source_uses_noise(source: int) -> bool:
	return (
		source >= MaterialBlendProfile.MaskSource.SMOOTH_NOISE
		and source <= MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
	)


## Map one compact preset to the exact mask kernel already consumed by the shader.
func _preset_source(preset: int) -> int:
	match preset:
		MaskPreset.BASE_HEIGHT_LOW, MaskPreset.BASE_HEIGHT_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_HEIGHT
		MaskPreset.WORLD_HEIGHT_LOW, MaskPreset.WORLD_HEIGHT_HIGH:
			return MaterialBlendProfile.MaskSource.WORLD_HEIGHT
		MaskPreset.BASE_CAVITY_LOW, MaskPreset.BASE_CAVITY_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_CAVITY
		MaskPreset.BASE_CURVATURE_LOW, MaskPreset.BASE_CURVATURE_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_CURVATURE
		MaskPreset.BASE_AO_LOW, MaskPreset.BASE_AO_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_AO
		MaskPreset.BASE_ROUGHNESS_LOW, MaskPreset.BASE_ROUGHNESS_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_ROUGHNESS
		MaskPreset.BASE_METALLIC_LOW, MaskPreset.BASE_METALLIC_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_METALLIC
		MaskPreset.BASE_LUMINANCE_LOW, MaskPreset.BASE_LUMINANCE_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_ALBEDO_LUMINANCE
		MaskPreset.BASE_MATERIAL_ID_LOW, MaskPreset.BASE_MATERIAL_ID_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_MATERIAL_ID
		MaskPreset.ABSOLUTE_ELEVATION_LOW, MaskPreset.ABSOLUTE_ELEVATION_HIGH:
			return MaterialBlendProfile.MaskSource.ABSOLUTE_ELEVATION
		MaskPreset.SURFACE_UP_LOW, MaskPreset.SURFACE_UP_HIGH:
			return MaterialBlendProfile.MaskSource.SURFACE_UP
		MaskPreset.SURFACE_SLOPE_LOW, MaskPreset.SURFACE_SLOPE_HIGH:
			return MaterialBlendProfile.MaskSource.SURFACE_SLOPE
		MaskPreset.SURFACE_BOTTOM:
			return MaterialBlendProfile.MaskSource.SURFACE_BOTTOM
		MaskPreset.SURFACE_TOP:
			return MaterialBlendProfile.MaskSource.SURFACE_TOP
		MaskPreset.CONTACT_LOW, MaskPreset.CONTACT_HIGH:
			return MaterialBlendProfile.MaskSource.CONTACT
		MaskPreset.SMOOTH_NOISE_LOW, MaskPreset.SMOOTH_NOISE_HIGH:
			return MaterialBlendProfile.MaskSource.SMOOTH_NOISE
		MaskPreset.RIDGED_NOISE_LOW, MaskPreset.RIDGED_NOISE_HIGH:
			return MaterialBlendProfile.MaskSource.RIDGED_NOISE
		MaskPreset.CELLULAR_NOISE_LOW, MaskPreset.CELLULAR_NOISE_HIGH:
			return MaterialBlendProfile.MaskSource.CELLULAR_NOISE
		MaskPreset.DIRECTIONAL_BANDS_LOW, MaskPreset.DIRECTIONAL_BANDS_HIGH:
			return MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
	return MaterialBlendProfile.MaskSource.PAINT


## Return whether a compact preset keeps the highest rather than lowest percentage range.
func _preset_uses_high_end(preset: int) -> bool:
	return preset in [
		MaskPreset.BASE_HEIGHT_HIGH,
		MaskPreset.WORLD_HEIGHT_HIGH,
		MaskPreset.BASE_CAVITY_HIGH,
		MaskPreset.BASE_CURVATURE_HIGH,
		MaskPreset.BASE_AO_HIGH,
		MaskPreset.BASE_ROUGHNESS_HIGH,
		MaskPreset.BASE_METALLIC_HIGH,
		MaskPreset.BASE_LUMINANCE_HIGH,
		MaskPreset.BASE_MATERIAL_ID_HIGH,
		MaskPreset.ABSOLUTE_ELEVATION_HIGH,
		MaskPreset.SURFACE_UP_HIGH,
		MaskPreset.SURFACE_SLOPE_HIGH,
		MaskPreset.SURFACE_BOTTOM,
		MaskPreset.SURFACE_TOP,
		MaskPreset.CONTACT_HIGH,
		MaskPreset.SMOOTH_NOISE_HIGH,
		MaskPreset.RIDGED_NOISE_HIGH,
		MaskPreset.CELLULAR_NOISE_HIGH,
		MaskPreset.DIRECTIONAL_BANDS_HIGH,
	]


## Map one stored source and range direction back to its compact visible preset.
func _preset_for_source(source: int, high_end: bool) -> int:
	match source:
		MaterialBlendProfile.MaskSource.BASE_HEIGHT:
			return MaskPreset.BASE_HEIGHT_HIGH if high_end else MaskPreset.BASE_HEIGHT_LOW
		MaterialBlendProfile.MaskSource.WORLD_HEIGHT:
			return MaskPreset.WORLD_HEIGHT_HIGH if high_end else MaskPreset.WORLD_HEIGHT_LOW
		MaterialBlendProfile.MaskSource.BASE_CAVITY:
			return MaskPreset.BASE_CAVITY_HIGH if high_end else MaskPreset.BASE_CAVITY_LOW
		MaterialBlendProfile.MaskSource.BASE_CURVATURE:
			return MaskPreset.BASE_CURVATURE_HIGH if high_end else MaskPreset.BASE_CURVATURE_LOW
		MaterialBlendProfile.MaskSource.BASE_AO:
			return MaskPreset.BASE_AO_HIGH if high_end else MaskPreset.BASE_AO_LOW
		MaterialBlendProfile.MaskSource.BASE_ROUGHNESS:
			return MaskPreset.BASE_ROUGHNESS_HIGH if high_end else MaskPreset.BASE_ROUGHNESS_LOW
		MaterialBlendProfile.MaskSource.BASE_METALLIC:
			return MaskPreset.BASE_METALLIC_HIGH if high_end else MaskPreset.BASE_METALLIC_LOW
		MaterialBlendProfile.MaskSource.BASE_ALBEDO_LUMINANCE:
			return MaskPreset.BASE_LUMINANCE_HIGH if high_end else MaskPreset.BASE_LUMINANCE_LOW
		MaterialBlendProfile.MaskSource.BASE_MATERIAL_ID:
			return MaskPreset.BASE_MATERIAL_ID_HIGH if high_end else MaskPreset.BASE_MATERIAL_ID_LOW
		MaterialBlendProfile.MaskSource.ABSOLUTE_ELEVATION:
			return MaskPreset.ABSOLUTE_ELEVATION_HIGH if high_end else MaskPreset.ABSOLUTE_ELEVATION_LOW
		MaterialBlendProfile.MaskSource.SURFACE_UP:
			return MaskPreset.SURFACE_UP_HIGH if high_end else MaskPreset.SURFACE_UP_LOW
		MaterialBlendProfile.MaskSource.SURFACE_SLOPE:
			return MaskPreset.SURFACE_SLOPE_HIGH if high_end else MaskPreset.SURFACE_SLOPE_LOW
		MaterialBlendProfile.MaskSource.SURFACE_BOTTOM:
			return MaskPreset.SURFACE_BOTTOM if high_end else MaskPreset.CUSTOM
		MaterialBlendProfile.MaskSource.SURFACE_TOP:
			return MaskPreset.SURFACE_TOP if high_end else MaskPreset.CUSTOM
		MaterialBlendProfile.MaskSource.CONTACT:
			return MaskPreset.CONTACT_HIGH if high_end else MaskPreset.CONTACT_LOW
		MaterialBlendProfile.MaskSource.SMOOTH_NOISE:
			return MaskPreset.SMOOTH_NOISE_HIGH if high_end else MaskPreset.SMOOTH_NOISE_LOW
		MaterialBlendProfile.MaskSource.RIDGED_NOISE:
			return MaskPreset.RIDGED_NOISE_HIGH if high_end else MaskPreset.RIDGED_NOISE_LOW
		MaterialBlendProfile.MaskSource.CELLULAR_NOISE:
			return MaskPreset.CELLULAR_NOISE_HIGH if high_end else MaskPreset.CELLULAR_NOISE_LOW
		MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS:
			return MaskPreset.DIRECTIONAL_BANDS_HIGH if high_end else MaskPreset.DIRECTIONAL_BANDS_LOW
	return MaskPreset.CUSTOM


## Allocate one stable palette entry and initialize it for exactly one visible workflow.
func _allocate_layer(asset_id: String, workflow: int, preset: int = MaskPreset.NONE) -> int:
	var index := _find_empty_layer()
	if index < 0:
		index = _draft.add_layer(MaterialBlendProfile.default_layer(_draft.layer_count()))
	var had_active_layers := _draft.has_active_layers()
	var layer := MaterialBlendProfile.default_layer(index)
	layer["asset_id"] = asset_id
	layer["application_mode"] = (
		MaterialBlendProfile.ApplicationMode.BRUSH
		if workflow == Workflow.PAINT
		else MaterialBlendProfile.ApplicationMode.PROCEDURAL
	)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	if workflow == Workflow.PAINT:
		layer["masks"] = _simple_mask_rules(preset, workflow, index)
	else:
		layer["masks"] = _simple_mask_rules(preset, workflow, index)
	_draft.set_layer(index, layer)
	if not had_active_layers:
		_draft.blend_mode = MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
	_selected_layers[workflow] = index
	_pending_assets[workflow] = ""
	_commit_profile(
		"Add brush material" if workflow == Workflow.PAINT else "Add procedural material"
	)
	return index


## Build the exact stored mask stack represented by the visible preset controls.
func _simple_mask_rules(preset: int, workflow: int, layer_index: int) -> Array:
	var rules: Array = []
	if workflow == Workflow.PAINT:
		rules.append(MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.PAINT, layer_index))
	if preset == MaskPreset.NONE:
		return rules
	var rule := MaterialBlendProfile.default_rule(_preset_source(preset), layer_index)
	rule["range_low_percent"] = _range_low.value
	rule["range_high_percent"] = _range_high.value
	rule["softness_percent"] = _fade.value
	rule["strength_percent"] = _influence.value
	rule["invert"] = _invert.button_pressed
	rule["channel"] = 0
	if _preset_uses_noise(preset):
		rule["noise_scale_m"] = _noise_scale.value
		rule["noise_seed"] = roundi(_noise_seed.value)
	if _preset_uses_directional_bands(preset):
		rule["noise_angle_degrees"] = _noise_angle.value
	rules.append(rule)
	return rules


## Copy the visible brush constraints while removing only its structural own-channel paint rule.
func _procedural_rules_from_brush_layer(
	brush_layer: Dictionary,
	brush_layer_index: int
) -> Array:
	var result: Array = []
	var masks_value: Variant = brush_layer.get("masks", [])
	if not (masks_value is Array):
		return result
	var removed_structural_rule := false
	for value: Variant in masks_value as Array:
		if not (value is Dictionary):
			continue
		var rule := value as Dictionary
		if (
			not removed_structural_rule
			and _is_default_paint_rule(rule, brush_layer_index)
		):
			removed_structural_rule = true
			continue
		result.append(rule.duplicate(true))
	return result


## Run the visible whole-level action for either the loaded splatmap or one procedural material layer.
func _apply_procedural_level() -> void:
	if _draft == null or viewport == null:
		return
	if _splatmap_mode_enabled():
		if _draft.splatmap_source_path.is_empty():
			_status.text = "Load an RGBA splatmap before painting the entire terrain."
			return
		if viewport.paint_entire_terrain_from_splatmap():
			_status.text = (
				"Painted every %s-projection terrain face from the loaded RGBA splatmap."
				% SPLATMAP_PROJECTION_NAMES[int(_draft.splatmap_projection)]
			)
		else:
			_status.text = "Whole-terrain splatmap paint failed; existing terrain paint was preserved."
		return
	var brush_layer_index := _selected_layers[Workflow.PAINT]
	if brush_layer_index < 0:
		_update_status()
		return
	var brush_layer := _draft.layer(brush_layer_index)
	var asset_id := String(brush_layer.get("asset_id", ""))
	if asset_id.is_empty():
		return
	var draft_before_json := _draft.to_json().duplicate(true)
	var selected_before := int(_selected_layers[Workflow.PROCEDURAL])
	var procedural_layer_index := _find_layer_for_asset(
		asset_id,
		Workflow.PROCEDURAL
	)
	var updating_existing := procedural_layer_index >= 0
	if procedural_layer_index < 0:
		procedural_layer_index = _find_empty_layer()
	if procedural_layer_index < 0:
		procedural_layer_index = _draft.add_layer(
			MaterialBlendProfile.default_layer(_draft.layer_count())
		)
	var procedural_layer := MaterialBlendProfile.default_layer(procedural_layer_index)
	procedural_layer["asset_id"] = asset_id
	procedural_layer["application_mode"] = MaterialBlendProfile.ApplicationMode.PROCEDURAL
	procedural_layer["enabled"] = true
	procedural_layer["opacity_percent"] = 100.0
	procedural_layer["texture_scale_percent"] = float(
		brush_layer.get("texture_scale_percent", 100.0)
	)
	procedural_layer["height_blend_percent"] = float(
		brush_layer.get("height_blend_percent", 0.0)
	)
	procedural_layer["masks"] = _procedural_rules_from_brush_layer(
		brush_layer,
		brush_layer_index
	)
	_draft.set_layer(procedural_layer_index, procedural_layer)
	_selected_layers[Workflow.PROCEDURAL] = procedural_layer_index
	# A level-wide pass must be representable on every face before either the
	# palette recipe or any face mapping is committed.
	var assignment := viewport.assign_material_palette_to_all_faces(procedural_layer_index)
	if int(assignment.get("error", FAILED)) != OK:
		_draft.from_json(draft_before_json)
		_selected_layers[Workflow.PROCEDURAL] = selected_before
		_status.text = (
			"Cannot apply this level pass: terrain face '%s' already uses four painted "
			+ "materials. Existing palette and paint were preserved."
		) % String(assignment.get("face_uid", "unknown"))
		return
	var paint_patches: Dictionary = assignment.get("patches", {})
	_commit_profile(
		(
			"Update procedural level pass"
			if updating_existing
			else "Procedurally paint level"
		),
		UndoRedo.MERGE_DISABLE,
		paint_patches
	)
	_refresh_main_controls()


## Select one PNG visually without creating, enabling, or otherwise mutating a material layer.
func _on_material_selected(index: int) -> void:
	if _updating or _draft == null:
		return
	var asset_id := (
		_material_asset_ids[index]
		if index >= 0 and index < _material_asset_ids.size()
		else ""
	)
	if asset_id.is_empty():
		_update_status()
		return
	var workflow := Workflow.PAINT
	var existing := _find_layer_for_asset(asset_id, workflow)
	if existing >= 0:
		_selected_layers[workflow] = existing
		_pending_assets[workflow] = ""
	else:
		_selected_layers[workflow] = -1
		_pending_assets[workflow] = asset_id
	if _no_constraint_mode_enabled():
		_ensure_no_constraint_layer(asset_id)
	_refresh_main_controls()


## Ensure one selected PNG is stored as an enabled paint-only overlay layer.
func _ensure_no_constraint_layer(asset_id: String) -> int:
	if _draft == null or asset_id.is_empty():
		return -1
	var workflow := Workflow.PAINT
	var layer_index := _find_layer_for_asset(asset_id, workflow)
	if layer_index < 0:
		return _allocate_layer(asset_id, workflow, MaskPreset.NONE)
	_selected_layers[workflow] = layer_index
	_pending_assets[workflow] = ""
	var layer := _draft.layer(layer_index)
	var already_unconstrained := (
		_infer_mask_preset(layer, workflow, layer_index) == MaskPreset.NONE
		and bool(layer.get("enabled", false))
	)
	if already_unconstrained:
		return layer_index
	layer["masks"] = _simple_mask_rules(MaskPreset.NONE, workflow, layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	_draft.set_layer(layer_index, layer)
	_commit_profile("Set No Constraint material")
	return layer_index


## Replace the current compact preset immediately while preserving the complete custom editor path.
func _on_mask_selected(_index: int) -> void:
	if _updating or _draft == null:
		return
	var preset := _mask.get_selected_id()
	if preset == MASK_SELECTION_REQUIRED:
		return
	_set_simple_mask_defaults(preset)
	var workflow := Workflow.PAINT
	var layer_index := _selected_layers[workflow]
	if preset == MaskPreset.CUSTOM:
		if layer_index < 0 and not _pending_assets[workflow].is_empty():
			layer_index = _allocate_layer(
				_pending_assets[workflow],
				workflow,
				MaskPreset.NONE
			)
		if layer_index >= 0:
			_open_mask_stack()
		return
	if layer_index < 0:
		if _pending_assets[workflow].is_empty():
			_update_status()
			return
		layer_index = _allocate_layer(_pending_assets[workflow], workflow, preset)
		if layer_index < 0:
			return
	var layer := _draft.layer(layer_index)
	layer["masks"] = _simple_mask_rules(preset, workflow, layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	_draft.set_layer(layer_index, layer)
	# Choosing the mask completes the ordinary three-step workflow, so it arms
	# this material for painting while the visible toggle remains available to release input.
	_mask_paint_mode.set_pressed_no_signal(true)
	_clear_other_paint_modes(_mask_paint_mode)
	_commit_profile("Set brush mask")
	_refresh_main_controls()


## Initialize a newly chosen simple mask to a useful low or high twenty-percent range.
func _set_simple_mask_defaults(preset: int) -> void:
	if preset < MaskPreset.BASE_HEIGHT_LOW or preset > MaskPreset.DIRECTIONAL_BANDS_HIGH:
		return
	if _preset_uses_high_end(preset):
		_range_low.set_value_no_signal(80.0)
		_range_high.set_value_no_signal(100.0)
	else:
		_range_low.set_value_no_signal(0.0)
		_range_high.set_value_no_signal(20.0)
	_fade.set_value_no_signal(10.0)
	_influence.set_value_no_signal(100.0)
	_invert.set_pressed_no_signal(false)
	_noise_scale.set_value_no_signal(2.0)
	_noise_seed.set_value_no_signal(0.0)
	_noise_angle.set_value_no_signal(0.0)


## Keep Range High visibly valid when the user raises the lower bound past it.
func _on_range_low_changed(value: float) -> void:
	if not _updating and value > _range_high.value:
		_range_high.set_value_no_signal(value)
	_on_simple_mask_value_changed(value)


## Keep Range Low visibly valid when the user lowers the upper bound past it.
func _on_range_high_changed(value: float) -> void:
	if not _updating and value < _range_low.value:
		_range_low.set_value_no_signal(value)
	_on_simple_mask_value_changed(value)


## Update a simple mask's visible controls without changing material resources or geometry.
func _on_simple_mask_value_changed(_value: Variant) -> void:
	for slider: HSlider in [
		_range_low,
		_range_high,
		_fade,
		_influence,
		_noise_scale,
	]:
		_update_slider_label(slider)
	if _updating or _draft == null:
		return
	var preset := _mask.get_selected_id()
	if preset < MaskPreset.BASE_HEIGHT_LOW or preset > MaskPreset.DIRECTIONAL_BANDS_HIGH:
		return
	var workflow := Workflow.PAINT
	var layer_index := _selected_layers[workflow]
	if layer_index < 0:
		return
	var layer := _draft.layer(layer_index)
	layer["masks"] = _simple_mask_rules(preset, workflow, layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	_draft.set_layer(layer_index, layer)
	_commit_profile("Adjust brush mask", UndoRedo.MERGE_ENDS)
	_update_status()


## Switch between terrain material painting and one-click native decal stamping.
##
## This is transient tool state only: committing a decal writes presentation on
## the placement itself, while ordinary material painting still writes its layer.
func _on_decal_mode_toggled(enabled: bool) -> void:
	if _updating:
		return
	# One placement has one render role, so arming this disarms the others.
	if enabled:
		_clear_other_paint_modes(_decal_mode)
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Switch between terrain material painting and one-click shader-decal stamping.
##
## A shader decal is committed as a SurfacePlacement exactly like a native decal.
## Its original maps are sampled once through the terrain's ordinary material-layer
## path, with placement-local addressing instead of tiled repetition.
func _on_shader_decal_mode_toggled(enabled: bool) -> void:
	if _updating:
		return
	if enabled:
		_clear_other_paint_modes(_shader_decal_mode)
	_refresh_main_controls()
	tile_brush_mode_changed.emit(uses_tile_brush())


## Refresh the active decal brush when the visible grid-edge toggle changes.
func _on_decal_edge_mode_toggled(_enabled: bool) -> void:
	if _updating:
		return
	_update_viewport_tool()
	_update_status()


## Turn off every local paint or stamp toggle except the one just armed.
##
## One visible mode owns viewport input at a time, so changing modes cannot leave
## the masked painter active behind a decal brush or another placement workflow.
func _clear_other_paint_modes(keep: CheckButton) -> void:
	for toggle: CheckButton in [
		_no_constraint_mode,
		_mask_paint_mode,
		_decal_mode,
		_shader_decal_mode,
	]:
		if toggle != null and toggle != keep:
			toggle.set_pressed_no_signal(false)


## Push the visible palette-match choice into the armed decal brush immediately.
##
## The toggle changes only subsequently authored placements.
func _on_palette_match_toggled(_enabled: bool) -> void:
	if _updating:
		return
	_update_viewport_tool()
	_update_status()


## Return whether one asset carries the height map a decal's relief is built from.
##
## Asked of the asset's own map set rather than assumed, so the panel can say that
## relief is unavailable instead of stamping a decal that silently renders flat.
func _asset_has_height_map(asset: TileAsset) -> bool:
	if asset == null or asset.gbuffer == null:
		return false
	return asset.gbuffer.load_texture("height") != null


## Return whether any stamp mode currently owns the brush.
##
## Both suppress the material-layer controls for the same reason: they commit a
## placement rather than painting into a layer's mask.
func _stamp_mode_active() -> bool:
	return (
		(_decal_mode != null and _decal_mode.button_pressed)
		or (_shader_decal_mode != null and _shader_decal_mode.button_pressed)
	)


## Forward the visible diagnostic checkbox without committing profile or board state.
func _on_mask_preview_toggled(_enabled: bool) -> void:
	if _updating:
		return
	_update_viewport_tool()


## Route the Materials-owned circular pen radius only to the sparse touch-up painter.
func _on_brush_radius_changed(value: float) -> void:
	if viewport != null:
		viewport.set_material_brush_radius(value)


## Route brush strength directly to the sparse painter without creating a layer-opacity duplicate.
func _on_brush_opacity_changed(value: float) -> void:
	_update_slider_label(_brush_opacity)
	if viewport != null:
		viewport.set_material_brush_opacity(value / 100.0)


## Route brush edge hardness directly to the sparse painter's existing capsule kernel.
func _on_brush_hardness_changed(value: float) -> void:
	_update_slider_label(_hardness)
	if viewport != null:
		viewport.set_material_brush_hardness(value / 100.0)


## Open the selected material's two-result appearance editor with live stored values.
func _open_material_settings() -> void:
	var layer_index := _current_layer_index()
	if layer_index < 0 or _draft == null:
		return
	var layer := _draft.layer(layer_index)
	_updating = true
	_material_scale.value = float(layer.get("texture_scale_percent", 100.0))
	_material_height_blend.value = float(layer.get("height_blend_percent", 0.0))
	_update_slider_label(_material_scale)
	_update_slider_label(_material_height_blend)
	_updating = false
	_material_dialog.popup_centered(Vector2i(470, 190))


## Commit material scale and height blending immediately while layer opacity remains deliberately absent.
func _on_material_settings_changed(_value: float) -> void:
	_update_slider_label(_material_scale)
	_update_slider_label(_material_height_blend)
	if _updating or _draft == null:
		return
	var layer_index := _current_layer_index()
	if layer_index < 0:
		return
	var layer := _draft.layer(layer_index)
	layer["texture_scale_percent"] = _material_scale.value
	layer["height_blend_percent"] = _material_height_blend.value
	layer["opacity_percent"] = 100.0
	_draft.set_layer(layer_index, layer)
	_commit_profile("Adjust material appearance", UndoRedo.MERGE_ENDS)


## Open the complete ordered mask editor for the selected material without adding a setup step.
func _open_mask_stack() -> void:
	if _current_layer_index() < 0 or _draft == null:
		return
	_selected_rule = 0
	_refresh_mask_dialog()
	_mask_dialog.popup_centered(Vector2i(520, 620))


## Populate the mask source selector with palette entries for paint or RGBA components for derived maps.
func _populate_rule_channel_options(source: int, selected_id: int) -> void:
	_rule_channel.clear()
	if source == MaterialBlendProfile.MaskSource.PAINT:
		for palette_index: int in _draft.layer_count():
			var layer := _draft.layer(palette_index)
			var asset_id := String(layer.get("asset_id", ""))
			var display := "Palette %d — Unassigned" % (palette_index + 1)
			if not asset_id.is_empty():
				var asset: TileAsset = library.get_asset(asset_id) if library != null else null
				display = (
					asset.display_name
					if asset != null and not asset.display_name.is_empty()
					else asset_id
				)
				display = "Palette %d — %s" % [palette_index + 1, display]
			_rule_channel.add_item(display, palette_index)
			_rule_channel.set_item_disabled(
				_rule_channel.item_count - 1,
				asset_id.is_empty()
			)
		_rule_channel.tooltip_text = (
			"Choose the board-palette material whose painted face weight this condition samples."
		)
	else:
		for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			_rule_channel.add_item(SPLATMAP_CHANNEL_NAMES[channel_index], channel_index)
		_rule_channel.tooltip_text = "Choose the R, G, B, or A component sampled from this derived source."
	var selected_item := _rule_channel.get_item_index(selected_id)
	if selected_item >= 0:
		_rule_channel.select(selected_item)


## Refresh every custom mask field from the one stored layer mask stack.
func _refresh_mask_dialog() -> void:
	var layer_index := _current_layer_index()
	if layer_index < 0 or _draft == null:
		return
	var masks := _draft.layer_masks(layer_index)
	_updating = true
	_rule_select.clear()
	for index: int in masks.size():
		var name := "Brush strokes" if _workflow() == Workflow.PAINT and index == 0 else "Condition %d" % (index + 1)
		_rule_select.add_item(name, index)
		_rule_select.set_item_tooltip(
			index,
			(
				"Required local-stroke gate; add another condition to constrain it."
				if _workflow() == Workflow.PAINT and index == 0
				else "Ordered mask condition %d." % index
			)
		)
	_selected_rule = clampi(_selected_rule, 0, maxi(masks.size() - 1, 0))
	if not masks.is_empty():
		_rule_select.select(_selected_rule)
	var has_rule := not masks.is_empty()
	var protected_paint_rule := _workflow() == Workflow.PAINT and _selected_rule == 0
	_remove_rule_button.disabled = not has_rule or protected_paint_rule or masks.size() <= 1
	_add_rule_button.disabled = masks.size() >= 4
	if has_rule:
		var rule: Dictionary = masks[_selected_rule]
		var rule_source := int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT))
		_rule_source.select(_rule_source.get_item_index(rule_source))
		_rule_combine.select(_rule_combine.get_item_index(int(rule.get("combine", 0))))
		var channel := (
			int(rule.get("paint_channel", layer_index))
			if rule_source == MaterialBlendProfile.MaskSource.PAINT
			else int(rule.get("channel", 0))
		)
		_populate_rule_channel_options(rule_source, channel)
		_rule_low.value = float(rule.get("range_low_percent", 0.0))
		_rule_high.value = float(rule.get("range_high_percent", 100.0))
		_rule_fade.value = float(rule.get("softness_percent", 10.0))
		_rule_strength.value = float(rule.get("strength_percent", 100.0))
		_rule_invert.button_pressed = bool(rule.get("invert", false))
		_rule_noise_scale.value = float(rule.get("noise_scale_m", 2.0))
		_rule_noise_seed.value = float(rule.get("noise_seed", 0))
		_rule_noise_angle.value = float(rule.get("noise_angle_degrees", 0.0))
	_rule_source.disabled = protected_paint_rule
	_rule_combine.disabled = protected_paint_rule
	_rule_channel.disabled = protected_paint_rule
	_rule_low.editable = not protected_paint_rule
	_rule_high.editable = not protected_paint_rule
	_rule_fade.editable = not protected_paint_rule
	_rule_strength.editable = not protected_paint_rule
	_rule_invert.disabled = protected_paint_rule
	_rule_noise_scale.editable = not protected_paint_rule
	_rule_noise_seed.editable = not protected_paint_rule
	_rule_noise_angle.editable = not protected_paint_rule
	var selected_source := (
		int(masks[_selected_rule].get("source", MaterialBlendProfile.MaskSource.PAINT))
		if has_rule
		else MaterialBlendProfile.MaskSource.PAINT
	)
	var uses_noise := _mask_source_uses_noise(selected_source)
	_rule_noise_scale.get_parent().visible = uses_noise
	_rule_noise_seed.get_parent().visible = uses_noise
	_rule_noise_angle.get_parent().visible = (
		selected_source == MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
	)
	_updating = false


## Switch the full mask editor to one stored condition without modifying its values.
func _on_rule_selected(index: int) -> void:
	if _updating:
		return
	_selected_rule = index
	_refresh_mask_dialog()


## Append one explicit mask condition while preserving the shader's four-rule kernel limit.
func _add_mask_rule() -> void:
	var layer_index := _current_layer_index()
	if layer_index < 0 or _draft == null:
		return
	var masks := _draft.layer_masks(layer_index)
	if masks.size() >= 4:
		_status.text = "Each material supports four ordered mask conditions."
		return
	masks.append(MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.BASE_HEIGHT, layer_index))
	_draft.set_layer_masks(layer_index, masks)
	_selected_rule = masks.size() - 1
	_commit_profile("Add material mask condition")
	_refresh_mask_dialog()
	_refresh_main_controls()


## Remove one optional mask condition while retaining the mandatory brush bridge in Paint mode.
func _remove_mask_rule() -> void:
	var layer_index := _current_layer_index()
	if layer_index < 0 or _draft == null:
		return
	var masks := _draft.layer_masks(layer_index)
	if masks.size() <= 1 or (_workflow() == Workflow.PAINT and _selected_rule == 0):
		return
	masks.remove_at(_selected_rule)
	_draft.set_layer_masks(layer_index, masks)
	_selected_rule = clampi(_selected_rule, 0, masks.size() - 1)
	_commit_profile("Remove material mask condition")
	_refresh_mask_dialog()
	_refresh_main_controls()


## Commit one full mask rule edit directly to the same layer consumed by the compact presets.
func _on_rule_value_changed(_value: Variant) -> void:
	if _updating or _draft == null:
		return
	var layer_index := _current_layer_index()
	if layer_index < 0:
		return
	var masks := _draft.layer_masks(layer_index)
	if _selected_rule < 0 or _selected_rule >= masks.size():
		return
	var rule: Dictionary = masks[_selected_rule]
	var protected_paint_rule := _workflow() == Workflow.PAINT and _selected_rule == 0
	if protected_paint_rule:
		return
	var previous_source := int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT))
	var source := _rule_source.get_selected_id()
	if source != previous_source:
		_updating = true
		_populate_rule_channel_options(
			source,
			layer_index if source == MaterialBlendProfile.MaskSource.PAINT else 0
		)
		_updating = false
	rule["source"] = source
	rule["combine"] = _rule_combine.get_selected_id()
	if source == MaterialBlendProfile.MaskSource.PAINT:
		rule["paint_channel"] = _rule_channel.get_selected_id()
	else:
		rule["channel"] = _rule_channel.get_selected_id()
	rule["range_low_percent"] = _rule_low.value
	rule["range_high_percent"] = _rule_high.value
	rule["softness_percent"] = _rule_fade.value
	rule["strength_percent"] = _rule_strength.value
	rule["invert"] = _rule_invert.button_pressed
	rule["noise_scale_m"] = _rule_noise_scale.value
	rule["noise_seed"] = roundi(_rule_noise_seed.value)
	rule["noise_angle_degrees"] = _rule_noise_angle.value
	masks[_selected_rule] = rule
	_draft.set_layer_masks(layer_index, masks)
	var layer := _draft.layer(layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	_draft.set_layer(layer_index, layer)
	_commit_profile("Edit material mask condition", UndoRedo.MERGE_ENDS)
	_refresh_main_controls()


## Open global paint-system algorithms in one focused dialog instead of padding both workflows.
func _open_system_settings() -> void:
	if _draft == null:
		return
	_updating = true
	_blend_mode.select(_blend_mode.get_item_index(int(_draft.blend_mode)))
	_debug_view.select(_debug_view.get_item_index(int(_draft.debug_view)))
	_paint_detail.value = _draft.paint_texels_per_metre
	_maximum_edge.value = _draft.maximum_surface_edge_px
	_pressure_size.button_pressed = _draft.pressure_controls_size
	_pressure_opacity.button_pressed = _draft.pressure_controls_opacity
	_auto_texture_thin_side_slivers.button_pressed = _draft.auto_texture_thin_side_slivers
	_updating = false
	_refresh_resolution_summary()
	_settings_dialog.popup_centered(Vector2i(490, 485))


## Commit cheap global algorithms immediately while resolution remains an explicit rebuild.
func _on_system_settings_changed(_value: Variant) -> void:
	if _updating or _draft == null:
		return
	_draft.blend_mode = _blend_mode.get_selected_id() as MaterialBlendProfile.BlendMode
	_draft.debug_view = _debug_view.get_selected_id() as MaterialBlendProfile.DebugView
	_draft.pressure_controls_size = _pressure_size.button_pressed
	_draft.pressure_controls_opacity = _pressure_opacity.button_pressed
	_commit_profile("Change paint system", UndoRedo.MERGE_ENDS)


## Persist the visible side-strip option; the scoped profile refresh updates its affected batches.
func _on_auto_texture_thin_side_slivers_toggled(enabled: bool) -> void:
	if _updating or _draft == null:
		return
	_draft.auto_texture_thin_side_slivers = enabled
	_commit_profile("Change thin side-strip texturing", UndoRedo.MERGE_ENDS)


## Update the requested memory consequence without mutating canonical paint or board state.
func _on_resolution_settings_changed(_value: float) -> void:
	if _updating or _draft == null:
		return
	_refresh_resolution_summary()


## Build a complete candidate profile from the visible pending resolution controls.
func _resolution_candidate_profile() -> MaterialBlendProfile:
	var candidate := MaterialBlendProfile.new()
	candidate.from_json(_draft.to_json())
	candidate.paint_texels_per_metre = roundi(_paint_detail.value)
	candidate.maximum_surface_edge_px = roundi(_maximum_edge.value)
	return candidate


## Show current and requested controllable RGBA8 memory before the explicit rebuild.
func _refresh_resolution_summary() -> void:
	if _paint_memory_summary == null or _apply_resolution_button == null or _draft == null:
		return
	var candidate := _resolution_candidate_profile()
	var changed := (
		candidate.paint_texels_per_metre != _draft.paint_texels_per_metre
		or candidate.maximum_surface_edge_px != _draft.maximum_surface_edge_px
	)
	_apply_resolution_button.disabled = not changed
	if viewport == null or viewport.surface_material_paint == null:
		_paint_memory_summary.text = "Paint-mask memory is unavailable without an active board."
		return
	var current := viewport.surface_material_paint.paint_memory_bytes()
	var requested := viewport.surface_material_paint.paint_memory_bytes(candidate)
	if (
		int(current.get("error", FAILED)) != OK
		or int(requested.get("error", FAILED)) != OK
	):
		_paint_memory_summary.text = "Paint-mask memory could not be calculated from the active board."
		_apply_resolution_button.disabled = true
		return
	var painted_surfaces := int(current.get("painted_surfaces", 0))
	if painted_surfaces == 0:
		_paint_memory_summary.text = (
			"No brush masks are allocated. New masks will use %d texels/m with a %d px edge cap."
			% [candidate.paint_texels_per_metre, candidate.maximum_surface_edge_px]
		)
		return
	_paint_memory_summary.text = (
		"Controllable mask memory: %s now → %s requested across %d painted surfaces "
		+ "(canonical CPU + derived GPU RGBA8 texels; driver overhead excluded)."
	) % [
		_format_memory_bytes(int(current.get("total_bytes", 0))),
		_format_memory_bytes(int(requested.get("total_bytes", 0))),
		painted_surfaces,
	]


## Format one byte count compactly for the visible paint-memory summary.
static func _format_memory_bytes(byte_count: int) -> String:
	if byte_count >= 1024 * 1024:
		return "%.1f MiB" % (float(byte_count) / float(1024 * 1024))
	if byte_count >= 1024:
		return "%.1f KiB" % (float(byte_count) / 1024.0)
	return "%d B" % byte_count


## Confirm a potentially lossy resample only when canonical paint already exists.
func _request_resolution_rebuild() -> void:
	_refresh_resolution_summary()
	if _apply_resolution_button.disabled:
		return
	if (
		viewport != null
		and viewport.surface_material_paint != null
		and viewport.surface_material_paint.has_any_paint()
	):
		_resolution_dialog.dialog_text = (
			_paint_memory_summary.text
			+ "\n\nExisting masks will be bilinearly resampled. Lower resolution can remove fine "
			+ "mask detail. The current exact masks are retained as compressed undo data."
		)
		_resolution_dialog.popup_centered(Vector2i(520, 260))
		return
	_apply_resolution_rebuild()


## Apply the pending resolution atomically through the viewport's canonical paint owner.
func _apply_resolution_rebuild() -> void:
	if _draft == null or viewport == null or board == null:
		return
	var requested_detail := roundi(_paint_detail.value)
	var requested_edge := roundi(_maximum_edge.value)
	if not viewport.apply_material_paint_resolution(requested_detail, requested_edge):
		_status.text = "Paint-mask resolution rebuild failed; the previous paint is unchanged."
		return
	_draft.from_json(board.material_blend.to_json())
	_refresh_resolution_summary()
	_status.text = (
		"Paint masks rebuilt at %d texels/m with a %d px edge cap."
		% [_draft.paint_texels_per_metre, _draft.maximum_surface_edge_px]
	)


## Ask for explicit confirmation before clearing one palette material's weights everywhere.
func _request_remove_material() -> void:
	_pending_remove_layer = _current_layer_index()
	if _pending_remove_layer >= 0:
		_remove_dialog.title = "Remove Brush Material"
		_remove_dialog.dialog_text = "Remove this brush material and clear its face-local weights from every painted PNG surface?"
		_remove_dialog.popup_centered()


## Ask before removing only the level-wide pass associated with the visible PNG thumbnail.
func _request_remove_level_pass() -> void:
	_pending_remove_layer = _find_layer_for_asset(
		_current_asset_id(),
		Workflow.PROCEDURAL
	)
	if _pending_remove_layer >= 0:
		_remove_dialog.title = "Remove Procedural Level Pass"
		_remove_dialog.dialog_text = "Remove this level-wide pass while preserving the selected material's local brush strokes?"
		_remove_dialog.popup_centered()


## Remove one palette material atomically and clear only its corresponding sparse weights.
func _remove_current_material() -> void:
	if _pending_remove_layer < 0 or _draft == null:
		return
	var removed_layer := _pending_remove_layer
	var removed_mode := int(
		_draft.layer(removed_layer).get(
			"application_mode",
			MaterialBlendProfile.ApplicationMode.BRUSH
		)
	)
	_pending_remove_layer = -1
	var paint_patches: Dictionary = {}
	if viewport != null and viewport.surface_material_paint != null:
		paint_patches = viewport.surface_material_paint.clear_palette_material(removed_layer)
	_draft.set_layer(removed_layer, MaterialBlendProfile.default_layer(removed_layer))
	var splatmap_slots := _draft.splatmap_palette_indices.duplicate()
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		if splatmap_slots[channel_index] == removed_layer:
			splatmap_slots[channel_index] = -1
	_draft.splatmap_palette_indices = splatmap_slots
	for workflow: int in [Workflow.PAINT, Workflow.PROCEDURAL]:
		if _selected_layers[workflow] == removed_layer:
			_selected_layers[workflow] = _find_first_layer(workflow)
	_commit_profile(
		(
			"Remove procedural level pass"
			if removed_mode == MaterialBlendProfile.ApplicationMode.PROCEDURAL
			else "Remove brush material"
		),
		UndoRedo.MERGE_DISABLE,
		paint_patches
	)
	_refresh_main_controls()


## Ask for explicit confirmation before clearing every canonical brush-authored weight image.
func _request_clear_paint() -> void:
	_clear_dialog.popup_centered()


## Clear brush-authored splat images while leaving all procedural layer rules unchanged.
func _clear_brush_paint() -> void:
	if viewport == null:
		return
	viewport.clear_surface_material_paint(true)
	_status.text = "Brush paint cleared; procedural materials and source PNGs were preserved."


## Commit the visible profile through the viewport's scoped refresh planner.
##
## A failed source-projection change restores both the canonical board profile and
## its visible draft before any undo entry is registered.
func _commit_profile(
	action_name: String = "Change surface material",
	merge_mode: int = UndoRedo.MERGE_DISABLE,
	paint_patches: Dictionary = {}
) -> bool:
	if board == null or viewport == null or _draft == null:
		return false
	var before_json := board.material_blend.to_json().duplicate(true)
	for index: int in _draft.layer_count():
		var layer := _draft.layer(index)
		layer["opacity_percent"] = 100.0
		if String(layer.get("asset_id", "")).is_empty():
			layer["enabled"] = false
		_draft.set_layer(index, layer)
	_draft.enabled = _draft.has_active_layers()
	var after_json := _draft.to_json().duplicate(true)
	if before_json == after_json and paint_patches.is_empty():
		_update_status()
		return true
	board.material_blend.from_json(after_json)
	viewport.set_material_pressure_controls(
		_draft.pressure_controls_size,
		_draft.pressure_controls_opacity
	)
	if not viewport.refresh_material_profile_change(before_json):
		board.material_blend.from_json(before_json)
		_draft.from_json(before_json)
		viewport.set_material_pressure_controls(
			_draft.pressure_controls_size,
			_draft.pressure_controls_opacity
		)
		if not viewport.refresh_material_profile_change(after_json):
			push_error("[Tile Studio] The previous material profile could not be restored visibly.")
		_update_status()
		return false
	viewport.register_material_profile_undo(
		before_json,
		after_json,
		action_name,
		merge_mode,
		paint_patches
	)
	_update_status()
	return true


## Arm the viewport brush only after both a visible PNG and an explicit mask exist.
func _update_viewport_tool() -> void:
	if viewport == null:
		return
	var splatmap_mode := _splatmap_mode_enabled()
	var mask_paint_mode := _mask_paint_mode_enabled()
	var no_constraint_mode := _no_constraint_mode_enabled()
	var layer_index := _selected_layers[Workflow.PAINT]
	var local_layer_mode := (
		(mask_paint_mode or no_constraint_mode)
		and not splatmap_mode
		and layer_index >= 0
		and not _stamp_mode_active()
	)
	var layer_asset: TileAsset = null
	if local_layer_mode and _draft != null and library != null:
		var layer_asset_id := String(_draft.layer(layer_index).get("asset_id", ""))
		layer_asset = library.get_asset(layer_asset_id)
	var local_input_ready := layer_asset != null and layer_asset.is_surface()
	var layer_tile_mode := (
		local_layer_mode
		and local_input_ready
		and _paint_target_mode() == PaintTarget.TILE_BRUSH
	)
	if layer_index >= 0:
		viewport.set_material_brush_palette_index(layer_index)
	if local_input_ready:
		viewport.set_material_layer_brush_asset(layer_asset)
	else:
		viewport.clear_material_layer_brush_asset()
	viewport.set_splatmap_tile_paint_enabled(splatmap_mode)
	viewport.set_material_tile_paint_enabled(layer_tile_mode)
	if splatmap_mode:
		# The visible mode delegates input exclusively to the ordinary base-coat
		# controller, which stamps every RGBA weight through one tile gesture.
		viewport.set_material_mask_preview(false, 0)
		viewport.disarm_native_decal_brush()
		viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
		return
	if _stamp_mode_active():
		viewport.set_material_mask_preview(false, 0)
		var asset := library.get_asset(_current_asset_id()) if library != null else null
		if asset == null or not asset.is_surface():
			viewport.disarm_native_decal_brush()
			return
		# The two stamp toggles differ only in the presentation they arm; each
		# commits an ordinary SurfacePlacement through the placement controller.
		if _shader_decal_mode != null and _shader_decal_mode.button_pressed:
			viewport.arm_shader_decal_brush(
				asset,
				(
					_match_underlying_palette != null
					and _match_underlying_palette.button_pressed
				),
				_decal_edge_mode != null and _decal_edge_mode.button_pressed
			)
		else:
			viewport.arm_native_decal_brush(
				asset,
				(
					_match_underlying_palette != null
					and _match_underlying_palette.button_pressed
				),
				_decal_edge_mode != null and _decal_edge_mode.button_pressed
			)
		return

	viewport.disarm_native_decal_brush()
	var preview_enabled := (
		mask_paint_mode
		and layer_index >= 0
		and _mask_preview != null
		and _mask_preview.button_pressed
	)
	viewport.set_material_mask_preview(preview_enabled, maxi(layer_index, 0))
	if layer_tile_mode:
		viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	elif local_layer_mode and local_input_ready:
		viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.PAINT)
	else:
		viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)


## Describe the one missing step or confirm local and level-wide actions without backend jargon.
func _update_status() -> void:
	if _status == null:
		return
	if _draft == null:
		_status.text = "Open or create a board to texture its PNG surfaces."
		return
	if _splatmap_mode_enabled():
		if _draft.splatmap_source_path.is_empty():
			_status.text = "Load an RGBA splatmap to arm the square base-coat terrain brush."
		else:
			var overlay_state := "ON" if _draft.splatmap_overlay_enabled else "OFF"
			var empty_region_state := "native empty regions"
			if _draft.splatmap_fill_empty_regions:
				empty_region_state = "%s base fill ON" % SPLATMAP_CHANNEL_NAMES[
					_draft.splatmap_empty_region_channel
				]
			var strength_state := "native RGBA strengths"
			if _draft.splatmap_channel_strengths_enabled:
				var strengths := _draft.splatmap_channel_strengths * 100.0
				strength_state = "R %.0f%% · G %.0f%% · B %.0f%% · A %.0f%%" % [
					strengths.x,
					strengths.y,
					strengths.z,
					strengths.w,
				]
			_status.text = (
				"Splatmap loaded on %s; empty outer frame fitted to the terrain footprint; "
				+ "overlay %s; %s; %s. The square base-coat brush paints all four RGBA "
				+ "materials together on matching terrain faces."
			) % [
				SPLATMAP_PROJECTION_NAMES[int(_draft.splatmap_projection)],
				overlay_state,
				empty_region_state,
				strength_state,
			]
		return
	if _stamp_mode_active():
		var shader_decal := (
			_shader_decal_mode != null and _shader_decal_mode.button_pressed
		)
		var decal_asset_id := _current_asset_id()
		var kind := "shader" if shader_decal else "native"
		var anchor_note := (
			" Edge placement snaps the image centre to a four-cell grid junction."
			if _decal_edge_mode != null and _decal_edge_mode.button_pressed
			else ""
		)
		if decal_asset_id.is_empty():
			_status.text = (
				"Select a PNG, then click a terrain face to stamp a %s decal.%s"
				% [kind, anchor_note]
			)
		elif shader_decal:
			var decal_asset := (
				library.get_asset(decal_asset_id) if library != null else null
			)
			var footprint_size := (
				decal_asset.surface_footprint()
				if decal_asset != null
				else Vector2i.ONE
			)
			var palette_note := (
				" Palette matching is ON."
				if (
					_match_underlying_palette != null
					and _match_underlying_palette.button_pressed
				)
				else ""
			)
			if not _asset_has_height_map(decal_asset):
				_status.text = (
					"'%s' has no height map, so it will stamp flat. The albedo, normal, "
					+ "ORM, and emission maps still join the terrain material.%s"
				) % [decal_asset_id, palette_note + anchor_note]
			else:
				_status.text = (
					"Click a terrain face to compose %s as one image across its %d x %d "
					+ "footprint. Its height map uses the existing board-wide parallax "
					+ "controls; no separate geometry or transparent draw is created.%s"
				) % [
					decal_asset_id,
					footprint_size.x,
					footprint_size.y,
					palette_note + anchor_note,
				]
		else:
			_status.text = (
				"Click a terrain face to stamp %s as a native decal. Albedo, normal, "
				+ "ORM, and emission apply; height/parallax does not.%s"
			) % [decal_asset_id, anchor_note]
		return
	var workflow := Workflow.PAINT
	var layer_index := _selected_layers[workflow]
	var pending_asset := _pending_assets[workflow]
	if layer_index < 0 and pending_asset.is_empty():
		_status.text = "Step 1: choose the PNG material you want to use."
		return
	if layer_index < 0:
		_status.text = (
			"Step 2: choose a mask for '%s'. Selecting the PNG has not changed the map."
			% pending_asset
		)
		return
	var layer := _draft.layer(layer_index)
	var asset_id := String(layer.get("asset_id", ""))
	if _no_constraint_mode_enabled():
		var unconstrained_instruction := (
			"Use tile Paint, Replace, Erase, Path, or Polygon from the top toolbar."
			if _uses_mask_tile_brush()
			else "Paint with left drag; right drag erases."
		)
		_status.text = (
			"No Constraint ON: %s Arrow keys rotate the PNG for both Pen and Tile. "
			+ "'%s' layers over the base coat without replacing it."
		) % [unconstrained_instruction, asset_id]
		return
	if not _mask_paint_mode_enabled():
		_status.text = (
			"Step 3: turn on Mask-based terrain painting when this layer should own "
			+ "viewport paint input."
		)
		return
	var has_level_pass := _find_layer_for_asset(asset_id, Workflow.PROCEDURAL) >= 0
	var paint_instruction := (
		"Use tile Paint, Replace, Erase, Path, or Polygon from the top toolbar."
		if _uses_mask_tile_brush()
		else "Paint with left drag; right drag erases."
	)
	_status.text = "Mask-based terrain painting ON: %s %s %s" % [
		paint_instruction,
		asset_id,
		(
			"The level pass is active; the bottom button updates it."
			if has_level_pass
			else "The bottom button applies this setup level-wide."
		),
	]
