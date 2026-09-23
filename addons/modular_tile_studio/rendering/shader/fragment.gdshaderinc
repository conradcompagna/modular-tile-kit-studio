// -----------------------------------------------------------------------------
// Fragment stage
// -----------------------------------------------------------------------------

// Return the anti-aliased coverage of canonical polygon edges only.
// Internal fan and quad diagonals have no boundary bit and remain invisible.
float terrain_grid_factor() {
	vec3 derivative_width = max(
		fwidth(v_terrain_barycentric) * max(terrain_grid_line_width_px, 0.5),
		vec3(0.00001)
	);
	float coverage = 0.0;
	// Bit 0: point 0 to point 1, whose opposite barycentric coordinate is Z.
	if (mod(v_terrain_boundary_mask, 2.0) >= 1.0) {
		coverage = max(coverage, 1.0 - smoothstep(
			0.0, derivative_width.z, v_terrain_barycentric.z
		));
	}
	// Bit 1: point 1 to point 2, whose opposite coordinate is X.
	if (mod(floor(v_terrain_boundary_mask * 0.5), 2.0) >= 1.0) {
		coverage = max(coverage, 1.0 - smoothstep(
			0.0, derivative_width.x, v_terrain_barycentric.x
		));
	}
	// Bit 2: point 2 to point 0, whose opposite coordinate is Y.
	if (mod(floor(v_terrain_boundary_mask * 0.25), 2.0) >= 1.0) {
		coverage = max(coverage, 1.0 - smoothstep(
			0.0, derivative_width.y, v_terrain_barycentric.y
		));
	}
	return coverage;
}

void fragment() {
	// A stable per-pixel threshold reads as transparency while retaining opaque
	// depth behavior. The instance uniform changes without duplicating materials or
	// selecting a transparent shader variant during character movement.

	// Terrain channels sample one map-wide triplanar field from canonical world
	// position. Non-terrain assets retain their authored face projection.
	vec2 base_coord = v_metric_uv;
	vec2 grad_x = dFdx(base_coord);
	vec2 grad_y = dFdy(base_coord);

	vec2 coord = base_coord;
	// Resolve the control field before parallax and keep it for every later stage.
	// This is the only material_control_tex call in the complete fragment path.
	vec4 painted_weights = resolved_material_control_weights();

	// The parallax offset depends only on this fragment's world position and
	// normal, so it is resolved once and shared by every channel below. Resolving
	// it per channel inlined the whole height-blend chain into each sample and
	// made the shader take tens of seconds to compile on first draw.
	vec3 material_world_pos = parallax_sample_world_pos(
		v_base_world_pos, v_base_normal_world, painted_weights
	);
	bool sample_base_coat = material_base_coat_needed(painted_weights);

	vec4 albedo_sample = vec4(1.0);
	if (sample_base_coat) {
		albedo_sample = sample_projected_fragment_raw(
			albedo_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
			stochastic_tiling, texture_variation_asset_seed,
			random_texture_rotation, random_texture_mirroring
		);
	}
	vec3 albedo = mix(vec3(1.0), albedo_sample.rgb, clamp(albedo_strength, 0.0, 1.0));
	// Strength zero is exactly neutral; strength one applies the selected asset tint.
	albedo *= mix(vec3(1.0), texture_tint_color.rgb, clamp(texture_tint_strength, 0.0, 1.0));

	// Detail albedo is an optional high-frequency overlay using the same coherent
	// stochastic coordinates as every other map.
	if (sample_base_coat && has_detail_albedo) {
		vec3 detail_color = sample_projected_fragment_raw(
			detail_albedo_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
		).rgb;
		albedo *= mix(vec3(1.0), detail_color, 0.35);
	}

	// One packed ORM fetch is the complete runtime scalar-PBR contract. Cavity
	// and curvature have already been baked into R/G, while the live controls
	// below still adjust AO, roughness, and metallic independently.
	vec3 orm_value = vec3(1.0, 1.0, 0.0);
	if (sample_base_coat && has_orm) {
		orm_value = sample_projected_fragment_raw(
			orm_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
		).rgb;
	}

	float roughness_value = 1.0;
	if (sample_base_coat && has_orm) {
		roughness_value = 1.0 + (orm_value.g - 1.0) * roughness_strength;
	}
	roughness_value = clamp(roughness_value + roughness_bias, 0.0, 1.0);

	float metallic_value = 0.0;
	if (sample_base_coat && has_orm) {
		metallic_value = orm_value.b * metallic_strength;
	}
	metallic_value = clamp(metallic_value + metallic_bias, 0.0, 1.0);

	float ao_value = 1.0;
	if (sample_base_coat && has_orm) {
		ao_value = 1.0 + (orm_value.r - 1.0) * ao_strength;
	}

	vec3 tangent_ws;
	vec3 binormal_ws;
	vec3 geometry_normal_ws;
	surface_tangent_frame(coord, tangent_ws, binormal_ws, geometry_normal_ws);
	// Do not turn a visible back face into a second front face. Keeping the
	// authored frame makes the production material expose reversed placement in
	// the same directionally dark way as the paint preview.

	vec3 tangent_normal = vec3(0.0, 0.0, 1.0);
	if (sample_base_coat && has_normal && normal_strength > 0.0) {
		vec3 sampled_n = sample_projected_tangent_normal(
			normal_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, v_tangent_world,
			v_binormal_world, surface_size_m,
			stochastic_tiling, texture_variation_asset_seed,
			random_texture_rotation, random_texture_mirroring
		);
		// Blend the whole vector from flat to authored. Scaling XY alone left a
		// near-zero Z unchanged, so even the lowest setting could renormalize a
		// steep texel back into an almost horizontal, incorrectly dark normal.
		tangent_normal = normalize(mix(
			vec3(0.0, 0.0, 1.0),
			sampled_n,
			clamp(normal_strength, 0.0, 1.0)
		));
	}
	vec3 emission_value = vec3(0.0);
	if (sample_base_coat && has_emission) {
		emission_value += sample_projected_fragment_raw(
			emission_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
		).rgb * emission_strength;
	}
	float specular_value = clamp(specular_strength, 0.0, 1.0);

	// Contact is sampled once and shared by automatic masks and the final grime pass.
	vec4 interaction = sample_interaction_fragment(v_base_world_pos.xz);
	float base_height_value = material_base_height_needed(painted_weights) ? sample_projected_fragment_raw(
		height_tex, coord, grad_x, grad_y,
		material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
	).r : 0.5;
	vec4 material_id_value = (has_material_id && material_base_source_needed(painted_weights, 8)) ? sample_projected_fragment_raw(
		material_id_tex, coord, grad_x, grad_y,
		material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
	) : vec4(0.0);
	float base_luminance = dot(albedo, MTS_LUMINANCE_WEIGHTS);
	// AO, roughness and metallic are the only base values whose live variables are
	// later rewritten in place -- by the composited layers, the shader decal and the
	// contact grime pass. Snapshotting them here, exactly as base_luminance already
	// does, gives material_surface_beneath() one stable base-coat term regardless of
	// where in fragment() its result is consumed.
	float base_ao_value = ao_value;
	float base_roughness_value = roughness_value;
	float base_metallic_value = metallic_value;
	float normalized_world_height = 0.0;
#ifdef MTS_WORLD_HEIGHT_FIELD
	if (material_debug_view == 7 || material_base_source_needed(painted_weights, 9)) {
		vec2 world_height_uv = world_rect_uv(v_base_world_pos.xz, g_world_height_rect);
		float raw_world_height = uv_inside_01(world_height_uv)
			? texture(g_world_height_tex, world_height_uv).r
			: material_world_height_range.x;
		normalized_world_height = material_normalized_range(
			raw_world_height,
			material_world_height_range
		);
	}
#endif
	float normalized_elevation = material_normalized_range(
		v_base_world_pos.y,
		material_world_elevation_range
	);
	float surface_up = abs(normalize(v_base_normal_world).y);

#if MTS_LAYER_COUNT > 0
	MaterialLayerSample layer_0 = sample_material_layer(
		material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r), v_metric_uv, material_world_pos, tiled_material_layer_addressing(0),
		material_layer_0_albedo_tex, material_layer_0_normal_tex,
		material_layer_0_orm_tex, material_layer_0_height_tex, material_layer_0_emission_tex,
		material_layer_0_detail_albedo_tex,
		material_layer_0_has_normal, material_layer_0_has_height, material_layer_0_has_emission,
		material_layer_0_has_orm,
		material_layer_0_has_detail_albedo,
		material_layer_0_albedo_strength, material_layer_0_tint_color, material_layer_0_tint_strength,
		material_layer_0_normal_strength,
		material_layer_0_ao_strength, material_layer_0_roughness_strength, material_layer_0_metallic_strength,
		material_layer_0_roughness_bias, material_layer_0_metallic_bias,
		material_layer_0_emission_strength, material_layer_0_specular_strength, material_layer_0_repeat_m,
		material_layer_0_stochastic_tiling, material_layer_0_variation_asset_seed,
		material_layer_0_random_texture_rotation, material_layer_0_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_0 = mts_inert_material_layer();
#endif
#if MTS_LAYER_COUNT > 1
	MaterialLayerSample layer_1 = sample_material_layer(
		material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g), v_metric_uv, material_world_pos, tiled_material_layer_addressing(1),
		material_layer_1_albedo_tex, material_layer_1_normal_tex,
		material_layer_1_orm_tex, material_layer_1_height_tex, material_layer_1_emission_tex,
		material_layer_1_detail_albedo_tex,
		material_layer_1_has_normal, material_layer_1_has_height, material_layer_1_has_emission,
		material_layer_1_has_orm,
		material_layer_1_has_detail_albedo,
		material_layer_1_albedo_strength, material_layer_1_tint_color, material_layer_1_tint_strength,
		material_layer_1_normal_strength,
		material_layer_1_ao_strength, material_layer_1_roughness_strength, material_layer_1_metallic_strength,
		material_layer_1_roughness_bias, material_layer_1_metallic_bias,
		material_layer_1_emission_strength, material_layer_1_specular_strength, material_layer_1_repeat_m,
		material_layer_1_stochastic_tiling, material_layer_1_variation_asset_seed,
		material_layer_1_random_texture_rotation, material_layer_1_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_1 = mts_inert_material_layer();
#endif
#if MTS_LAYER_COUNT > 2
	MaterialLayerSample layer_2 = sample_material_layer(
		material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b), v_metric_uv, material_world_pos, tiled_material_layer_addressing(2),
		material_layer_2_albedo_tex, material_layer_2_normal_tex,
		material_layer_2_orm_tex, material_layer_2_height_tex, material_layer_2_emission_tex,
		material_layer_2_detail_albedo_tex,
		material_layer_2_has_normal, material_layer_2_has_height, material_layer_2_has_emission,
		material_layer_2_has_orm,
		material_layer_2_has_detail_albedo,
		material_layer_2_albedo_strength, material_layer_2_tint_color, material_layer_2_tint_strength,
		material_layer_2_normal_strength,
		material_layer_2_ao_strength, material_layer_2_roughness_strength, material_layer_2_metallic_strength,
		material_layer_2_roughness_bias, material_layer_2_metallic_bias,
		material_layer_2_emission_strength, material_layer_2_specular_strength, material_layer_2_repeat_m,
		material_layer_2_stochastic_tiling, material_layer_2_variation_asset_seed,
		material_layer_2_random_texture_rotation, material_layer_2_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_2 = mts_inert_material_layer();
#endif
#if MTS_LAYER_COUNT > 3
	MaterialLayerSample layer_3 = sample_material_layer(
		material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a), v_metric_uv, material_world_pos, tiled_material_layer_addressing(3),
		material_layer_3_albedo_tex, material_layer_3_normal_tex,
		material_layer_3_orm_tex, material_layer_3_height_tex, material_layer_3_emission_tex,
		material_layer_3_detail_albedo_tex,
		material_layer_3_has_normal, material_layer_3_has_height, material_layer_3_has_emission,
		material_layer_3_has_orm,
		material_layer_3_has_detail_albedo,
		material_layer_3_albedo_strength, material_layer_3_tint_color, material_layer_3_tint_strength,
		material_layer_3_normal_strength,
		material_layer_3_ao_strength, material_layer_3_roughness_strength, material_layer_3_metallic_strength,
		material_layer_3_roughness_bias, material_layer_3_metallic_bias,
		material_layer_3_emission_strength, material_layer_3_specular_strength, material_layer_3_repeat_m,
		material_layer_3_stochastic_tiling, material_layer_3_variation_asset_seed,
		material_layer_3_random_texture_rotation, material_layer_3_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_3 = mts_inert_material_layer();
#endif
	// A shader decal is one more MaterialLayerSample. Its addressing state is the
	// sole distinction from the tiled profile layers above.
	MaterialLayerSample shader_decal_layer = sample_material_layer(
		shader_decal_enabled, v_metric_uv, material_world_pos,
		shader_decal_material_layer_addressing(),
		shader_decal_albedo_tex, shader_decal_normal_tex,
		shader_decal_orm_tex, shader_decal_height_tex, shader_decal_emission_tex,
		shader_decal_detail_albedo_tex,
		shader_decal_has_normal, shader_decal_has_height, shader_decal_has_emission,
		shader_decal_has_orm,
		shader_decal_has_detail_albedo,
		shader_decal_albedo_strength, shader_decal_tint_color,
		shader_decal_tint_strength, shader_decal_normal_strength,
		shader_decal_ao_strength,
		shader_decal_roughness_strength, shader_decal_metallic_strength,
		shader_decal_roughness_bias,
		shader_decal_metallic_bias, shader_decal_emission_strength,
		shader_decal_specular_strength, shader_decal_footprint_m,
		false, 0.0, false, false
	);

	// What is ALREADY on this texel: authored paint weight times each layer's own art
	// coverage. Layers this variant did not compile return coverage 0.0 from
	// mts_inert_material_layer(), so they drop out of every sum below without a guard.
	vec4 layer_presence = painted_weights * vec4(
		layer_0.coverage, layer_1.coverage, layer_2.coverage, layer_3.coverage
	);
	vec4 layer_height_channel = vec4(
		layer_0.height, layer_1.height, layer_2.height, layer_3.height
	);
	vec4 layer_ao_channel = vec4(
		layer_0.orm.r, layer_1.orm.r, layer_2.orm.r, layer_3.orm.r
	);
	vec4 layer_roughness_channel = vec4(
		layer_0.orm.g, layer_1.orm.g, layer_2.orm.g, layer_3.orm.g
	);
	vec4 layer_metallic_channel = vec4(
		layer_0.orm.b, layer_1.orm.b, layer_2.orm.b, layer_3.orm.b
	);
	vec4 layer_luminance_channel = vec4(
		dot(layer_0.albedo, MTS_LUMINANCE_WEIGHTS),
		dot(layer_1.albedo, MTS_LUMINANCE_WEIGHTS),
		dot(layer_2.albedo, MTS_LUMINANCE_WEIGHTS),
		dot(layer_3.albedo, MTS_LUMINANCE_WEIGHTS)
	);

	vec4 layer_weights = vec4(0.0);
	vec4 layer_constraints = vec4(0.0);
	if (material_blend_enabled) {
#if MTS_LAYER_COUNT > 0
		MaterialSurfaceBeneath beneath_0 = material_surface_beneath(
			0, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_0_masks = material_layer_masks(
			material_layer_0_mask_count,
			material_layer_0_mask_sources, material_layer_0_mask_combines,
			material_layer_0_mask_channels, material_layer_0_mask_inversions, material_layer_0_mask_lows,
			material_layer_0_mask_highs, material_layer_0_mask_softness, material_layer_0_mask_strengths,
			material_layer_0_mask_noise_scales, material_layer_0_mask_noise_seeds,
			material_layer_0_mask_noise_angles, 0, material_layer_0_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_0.height, beneath_0.ao,
			beneath_0.roughness, beneath_0.metallic, beneath_0.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.r = layer_0_masks.x * material_layer_0_opacity * float(material_layer_0_enabled);
		layer_constraints.r = layer_0_masks.y * float(material_layer_0_enabled);
#endif
#if MTS_LAYER_COUNT > 1
		MaterialSurfaceBeneath beneath_1 = material_surface_beneath(
			1, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_1_masks = material_layer_masks(
			material_layer_1_mask_count,
			material_layer_1_mask_sources, material_layer_1_mask_combines,
			material_layer_1_mask_channels, material_layer_1_mask_inversions, material_layer_1_mask_lows,
			material_layer_1_mask_highs, material_layer_1_mask_softness, material_layer_1_mask_strengths,
			material_layer_1_mask_noise_scales, material_layer_1_mask_noise_seeds,
			material_layer_1_mask_noise_angles, 1, material_layer_1_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_1.height, beneath_1.ao,
			beneath_1.roughness, beneath_1.metallic, beneath_1.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.g = layer_1_masks.x * material_layer_1_opacity * float(material_layer_1_enabled);
		layer_constraints.g = layer_1_masks.y * float(material_layer_1_enabled);
#endif
#if MTS_LAYER_COUNT > 2
		MaterialSurfaceBeneath beneath_2 = material_surface_beneath(
			2, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_2_masks = material_layer_masks(
			material_layer_2_mask_count,
			material_layer_2_mask_sources, material_layer_2_mask_combines,
			material_layer_2_mask_channels, material_layer_2_mask_inversions, material_layer_2_mask_lows,
			material_layer_2_mask_highs, material_layer_2_mask_softness, material_layer_2_mask_strengths,
			material_layer_2_mask_noise_scales, material_layer_2_mask_noise_seeds,
			material_layer_2_mask_noise_angles, 2, material_layer_2_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_2.height, beneath_2.ao,
			beneath_2.roughness, beneath_2.metallic, beneath_2.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.b = layer_2_masks.x * material_layer_2_opacity * float(material_layer_2_enabled);
		layer_constraints.b = layer_2_masks.y * float(material_layer_2_enabled);
#endif
#if MTS_LAYER_COUNT > 3
		MaterialSurfaceBeneath beneath_3 = material_surface_beneath(
			3, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_3_masks = material_layer_masks(
			material_layer_3_mask_count,
			material_layer_3_mask_sources, material_layer_3_mask_combines,
			material_layer_3_mask_channels, material_layer_3_mask_inversions, material_layer_3_mask_lows,
			material_layer_3_mask_highs, material_layer_3_mask_softness, material_layer_3_mask_strengths,
			material_layer_3_mask_noise_scales, material_layer_3_mask_noise_seeds,
			material_layer_3_mask_noise_angles, 3, material_layer_3_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_3.height, beneath_3.ao,
			beneath_3.roughness, beneath_3.metallic, beneath_3.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.a = layer_3_masks.x * material_layer_3_opacity * float(material_layer_3_enabled);
		layer_constraints.a = layer_3_masks.y * float(material_layer_3_enabled);
#endif

			// A layer this variant did not compile already carries zero weight, so
			// skipping its height blend leaves the composite unchanged.
#if MTS_LAYER_COUNT > 0
			layer_weights.r = material_height_blend(layer_weights.r, layer_0.height, base_height_value, material_layer_0_height_blend, material_layer_0_has_height);
#endif
#if MTS_LAYER_COUNT > 1
			layer_weights.g = material_height_blend(layer_weights.g, layer_1.height, base_height_value, material_layer_1_height_blend, material_layer_1_has_height);
#endif
#if MTS_LAYER_COUNT > 2
			layer_weights.b = material_height_blend(layer_weights.b, layer_2.height, base_height_value, material_layer_2_height_blend, material_layer_2_has_height);
#endif
#if MTS_LAYER_COUNT > 3
			layer_weights.a = material_height_blend(layer_weights.a, layer_3.height, base_height_value, material_layer_3_height_blend, material_layer_3_has_height);
#endif

			// Fold each layer's own art coverage into its weight. The painted mask
			// says WHERE the user brushed a layer; the layer albedo's alpha says
			// where that image has pixels at all. Multiplying them here gates both
			// composition modes below, and every channel within them, from one
			// place -- so a background-removed PNG stops contributing its
			// transparent region as opaque black with a flat normal.
			layer_weights.r *= layer_0.coverage;
			layer_weights.g *= layer_1.coverage;
			layer_weights.b *= layer_2.coverage;
			layer_weights.a *= layer_3.coverage;

			if (material_blend_mode == 1) {
				float overlay_total = layer_weights.r + layer_weights.g + layer_weights.b + layer_weights.a;
				float base_weight = max(1.0 - overlay_total, 0.0);
				float total_weight = max(base_weight + overlay_total, 0.00001);
				albedo = (
					albedo * base_weight + layer_0.albedo * layer_weights.r
					+ layer_1.albedo * layer_weights.g + layer_2.albedo * layer_weights.b
					+ layer_3.albedo * layer_weights.a
				) / total_weight;
				tangent_normal = normalize(
					tangent_normal * base_weight + layer_0.tangent_normal * layer_weights.r
					+ layer_1.tangent_normal * layer_weights.g + layer_2.tangent_normal * layer_weights.b
					+ layer_3.tangent_normal * layer_weights.a
				);
				ao_value = (ao_value * base_weight + layer_0.orm.r * layer_weights.r + layer_1.orm.r * layer_weights.g + layer_2.orm.r * layer_weights.b + layer_3.orm.r * layer_weights.a) / total_weight;
				roughness_value = (roughness_value * base_weight + layer_0.orm.g * layer_weights.r + layer_1.orm.g * layer_weights.g + layer_2.orm.g * layer_weights.b + layer_3.orm.g * layer_weights.a) / total_weight;
				metallic_value = (metallic_value * base_weight + layer_0.orm.b * layer_weights.r + layer_1.orm.b * layer_weights.g + layer_2.orm.b * layer_weights.b + layer_3.orm.b * layer_weights.a) / total_weight;
				emission_value = (emission_value * base_weight + layer_0.emission * layer_weights.r + layer_1.emission * layer_weights.g + layer_2.emission * layer_weights.b + layer_3.emission * layer_weights.a) / total_weight;
				specular_value = (specular_value * base_weight + layer_0.specular * layer_weights.r + layer_1.specular * layer_weights.g + layer_2.specular * layer_weights.b + layer_3.specular * layer_weights.a) / total_weight;
			} else {
				material_mix_layer(layer_0, layer_weights.r, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
				material_mix_layer(layer_1, layer_weights.g, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
				material_mix_layer(layer_2, layer_weights.b, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
				material_mix_layer(layer_3, layer_weights.a, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
			}
	}

	// Apply the one-shot decal through the same weighted PBR layer mixer. At full
	// source alpha it replaces the coat; transparent pixels contribute nothing.
	float shader_decal_weight = shader_decal_enabled ? shader_decal_layer.coverage : 0.0;
	material_mix_layer(
		shader_decal_layer,
		shader_decal_weight,
		albedo,
		tangent_normal,
		roughness_value,
		metallic_value,
		ao_value,
		emission_value,
		specular_value
	);

	vec3 final_normal_ws = normalize(
		tangent_ws * tangent_normal.x
		+ binormal_ws * tangent_normal.y
		+ geometry_normal_ws * tangent_normal.z
	);
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal_ws, 0.0)).xyz);

	// Contact R is the one geometry-derived distance field for GLB silhouettes
	// and wall/floor seams. Contact grime is its sole reach gain: higher values
	// cross the fixed boundary farther out without introducing a second size model.
	float floor_like = pow(abs(normalize(v_base_normal_world).y), 8.0);
	float stored_contact = clamp(interaction.r, 0.0, 1.0);
	float contact_response = stored_contact * max(mts_contact_grime, 0.0);
	float contour_threshold = 0.25;
	float breakup_coverage = 1.0;
	if (mts_contact_grime_noise > 0.0 && stored_contact > 0.0001) {
		float noise_amount = clamp(mts_contact_grime_noise, 0.0, 1.0);
		// Broad noise moves the actual iso-contour in and out. Unlike colour
		// modulation, changing this threshold changes which fragments belong to
		// the mask, so the silhouette no longer remains a mechanically even band.
		float contour_noise = material_smooth_noise(v_base_world_pos.xz, 1.1, 0.0);
		contour_threshold = clamp(
			contour_threshold + (contour_noise - 0.5) * 0.65 * noise_amount,
			0.03,
			0.65
		);
		// A separately seeded patch field perforates the mask. The hard zeroes are
		// intentional: at high noise, disconnected grime patches replace the
		// continuous line instead of merely tinting that line lighter and darker.
		float breakup_noise =
			material_smooth_noise(v_base_world_pos.xz, 0.48, 61.0) * 0.55
			+ (1.0 - material_cellular_noise(v_base_world_pos.xz, 0.34, 149.0)) * 0.45;
		float breakup_cutoff = mix(0.25, 0.68, noise_amount);
		breakup_coverage = smoothstep(
			breakup_cutoff - 0.08,
			breakup_cutoff + 0.08,
			breakup_noise
		);
	}
	// Fade is opacity falloff inside the already-selected boundary. Both forms
	// become zero at the same contour threshold, so changing fade softens the
	// mask instead of retracting or extending its outer edge.
	float hard_contact = step(contour_threshold, contact_response);
	float faded_contact = smoothstep(contour_threshold, 1.0, contact_response);
	float contact_mask = mix(
		hard_contact,
		faded_contact,
		clamp(mts_contact_grime_fade, 0.0, 1.0)
	);
	contact_mask *= breakup_coverage * step(0.0001, stored_contact);
	float grime = clamp(contact_mask * floor_like, 0.0, 1.0);
	albedo *= 1.0 - grime * mts_contact_grime_darkening;
	roughness_value = mix(roughness_value, 1.0, grime * 0.25);

	// Debug choices visualize the exact stored or derived percentage masks.
	if (material_debug_view >= 1 && material_debug_view <= 4) {
		float debug_mask = material_component(layer_weights, material_debug_view - 1);
		albedo = vec3(debug_mask);
	} else if (material_debug_view == 5) {
		albedo = painted_weights.rgb;
	} else if (material_debug_view == 6) {
		albedo = vec3(base_height_value);
	} else if (material_debug_view == 7) {
		albedo = vec3(normalized_world_height);
	}
	// Source overlay is deliberately last among diagnostics: turning it on
	// shows the exact terrain-wide guide without changing painted RGBA weights.
	if (splatmap_source_overlay_enabled) {
		// The selected face direction owns one explicit two-dimensional world plane.
		// Vertical rows use 1-Y so the image's top row maps to the highest wall band,
		// exactly matching the integer projection cells sampled by the brush.
		vec2 overlay_position = v_base_world_pos.xz;
		bool overlay_face_matches = terrain_grid_is_top;
		vec3 overlay_normal = normalize(v_base_normal_world);
		if (splatmap_source_overlay_projection == 1) {
			overlay_position = vec2(v_base_world_pos.x, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.z < -0.5;
		} else if (splatmap_source_overlay_projection == 2) {
			overlay_position = vec2(v_base_world_pos.x, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.z > 0.5;
		} else if (splatmap_source_overlay_projection == 3) {
			overlay_position = vec2(v_base_world_pos.z, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.x > 0.5;
		} else if (splatmap_source_overlay_projection == 4) {
			overlay_position = vec2(v_base_world_pos.z, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.x < -0.5;
		}
		if (overlay_face_matches) {
			vec2 overlay_uv = (
				overlay_position - splatmap_source_overlay_rect.xy
			) / max(splatmap_source_overlay_rect.zw, vec2(0.0001));
			vec4 source_weights = adjusted_splatmap_channel_weights(
				texture(
					splatmap_source_overlay_tex,
					clamp(overlay_uv, vec2(0.0), vec2(1.0))
				) * splatmap_source_overlay_channel_mask
			);
			// Four weights cannot be shown in three display channels literally, so each
			// slot gets one legend colour and the result is the weighted average of the
			// slots present here. That reads as "which material wins on this square",
			// which is what the guide exists to answer.
			const vec3 slot_1_colour = vec3(0.94, 0.22, 0.20);
			const vec3 slot_2_colour = vec3(0.24, 0.86, 0.30);
			const vec3 slot_3_colour = vec3(0.26, 0.48, 0.98);
			const vec3 slot_4_colour = vec3(0.98, 0.83, 0.18);
			float total_weight = dot(source_weights, vec4(1.0));
			vec3 slot_mix = (
				source_weights.r * slot_1_colour
				+ source_weights.g * slot_2_colour
				+ source_weights.b * slot_3_colour
				+ source_weights.a * slot_4_colour
			) / max(total_weight, 0.0001);
			// Where the map carries no weight the terrain has nothing to paint, so that
			// region stays neutral grey instead of being tinted by an arbitrary slot.
			albedo = mix(vec3(0.12), slot_mix, clamp(total_weight, 0.0, 1.0));
		}
	}
	if (material_mask_preview_enabled) {
		// The tint is drawn here, after compositing, but every value fed to the mask
		// must be the same input the layer gate above consumed -- otherwise the overlay
		// stops being a prediction of what the brush will do. That means the surface
		// beneath this entry's own slot, never the live roughness/metallic/AO variables,
		// which describe the finished surface by this point.
		MaterialSurfaceBeneath beneath_preview = material_surface_beneath(
			material_mask_preview_slot, layer_presence, layer_height_channel,
			layer_ao_channel, layer_roughness_channel, layer_metallic_channel,
			layer_luminance_channel, base_height_value, base_ao_value,
			base_roughness_value, base_metallic_value, base_luminance
		);
		vec2 preview_masks = material_layer_masks(
			material_mask_preview_count,
			material_mask_preview_sources, material_mask_preview_combines,
			material_mask_preview_channels, material_mask_preview_inversions,
			material_mask_preview_lows, material_mask_preview_highs,
			material_mask_preview_softness, material_mask_preview_strengths,
			material_mask_preview_noise_scales, material_mask_preview_noise_seeds,
			material_mask_preview_noise_angles, 0,
			material_mask_preview_brush_authored, false, painted_weights,
			material_mask_preview_paint_available,
			material_id_value, beneath_preview.height,
			beneath_preview.ao, beneath_preview.roughness,
			beneath_preview.metallic, beneath_preview.luminance,
			normalized_world_height, normalized_elevation,
			surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		float preview_mask = preview_masks.y;
		vec3 preview_green = vec3(0.02, 1.0, 0.16);
		// Dim rejected areas and tint accepted strength with a fixed diagnostic
		// green; this is transient presentation and never enters authored state.
		albedo = mix(albedo * 0.22, preview_green, preview_mask);
	}

	// Draw the grid on these exact terrain fragments after every material layer.
	// Top and side toggles select face batches; neither path owns any geometry.
	bool show_terrain_grid = terrain_triangle_instances && (
		(terrain_grid_is_top && terrain_show_top_grid)
		|| (!terrain_grid_is_top && terrain_show_side_grid)
	);
	if (show_terrain_grid && v_terrain_boundary_mask > 0.0) {
		vec4 grid_color = terrain_grid_is_top
			? terrain_top_grid_color
			: terrain_side_grid_color;
		float grid_coverage = terrain_grid_factor() * grid_color.a;
		albedo = mix(albedo, grid_color.rgb, grid_coverage);
	}

	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	SPECULAR = clamp(specular_value, 0.0, 1.0);
	AO = clamp(ao_value, 0.0, 1.0);
	// The board lighting profile exposes this direct-light response explicitly;
	// zero retains indirect-only AO, while larger values make packed AO visible
	// under direct light without enabling the separate screen-space AO pass.
	AO_LIGHT_AFFECT = clamp(material_ao_light_affect, 0.0, 1.0);
	EMISSION = emission_value;

	// CUTOUT preserves the PNG silhouette with depth and shadows; the factory
	// removes these writes for OPAQUE or removes scissor alone for BLEND.
	ALPHA = albedo_sample.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
}
