@tool
class_name MaterialBlendProfile
extends Resource

## Stores the board-visible material palette, layer recipes, and paint-resolution contract.
##
## Painted RGBA weights and their per-face palette mappings are authored by
## MTSSurfaceMaterialPaint. This profile owns the unbounded palette and how each
## material is masked; a face mapping decides which four entries its RGBA texel carries.

enum BlendMode {
	LAYER,
	NORMALIZED_SPLAT,
}

enum ApplicationMode {
	BRUSH,
	PROCEDURAL,
}

## Names the one world-facing plane on which the active terrain control image is projected.
enum SplatmapProjection {
	TOP,
	NORTH,
	SOUTH,
	EAST,
	WEST,
}

enum MaskSource {
	PAINT,
	BASE_HEIGHT,
	BASE_CAVITY,
	BASE_CURVATURE,
	BASE_AO,
	BASE_ROUGHNESS,
	BASE_METALLIC,
	BASE_ALBEDO_LUMINANCE,
	BASE_MATERIAL_ID,
	WORLD_HEIGHT,
	ABSOLUTE_ELEVATION,
	SURFACE_UP,
	SURFACE_SLOPE,
	SURFACE_BOTTOM,
	SURFACE_TOP,
	CONTACT,
	SMOOTH_NOISE,
	RIDGED_NOISE,
	CELLULAR_NOISE,
	DIRECTIONAL_BANDS,
}

enum CombineOperation {
	MULTIPLY,
	ADD,
	SUBTRACT,
	MAXIMUM,
	MINIMUM,
}

enum DebugView {
	FINAL_MATERIAL,
	LAYER_1_MASK,
	LAYER_2_MASK,
	LAYER_3_MASK,
	LAYER_4_MASK,
	PAINTED_RGBA,
	BASE_HEIGHT,
	WORLD_HEIGHT,
}

## How many material weights one control texel carries.
##
## This is fixed by the RGBA control image and by the four layer slots the shader
## binds, so it caps how many materials may blend at a single texel. It is NOT a
## limit on how many materials a board may hold: `layers` is the unbounded board
## palette, and each painted face names which of its entries occupy its four slots.
const WEIGHTS_PER_TEXEL: int = 4
const MIN_TEXELS_PER_METRE: int = 4
const MAX_TEXELS_PER_METRE: int = 256
const MIN_SURFACE_EDGE_PX: int = 16
const MAX_SURFACE_EDGE_PX: int = 1024

@export var enabled: bool = false
@export var blend_mode: BlendMode = BlendMode.LAYER
@export_range(4, 256, 4) var paint_texels_per_metre: int = 64
@export_range(16, 1024, 16) var maximum_surface_edge_px: int = 512
@export var debug_view: DebugView = DebugView.FINAL_MATERIAL
## The top-level Materials toggle that gives the normal base-coat brush RGBA ownership.
@export var splatmap_mode_enabled: bool = false
## The independent source-guide toggle; painting never depends on its visibility.
@export var splatmap_overlay_enabled: bool = false
## The exact control image loaded by the visible RGBA setup dialog.
##
## Splat tile strokes resample this canonical source so every painted tile receives
## all four weights without depending on a hidden in-memory copy.
@export var splatmap_source_path: String = ""
## Palette entry carried by each literal R/G/B/A splatmap channel.
##
## Ordinary painting resolves these assignments independently for every terrain face;
## only splatmap mode needs one explicit four-entry mapping because its source pixels
## arrive with fixed R/G/B/A meanings.
@export var splatmap_palette_indices: PackedInt32Array = PackedInt32Array([-1, -1, -1, -1])
## The visible world-facing direction used by preview, brush sampling, and whole-terrain paint.
@export var splatmap_projection: SplatmapProjection = SplatmapProjection.TOP
## Whether effectively black source texels become one explicit base channel before normalization.
@export var splatmap_fill_empty_regions: bool = false
## The visible R/G/B/A slot used as the base wherever optional empty-region filling is enabled.
@export_range(0, 3, 1) var splatmap_empty_region_channel: int = 0
## Whether the optional channel-strength sliders modify the source's native RGBA proportions.
@export var splatmap_channel_strengths_enabled: bool = false
## Per-channel source multipliers applied before the four splat weights are normalized.
@export var splatmap_channel_strengths: Vector4 = Vector4.ONE
@export var pressure_controls_size: bool = true
@export var pressure_controls_opacity: bool = true
## Opt-in derived resolution for residual heightfield wall strips; manual sliver paint still wins.
@export var auto_texture_thin_side_slivers: bool = false
@export var layers: Array[Dictionary] = []


## Start each board with four empty palette positions matching the RGBA texel capacity.
##
## These entries contain no material and impose no board-wide cap; additional materials
## append normally, while the initial stable indices preserve older face mappings.
func _init() -> void:
	ensure_minimum_layers(WEIGHTS_PER_TEXEL)


## Return one complete default mask rule whose values are percentages in the UI.
static func default_rule(
	source: int = MaskSource.PAINT,
	paint_channel: int = 0
) -> Dictionary:
	return {
		"source": clampi(source, MaskSource.PAINT, MaskSource.DIRECTIONAL_BANDS),
		"combine": CombineOperation.MULTIPLY,
		"paint_channel": maxi(paint_channel, 0),
		"channel": 0,
		"range_low_percent": 0.0,
		"range_high_percent": 100.0,
		"softness_percent": 10.0,
		"strength_percent": 100.0,
		"invert": false,
		"noise_scale_m": 2.0,
		"noise_seed": 0,
		"noise_angle_degrees": 0.0,
	}


## Return one complete palette entry whose own paint weight is its first mask.
##
## The rule references this entry's own palette index: a brush material is defined
## by being gated on the weight painted for itself, and a face decides at paint time
## which of its four texel slots carries that weight.
static func default_layer(index: int) -> Dictionary:
	return {
		"enabled": false,
		"asset_id": "",
		"application_mode": ApplicationMode.BRUSH,
		"opacity_percent": 100.0,
		"texture_scale_percent": 100.0,
		"height_blend_percent": 0.0,
		"masks": [default_rule(MaskSource.PAINT, maxi(index, 0))],
	}


## Normalize every palette entry in place without changing how many there are.
##
## The palette is unbounded, so this repairs each entry's fields rather than padding
## or truncating the array to a fixed size the way the four-slot model required.
func ensure_layers() -> void:
	for index: int in layers.size():
		layers[index] = _normalized_layer(layers[index], index)


## Return how many materials this board's palette holds.
func layer_count() -> int:
	return layers.size()


## Grow the palette so it holds at least `count` entries.
##
## Splatmap mode addresses a literal RGBA source and therefore cannot work with
## fewer than four palette entries. This exists for that mode alone; ordinary
## painting appends entries one at a time through add_layer().
func ensure_minimum_layers(count: int) -> void:
	while layers.size() < count:
		layers.append(default_layer(layers.size()))
	ensure_layers()


## Return a duplicated layer so callers cannot mutate saved state invisibly.
func layer(index: int) -> Dictionary:
	ensure_layers()
	if index < 0 or index >= layers.size():
		push_error(
			"MaterialBlendProfile: palette index %d is outside 0..%d."
			% [index, layers.size() - 1]
		)
		return {}
	return layers[index].duplicate(true)


## Append one material to the board palette and return its index.
##
## The palette is unbounded, so this cannot fail the way allocating one of four
## fixed splat channels could. Which four palette entries a given face blends is
## decided per face at paint time, not here.
func add_layer(value: Dictionary) -> int:
	var index := layers.size()
	layers.append(_normalized_layer(value, index))
	emit_changed()
	return index


## Replace one layer only after normalizing every user-visible field.
func set_layer(index: int, value: Dictionary) -> bool:
	if index < 0 or index >= layers.size():
		push_error(
			"MaterialBlendProfile: palette index %d is outside 0..%d."
			% [index, layers.size() - 1]
		)
		return false
	ensure_layers()
	layers[index] = _normalized_layer(value, index)
	emit_changed()
	return true


## Replace one layer's ordered mask stack without creating a second recipe path.
func set_layer_masks(index: int, rules: Array) -> bool:
	var current := layer(index)
	if current.is_empty():
		return false
	current["masks"] = rules.duplicate(true)
	return set_layer(index, current)


## Return the exact mask stack consumed for one layer.
func layer_masks(index: int) -> Array:
	var current := layer(index)
	var value: Variant = current.get("masks", [])
	return (value as Array).duplicate(true) if value is Array else []


## Report whether at least one enabled layer has an explicit overlay asset.
func has_active_layers() -> bool:
	ensure_layers()
	for value: Variant in layers:
		var current: Dictionary = value
		if bool(current.get("enabled", false)) and not String(current.get("asset_id", "")).is_empty():
			return true
	return false


## Return the per-surface RGBA image size for one canonical footprint.
##
## All placements in an existing surface batch share the same asset and therefore
## the same dimensions, which lets one Texture2DArray update exactly one layer.
func paint_resolution(footprint_m: Vector2i) -> Vector2i:
	var ppm := clampi(
		paint_texels_per_metre,
		MIN_TEXELS_PER_METRE,
		MAX_TEXELS_PER_METRE
	)
	var limit := clampi(
		maximum_surface_edge_px,
		MIN_SURFACE_EDGE_PX,
		MAX_SURFACE_EDGE_PX
	)
	var requested := Vector2(
		maxi(1, footprint_m.x) * ppm,
		maxi(1, footprint_m.y) * ppm
	)
	var scale := minf(1.0, float(limit) / maxf(requested.x, requested.y))
	return Vector2i(
		maxi(MIN_SURFACE_EDGE_PX, roundi(requested.x * scale)),
		maxi(MIN_SURFACE_EDGE_PX, roundi(requested.y * scale))
	)


## Return whether the visible recipe needs the board-wide world-height field.
##
## Shader selection and live profile refresh planning share this one answer so an
## ordinary mask edit cannot accidentally trigger a different material lifecycle.
func uses_world_height() -> bool:
	if not enabled:
		return false
	if int(debug_view) == DebugView.WORLD_HEIGHT:
		return true
	for palette_index: int in layer_count():
		var material_layer := layer(palette_index)
		if not bool(material_layer.get("enabled", false)):
			continue
		var rules_value: Variant = material_layer.get("masks", [])
		if not rules_value is Array:
			continue
		for rule_value: Variant in rules_value as Array:
			if (
				rule_value is Dictionary
				and int((rule_value as Dictionary).get("source", -1))
				== MaskSource.WORLD_HEIGHT
			):
				return true
	return false


## Serialize the complete visible profile into portable board JSON.
func to_json() -> Dictionary:
	ensure_layers()
	return {
		"enabled": enabled,
		"blend_mode": int(blend_mode),
		"paint_texels_per_metre": paint_texels_per_metre,
		"maximum_surface_edge_px": maximum_surface_edge_px,
		"debug_view": int(debug_view),
		"splatmap_mode_enabled": splatmap_mode_enabled,
		"splatmap_overlay_enabled": splatmap_overlay_enabled,
		"splatmap_source_path": splatmap_source_path,
		"splatmap_palette_indices": Array(splatmap_palette_indices),
		"splatmap_projection": int(splatmap_projection),
		"splatmap_fill_empty_regions": splatmap_fill_empty_regions,
		"splatmap_empty_region_channel": splatmap_empty_region_channel,
		"splatmap_channel_strengths_enabled": splatmap_channel_strengths_enabled,
		"splatmap_channel_strengths": [
			splatmap_channel_strengths.x,
			splatmap_channel_strengths.y,
			splatmap_channel_strengths.z,
			splatmap_channel_strengths.w,
		],
		"pressure_controls_size": pressure_controls_size,
		"pressure_controls_opacity": pressure_controls_opacity,
		"auto_texture_thin_side_slivers": auto_texture_thin_side_slivers,
		"layers": layers.duplicate(true),
	}


## Replace profile state from saved JSON while clamping it to the UI contract.
func from_json(data: Dictionary) -> void:
	enabled = bool(data.get("enabled", false))
	blend_mode = clampi(
		int(data.get("blend_mode", BlendMode.LAYER)),
		BlendMode.LAYER,
		BlendMode.NORMALIZED_SPLAT
	) as BlendMode
	paint_texels_per_metre = clampi(
		int(data.get("paint_texels_per_metre", 64)),
		MIN_TEXELS_PER_METRE,
		MAX_TEXELS_PER_METRE
	)
	maximum_surface_edge_px = clampi(
		int(data.get("maximum_surface_edge_px", 512)),
		MIN_SURFACE_EDGE_PX,
		MAX_SURFACE_EDGE_PX
	)
	debug_view = clampi(
		int(data.get("debug_view", DebugView.FINAL_MATERIAL)),
		DebugView.FINAL_MATERIAL,
		DebugView.WORLD_HEIGHT
	) as DebugView
	splatmap_mode_enabled = bool(data.get("splatmap_mode_enabled", false))
	splatmap_overlay_enabled = bool(data.get("splatmap_overlay_enabled", false))
	splatmap_source_path = String(data.get("splatmap_source_path", ""))
	splatmap_projection = clampi(
		int(data.get("splatmap_projection", SplatmapProjection.TOP)),
		SplatmapProjection.TOP,
		SplatmapProjection.WEST
	) as SplatmapProjection
	splatmap_fill_empty_regions = bool(data.get("splatmap_fill_empty_regions", false))
	splatmap_empty_region_channel = clampi(
		int(data.get("splatmap_empty_region_channel", 0)),
		0,
		WEIGHTS_PER_TEXEL - 1
	)
	splatmap_channel_strengths_enabled = bool(
		data.get("splatmap_channel_strengths_enabled", false)
	)
	var splatmap_strength_values: Variant = data.get(
		"splatmap_channel_strengths",
		[1.0, 1.0, 1.0, 1.0]
	)
	if splatmap_strength_values is Array and (splatmap_strength_values as Array).size() == WEIGHTS_PER_TEXEL:
		var saved_strengths: Array = splatmap_strength_values as Array
		splatmap_channel_strengths = Vector4(
			clampf(float(saved_strengths[0]), 0.0, 4.0),
			clampf(float(saved_strengths[1]), 0.0, 4.0),
			clampf(float(saved_strengths[2]), 0.0, 4.0),
			clampf(float(saved_strengths[3]), 0.0, 4.0)
		)
	else:
		push_error("MaterialBlendProfile: splatmap channel strengths must contain four values.")
		splatmap_channel_strengths = Vector4.ONE
	pressure_controls_size = bool(data.get("pressure_controls_size", true))
	pressure_controls_opacity = bool(data.get("pressure_controls_opacity", true))
	auto_texture_thin_side_slivers = bool(data.get("auto_texture_thin_side_slivers", false))
	var saved_layers: Variant = data.get("layers", [])
	layers.clear()
	if saved_layers is Array:
		for saved_layer: Variant in saved_layers:
			layers.append(
				(saved_layer as Dictionary).duplicate(true)
				if saved_layer is Dictionary
				else {}
			)
	ensure_minimum_layers(WEIGHTS_PER_TEXEL)
	splatmap_palette_indices = _normalized_splatmap_palette_indices(
		data.get("splatmap_palette_indices", null)
	)
	emit_changed()


## Return four explicit palette indices for the literal splatmap channels.
##
## Boards saved before face-local palettes had no separate mapping, so their existing
## palette order is migrated once to the identical R/G/B/A meaning. New or malformed
## entries remain visibly unassigned instead of being redirected to another material.
func _normalized_splatmap_palette_indices(value: Variant) -> PackedInt32Array:
	var result := PackedInt32Array([-1, -1, -1, -1])
	if value is Array or value is PackedInt32Array:
		if value.size() != WEIGHTS_PER_TEXEL:
			push_error("MaterialBlendProfile: splatmap palette mapping must contain four indices.")
			return result
		for slot_index: int in WEIGHTS_PER_TEXEL:
			var palette_index := int(value[slot_index])
			result[slot_index] = (
				palette_index
				if palette_index >= 0 and palette_index < layers.size()
				else -1
			)
		return result
	# This is the explicit version-1 migration: channels previously addressed the
	# first four fixed layers directly, so preserving those indices preserves pixels.
	for slot_index: int in mini(WEIGHTS_PER_TEXEL, layers.size()):
		result[slot_index] = slot_index
	return result


## Return one normalized layer dictionary accepted by both the panel and shader binder.
##
## Layer opacity is fixed at full strength because brush strength and mask influence already author
## the same weight; retaining another persistent multiplier would recreate hidden duplicate state.
## An explicitly empty mask stack is preserved as the visible No Constraint procedural choice.
## Older layers without an application mode are classified once from their first canonical rule.
func _normalized_layer(value: Variant, index: int) -> Dictionary:
	var source: Dictionary = value if value is Dictionary else {}
	var masks_value: Variant = source.get("masks", [])
	var masks: Array = []
	if masks_value is Array:
		for rule_value: Variant in masks_value:
			if rule_value is Dictionary:
				masks.append(_normalized_rule(rule_value, index))
	var inferred_mode := ApplicationMode.PROCEDURAL
	if not masks.is_empty():
		var first_rule: Dictionary = masks[0]
		if (
			int(first_rule.get("source", -1)) == MaskSource.PAINT
			and int(first_rule.get("paint_channel", -1)) == index
		):
			inferred_mode = ApplicationMode.BRUSH
	return {
		"enabled": bool(source.get("enabled", false)),
		"asset_id": String(source.get("asset_id", "")),
		"application_mode": clampi(
			int(source.get("application_mode", inferred_mode)),
			ApplicationMode.BRUSH,
			ApplicationMode.PROCEDURAL
		),
		"opacity_percent": 100.0,
		"texture_scale_percent": clampf(float(source.get("texture_scale_percent", 100.0)), 1.0, 800.0),
		"height_blend_percent": clampf(float(source.get("height_blend_percent", 0.0)), 0.0, 100.0),
		"masks": masks,
	}


## Return one normalized scalar mask rule with no implicit source conversion.
func _normalized_rule(value: Dictionary, default_channel: int) -> Dictionary:
	return {
		"source": clampi(
			int(value.get("source", MaskSource.PAINT)),
			MaskSource.PAINT,
			MaskSource.DIRECTIONAL_BANDS
		),
		"combine": clampi(
			int(value.get("combine", CombineOperation.MULTIPLY)),
			CombineOperation.MULTIPLY,
			CombineOperation.MINIMUM
		),
		# A PAINT rule names the palette entry whose painted weight gates this
		# material, so it is a palette index and has no fixed upper bound. The batch
		# binder translates it into that batch's four texel slots.
		"paint_channel": maxi(int(value.get("paint_channel", default_channel)), 0),
		"channel": clampi(int(value.get("channel", 0)), 0, 3),
		"range_low_percent": clampf(
			float(value.get("range_low_percent", 0.0)),
			0.0,
			100.0
		),
		"range_high_percent": clampf(
			float(value.get("range_high_percent", 100.0)),
			0.0,
			100.0
		),
		"softness_percent": clampf(
			float(value.get("softness_percent", 10.0)),
			0.0,
			100.0
		),
		"strength_percent": clampf(
			float(value.get("strength_percent", 100.0)),
			0.0,
			100.0
		),
		"invert": bool(value.get("invert", false)),
		"noise_scale_m": clampf(float(value.get("noise_scale_m", 2.0)), 0.01, 10000.0),
		"noise_seed": int(value.get("noise_seed", 0)),
		"noise_angle_degrees": clampf(
			float(value.get("noise_angle_degrees", 0.0)),
			0.0,
			360.0
		),
	}
