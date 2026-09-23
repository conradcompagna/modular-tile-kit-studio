// Apply live RGBA multipliers while preserving the authored pixel's total coverage.
// This declaration precedes terrain_parallax_height because Godot resolves shader
// functions in source order and the parallax helpers are the first consumers.
const float MTS_PAINT_WEIGHT_THRESHOLD = 4.0 / 255.0;

// Remove 8-bit encoding noise while preserving meaningful authored base coverage.
// If the remaining base coat is itself at or below the same threshold, the
// painted survivors expand to full coverage so no downstream base channel is read.
vec4 prune_material_weights(vec4 weights) {
	vec4 positive = max(weights, vec4(0.0));
	float original_total = dot(positive, vec4(1.0));
	vec4 surviving = positive * step(vec4(MTS_PAINT_WEIGHT_THRESHOLD + 0.000001), positive);
	float surviving_total = dot(surviving, vec4(1.0));
	if (surviving_total <= 0.00001) {
		return vec4(0.0);
	}
	float original_base_weight = max(1.0 - original_total, 0.0);
	float resolved_painted_total = original_base_weight <= MTS_PAINT_WEIGHT_THRESHOLD
		? 1.0
		: original_total;
	return surviving * (resolved_painted_total / surviving_total);
}

vec4 adjusted_splatmap_channel_weights(vec4 weights) {
	vec4 native_weights = max(weights, vec4(0.0));
	if (!splatmap_channel_strengths_enabled) {
		return prune_material_weights(native_weights);
	}
	float native_total = dot(native_weights, vec4(1.0));
	vec4 adjusted = native_weights * max(splatmap_channel_strengths, vec4(0.0));
	float adjusted_total = dot(adjusted, vec4(1.0));
	if (native_total <= 0.00001 || adjusted_total <= 0.00001) {
		return vec4(0.0);
	}
	return prune_material_weights(adjusted * (native_total / adjusted_total));
}

// Resolve this fragment's canonical painted weights exactly once.
//
// Whole-face classification is carried by MultiMesh COLOR. Base-only and
// uniform faces therefore never touch the control array, while mixed faces
// perform the sole texture read reused by parallax, masks, and composition.
vec4 resolved_material_control_weights() {
	if (!material_blend_enabled) {
		return vec4(0.0);
	}
	if (terrain_triangle_instances && v_material_control_class < 0.5) {
		return vec4(0.0);
	}
	if (terrain_triangle_instances && v_material_control_class < 1.5) {
		vec4 uniform_weights = vec4(0.0);
		int slot = int(round(v_material_uniform_slot));
		if (slot == 0) {
			uniform_weights.r = 1.0;
		} else if (slot == 1) {
			uniform_weights.g = 1.0;
		} else if (slot == 2) {
			uniform_weights.b = 1.0;
		} else {
			uniform_weights.a = 1.0;
		}
		return adjusted_splatmap_channel_weights(uniform_weights);
	}
	return adjusted_splatmap_channel_weights(texture(
		material_control_tex,
		vec3(clamp(v_surface_uv, vec2(0.0), vec2(1.0)), v_material_control_layer)
	));
}
