@tool
class_name LightingPanel
extends LookPanelBase

## Lighting for the board being worked on.
##
## Ported from the Blackledger Professional Plate Runtime lighting dock: ambient
## and tonemap, a directional key light described in azimuth/elevation with its
## own shadow controls, and up to eight named local lights with position,
## colour, intensity, radius, falloff and per-light shadow strength. Each light
## stores one geometry surface anchor plus one world-height offset.
##
## That project drove an eight-light shader uniform array; here the same rig
## drives real Godot lights, and is keyed to the BOARD rather than a level
## folder so it saves, loads and resets with everything else the board owns.
##
## Rendering owns GPU surface effects. This panel owns scene lighting and final colour grade.

## Emitted when the selector or a viewport handle chooses one authored local light.
signal local_light_selected(index: int)
## Emitted when New enters the viewport's explicit surface-pick placement mode.
signal local_light_create_requested()
## Emitted when the temporary uniform painting-light preview is toggled.
signal painting_light_override_changed(enabled: bool)

# Local-light editor widgets, rebuilt with the panel.
var _light_selector: OptionButton
var _light_fields: Dictionary = {}
var _selected_light: int = 0
## The comfort preview is session-only UI state and is never copied into the board profile.
var _painting_light_override_enabled: bool = false


## Rebuild every control from the currently bound board lighting profile.
func rebuild() -> void:
	_clear_body()
	_light_fields.clear()
	_light_selector = null
	if board == null:
		_update_status()
		return
	var profile := board.lighting

	_toggle(
		_body,
		"Uniform painting light (temporary)",
		_painting_light_override_enabled,
		"Use neutral light from every direction with no shadows while painting. This preview is never saved.",
		func(enabled: bool) -> void:
			_painting_light_override_enabled = enabled
			painting_light_override_changed.emit(enabled)
			_update_status()
	)
	_note(
		_body,
		"Comfort preview only: authored lighting remains unchanged and returns when this is turned off."
	)

	_reset_all_row(_body, "Reset all lighting", func() -> void:
		board.reset_lighting()
		_selected_light = 0
		rebuild()
		_changed())

	_section(_body, "Ambient and tonemap", func() -> void:
		profile.reset_section(LightingProfile.SECTION_AMBIENT)
		rebuild()
		_changed())
	_profile_fields(_body, profile, LightingProfile.SECTION_AMBIENT,
		LightingProfile.FIELDS, LightingProfile.COLOR_FIELDS, LightingProfile.TOGGLE_FIELDS)

	var tonemap := OptionButton.new()
	for tonemap_name: String in LightingProfile.TONEMAP_NAMES:
		tonemap.add_item(tonemap_name)
	tonemap.select(profile.tonemap_mode)
	tonemap.item_selected.connect(func(index: int) -> void:
		profile.tonemap_mode = index
		_changed())
	_labelled(_body, "Tonemap", tonemap,
		"Curve used to map high dynamic range down to the display.")

	_section(_body, "Sky / image lighting", func() -> void:
		profile.reset_section(LightingProfile.SECTION_SKY)
		rebuild()
		_changed())
	_profile_fields(_body, profile, LightingProfile.SECTION_SKY,
		LightingProfile.FIELDS, LightingProfile.COLOR_FIELDS, LightingProfile.TOGGLE_FIELDS)

	var sky_mode := OptionButton.new()
	for sky_mode_name: String in LightingProfile.SKY_MODE_NAMES:
		sky_mode.add_item(sky_mode_name)
	sky_mode.select(profile.sky_mode)
	sky_mode.item_selected.connect(func(index: int) -> void:
		profile.sky_mode = index
		rebuild()
		_changed())
	_labelled(_body, "Sky source", sky_mode,
		"Procedural uses the visible sky colours below; Panorama requires an imported Godot Texture2D path.")
	if profile.sky_mode == LightingProfile.SkyMode.PANORAMA:
		_text(_body, "Panorama path", profile.sky_panorama_path,
			"Imported project path such as res://environment/crypt.hdr. A missing path is reported and does not silently select another sky.",
			func(value: String) -> void:
				profile.sky_panorama_path = value.strip_edges()
				_changed())
	_note(_body, "The sky can light and reflect in the board even when Show sky background is off.")

	_section(_body, "Reflections and GI", func() -> void:
		profile.reset_section(LightingProfile.SECTION_REFLECTIONS)
		rebuild()
		_changed())
	_profile_fields(_body, profile, LightingProfile.SECTION_REFLECTIONS,
		LightingProfile.FIELDS, LightingProfile.COLOR_FIELDS, LightingProfile.TOGGLE_FIELDS)
	_note(_body, "The reflection probe is sized from the exact current board bounds plus the visible padding value. SDFGI requires Forward+.")

	_section(_body, "Screen-space lighting", func() -> void:
		profile.reset_section(LightingProfile.SECTION_SCREEN)
		rebuild()
		_changed())
	_profile_fields(_body, profile, LightingProfile.SECTION_SCREEN,
		LightingProfile.FIELDS, LightingProfile.COLOR_FIELDS, LightingProfile.TOGGLE_FIELDS)
	_note(_body, "SSAO adds placement contact, Glow uses HDR emission, SSIL adds visible-pixel bounce, and SSR reflects visible opaque geometry.")

	_section(_body, "Fog and atmosphere", func() -> void:
		profile.reset_section(LightingProfile.SECTION_FOG)
		rebuild()
		_changed())
	_profile_fields(_body, profile, LightingProfile.SECTION_FOG,
		LightingProfile.FIELDS, LightingProfile.COLOR_FIELDS, LightingProfile.TOGGLE_FIELDS)
	_note(_body, "Ordinary fog combines camera depth and world height. Volumetric fog enables light shafts and future local FogVolume emitters and requires Forward+.")

	_section(_body, "Key light", func() -> void:
		profile.reset_section(LightingProfile.SECTION_SUN)
		rebuild()
		_changed())
	_profile_fields(_body, profile, LightingProfile.SECTION_SUN,
		LightingProfile.FIELDS, LightingProfile.COLOR_FIELDS, LightingProfile.TOGGLE_FIELDS)

	var aesthetics := board.aesthetics
	_section(_body, "Final colour grade", func() -> void:
		aesthetics.reset_section(AestheticProfile.SECTION_GRADE)
		rebuild()
		_changed())
	_profile_fields(_body, aesthetics, AestheticProfile.SECTION_GRADE,
		AestheticProfile.FIELDS, AestheticProfile.COLOR_FIELDS, AestheticProfile.TOGGLE_FIELDS)
	_note(_body,
		"These controls grade the final composed board. Per-texture Tint and Tint strength live in the selected texture's GPU Surface settings.")

	_build_light_list(profile)
	local_light_selected.emit(
		_selected_light if not profile.lights.is_empty() else -1
	)
	_update_status()


## Summarize the temporary preview, current board lighting state, and local-light count.
func _update_status() -> void:
	if board == null:
		_status.text = "No board bound."
		return
	var preview_status := (
		"Uniform painting light ON (temporary, not saved)"
		if _painting_light_override_enabled
		else "Authored lighting preview"
	)
	_status.text = "%s   ·   Lighting: %s   ·   %d local light%s   ·   saved with the board." % [
		preview_status,
		"default" if board.lighting.is_default() else "customised",
		board.lighting.lights.size(),
		"" if board.lighting.lights.size() == 1 else "s",
	]


## Local lights. Ported from the Blackledger dock: a selector plus add/remove,
## with one editor bound to whichever light is selected, rather than eight
## expanded blocks nobody can scan.
func _build_light_list(profile: LightingProfile) -> void:
	_section(_body, "Local lights (max %d)" % LightingProfile.MAX_LIGHTS, func() -> void:
		profile.reset_lights()
		_selected_light = 0
		rebuild()
		_changed())

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(row)

	_light_selector = OptionButton.new()
	_light_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_light_selector.clip_text = true
	for light: Dictionary in profile.lights:
		_light_selector.add_item(String(light.get("name", "Light")))
	if _light_selector.item_count > 0:
		_selected_light = clampi(_selected_light, 0, _light_selector.item_count - 1)
		_light_selector.select(_selected_light)
	_light_selector.item_selected.connect(func(index: int) -> void:
		_selected_light = index
		_refresh_light_editor()
		local_light_selected.emit(index))
	row.add_child(_light_selector)

	var new_button := Button.new()
	new_button.text = "New"
	new_button.tooltip_text = "Create a light by clicking the authored terrain mesh in the viewport"
	new_button.pressed.connect(func() -> void:
		if profile.lights.size() >= LightingProfile.MAX_LIGHTS:
			_status.text = "This rig supports at most %d local lights." % LightingProfile.MAX_LIGHTS
			return
		local_light_create_requested.emit()
		_status.text = "Click the authored terrain mesh to anchor the new light.")
	row.add_child(new_button)

	var duplicate_button := Button.new()
	duplicate_button.text = "Duplicate"
	duplicate_button.tooltip_text = "Copy the selected light and all of its authored settings"
	duplicate_button.disabled = profile.lights.is_empty()
	duplicate_button.pressed.connect(func() -> void:
		var duplicate_index := profile.duplicate_light(_selected_light)
		if duplicate_index < 0:
			_status.text = "Select a light to copy; this rig supports at most %d." % LightingProfile.MAX_LIGHTS
			return
		_selected_light = duplicate_index
		rebuild()
		_changed())
	row.add_child(duplicate_button)

	var remove_button := Button.new()
	remove_button.text = "Delete"
	remove_button.tooltip_text = "Remove the selected light"
	remove_button.disabled = profile.lights.is_empty()
	remove_button.pressed.connect(func() -> void:
		profile.remove_light(_selected_light)
		_selected_light = maxi(0, _selected_light - 1)
		rebuild()
		_changed())
	row.add_child(remove_button)

	if profile.lights.is_empty():
		_note(_body, "No local lights. The key light and ambient fill are lighting the board on their own.")
		return

	_note(
		_body,
		"Drag the gold emitter smoothly across the map. With a light selected, Up/Down changes Height above surface by 0.10 m; the slider below edits the same value."
	)

	var light_type := OptionButton.new()
	for light_type_name: String in LightingProfile.LOCAL_LIGHT_TYPE_NAMES:
		light_type.add_item(light_type_name)
	light_type.item_selected.connect(func(index: int) -> void:
		_set_light("type", index)
		rebuild())
	_light_fields["type"] = light_type
	_labelled(_body, "Type", light_type,
		"Omni radiates in every direction. Spot uses the authored rotation and cone angle.")

	_light_fields["enabled"] = _toggle(_body, "Enabled", true,
		"Turn this light off without deleting it.",
		func(value: bool) -> void: _set_light("enabled", value))
	_light_fields["name"] = _text(_body, "Name", "",
		"Naming lights is how a rig stays readable once there are more than two.",
		func(value: String) -> void:
			_set_light("name", value)
			if _light_selector != null and _selected_light < _light_selector.item_count:
				_light_selector.set_item_text(_selected_light, value))
	_light_fields["color"] = _color(_body, "Colour", Color.WHITE,
		"Colour of this light.",
		func(value: Color) -> void: _set_light("color", value))
	_light_fields["surface_x"] = _read_only_surface_coordinate(
		"Surface X", -256.0, 256.0,
		"Exact world X of the geometry point under the light."
	)
	_light_fields["surface_y"] = _read_only_surface_coordinate(
		"Surface Y", -64.0, 128.0,
		"Exact world Y of the geometry point under the light."
	)
	_light_fields["surface_z"] = _read_only_surface_coordinate(
		"Surface Z", -256.0, 256.0,
		"Exact world Z of the geometry point under the light."
	)
	_light_fields["height_offset"] = _slider(
		_body,
		"Height above surface",
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M,
		0.01,
		LightingProfile.DEFAULT_LOCAL_LIGHT_HEIGHT_M,
		"World-height offset above the stored surface anchor.",
		func(value: float) -> void: _set_light("height_offset", value)
	)
	_light_fields["intensity"] = _slider(_body, "Intensity", 0.0, 32.0, 0.05, 4.0,
		"Brightness of this light.",
		func(value: float) -> void: _set_light("intensity", value))
	_light_fields["radius"] = _slider(_body, "Radius", 0.1, 128.0, 0.1, 8.0,
		"How far the light reaches, in metres.",
		func(value: float) -> void: _set_light("radius", value))
	_light_fields["attenuation"] = _slider(_body, "Falloff", 0.1, 8.0, 0.05, 1.0,
		"Curve of the falloff inside the radius. Higher concentrates light near the source.",
		func(value: float) -> void: _set_light("attenuation", value))
	_light_fields["shadow"] = _slider(_body, "Shadow strength", 0.0, 1.0, 0.01, 0.0,
		"0 makes this a pure fill light that casts no shadows of its own.",
		func(value: float) -> void: _set_light("shadow", value))
	_light_fields["light_size"] = _slider(_body, "Source size", 0.0, 16.0, 0.01, 0.0,
		"Physical source radius used for contact-hardening soft shadows.",
		func(value: float) -> void: _set_light("light_size", value))
	_light_fields["projector_path"] = _text(_body, "Projector path", "",
		"Optional imported Texture2D path projected by this light. A missing path is reported and leaves the projector empty.",
		func(value: String) -> void: _set_light("projector_path", value.strip_edges()))
	_light_fields["rotation_x"] = _slider(_body, "Spot pitch", -180.0, 180.0, 0.5, -45.0,
		"Spot-only X rotation in degrees.",
		func(value: float) -> void: _set_light_rotation_axis(0, value))
	_light_fields["rotation_y"] = _slider(_body, "Spot yaw", -180.0, 180.0, 0.5, 0.0,
		"Spot-only Y rotation in degrees.",
		func(value: float) -> void: _set_light_rotation_axis(1, value))
	_light_fields["rotation_z"] = _slider(_body, "Spot roll", -180.0, 180.0, 0.5, 0.0,
		"Spot-only Z rotation in degrees.",
		func(value: float) -> void: _set_light_rotation_axis(2, value))
	_light_fields["spot_angle"] = _slider(_body, "Spot angle", 1.0, 89.0, 0.5, 45.0,
		"Spot-only outer cone angle in degrees.",
		func(value: float) -> void: _set_light("spot_angle", value))
	_light_fields["spot_attenuation"] = _slider(_body, "Spot cone falloff", 0.0, 8.0, 0.05, 1.0,
		"Spot-only falloff from the centre to the edge of the cone.",
		func(value: float) -> void: _set_light("spot_attenuation", value))

	_refresh_light_editor()


## Build a read-only coordinate row that displays the exact stored surface anchor.
func _read_only_surface_coordinate(
	label: String,
	minimum: float,
	maximum: float,
	tooltip: String
) -> HSlider:
	var slider := _slider(
		_body,
		label,
		minimum,
		maximum,
		0.01,
		0.0,
		tooltip,
		func(_value: float) -> void: pass
	)
	slider.editable = false
	slider.focus_mode = Control.FOCUS_NONE
	var exact := slider.get_meta("exact") as LineEdit
	if exact != null:
		exact.editable = false
		exact.focus_mode = Control.FOCUS_NONE
	return slider


## Refresh the selected local-light widgets from its authoritative dictionary.
func _refresh_light_editor() -> void:
	if board == null or _light_fields.is_empty():
		return
	var lights := board.lighting.lights
	if _selected_light < 0 or _selected_light >= lights.size():
		return
	var light: Dictionary = lights[_selected_light]
	var surface_position: Vector3 = light.get("surface_position", Vector3.ZERO)
	var rotation: Vector3 = light.get("rotation_degrees", Vector3(-45.0, 0.0, 0.0))

	_refreshing = true
	(_light_fields["type"] as OptionButton).select(int(light.get("type", LightingProfile.LocalLightType.OMNI)))
	(_light_fields["enabled"] as CheckBox).button_pressed = bool(light.get("enabled", true))
	(_light_fields["name"] as LineEdit).text = String(light.get("name", "Light"))
	(_light_fields["color"] as ColorPickerButton).color = light.get("color", Color.WHITE)
	_set_slider(_light_fields["surface_x"], surface_position.x)
	_set_slider(_light_fields["surface_y"], surface_position.y)
	_set_slider(_light_fields["surface_z"], surface_position.z)
	_set_slider(_light_fields["height_offset"], float(light.get("height_offset", 0.0)))
	_set_slider(_light_fields["intensity"], float(light.get("intensity", 4.0)))
	_set_slider(_light_fields["radius"], float(light.get("radius", 8.0)))
	_set_slider(_light_fields["attenuation"], float(light.get("attenuation", 1.0)))
	_set_slider(_light_fields["shadow"], float(light.get("shadow", 0.0)))
	_set_slider(_light_fields["light_size"], float(light.get("light_size", 0.0)))
	(_light_fields["projector_path"] as LineEdit).text = String(light.get("projector_path", ""))
	_set_slider(_light_fields["rotation_x"], rotation.x)
	_set_slider(_light_fields["rotation_y"], rotation.y)
	_set_slider(_light_fields["rotation_z"], rotation.z)
	_set_slider(_light_fields["spot_angle"], float(light.get("spot_angle", 45.0)))
	_set_slider(_light_fields["spot_attenuation"], float(light.get("spot_attenuation", 1.0)))
	_refreshing = false


## Select one local light from a viewport-handle click and refresh the same panel fields.
func select_local_light(index: int) -> void:
	if board == null or board.lighting.lights.is_empty():
		_selected_light = 0
		return
	_selected_light = clampi(index, 0, board.lighting.lights.size() - 1)
	if _light_selector == null or _light_selector.item_count != board.lighting.lights.size():
		rebuild()
		return
	_light_selector.select(_selected_light)
	_refresh_light_editor()


## Return the exact profile index currently represented by the local-light editor.
func selected_local_light() -> int:
	if board == null or board.lighting.lights.is_empty():
		return -1
	return clampi(_selected_light, 0, board.lighting.lights.size() - 1)


## Refresh the visible anchor and height controls during a viewport drag preview.
func refresh_local_light_transform(
	index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	if (
		index != _selected_light
		or _light_fields.is_empty()
		or not _light_fields.has("surface_x")
	):
		return
	_refreshing = true
	_set_slider(_light_fields["surface_x"], surface_position.x)
	_set_slider(_light_fields["surface_y"], surface_position.y)
	_set_slider(_light_fields["surface_z"], surface_position.z)
	_set_slider(_light_fields["height_offset"], height_offset)
	_refreshing = false


## Store one selected local-light field and immediately apply it to the board.
func _set_light(key: String, value: Variant) -> void:
	if _refreshing or board == null:
		return
	var lights := board.lighting.lights
	if _selected_light < 0 or _selected_light >= lights.size():
		return
	var light: Dictionary = lights[_selected_light]
	light[key] = value
	lights[_selected_light] = light
	_changed()


## Store one component of the selected Spot light's exact Euler rotation.
func _set_light_rotation_axis(axis: int, value: float) -> void:
	if _refreshing or board == null:
		return
	var lights := board.lighting.lights
	if _selected_light < 0 or _selected_light >= lights.size():
		return
	var light: Dictionary = lights[_selected_light]
	var rotation: Vector3 = light.get("rotation_degrees", Vector3(-45.0, 0.0, 0.0))
	rotation[axis] = value
	light["rotation_degrees"] = rotation
	lights[_selected_light] = light
	_changed()
