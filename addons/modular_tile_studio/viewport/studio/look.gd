@tool
extends RefCounted

## Look behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Re-apply only the renderer state owned by each changed look control.
##
## Shader-global controls remain uniform updates. Geometry, terrain supports and
## Apply document look notifications unless an atomic load already applied the same state.
static func _on_board_look_changed(host: MTSStudioViewport) -> void:
	if host._skip_next_look_apply:
		return
	host.apply_look()


## GLB buffers are touched only when their explicit input signatures change.
static func apply_look(host: MTSStudioViewport) -> void:
	host.apply_lighting_profile()
	host.apply_grade()

	var renderer_signature := host._current_renderer_settings_signature()
	var renderer_settings_changed := renderer_signature != host._renderer_settings_signature
	if host.material_factory != null:
		host.material_factory.aesthetics = host.board.aesthetics if host.board != null else null
		host.material_factory.world_fields = host.world_surface_fields
		host.material_factory.apply_global_effects(host.board.aesthetics if host.board != null else null)
		if renderer_settings_changed:
			host.material_factory.clear_cache()

	if renderer_settings_changed:
		host._apply_renderer_settings_to_existing_geometry()
		host._renderer_settings_signature = renderer_signature

	host.request_render()


## The colour grade, applied to the whole viewport rather than per material.
##
## Ported from Plate Level Studio's grade_color(), which ran as shader uniforms
## on its single plate. Here the board is many materials, so grading each one
## would both multiply the work and produce seams where a tile happened to miss
## a channel. Godot's Environment adjustment stack grades the composed image
## instead, which is what the plate shader was approximating in the first place.
##
## Exposure sits on tonemap_exposure, before the tonemapper, so it behaves as a
## real exposure rather than a post multiply. Shadow lift and highlight
## compression have no direct Environment control, so they are expressed through
## the adjustment colour-correction ramp built below.
static func apply_grade(host: MTSStudioViewport) -> void:
	if host.world_environment == null or host.world_environment.environment == null or host.board == null:
		return
	var look := host.board.aesthetics
	var env := host.world_environment.environment
	if host._painting_light_override_enabled:
		env.tonemap_exposure = 1.0
		env.adjustment_enabled = false
		return

	env.tonemap_exposure = maxf(look.exposure, 0.0)
	env.adjustment_enabled = true
	env.adjustment_contrast = look.contrast
	env.adjustment_saturation = look.saturation
	env.adjustment_brightness = 1.0
	env.adjustment_color_correction = host._grade_ramp(look)


## A 1D colour-correction ramp encoding shadow lift and highlight compression.
##
## Both are curve shapes, not scalars, so there is no Environment property that
## expresses them; a gradient texture is the mechanism Godot provides for
## exactly this. Rebuilt only when the grade changes, never per frame.
static func _grade_ramp(host: MTSStudioViewport, look: AestheticProfile) -> GradientTexture1D:
	# A neutral grade needs no lookup at all, and skipping it avoids paying for
	# a texture fetch on every fragment of an untouched board.
	if is_zero_approx(look.shadow_lift) and is_zero_approx(look.highlight_compression):
		return null

	const STEPS := 32
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for step in STEPS:
		var x := float(step) / float(STEPS - 1)
		# Shadow lift: blend toward sqrt, which raises darks far more than
		# lights, for a flatter painterly base. Same curve the plate shader used.
		var value: float = lerpf(x, sqrt(x), clampf(look.shadow_lift, 0.0, 1.0))
		# Highlight compression: a Reinhard roll-off, so bright values converge
		# instead of clipping.
		value = value / (1.0 + value * maxf(look.highlight_compression, 0.0))
		offsets.append(x)
		colors.append(Color(value, value, value))

	# Assigned wholesale rather than built with add_point(): a Gradient is seeded
	# with stops at offset 0 and 1, which add_point() would collide with at
	# exactly the two ends of this ramp.
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors

	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	texture.width = 256
	return texture
