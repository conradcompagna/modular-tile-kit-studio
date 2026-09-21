@tool
extends RefCounted

## World fields behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Publish scalar look values for the active board through Godot's project-wide
## shader-global store. The editor binds one board at a time, while each board
## keeps its own AestheticProfile as the authoritative persisted value.
static func _apply_global_shader_parameters(host: SurfaceMaterialFactory, look: AestheticProfile) -> void:
	if look == null:
		return
	RenderingServer.global_shader_parameter_set("mts_parallax_master", look.parallax_master)
	RenderingServer.global_shader_parameter_set(
		"mts_height_metres_per_source_pixel", look.height_metres_per_source_pixel
	)
	RenderingServer.global_shader_parameter_set("mts_stochastic_scale", look.stochastic_scale)
	RenderingServer.global_shader_parameter_set("mts_stochastic_blend_sharpness", look.stochastic_blend_sharpness)
	RenderingServer.global_shader_parameter_set("mts_stochastic_seed", look.stochastic_seed)
	RenderingServer.global_shader_parameter_set("mts_interaction_enabled", look.interaction_effects_enabled)
	RenderingServer.global_shader_parameter_set("mts_contact_grime", look.contact_grime)
	RenderingServer.global_shader_parameter_set("mts_contact_grime_darkening", look.contact_grime_darkening)
	RenderingServer.global_shader_parameter_set("mts_contact_grime_fade", look.contact_grime_fade)
	RenderingServer.global_shader_parameter_set("mts_contact_grime_noise", look.contact_grime_noise)


## Bind the active board's textures and world rectangles to one material.
##
## Textures stay material-local because they are Resources owned by the board
## viewport; raymarched parallax is now the shader's sole algorithm.
static func _apply_board_resources_to_material(host: SurfaceMaterialFactory, mat: ShaderMaterial) -> void:
	if mat == null:
		return
	var uses_world_height := bool(mat.get_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_WORLD_HEIGHT_META, true))
	if host.world_fields != null:
		if uses_world_height:
			mat.set_shader_parameter("g_world_height_tex", host.world_fields.height_texture)
			mat.set_shader_parameter("g_world_height_rect", host.world_fields.shader_rect())
		mat.set_shader_parameter("g_interaction_tex", host.world_fields.interaction_texture)
		mat.set_shader_parameter("g_interaction_rect", host.world_fields.shader_rect())
	else:
		if uses_world_height:
			mat.set_shader_parameter("g_world_height_tex", SurfaceMaterialFactory._black_texture())
		mat.set_shader_parameter("g_interaction_tex", SurfaceMaterialFactory._black_texture())


## Apply a board look without rebuilding geometry or materials.
##
## Scalar controls update the native shader-global store. Cached materials also
## receive the active board textures used by the sole raymarched parallax path.
static func apply_global_effects(host: SurfaceMaterialFactory, profile: AestheticProfile = null) -> void:
	if profile != null:
		host.aesthetics = profile
	var look := host._look()
	host._apply_global_shader_parameters(look)
	# Live batch duplicates are included: they render the board and would keep a
	# replaced world-field or interaction texture if only the cache were updated.
	for shader_mat: ShaderMaterial in host._all_live_materials():
		host._apply_board_resources_to_material(shader_mat)
