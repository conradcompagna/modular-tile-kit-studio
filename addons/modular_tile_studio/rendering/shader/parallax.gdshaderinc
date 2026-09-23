// Resolve which height sources contribute at this fragment and how strongly.
//
// The weights depend only on the painted splat control texture, never on the
// sampled world position, so they are constant along a parallax ray and both
// parallax modes read them from here. Restating this mix per mode would let the
// two modes disagree about the same painted surface.
void terrain_parallax_weights(
	vec4 painted_weights,
	out float base_weight,
	out vec4 layer_weights,
	out float total_weight,
	out float source_short_edge_px
) {
	base_weight = has_height ? 1.0 : 0.0;
	layer_weights = vec4(0.0);
	float base_source_px = has_height ? parallax_source_short_edge_px : 0.0;
	if (!material_blend_enabled) {
		total_weight = base_weight;
		source_short_edge_px = base_source_px;
		return;
	}

	// Only a layer this variant actually compiled can contribute; the others stay
	// zero, so a reduced variant blends exactly as the full shader would with
	// those layers disabled.
	vec4 layer_mask = vec4(0.0);
#if MTS_LAYER_COUNT > 0
	layer_mask.x = (material_layer_0_enabled && material_layer_0_has_height) ? 1.0 : 0.0;
#endif
#if MTS_LAYER_COUNT > 1
	layer_mask.y = (material_layer_1_enabled && material_layer_1_has_height) ? 1.0 : 0.0;
#endif
#if MTS_LAYER_COUNT > 2
	layer_mask.z = (material_layer_2_enabled && material_layer_2_has_height) ? 1.0 : 0.0;
#endif
#if MTS_LAYER_COUNT > 3
	layer_mask.w = (material_layer_3_enabled && material_layer_3_has_height) ? 1.0 : 0.0;
#endif
	layer_weights = max(painted_weights, vec4(0.0)) * layer_mask;
	base_weight *= max(1.0 - dot(max(painted_weights, vec4(0.0)), vec4(1.0)), 0.0);
	total_weight = base_weight + dot(layer_weights, vec4(1.0));
	if (total_weight <= 0.00001) {
		source_short_edge_px = 0.0;
		return;
	}
	float source_px_sum = base_source_px * base_weight;
#if MTS_LAYER_COUNT > 0
	source_px_sum += material_layer_0_parallax_source_short_edge_px * layer_weights.x;
#endif
#if MTS_LAYER_COUNT > 1
	source_px_sum += material_layer_1_parallax_source_short_edge_px * layer_weights.y;
#endif
#if MTS_LAYER_COUNT > 2
	source_px_sum += material_layer_2_parallax_source_short_edge_px * layer_weights.z;
#endif
#if MTS_LAYER_COUNT > 3
	source_px_sum += material_layer_3_parallax_source_short_edge_px * layer_weights.w;
#endif
	source_short_edge_px = source_px_sum / total_weight;
}

// Resolve the visible terrain height before offsetting texture samples.
//
// Direct terrain paint uses its own height map. Material-paint layers use their
// painted weights, so an artist's map painting is the sole source of which
// height relief appears in each terrain region.
void terrain_parallax_height(
	vec3 world_pos,
	vec3 world_normal,
	vec4 painted_weights,
	out float height,
	out float relief_range_m
) {
	height = 0.5;
	relief_range_m = 0.0;
	if (!terrain_triangle_instances) {
		return;
	}

	vec2 face_coord = v_surface_uv;
	vec2 face_grad_x = dFdx(face_coord);
	vec2 face_grad_y = dFdy(face_coord);

	float base_height = has_height ? sample_projected_fragment_raw(
		height_tex, face_coord, face_grad_x, face_grad_y,
		world_pos, world_normal, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
	).r : 0.5;

	float base_weight;
	vec4 layer_weights;
	float total_weight;
	float source_short_edge_px;
	terrain_parallax_weights(painted_weights, base_weight, layer_weights, total_weight, source_short_edge_px);
	if (!material_blend_enabled) {
		height = base_height;
	} else if (total_weight > 0.00001) {
		// Accumulated rather than summed in one expression so a layer this variant
		// did not compile contributes nothing without leaving a dangling term. Its
		// weight is already zero in layer_weights, so the result is identical to
		// the full shader with that layer disabled.
		float height_sum = base_height * base_weight;
#if MTS_LAYER_COUNT > 0
		height_sum += sample_projected_fragment_oriented(
			material_layer_0_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_0_repeat_m,
			material_layer_0_stochastic_tiling, material_layer_0_variation_asset_seed,
			material_layer_0_random_texture_rotation, material_layer_0_random_texture_mirroring, material_layer_quarter_turns(0)
		).r * layer_weights.x;
#endif
#if MTS_LAYER_COUNT > 1
		height_sum += sample_projected_fragment_oriented(
			material_layer_1_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_1_repeat_m,
			material_layer_1_stochastic_tiling, material_layer_1_variation_asset_seed,
			material_layer_1_random_texture_rotation, material_layer_1_random_texture_mirroring, material_layer_quarter_turns(1)
		).r * layer_weights.y;
#endif
#if MTS_LAYER_COUNT > 2
		height_sum += sample_projected_fragment_oriented(
			material_layer_2_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_2_repeat_m,
			material_layer_2_stochastic_tiling, material_layer_2_variation_asset_seed,
			material_layer_2_random_texture_rotation, material_layer_2_random_texture_mirroring, material_layer_quarter_turns(2)
		).r * layer_weights.z;
#endif
#if MTS_LAYER_COUNT > 3
		height_sum += sample_projected_fragment_oriented(
			material_layer_3_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_3_repeat_m,
			material_layer_3_stochastic_tiling, material_layer_3_variation_asset_seed,
			material_layer_3_random_texture_rotation, material_layer_3_random_texture_mirroring, material_layer_quarter_turns(3)
		).r * layer_weights.w;
#endif
		height = height_sum / total_weight;
	}

	relief_range_m = source_short_edge_px * mts_height_metres_per_source_pixel;
	// A one-shot decal is the topmost material at its source alpha. It uses the
	// same board-wide height conversion while changing only texture addressing.
	vec2 decal_coord = shader_decal_uv_for_world_position(world_pos);
	vec2 decal_grad_x = shader_decal_uv_for_world_direction(dFdx(world_pos));
	vec2 decal_grad_y = shader_decal_uv_for_world_direction(dFdy(world_pos));
	vec3 decal_height = sample_shader_decal_height(
		decal_coord, decal_grad_x, decal_grad_y
	);
	height = mix(height, decal_height.r, decal_height.b);
	float decal_relief_range_m = decal_height.g * mts_height_metres_per_source_pixel;
	relief_range_m = mix(relief_range_m, decal_relief_range_m, decal_height.b);
	relief_range_m *= mts_parallax_master;
}

// RETIRED: Offset terrain samples once using the visible painted height.
//
// This legacy implementation is intentionally retained as dead reference code.
// The active shader path never calls it; raymarching is the sole parallax system.
vec3 offset_parallax_sample_world_pos(vec3 world_pos, vec3 world_normal) {
	if (!terrain_triangle_instances) {
		return world_pos;
	}
	vec3 normal_ws = normalize(world_normal);
	float height;
	float relief_range_m;
	terrain_parallax_height(world_pos, normal_ws, resolved_material_control_weights(), height, relief_range_m);
	if (relief_range_m <= 0.0) {
		return world_pos;
	}
	vec3 view_ws = normalize(v_camera_position_world - world_pos);
	float view_normal_alignment = abs(dot(view_ws, normal_ws));
	vec3 view_parallel = view_ws - normal_ws * dot(view_ws, normal_ws);
	float parallel_length = length(view_parallel);
	if (parallel_length <= 0.0001) {
		return world_pos;
	}
	float travel_m = (height - 0.5) * relief_range_m / max(view_normal_alignment, 0.15);
	return world_pos - normalize(view_parallel) * travel_m;
}

// -----------------------------------------------------------------------------
// Deep parallax (occlusion mapping)
//
// The march must never call terrain_parallax_height. That function resolves the
// full visible height: triplanar (three projections) over stochastic variation
// (three lattice copies) for five sources, so up to forty-five texture fetches
// per evaluation. Marching it costs hundreds of fetches per fragment and, with
// an unbounded loop, expands to a pipeline the driver cannot compile in
// reasonable time or memory.
//
// Instead every per-ray constant is resolved once into MTSMarchSource, so each
// march step costs one textureGrad per contributing height source:
//
//     full-quality height  ->  hoist projection axis, lattice descriptor,
//                              splat weights and gradients
//                          ->  flat 2D coord + constant per-step advance
//                          ->  one fetch per source per step
//
// The trip count is a compile-time constant so the loop is always bounded.
// -----------------------------------------------------------------------------

const int MTS_PARALLAX_MAX_STEPS = 16;
const int MTS_PARALLAX_REFINE_STEPS = 4;

// One height source pre-resolved into the flat texture space the march walks.
struct MTSMarchSource {
	vec2 coord;
	vec2 advance;
	vec2 grad_x;
	vec2 grad_y;
	float weight;
};

// Return a source that contributes nothing and is never sampled.
//
// A variant compiled for fewer layers has no uniforms for the layers it dropped,
// so those slots are filled with this instead. Zero weight makes
// mts_march_source_height return early, and the matching MTS_LAYER_COUNT guard in
// mts_march_height removes the call altogether, so this is only ever a
// placeholder that keeps one function signature across every variant.
MTSMarchSource mts_inert_march_source() {
	MTSMarchSource source;
	source.coord = vec2(0.0);
	source.advance = vec2(0.0);
	source.grad_x = vec2(0.0);
	source.grad_y = vec2(0.0);
	source.weight = 0.0;
	return source;
}

// Return the strongest of the three world projections for one face normal.
//
// A parallax ray stays inside a single face and travels only centimetres, so the
// triplanar blend cannot shift meaningfully along it. Marching the dominant axis
// alone is therefore visually identical to marching the blend at a third of the
// cost, and the final shaded sample still uses the full triplanar path.
int mts_dominant_projection_axis(vec3 world_normal) {
	vec3 weights = abs(normalize(world_normal));
	if (weights.x >= weights.y && weights.x >= weights.z) {
		return 0;
	}
	if (weights.y >= weights.z) {
		return 1;
	}
	return 2;
}

// Project one world point, or one world-space direction, onto a single axis.
//
// This is exactly the per-axis mapping sample_projected_fragment_raw uses. It
// carries no translation term, which is what allows a direction to be projected
// by the same call and the march to advance by a constant 2D step.
vec2 mts_march_coord(vec3 world_point, int axis, int quarter_turns) {
	if (axis == 0) {
		return rotate_quarter_turns(vec2(-world_point.z, world_point.y), quarter_turns);
	}
	if (axis == 1) {
		return rotate_quarter_turns(vec2(world_point.x, -world_point.z), quarter_turns);
	}
	return rotate_quarter_turns(vec2(world_point.x, world_point.y), quarter_turns);
}

// Resolve one height source into ray-constant march state.
//
// The lattice descriptor is hoisted from the ray origin and reused for the whole
// ray. Stochastic variation only changes across tile boundaries metres apart,
// while the ray spans centimetres, so holding one descriptor keeps the marched
// height field registered to the pattern that will actually be shaded. Gradients
// are derived from the caller's world derivatives rather than dFdx/dFdy here,
// because the march runs inside branchy control flow where derivatives are
// undefined.
MTSMarchSource mts_make_march_source(
	vec3 origin,
	vec3 step_world,
	vec3 world_ddx,
	vec3 world_ddy,
	int axis,
	int quarter_turns,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	float weight
) {
	MTSMarchSource source;
	source.weight = weight;
	vec2 period_m = safe_size(repeat_m);
	if (use_stochastic_tiling) {
		period_m *= max(mts_stochastic_scale, 0.0001);
	}
	source.coord = mts_march_coord(origin, axis, quarter_turns) / period_m;
	source.advance = mts_march_coord(step_world, axis, quarter_turns) / period_m;
	source.grad_x = mts_march_coord(world_ddx, axis, quarter_turns) / period_m;
	source.grad_y = mts_march_coord(world_ddy, axis, quarter_turns) / period_m;
#ifdef MTS_TEXTURE_VARIATION
	if (use_stochastic_tiling || use_random_rotation || use_random_mirroring) {
		vec2 id0;
		vec2 id1;
		vec2 id2;
		vec3 lattice_weights;
		variation_triangle(source.coord, id0, id1, id2, lattice_weights);
		// The strongest lattice copy carries the pattern a viewer actually reads.
		vec2 lattice_id = id0;
		if (lattice_weights.y > lattice_weights.x && lattice_weights.y >= lattice_weights.z) {
			lattice_id = id1;
		} else if (lattice_weights.z > lattice_weights.x && lattice_weights.z > lattice_weights.y) {
			lattice_id = id2;
		}
		vec2 varied_coord;
		int varied_turns;
		bool varied_mirror;
		texture_variation_descriptor(
			source.coord, lattice_id, use_stochastic_tiling, asset_seed,
			use_random_rotation, use_random_mirroring,
			varied_coord, varied_turns, varied_mirror
		);
		// The descriptor's phase shift applies to the point only; the advance and
		// gradients are directions and take just its rotation and mirror.
		source.coord = varied_coord;
		source.advance = texture_variation_direction(source.advance, varied_turns, varied_mirror);
		source.grad_x = texture_variation_direction(source.grad_x, varied_turns, varied_mirror);
		source.grad_y = texture_variation_direction(source.grad_y, varied_turns, varied_mirror);
	}
#endif
	return source;
}

// Resolve one placement-local shader decal into ray-constant march state.
//
// Unlike tiled terrain layers this coordinate is the asset's exact 0..1 footprint,
// so it needs neither triplanar projection nor stochastic repetition.
MTSMarchSource mts_make_shader_decal_source(
	vec3 origin,
	vec3 step_world,
	vec3 world_ddx,
	vec3 world_ddy
) {
	MTSMarchSource source;
	source.coord = shader_decal_uv_for_world_position(origin);
	source.advance = shader_decal_uv_for_world_direction(step_world);
	source.grad_x = shader_decal_uv_for_world_direction(world_ddx);
	source.grad_y = shader_decal_uv_for_world_direction(world_ddy);
	source.weight = (shader_decal_enabled && shader_decal_has_height) ? 1.0 : 0.0;
	return source;
}

// Sample one source's weighted height contribution at a fractional march step.
//
// A source with no painted weight is skipped outright, so the common case of one
// or two active layers costs one or two fetches per step rather than five.
float mts_march_source_height(sampler2D tex, MTSMarchSource source, float step_index) {
	if (source.weight <= 0.0005) {
		return 0.0;
	}
	return textureGrad(
		tex,
		source.coord + source.advance * step_index,
		source.grad_x,
		source.grad_y
	).r * source.weight;
}

// Resolve the blended march height at a fractional step along the ray.
//
// The weights are pre-normalised by the caller, so this returns the same 0..1
// height terrain_parallax_height would report, built from single lookups.
float mts_march_height(
	MTSMarchSource base_source,
	MTSMarchSource layer_0_source,
	MTSMarchSource layer_1_source,
	MTSMarchSource layer_2_source,
	MTSMarchSource layer_3_source,
	MTSMarchSource decal_source,
	float empty_terrain_height,
	float step_index
) {
	// Accumulated so a layer this variant did not compile leaves no dangling term.
	// Its source carries zero weight regardless, so the marched field matches the
	// full shader with that layer disabled.
	float terrain_height = empty_terrain_height
		+ mts_march_source_height(height_tex, base_source, step_index);
#if MTS_LAYER_COUNT > 0
	terrain_height += mts_march_source_height(material_layer_0_height_tex, layer_0_source, step_index);
#endif
#if MTS_LAYER_COUNT > 1
	terrain_height += mts_march_source_height(material_layer_1_height_tex, layer_1_source, step_index);
#endif
#if MTS_LAYER_COUNT > 2
	terrain_height += mts_march_source_height(material_layer_2_height_tex, layer_2_source, step_index);
#endif
#if MTS_LAYER_COUNT > 3
	terrain_height += mts_march_source_height(material_layer_3_height_tex, layer_3_source, step_index);
#endif
	if (decal_source.weight <= 0.0) {
		return terrain_height;
	}
	vec2 decal_coord = decal_source.coord + decal_source.advance * step_index;
	vec2 height_inset = 0.5 / max(
		vec2(textureSize(shader_decal_height_tex, 0)),
		vec2(1.0)
	);
	vec2 albedo_inset = 0.5 / max(
		vec2(textureSize(shader_decal_albedo_tex, 0)),
		vec2(1.0)
	);
	vec2 height_uv = clamp(decal_coord, height_inset, vec2(1.0) - height_inset);
	vec2 albedo_uv = clamp(decal_coord, albedo_inset, vec2(1.0) - albedo_inset);
	float decal_height = textureGrad(
		shader_decal_height_tex, height_uv, decal_source.grad_x, decal_source.grad_y
	).r;
	float decal_coverage = textureGrad(
		shader_decal_albedo_tex, albedo_uv, decal_source.grad_x, decal_source.grad_y
	).a * shader_decal_inside(decal_coord);
	return mix(terrain_height, decal_height, clamp(decal_coverage, 0.0, 1.0));
}

// Raymarch the visible painted height to its true intersection with the view ray.
//
// The wall or terrain surface is the minimum plane. The march begins at the
// virtual top of the outward relief volume, walks back toward that plane until it
// meets the height field, and then bisects the crossed interval.
vec3 godot_raymarched_parallax_sample_world_pos(vec3 world_pos, vec3 world_normal, vec4 painted_weights) {
	if (!terrain_triangle_instances) {
		return world_pos;
	}

	// Derivatives are only defined in uniform control flow. The one return above
	// branches on a uniform, so it is identical for every fragment in the draw and
	// safe to precede them; every return below this point is per-fragment, so no
	// derivative may be taken after one. They double as the march's gradients.
	vec3 world_ddx = dFdx(world_pos);
	vec3 world_ddy = dFdy(world_pos);
	float metres_per_pixel = max(max(length(world_ddx), length(world_ddy)), 0.000001);

	float base_weight;
	vec4 layer_weights;
	float total_weight;
	float source_short_edge_px;
	terrain_parallax_weights(painted_weights, base_weight, layer_weights, total_weight, source_short_edge_px);
	vec2 decal_origin_uv = shader_decal_uv_for_world_position(world_pos);
	vec2 decal_ddx = shader_decal_uv_for_world_direction(world_ddx);
	vec2 decal_ddy = shader_decal_uv_for_world_direction(world_ddy);
	vec3 decal_origin_height = sample_shader_decal_height(
		decal_origin_uv, decal_ddx, decal_ddy
	);
	if (total_weight <= 0.00001 && decal_origin_height.b <= 0.00001) {
		return world_pos;
	}
	float terrain_relief_range_m = source_short_edge_px * mts_height_metres_per_source_pixel;
	float decal_relief_range_m = decal_origin_height.g * mts_height_metres_per_source_pixel;
	float relief_range_m = mix(
		terrain_relief_range_m,
		decal_relief_range_m,
		decal_origin_height.b
	) * mts_parallax_master;
	if (relief_range_m <= 0.0) {
		return world_pos;
	}

	// Relief thinner than a pixel cannot be seen, so the march fades out and then
	// stops entirely as the board is zoomed away. This is the largest single cost
	// control: a zoomed-out board pays nothing for deep parallax. Measuring it in
	// pixels rather than metres keeps it correct for both orthographic and
	// perspective cameras without consulting the projection.
	float relief_pixels = relief_range_m / metres_per_pixel;
	float quality = smoothstep(1.0, 4.0, relief_pixels);
	if (quality <= 0.0) {
		return world_pos;
	}

	vec3 normal_ws = normalize(world_normal);
	vec3 view_ws = normalize(v_camera_position_world - world_pos);
	float view_normal_alignment = abs(dot(view_ws, normal_ws));
	vec3 view_parallel = view_ws - normal_ws * dot(view_ws, normal_ws);
	if (length(view_parallel) <= 0.0001) {
		return world_pos;
	}

	// The sweep reaches from the receiver plane to the virtual top of the outward
	// relief volume. Its clamped denominator prevents an unbounded grazing trace.
	vec3 sweep = view_parallel * relief_range_m / max(view_normal_alignment, 0.15);

	// A flatter view spreads the same depth range over a longer sweep and needs
	// more steps to avoid stair-stepping. Isometric floors sit near 0.5 alignment,
	// which lands in the middle of this range.
	int steps = int(clamp(
		ceil(mix(float(MTS_PARALLAX_MAX_STEPS), 6.0, view_normal_alignment) * quality),
		2.0,
		float(MTS_PARALLAX_MAX_STEPS)
	));
	vec3 ray_origin_world = world_pos + sweep;
	vec3 step_world = -sweep / float(steps);

	int axis = mts_dominant_projection_axis(normal_ws);
	int quarter_turns = surface_quarter_turns();
	float inverse_total_weight = total_weight > 0.00001 ? 1.0 / total_weight : 0.0;
	float empty_terrain_height = total_weight > 0.00001 ? 0.0 : 0.5;

	MTSMarchSource base_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, quarter_turns,
		surface_size_m, stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring,
		base_weight * inverse_total_weight
	);
	// A layer this variant did not compile has no uniforms to read, so it is given
	// an inert source instead. mts_march_height skips it on the same condition,
	// so the inert source is never sampled; it exists only to keep one signature.
#if MTS_LAYER_COUNT > 0
	MTSMarchSource layer_0_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(0),
		material_layer_0_repeat_m, material_layer_0_stochastic_tiling,
		material_layer_0_variation_asset_seed, material_layer_0_random_texture_rotation,
		material_layer_0_random_texture_mirroring,
		layer_weights.x * inverse_total_weight
	);
#else
	MTSMarchSource layer_0_source = mts_inert_march_source();
#endif
#if MTS_LAYER_COUNT > 1
	MTSMarchSource layer_1_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(1),
		material_layer_1_repeat_m, material_layer_1_stochastic_tiling,
		material_layer_1_variation_asset_seed, material_layer_1_random_texture_rotation,
		material_layer_1_random_texture_mirroring,
		layer_weights.y * inverse_total_weight
	);
#else
	MTSMarchSource layer_1_source = mts_inert_march_source();
#endif
#if MTS_LAYER_COUNT > 2
	MTSMarchSource layer_2_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(2),
		material_layer_2_repeat_m, material_layer_2_stochastic_tiling,
		material_layer_2_variation_asset_seed, material_layer_2_random_texture_rotation,
		material_layer_2_random_texture_mirroring,
		layer_weights.z * inverse_total_weight
	);
#else
	MTSMarchSource layer_2_source = mts_inert_march_source();
#endif
#if MTS_LAYER_COUNT > 3
	MTSMarchSource layer_3_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(3),
		material_layer_3_repeat_m, material_layer_3_stochastic_tiling,
		material_layer_3_variation_asset_seed, material_layer_3_random_texture_rotation,
		material_layer_3_random_texture_mirroring,
		layer_weights.w * inverse_total_weight
	);
#else
	MTSMarchSource layer_3_source = mts_inert_march_source();
#endif
	MTSMarchSource decal_source = mts_make_shader_decal_source(
		ray_origin_world, step_world, world_ddx, world_ddy
	);

	// Convert authored white-is-high height to depth measured from the virtual top,
	// then walk toward the receiver plane until the ray reaches that depth.
	float layer_depth = 1.0 / float(steps);
	float previous_index = 0.0;
	float resolved_index = float(steps);
	bool crossed = false;
	for (int i = 1; i <= MTS_PARALLAX_MAX_STEPS; i++) {
		if (i > steps) {
			break;
		}
		float index = float(i);
		float sampled_depth = 1.0 - mts_march_height(
			base_source, layer_0_source, layer_1_source, layer_2_source, layer_3_source,
			decal_source, empty_terrain_height, index
		);
		if (index * layer_depth >= sampled_depth) {
			resolved_index = index;
			crossed = true;
			break;
		}
		previous_index = index;
	}

	// Bisect the crossed interval so a hard edge resolves to a sharp contact
	// instead of the linear walk's visible stair step. Four halvings shrink the
	// residual error to a sixteenth of one step, which is below a pixel at every
	// zoom this fades out at.
	if (crossed) {
		float low_index = previous_index;
		float high_index = resolved_index;
		for (int refine = 0; refine < MTS_PARALLAX_REFINE_STEPS; refine++) {
			float mid_index = (low_index + high_index) * 0.5;
			float mid_depth = 1.0 - mts_march_height(
				base_source, layer_0_source, layer_1_source, layer_2_source, layer_3_source,
				decal_source, empty_terrain_height, mid_index
			);
			if (mid_index * layer_depth >= mid_depth) {
				high_index = mid_index;
			} else {
				low_index = mid_index;
			}
		}
		resolved_index = high_index;
	}

	// Scale the complete outward offset from the receiver plane so quality zero
	// returns exactly to canonical geometry without a zoom-distance pop.
	vec3 resolved_offset_world = sweep + step_world * resolved_index;
	return world_pos + resolved_offset_world * quality;
}

// Raymarching is the sole active parallax algorithm.
//
// The retired offset function remains above as dead reference code and is never
// selected by this shader.
vec3 parallax_sample_world_pos(vec3 world_pos, vec3 world_normal, vec4 painted_weights) {
	return godot_raymarched_parallax_sample_world_pos(world_pos, world_normal, painted_weights);
}
