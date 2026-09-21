vec2 world_rect_uv(vec2 world_xz, vec4 rect) {
	vec2 size_m = max(abs(rect.zw), vec2(0.0001));
	return (world_xz - rect.xy) / size_m;
}

bool uv_inside_01(vec2 uv) {
	return uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0;
}

vec4 sample_interaction_fragment(vec2 world_xz) {
	if (!mts_interaction_enabled) {
		return vec4(0.0);
	}
	vec2 uv = world_rect_uv(world_xz, g_interaction_rect);
	if (!uv_inside_01(uv)) {
		return vec4(0.0);
	}
	return texture(g_interaction_tex, uv);
}
