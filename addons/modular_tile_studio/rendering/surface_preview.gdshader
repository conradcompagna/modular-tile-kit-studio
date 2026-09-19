shader_type spatial;

// The paint/fill overlay is an orientation readout, not board lighting. It
// reproduces the committed renderer's tested front-side convention for both
// horizontal tiles and vertical side cards.
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_mix;

uniform sampler2D preview_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_albedo = false;
uniform vec4 preview_tint : source_color = vec4(1.0);

const float BACKFACE_BRIGHTNESS = 0.18;

varying vec3 authored_front_world;

// Preserve the source mesh normal before rasterization classifies triangle winding.
void vertex() {
	authored_front_world = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

// Darken the camera-visible side that the committed renderer treats as the back.
void fragment() {
	// Missing art is handled as an explicit magenta diagnostic by the caller;
	// it never substitutes a different asset or material source.
	vec4 sampled = has_albedo ? texture(preview_albedo, UV) : vec4(1.0);
	vec3 toward_camera_world = normalize(INV_VIEW_MATRIX[2].xyz);
	float camera_dot = dot(authored_front_world, toward_camera_world);

	// Horizontal +Y/-Y cards use the mesh-normal side directly. Godot's
	// committed two-sided wall rendering exposes the opposite side for all four
	// vertical orientations, so mirror that same convention in the overlay.
	float horizontal_surface = step(0.5, abs(authored_front_world.y));
	float committed_front_score = mix(-camera_dot, camera_dot, horizontal_surface);
	float facing_brightness = committed_front_score >= 0.0
		? 1.0
		: BACKFACE_BRIGHTNESS;
	ALBEDO = sampled.rgb * preview_tint.rgb * facing_brightness;
	ALPHA = sampled.a * preview_tint.a;
}
