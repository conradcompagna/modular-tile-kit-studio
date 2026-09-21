@tool
class_name LightingProfile
extends Resource

## Stores every authored lighting, reflection, atmosphere, and environment value for one board.
##
## The profile is the single source of truth for the Lighting panel and the
## StudioViewport. Optional native renderer features remain on this same path:
## a disabled feature simply has its enabled flag set to false.

const MAX_LIGHTS: int = 8

const SECTION_AMBIENT := "ambient"
const SECTION_SKY := "sky"
const SECTION_REFLECTIONS := "reflections"
const SECTION_SCREEN := "screen"
const SECTION_FOG := "fog"
const SECTION_SUN := "sun"

## The sky source is explicit so a missing panorama never silently changes into a procedural sky.
enum SkyMode { PROCEDURAL, PANORAMA }

## Local light nodes are limited to the two native movable point-source types Godot provides.
enum LocalLightType { OMNI, SPOT }

# --- Ambient and tonemap --------------------------------------------------

@export var background_color: Color = Color(0.09, 0.10, 0.12)
@export var ambient_color: Color = Color(0.30, 0.35, 0.42)
@export var ambient_energy: float = 0.45
## Environment.ToneMapper: 0 linear, 1 Reinhardt, 2 filmic, 3 ACES, 4 AgX.
@export var tonemap_mode: int = 2
@export var tonemap_white: float = 1.0

# --- Sky and image-based lighting ----------------------------------------

@export var sky_enabled: bool = false
@export var sky_mode: SkyMode = SkyMode.PROCEDURAL
@export var sky_panorama_path: String = ""
@export var show_sky_background: bool = false
@export var sky_energy_multiplier: float = 1.0
@export var sky_rotation_degrees: float = 0.0
@export var sky_ambient_contribution: float = 1.0
@export var sky_top_color: Color = Color(0.18, 0.32, 0.55)
@export var sky_horizon_color: Color = Color(0.70, 0.74, 0.80)
@export var ground_bottom_color: Color = Color(0.08, 0.07, 0.06)
@export var ground_horizon_color: Color = Color(0.38, 0.34, 0.30)

# --- Reflections and indirect light --------------------------------------

@export var reflection_probe_enabled: bool = false
@export var reflection_probe_intensity: float = 1.0
@export var reflection_probe_padding_m: float = 2.0
@export var reflection_probe_box_projection: bool = true
@export var reflection_probe_shadows: bool = true

@export var sdfgi_enabled: bool = false
@export var sdfgi_energy: float = 1.0
@export var sdfgi_use_occlusion: bool = true
@export var sdfgi_read_sky_light: bool = true

# --- Screen-space environment effects ------------------------------------

@export var ssao_enabled: bool = false
@export var ssao_radius: float = 1.0
@export var ssao_intensity: float = 2.0
@export var ssao_power: float = 1.5
@export var ssao_detail: float = 0.5

## Material AO direct-light influence is board-wide because it belongs to the lighting look, not to individual texture analysis.
@export var material_ao_light_affect: float = 0.25

@export var glow_enabled: bool = false
@export var glow_intensity: float = 0.8
@export var glow_bloom: float = 0.0

@export var ssil_enabled: bool = false
@export var ssil_radius: float = 5.0
@export var ssil_intensity: float = 1.0

@export var ssr_enabled: bool = false
@export var ssr_max_steps: float = 64.0
@export var ssr_fade_in: float = 0.15
@export var ssr_fade_out: float = 2.0
@export var ssr_depth_tolerance: float = 0.2

# --- Fog and atmosphere ---------------------------------------------------

@export var fog_enabled: bool = false
@export var fog_color: Color = Color(0.30, 0.34, 0.42)
@export var fog_density: float = 0.01
@export var fog_depth_begin_m: float = 10.0
@export var fog_depth_end_m: float = 100.0
@export var fog_depth_curve: float = 1.0
@export var fog_height_m: float = 0.0
@export var fog_height_density: float = 0.0
@export var fog_sun_scatter: float = 0.0
@export var fog_aerial_perspective: float = 0.0

@export var volumetric_fog_enabled: bool = false
@export var volumetric_fog_density: float = 0.05
@export var volumetric_fog_albedo: Color = Color.WHITE
@export var volumetric_fog_emission: Color = Color.BLACK
@export var volumetric_fog_emission_energy: float = 1.0
@export var volumetric_fog_length_m: float = 64.0
@export var volumetric_fog_detail_spread: float = 2.0
@export var volumetric_fog_gi_inject: float = 1.0
@export var volumetric_fog_sky_affect: float = 1.0

# --- Directional sun ------------------------------------------------------

@export var sun_enabled: bool = true
@export var sun_color: Color = Color(1.0, 0.878, 0.690)
@export var sun_energy: float = 1.6
@export var sun_azimuth_degrees: float = -38.0
@export var sun_elevation_degrees: float = 46.0
@export var sun_angular_distance_degrees: float = 0.5
@export var sun_shadow_enabled: bool = true
@export var sun_shadow_opacity: float = 0.6
@export var sun_shadow_bias: float = 0.03
@export var sun_specular: float = 0.5

# --- Local lights ---------------------------------------------------------
#
# Each entry stores its native type, transform, projector, physical reach, soft
# shadow source size, and the Spot-only cone controls in one inspectable record.
@export var lights: Array[Dictionary] = []


## Numeric definitions drive the panel, reset, comparison, and JSON paths together.
const FIELDS: Array = [
	["ambient_energy", "Ambient energy", 0.0, 4.0, 0.01, SECTION_AMBIENT,
		"Strength of constant ambient fill when sky lighting is disabled or only partly contributes."],
	["tonemap_white", "Tonemap white", 0.5, 16.0, 0.05, SECTION_AMBIENT,
		"The luminance treated as pure white by the tonemapper."],

	["sky_energy_multiplier", "Sky energy", 0.0, 8.0, 0.01, SECTION_SKY,
		"Brightness of the procedural sky or panorama used for lighting and reflections."],
	["sky_rotation_degrees", "Sky rotation", -180.0, 180.0, 0.5, SECTION_SKY,
		"Horizontal rotation of the environment in degrees."],
	["sky_ambient_contribution", "Sky ambient contribution", 0.0, 1.0, 0.01, SECTION_SKY,
		"How much ambient light comes from the sky instead of the flat ambient colour."],

	["reflection_probe_intensity", "Probe intensity", 0.0, 8.0, 0.01, SECTION_REFLECTIONS,
		"Strength of the board-sized captured reflection."],
	["reflection_probe_padding_m", "Probe padding (m)", 0.0, 32.0, 0.1, SECTION_REFLECTIONS,
		"Extra metres added around the exact board bounds when sizing the probe."],
	["sdfgi_energy", "SDFGI energy", 0.0, 8.0, 0.01, SECTION_REFLECTIONS,
		"Strength of bounced light produced by SDFGI."],

	["ssao_radius", "SSAO radius", 0.01, 16.0, 0.01, SECTION_SCREEN,
		"Distance in metres over which placed geometry can create contact occlusion."],
	["ssao_intensity", "SSAO intensity", 0.0, 8.0, 0.01, SECTION_SCREEN,
		"Strength of screen-space contact occlusion."],
	["ssao_power", "SSAO power", 0.1, 8.0, 0.01, SECTION_SCREEN,
		"Response curve that controls how quickly SSAO becomes dark."],
	["ssao_detail", "SSAO detail", 0.0, 1.0, 0.01, SECTION_SCREEN,
		"Contribution of short-range high-frequency contact detail."],
	["material_ao_light_affect", "Material AO light affect", 0.0, 1.0, 0.01, SECTION_SCREEN,
		"How strongly texture AO darkens direct lighting; 0 affects only indirect light and 1 applies the full AO response."],
	["glow_intensity", "Glow intensity", 0.0, 8.0, 0.01, SECTION_SCREEN,
		"Strength of bloom around HDR-bright pixels and emission maps."],
	["glow_bloom", "Glow bloom", 0.0, 1.0, 0.01, SECTION_SCREEN,
		"Adds bloom to the whole image in addition to thresholded HDR glow."],
	["ssil_radius", "SSIL radius", 0.01, 32.0, 0.01, SECTION_SCREEN,
		"Distance over which visible pixels can contribute bounced diffuse light."],
	["ssil_intensity", "SSIL intensity", 0.0, 8.0, 0.01, SECTION_SCREEN,
		"Strength of screen-space indirect light."],
	["ssr_max_steps", "SSR steps", 8.0, 256.0, 1.0, SECTION_SCREEN,
		"Maximum ray steps used for screen-space reflections."],
	["ssr_fade_in", "SSR fade in", 0.0, 4.0, 0.01, SECTION_SCREEN,
		"Curve controlling the start of rough-surface reflection fading."],
	["ssr_fade_out", "SSR fade out", 0.0, 8.0, 0.01, SECTION_SCREEN,
		"Curve controlling the end of rough-surface reflection fading."],
	["ssr_depth_tolerance", "SSR depth tolerance", 0.01, 2.0, 0.01, SECTION_SCREEN,
		"Depth tolerance used when matching reflection rays to visible geometry."],

	["fog_density", "Fog density", 0.0, 1.0, 0.001, SECTION_FOG,
		"Global exponential fog density."],
	["fog_depth_begin_m", "Depth begin (m)", 0.0, 1000.0, 0.1, SECTION_FOG,
		"Camera distance where depth fog begins."],
	["fog_depth_end_m", "Depth end (m)", 0.1, 2000.0, 0.1, SECTION_FOG,
		"Camera distance where depth fog reaches full effect."],
	["fog_depth_curve", "Depth curve", 0.1, 8.0, 0.01, SECTION_FOG,
		"Response curve between the depth begin and end distances."],
	["fog_height_m", "Height cutoff (m)", -128.0, 256.0, 0.1, SECTION_FOG,
		"World height where height fog begins to thin."],
	["fog_height_density", "Height density", -8.0, 8.0, 0.01, SECTION_FOG,
		"Positive values concentrate fog below the cutoff; negative values concentrate it above."],
	["fog_sun_scatter", "Sun scatter", 0.0, 1.0, 0.01, SECTION_FOG,
		"Amount of directional sunlight scattered through ordinary fog."],
	["fog_aerial_perspective", "Aerial perspective", 0.0, 1.0, 0.01, SECTION_FOG,
		"Amount of sky colour mixed into distant ordinary fog."],
	["volumetric_fog_density", "Volumetric density", 0.0, 1.0, 0.001, SECTION_FOG,
		"Global participating-media density for volumetric fog and light shafts."],
	["volumetric_fog_emission_energy", "Volume emission energy", 0.0, 16.0, 0.01, SECTION_FOG,
		"Brightness of light emitted by the volumetric medium itself."],
	["volumetric_fog_length_m", "Volume length (m)", 1.0, 512.0, 0.5, SECTION_FOG,
		"Camera range over which volumetric fog is computed."],
	["volumetric_fog_detail_spread", "Volume detail spread", 0.5, 6.0, 0.01, SECTION_FOG,
		"Distribution of detail across the volumetric fog buffer."],
	["volumetric_fog_gi_inject", "Volume GI inject", 0.0, 16.0, 0.01, SECTION_FOG,
		"Strength of SDFGI injected into volumetric fog."],
	["volumetric_fog_sky_affect", "Volume sky affect", 0.0, 1.0, 0.01, SECTION_FOG,
		"How strongly volumetric fog obscures the visible sky."],

	["sun_energy", "Sun energy", 0.0, 12.0, 0.01, SECTION_SUN,
		"Brightness of the key directional light."],
	["sun_azimuth_degrees", "Sun azimuth", -180.0, 180.0, 0.5, SECTION_SUN,
		"Compass direction the sun comes from, in degrees."],
	["sun_elevation_degrees", "Sun elevation", 1.0, 89.0, 0.5, SECTION_SUN,
		"Height of the sun above the horizon."],
	["sun_angular_distance_degrees", "Sun angular size", 0.0, 10.0, 0.01, SECTION_SUN,
		"Angular diameter of the light source; larger values create softer contact-hardening shadows."],
	["sun_shadow_opacity", "Shadow strength", 0.0, 1.0, 0.01, SECTION_SUN,
		"How dark the cast shadows are."],
	["sun_shadow_bias", "Shadow bias", 0.001, 0.5, 0.001, SECTION_SUN,
		"Offsets shadows off their caster."],
	["sun_specular", "Sun specular", 0.0, 2.0, 0.01, SECTION_SUN,
		"Strength of the specular highlight from the key light."],
]

## Colour definitions use the same section routing as numeric fields.
const COLOR_FIELDS: Array = [
	["background_color", "Visible background", SECTION_AMBIENT, "Solid colour shown when the sky background is hidden."],
	["ambient_color", "Ambient colour", SECTION_AMBIENT, "Colour of constant ambient fill."],
	["sky_top_color", "Sky top", SECTION_SKY, "Procedural sky colour overhead."],
	["sky_horizon_color", "Sky horizon", SECTION_SKY, "Procedural sky colour at the horizon."],
	["ground_bottom_color", "Ground bottom", SECTION_SKY, "Procedural sky ground colour below the board."],
	["ground_horizon_color", "Ground horizon", SECTION_SKY, "Procedural ground colour at the horizon."],
	["fog_color", "Fog colour", SECTION_FOG, "Colour of ordinary depth and height fog."],
	["volumetric_fog_albedo", "Volume albedo", SECTION_FOG, "Colour of light scattered by volumetric fog."],
	["volumetric_fog_emission", "Volume emission", SECTION_FOG, "Colour emitted by the volumetric medium."],
	["sun_color", "Sun colour", SECTION_SUN, "Colour of the key directional light."],
]

## Toggle definitions keep every native feature visible rather than relying on hidden project state.
const TOGGLE_FIELDS: Array = [
	["sky_enabled", "Sky / image lighting", SECTION_SKY, "Enable a Sky resource for ambient light and reflections."],
	["show_sky_background", "Show sky background", SECTION_SKY, "Show the sky behind the board; disable to retain the solid background while still using sky lighting."],
	["reflection_probe_enabled", "Board reflection probe", SECTION_REFLECTIONS, "Capture the current board for local reflections."],
	["reflection_probe_box_projection", "Probe box projection", SECTION_REFLECTIONS, "Correct parallax inside the board-sized box."],
	["reflection_probe_shadows", "Probe shadows", SECTION_REFLECTIONS, "Include shadowed lighting in the reflection capture."],
	["sdfgi_enabled", "SDFGI", SECTION_REFLECTIONS, "Enable real-time bounced light for generated geometry."],
	["sdfgi_use_occlusion", "SDFGI occlusion", SECTION_REFLECTIONS, "Reduce light leaking through nearby geometry."],
	["sdfgi_read_sky_light", "SDFGI reads sky", SECTION_REFLECTIONS, "Allow the active sky to illuminate SDFGI probes."],
	["ssao_enabled", "SSAO", SECTION_SCREEN, "Enable contact occlusion between placed objects."],
	["glow_enabled", "Glow", SECTION_SCREEN, "Bloom HDR-bright pixels and emission maps."],
	["ssil_enabled", "SSIL", SECTION_SCREEN, "Enable screen-space bounced diffuse light."],
	["ssr_enabled", "SSR", SECTION_SCREEN, "Enable screen-space reflections for visible opaque geometry."],
	["fog_enabled", "Depth and height fog", SECTION_FOG, "Enable ordinary camera-depth and world-height fog."],
	["volumetric_fog_enabled", "Volumetric fog", SECTION_FOG, "Enable participating media, light shafts, and FogVolume support."],
	["sun_enabled", "Sun enabled", SECTION_SUN, "Turn the key directional light on or off."],
	["sun_shadow_enabled", "Sun shadows", SECTION_SUN, "Enable cast shadows from the key light."],
]

const TONEMAP_NAMES: Array = ["Linear", "Reinhardt", "Filmic", "ACES", "AgX"]
const SKY_MODE_NAMES: Array = ["Procedural", "Panorama / HDRI"]
const LOCAL_LIGHT_TYPE_NAMES: Array = ["Omni", "Spot"]


## Return a new shipped-default profile.
static func defaults() -> LightingProfile:
	return LightingProfile.new()


## Replace this profile with the shipped defaults.
func reset_to_defaults() -> void:
	_copy_from(defaults())


## Reset one visible menu section without disturbing the others.
func reset_section(section: String) -> void:
	var fresh := defaults()
	for definition in FIELDS:
		if String(definition[5]) == section:
			set(String(definition[0]), fresh.get(String(definition[0])))
	for definition in COLOR_FIELDS:
		if String(definition[2]) == section:
			set(String(definition[0]), fresh.get(String(definition[0])))
	for definition in TOGGLE_FIELDS:
		if String(definition[2]) == section:
			set(String(definition[0]), fresh.get(String(definition[0])))
	if section == SECTION_AMBIENT:
		tonemap_mode = fresh.tonemap_mode
	if section == SECTION_SKY:
		sky_mode = fresh.sky_mode
		sky_panorama_path = fresh.sky_panorama_path


## Remove every authored local light from this profile.
func reset_lights() -> void:
	lights.clear()


## Copy every authored field from another profile into this resource.
func _copy_from(other: LightingProfile) -> void:
	for definition in FIELDS:
		set(String(definition[0]), other.get(String(definition[0])))
	for definition in COLOR_FIELDS:
		set(String(definition[0]), other.get(String(definition[0])))
	for definition in TOGGLE_FIELDS:
		set(String(definition[0]), other.get(String(definition[0])))
	tonemap_mode = other.tonemap_mode
	sky_mode = other.sky_mode
	sky_panorama_path = other.sky_panorama_path
	lights.clear()
	for light in other.lights:
		lights.append(light.duplicate(true))


## Create an independent copy suitable for undo snapshots.
func duplicate_profile() -> LightingProfile:
	var copy := LightingProfile.new()
	copy._copy_from(self)
	return copy


## Return whether every stored lighting value still equals the shipped defaults.
func is_default() -> bool:
	var fresh := defaults()
	if not lights.is_empty() or tonemap_mode != fresh.tonemap_mode:
		return false
	if sky_mode != fresh.sky_mode or sky_panorama_path != fresh.sky_panorama_path:
		return false
	for definition in FIELDS:
		if not is_equal_approx(float(get(String(definition[0]))), float(fresh.get(String(definition[0])))):
			return false
	for definition in COLOR_FIELDS:
		if get(String(definition[0])) != fresh.get(String(definition[0])):
			return false
	for definition in TOGGLE_FIELDS:
		if bool(get(String(definition[0]))) != bool(fresh.get(String(definition[0]))):
			return false
	return true


# --- Local lights ---------------------------------------------------------

const DEFAULT_LOCAL_LIGHT_HEIGHT_M: float = 0.0
const MAX_LOCAL_LIGHT_HEIGHT_M: float = 128.0

## Return one fully explicit local-light record anchored to authored surface geometry.
static func default_light(
	index: int,
	surface_position: Vector3 = Vector3.ZERO,
	height_offset: float = DEFAULT_LOCAL_LIGHT_HEIGHT_M
) -> Dictionary:
	return {
		"name": "Light %d" % (index + 1),
		"type": LocalLightType.OMNI,
		"enabled": true,
		"surface_position": surface_position,
		"height_offset": clampf(height_offset, 0.0, MAX_LOCAL_LIGHT_HEIGHT_M),
		"rotation_degrees": Vector3(-45.0, 0.0, 0.0),
		"projector_path": "",
		"color": Color(1.0, 0.753, 0.502),
		"intensity": 4.0,
		"radius": 8.0,
		"attenuation": 1.0,
		"shadow": 0.0,
		"light_size": 0.0,
		"spot_angle": 45.0,
		"spot_attenuation": 1.0,
	}


## Add a surface-anchored local light and return its index, or -1 at the documented limit.
func add_light(
	surface_position: Vector3,
	height_offset: float = DEFAULT_LOCAL_LIGHT_HEIGHT_M
) -> int:
	if lights.size() >= MAX_LIGHTS:
		return -1
	lights.append(default_light(lights.size(), surface_position, height_offset))
	return lights.size() - 1


## Derive the emitter's exact world position from its one surface anchor and height offset.
static func local_light_world_position(light: Dictionary) -> Vector3:
	var surface_position: Vector3 = light.get("surface_position", Vector3.ZERO)
	var height_offset := clampf(
		float(light.get("height_offset", 0.0)),
		0.0,
		MAX_LOCAL_LIGHT_HEIGHT_M
	)
	return surface_position + Vector3.UP * height_offset


## Append an independent copy of one authored light and return the new index.
func duplicate_light(index: int) -> int:
	if index < 0 or index >= lights.size() or lights.size() >= MAX_LIGHTS:
		return -1
	var copied_light: Dictionary = lights[index].duplicate(true)
	copied_light["name"] = "%s Copy" % String(copied_light.get("name", "Light"))
	lights.append(copied_light)
	return lights.size() - 1


## Remove one local light when the requested index exists.
func remove_light(index: int) -> void:
	if index >= 0 and index < lights.size():
		lights.remove_at(index)


## Convert authored sun-source bearing and elevation to Godot light Euler degrees.
func sun_rotation_degrees() -> Vector3:
	var ray_azimuth_degrees: float = 180.0 - sun_azimuth_degrees
	return Vector3(-sun_elevation_degrees, ray_azimuth_degrees, 0.0)


## Serialize every visible profile field without quantizing colours.
func to_json() -> Dictionary:
	var data: Dictionary = {}
	for definition in FIELDS:
		data[String(definition[0])] = float(get(String(definition[0])))
	for definition in COLOR_FIELDS:
		data[String(definition[0])] = color_to_json(get(String(definition[0])))
	for definition in TOGGLE_FIELDS:
		data[String(definition[0])] = bool(get(String(definition[0])))
	data["tonemap_mode"] = tonemap_mode
	data["sky_mode"] = sky_mode
	data["sky_panorama_path"] = sky_panorama_path
	var light_list: Array = []
	for light in lights:
		var surface_position: Vector3 = light.get("surface_position", Vector3.ZERO)
		var height_offset := clampf(
			float(light.get("height_offset", 0.0)),
			0.0,
			MAX_LOCAL_LIGHT_HEIGHT_M
		)
		var rotation: Vector3 = light.get("rotation_degrees", Vector3.ZERO)
		var color: Color = light.get("color", Color.WHITE)
		light_list.append({
			"name": String(light.get("name", "Light")),
			"type": int(light.get("type", LocalLightType.OMNI)),
			"enabled": bool(light.get("enabled", true)),
			"surface_position": [surface_position.x, surface_position.y, surface_position.z],
			"height_offset": height_offset,
			"rotation_degrees": [rotation.x, rotation.y, rotation.z],
			"projector_path": String(light.get("projector_path", "")),
			"color": color_to_json(color),
			"intensity": float(light.get("intensity", 4.0)),
			"radius": float(light.get("radius", 8.0)),
			"attenuation": float(light.get("attenuation", 1.0)),
			"shadow": float(light.get("shadow", 0.0)),
			"light_size": float(light.get("light_size", 0.0)),
			"spot_angle": float(light.get("spot_angle", 45.0)),
			"spot_attenuation": float(light.get("spot_attenuation", 1.0)),
		})
	data["lights"] = light_list
	return data


## Load a profile while retaining shipped defaults for fields absent from older boards.
func from_json(data: Dictionary) -> void:
	reset_to_defaults()
	for definition in FIELDS:
		var key := String(definition[0])
		if data.has(key):
			set(key, clampf(float(data[key]), float(definition[2]), float(definition[3])))
	for definition in COLOR_FIELDS:
		var color_key := String(definition[0])
		if data.has(color_key):
			set(color_key, color_from_json(data[color_key], get(color_key)))
	for definition in TOGGLE_FIELDS:
		var toggle_key := String(definition[0])
		if data.has(toggle_key):
			set(toggle_key, bool(data[toggle_key]))
	if data.has("tonemap_mode"):
		tonemap_mode = clampi(int(data["tonemap_mode"]), 0, TONEMAP_NAMES.size() - 1)
	if data.has("sky_mode"):
		sky_mode = clampi(int(data["sky_mode"]), 0, SKY_MODE_NAMES.size() - 1)
	sky_panorama_path = String(data.get("sky_panorama_path", ""))

	lights.clear()
	for entry: Variant in data.get("lights", []):
		if not (entry is Dictionary) or lights.size() >= MAX_LIGHTS:
			continue
		var raw: Dictionary = entry
		var surface_position: Vector3
		var height_offset: float
		if raw.has("surface_position"):
			surface_position = _vector3_from_json(raw["surface_position"], Vector3.ZERO)
			height_offset = clampf(
				float(raw.get("height_offset", 0.0)),
				0.0,
				MAX_LOCAL_LIGHT_HEIGHT_M
			)
		else:
			# Boards written before surface anchoring are migrated once by preserving
			# their exact emitter position as a zero-height surface anchor.
			surface_position = _vector3_from_json(raw.get("position", []), Vector3.ZERO)
			height_offset = 0.0
		var rotation := _vector3_from_json(raw.get("rotation_degrees", []), Vector3(-45.0, 0.0, 0.0))
		lights.append({
			"name": String(raw.get("name", "Light %d" % (lights.size() + 1))),
			"type": clampi(int(raw.get("type", LocalLightType.OMNI)), LocalLightType.OMNI, LocalLightType.SPOT),
			"enabled": bool(raw.get("enabled", true)),
			"surface_position": surface_position,
			"height_offset": height_offset,
			"rotation_degrees": rotation,
			"projector_path": String(raw.get("projector_path", "")),
			"color": color_from_json(raw.get("color", null), Color(1.0, 0.753, 0.502)),
			"intensity": float(raw.get("intensity", 4.0)),
			"radius": float(raw.get("radius", 8.0)),
			"attenuation": float(raw.get("attenuation", 1.0)),
			"shadow": float(raw.get("shadow", 0.0)),
			"light_size": float(raw.get("light_size", 0.0)),
			"spot_angle": float(raw.get("spot_angle", 45.0)),
			"spot_attenuation": float(raw.get("spot_attenuation", 1.0)),
		})


## Convert a JSON number triple into a Vector3 while preserving an explicit fallback.
static func _vector3_from_json(value: Variant, fallback: Vector3) -> Vector3:
	if not (value is Array):
		return fallback
	var parts: Array = value
	if parts.size() < 3:
		return fallback
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


## Store colour channels as floats so a board save never introduces 8-bit quantization.
static func color_to_json(color: Color) -> Array:
	return [color.r, color.g, color.b]


## Read current float triples and legacy hex strings used by older boards.
static func color_from_json(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts: Array = value
		return Color(float(parts[0]), float(parts[1]), float(parts[2]))
	if value is String:
		return Color.from_string(String(value), fallback)
	return fallback


## Build the exact Sky resource this profile selects, without substituting another source.
##
## Returns null and reports when the authored source cannot be produced, so a missing
## panorama stays visible as a missing panorama rather than silently becoming a
## procedural sky.
func create_sky() -> Sky:
	var sky := Sky.new()
	match sky_mode:
		SkyMode.PROCEDURAL:
			var procedural := ProceduralSkyMaterial.new()
			procedural.sky_top_color = sky_top_color
			procedural.sky_horizon_color = sky_horizon_color
			procedural.ground_bottom_color = ground_bottom_color
			procedural.ground_horizon_color = ground_horizon_color
			sky.sky_material = procedural
		SkyMode.PANORAMA:
			if sky_panorama_path.is_empty():
				push_error("[Tile Studio] Panorama sky is enabled but no panorama path is authored.")
				return null
			var panorama := load(sky_panorama_path) as Texture2D
			if panorama == null:
				push_error("[Tile Studio] Panorama sky texture could not be loaded: %s" % sky_panorama_path)
				return null
			var panoramic := PanoramaSkyMaterial.new()
			panoramic.panorama = panorama
			sky.sky_material = panoramic
		_:
			push_error("[Tile Studio] Unknown sky mode %d." % sky_mode)
			return null
	return sky


## Write every authored environment value onto one Environment.
##
## This is the single mapping from authored lighting to Godot's Environment, shared by the
## editor preview and the runtime game. It lives on the profile rather than in either
## consumer so the played level's atmosphere cannot drift from the authored one.
func apply_to_environment(env: Environment) -> void:
	if env == null:
		return
	env.background_color = background_color
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = tonemap_mode as Environment.ToneMapper
	env.tonemap_white = tonemap_white
	# Sky lighting and sky visibility are separate authored choices. The resource stays
	# available for lighting and reflections even behind a solid background colour.
	env.sky = create_sky() if sky_enabled else null
	env.background_mode = (
		Environment.BG_SKY
		if sky_enabled and show_sky_background
		else Environment.BG_COLOR
	)
	env.background_energy_multiplier = sky_energy_multiplier
	env.sky_rotation = Vector3(0.0, deg_to_rad(sky_rotation_degrees), 0.0)
	env.ambient_light_source = (
		Environment.AMBIENT_SOURCE_SKY if sky_enabled else Environment.AMBIENT_SOURCE_COLOR
	)
	env.ambient_light_sky_contribution = sky_ambient_contribution if sky_enabled else 0.0
	env.reflected_light_source = (
		Environment.REFLECTION_SOURCE_SKY if sky_enabled else Environment.REFLECTION_SOURCE_DISABLED
	)

	# Screen-space and GI switches directly mirror their profile values.
	env.ssao_enabled = ssao_enabled
	env.ssao_radius = ssao_radius
	env.ssao_intensity = ssao_intensity
	env.ssao_power = ssao_power
	env.ssao_detail = ssao_detail
	env.glow_enabled = glow_enabled
	env.glow_intensity = glow_intensity
	env.glow_bloom = glow_bloom
	env.ssil_enabled = ssil_enabled
	env.ssil_radius = ssil_radius
	env.ssil_intensity = ssil_intensity
	env.ssr_enabled = ssr_enabled
	env.ssr_max_steps = int(ssr_max_steps)
	env.ssr_fade_in = ssr_fade_in
	env.ssr_fade_out = ssr_fade_out
	env.ssr_depth_tolerance = ssr_depth_tolerance
	env.sdfgi_enabled = sdfgi_enabled
	env.sdfgi_energy = sdfgi_energy
	env.sdfgi_use_occlusion = sdfgi_use_occlusion
	env.sdfgi_read_sky_light = sdfgi_read_sky_light

	# Ordinary fog combines depth and height inside one Environment contract.
	env.fog_enabled = fog_enabled
	env.fog_light_color = fog_color
	env.fog_density = fog_density
	env.fog_depth_begin = fog_depth_begin_m
	env.fog_depth_end = fog_depth_end_m
	env.fog_depth_curve = fog_depth_curve
	env.fog_height = fog_height_m
	env.fog_height_density = fog_height_density
	env.fog_sun_scatter = fog_sun_scatter
	env.fog_aerial_perspective = fog_aerial_perspective

	# Volumetric fog is separately visible because it is a Forward+ effect and also
	# activates light shafts and FogVolume participation.
	env.volumetric_fog_enabled = volumetric_fog_enabled
	env.volumetric_fog_density = volumetric_fog_density
	env.volumetric_fog_albedo = volumetric_fog_albedo
	env.volumetric_fog_emission = volumetric_fog_emission
	env.volumetric_fog_emission_energy = volumetric_fog_emission_energy
	env.volumetric_fog_length = volumetric_fog_length_m
	env.volumetric_fog_detail_spread = volumetric_fog_detail_spread
	env.volumetric_fog_gi_inject = volumetric_fog_gi_inject
	env.volumetric_fog_sky_affect = volumetric_fog_sky_affect


## Write the authored sun onto one directional key light.
func apply_to_sun(key_light: DirectionalLight3D) -> void:
	if key_light == null:
		return
	key_light.visible = sun_enabled
	key_light.light_energy = sun_energy
	key_light.light_color = sun_color
	key_light.light_specular = sun_specular
	# Azimuth/elevation, not raw Euler: this profile owns the conversion so the panel and
	# any runtime consumer derive the same direction.
	key_light.rotation_degrees = sun_rotation_degrees()
	key_light.shadow_enabled = sun_shadow_enabled
	key_light.shadow_opacity = sun_shadow_opacity
	key_light.shadow_bias = sun_shadow_bias
	# Terrain is rendered as adjacent affine triangle instances. Reversing the directional
	# shadow cull face prevents each triangle from shadowing its coplanar neighbour while
	# preserving the terrain and GLB cast shadows.
	key_light.shadow_reverse_cull_face = true
	key_light.light_angular_distance = sun_angular_distance_degrees


## Build one Light3D per enabled authored local light, in authored order.
##
## The caller owns parenting. Each light carries its authored index so an editor handle or
## a runtime effect can map a node back to the entry that produced it.
func build_local_lights() -> Array[Light3D]:
	var built: Array[Light3D] = []
	for light_index: int in lights.size():
		var entry: Dictionary = lights[light_index]
		if not bool(entry.get("enabled", true)):
			continue
		var light: Light3D
		var light_type := int(entry.get("type", LocalLightType.OMNI))
		match light_type:
			LocalLightType.OMNI:
				var omni := OmniLight3D.new()
				omni.omni_range = float(entry.get("radius", 8.0))
				omni.omni_attenuation = float(entry.get("attenuation", 1.0))
				light = omni
			LocalLightType.SPOT:
				var spot := SpotLight3D.new()
				spot.spot_range = float(entry.get("radius", 8.0))
				spot.spot_attenuation = float(entry.get("attenuation", 1.0))
				spot.spot_angle = float(entry.get("spot_angle", 45.0))
				spot.spot_angle_attenuation = float(entry.get("spot_attenuation", 1.0))
				spot.rotation_degrees = entry.get("rotation_degrees", Vector3(-45.0, 0.0, 0.0))
				light = spot
			_:
				push_error(
					"[Tile Studio] Local light '%s' has unknown type %d."
					% [String(entry.get("name", "Light")), light_type]
				)
				continue
		light.name = String(entry.get("name", "Light"))
		light.position = LightingProfile.local_light_world_position(entry)
		light.light_color = entry.get("color", Color.WHITE)
		light.light_energy = float(entry.get("intensity", 4.0))
		light.light_size = float(entry.get("light_size", 0.0))
		# A shadow value of 0 is an explicit shadowless fill light.
		var shadow := float(entry.get("shadow", 0.0))
		light.shadow_enabled = shadow > 0.0
		light.shadow_opacity = shadow
		var projector_path := String(entry.get("projector_path", ""))
		if not projector_path.is_empty():
			var projector := load(projector_path) as Texture2D
			if projector == null:
				push_error("[Tile Studio] Light projector texture could not be loaded: %s" % projector_path)
			else:
				light.light_projector = projector
		light.set_meta("mts_light_index", light_index)
		built.append(light)
	return built
