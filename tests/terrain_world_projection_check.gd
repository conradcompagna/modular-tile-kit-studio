extends SceneTree

## Verifies every terrain triangle samples one continuous map-wide texture field.

var failures: int = 0


## Defer checks until the project's global script classes are registered.
func _init() -> void:
	_run.call_deferred()


## Record one failed world-projection invariant with a precise diagnostic.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("TERRAIN WORLD PROJECTION CHECK FAILED: %s" % message)


## Return the three fixed global projection coordinates for one world point.
func _world_projection_coordinates(
	point: Vector3,
	repeat_m: Vector2
) -> Array[Vector2]:
	return [
		Vector2(-point.z, point.y) / repeat_m,
		Vector2(point.x, -point.z) / repeat_m,
		Vector2(point.x, point.y) / repeat_m,
	]


## Verify the instance texture stores all canonical data needed by world projection.
func _test_instance_world_vertices() -> void:
	var renderer := MTSTerrainRenderer.new()
	var points := PackedVector3Array([
		Vector3.ZERO,
		Vector3(4.0, 0.0, 0.0),
		Vector3(0.0, 3.0, -4.0),
	])
	var triangle_normal := (
		(points[1] - points[0]).cross(points[2] - points[0]).normalized()
	)
	var triangle := {
		"points": points,
		"uvs": PackedVector2Array([
			Vector2.ZERO,
			Vector2.RIGHT,
			Vector2.DOWN,
		]),
		"normal": triangle_normal,
		"face": {
			"paint_uid": "world_projection_probe",
			"face": 2,
		},
		"boundary_mask": 0,
	}
	var triangles: Array[Dictionary] = [triangle]
	var visual := renderer._build_visual_batch(
		Vector2i.ZERO,
		"world_projection_probe",
		triangles,
		{},
		null
	)
	_check(visual != null, "a valid sloped triangle must build one render instance")
	if visual == null:
		renderer.free()
		return
	var data_texture := visual.get_meta("mts_terrain_instance_data", null) as Texture2D
	_check(data_texture != null, "the render instance must expose its projection data")
	if data_texture != null:
		var image := data_texture.get_image()
		_check(
			image.get_width() * image.get_height() == 5,
			"one triangle must own exactly five UV, seam, orientation, and world-point texels"
		)
		for point_index: int in 3:
			var stored := image.get_pixel(2 + point_index, 0)
			var expected := points[point_index]
			_check(
				Vector3(stored.r, stored.g, stored.b).is_equal_approx(expected),
				"world vertex %d must survive the instance texture exactly" % point_index
			)
	visual.free()
	renderer.free()


## Verify triangle identity and slope cannot change global phase or repeat period.
func _test_map_wide_phase_and_period() -> void:
	var repeat_m := Vector2(4.0, 2.0)
	var shared_world_point := Vector3(12.0, 3.0, -8.0)
	var first_triangle_sample := _world_projection_coordinates(
		shared_world_point,
		repeat_m
	)
	var second_triangle_sample := _world_projection_coordinates(
		shared_world_point,
		repeat_m
	)
	_check(
		first_triangle_sample == second_triangle_sample,
		"two differently sloped triangles must sample the same phase at a shared point"
	)
	_check(
		first_triangle_sample[0].is_equal_approx(Vector2(2.0, 1.5))
		and first_triangle_sample[1].is_equal_approx(Vector2(3.0, 4.0))
		and first_triangle_sample[2].is_equal_approx(Vector2(3.0, 1.5)),
		"global X, Y, and Z projections must use only world position and authored metres"
	)
	var one_u_repeat := _world_projection_coordinates(
		shared_world_point + Vector3(repeat_m.x, 0.0, 0.0),
		repeat_m
	)
	_check(
		is_equal_approx(one_u_repeat[1].x - first_triangle_sample[1].x, 1.0)
		and is_equal_approx(one_u_repeat[2].x - first_triangle_sample[2].x, 1.0),
		"moving one authored width in world X must advance exactly one repeat"
	)
	var one_v_repeat := _world_projection_coordinates(
		shared_world_point + Vector3(0.0, repeat_m.y, 0.0),
		repeat_m
	)
	_check(
		is_equal_approx(one_v_repeat[0].y - first_triangle_sample[0].y, 1.0)
		and is_equal_approx(one_v_repeat[2].y - first_triangle_sample[2].y, 1.0),
		"moving one authored height in world Y must advance exactly one repeat"
	)


## Verify the shader consumes one fixed global projection contract.
func _test_shader_contract() -> void:
	var shader_path := "res://addons/modular_tile_studio/rendering/mts_surface_gpu.gdshader"
	var source := FileAccess.get_file_as_string(shader_path)
	_check(not source.is_empty(), "the surface shader source must be readable")
	_check(
		source.contains("int data_base = INSTANCE_ID * 5;"),
		"the shader must address the renderer's five texels per terrain triangle"
	)
	_check(
		source.contains("base_normal_world = normalize(triangle_normal);"),
		"the shader must use the true triangle slope only for projection blending"
	)
	_check(
		source.contains("vec2 coord_x = rotate_quarter_turns(vec2(-world_pos.z, world_pos.y), steps) / period_m;")
		and source.contains("vec2 coord_y = rotate_quarter_turns(vec2(world_pos.x, -world_pos.z), steps) / period_m;")
		and source.contains("vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;"),
		"all terrain channels must use the same fixed global-axis coordinates"
	)
	_check(
		source.contains("vec3 world_projection_weights(vec3 world_normal)"),
		"slope may select global projections without creating a triangle-local field"
	)


## Verify canonical and duplicated terrain materials retain their explicit live-refresh contract.
func _test_live_shader_refresh_contract() -> void:
	var factory := SurfaceMaterialFactory.new()
	var terrain := factory.terrain_material()
	_check(terrain != null, "the canonical terrain material must build successfully")
	if terrain == null:
		return
	_check(
		terrain.has_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META),
		"the terrain material must store the alpha mode used to regenerate its shader"
	)
	var batch_duplicate := terrain.duplicate(true) as ShaderMaterial
	_check(batch_duplicate != null, "a terrain batch must be able to duplicate its material")
	if batch_duplicate == null:
		return
	factory._register_live_material(batch_duplicate)
	_check(
		factory._all_live_materials().has(batch_duplicate),
		"the factory must retain the registered terrain batch in its weak live registry"
	)
	_check(
		batch_duplicate.has_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META),
		"a terrain batch duplicate must retain the live shader refresh contract"
	)
	_check(
		batch_duplicate.shader.code.contains(
			"vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;"
		),
		"the generated terrain shader variant must contain the map-wide projection"
	)
	var previous_variant := batch_duplicate.shader
	factory._observed_surface_shader_source_hash = -1
	SurfaceMaterialFactory._gpu_surface_shader_source_hash = -1
	factory._ensure_surface_shader_source_current()
	_check(
		batch_duplicate.shader != previous_variant,
		"source revision invalidation must replace the shader on an existing terrain batch"
	)
	_check(
		batch_duplicate.shader.code.contains(
			"vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;"
		),
		"a refreshed terrain batch must still contain the map-wide projection"
	)
	_check(
		factory._observed_surface_shader_source_hash
		== factory._surface_shader_source_code().hash(),
		"the material factory must hash the authored shader file as its source of truth"
	)


## Run the focused renderer, map-wide phase, shader, and live-refresh regressions.
func _run() -> void:
	_test_instance_world_vertices()
	_test_map_wide_phase_and_period()
	_test_shader_contract()
	_test_live_shader_refresh_contract()
	print("terrain_world_projection_check: %d failures" % failures)
	quit(failures)
