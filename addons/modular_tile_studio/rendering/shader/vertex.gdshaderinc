// -----------------------------------------------------------------------------
// Vertex stage
// -----------------------------------------------------------------------------

void vertex() {
	// world_vertex_coords presents this entire authored frame in world space.
	// Transforming it through MODEL_MATRIX again applies each terrain triangle's
	// affine instance transform twice and makes adjacent halves shade differently.
	vec3 base_world = VERTEX;
	vec3 base_normal_world = normalize(NORMAL);
	vec3 tangent_world = normalize(TANGENT);
	vec3 binormal_world = normalize(BINORMAL);
	v_camera_position_world = CAMERA_POSITION_WORLD;

	// Terrain-specific UV and world-point data is indexed by MultiMesh INSTANCE_ID.
	// Terrain keeps one canonical heightfield geometry; all relief is material-only.
	v_surface_uv = UV;
	v_terrain_barycentric = vec3(0.0);
	v_terrain_boundary_mask = 0.0;
	v_texture_quarters = 0.0;
	v_material_texture_quarters = vec4(0.0);
	// Non-terrain surface assets have no face classification and retain the full
	// material-control path if blending is explicitly enabled on them.
	v_material_control_class = 2.0;
	v_material_uniform_slot = 0.0;
	if (terrain_triangle_instances) {
		int row_width = max(terrain_instance_data_width, 1);
		int data_base = INSTANCE_ID * 6;
		ivec2 data_coord_0 = ivec2(data_base % row_width, data_base / row_width);
		ivec2 data_coord_1 = ivec2((data_base + 1) % row_width, (data_base + 1) / row_width);
		ivec2 data_coord_2 = ivec2((data_base + 2) % row_width, (data_base + 2) / row_width);
		ivec2 data_coord_3 = ivec2((data_base + 3) % row_width, (data_base + 3) / row_width);
		ivec2 data_coord_4 = ivec2((data_base + 4) % row_width, (data_base + 4) / row_width);
		ivec2 data_coord_5 = ivec2((data_base + 5) % row_width, (data_base + 5) / row_width);
		vec4 terrain_uv_data_0 = texelFetch(terrain_instance_data_tex, data_coord_0, 0);
		vec4 terrain_uv_data_1 = texelFetch(terrain_instance_data_tex, data_coord_1, 0);
		vec3 world_point_0 = texelFetch(terrain_instance_data_tex, data_coord_2, 0).xyz;
		vec3 world_point_1 = texelFetch(terrain_instance_data_tex, data_coord_3, 0).xyz;
		vec3 world_point_2 = texelFetch(terrain_instance_data_tex, data_coord_4, 0).xyz;
		v_material_texture_quarters = texelFetch(terrain_instance_data_tex, data_coord_5, 0);
		v_terrain_boundary_mask = terrain_uv_data_1.z;
		// The painting placement's quarter turn rides in this texel's spare
		// channel, so a rotation never changes the per-instance data size.
		v_texture_quarters = terrain_uv_data_1.w;
		v_terrain_barycentric = vec3(1.0 - UV.x - UV.y, UV.x, UV.y);
		// Derive material projection from canonical world vertices rather than
		// VERTEX, whose MultiMesh transform stage is renderer implementation detail.
		base_world = (
			world_point_0 * v_terrain_barycentric.x
			+ world_point_1 * v_terrain_barycentric.y
			+ world_point_2 * v_terrain_barycentric.z
		);
		vec3 triangle_normal = cross(
			world_point_1 - world_point_0,
			world_point_2 - world_point_0
		);
		if (dot(triangle_normal, triangle_normal) > 0.0) {
			// Projection follows the actual sloped triangle instead of flattening
			// texture features to a cardinal heightfield direction.
			base_normal_world = normalize(triangle_normal);
		}
		v_surface_uv = (
			terrain_uv_data_0.xy
			+ UV.x * terrain_uv_data_0.zw
			+ UV.y * terrain_uv_data_1.xy
		);
		// Build the slope-aware frame used for lighting and normal-map conversion.
		if (abs(base_normal_world.y) > 0.9999) {
			tangent_world = vec3(1.0, 0.0, 0.0);
			binormal_world = vec3(0.0, 0.0, -sign(base_normal_world.y));
		} else {
			tangent_world = normalize(cross(vec3(0.0, 1.0, 0.0), base_normal_world));
			binormal_world = normalize(cross(base_normal_world, tangent_world));
		}
	}

	v_base_world_pos = base_world;
	v_base_normal_world = base_normal_world;
	v_tangent_world = tangent_world;
	v_binormal_world = binormal_world;
	// Two normalized color bytes address up to 65,536 sparse surface layers.
	v_material_control_layer = floor(COLOR.r * 255.0 + 0.5) + floor(COLOR.g * 255.0 + 0.5) * 256.0;
	// Blue carries three exact classification states; alpha carries a 0..3 slot.
	v_material_control_class = floor(COLOR.b * 2.0 + 0.5);
	v_material_uniform_slot = floor(COLOR.a * 3.0 + 0.5);

	// Retain a surface-local metric coordinate only for non-terrain surface assets.
	// Terrain samplers ignore this coordinate and use the canonical world point,
	// so no triangle-local frame can reset the map-wide material field.
	vec2 period_m = safe_size(surface_size_m) * max(mts_stochastic_scale, 0.0001);
	vec2 metric_m = vec2(dot(base_world, tangent_world), dot(base_world, binormal_world));
	v_metric_uv = metric_m / period_m;
	v_world_pos = base_world;
}

// -----------------------------------------------------------------------------
// Tangent-frame helpers
// -----------------------------------------------------------------------------

// Derive the tangent frame from the canonical terrain world positions. Parallax
// offsets texture sampling only, so lighting remains attached to real geometry.
void surface_tangent_frame(vec2 coord, out vec3 tangent_ws, out vec3 binormal_ws, out vec3 normal_ws) {
	vec3 dpdx = dFdx(v_world_pos);
	vec3 dpdy = dFdy(v_world_pos);
	vec2 dtdx = dFdx(coord);
	vec2 dtdy = dFdy(coord);

	float determinant = dtdx.x * dtdy.y - dtdx.y * dtdy.x;
	if (abs(determinant) < 0.0000001) {
		tangent_ws = normalize(v_tangent_world);
		binormal_ws = normalize(v_binormal_world);
		normal_ws = normalize(cross(tangent_ws, binormal_ws));
	} else {
		float inv_det = 1.0 / determinant;
		tangent_ws = normalize((dpdx * dtdy.y - dpdy * dtdx.y) * inv_det);
		binormal_ws = normalize((-dpdx * dtdy.x + dpdy * dtdx.x) * inv_det);
		normal_ws = normalize(cross(tangent_ws, binormal_ws));
	}

	// Keep the generated frame on the same side as the authored surface. A
	// visible back face intentionally retains the opposite lighting direction
	// so an upside-down placement is obvious instead of silently corrected.
	if (dot(normal_ws, normalize(v_base_normal_world)) < 0.0) {
		normal_ws = -normal_ws;
		binormal_ws = -binormal_ws;
	}
}
