float material_normalized_range(float value, vec2 value_range) {
	float width = max(value_range.y - value_range.x, 0.000001);
	return clamp((value - value_range.x) / width, 0.0, 1.0);
}

// Interpolate hashed lattice values so the mask varies continuously across world space.
float material_value_noise(vec2 point, float seed) {
	vec2 cell = floor(point);
	vec2 fraction = fract(point);
	vec2 blend = fraction * fraction * (3.0 - 2.0 * fraction);
	float value_00 = hash12(cell, seed);
	float value_10 = hash12(cell + vec2(1.0, 0.0), seed);
	float value_01 = hash12(cell + vec2(0.0, 1.0), seed);
	float value_11 = hash12(cell + vec2(1.0, 1.0), seed);
	return mix(mix(value_00, value_10, blend.x), mix(value_01, value_11, blend.x), blend.y);
}

// Sum four rotated octaves to produce broad, non-grid-aligned smooth variation.
float material_smooth_noise(vec2 world_xz, float scale_m, float seed) {
	vec2 point = world_xz / max(scale_m, 0.01);
	float value = 0.0;
	float amplitude = 0.5333333;
	float total = 0.0;
	for (int octave = 0; octave < 4; octave++) {
		value += material_value_noise(point, seed + float(octave) * 31.7) * amplitude;
		total += amplitude;
		point = vec2(point.x * 0.6 + point.y * 0.8, -point.x * 0.8 + point.y * 0.6) * 2.03 + vec2(11.7, -9.2);
		amplitude *= 0.5;
	}
	return value / max(total, 0.00001);
}

// Fold smooth noise around its midpoint to form sharper branching ridges.
float material_ridged_noise(vec2 world_xz, float scale_m, float seed) {
	float ridge = 1.0 - abs(material_smooth_noise(world_xz, scale_m, seed) * 2.0 - 1.0);
	return ridge * ridge;
}

// Measure distance to seeded cell points for rounded patches and irregular borders.
float material_cellular_noise(vec2 world_xz, float scale_m, float seed) {
	vec2 point = world_xz / max(scale_m, 0.01);
	vec2 base_cell = floor(point);
	float nearest_squared = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = base_cell + vec2(float(x), float(y));
			vec2 feature = cell + hash22(cell, seed);
			vec2 delta = feature - point;
			nearest_squared = min(nearest_squared, dot(delta, delta));
		}
	}
	return clamp(sqrt(nearest_squared) * 1.41421356, 0.0, 1.0);
}

// Warp world-space stripes with smooth noise while keeping their direction explicit.
float material_directional_bands(vec2 world_xz, float scale_m, float seed, float angle_degrees) {
	float angle = radians(angle_degrees);
	vec2 axis = vec2(cos(angle), sin(angle));
	float warp = material_smooth_noise(world_xz, scale_m * 3.0, seed + 47.0) - 0.5;
	float phase = dot(world_xz, axis) / max(scale_m, 0.01) + warp * 0.65 + seed * 0.013;
	return sin(phase * TAU) * 0.5 + 0.5;
}

// Resolve one explicit material-mask source without substituting another algorithm.
float material_source_value(
	int source,
	int channel,
	vec4 painted_weights,
	vec4 material_id_value,
	float base_height,
	float base_ao,
	float base_roughness,
	float base_metallic,
	float base_luminance,
	float world_height,
	float elevation,
	float surface_up,
	vec2 local_uv,
	float contact,
	vec2 world_xz,
	float noise_scale,
	float noise_seed,
	float noise_angle_degrees
) {
	if (source == 0) {
		return material_component(painted_weights, channel);
	}
	if (source == 1) {
		return base_height;
	}
	// Legacy cavity/curvature mask recipes now read their baked ORM channels.
	// The runtime cannot recover the pre-bake derivative fields independently.
	if (source == 2) {
		return base_ao;
	}
	if (source == 3) {
		return base_roughness;
	}
	if (source == 4) {
		return base_ao;
	}
	if (source == 5) {
		return base_roughness;
	}
	if (source == 6) {
		return base_metallic;
	}
	if (source == 7) {
		return base_luminance;
	}
	if (source == 8) {
		return material_component(material_id_value, channel);
	}
	if (source == 9) {
		return world_height;
	}
	if (source == 10) {
		return elevation;
	}
	if (source == 11) {
		return surface_up;
	}
	if (source == 12) {
		return 1.0 - surface_up;
	}
	if (source == 13) {
		return 1.0 - clamp(local_uv.y, 0.0, 1.0);
	}
	if (source == 14) {
		return clamp(local_uv.y, 0.0, 1.0);
	}
	if (source == 15) {
		return contact;
	}
	if (source == 16) {
		return material_smooth_noise(world_xz, noise_scale, noise_seed);
	}
	if (source == 17) {
		return material_ridged_noise(world_xz, noise_scale, noise_seed);
	}
	if (source == 18) {
		return material_cellular_noise(world_xz, noise_scale, noise_seed);
	}
	return material_directional_bands(world_xz, noise_scale, noise_seed, noise_angle_degrees);
}

float material_range_mask(float value, float low, float high, float softness) {
	float minimum_value = min(low, high);
	float maximum_value = max(low, high);
	float edge = max(softness, 0.00001);
	float lower = minimum_value <= 0.0
		? 1.0
		: smoothstep(minimum_value - edge, minimum_value + edge, value);
	float upper = maximum_value >= 1.0
		? 1.0
		: 1.0 - smoothstep(maximum_value - edge, maximum_value + edge, value);
	return clamp(lower * upper, 0.0, 1.0);
}

// Rec. 709 luma, shared by the base coat and by every painted layer so the
// Albedo mask source cannot mean two different things at two call sites.
const vec3 MTS_LUMINANCE_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);

// The mask inputs describing the surface a layer is painted ONTO: the base coat
// plus every other layer already painted at this texel.
//
// Cavity and curvature recipes consume the AO/roughness values into which those
// analyses were baked. Material ID remains base-coat-only because layers carry
// no equivalent channel.
struct MaterialSurfaceBeneath {
	float height;
	float ao;
	float roughness;
	float metallic;
	float luminance;
};

// Return one channel of the surface beneath a slot, given that slot's own paint
// already removed from the weights.
//
// The base coat occupies whatever coverage the painted layers leave, which is the
// same remainder the normalized composite computes further down. A face whose base
// coat has been fully painted over therefore contributes none of it here, which is
// the entire point: the mask reads what is actually on the square.
float material_channel_beneath(
	vec4 layer_channel,
	vec4 present_weights,
	float base_channel
) {
	float present_total = dot(present_weights, vec4(1.0));
	float base_weight = max(1.0 - present_total, 0.0);
	return (base_channel * base_weight + dot(layer_channel, present_weights))
		/ max(base_weight + present_total, 0.0001);
}

// Resolve every composite-able mask input for one slot in a single pass.
//
// Weighting the lower layers by authored paint x art coverage -- rather than by each
// lower layer's own resolved mask -- is what keeps this non-circular AND independent
// of slot order: every slot excludes only itself and includes all others equally. So a
// layer masks on "where the layers under me were brushed and have pixels", not on
// "what those layers' masks finally let through". Making that exact would require
// evaluating masks in slot order, and slot order is allocated per face rather than
// authored, so it would make the same two materials stack differently on neighbouring
// tiles for reasons nothing in the UI shows.
MaterialSurfaceBeneath material_surface_beneath(
	int slot,
	vec4 layer_presence,
	vec4 layer_height_channel,
	vec4 layer_ao_channel,
	vec4 layer_roughness_channel,
	vec4 layer_metallic_channel,
	vec4 layer_luminance_channel,
	float base_height,
	float base_ao,
	float base_roughness,
	float base_metallic,
	float base_luminance
) {
	// Slot -1 excludes nothing, which is exactly what the preview needs for a palette
	// entry this face does not carry yet: it would land on top of everything present.
	vec4 others = layer_presence * vec4(
		slot == 0 ? 0.0 : 1.0,
		slot == 1 ? 0.0 : 1.0,
		slot == 2 ? 0.0 : 1.0,
		slot == 3 ? 0.0 : 1.0
	);
	MaterialSurfaceBeneath result;
	result.height = material_channel_beneath(layer_height_channel, others, base_height);
	result.ao = material_channel_beneath(layer_ao_channel, others, base_ao);
	result.roughness = material_channel_beneath(layer_roughness_channel, others, base_roughness);
	result.metallic = material_channel_beneath(layer_metallic_channel, others, base_metallic);
	result.luminance = material_channel_beneath(layer_luminance_channel, others, base_luminance);
	return result;
}

// Evaluate one material's ordered mask constraints with an explicit paint-coverage gate.
//
// Real brush layers apply their authored splat weight, while the reach preview disables
// that gate but still skips rule zero because it remains the brush's structural rule.
vec2 material_layer_masks(
	int count,
	ivec4 sources,
	ivec4 combines,
	ivec4 channels,
	ivec4 inversions,
	vec4 lows,
	vec4 highs,
	vec4 softness,
	vec4 strengths,
	vec4 noise_scales,
	vec4 noise_seeds,
	vec4 noise_angles,
	int layer_index,
	bool brush_authored,
	bool apply_painted_gate,
	vec4 painted_weights,
	ivec4 painted_channel_available,
	vec4 material_id_value,
	float base_height,
	float base_ao,
	float base_roughness,
	float base_metallic,
	float base_luminance,
	float world_height,
	float elevation,
	float surface_up,
	vec2 local_uv,
	float contact,
	vec2 world_xz
) {
	bool painted_gate_enabled = brush_authored && apply_painted_gate;
	float painted_gate = painted_gate_enabled
		? material_component(painted_weights, layer_index)
		: 1.0;
	// A brush layer absent from this texel cannot be revived by any later mask
	// operation, so avoid its complete rule stack here.
	if (painted_gate_enabled && painted_gate <= MTS_PAINT_WEIGHT_THRESHOLD) {
		return vec2(0.0);
	}
	float result = 1.0;
	for (int rule_index = 0; rule_index < 4; rule_index++) {
		// Rule zero records the brush layer's structural channel assignment. The
		// exact splat weight is applied after every optional constraint so no
		// combine operation can create coverage outside authored brush pixels.
		if (rule_index >= count || (brush_authored && rule_index == 0)) {
			continue;
		}
		int source = material_int_component(sources, rule_index);
		int channel = material_int_component(channels, rule_index);
		float source_value = material_source_value(
			source,
			channel,
			painted_weights,
			material_id_value,
			base_height,
			base_ao,
			base_roughness,
			base_metallic,
			base_luminance,
			world_height,
			elevation,
			surface_up,
			local_uv,
			contact,
			world_xz,
			material_component(noise_scales, rule_index),
			material_component(noise_seeds, rule_index),
			material_component(noise_angles, rule_index)
		);
		// A referenced palette entry absent from this face has exactly zero
		// painted weight; preview availability records that fact explicitly.
		if (
			source == 0
			&& material_int_component(painted_channel_available, rule_index) == 0
		) {
			source_value = 0.0;
		}
		float rule = material_range_mask(
			source_value,
			material_component(lows, rule_index),
			material_component(highs, rule_index),
			material_component(softness, rule_index)
		);
		if (material_int_component(inversions, rule_index) != 0) {
			rule = 1.0 - rule;
		}
		float strength = clamp(material_component(strengths, rule_index), 0.0, 1.0);
		int combine = material_int_component(combines, rule_index);
		if (combine == 0) {
			result *= mix(1.0, rule, strength);
		} else if (combine == 1) {
			result += rule * strength;
		} else if (combine == 2) {
			result -= rule * strength;
		} else if (combine == 3) {
			result = max(result, rule * strength);
		} else {
			result = min(result, mix(1.0, rule, strength));
		}
	}
	float constraint_mask = clamp(result, 0.0, 1.0);
	return vec2(constraint_mask * painted_gate, constraint_mask);
}

MaterialLayerSample sample_material_layer(
	bool enabled,
	vec2 metric_uv,
	// Resolved once by fragment() and shared by every channel this layer samples.
	vec3 material_world_pos,
	MaterialLayerAddressing addressing,
	sampler2D albedo_texture,
	sampler2D normal_texture,
	sampler2D orm_texture,
	sampler2D height_texture,
	sampler2D emission_texture,
	sampler2D detail_albedo_texture,
	bool has_layer_normal,
	bool has_layer_height,
	bool has_layer_emission,
	bool has_layer_orm,
	bool has_layer_detail_albedo,
	float layer_albedo_strength,
	vec4 layer_tint_color,
	float layer_tint_strength,
	float layer_normal_strength,
	float layer_ao_strength,
	float layer_roughness_strength,
	float layer_metallic_strength,
	float layer_roughness_bias,
	float layer_metallic_bias,
	float layer_emission_strength,
	float layer_specular_strength,
	vec2 repeat_m,
	bool layer_stochastic_tiling,
	float layer_variation_asset_seed,
	bool layer_random_texture_rotation,
	bool layer_random_texture_mirroring
) {
	MaterialLayerSample layer;
	layer.albedo = vec3(1.0);
	layer.tangent_normal = vec3(0.0, 0.0, 1.0);
	layer.orm = vec3(1.0, 1.0, 0.0);
	layer.height = 0.5;
	layer.emission = vec3(0.0);
	layer.specular = 0.5;
	// Fully covering by default, so a layer with no albedo texture keeps behaving
	// exactly as it did before coverage existed.
	layer.coverage = 1.0;
	if (!enabled) {
		return layer;
	}

	vec2 overlay_coord = addressing.one_shot
		? shader_decal_uv_for_world_position(material_world_pos)
		: metric_uv * safe_size(surface_size_m) / safe_size(repeat_m);
	vec2 overlay_grad_x = dFdx(overlay_coord);
	vec2 overlay_grad_y = dFdy(overlay_coord);
	// Sampled as vec4: the alpha is this layer's own coverage and is carried
	// through to composition instead of being dropped with the .rgb swizzle.
	vec4 raw_albedo_sample = sample_material_layer_raw(
		albedo_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
		material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
	);
	layer.coverage = clamp(raw_albedo_sample.a, 0.0, 1.0);
	if (addressing.one_shot) {
		layer.coverage *= shader_decal_inside(overlay_coord);
	}
	layer.albedo = mix(vec3(1.0), raw_albedo_sample.rgb, clamp(layer_albedo_strength, 0.0, 1.0));
	// Strength blends the multiplier from neutral white to the asset's exact tint.
	layer.albedo *= mix(vec3(1.0), layer_tint_color.rgb, clamp(layer_tint_strength, 0.0, 1.0));
	layer.albedo = layer.albedo * addressing.palette_scale + addressing.palette_offset;
	// Transparent art contributes no downstream PBR channels. Height used by the
	// parallax intersection was already resolved by the dedicated march, so this
	// final-shading return cannot flatten relief in neighbouring covered texels.
	if (layer.coverage <= MTS_PAINT_WEIGHT_THRESHOLD) {
		return layer;
	}
	if (has_layer_detail_albedo) {
		vec3 detail_color = sample_material_layer_raw(
			detail_albedo_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).rgb;
		layer.albedo *= mix(vec3(1.0), detail_color, 0.35);
	}
	if (has_layer_orm) {
		vec3 raw_orm = sample_material_layer_raw(
			orm_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).rgb;
		layer.orm.r = 1.0 + (raw_orm.r - 1.0) * clamp(layer_ao_strength, 0.0, 1.0);
		layer.orm.g = clamp(
			1.0 + (raw_orm.g - 1.0) * clamp(layer_roughness_strength, 0.0, 1.0)
				+ layer_roughness_bias,
			0.0,
			1.0
		);
		layer.orm.b = clamp(
			raw_orm.b * clamp(layer_metallic_strength, 0.0, 1.0)
				+ layer_metallic_bias,
			0.0,
			1.0
		);
	}
	if (has_layer_normal && layer_normal_strength > 0.0) {
		vec3 sampled_normal = sample_material_layer_tangent_normal(
			normal_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, v_tangent_world,
			v_binormal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		);
		layer.tangent_normal = normalize(mix(
			vec3(0.0, 0.0, 1.0),
			sampled_normal,
			clamp(layer_normal_strength, 0.0, 1.0)
		));
	}
	if (has_layer_height) {
		layer.height = sample_material_layer_raw(
			height_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).r;
	}
	if (has_layer_emission) {
		layer.emission = sample_material_layer_raw(
			emission_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).rgb * layer_emission_strength;
	}
	layer.specular = clamp(layer_specular_strength, 0.0, 1.0);
	return layer;
}

float material_height_blend(
	float weight,
	float layer_height,
	float base_height,
	float strength,
	bool has_layer_height
) {
	if (!has_layer_height || strength <= 0.0) {
		return weight;
	}
	// Height can bias only an existing transition. Preserving both endpoints
	// prevents height data from inventing procedural or brush coverage.
	float transition = clamp(weight, 0.0, 1.0);
	float transition_band = 4.0 * transition * (1.0 - transition);
	return clamp(
		transition + (layer_height - base_height) * strength * transition_band,
		0.0,
		1.0
	);
}

void material_mix_layer(
	MaterialLayerSample layer,
	float weight,
	inout vec3 albedo,
	inout vec3 tangent_normal,
	inout float roughness,
	inout float metallic,
	inout float ao,
	inout vec3 emission,
	inout float specular
) {
	// `weight` already has this layer's art coverage folded into it by the caller,
	// which is what keeps the LAYER and NORMALIZED_SPLAT modes agreeing about
	// where a transparent region contributes nothing.
	float amount = clamp(weight, 0.0, 1.0);
	albedo = mix(albedo, layer.albedo, amount);
	tangent_normal = normalize(mix(tangent_normal, layer.tangent_normal, amount));
	roughness = mix(roughness, layer.orm.g, amount);
	metallic = mix(metallic, layer.orm.b, amount);
	ao = mix(ao, layer.orm.r, amount);
	emission = mix(emission, layer.emission, amount);
	specular = mix(specular, layer.specular, amount);
}
