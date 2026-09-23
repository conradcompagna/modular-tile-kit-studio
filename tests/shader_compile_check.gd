extends SceneTree

## Confirm the canonical surface shader still parses and keeps its uniform surface.
##
## A shader with a syntax error does not fail loudly at runtime -- it silently
## renders flat colour -- so an explicit parse plus uniform count is the cheap
## check that a shader edit did not quietly break every terrain material.

const SHADER_PATH := "res://addons/modular_tile_studio/rendering/mts_surface_gpu.gdshader"
const ShaderSource := preload("res://addons/modular_tile_studio/rendering/shader_source.gd")
const ORIGINAL_SOURCE_SHA256 := "5632080daebe2830f69cdc0328460757aefd7be29eb1a5d23920a2f76faddd40"


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
	var source := ShaderSource.read_expanded(SHADER_PATH)
	var failed := false
	# These includes are a lossless extraction of the original authored shader.
	if source.replace("\r\n", "\n").sha256_text() != ORIGINAL_SOURCE_SHA256:
		push_error("Expanded shader differs from the pre-refactor source contract.")
		failed = true
	for token: String in [
		"ALPHA = albedo_sample.a;",
		"ALPHA_SCISSOR_THRESHOLD = alpha_scissor;",
		"render_mode cull_disabled,",
		"float coverage;",
		"layer_weights.r *= layer_0.coverage;",
	]:
		print("%-46s %s" % [token, "present" if source.contains(token) else "MISSING"])
		if not source.contains(token):
			failed = true
	# Exercise nested source edits without modifying any project shader.
	var directory := "user://shader_source_check"
	DirAccess.make_dir_recursive_absolute(directory)
	var entry_path := directory.path_join("fixture.gdshader")
	var included_path := directory.path_join("nested.gdshaderinc")
	_write(entry_path, '#include "nested.gdshaderinc"\n')
	_write(included_path, "float fixture = 1.0;\n")
	var first_source := ShaderSource.read_expanded(entry_path)
	_write(included_path, "float fixture = 2.0;\n")
	var second_source := ShaderSource.read_expanded(entry_path)
	if first_source.hash() == second_source.hash() or not second_source.contains("2.0"):
		push_error("Included shader edits did not change the expanded cache source.")
		failed = true
	DirAccess.remove_absolute(entry_path)
	DirAccess.remove_absolute(included_path)
	DirAccess.remove_absolute(directory)
	quit(1 if failed else 0)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
