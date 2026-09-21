extends SceneTree

const Fixture := preload("res://tests/fixtures/public_board.gd")
var failures := 0


func _init() -> void:
	_run.call_deferred()


## Render all alpha contracts with and without variation at 0, 1, and 4 layers.
## This requires a real renderer; the dummy headless driver cannot verify pixels.
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("shader_render_check requires a display and GPU/software renderer.")
		quit(1)
		return
	var view := SubViewport.new()
	view.size = Vector2i(960, 540)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var world := Node3D.new()
	view.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.035, 0.045, 0.065)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.8
	world.add_child(environment)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 5.2
	world.add_child(camera)
	camera.position = Vector3(3.25, 10, 1.3)
	camera.rotation_degrees.x = -90
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-70, -20, 0)
	world.add_child(light)
	var library := Fixture.library()
	var asset := library.get_asset("FIXTURE_STONE")
	var factory := SurfaceMaterialFactory.new()
	var canonical := factory.get_material(asset) as ShaderMaterial
	var positions: Array[Vector3] = []
	var index := 0
	for alpha: int in [TileAsset.SurfaceAlphaMode.OPAQUE, TileAsset.SurfaceAlphaMode.CUTOUT, TileAsset.SurfaceAlphaMode.BLEND]:
		for variation: bool in [false, true]:
			for layers: int in [0, 1, 4]:
				var material := canonical.duplicate() as ShaderMaterial
				material.shader = factory._surface_shader(alpha, variation, layers, false)
				_check(material.shader != null, "variant source builds")
				var mesh := MeshInstance3D.new()
				var plane := PlaneMesh.new()
				plane.size = Vector2(1.1, 1.1)
				mesh.mesh = plane
				mesh.material_override = material
				mesh.position = Vector3((index % 6) * 1.3, 0, (index / 6) * 1.3)
				positions.append(mesh.position)
				world.add_child(mesh)
				index += 1
	for _frame in 6:
		RenderingServer.force_draw(false, 1.0 / 60.0)
		await process_frame
	var image := view.get_texture().get_image()
	_check(image != null and not image.is_empty(), "renderer returns an image")
	if image != null and not image.is_empty():
		var background := image.get_pixel(0, 0)
		for position: Vector3 in positions:
			var center := camera.unproject_position(position)
			var visible_pixels := 0
			for y in range(-20, 21, 4):
				for x in range(-20, 21, 4):
					var pixel := image.get_pixel(int(center.x) + x, int(center.y) + y)
					if Vector3(pixel.r, pixel.g, pixel.b).distance_to(Vector3(background.r, background.g, background.b)) > 0.1:
						visible_pixels += 1
			_check(visible_pixels > 20, "each shader variant draws visible textured pixels")
		for argument: String in OS.get_cmdline_user_args():
			if argument.begins_with("--image="):
				_check(image.save_png(argument.trim_prefix("--image=")) == OK, "render artifact saves")
	view.queue_free()
	await process_frame
	print("Shader render: %d variants; %d failures" % [positions.size(), failures])
	_finish.call_deferred(1 if failures else 0)


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error(label)


func _finish(code: int) -> void:
	quit(code)
