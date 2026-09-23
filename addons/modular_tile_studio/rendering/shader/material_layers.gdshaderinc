// -----------------------------------------------------------------------------
// Material-layer sampling and mask composition
// -----------------------------------------------------------------------------

struct MaterialLayerAddressing {
	bool one_shot;
	int quarter_turns;
	vec3 axis_u;
	vec3 axis_v;
	vec3 normal;
	vec3 palette_scale;
	vec3 palette_offset;
};

struct MaterialLayerSample {
	vec3 albedo;
	vec3 tangent_normal;
	vec3 orm;
	float height;
	vec3 emission;
	float specular;
	// How much of this layer's ART exists at this fragment, straight from the
	// layer albedo's own alpha.
	//
	// This is INDEPENDENT of the painted mask weight: the mask says where the
	// user brushed the layer, this says where the image has pixels at all. They
	// are multiplied at composition time. Without it a background-removed PNG
	// composited its transparent region as opaque black at full mask weight,
	// which is what stamped a black rectangle around cut-out art.
	float coverage;
};

// Return the neutral addressing state used by every repeating splat layer.
MaterialLayerAddressing tiled_material_layer_addressing(int material_slot) {
	MaterialLayerAddressing addressing;
	addressing.one_shot = false;
	addressing.quarter_turns = material_layer_quarter_turns(material_slot);
	addressing.axis_u = vec3(1.0, 0.0, 0.0);
	addressing.axis_v = vec3(0.0, 1.0, 0.0);
	addressing.normal = vec3(0.0, 0.0, 1.0);
	addressing.palette_scale = vec3(1.0);
	addressing.palette_offset = vec3(0.0);
	return addressing;
}

// Return placement-local addressing for the one-shot shader-decal layer.
MaterialLayerAddressing shader_decal_material_layer_addressing() {
	MaterialLayerAddressing addressing;
	addressing.one_shot = true;
	addressing.quarter_turns = 0;
	addressing.axis_u = normalize(shader_decal_axis_u);
	addressing.axis_v = normalize(shader_decal_axis_v);
	addressing.normal = normalize(shader_decal_normal);
	addressing.palette_scale = shader_decal_palette_scale;
	addressing.palette_offset = shader_decal_palette_offset;
	return addressing;
}

// Sample either the existing repeating projection or one exact non-repeating UV.
vec4 sample_material_layer_raw(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	MaterialLayerAddressing addressing
) {
	if (addressing.one_shot) {
		vec2 texel_inset = 0.5 / max(vec2(textureSize(tex, 0)), vec2(1.0));
		vec2 bounded_uv = clamp(coord, texel_inset, vec2(1.0) - texel_inset);
		return textureGrad(tex, bounded_uv, grad_x, grad_y);
	}
	return sample_projected_fragment_oriented(
		tex, coord, grad_x, grad_y, world_pos, world_normal, repeat_m,
		use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring,
		addressing.quarter_turns
	);
}

// Decode a normal through the same addressing choice and return receiver tangent space.
vec3 sample_material_layer_tangent_normal(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec3 tangent_world,
	vec3 binormal_world,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	MaterialLayerAddressing addressing
) {
	if (!addressing.one_shot) {
		return sample_projected_tangent_normal_oriented(
			tex, coord, grad_x, grad_y, world_pos, world_normal,
			tangent_world, binormal_world, repeat_m,
			use_stochastic_tiling, asset_seed,
			use_random_rotation, use_random_mirroring,
			addressing.quarter_turns
		);
	}
	vec2 texel_inset = 0.5 / max(vec2(textureSize(tex, 0)), vec2(1.0));
	vec2 bounded_uv = clamp(coord, texel_inset, vec2(1.0) - texel_inset);
	// Use the same RG decode as every existing material layer. Godot's imported
	// normal path reconstructs positive Z; treating stored B as authoritative can
	// turn a valid normal inward and blacken the entire stamped region.
	vec3 sampled = decode_sampled_normal(textureGrad(
		tex, bounded_uv, grad_x, grad_y
	).rgb);
	vec3 receiver_normal = normalize(world_normal);
	// UV V runs opposite the placement basis Y, matching the 0.5-local_y mapping.
	// The receiving terrain geometry owns outward Z; placement contributes only
	// the image's in-plane U/V orientation.
	vec3 sampled_world = normalize(
		addressing.axis_u * sampled.x
		- addressing.axis_v * sampled.y
		+ receiver_normal * sampled.z
	);
	return normalize(vec3(
		dot(sampled_world, tangent_world),
		dot(sampled_world, binormal_world),
		dot(sampled_world, receiver_normal)
	));
}

// Return a layer sample that contributes nothing to the composite.
//
// A variant compiled for fewer layers has no uniforms for the layers it dropped,
// so those slots take this instead. Zero coverage and zero painted weight both
// exclude it at composition time, so it cannot tint, light, or occlude anything.
MaterialLayerSample mts_inert_material_layer() {
	MaterialLayerSample layer;
	layer.albedo = vec3(0.0);
	layer.tangent_normal = vec3(0.0, 0.0, 1.0);
	layer.orm = vec3(1.0, 1.0, 0.0);
	layer.height = 0.0;
	layer.emission = vec3(0.0);
	layer.specular = 0.5;
	layer.coverage = 0.0;
	return layer;
}

float material_component(vec4 value, int component) {
	if (component == 0) {
		return value.r;
	}
	if (component == 1) {
		return value.g;
	}
	if (component == 2) {
		return value.b;
	}
	return value.a;
}

int material_int_component(ivec4 value, int component) {
	if (component == 0) {
		return value.r;
	}
	if (component == 1) {
		return value.g;
	}
	if (component == 2) {
		return value.b;
	}
	return value.a;
}

// Return whether a layer can affect this fragment before any texture fetches.
bool material_layer_is_active(bool enabled, bool brush_authored, float painted_weight) {
	return enabled && (!brush_authored || painted_weight > MTS_PAINT_WEIGHT_THRESHOLD);
}

// Test one packed mask-source dependency written by SurfaceMaterialFactory.
bool material_has_dependency(int dependencies, int source) {
	return (dependencies & (1 << source)) != 0;
}

// Return whether one active layer is guaranteed to replace its share with opaque art.
bool material_layer_guarantees_opaque_coat(
	bool brush_authored,
	bool albedo_has_transparency,
	float opacity,
	float height_blend,
	int mask_count
) {
	return (
		brush_authored
		&& !albedo_has_transparency
		&& opacity >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD
		&& height_blend <= MTS_PAINT_WEIGHT_THRESHOLD
		&& mask_count <= 1
	);
}

// Return whether the base coat can contribute visible PBR channels at this fragment.
//
// Normalized splat can omit the base only when painted coverage is full and every
// active layer is an opaque, unconstrained coat. Ordered layering can omit it when
// any such layer fully replaces everything beneath it. Diagnostics deliberately
// retain the base because they inspect the pre-composite material channels.
bool material_base_coat_needed(vec4 painted_weights) {
	if (!terrain_triangle_instances || !material_blend_enabled) {
		return true;
	}
	if (material_debug_view != 0 || material_mask_preview_enabled) {
		return true;
	}
	if (material_blend_mode == 1) {
		if (dot(painted_weights, vec4(1.0)) < 1.0 - MTS_PAINT_WEIGHT_THRESHOLD) {
			return true;
		}
		bool all_active_layers_are_opaque = true;
#if MTS_LAYER_COUNT > 0
		if (material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_0_brush_authored, material_layer_0_albedo_has_transparency, material_layer_0_opacity, material_layer_0_height_blend, material_layer_0_mask_count);
		}
#endif
#if MTS_LAYER_COUNT > 1
		if (material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_1_brush_authored, material_layer_1_albedo_has_transparency, material_layer_1_opacity, material_layer_1_height_blend, material_layer_1_mask_count);
		}
#endif
#if MTS_LAYER_COUNT > 2
		if (material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_2_brush_authored, material_layer_2_albedo_has_transparency, material_layer_2_opacity, material_layer_2_height_blend, material_layer_2_mask_count);
		}
#endif
#if MTS_LAYER_COUNT > 3
		if (material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_3_brush_authored, material_layer_3_albedo_has_transparency, material_layer_3_opacity, material_layer_3_height_blend, material_layer_3_mask_count);
		}
#endif
		return !all_active_layers_are_opaque;
	}
	bool has_full_opaque_layer = false;
#if MTS_LAYER_COUNT > 0
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.r >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_0_brush_authored, material_layer_0_albedo_has_transparency, material_layer_0_opacity, material_layer_0_height_blend, material_layer_0_mask_count));
#endif
#if MTS_LAYER_COUNT > 1
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.g >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_1_brush_authored, material_layer_1_albedo_has_transparency, material_layer_1_opacity, material_layer_1_height_blend, material_layer_1_mask_count));
#endif
#if MTS_LAYER_COUNT > 2
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.b >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_2_brush_authored, material_layer_2_albedo_has_transparency, material_layer_2_opacity, material_layer_2_height_blend, material_layer_2_mask_count));
#endif
#if MTS_LAYER_COUNT > 3
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.a >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_3_brush_authored, material_layer_3_albedo_has_transparency, material_layer_3_opacity, material_layer_3_height_blend, material_layer_3_mask_count));
#endif
	return !has_full_opaque_layer;
}

// Return whether any active mask at this fragment consumes one base/world source.
bool material_base_source_needed(vec4 painted_weights, int source) {
	if (material_mask_preview_enabled) {
		return true;
	}
	bool needed = false;
#if MTS_LAYER_COUNT > 0
	needed = needed || (material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r) && material_has_dependency(material_layer_0_mask_dependencies, source));
#endif
#if MTS_LAYER_COUNT > 1
	needed = needed || (material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g) && material_has_dependency(material_layer_1_mask_dependencies, source));
#endif
#if MTS_LAYER_COUNT > 2
	needed = needed || (material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b) && material_has_dependency(material_layer_2_mask_dependencies, source));
#endif
#if MTS_LAYER_COUNT > 3
	needed = needed || (material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a) && material_has_dependency(material_layer_3_mask_dependencies, source));
#endif
	return needed;
}

// Return whether final mask/height blending needs a second base-height lookup.
bool material_base_height_needed(vec4 painted_weights) {
	if (!has_height) {
		return false;
	}
	if (material_debug_view == 6 || material_mask_preview_enabled || material_base_source_needed(painted_weights, 1)) {
		return true;
	}
	bool needed = false;
#if MTS_LAYER_COUNT > 0
	needed = needed || (material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r) && material_layer_0_has_height && material_layer_0_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
#if MTS_LAYER_COUNT > 1
	needed = needed || (material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g) && material_layer_1_has_height && material_layer_1_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
#if MTS_LAYER_COUNT > 2
	needed = needed || (material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b) && material_layer_2_has_height && material_layer_2_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
#if MTS_LAYER_COUNT > 3
	needed = needed || (material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a) && material_layer_3_has_height && material_layer_3_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
	return needed;
}
