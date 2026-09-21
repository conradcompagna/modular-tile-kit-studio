extends SceneTree

## Confirm the canonical surface shader still parses and keeps its uniform surface.
##
## A shader with a syntax error does not fail loudly at runtime -- it silently
## renders flat colour -- so an explicit parse plus uniform count is the cheap
## check that a shader edit did not quietly break every terrain material.

const SHADER_PATH := "res://addons/modular_tile_studio/rendering/mts_surface_gpu.gdshader"


## Defer so resource loading happens with the tree already available.
func _init() -> void:
	_run.call_deferred()


## Load the shader and report its uniform count and required alpha tokens.
func _run() -> void:
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		print("FAIL  shader did not load at all")
		quit(1)
		return

	var uniforms := shader.get_shader_uniform_list()
	print("UNIFORM_COUNT=%d" % uniforms.size())

	# The factory rewrites these exact tokens to build its alpha variants, so a
	# rename here would break OPAQUE and BLEND while leaving CUTOUT working.
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	for token: String in [
		"ALPHA = albedo_sample.a;",
		"ALPHA_SCISSOR_THRESHOLD = alpha_scissor;",
		"render_mode cull_disabled,",
		"float coverage;",
		"layer_weights.r *= layer_0.coverage;",
	]:
		print("%-46s %s" % [token, "present" if source.contains(token) else "MISSING"])
	quit()
