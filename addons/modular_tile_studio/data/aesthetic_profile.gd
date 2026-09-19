@tool
class_name AestheticProfile
extends Resource

## Global look settings for one board -- only the controls that genuinely act
## on the composed scene or on shared surface behavior.
##
## Material parallax, stochastic synthesis, geometry contact, and final colour
## grade remain board-global because they describe one board-wide response.
## Albedo tint is deliberately absent: TileAsset owns its tint colour and
## strength so each texture shows and stores the exact value the shader consumes.
##
## The knobs are keyed to the BOARD, not the application, so two boards
## authored in the same session keep their own look and the values travel with
## the board JSON (spec 44: the document is authoritative).
##
## Every field carries a default; reset_to_defaults() and reset_section() put
## them back without touching anything else on the board.

const SECTION_SURFACE_GPU := "surface_gpu"
const SECTION_GRADE := "grade"

# --- GPU surface field / material effects ---------------------------------

@export var interaction_effects_enabled: bool = true
@export var backface_culling_enabled: bool = false
@export var one_sided_shadows_enabled: bool = false
## Material-only multiplier for terrain height-map parallax relief.
##
## This never changes terrain vertices, collision, or placement coordinates; it
## only controls the view-dependent texture lookup in the shared surface shader.
@export var parallax_master: float = 1.0
## World metres represented by one pixel along a height image's shorter edge.
##
## Combined with the asset's Height strength and the source resolution, this
## determines visible parallax travel without introducing a second mesh shape.
@export var height_metres_per_source_pixel: float = 0.0001

@export var stochastic_scale: float = 1.0
@export var stochastic_blend_sharpness: float = 1.5
@export var stochastic_seed: float = 0.0

## Gain applied to the stored contact distance field; this is the one authored reach control.
@export var contact_grime: float = 0.65
@export var contact_grime_darkening: float = 0.28
## Opacity falloff from the selected outer boundary back toward the contact source.
@export var contact_grime_fade: float = 1.0
## How strongly world-space noise deforms and perforates the contact mask.
@export var contact_grime_noise: float = 0.45

# --- Colour grade ---------------------------------------------------------

@export var exposure: float = 1.0
@export var contrast: float = 1.0
@export var saturation: float = 1.0
@export var shadow_lift: float = 0.0
@export var highlight_compression: float = 0.0


## Boolean field definitions, same contract as FIELDS: [key, label, section, tooltip].
const TOGGLE_FIELDS: Array = [
	["interaction_effects_enabled", "Contact field", SECTION_SURFACE_GPU,
		"Enable geometry-derived prop silhouettes and wall/floor contact grime."],
	["backface_culling_enabled", "Back-face culling", SECTION_SURFACE_GPU,
		"Render only camera-facing triangles on PNG surfaces and compatible GLB materials. Enable this when the fixed isometric view never needs mesh interiors or reverse-facing cards."],
	["one_sided_shadows_enabled", "One-sided shadows", SECTION_SURFACE_GPU,
		"Cast shadows only from faces that survive material culling. This reduces directional shadow work for the fixed camera; leave it off when thin two-sided cards must cast from both sides."],
]

## Field definitions drive both the UI and reset, so a knob cannot exist in one
## and be forgotten by the other: [key, label, min, max, step, section, tooltip].
const FIELDS: Array = [
	["parallax_master", "Parallax relief", 0.0, 2.0, 0.01, SECTION_SURFACE_GPU,
		"Master multiplier for material-only terrain parallax. It never changes terrain vertices or collision."],
	["height_metres_per_source_pixel", "Height metres per source pixel", 0.0, 0.01, 0.00001, SECTION_SURFACE_GPU,
		"Height range represented by one pixel along the source height image's shorter edge. The material uses this with the texture's full source resolution."],
	["stochastic_scale", "Stochastic world scale", 0.125, 8.0, 0.01, SECTION_SURFACE_GPU,
		"Physical period multiplier used only by assets whose Stochastic tiling checkbox is enabled."],
	["stochastic_blend_sharpness", "Stochastic blend sharpness", 0.5, 8.0, 0.01, SECTION_SURFACE_GPU,
		"Sharpens the three-way triangular stochastic blend. Higher preserves individual patches more strongly; too high can reveal the lattice."],
	["stochastic_seed", "Stochastic seed", 0.0, 10000.0, 1.0, SECTION_SURFACE_GPU,
		"Board-wide deterministic phase seed. Changes texture variation without changing any placements."],
	["contact_grime", "Contact grime", 0.0, 4.0, 0.01, SECTION_SURFACE_GPU,
		"The only contact-mask reach control. Higher values pull more of the stored distance field outward around GLB silhouettes and wall/floor seams."],
	["contact_grime_darkening", "Contact grime darkening", 0.0, 1.0, 0.01, SECTION_SURFACE_GPU,
		"How much the resulting contact mask darkens albedo; this does not change the mask's reach or shape."],
	["contact_grime_fade", "Contact grime fade", 0.0, 1.0, 0.01, SECTION_SURFACE_GPU,
		"Opacity falloff inside the selected mask boundary. Zero is solid to the edge; one fades continuously from the contact source to transparent without retracting the boundary."],
	["contact_grime_noise", "Contact grime noise", 0.0, 1.0, 0.01, SECTION_SURFACE_GPU,
		"Deforms the mask boundary and cuts organic gaps through its coverage. Zero preserves the contact field; one strongly breaks up continuous contour lines."],

	["exposure", "Exposure", 0.05, 4.0, 0.01, SECTION_GRADE,
		"Overall brightness before tonemapping."],
	["contrast", "Contrast", 0.0, 3.0, 0.01, SECTION_GRADE,
		"Contrast around mid grey."],
	["saturation", "Saturation", 0.0, 3.0, 0.01, SECTION_GRADE,
		"Colour intensity. 0 is monochrome."],
	["shadow_lift", "Shadow lift", 0.0, 1.0, 0.01, SECTION_GRADE,
		"Raises the darkest values, for a flatter, more painterly base."],
	["highlight_compression", "Highlight compression", 0.0, 2.0, 0.01, SECTION_GRADE,
		"Rolls off bright values instead of letting them clip."],
]

## The global profile has no colour picker because per-texture tint is authored on TileAsset.
const COLOR_FIELDS: Array = []


## Create a fresh profile containing the shipped values used by reset and missing-board fallbacks.
static func defaults() -> AestheticProfile:
	return AestheticProfile.new()


## Restore every authored look field to the shipped defaults without replacing the resource instance.
func reset_to_defaults() -> void:
	_copy_from(defaults())


## Reset one section only, so tuning the grade never loses surface work.
func reset_section(section: String) -> void:
	var fresh := defaults()
	for definition in TOGGLE_FIELDS:
		if String(definition[2]) == section:
			set(String(definition[0]), fresh.get(String(definition[0])))
	for definition in FIELDS:
		if String(definition[5]) == section:
			set(String(definition[0]), fresh.get(String(definition[0])))
	for definition in COLOR_FIELDS:
		if String(definition[2]) == section:
			set(String(definition[0]), fresh.get(String(definition[0])))


## Copy every declared field from another profile so reset/duplicate cannot drift from the UI field list.
func _copy_from(other: AestheticProfile) -> void:
	for definition in TOGGLE_FIELDS:
		set(String(definition[0]), other.get(String(definition[0])))
	for definition in FIELDS:
		set(String(definition[0]), other.get(String(definition[0])))
	for definition in COLOR_FIELDS:
		set(String(definition[0]), other.get(String(definition[0])))


## Produce an independent profile for board duplication while preserving every currently exposed setting.
func duplicate_profile() -> AestheticProfile:
	var copy := AestheticProfile.new()
	copy._copy_from(self)
	return copy


## True when nothing has been changed from the shipped defaults, so the UI can
## say so rather than making the user compare numbers by eye.
func is_default() -> bool:
	var fresh := defaults()
	for definition in TOGGLE_FIELDS:
		if bool(get(String(definition[0]))) != bool(fresh.get(String(definition[0]))):
			return false
	for definition in FIELDS:
		if not is_equal_approx(float(get(String(definition[0]))), float(fresh.get(String(definition[0])))):
			return false
	for definition in COLOR_FIELDS:
		if get(String(definition[0])) != fresh.get(String(definition[0])):
			return false
	return true


## Serialize only the declared profile fields so board JSON exactly mirrors the controls visible in the editor.
func to_json() -> Dictionary:
	var data: Dictionary = {}
	for definition in TOGGLE_FIELDS:
		data[String(definition[0])] = bool(get(String(definition[0])))
	for definition in FIELDS:
		data[String(definition[0])] = float(get(String(definition[0])))
	return data


## Load profile JSON defensively, keeping defaults for absent older fields and clamping values to the same UI ranges.
func from_json(data: Dictionary) -> void:
	# Unknown keys are ignored and missing keys keep their default, so a board
	# written by an older build still loads.
	reset_to_defaults()
	for definition in TOGGLE_FIELDS:
		var toggle_key := String(definition[0])
		if data.has(toggle_key):
			set(toggle_key, bool(data[toggle_key]))
	for definition in FIELDS:
		var key := String(definition[0])
		if data.has(key):
			set(key, clampf(float(data[key]), float(definition[2]), float(definition[3])))

	# The old vertex-displacement values become the new material-only values when
	# an existing development board is first opened. They are read once and are
	# never written again, leaving a single canonical parallax representation.
	if not data.has("parallax_master") and data.has("gpu_displacement_master"):
		parallax_master = clampf(float(data["gpu_displacement_master"]), 0.0, 2.0)
	if not data.has("height_metres_per_source_pixel") and data.has("chord_metres_per_pixel"):
		height_metres_per_source_pixel = clampf(
			float(data["chord_metres_per_pixel"]), 0.0, 0.01
		)
