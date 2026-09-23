@tool
class_name AssetInspectorPanel
extends ScrollContainer

## Right column: brush/asset inspector (spec 52).
##
## Shows different fields for surfaces and props, plus the optional analysis
## controls. Analysis is always presented as optional -- an asset with only
## albedo is complete and paintable (spec 18).

const K := preload("../utils/mts_constants.gd")
const GLBCanonicalizer := preload("../importers/glb_canonicalizer.gd")
const SurfaceFactory := preload("../rendering/surface_material_factory.gd")

## Small previews keep every generated/material map inspectable without turning
## the inspector into a full-resolution image viewer.
const MAP_PREVIEW_SIZE: int = 84
const MAP_PREVIEW_CACHE_LIMIT: int = 160

## Human-readable meaning and the material response that consumes each visible channel.
const CHANNEL_INFO: Dictionary = {
	"albedo": ["Albedo", "Generated/albedo map. Use Generated albedo blend below to mix it with the untouched source image."],
	"alpha": ["Alpha", "Cutout -- explicit alpha only, no strength knob"],
	"geometry_mask": ["Geometry mask", "Diagnostic only -- MoGe geometry-validity mask, constrains derived maps at analysis time, not a runtime material input"],
	"diffuse_shading": ["Diffuse shading", "Diagnostic only -- Marigold's recovered illumination, the part divided OUT of albedo during delighting"],
	"lighting_residual": ["Lighting residual", "Diagnostic only -- Marigold's non-diffuse residual (specular highlights, direct light sources)"],
	"depth": ["Depth / disparity", "Diagnostic only -- raw analysis input; Height below is derived from this"],
	"height": ["Height", "Per-material Height strength; 1.0 uses the automatic physical range calculated from this 0–1 CHORD image and the authored surface size."],
	"normal": ["Runtime normal", "Primary runtime normal sampled at the parallax-shifted position. Rebuild Runtime Maps bakes the analysis normal and detail normal into this one texture."],
	"analysis_normal": ["Analysis normal", "Untouched CHORD normal retained as an inspectable bake input; the runtime shader does not sample it directly."],
	"bent_normal": ["Bent normal (analysis only)", "CHORD least-occluded direction retained for inspection and export; it is not representable in ORM and has no runtime sampler."],
	"ambient_occlusion": ["Ambient occlusion", "Primary AO response control. Rebuild Runtime Maps packs this map and cavity into ORM red."],
	"cavity": ["Cavity bake input", "Fine occlusion analysis baked into ORM red at the stored bake strength; it has no independent runtime sampler."],
	"curvature": ["Curvature bake input", "Height-derived edge response baked into ORM green at the stored bake strength; it has no independent runtime sampler."],
	"roughness": ["Roughness", "Primary roughness response strength + bias applied to ORM green at runtime."],
	"metallic": ["Metallic", "Primary metallic response strength + bias applied to ORM blue at runtime."],
	"orm": ["Runtime ORM", "Final packed runtime map -- R=AO plus cavity, G=roughness plus curvature, B=metallic. The shader reads all three from one texture."],
	"emission": ["Emission", "Emission strength"],
	"material_id": ["Material ID", "Diagnostic only -- segmentation output, not a material input"],
	"detail_normal": ["Detail normal bake input", "Fine tangent-space normal analysis baked into Runtime normal at the stored bake strength; it has no independent runtime sampler."],
	"detail_albedo": ["Detail albedo", "Detail layer colour -- used only when a detail normal is also present"],
}

## Visible material channels, in inspector order. Analysis-only intermediates
## remain in the stored map set for derivation/export but are not rendered or
## shown here as if they were artist-facing material controls.
const DISPLAY_CHANNELS: PackedStringArray = [
	"albedo", "alpha",
	"normal", "analysis_normal", "bent_normal", "height",
	"ambient_occlusion", "cavity", "curvature",
	"roughness", "metallic", "orm", "emission",
	"detail_normal", "detail_albedo",
]

signal analyze_requested(asset: TileAsset, recipe: Dictionary)
signal regenerate_derived_requested(asset: TileAsset)
signal channel_attach_requested(asset: TileAsset, channel: String)
signal channel_clear_requested(asset: TileAsset, channel: String)
## User asked to strip the flat background plate off this surface's art. The
## panel does not do the work: it writes a derived image and repoints the
## asset's albedo, which the plugin owns.
signal remove_background_requested(asset: TileAsset)
## User asked to go back to the untouched source art. Possible because the cut
## is a separate file rather than an overwrite of the original.
signal restore_background_requested(asset: TileAsset)
## Emitted when the user edits asset metadata. `geometry_changed` is true when
## the edit alters footprint/occupancy, meaning placements must be rebuilt.
signal asset_edited(asset: TileAsset, geometry_changed: bool)
## Emitted only when Apply commits the selected GLB contact mode.
## Every existing floor instance then receives that one stored mode together.
signal prop_contact_flatten_changed(asset: TileAsset)
## User requested an explicit prop derivation. Apply Size rebuilds source-based
## pose and collision as well as the selected runtime GLB; Rebuild Optimized
## Asset changes only the runtime artifact and preserves authored voxel collision.
signal prop_rebuild_requested(asset: TileAsset, settings: Dictionary)
var asset: TileAsset
var recipes: Array[Dictionary] = []
var provider_available: bool = false
var provider_status: String = "offline"

var _root: VBoxContainer
## The rebuilt inspector retains visible image controls for exact refresh and regression checks.
var _surface_tint_picker: ColorPickerButton
var _surface_tint_strength_slider: HSlider
var _surface_image_adjustment_sliders: Dictionary = {}
var _surface_image_adjustment_reset_button: Button

## path|mtime -> downscaled preview texture. Rebuilding the inspector must not
## repeatedly decode several 2K maps for every GLB facing.
var _map_preview_cache: Dictionary = {}

## Build the inspector container once; all asset-specific controls are regenerated by rebuild().
func _ready() -> void:
	custom_minimum_size = Vector2(300, 0)
	# Hard ceiling. Long asset ids and file paths otherwise widen the panel
	# without limit, pushing it past the edge of the editor window.
	size_flags_horizontal = Control.SIZE_SHRINK_END
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root = VBoxContainer.new()
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_root)
	rebuild()


## Point the inspector at one live asset resource and immediately redraw its actual stored/generated state.
func set_asset(p_asset: TileAsset) -> void:
	asset = p_asset
	rebuild()


## Replace the visible analysis recipe list with the provider's current recipe descriptors.
func set_recipes(p_recipes: Array[Dictionary]) -> void:
	recipes = p_recipes
	rebuild()


## Update analysis availability and rebuild so recipe buttons never disagree with backend reachability.
func set_provider_state(available: bool, status: String) -> void:
	provider_available = available
	provider_status = status
	rebuild()


## Recreate the inspector from the live asset resource so every backend value shown here is authoritative rather than cached UI state.
func rebuild() -> void:
	if _root == null:
		return
	_surface_tint_picker = null
	_surface_tint_strength_slider = null
	_surface_image_adjustment_sliders.clear()
	_surface_image_adjustment_reset_button = null
	for child in _root.get_children():
		child.queue_free()

	if asset == null:
		var empty := Label.new()
		empty.text = "No asset selected."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_root.add_child(empty)
		_add_analysis_status_only()
		return

	_heading(asset.asset_id)
	_field("Source", asset.source_path.get_file())

	# Editable metadata. Everything the import dialog asks for must remain
	# changeable afterwards -- getting a name or a tile size wrong on import
	# should not mean re-importing the asset.
	_text_field("Name", asset.display_name, func(v: String) -> void:
		asset.display_name = v
		asset_edited.emit(asset, false))
	# Category is shown, not edited. There are exactly two, and which one an
	# asset belongs to follows from what it IS -- a PNG or a GLB -- so there is
	# nothing here for the user to decide or to get wrong.
	_field("Category", asset.category_name())
	_text_field("Biome", asset.biome, func(v: String) -> void:
		asset.biome = v
		asset_edited.emit(asset, false))

	if asset.is_surface():
		_build_surface_section()
	else:
		_build_prop_section()

	_build_gbuffer_section()
	_build_analysis_section()


# --- Surfaces -------------------------------------------------------------

func _build_surface_section() -> void:
	_separator()
	_heading("SURFACE")

	# Physical size is editable: an import guessed or typed wrong must be
	# fixable in place. Changing it rebuilds placements, so the board updates.
	var size_row := HBoxContainer.new()
	var size_label := Label.new()
	size_label.text = "Size (m)"
	size_label.custom_minimum_size = Vector2(110, 0)
	size_label.add_theme_font_size_override("font_size", 11)
	size_label.modulate = Color(0.7, 0.74, 0.8)
	size_row.add_child(size_label)

	var width_spin := SpinBox.new()
	width_spin.min_value = 1
	width_spin.max_value = 64
	width_spin.value = asset.grid_bounds.x
	width_spin.tooltip_text = "Width in whole metres"
	size_row.add_child(width_spin)

	var by_label := Label.new()
	by_label.text = "x"
	size_row.add_child(by_label)

	var height_spin := SpinBox.new()
	height_spin.min_value = 1
	height_spin.max_value = 64
	height_spin.value = asset.grid_bounds.y
	height_spin.tooltip_text = "Height in whole metres"
	size_row.add_child(height_spin)
	_root.add_child(size_row)

	var aspect_note := Label.new()
	aspect_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	aspect_note.add_theme_font_size_override("font_size", 10)
	aspect_note.modulate = Color(0.65, 0.68, 0.75)
	aspect_note.text = _aspect_note_text()
	_root.add_child(aspect_note)

	var apply_size := func(_v: float) -> void:
		var w := int(width_spin.value)
		var h := int(height_spin.value)
		if asset.grid_bounds.x == w and asset.grid_bounds.y == h:
			return
		# A surface is a quad with no volume, so its footprint IS its whole
		# spatial description -- there is no occupancy to keep in step with it.
		# Props are the opposite and cannot be resized this way at all: theirs
		# is rebuilt from the source GLB behind an explicit Apply.
		asset.grid_bounds = Vector3i(maxi(1, w), maxi(1, h), 1)
		asset.visual_size_m = Vector3(w, h, 0)
		# true = geometry changed, so the board must be revalidated and rebuilt.
		asset_edited.emit(asset, true)
		# The aspect note is derived from the size that just changed, so it is
		# stale the moment the emit returns. The prop path rebuilds for the same
		# reason; a note claiming the old stretch is worse than no note.
		aspect_note.text = _aspect_note_text()
	width_spin.value_changed.connect(apply_size)
	height_spin.value_changed.connect(apply_size)

	var orientation_note := Label.new()
	orientation_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	orientation_note.add_theme_font_size_override("font_size", 10)
	orientation_note.modulate = Color(0.65, 0.68, 0.75)
	orientation_note.text = "Source orientation: Y-up. Rotate or flip each placement with the editor controls."
	_root.add_child(orientation_note)

	_build_background_section()

	_build_surface_alpha_controls()
	_separator()
	_heading("GPU SURFACE")
	var relief_note := Label.new()
	relief_note.text = "The CHORD 0–1 range is calculated from this image and its authored size. This material controls Height strength and stochastic tiling; the displayed mesh is always GPU-displaced and seam-corrected."
	relief_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	relief_note.add_theme_font_size_override("font_size", 11)
	relief_note.add_theme_color_override("font_color", Color(0.60, 0.64, 0.70))
	_root.add_child(relief_note)

	_build_gpu_surface_controls()


## Expose the stored alpha contract and the exact pipeline AUTO currently selects.
func _build_surface_alpha_controls() -> void:
	_separator()
	_heading("ALPHA / DEPTH")

	var mode := OptionButton.new()
	mode.add_item("Auto", TileAsset.SurfaceAlphaMode.AUTO)
	mode.add_item("Opaque", TileAsset.SurfaceAlphaMode.OPAQUE)
	mode.add_item("Cutout", TileAsset.SurfaceAlphaMode.CUTOUT)
	mode.add_item("Translucent blend", TileAsset.SurfaceAlphaMode.BLEND)
	mode.select(asset.surface_alpha_mode)
	mode.tooltip_text = "Opaque writes normal depth, Cutout uses alpha scissor, and Translucent blend uses continuous alpha. Auto chooses Opaque only when every visible pixel is opaque; otherwise it chooses Cutout."
	mode.item_selected.connect(func(index: int) -> void:
		var selected_mode := mode.get_item_id(index)
		if asset.surface_alpha_mode == selected_mode:
			return
		asset.surface_alpha_mode = selected_mode
		asset_edited.emit(asset, false)
		rebuild())
	_root.add_child(mode)

	var resolved_mode := SurfaceFactory.new().resolved_alpha_mode(asset)
	var resolved := Label.new()
	resolved.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	resolved.add_theme_font_size_override("font_size", 10)
	resolved.modulate = Color(0.65, 0.72, 0.82)
	resolved.text = "Actual pipeline: %s. Auto never infers translucency; choose Translucent blend when the whole image is intentionally see-through." % _alpha_mode_name(resolved_mode)
	_root.add_child(resolved)


## Return the label used to expose one resolved alpha pipeline in the inspector.
func _alpha_mode_name(mode: int) -> String:
	match mode:
		TileAsset.SurfaceAlphaMode.OPAQUE:
			return "Opaque"
		TileAsset.SurfaceAlphaMode.CUTOUT:
			return "Cutout"
		TileAsset.SurfaceAlphaMode.BLEND:
			return "Translucent blend"
		_:
			return "Unresolved"


## Build the per-asset colour and sampling controls consumed by every base, painted, or decal use.
##
## Tint, stochastic synthesis, quarter-turns, and mirroring remain independent
## so each visible control owns one non-overlapping material consequence.
func _build_gpu_surface_controls() -> void:
	var status := Label.new()
	status.text = "Live GPU displacement · 32 samples/m · seam-corrected"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 10)
	status.modulate = Color(0.55, 0.82, 0.70)
	_root.add_child(status)

	var tint_row := HBoxContainer.new()
	tint_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tint_label := Label.new()
	tint_label.text = "Tint"
	tint_label.custom_minimum_size = Vector2(150, 0)
	tint_label.add_theme_font_size_override("font_size", 10)
	tint_label.modulate = Color(0.62, 0.70, 0.84)
	tint_label.tooltip_text = "Colour multiplied into this texture's albedo wherever it is used."
	tint_row.add_child(tint_label)
	var tint_picker := ColorPickerButton.new()
	var tint_asset := asset
	_surface_tint_picker = tint_picker
	tint_picker.color = tint_asset.surface_tint_color
	tint_picker.edit_alpha = false
	tint_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tint_picker.tooltip_text = tint_label.tooltip_text
	# Commit once when the picker closes because saving and refreshing the asset
	# on every intermediate colour drag would rebuild its board instances continuously.
	# Capturing this picker and asset keeps a closing popup from editing a later selection.
	tint_picker.popup_closed.connect(func() -> void:
		if not is_instance_valid(tint_asset) or tint_asset.surface_tint_color == tint_picker.color:
			return
		tint_asset.surface_tint_color = tint_picker.color
		asset_edited.emit(tint_asset, false))
	tint_row.add_child(tint_picker)
	_root.add_child(tint_row)

	_surface_tint_strength_slider = _add_strength_row(
		"Tint strength",
		asset.surface_tint_strength,
		0.0,
		1.0,
		"0 is neutral. 1 applies the selected Tint colour at full strength wherever this texture is used.",
		func(value: float) -> void:
			asset.surface_tint_strength = clampf(value, 0.0, 1.0)
			asset_edited.emit(asset, false)
	)

	_surface_image_adjustment_sliders["brightness"] = _add_strength_row(
		"Brightness",
		asset.surface_brightness,
		0.0,
		2.0,
		"0 is black, 1 is the source brightness, and 2 doubles the texture's RGB values.",
		func(value: float) -> void:
			asset.surface_brightness = value
			if _surface_image_adjustment_reset_button != null:
				_surface_image_adjustment_reset_button.disabled = asset.surface_image_adjustments_are_default()
			asset_edited.emit(asset, false)
	)
	_surface_image_adjustment_sliders["contrast"] = _add_strength_row(
		"Contrast",
		asset.surface_contrast,
		0.0,
		2.0,
		"0 removes tonal contrast, 1 preserves the source, and 2 doubles contrast around mid-grey.",
		func(value: float) -> void:
			asset.surface_contrast = value
			if _surface_image_adjustment_reset_button != null:
				_surface_image_adjustment_reset_button.disabled = asset.surface_image_adjustments_are_default()
			asset_edited.emit(asset, false)
	)
	_surface_image_adjustment_sliders["saturation"] = _add_strength_row(
		"Saturation",
		asset.surface_saturation,
		0.0,
		2.0,
		"0 is greyscale, 1 preserves the source colour, and 2 doubles colour intensity.",
		func(value: float) -> void:
			asset.surface_saturation = value
			if _surface_image_adjustment_reset_button != null:
				_surface_image_adjustment_reset_button.disabled = asset.surface_image_adjustments_are_default()
			asset_edited.emit(asset, false)
	)
	_surface_image_adjustment_sliders["sharpness"] = _add_strength_row(
		"Detail",
		asset.surface_sharpness,
		-1.0,
		1.0,
		"0 preserves the source. Negative values soften by low-passing luminance toward the neighbouring pixels; positive values strengthen luminance edges. Alpha is never changed.",
		func(value: float) -> void:
			asset.surface_sharpness = value
			if _surface_image_adjustment_reset_button != null:
				_surface_image_adjustment_reset_button.disabled = asset.surface_image_adjustments_are_default()
			asset_edited.emit(asset, false)
	)
	_surface_image_adjustment_sliders["hue_shift_degrees"] = _add_strength_row(
		"Hue shift",
		asset.surface_hue_shift_degrees,
		-180.0,
		180.0,
		"Rotate this texture's hue in degrees while preserving its luminance and alpha.",
		func(value: float) -> void:
			asset.surface_hue_shift_degrees = value
			if _surface_image_adjustment_reset_button != null:
				_surface_image_adjustment_reset_button.disabled = asset.surface_image_adjustments_are_default()
			asset_edited.emit(asset, false)
	)

	_surface_image_adjustment_reset_button = Button.new()
	_surface_image_adjustment_reset_button.text = "Reset image adjustments"
	_surface_image_adjustment_reset_button.tooltip_text = "Restore Brightness, Contrast, Saturation, Sharpness, and Hue shift to their neutral defaults. Tint is unchanged."
	_surface_image_adjustment_reset_button.disabled = asset.surface_image_adjustments_are_default()
	_surface_image_adjustment_reset_button.pressed.connect(func() -> void:
		asset.reset_surface_image_adjustments()
		asset_edited.emit(asset, false)
		rebuild())
	_root.add_child(_surface_image_adjustment_reset_button)

	var stochastic := CheckBox.new()
	stochastic.text = "Stochastic tiling"
	stochastic.button_pressed = asset.stochastic_tiling
	stochastic.tooltip_text = "Blend three deterministic world-anchored texture phases for this material. Leave off for deliberate motifs or trim sheets."
	stochastic.toggled.connect(func(enabled: bool) -> void:
		asset.stochastic_tiling = enabled
		asset_edited.emit(asset, false))
	_root.add_child(stochastic)

	var rotation := CheckBox.new()
	rotation.text = "Random 90° texture rotation"
	rotation.button_pressed = asset.random_texture_rotation
	rotation.tooltip_text = "Rotate deterministic texture patches in quarter turns wherever this asset is used, including as base terrain. Normal maps rotate with the visible texture."
	rotation.toggled.connect(func(enabled: bool) -> void:
		asset.random_texture_rotation = enabled
		asset_edited.emit(asset, false))
	_root.add_child(rotation)

	var mirroring := CheckBox.new()
	mirroring.text = "Random texture mirroring"
	mirroring.button_pressed = asset.random_texture_mirroring
	mirroring.tooltip_text = "Mirror deterministic texture patches wherever this asset is used, independently of stochastic tiling and rotation. Every PBR channel uses the same mirror."
	mirroring.toggled.connect(func(enabled: bool) -> void:
		asset.random_texture_mirroring = enabled
		asset_edited.emit(asset, false))
	_root.add_child(mirroring)


## Background removal for surface art, offered after import as well as during it.
##
## An AI-generated PNG usually arrives on a flat plate. Removing it is not
## something to decide once at import: whether a tile needs it often only becomes
## obvious once the art is on the board next to its neighbours, so the same
## operation has to be reachable here.
##
## Non-destructive, and therefore reversible. The cut is written as a separate
## file and the untouched source is kept, so this is a toggle rather than a
## one-way button: restoring simply points the albedo back at the original.
func _build_background_section() -> void:
	_separator()
	_heading("BACKGROUND")

	var report: Dictionary = asset.processing.get("background_removed", {})
	var removed: bool = not report.is_empty() and int(report.get("removed_pixels", 0)) > 0

	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 10)

	if removed:
		note.text = "Background removed: %s pixels cleared (%.0f%% of the image, background %s). The original source is kept unchanged." % [
			_grouped(int(report.get("removed_pixels", 0))),
			float(report.get("removed_fraction", 0.0)) * 100.0,
			String(report.get("background", "?"))
		]
		note.modulate = Color(0.55, 0.85, 0.6)
		_root.add_child(note)

		var restore := Button.new()
		restore.text = "Restore Original Background"
		restore.tooltip_text = "Point this asset back at its untouched source image. The cut file is left on disk, so the background can be removed again without reprocessing."
		restore.pressed.connect(func() -> void: restore_background_requested.emit(asset))
		_root.add_child(restore)
		return

	note.text = "Clears the flat plate this art sits on, in place -- the tile keeps its metre size and is not re-framed. Only pixels that exactly match the border colour and connect to the edge are removed, so detail enclosed by the artwork survives."
	note.modulate = Color(0.65, 0.68, 0.75)
	_root.add_child(note)

	var button := Button.new()
	button.text = "Remove Background"
	button.tooltip_text = "Write a background-stripped copy and paint with that instead. The stored source is never modified, so this can be undone with Restore."
	button.pressed.connect(func() -> void: remove_background_requested.emit(asset))
	_root.add_child(button)


## Thousands separators, so a six-figure pixel count is readable at a glance.
func _grouped(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out


# --- Props ----------------------------------------------------------------

## Grid-first prop sizing, applied only on an explicit rebuild.
##
## Nothing here mutates the asset as controls move. Apply Size rebuilds pose and
## collision from source, while Rebuild Optimized Asset replaces only the
## validated runtime GLB. Both actions are explicit and the untouched source
## remains the only input to either derivation.
func _build_prop_section() -> void:
	_separator()
	_heading("PROP")

	_field("Original mesh", "%.3f x %.3f x %.3f m" % [
		asset.source_size_m.x, asset.source_size_m.y, asset.source_size_m.z
	])

	var optimize := CheckBox.new()
	optimize.text = "Optimize mesh"
	optimize.button_pressed = asset.prop_mesh_optimization_enabled
	optimize.tooltip_text = "Render from a separately validated GLB whose base mesh is promoted from a Godot-generated native LOD. The untouched source remains canonical."
	_root.add_child(optimize)

	var mesh_target := OptionButton.new()
	mesh_target.add_item("50% base triangles")
	mesh_target.set_item_metadata(0, 0.5)
	mesh_target.add_item("25% base triangles")
	mesh_target.set_item_metadata(1, 0.25)
	mesh_target.add_item("12.5% base triangles")
	mesh_target.set_item_metadata(2, 0.125)
	var target_index := 2
	if is_equal_approx(asset.prop_mesh_target_ratio, 0.5):
		target_index = 0
	elif is_equal_approx(asset.prop_mesh_target_ratio, 0.25):
		target_index = 1
	mesh_target.select(target_index)
	_root.add_child(mesh_target)

	var texture_limit := OptionButton.new()
	texture_limit.add_item("Original embedded texture size", 0)
	texture_limit.add_item("4096 px maximum", 4096)
	texture_limit.add_item("2048 px maximum", 2048)
	var texture_index := texture_limit.get_item_index(asset.prop_max_texture_size)
	texture_limit.select(texture_index if texture_index >= 0 else 2)
	_root.add_child(texture_limit)

	var update_optimization_controls := func() -> void:
		mesh_target.disabled = not optimize.button_pressed
		texture_limit.disabled = not optimize.button_pressed
	optimize.toggled.connect(func(_enabled: bool) -> void: update_optimization_controls.call())
	update_optimization_controls.call()

	var runtime_status := "Source GLB selected"
	if asset.prop_mesh_optimization_enabled:
		runtime_status = (
			"Optimized GLB ready"
			if asset.prop_model_is_ready()
			else "ERROR: optimized GLB is missing"
		)
	_field("Runtime model", runtime_status)
	var source_metrics: Dictionary = asset.prop_runtime_metrics.get("source", {})
	var output_metrics: Dictionary = asset.prop_runtime_metrics.get("output", {})
	if not source_metrics.is_empty():
		_field("Source cost", _prop_metric_summary(source_metrics))
	if not output_metrics.is_empty():
		_field("Runtime cost", _prop_metric_summary(output_metrics))
	if not asset.prop_runtime_path.is_empty():
		_field("Runtime file", asset.prop_runtime_path.get_file())

	var canonicalizer := GLBCanonicalizer.new()

	# Boxed so the lambdas below can write to them.
	var driver := [clampi(asset.size_driver_axis, 0, 2)]
	var updating := [false]

	var x_spin := SpinBox.new()
	var y_spin := SpinBox.new()
	var z_spin := SpinBox.new()

	for spin in [x_spin, y_spin, z_spin]:
		spin.min_value = 1
		spin.max_value = 128
		spin.step = 1
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	x_spin.value = asset.requested_grid_size.x
	y_spin.value = asset.requested_grid_size.y
	z_spin.value = asset.requested_grid_size.z

	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Grid size"
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(0.7, 0.74, 0.8)
	row.add_child(label)
	row.add_child(x_spin)
	row.add_child(y_spin)
	row.add_child(z_spin)
	_root.add_child(row)

	var stretch := CheckBox.new()
	stretch.text = "Stretch exactly to grid"
	stretch.tooltip_text = "Off: one axis drives a proportional scale and the others are calculated. On: the mesh is distorted to fill the integer box exactly."
	stretch.button_pressed = asset.stretch_to_grid
	_root.add_child(stretch)

	var actual_label := Label.new()
	actual_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(actual_label)

	var recalculate := func(axis: int) -> void:
		if updating[0]:
			return
		driver[0] = axis

		var requested := Vector3i(
			int(x_spin.value),
			int(y_spin.value),
			int(z_spin.value)
		)

		var plan := canonicalizer.compute_grid_plan(
			asset.source_size_m,
			requested,
			driver[0],
			stretch.button_pressed
		)

		var grid: Vector3i = plan["grid_size"]
		var actual: Vector3 = plan["actual_size"]

		if not stretch.button_pressed:
			updating[0] = true
			x_spin.value = grid.x
			y_spin.value = grid.y
			z_spin.value = grid.z
			updating[0] = false

		actual_label.text = (
			"Grid box: %d x %d x %d m\nActual mesh: %.3f x %.3f x %.3f m"
		) % [
			grid.x, grid.y, grid.z,
			actual.x, actual.y, actual.z,
		]

	x_spin.value_changed.connect(func(_v: float) -> void: recalculate.call(0))
	y_spin.value_changed.connect(func(_v: float) -> void: recalculate.call(1))
	z_spin.value_changed.connect(func(_v: float) -> void: recalculate.call(2))
	stretch.toggled.connect(func(_v: bool) -> void: recalculate.call(driver[0]))

	recalculate.call(driver[0])

	var apply := Button.new()
	apply.text = "Apply Size and Rebuild"
	apply.tooltip_text = (
		"Reload the untouched Y-up source GLB and rebuild its canonical pose "
		+ "and voxel collision from scratch. Nothing changes until the complete "
		+ "rebuild succeeds."
	)
	apply.pressed.connect(func() -> void:
		prop_rebuild_requested.emit(asset, {
			"grid_size": Vector3i(
				int(x_spin.value),
				int(y_spin.value),
				int(z_spin.value)
			),
			"driver_axis": driver[0],
			"stretch_to_grid": stretch.button_pressed,
			"rebuild_geometry": true,
			"optimize_mesh": optimize.button_pressed,
			"mesh_target_ratio": float(mesh_target.get_selected_metadata()),
			"max_texture_size": texture_limit.get_selected_id(),
		}))
	_root.add_child(apply)

	var rebuild_runtime := Button.new()
	rebuild_runtime.text = "Rebuild Optimized Asset"
	rebuild_runtime.tooltip_text = "Rebuild or disable the selected runtime GLB from the untouched source without changing pose, placement, or voxel collision."
	rebuild_runtime.pressed.connect(func() -> void:
		prop_rebuild_requested.emit(asset, {
			"rebuild_geometry": false,
			"optimize_mesh": optimize.button_pressed,
			"mesh_target_ratio": float(mesh_target.get_selected_metadata()),
			"max_texture_size": texture_limit.get_selected_id(),
		}))
	_root.add_child(rebuild_runtime)

	var orientation_note := Label.new()
	orientation_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	orientation_note.add_theme_font_size_override("font_size", 10)
	orientation_note.modulate = Color(0.65, 0.68, 0.75)
	orientation_note.text = "Source orientation: Y-up. Rotate or flip each placement with the editor controls."
	_root.add_child(orientation_note)

	_separator()
	_heading("TERRAIN CONTACT")

	var contact_mode_row := HBoxContainer.new()
	var contact_mode_label := Label.new()
	contact_mode_label.text = "Transition"
	contact_mode_label.custom_minimum_size = Vector2(110, 0)
	contact_mode_label.add_theme_font_size_override("font_size", 11)
	contact_mode_label.modulate = Color(0.7, 0.74, 0.8)
	contact_mode_row.add_child(contact_mode_label)

	var contact_mode := OptionButton.new()
	contact_mode.add_item("Off")
	contact_mode.set_item_metadata(0, "off")
	contact_mode.add_item("Smooth")
	contact_mode.set_item_metadata(1, "smooth")
	contact_mode.add_item("Stepped")
	contact_mode.set_item_metadata(2, "stepped")
	var stored_contact_index := 0
	if asset.prop_contact_flatten:
		stored_contact_index = 1 if asset.prop_contact_flatten_smooth else 2
	contact_mode.select(stored_contact_index)
	contact_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contact_mode.tooltip_text = (
		"Off prevents this GLB from changing terrain. Smooth levels the footprint "
		+ "and shares its boundary corners with adjacent quads so they slope into "
		+ "the pad. Stepped levels only the footprint and keeps a real vertical wall "
		+ "at its edge. Selecting a mode does not alter terrain until Apply is pressed."
	)
	contact_mode_row.add_child(contact_mode)
	_root.add_child(contact_mode_row)

	var apply_contact := Button.new()
	apply_contact.tooltip_text = (
		"Commit the selected terrain-contact state for this GLB and every existing "
		+ "floor instance. Smooth and Stepped edit only each instance footprint and "
		+ "its immediate seam neighbourhood. Off prevents future contact edits but "
		+ "cannot reconstruct terrain changed by an earlier Apply."
	)
	var refresh_apply_contact_text := func() -> void:
		var selected_mode := String(contact_mode.get_selected_metadata())
		apply_contact.text = "Apply %s to All Instances" % selected_mode.capitalize()
	contact_mode.item_selected.connect(func(_index: int) -> void:
		refresh_apply_contact_text.call())
	apply_contact.pressed.connect(func() -> void:
		var selected_mode := String(contact_mode.get_selected_metadata())
		asset.prop_contact_flatten = selected_mode != "off"
		asset.prop_contact_flatten_smooth = selected_mode == "smooth"
		prop_contact_flatten_changed.emit(asset))
	refresh_apply_contact_text.call()
	_root.add_child(apply_contact)

	_separator()
	_heading("COLLISION GEOMETRY")

	var measurements_ready := asset.prop_collision_measurements_ready()
	var collision_note := Label.new()
	collision_note.text = (
		"Collision filtering is board-wide. Open Movement Grid in the top toolbar "
		+ "to set one threshold for every GLB and all of its instances."
	)
	collision_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	collision_note.add_theme_font_size_override("font_size", 10)
	collision_note.modulate = Color(0.65, 0.68, 0.75)
	_root.add_child(collision_note)

	var measure_collision := Button.new()
	measure_collision.text = "Rebuild This Asset's Raw Collision Scan"
	measure_collision.tooltip_text = (
		"Reload the untouched source GLB and measure triangle shares for every "
		+ "canonical and 45-degree voxel. The global threshold remains on the board."
	)
	measure_collision.pressed.connect(func() -> void:
		prop_rebuild_requested.emit(asset, {
			"grid_size": Vector3i(
				int(x_spin.value),
				int(y_spin.value),
				int(z_spin.value)
			),
			"driver_axis": driver[0],
			"stretch_to_grid": stretch.button_pressed,
			"rebuild_geometry": true,
			"optimize_mesh": optimize.button_pressed,
			"mesh_target_ratio": float(mesh_target.get_selected_metadata()),
			"max_texture_size": texture_limit.get_selected_id(),
		}))
	_root.add_child(measure_collision)

	var measurement_status := (
		"triangle shares measured"
		if measurements_ready
		else "triangle shares not measured"
	)
	_field("Canonical box", "%d x %d x %d cells | %.2f x %.2f x %.2f actual | %d raw | %s" % [
		asset.grid_bounds.x, asset.grid_bounds.y, asset.grid_bounds.z,
		asset.visual_size_m.x, asset.visual_size_m.y, asset.visual_size_m.z,
		asset.prop_voxels.size(),
		measurement_status,
	])

	# A missing diagonal scan is stated outright because diagonal placement is
	# unavailable until the user explicitly rebuilds this asset from its source GLB.
	var diagonal_bounds := K.diagonal_scan_bounds(asset.grid_bounds)
	if asset.prop_voxels_diagonal.is_empty():
		_field(
			"Diagonal box",
			"not scanned | diagonal placement unavailable until this asset is rebuilt"
		)
	else:
		_field("Diagonal box", "%d x %d x %d cells | %d raw | %s | all 4 diagonal headings" % [
			diagonal_bounds.x, diagonal_bounds.y, diagonal_bounds.z,
			asset.prop_voxels_diagonal.size(),
			measurement_status,
		])

## Format one persisted optimizer measurement as a compact source/runtime row.
func _prop_metric_summary(metrics: Dictionary) -> String:
	return "%s triangles | %s vertices | %d textures | %s texture estimate | %s GLB" % [
		_grouped(int(metrics.get("triangles", 0))),
		_grouped(int(metrics.get("vertices", 0))),
		int(metrics.get("textures", 0)),
		_format_bytes(int(metrics.get("estimated_texture_bytes", 0))),
		_format_bytes(int(metrics.get("file_bytes", 0))),
	]


## Format byte metrics without hiding their approximate unit conversion.
func _format_bytes(byte_count: int) -> String:
	if byte_count >= 1024 * 1024 * 1024:
		return "%.2f GiB" % (float(byte_count) / float(1024 * 1024 * 1024))
	if byte_count >= 1024 * 1024:
		return "%.1f MiB" % (float(byte_count) / float(1024 * 1024))
	if byte_count >= 1024:
		return "%.1f KiB" % (float(byte_count) / 1024.0)
	return "%d B" % byte_count


# --- G-buffer -------------------------------------------------------------

func _build_gbuffer_section() -> void:
	# Props render from their own imported GLB materials -- no gbuffer, no
	# analysis maps to show here. See _deprecated/glb_sprite_pipeline/README.md.
	if asset.is_prop():
		return

	_separator()
	_heading("MATERIAL / ANALYSIS MAPS")


	if asset.gbuffer == null:
		_root.add_child(_small_label("No map set."))
		return

	# PNG maps are authored/analysed resources, so every channel remains directly
	# attachable and clearable. The thumbnail is the actual map the renderer sees.
	# source_path is passed so the untouched original can be shown for Delight
	# blend -- a GLB facing has no separate source to blend against (its render
	# already IS its albedo), so that call omits it.
	_build_map_set_preview(asset.gbuffer, true, asset.source_path)

	var regenerate := Button.new()
	regenerate.text = "Rebuild Runtime Maps"
	regenerate.tooltip_text = "Regenerate height-analysis outputs, then bake cavity and curvature into Runtime ORM and detail normal into Runtime normal. Analysis files remain inspectable; existing explicit primary maps are preserved."
	regenerate.pressed.connect(func() -> void: regenerate_derived_requested.emit(asset))
	_root.add_child(regenerate)


## Draw every visible runtime map as a thumbnail and expose only the controls
## that change its rendered response. Editable PNG map sets also expose explicit
## attach/clear actions; generated GLB facing sets are read-only for the map.
##
## `strength_source` is the GBufferMapSet strength SLIDERS read/write, when it
## differs from `maps` (the one supplying thumbnails/paths). Only surfaces
## call this now (props have no gbuffer to preview), so it is always null in
## practice and falls back to `maps` itself.
func _build_map_set_preview(
	maps: GBufferMapSet,
	editable: bool,
	source_path: String = "",
	strength_source: GBufferMapSet = null
) -> void:
	if maps == null:
		_root.add_child(_small_label("No maps."))
		return
	if strength_source == null:
		strength_source = maps

	# The untouched SOURCE image, shown once above the analyzed channels so it
	# can be compared directly against "albedo" -- and so Delight blend below
	# is editing something the user can see, not a hidden file path. Only
	# meaningful for a PNG surface with a real source_path; a GLB facing's
	# "source" IS its render, already shown as its albedo channel.
	if not source_path.is_empty():
		_add_source_preview_row(strength_source, source_path)

	var present_count := 0
	var missing := PackedStringArray()

	for channel: String in DISPLAY_CHANNELS:
		var path := maps.get_channel(channel)
		if path.is_empty():
			missing.append(channel)
			if editable:
				_add_missing_map_row(channel)
			continue

		present_count += 1
		_add_map_preview_row(maps, strength_source, channel, path, editable)

	if present_count == 0 and not editable:
		_root.add_child(_small_label("No generated maps."))
	elif not editable and not missing.is_empty():
		var absent := _small_label("Not present: %s" % ", ".join(missing))
		absent.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		absent.modulate = Color(0.58, 0.61, 0.68)
		_root.add_child(absent)



## Show the untouched source image (never modified -- see TileAsset.source_path's
## comment) alongside the Delight blend slider that mixes it with the analyzed
## albedo channel. See GBufferMapSet.delight_blend and
## SurfaceMaterialFactory._blend_albedo_with_source for how the blend is
## actually applied at material-build time.
func _add_source_preview_row(strength_source: GBufferMapSet, source_path: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(MAP_PREVIEW_SIZE, MAP_PREVIEW_SIZE)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = _map_preview_texture(source_path)
	preview.tooltip_text = source_path
	row.add_child(preview)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)

	var title := Label.new()
	title.text = "Source (original)"
	title.add_theme_font_size_override("font_size", 11)
	text.add_child(title)

	var role := Label.new()
	role.text = "Untouched import -- never modified. Generated albedo blend below chooses how much remains visible."
	role.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	role.add_theme_font_size_override("font_size", 9)
	role.modulate = Color(0.62, 0.70, 0.84)
	text.add_child(role)

	var file := Label.new()
	file.text = source_path.get_file()
	file.tooltip_text = source_path
	file.clip_text = true
	file.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	file.add_theme_font_size_override("font_size", 9)
	file.modulate = Color(0.60, 0.62, 0.68)
	text.add_child(file)

	_root.add_child(row)

	# This is a separate choice from the Albedo map's own strength: it decides
	# whether the visible base color comes from the untouched import, the
	# generated albedo map, or a direct blend of the two source images.
	_add_strength_row(
		"Generated albedo blend",
		strength_source.delight_blend,
		0.0,
		1.0,
		"0% uses the untouched source image. 100% uses the generated Albedo map. Intermediate values blend both images without modifying either file.",
		func(value: float) -> void:
			strength_source.delight_blend = value
			asset_edited.emit(asset, false)
	)


## Show one visible material channel with a downscaled preview, its shader
## role, correctly ranged response control, optional bias, and edit controls
## when this map set is user-editable.
func _add_map_preview_row(
	maps: GBufferMapSet,
	strength_source: GBufferMapSet,
	channel: String,
	path: String,
	editable: bool
) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(MAP_PREVIEW_SIZE, MAP_PREVIEW_SIZE)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = _map_preview_texture(path)
	preview.tooltip_text = path
	row.add_child(preview)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)

	var info: Array = CHANNEL_INFO.get(channel, [channel.capitalize(), "Stored channel"])
	var title := Label.new()
	title.text = String(info[0])
	title.add_theme_font_size_override("font_size", 11)
	text.add_child(title)

	var role := Label.new()
	role.text = String(info[1])
	if channel == "height" and asset != null:
		role.text += (
			"\nHeight short edge: %.0f px. Terrain parallax travel = pixels × board height metres per source pixel × Height response."
			% SurfaceMaterialFactory.height_image_short_edge_px(asset)
		)
	role.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	role.add_theme_font_size_override("font_size", 9)
	role.modulate = Color(0.62, 0.70, 0.84)
	text.add_child(role)

	var file := Label.new()
	file.text = path.get_file()
	file.tooltip_text = path
	file.clip_text = true
	file.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	file.add_theme_font_size_override("font_size", 9)
	file.modulate = Color(0.60, 0.62, 0.68)
	text.add_child(file)

	if editable:
		var actions := HBoxContainer.new()
		var replace := Button.new()
		replace.text = "Replace"
		replace.tooltip_text = "Attach a different image to the '%s' channel." % channel
		replace.pressed.connect(func() -> void: channel_attach_requested.emit(asset, channel))
		actions.add_child(replace)

		var clear := Button.new()
		clear.text = "Clear"
		clear.tooltip_text = "Clear the '%s' channel explicitly." % channel
		clear.pressed.connect(func() -> void: channel_clear_requested.emit(asset, channel))
		actions.add_child(clear)
		text.add_child(actions)

	_root.add_child(row)

	# Strength controls sit below the thumbnail so their label, slider, and
	# exact value stay readable. GBufferMapSet owns both its range and stored
	# value, ensuring a percentage blend never presents unusable overdrive.
	if GBufferMapSet.STRENGTH_CHANNELS.has(channel) and channel != "bent_normal":
		var label_text := "%s strength" % String(info[0])
		if channel == "albedo":
			label_text = "Albedo map blend"
		elif strength_source.is_bake_strength(channel):
			label_text = "%s bake strength" % String(info[0])
		var maximum := strength_source.strength_maximum(channel)
		var response_text := "0–100% blend; 1.0 uses the authored map exactly." if maximum <= 1.0 else "1.0 uses the authored map exactly; higher values deliberately overdrive it."
		if strength_source.is_bake_strength(channel):
			response_text = "Stored for the next Rebuild Runtime Maps operation; changing it does not add a live runtime sampler."
		_add_strength_row(label_text, strength_source.get_strength(channel), 0.0, maximum,
			"%s %s" % [String(info[0]), response_text],
			func(value: float) -> void:
				strength_source.set_strength(channel, value)
				asset_edited.emit(asset, false))
	if GBufferMapSet.BIAS_CHANNELS.has(channel):
		_add_strength_row("%s bias" % String(info[0]), strength_source.get_bias(channel), -1.0, 1.0,
			"Additive shift applied to this asset's own %s map after its strength." % String(info[0]).to_lower(),
			func(value: float) -> void:
				strength_source.set_bias(channel, value)
				asset_edited.emit(asset, false))


## One labelled slider-plus-exact-value row for a per-asset strength/bias knob, matching the Rendering panel's slider layout.
func _add_strength_row(
	label_text: String,
	value: float,
	minimum: float,
	maximum: float,
	tooltip: String,
	on_change: Callable
) -> HSlider:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(150, 0)
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(0.62, 0.70, 0.84)
	label.tooltip_text = tooltip
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.05
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(80, 0)
	slider.tooltip_text = tooltip
	row.add_child(slider)

	var exact := LineEdit.new()
	exact.custom_minimum_size = Vector2(50, 0)
	exact.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	exact.select_all_on_focus = true
	exact.text = "%.2f" % value
	row.add_child(exact)

	# Same drag-release contract as LookPanelBase._slider: this asset's strength
	# edit invalidates the material cache and rebuilds the board (see
	# plugin.gd's _on_asset_edited), so it must not fire every frame of a drag.
	# The number beside the slider still updates live; on_change waits for
	# drag_ended, which Range fires exactly once on mouse release.
	slider.value_changed.connect(func(next: float) -> void:
		exact.text = "%.2f" % next
		if not slider.has_meta("_dragging"):
			on_change.call(next))
	slider.drag_started.connect(func() -> void:
		slider.set_meta("_dragging", true))
	# Always commit on release, regardless of Range's own value_changed flag --
	# relying on that flag meant a release that Range did not consider a
	# "real" change (e.g. ending a drag back at the starting value after an
	# intermediate move) silently dropped the edit with no error, which is a
	# strictly worse failure mode than committing one extra time.
	slider.drag_ended.connect(func(_value_changed: bool) -> void:
		slider.remove_meta("_dragging")
		on_change.call(slider.value))
	var commit := func() -> void:
		var typed := exact.text.strip_edges()
		if typed.is_valid_float():
			slider.value = clampf(typed.to_float(), minimum, maximum)
		exact.text = "%.2f" % slider.value
	exact.text_submitted.connect(func(_text: String) -> void: commit.call())
	exact.focus_exited.connect(commit)

	_root.add_child(row)
	return slider


## Keep absent visible material channels as explicit inputs so the frontend
## exposes every renderer channel an artist can attach manually.
func _add_missing_map_row(channel: String) -> void:
	var row := HBoxContainer.new()
	var info: Array = CHANNEL_INFO.get(channel, [channel.capitalize(), "Stored channel"])

	var label := Label.new()
	label.text = "[ ] %s" % String(info[0])
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.tooltip_text = String(info[1])
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(0.58, 0.61, 0.68)
	row.add_child(label)

	var attach := Button.new()
	attach.text = "Attach"
	attach.tooltip_text = "Attach an image to the '%s' channel." % channel
	attach.pressed.connect(func() -> void: channel_attach_requested.emit(asset, channel))
	row.add_child(attach)
	_root.add_child(row)


## Decode one map directly from disk and downscale it for the inspector. Direct
## file loading makes freshly generated maps visible before Godot's resource
## filesystem has finished importing them.
func _map_preview_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null

	var global_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(global_path):
		global_path = path
	if not FileAccess.file_exists(global_path):
		return null

	var modified := FileAccess.get_modified_time(global_path)
	var key := "%s|%d" % [global_path, modified]
	var cached: Texture2D = _map_preview_cache.get(key, null)
	if cached != null:
		return cached

	var image := Image.new()
	if image.load(global_path) != OK or image.is_empty():
		return null

	var longest := maxi(image.get_width(), image.get_height())
	if longest > MAP_PREVIEW_SIZE:
		var scale := float(MAP_PREVIEW_SIZE) / float(longest)
		image.resize(
			maxi(1, roundi(float(image.get_width()) * scale)),
			maxi(1, roundi(float(image.get_height()) * scale)),
			Image.INTERPOLATE_LANCZOS
		)
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	var texture := ImageTexture.create_from_image(image)
	if _map_preview_cache.size() >= MAP_PREVIEW_CACHE_LIMIT:
		_map_preview_cache.clear()
	_map_preview_cache[key] = texture
	return texture


# --- Analysis -------------------------------------------------------------

func _build_analysis_section() -> void:
	_separator()
	_heading("AI ANALYSIS")
	_field("Status", asset.analysis_status)
	_add_analysis_status_only()

	if not asset.is_surface():
		var note := Label.new()
		note.text = "Props take exact G-buffer passes from the source mesh, so image analysis is not needed here."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 10)
		_root.add_child(note)
		return

	if recipes.is_empty():
		_root.add_child(_small_label("No recipes found in the recipe directory."))
		return

	for recipe in recipes:
		var row := HBoxContainer.new()
		var needs_setup := bool(recipe.get("requires_setup", false))

		var button := Button.new()
		button.text = String(recipe.get("name", "Recipe"))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = String(recipe.get("description", ""))
		if needs_setup:
			button.tooltip_text += "\n\nNEEDS SETUP: " + String(recipe.get("setup_notes", ""))
		# Analysis is optional: unavailable backends disable the button rather
		# than blocking any other part of the editor.
		button.disabled = not provider_available or needs_setup
		var captured := recipe
		button.pressed.connect(func() -> void: analyze_requested.emit(asset, captured))
		row.add_child(button)

		if needs_setup:
			var flag := Label.new()
			flag.text = "setup"
			flag.add_theme_font_size_override("font_size", 10)
			row.add_child(flag)

		_root.add_child(row)


## Show the current ComfyUI status as read-only backend state beside the analysis controls.
func _add_analysis_status_only() -> void:
	var status := Label.new()
	status.text = "ComfyUI: %s" % provider_status
	status.add_theme_font_size_override("font_size", 10)
	status.modulate = Color(0.55, 0.9, 0.6) if provider_available else Color(0.85, 0.65, 0.5)
	_root.add_child(status)


# --- Small helpers --------------------------------------------------------

func _heading(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	_root.add_child(label)


## Editable single-line field. Commits on Enter and on focus loss, so a typed
## value is never silently lost by clicking away.
func _text_field(key: String, value: String, on_commit: Callable) -> void:
	var row := HBoxContainer.new()
	var key_label := Label.new()
	key_label.text = key
	key_label.custom_minimum_size = Vector2(110, 0)
	key_label.add_theme_font_size_override("font_size", 11)
	key_label.modulate = Color(0.7, 0.74, 0.8)
	row.add_child(key_label)

	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_submitted.connect(func(v: String) -> void: on_commit.call(v))
	edit.focus_exited.connect(func() -> void: on_commit.call(edit.text))
	row.add_child(edit)
	_root.add_child(row)


## Describes how the chosen tile size relates to the source image's aspect, so a
## stretched tile is visible rather than mysterious.
func _aspect_note_text() -> String:
	if asset == null or asset.source_path.is_empty():
		return ""
	var image := Image.new()
	var global_path := ProjectSettings.globalize_path(asset.source_path)
	if not FileAccess.file_exists(global_path) or image.load(global_path) != OK:
		return ""
	var source_aspect := float(image.get_width()) / maxf(1.0, float(image.get_height()))
	var chosen := float(asset.grid_bounds.x) / maxf(1.0, float(asset.grid_bounds.y))
	var base := "Source %d x %d px (aspect %.3f : 1)." % [
		image.get_width(), image.get_height(), source_aspect
	]
	if absf(chosen - source_aspect) / maxf(source_aspect, 0.001) < 0.02:
		return base + " Tile size matches the source aspect."
	return base + " Tile size %d x %d gives %.3f : 1, so the image is stretched to fit." % [
		asset.grid_bounds.x, asset.grid_bounds.y, chosen
	]


## Add one clipped read-only key/value row for derived values the user should be able to audit but not directly edit.
func _field(key: String, value: String) -> void:
	var row := HBoxContainer.new()
	var key_label := Label.new()
	key_label.text = key
	key_label.custom_minimum_size = Vector2(110, 0)
	key_label.add_theme_font_size_override("font_size", 11)
	key_label.modulate = Color(0.7, 0.74, 0.8)
	var value_label := Label.new()
	value_label.text = value
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.add_theme_font_size_override("font_size", 11)
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Wrapping alone does not stop a long unbroken token (a path, an id)
	# from forcing the panel wider than the window.
	value_label.custom_minimum_size = Vector2(120, 0)
	value_label.clip_text = true
	row.add_child(key_label)
	row.add_child(value_label)
	_root.add_child(row)


## Construct the compact labels used for explanatory and missing-data messages without duplicating theme setup.
func _small_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	return label


## Insert a visual divider between inspector sections so generated maps and authoring controls remain easy to audit.
func _separator() -> void:
	_root.add_child(HSeparator.new())
