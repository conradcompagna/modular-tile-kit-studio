@tool
extends RefCounted

## Environment behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Build the native environment and light containers before a board profile is bound.
static func _build_environment(host: MTSStudioViewport) -> void:
	# The rig is built empty and then filled from the board's LightingProfile by
	# apply_lighting_profile(). Nothing about the look is hard-coded here: a
	# value that only existed in this function could never be tuned or reset.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.fog_mode = Environment.FOG_MODE_DEPTH

	host.world_environment = WorldEnvironment.new()
	host.world_environment.name = "WorldEnvironment"
	host.world_environment.environment = env
	host.world_root.add_child(host.world_environment)

	host.key_light = DirectionalLight3D.new()
	host.key_light.name = "KeyLight"
	host.world_root.add_child(host.key_light)

	# Local lights live under their own node so rebuilding them cannot disturb
	# the key light or anything else in the world.
	host.lights_root = Node3D.new()
	host.lights_root.name = "LocalLights"
	host.world_root.add_child(host.lights_root)

	# These transient globs mirror profile positions only while Lighting is open.
	# They never become board data and therefore cannot create a second source of truth.
	host.light_handles_root = Node3D.new()
	host.light_handles_root.name = "LocalLightHandles"
	host.light_handles_root.visible = false
	host.world_root.add_child(host.light_handles_root)

	# Defaults until a board is bound, so the viewport is never black on open.
	var startup := LightingProfile.defaults()
	env.background_color = startup.background_color
	env.ambient_light_color = startup.ambient_color
	env.ambient_light_energy = startup.ambient_energy
	env.tonemap_mode = startup.tonemap_mode as Environment.ToneMapper
	env.tonemap_white = startup.tonemap_white
	host.key_light.light_energy = startup.sun_energy
	host.key_light.light_color = startup.sun_color
	host.key_light.rotation_degrees = startup.sun_rotation_degrees()
