// -----------------------------------------------------------------------------
// Utility / stochastic texture sampling
// -----------------------------------------------------------------------------

vec2 safe_size(vec2 size_m) {
	return max(abs(size_m), vec2(0.0001));
}

vec2 hash22(vec2 p, float seed) {
	vec2 q = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(q + vec2(seed * 17.17, seed * 43.11)) * 43758.5453123);
}

// Return a deterministic scalar hash for one lattice identifier and seed.
float hash12(vec2 p, float seed) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 17.17) * 43758.5453123);
}

// Turn a coordinate by an exact number of quarter turns.
vec2 rotate_quarter_turns(vec2 coord, int steps) {
	if (steps == 1) {
		return vec2(-coord.y, coord.x);
	}
	if (steps == 2) {
		return -coord;
	}
	if (steps == 3) {
		return vec2(coord.y, -coord.x);
	}
	return coord;
}

// Return shared lattice identifiers and continuous barycentric weights.
void variation_triangle(vec2 coord, out vec2 id0, out vec2 id1, out vec2 id2, out vec3 weights) {
	vec2 skewed = vec2(coord.x - 0.57735026919 * coord.y, 1.15470053838 * coord.y);
	vec2 cell = floor(skewed);
	vec2 fraction = fract(skewed);
	float diagonal = 1.0 - fraction.x - fraction.y;
	if (diagonal > 0.0) {
		weights = vec3(diagonal, fraction.y, fraction.x);
		id0 = cell;
		id1 = cell + vec2(0.0, 1.0);
		id2 = cell + vec2(1.0, 0.0);
	} else {
		weights = vec3(-diagonal, 1.0 - fraction.y, 1.0 - fraction.x);
		id0 = cell + vec2(1.0, 1.0);
		id1 = cell + vec2(1.0, 0.0);
		id2 = cell + vec2(0.0, 1.0);
	}
	weights = pow(max(weights, vec3(0.00001)), vec3(max(mts_stochastic_blend_sharpness, 0.01)));
	weights /= max(weights.x + weights.y + weights.z, 0.00001);
}

// Resolve one lattice copy's phase, quarter-turn, and mirror from explicit asset controls.
void texture_variation_descriptor(
	vec2 coord,
	vec2 lattice_id,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	out vec2 sample_coord,
	out int quarter_turns,
	out bool mirrored
) {
	float full_seed = asset_seed + mts_stochastic_seed;
	sample_coord = coord;
	if (use_stochastic_tiling) {
		sample_coord += hash22(lattice_id, full_seed);
	}
	quarter_turns = use_random_rotation ? int(floor(hash12(lattice_id, full_seed + 71.31) * 4.0)) : 0;
	mirrored = use_random_mirroring && hash12(lattice_id, full_seed + 149.73) >= 0.5;
	if (mirrored) {
		sample_coord.x = -sample_coord.x;
	}
	sample_coord = rotate_quarter_turns(sample_coord, quarter_turns);
}

// Apply the same rotation and mirror to texture gradients as to their coordinate.
vec2 texture_variation_direction(vec2 direction, int quarter_turns, bool mirrored) {
	if (mirrored) {
		direction.x = -direction.x;
	}
	return rotate_quarter_turns(direction, quarter_turns);
}

// Return a sampled tangent normal from varied texture space to the original surface frame.
vec2 texture_variation_normal_xy(vec2 normal_xy, int quarter_turns, bool mirrored) {
	normal_xy = rotate_quarter_turns(normal_xy, (4 - quarter_turns) & 3);
	if (mirrored) {
		normal_xy.x = -normal_xy.x;
	}
	return normal_xy;
}

// PNG maps always repeat; texture variation changes sampling synthesis only.
vec2 clamp_regular_coord(sampler2D tex, vec2 coord) {
	return coord;
}

// Sample one channel with any independently enabled texture-variation controls.
vec4 sample_surface_fragment(
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
		return textureGrad(tex, clamp_regular_coord(tex, coord), grad_x, grad_y);
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
	return (
		textureGrad(tex, coord0, texture_variation_direction(grad_x, turns0, mirror0), texture_variation_direction(grad_y, turns0, mirror0)) * weights.x
		+ textureGrad(tex, coord1, texture_variation_direction(grad_x, turns1, mirror1), texture_variation_direction(grad_y, turns1, mirror1)) * weights.y
		+ textureGrad(tex, coord2, texture_variation_direction(grad_x, turns2, mirror2), texture_variation_direction(grad_y, turns2, mirror2)) * weights.z
	);
#else
	// SurfaceMaterialFactory compiled this variant for a material whose assets
	// enable no texture variation, so the three-copy lattice path does not exist
	// here at all. The runtime flags are always false in this variant.
	return textureGrad(tex, clamp_regular_coord(tex, coord), grad_x, grad_y);
#endif
}

// Sample vertex-stage data through the same explicit variation descriptor.
vec4 sample_surface_vertex(
	sampler2D tex,
	vec2 coord,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
#ifdef MTS_TEXTURE_VARIATION
	if (!use_stochastic_tiling && !use_random_rotation && !use_random_mirroring) {
		return textureLod(tex, clamp_regular_coord(tex, coord), 0.0);
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
	return textureLod(tex, coord0, 0.0) * weights.x + textureLod(tex, coord1, 0.0) * weights.y + textureLod(tex, coord2, 0.0) * weights.z;
#else
	// No-variation variant: the lattice path is not compiled. See
	// sample_surface_fragment for the same contract on the fragment side.
	return textureLod(tex, clamp_regular_coord(tex, coord), 0.0);
#endif
}

// Return continuous blend weights for the map-wide X, Y, and Z projections.
vec3 world_projection_weights(vec3 world_normal) {
	vec3 weights = abs(normalize(world_normal));
	return weights / max(weights.x + weights.y + weights.z, 0.00001);
}

// Return this triangle's authored in-plane rotation as 0..3 quarter turns.
int surface_quarter_turns() {
	return int(round(v_texture_quarters)) & 3;
}

// Return one RGBA material slot's face-local regular PNG brush orientation.
int material_layer_quarter_turns(int material_slot) {
	if (material_slot == 0) {
		return int(round(v_material_texture_quarters.r)) & 3;
	}
	if (material_slot == 1) {
		return int(round(v_material_texture_quarters.g)) & 3;
	}
	if (material_slot == 2) {
		return int(round(v_material_texture_quarters.b)) & 3;
	}
	return int(round(v_material_texture_quarters.a)) & 3;
}

// Convert a tangent-plane world direction into the receiving face's exact UV delta.
//
// The solve uses fragment derivatives from the canonical triangle, so clipped side
// bands and sloped faces retain their real UV scale rather than assuming one metre.
vec2 surface_uv_direction_from_world(
	vec3 world_direction,
	vec3 world_ddx,
	vec3 world_ddy,
	vec2 uv_ddx,
	vec2 uv_ddy
) {
	float xx = dot(world_ddx, world_ddx);
	float xy = dot(world_ddx, world_ddy);
	float yy = dot(world_ddy, world_ddy);
	float determinant = xx * yy - xy * xy;
	if (abs(determinant) <= 0.0000000001) {
		return vec2(0.0);
	}
	float direction_x = dot(world_direction, world_ddx);
	float direction_y = dot(world_direction, world_ddy);
	float screen_x = (direction_x * yy - direction_y * xy) / determinant;
	float screen_y = (direction_y * xx - direction_x * xy) / determinant;
	return uv_ddx * screen_x + uv_ddy * screen_y;
}

// Convert one world point into the decal asset's placement-local 0..1 footprint.
vec2 shader_decal_uv_for_world_position(vec3 world_pos) {
	vec3 offset = world_pos - shader_decal_origin;
	return vec2(
		dot(offset, shader_decal_axis_u) / max(shader_decal_footprint_m.x, 0.0001) + 0.5,
		0.5 - dot(offset, shader_decal_axis_v) / max(shader_decal_footprint_m.y, 0.0001)
	);
}

// Convert a world direction into the matching decal-UV direction without translation.
vec2 shader_decal_uv_for_world_direction(vec3 world_direction) {
	return vec2(
		dot(world_direction, shader_decal_axis_u) / max(shader_decal_footprint_m.x, 0.0001),
		-dot(world_direction, shader_decal_axis_v) / max(shader_decal_footprint_m.y, 0.0001)
	);
}

// Return one only inside the authored footprint so clamp sampling cannot repeat edge pixels.
float shader_decal_inside(vec2 decal_uv) {
	vec2 lower = step(vec2(0.0), decal_uv);
	vec2 upper = step(decal_uv, vec2(1.0));
	return lower.x * lower.y * upper.x * upper.y;
}

// Sample normalized decal height, source response, and source-alpha coverage together.
vec3 sample_shader_decal_height(vec2 decal_uv, vec2 grad_x, vec2 grad_y) {
	if (!shader_decal_enabled || !shader_decal_has_height) {
		return vec3(0.5, 0.0, 0.0);
	}
	vec2 albedo_inset = 0.5 / max(
		vec2(textureSize(shader_decal_albedo_tex, 0)),
		vec2(1.0)
	);
	vec2 height_inset = 0.5 / max(
		vec2(textureSize(shader_decal_height_tex, 0)),
		vec2(1.0)
	);
	vec2 albedo_uv = clamp(decal_uv, albedo_inset, vec2(1.0) - albedo_inset);
	vec2 height_uv = clamp(decal_uv, height_inset, vec2(1.0) - height_inset);
	float coverage = textureGrad(shader_decal_albedo_tex, albedo_uv, grad_x, grad_y).a;
	coverage *= shader_decal_inside(decal_uv);
	float height = textureGrad(shader_decal_height_tex, height_uv, grad_x, grad_y).r;
	return vec3(
		height,
		shader_decal_parallax_source_short_edge_px,
		clamp(coverage, 0.0, 1.0)
	);
}

// Sample one material channel from a field anchored to the world origin.
//
// The coordinate permutations contain no face-dependent sign or tangent, so a
// grid square cannot mirror, offset, or rescale the pattern on its own. The one
// thing it may change is the authored quarter turn carried per placement.
vec4 sample_projected_fragment_oriented(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	int orientation_quarters
) {
	if (!terrain_triangle_instances) {
		return sample_surface_fragment(
			tex, planar_coord, planar_grad_x, planar_grad_y,
			use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring
		);
	}
	vec2 period_m = safe_size(repeat_m);
	if (use_stochastic_tiling) {
		period_m *= max(mts_stochastic_scale, 0.0001);
	}
	int steps = orientation_quarters & 3;
	vec2 coord_x = rotate_quarter_turns(vec2(-world_pos.z, world_pos.y), steps) / period_m;
	vec2 coord_y = rotate_quarter_turns(vec2(world_pos.x, -world_pos.z), steps) / period_m;
	vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;
	vec3 weights = world_projection_weights(world_normal);
	// Axis-aligned walls and nearly all flat terrain need one projected fetch.
	// The threshold is intentionally exact enough to reject only numerical slope
	// noise; genuinely sloped faces retain the complete three-axis blend.
	if (weights.x >= 0.999) {
		return sample_surface_fragment(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	}
	if (weights.y >= 0.999) {
		return sample_surface_fragment(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	}
	if (weights.z >= 0.999) {
		return sample_surface_fragment(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	}
	return (
		sample_surface_fragment(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring) * weights.x
		+ sample_surface_fragment(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring) * weights.y
		+ sample_surface_fragment(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring) * weights.z
	);
}

// Sample the base coat through its authored regular terrain-paint orientation.
vec4 sample_projected_fragment_raw(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
	return sample_projected_fragment_oriented(
		tex, planar_coord, planar_grad_x, planar_grad_y,
		world_pos, world_normal, repeat_m, use_stochastic_tiling,
		asset_seed, use_random_rotation, use_random_mirroring,
		surface_quarter_turns()
	);
}
