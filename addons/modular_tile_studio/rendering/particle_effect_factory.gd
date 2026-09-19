@tool
class_name ParticleEffectFactory
extends RefCounted

## Builds the one native GPUParticles3D presentation used by every custom preset.
##
## Presets own every artist-facing value; the only derived values are Godot's
## required emission half-extents and a conservative visibility box.

## Build one emitter root at the placement's exact authored board-space position.
func build_emitter(
	preset: ParticleEffectPreset,
	placement: ParticleEffectPlacement
) -> Node3D:
	if preset == null or placement == null:
		push_error("[Tile Studio] Particle emitter construction requires a preset and placement.")
		return null
	if not preset.is_valid():
		push_error("[Tile Studio] Particle preset '%s' is incomplete." % preset.preset_id)
		return null
	var texture := load(preset.texture_path) as Texture2D
	if texture == null:
		push_error("[Tile Studio] Particle preset '%s' cannot load PNG '%s'." % [preset.preset_id, preset.texture_path])
		return null

	var root := Node3D.new()
	root.name = "Particle_%s" % placement.placement_id
	root.position = placement.position
	root.set_meta("mts_particle_placement", placement)
	root.set_meta("mts_particle_preset_id", preset.preset_id)

	var particles := GPUParticles3D.new()
	particles.name = "Emitter"
	particles.amount = preset.amount
	particles.lifetime = preset.lifetime_seconds
	particles.explosiveness = preset.explosiveness
	particles.randomness = preset.emission_randomness
	particles.one_shot = preset.one_shot
	particles.local_coords = false
	particles.use_fixed_seed = true
	particles.seed = preset.fixed_seed
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	particles.process_material = _build_process_material(preset)
	particles.draw_pass_1 = _build_particle_quad(preset, texture)
	particles.visibility_aabb = _visibility_aabb(preset)
	particles.emitting = placement.enabled
	root.add_child(particles)
	return root


## Build the standard Godot process material from the preset's visible simulation values.
func _build_process_material(preset: ParticleEffectPreset) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# Godot stores half-extents; the preset and UI expose the full box dimensions.
	process.emission_box_extents = preset.emission_box_size_m * 0.5
	process.direction = preset.direction
	process.spread = preset.spread_degrees
	process.initial_velocity_min = preset.initial_velocity_min
	process.initial_velocity_max = preset.initial_velocity_max
	process.gravity = preset.gravity
	process.angular_velocity_min = preset.angular_velocity_min
	process.angular_velocity_max = preset.angular_velocity_max
	process.scale_min = preset.particle_size_min_m
	process.scale_max = preset.particle_size_max_m
	process.color = preset.tint

	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([
		0.0,
		preset.fade_in_fraction,
		1.0 - preset.fade_out_fraction,
		1.0,
	])
	gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color.WHITE,
		Color.WHITE,
		Color(1.0, 1.0, 1.0, 0.0),
	])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	return process


## Build the single one-metre billboard quad whose process scale is authored directly in metres.
func _build_particle_quad(
	preset: ParticleEffectPreset,
	texture: Texture2D
) -> QuadMesh:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Billboarding preserves the preset's metre scale instead of resetting each particle to one metre.
	material.billboard_keep_scale = true
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = texture
	material.albedo_color = Color.WHITE
	if preset.emission_energy > 0.0:
		material.emission_enabled = true
		material.emission_texture = texture
		material.emission = preset.tint
		material.emission_energy_multiplier = preset.emission_energy

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = material
	return quad


## Derive a conservative culling box from emitter size, lifetime, speed, gravity, and particle size.
func _visibility_aabb(preset: ParticleEffectPreset) -> AABB:
	var lifetime := preset.lifetime_seconds
	var speed_travel := Vector3.ONE * preset.initial_velocity_max * lifetime
	var gravity_travel := Vector3(
		absf(preset.gravity.x),
		absf(preset.gravity.y),
		absf(preset.gravity.z)
	) * 0.5 * lifetime * lifetime
	var extent := preset.emission_box_size_m * 0.5 + speed_travel + gravity_travel
	extent += Vector3.ONE * preset.particle_size_max_m
	return AABB(-extent, extent * 2.0)
