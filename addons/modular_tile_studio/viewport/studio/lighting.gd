@tool
extends RefCounted

## Lighting behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Enable or disable the editor-only uniform light used while painting obscured faces.
##
## Reapplying both lighting and grade makes the switch reversible from the board's
## canonical profiles without storing a backup copy or mutating authored data.
static func set_painting_light_override_enabled(host: MTSStudioViewport, enabled: bool) -> void:
	if host._painting_light_override_enabled == enabled:
		return
	host._painting_light_override_enabled = enabled
	host.apply_lighting_profile()
	host.apply_grade()
	host.request_render()


## Apply neutral ambient illumination and disable every effect that can darken a face.
##
## Ambient light has no direction, so all building sides remain readable without a
## camera-relative light or a hidden azimuth correction. Direct lights are hidden,
## which guarantees this comfort preview cannot cast dynamic shadows.
static func _apply_painting_light_override(host: MTSStudioViewport) -> void:
	if host.world_environment != null and host.world_environment.environment != null:
		var env := host.world_environment.environment
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color.WHITE
		env.ambient_light_energy = 1.0
		env.ambient_light_sky_contribution = 0.0
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
		env.sdfgi_enabled = false
		env.ssao_enabled = false
		env.ssil_enabled = false
		env.ssr_enabled = false
		env.glow_enabled = false
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.tonemap_exposure = 1.0
		env.adjustment_enabled = false
	if host.key_light != null:
		host.key_light.visible = false
	if host.lights_root != null:
		host.lights_root.visible = false
	if host.reflection_probe != null:
		host.reflection_probe.visible = false


## Apply the board's lighting profile to the live rig.
##
## Called whenever the board emits look_changed, which the Look panel triggers on
## every knob move, so the viewport is always showing exactly what is saved.
## The temporary painting override is editor comfort state; every authored value
## remains on the document and is reapplied verbatim when that override is off.
static func apply_lighting_profile(host: MTSStudioViewport) -> void:
	var profile := host._profile()
	if profile == null:
		return

	# The authored-value mapping lives on LightingProfile so the editor preview and the
	# runtime game apply identical lighting from one place.
	if host.world_environment != null:
		profile.apply_to_environment(host.world_environment.environment)
	profile.apply_to_sun(host.key_light)

	if host._painting_light_override_enabled:
		host._apply_painting_light_override()
		host._sync_light_handles_from_profile()
		return

	if not host._defer_reflection_probe_rebuild:
		host._rebuild_reflection_probe(profile)
	host._rebuild_local_lights(profile)
	if host.lights_root != null:
		host.lights_root.visible = true
	if host.reflection_probe != null:
		host.reflection_probe.visible = true
	host._sync_light_handles_from_profile()


## Keep one UPDATE_ONCE ReflectionProbe synchronized to exact board bounds.
##
## Ordinary mutations update the existing probe in place. Recreating the node
## would force an unrelated reflection capture and SceneTree churn on every drag.
static func _rebuild_reflection_probe(host: MTSStudioViewport, profile: LightingProfile) -> void:
	var should_exist := (
		profile != null
		and profile.reflection_probe_enabled
		and host.board != null
		and not host.board.is_empty()
	)
	if not should_exist:
		if host.reflection_probe != null:
			if host.reflection_probe.get_parent() != null:
				host.reflection_probe.get_parent().remove_child(host.reflection_probe)
			host.reflection_probe.queue_free()
			host.reflection_probe = null
		if (
			profile != null
			and profile.reflection_probe_enabled
			and host.board != null
			and host.board.is_empty()
		):
			push_warning(
				"[Tile Studio] Reflection probe is enabled but the current board has no geometry to bound."
			)
		return

	var bounds := host._board_bounds()
	var padding := maxf(0.0, profile.reflection_probe_padding_m)
	var probe_size := bounds.size + Vector3.ONE * padding * 2.0
	probe_size.x = maxf(probe_size.x, 0.1)
	probe_size.y = maxf(probe_size.y, 0.1)
	probe_size.z = maxf(probe_size.z, 0.1)
	if host.reflection_probe == null:
		host.reflection_probe = ReflectionProbe.new()
		host.reflection_probe.name = "BoardReflectionProbe"
		host.reflection_probe.update_mode = ReflectionProbe.UPDATE_ONCE
		host.world_root.add_child(host.reflection_probe)
	host.reflection_probe.position = bounds.get_center()
	host.reflection_probe.size = probe_size
	host.reflection_probe.intensity = profile.reflection_probe_intensity
	host.reflection_probe.box_projection = profile.reflection_probe_box_projection
	host.reflection_probe.enable_shadows = profile.reflection_probe_shadows


## Local lights are rebuilt from the profile so node type and projector cannot leave stale state.
##
## Ported from the Blackledger runtime, which fed up to eight lights into a
## shader uniform array. Here they become real OmniLight3D nodes, so they light
## props and surfaces through the same path as the key light and cast real
## shadows. Rebuilding rather than diffing keeps this honest: at eight lights the
## cost is nil, and there is no stale-node class of bug.
static func _rebuild_local_lights(host: MTSStudioViewport, profile: LightingProfile) -> void:
	if host.lights_root == null:
		return
	for child in host.lights_root.get_children():
		host.lights_root.remove_child(child)
		child.queue_free()
	# LightingProfile builds the nodes so the editor and the runtime game produce
	# identical lights from one authored entry list.
	for light: Light3D in profile.build_local_lights():
		host.lights_root.add_child(light)
