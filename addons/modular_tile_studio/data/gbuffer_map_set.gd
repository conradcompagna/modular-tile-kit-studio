@tool
class_name GBufferMapSet
extends Resource

## Optional per-asset texture channels (spec 10).
##
## Every channel is optional by design. A perfectly valid asset carries only
## `albedo`. The material factory progressively uses whatever exists and ignores
## the rest, so an asset improves in place as analysis fills channels in rather
## than becoming a different kind of asset.
##
## Paths are stored rather than loaded Textures so the resource stays light and
## regeneration can overwrite files without stale references.

@export var albedo_path: String = ""
@export var alpha_path: String = ""

## MoGe validity mask. This is geometry-analysis metadata, NOT visible alpha.
@export var geometry_mask_path: String = ""

## Marigold IID Lighting diagnostics. They are preserved for inspection and
## export, but are not misrouted into AO or emission because those are different
## physical quantities.
@export var diffuse_shading_path: String = ""
@export var lighting_residual_path: String = ""

@export var depth_path: String = ""
@export var height_path: String = ""

## The shader consumes normal_path; analysis_normal_path retains the untouched AI/source normal when detail relief is baked into that runtime channel.
@export var normal_path: String = ""
@export var analysis_normal_path: String = ""
@export var bent_normal_path: String = ""

@export var ambient_occlusion_path: String = ""
@export var cavity_path: String = ""
@export var curvature_path: String = ""

@export var roughness_path: String = ""
@export var metallic_path: String = ""
@export var orm_path: String = ""

@export var emission_path: String = ""
@export var material_id_path: String = ""

@export var detail_normal_path: String = ""
@export var detail_albedo_path: String = ""

## Per-channel runtime strength, keyed by the same channel names as CHANNELS.
## The map's strength belongs to this material, because the same source map can
## legitimately need a different response on another asset.
@export var channel_strength: Dictionary = {}

## Additive shift applied after a channel's strength, for the two channels
## where that is meaningful (roughness, metallic -- see BIAS_CHANNELS). Same
## per-asset reasoning as channel_strength: a bias shifts what THIS map
## produces, so it belongs beside the map, not on a board-wide profile.
@export var channel_bias: Dictionary = {}

## This asset's own metallic_specular scalar. 0 removes reflections; 1
## maximises them; 0.5 is Godot's physically-plausible default. There is no
## "specular map" channel to attach a strength to -- this IS the whole control
## -- but it is still a property of THIS asset's surface response, not of the
## level, so it lives here rather than on the board-wide profile.
@export var specular_strength: float = 0.5

## Blend between the untouched SOURCE image (0.0) and the analyzed "albedo"
## channel (1.0) when both exist. 1.0 -- use the analyzed albedo exactly -- is
## the default, matching every other strength knob's "1 = use it as authored"
## convention.
##
## This exists for Marigold's intrinsic-lighting decomposition specifically:
## running it overwrites the "albedo" channel with a delit result (see
## marigold_lighting.recipe.json's "10": "albedo" mapping), which is sometimes
## overcorrected and reads washed out compared to the original photo/render.
## Blending back toward the untouched source is the fix, and it belongs here
## rather than as a one-off "undo Marigold" button because the same knob also
## works for any other recipe that overwrites albedo. See
## SurfaceMaterialFactory.get_material's albedo resolution for where this is
## applied -- it blends PIXELS at material-build time; the analyzed albedo
## file on disk is never modified, so re-running analysis or changing this
## slider is always non-destructive.
@export var delight_blend: float = 1.0

## Channel name -> property name. Drives generic get/set/enumerate so callers
## (analysis providers, the inspector, the derived pipeline) can work with
## channel names without a match statement in each one.
const CHANNELS: Dictionary = {
	"albedo": "albedo_path",
	"alpha": "alpha_path",
	"geometry_mask": "geometry_mask_path",
	"diffuse_shading": "diffuse_shading_path",
	"lighting_residual": "lighting_residual_path",
	"depth": "depth_path",
	"height": "height_path",
	"normal": "normal_path",
	"analysis_normal": "analysis_normal_path",
	"bent_normal": "bent_normal_path",
	"ambient_occlusion": "ambient_occlusion_path",
	"cavity": "cavity_path",
	"curvature": "curvature_path",
	"roughness": "roughness_path",
	"metallic": "metallic_path",
	"orm": "orm_path",
	"emission": "emission_path",
	"material_id": "material_id_path",
	"detail_normal": "detail_normal_path",
	"detail_albedo": "detail_albedo_path",
}

## Channels the material builder consumes as a scaled strength rather than as a
## flat map/no-map switch. ORM is a packed runtime input, but it deliberately
## has no independent strength: the AO, roughness, and metallic response knobs
## control its R, G, and B components. Diagnostic-only channels (geometry_mask,
## diffuse_shading, lighting_residual, depth, material_id) and alpha (a hard
## cutout, not a fade) are deliberately excluded: they have no strength
## knob because the renderer does not fade them, per CLAUDE.md 5.2 -- a channel
## either supplies real data or is absent, never a third "partially" state that
## does not exist in the shader/material contract.
const STRENGTH_CHANNELS: PackedStringArray = [
	"albedo", "normal", "bent_normal", "height", "detail_normal",
	"ambient_occlusion", "cavity", "curvature",
	"roughness", "metallic", "emission",
]

## These analysis strengths are applied by the explicit runtime-map bake and are not live shader uniforms.
const BAKE_STRENGTH_CHANNELS: PackedStringArray = ["cavity", "curvature", "detail_normal"]

## Channels that also carry an additive bias alongside their strength.
const BIAS_CHANNELS: PackedStringArray = ["roughness", "metallic"]

## Each material response declares the meaningful range that its inspector
## control presents. Percentage-style map and normal blends stop at 1.0; only
## height and emission support deliberate overdrive.
const STRENGTH_MAXIMUMS: Dictionary = {
	"albedo": 1.0,
	"normal": 1.0,
	"bent_normal": 1.0,
	"height": 4.0,
	"detail_normal": 1.0,
	"ambient_occlusion": 1.0,
	"cavity": 1.0,
	"curvature": 1.0,
	"roughness": 1.0,
	"metallic": 1.0,
	"emission": 8.0,
}

## Detail normals default to a restrained blend because generated detail maps
## often contain much steeper slopes than the macro normal they supplement.
const DEFAULT_STRENGTHS: Dictionary = {
	"detail_normal": 0.25,
}


## Return the range ceiling for one map response, shared by stored values and UI.
func strength_maximum(channel: String) -> float:
	return float(STRENGTH_MAXIMUMS.get(channel, 1.0))


## Return whether one response is consumed only when the user explicitly rebuilds the runtime maps.
func is_bake_strength(channel: String) -> bool:
	return channel in BAKE_STRENGTH_CHANNELS


## Runtime or bake strength for one channel, clamped to its documented meaningful range.
func get_strength(channel: String) -> float:
	var default_value := float(DEFAULT_STRENGTHS.get(channel, 1.0))
	return clampf(float(channel_strength.get(channel, default_value)), 0.0, strength_maximum(channel))


## Set one channel's runtime strength, clamped to the same range the inspector presents.
func set_strength(channel: String, value: float) -> void:
	channel_strength[channel] = clampf(value, 0.0, strength_maximum(channel))
	emit_changed()


## Runtime additive bias for one BIAS_CHANNELS channel, defaulting to 0.0 (no shift) when never set.
func get_bias(channel: String) -> float:
	return float(channel_bias.get(channel, 0.0))


## Set one channel's additive bias, clamped the same as the inspector slider that edits it.
func set_bias(channel: String, value: float) -> void:
	channel_bias[channel] = clampf(value, -1.0, 1.0)
	emit_changed()


## Assign one named map path through the shared channel table so PNG and GLB map sets obey the same storage contract.
func set_channel(channel: String, path: String) -> void:
	var prop: String = CHANNELS.get(channel, "")
	if prop.is_empty():
		push_warning("GBufferMapSet: unknown channel '%s'" % channel)
		return
	set(prop, path)
	emit_changed()


## Resolve one named channel to its stored path, returning empty for unknown or absent channels.
func get_channel(channel: String) -> String:
	var prop: String = CHANNELS.get(channel, "")
	if prop.is_empty():
		return ""
	var stored_value: Variant = get(prop)
	# Cached resources created before a newly added optional channel may not
	# expose that property until their script instance reloads; absence is the
	# normal missing-map state, never a string-conversion error.
	return stored_value if stored_value is String else ""


## Whether a channel points at a file that can be consumed now.
##
## Generated maps often exist on disk before the editor resource scanner has
## imported them. Checking the filesystem as well as ResourceLoader keeps the
## frontend and renderer in agreement during that window.
func has_channel(channel: String) -> bool:
	var path := get_channel(channel)
	if path.is_empty():
		return false
	if ResourceLoader.exists(path):
		return true
	var global_path := ProjectSettings.globalize_path(path)
	return FileAccess.file_exists(global_path) or FileAccess.file_exists(path)


## Explicitly remove one channel through set_channel so resource change notifications stay consistent.
func clear_channel(channel: String) -> void:
	set_channel(channel, "")


## Channel names that currently point at a loadable file, in CHANNELS order.
func available_channels() -> PackedStringArray:
	var out := PackedStringArray()
	for channel: String in CHANNELS:
		if has_channel(channel):
			out.append(channel)
	return out


## Load a channel as a Texture2D, or null when absent/unloadable.
##
## Never pushes an error for a missing channel: absence is the normal case and
## the renderer is required to degrade gracefully (spec 11).
func load_texture(channel: String) -> Texture2D:
	var path := get_channel(channel)
	if path.is_empty():
		return null

	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path) as Texture2D
		if res != null:
			return res

	# Freshly generated files may precede the editor's import scan. Direct Image
	# loading is the same explicit path the GLB albedo loader uses and prevents a
	# map from existing in the inspector while mysteriously not affecting render.
	var global_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(global_path):
		global_path = path
	if not FileAccess.file_exists(global_path):
		return null

	var image := Image.new()
	if image.load(global_path) != OK or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


## Copy every channel path and material response into a new lightweight map set without duplicating texture files.
func duplicate_maps() -> GBufferMapSet:
	var copy := GBufferMapSet.new()
	for channel: String in CHANNELS:
		copy.set_channel(channel, get_channel(channel))
	copy.channel_strength = channel_strength.duplicate()
	copy.channel_bias = channel_bias.duplicate()
	copy.specular_strength = specular_strength
	copy.delight_blend = delight_blend
	return copy
