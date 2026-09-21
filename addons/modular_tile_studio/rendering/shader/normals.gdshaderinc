// Decode the two stored normal channels used by Godot's normal-map import path.
vec3 decode_sampled_normal(vec3 encoded) {
	vec2 xy = encoded.rg * 2.0 - 1.0;
	float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
	return normalize(vec3(xy, z));
}

// Sample and reorient each varied normal copy before blending it in tangent space.
vec3 sample_surface_tangent_normal(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
#ifdef MTS_TEXTURE_VARIATION
	if (!use_stochastic_tiling && !use_random_rotation && !use_random_mirroring) {
		return decode_sampled_normal(textureGrad(tex, coord, grad_x, grad_y).rgb);
	}
	vec2 id0;
	vec2 id1;
	vec2 id2;
	vec3 weights;
	variation_triangle(coord, id0, id1, id2, weights);
	vec2 coord0;
	vec2 coord1;
	vec2 coord2;
	int turns0;
	int turns1;
	int turns2;
	bool mirror0;
	bool mirror1;
	bool mirror2;
	texture_variation_descriptor(coord, id0, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord0, turns0, mirror0);
	texture_variation_descriptor(coord, id1, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord1, turns1, mirror1);
	texture_variation_descriptor(coord, id2, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord2, turns2, mirror2);
	vec3 normal0 = decode_sampled_normal(textureGrad(tex, coord0, texture_variation_direction(grad_x, turns0, mirror0), texture_variation_direction(grad_y, turns0, mirror0)).rgb);
	vec3 normal1 = decode_sampled_normal(textureGrad(tex, coord1, texture_variation_direction(grad_x, turns1, mirror1), texture_variation_direction(grad_y, turns1, mirror1)).rgb);
	vec3 normal2 = decode_sampled_normal(textureGrad(tex, coord2, texture_variation_direction(grad_x, turns2, mirror2), texture_variation_direction(grad_y, turns2, mirror2)).rgb);
	normal0.xy = texture_variation_normal_xy(normal0.xy, turns0, mirror0);
	normal1.xy = texture_variation_normal_xy(normal1.xy, turns1, mirror1);
	normal2.xy = texture_variation_normal_xy(normal2.xy, turns2, mirror2);
	return normalize(normal0 * weights.x + normal1 * weights.y + normal2 * weights.z);
#else
	// No-variation variant: the lattice path is not compiled, so no per-copy
	// normal reorientation is needed either.
	return decode_sampled_normal(textureGrad(tex, coord, grad_x, grad_y).rgb);
#endif
}

// Reorient three globally projected normal samples into the terrain surface frame.
vec3 sample_projected_tangent_normal_oriented(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec3 surface_tangent,
	vec3 surface_binormal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	int orientation_quarters
) {
	if (!terrain_triangle_instances) {
		return sample_surface_tangent_normal(
			tex, planar_coord, planar_grad_x, planar_grad_y,
			use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring
		);
	}
	vec3 geometry_normal = normalize(world_normal);
	vec2 period_m = safe_size(repeat_m);
	if (use_stochastic_tiling) {
		period_m *= max(mts_stochastic_scale, 0.0001);
	}
	int steps = orientation_quarters & 3;
	vec2 coord_x = rotate_quarter_turns(vec2(-world_pos.z, world_pos.y), steps) / period_m;
	vec2 coord_y = rotate_quarter_turns(vec2(world_pos.x, -world_pos.z), steps) / period_m;
	vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;
	int normal_steps = (4 - steps) & 3;
	vec3 weights = world_projection_weights(geometry_normal);
	float sign_x = geometry_normal.x < 0.0 ? -1.0 : 1.0;
	float sign_y = geometry_normal.y < 0.0 ? -1.0 : 1.0;
	float sign_z = geometry_normal.z < 0.0 ? -1.0 : 1.0;
	// Match the scalar-channel fast path: an effectively cardinal projection
	// decodes and reorients exactly one normal sample.
	if (weights.x >= 0.999) {
		vec3 normal_x = sample_surface_tangent_normal(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
		normal_x.xy = rotate_quarter_turns(normal_x.xy, normal_steps);
		vec3 sampled_world_normal = normalize(vec3(normal_x.z * sign_x, normal_x.y, -normal_x.x));
		return normalize(vec3(
			dot(sampled_world_normal, normalize(surface_tangent)),
			dot(sampled_world_normal, normalize(surface_binormal)),
			dot(sampled_world_normal, geometry_normal)
		));
	}
	if (weights.y >= 0.999) {
		vec3 normal_y = sample_surface_tangent_normal(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
		normal_y.xy = rotate_quarter_turns(normal_y.xy, normal_steps);
		vec3 sampled_world_normal = normalize(vec3(normal_y.x, normal_y.z * sign_y, -normal_y.y));
		return normalize(vec3(
			dot(sampled_world_normal, normalize(surface_tangent)),
			dot(sampled_world_normal, normalize(surface_binormal)),
			dot(sampled_world_normal, geometry_normal)
		));
	}
	if (weights.z >= 0.999) {
		vec3 normal_z = sample_surface_tangent_normal(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
		normal_z.xy = rotate_quarter_turns(normal_z.xy, normal_steps);
		vec3 sampled_world_normal = normalize(vec3(normal_z.x, normal_z.y, normal_z.z * sign_z));
		return normalize(vec3(
			dot(sampled_world_normal, normalize(surface_tangent)),
			dot(sampled_world_normal, normalize(surface_binormal)),
			dot(sampled_world_normal, geometry_normal)
		));
	}
	vec3 normal_x = sample_surface_tangent_normal(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	vec3 normal_y = sample_surface_tangent_normal(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	vec3 normal_z = sample_surface_tangent_normal(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	normal_x.xy = rotate_quarter_turns(normal_x.xy, normal_steps);
	normal_y.xy = rotate_quarter_turns(normal_y.xy, normal_steps);
	normal_z.xy = rotate_quarter_turns(normal_z.xy, normal_steps);
	vec3 world_normal_x = normalize(vec3(normal_x.z * sign_x, normal_x.y, -normal_x.x));
	vec3 world_normal_y = normalize(vec3(normal_y.x, normal_y.z * sign_y, -normal_y.y));
	vec3 world_normal_z = normalize(vec3(normal_z.x, normal_z.y, normal_z.z * sign_z));
	vec3 sampled_world_normal = normalize(
		world_normal_x * weights.x + world_normal_y * weights.y + world_normal_z * weights.z
	);
	return normalize(vec3(
		dot(sampled_world_normal, normalize(surface_tangent)),
		dot(sampled_world_normal, normalize(surface_binormal)),
		dot(sampled_world_normal, geometry_normal)
	));
}

// Decode the base coat normal through its authored regular terrain-paint orientation.
vec3 sample_projected_tangent_normal(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec3 surface_tangent,
	vec3 surface_binormal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
	return sample_projected_tangent_normal_oriented(
		tex, planar_coord, planar_grad_x, planar_grad_y,
		world_pos, world_normal, surface_tangent, surface_binormal,
		repeat_m, use_stochastic_tiling, asset_seed,
		use_random_rotation, use_random_mirroring,
		surface_quarter_turns()
	);
}
