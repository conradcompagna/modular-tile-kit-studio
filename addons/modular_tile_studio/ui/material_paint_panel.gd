@tool
class_name MaterialPaintPanel
extends VBoxContainer

const LayoutFeature := preload("material_paint/layout.gd")
const ControlsFeature := preload("material_paint/controls.gd")
const DialogsFeature := preload("material_paint/dialogs.gd")
const BindingFeature := preload("material_paint/binding.gd")
const SelectionFeature := preload("material_paint/selection.gd")
const PaintModesFeature := preload("material_paint/paint_modes.gd")
const MaskPresetsFeature := preload("material_paint/mask_presets.gd")
const RefreshFeature := preload("material_paint/refresh.gd")
const SplatmapFeature := preload("material_paint/splatmap.gd")
const LayersFeature := preload("material_paint/layers.gd")
const MaterialSettingsFeature := preload("material_paint/material_settings.gd")
const MaskStackFeature := preload("material_paint/mask_stack.gd")
const SystemSettingsFeature := preload("material_paint/system_settings.gd")
const ProfileActionsFeature := preload("material_paint/profile_actions.gd")
const ViewportBindingFeature := preload("material_paint/viewport_binding.gd")

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


func _ready() -> void:
	LayoutFeature._ready(self)


func _row(parent: Control, label_text: String, tooltip: String = "") -> HBoxContainer:
	return ControlsFeature._row(self, parent, label_text, tooltip)


func _add_separator(parent: Control) -> void:
	ControlsFeature._add_separator(self, parent)


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
	return ControlsFeature._add_slider(self, parent, label_text, minimum, maximum, step, value, suffix, exponential, tooltip)


func _add_spin(
	parent: Control,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	tooltip: String = ""
) -> SpinBox:
	return ControlsFeature._add_spin(self, parent, label_text, minimum, maximum, step, value, tooltip)


func _add_option(
	parent: Control,
	label_text: String,
	names: PackedStringArray,
	tooltip: String = ""
) -> OptionButton:
	return ControlsFeature._add_option(self, parent, label_text, names, tooltip)


func _update_slider_label(slider: HSlider) -> void:
	ControlsFeature._update_slider_label(self, slider)


func _build_material_dialog() -> void:
	DialogsFeature._build_material_dialog(self)


func _build_mask_dialog() -> void:
	DialogsFeature._build_mask_dialog(self)


func _build_splatmap_dialog() -> void:
	DialogsFeature._build_splatmap_dialog(self)


func _build_settings_dialog() -> void:
	DialogsFeature._build_settings_dialog(self)


func _build_confirmation_dialogs() -> void:
	DialogsFeature._build_confirmation_dialogs(self)


func bind(
	p_board: BoardDocument,
	p_library: AssetLibrary,
	p_viewport: MTSStudioViewport
) -> void:
	BindingFeature.bind(self, p_board, p_library, p_viewport)


func _on_library_changed() -> void:
	BindingFeature._on_library_changed(self)


func _on_material_profile_replayed(profile_json: Dictionary) -> void:
	BindingFeature._on_material_profile_replayed(self, profile_json)


func uses_tile_brush() -> bool:
	return SelectionFeature.uses_tile_brush(self)


func _no_constraint_mode_enabled() -> bool:
	return SelectionFeature._no_constraint_mode_enabled(self)


func _paint_target_mode() -> int:
	return SelectionFeature._paint_target_mode(self)


func activate() -> void:
	SelectionFeature.activate(self)


func _workflow() -> int:
	return SelectionFeature._workflow(self)


func _current_layer_index() -> int:
	return SelectionFeature._current_layer_index(self)


func _current_asset_id() -> String:
	return SelectionFeature._current_asset_id(self)


func _layer_matches_workflow(layer: Dictionary, workflow: int, _layer_index: int) -> bool:
	return SelectionFeature._layer_matches_workflow(self, layer, workflow, _layer_index)


func _find_first_layer(workflow: int) -> int:
	return SelectionFeature._find_first_layer(self, workflow)


func _find_layer_for_asset(asset_id: String, workflow: int) -> int:
	return SelectionFeature._find_layer_for_asset(self, asset_id, workflow)


func _find_empty_layer() -> int:
	return SelectionFeature._find_empty_layer(self)


func _populate_materials() -> void:
	SelectionFeature._populate_materials(self)


func _load_asset_thumbnail(asset: TileAsset) -> Texture2D:
	return SelectionFeature._load_asset_thumbnail(self, asset)


func _surface_assets_newest_first() -> Array[TileAsset]:
	return SelectionFeature._surface_assets_newest_first(self)


func _sort_assets_by_newest(left: TileAsset, right: TileAsset) -> bool:
	return SelectionFeature._sort_assets_by_newest(self, left, right)


func _select_material(asset_id: String) -> void:
	SelectionFeature._select_material(self, asset_id)


func _splatmap_mode_enabled() -> bool:
	return PaintModesFeature._splatmap_mode_enabled(self)


func _mask_paint_mode_enabled() -> bool:
	return PaintModesFeature._mask_paint_mode_enabled(self)


func _uses_mask_tile_brush() -> bool:
	return PaintModesFeature._uses_mask_tile_brush(self)


func _populate_splatmap_channel_gallery() -> void:
	PaintModesFeature._populate_splatmap_channel_gallery(self)


func _on_splatmap_channel_selected(item_index: int) -> void:
	PaintModesFeature._on_splatmap_channel_selected(self, item_index)


func _on_splatmap_mode_toggled(enabled: bool) -> void:
	PaintModesFeature._on_splatmap_mode_toggled(self, enabled)


func _on_mask_paint_mode_toggled(enabled: bool) -> void:
	PaintModesFeature._on_mask_paint_mode_toggled(self, enabled)


func _on_no_constraint_mode_toggled(enabled: bool) -> void:
	PaintModesFeature._on_no_constraint_mode_toggled(self, enabled)


func _on_paint_target_selected(_index: int) -> void:
	PaintModesFeature._on_paint_target_selected(self, _index)


func _on_splatmap_projection_selected(_index: int) -> void:
	PaintModesFeature._on_splatmap_projection_selected(self, _index)


func _on_splatmap_overlay_toggled(enabled: bool) -> void:
	PaintModesFeature._on_splatmap_overlay_toggled(self, enabled)


func _populate_mask_presets(_workflow: int) -> void:
	MaskPresetsFeature._populate_mask_presets(self, _workflow)


func _mask_preset_tooltip(preset: int) -> String:
	return MaskPresetsFeature._mask_preset_tooltip(self, preset)


func _refresh_main_controls() -> void:
	RefreshFeature._refresh_main_controls(self)


func _mask_preview_tooltip(has_layer: bool, decal_mode: bool) -> String:
	return RefreshFeature._mask_preview_tooltip(self, has_layer, decal_mode)


func _refresh_more_menu(has_layer: bool) -> void:
	RefreshFeature._refresh_more_menu(self, has_layer)


func _on_more_action_selected(action: int) -> void:
	RefreshFeature._on_more_action_selected(self, action)


func _open_splatmap_import() -> void:
	SplatmapFeature._open_splatmap_import(self)


func _browse_splatmap() -> void:
	SplatmapFeature._browse_splatmap(self)


func _show_splatmap_file_dialog() -> void:
	SplatmapFeature._show_splatmap_file_dialog(self)


func _on_splatmap_file_selected(path: String) -> void:
	SplatmapFeature._on_splatmap_file_selected(self, path)


func _on_splatmap_file_dialog_canceled() -> void:
	SplatmapFeature._on_splatmap_file_dialog_canceled(self)


func _reopen_splatmap_dialog() -> void:
	SplatmapFeature._reopen_splatmap_dialog(self)


func _populate_splatmap_picker(choices: Array[TileAsset]) -> void:
	SplatmapFeature._populate_splatmap_picker(self, choices)


func _open_splatmap_slot_picker(layer_index: int) -> void:
	SplatmapFeature._open_splatmap_slot_picker(self, layer_index)


func _on_splatmap_picker_selected(item_index: int) -> void:
	SplatmapFeature._on_splatmap_picker_selected(self, item_index)


func _refresh_splatmap_slot_button(layer_index: int) -> void:
	SplatmapFeature._refresh_splatmap_slot_button(self, layer_index)


func _splatmap_slot_asset_ids() -> PackedStringArray:
	return SplatmapFeature._splatmap_slot_asset_ids(self)


func _visible_splatmap_strengths() -> Vector4:
	return SplatmapFeature._visible_splatmap_strengths(self)


func _update_splatmap_live_controls() -> void:
	SplatmapFeature._update_splatmap_live_controls(self)


func _splatmap_channel_assigned(channel: int) -> bool:
	return SplatmapFeature._splatmap_channel_assigned(self, channel)


func _on_splatmap_live_option_changed(_value: Variant) -> void:
	SplatmapFeature._on_splatmap_live_option_changed(self, _value)


func _update_splatmap_summary() -> void:
	SplatmapFeature._update_splatmap_summary(self)


func _apply_splatmap_import() -> void:
	SplatmapFeature._apply_splatmap_import(self)


func _refresh_simple_mask_values(layer: Dictionary, workflow: int, preset: int) -> void:
	MaskPresetsFeature._refresh_simple_mask_values(self, layer, workflow, preset)


func _infer_mask_preset(layer: Dictionary, workflow: int, layer_index: int) -> int:
	return MaskPresetsFeature._infer_mask_preset(self, layer, workflow, layer_index)


func _is_default_paint_rule(value: Variant, layer_index: int) -> bool:
	return MaskPresetsFeature._is_default_paint_rule(self, value, layer_index)


func _preset_uses_noise(preset: int) -> bool:
	return MaskPresetsFeature._preset_uses_noise(self, preset)


func _preset_uses_directional_bands(preset: int) -> bool:
	return MaskPresetsFeature._preset_uses_directional_bands(self, preset)


func _mask_source_uses_noise(source: int) -> bool:
	return MaskPresetsFeature._mask_source_uses_noise(self, source)


func _preset_source(preset: int) -> int:
	return MaskPresetsFeature._preset_source(self, preset)


func _preset_uses_high_end(preset: int) -> bool:
	return MaskPresetsFeature._preset_uses_high_end(self, preset)


func _preset_for_source(source: int, high_end: bool) -> int:
	return MaskPresetsFeature._preset_for_source(self, source, high_end)


func _allocate_layer(asset_id: String, workflow: int, preset: int = MaskPreset.NONE) -> int:
	return LayersFeature._allocate_layer(self, asset_id, workflow, preset)


func _simple_mask_rules(preset: int, workflow: int, layer_index: int) -> Array:
	return LayersFeature._simple_mask_rules(self, preset, workflow, layer_index)


func _procedural_rules_from_brush_layer(
	brush_layer: Dictionary,
	brush_layer_index: int
) -> Array:
	return LayersFeature._procedural_rules_from_brush_layer(self, brush_layer, brush_layer_index)


func _apply_procedural_level() -> void:
	LayersFeature._apply_procedural_level(self)


func _on_material_selected(index: int) -> void:
	LayersFeature._on_material_selected(self, index)


func _ensure_no_constraint_layer(asset_id: String) -> int:
	return LayersFeature._ensure_no_constraint_layer(self, asset_id)


func _on_mask_selected(_index: int) -> void:
	LayersFeature._on_mask_selected(self, _index)


func _set_simple_mask_defaults(preset: int) -> void:
	LayersFeature._set_simple_mask_defaults(self, preset)


func _on_range_low_changed(value: float) -> void:
	LayersFeature._on_range_low_changed(self, value)


func _on_range_high_changed(value: float) -> void:
	LayersFeature._on_range_high_changed(self, value)


func _on_simple_mask_value_changed(_value: Variant) -> void:
	LayersFeature._on_simple_mask_value_changed(self, _value)


func _on_decal_mode_toggled(enabled: bool) -> void:
	PaintModesFeature._on_decal_mode_toggled(self, enabled)


func _on_shader_decal_mode_toggled(enabled: bool) -> void:
	PaintModesFeature._on_shader_decal_mode_toggled(self, enabled)


func _on_decal_edge_mode_toggled(_enabled: bool) -> void:
	PaintModesFeature._on_decal_edge_mode_toggled(self, _enabled)


func _clear_other_paint_modes(keep: CheckButton) -> void:
	PaintModesFeature._clear_other_paint_modes(self, keep)


func _on_palette_match_toggled(_enabled: bool) -> void:
	PaintModesFeature._on_palette_match_toggled(self, _enabled)


func _asset_has_height_map(asset: TileAsset) -> bool:
	return PaintModesFeature._asset_has_height_map(self, asset)


func _stamp_mode_active() -> bool:
	return PaintModesFeature._stamp_mode_active(self)


func _on_mask_preview_toggled(_enabled: bool) -> void:
	PaintModesFeature._on_mask_preview_toggled(self, _enabled)


func _on_brush_radius_changed(value: float) -> void:
	PaintModesFeature._on_brush_radius_changed(self, value)


func _on_brush_opacity_changed(value: float) -> void:
	PaintModesFeature._on_brush_opacity_changed(self, value)


func _on_brush_hardness_changed(value: float) -> void:
	PaintModesFeature._on_brush_hardness_changed(self, value)


func _open_material_settings() -> void:
	MaterialSettingsFeature._open_material_settings(self)


func _on_material_settings_changed(_value: float) -> void:
	MaterialSettingsFeature._on_material_settings_changed(self, _value)


func _open_mask_stack() -> void:
	MaskStackFeature._open_mask_stack(self)


func _populate_rule_channel_options(source: int, selected_id: int) -> void:
	MaskStackFeature._populate_rule_channel_options(self, source, selected_id)


func _refresh_mask_dialog() -> void:
	MaskStackFeature._refresh_mask_dialog(self)


func _on_rule_selected(index: int) -> void:
	MaskStackFeature._on_rule_selected(self, index)


func _add_mask_rule() -> void:
	MaskStackFeature._add_mask_rule(self)


func _remove_mask_rule() -> void:
	MaskStackFeature._remove_mask_rule(self)


func _on_rule_value_changed(_value: Variant) -> void:
	MaskStackFeature._on_rule_value_changed(self, _value)


func _open_system_settings() -> void:
	SystemSettingsFeature._open_system_settings(self)


func _on_system_settings_changed(_value: Variant) -> void:
	SystemSettingsFeature._on_system_settings_changed(self, _value)


func _on_auto_texture_thin_side_slivers_toggled(enabled: bool) -> void:
	SystemSettingsFeature._on_auto_texture_thin_side_slivers_toggled(self, enabled)


func _on_resolution_settings_changed(_value: float) -> void:
	SystemSettingsFeature._on_resolution_settings_changed(self, _value)


func _resolution_candidate_profile() -> MaterialBlendProfile:
	return SystemSettingsFeature._resolution_candidate_profile(self)


func _refresh_resolution_summary() -> void:
	SystemSettingsFeature._refresh_resolution_summary(self)


static func _format_memory_bytes(byte_count: int) -> String:
	return SystemSettingsFeature._format_memory_bytes(byte_count)


func _request_resolution_rebuild() -> void:
	SystemSettingsFeature._request_resolution_rebuild(self)


func _apply_resolution_rebuild() -> void:
	SystemSettingsFeature._apply_resolution_rebuild(self)


func _request_remove_material() -> void:
	ProfileActionsFeature._request_remove_material(self)


func _request_remove_level_pass() -> void:
	ProfileActionsFeature._request_remove_level_pass(self)


func _remove_current_material() -> void:
	ProfileActionsFeature._remove_current_material(self)


func _request_clear_paint() -> void:
	ProfileActionsFeature._request_clear_paint(self)


func _clear_brush_paint() -> void:
	ProfileActionsFeature._clear_brush_paint(self)


func _commit_profile(
	action_name: String = "Change surface material",
	merge_mode: int = UndoRedo.MERGE_DISABLE,
	paint_patches: Dictionary = {}
) -> bool:
	return ProfileActionsFeature._commit_profile(self, action_name, merge_mode, paint_patches)


func _update_viewport_tool() -> void:
	ViewportBindingFeature._update_viewport_tool(self)


func _update_status() -> void:
	ViewportBindingFeature._update_status(self)
