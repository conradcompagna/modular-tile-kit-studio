extends SceneTree

var stage: Node3D
var camera: Camera3D
var environment: Environment
var key_light: DirectionalLight3D
var instance: Node3D

## Start a disposable isolated rendering test without changing an authored board or library.
func _initialize() -> void:
	call_deferred("_diagnose")

## Compare source and native optimized meshes under the same ordinary PBR lighting.
func _diagnose() -> void:
	root.size = Vector2i(1280, 1000)
	stage = Node3D.new()
	root.add_child(stage)
	current_scene = stage
	var world_environment := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.09, 0.09, 0.09)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.35
	world_environment.environment = environment
	stage.add_child(world_environment)
	key_light = DirectionalLight3D.new()
	key_light.light_energy = 1.2
	key_light.rotation_degrees = Vector3(-35, -35, 0)
	key_light.shadow_enabled = false
	stage.add_child(key_light)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	stage.add_child(camera)
	camera.current = true
	var paths := {
		"optimized": "res://tile_library/assets/BW_MESHY_INTERROGATION_FRAME/derived/runtime_optimized.glb",
		"source": "res://tile_library/assets/BW_MESHY_INTERROGATION_FRAME/source/interrogation_frame.glb"
	}
	for key: String in paths:
		instance = load(paths[key]).instantiate()
		stage.add_child(instance)
		instance.scale = Vector3.ONE * 1.565446
		instance.position = Vector3(12.002,3.136202,18.49039)
		var bounds: AABB = _bounds(instance)
		var center: Vector3 = bounds.get_center()
		var extent: float = bounds.size.length()
		camera.size = extent * 0.95
		camera.position = center + Vector3(0.9, 0.5, 1.1).normalized() * extent * 3.0
		camera.look_at(center, Vector3.UP)
		print("ISOLATED " + key + " bounds=" + str(bounds))
		camera.size = 11.0
		camera.position = Vector3(20.5,5.4,30)
		camera.look_at(Vector3(12.5,2.4,21),Vector3.UP)
		var green := OmniLight3D.new()
		green.position = Vector3(12.5,3.0,19.0)
		green.light_color = Color(0.26,0.72,0.4)
		green.light_energy = 5.0
		green.omni_range = 6.0
		green.omni_attenuation = 1.4
		green.shadow_enabled = false
		stage.add_child(green)
		environment.ambient_light_color = Color(0.2,0.27,0.36)
		environment.ambient_light_energy = 0.32
		key_light.rotation_degrees = Vector3(-58,-35,0)
		key_light.light_energy = 0.72
		await _capture("isolated_pose_" + key + "_green")
		green.visible = false
		await _capture("isolated_pose_" + key + "_sun")
		green.queue_free()
		environment.ambient_light_color = Color.WHITE
		environment.ambient_light_energy = 0.35
		key_light.visible = true
		await _capture("isolated_" + key + "_pbr")
		for mesh: MeshInstance3D in instance.find_children("*", "MeshInstance3D", true, false):
			print("MESH " + str(mesh.get_path()) + " determinant=" + str(mesh.global_basis.determinant()) + " surfaces=" + str(mesh.mesh.get_surface_count()))
			for i: int in mesh.mesh.get_surface_count():
				var original: BaseMaterial3D = mesh.get_active_material(i) as BaseMaterial3D
				var mat: BaseMaterial3D = original.duplicate()
				mat.normal_enabled = false
				mat.ao_enabled = false
				mesh.set_surface_override_material(i, mat)
		await _capture("isolated_" + key + "_no_normal")
		for mesh: MeshInstance3D in instance.find_children("*", "MeshInstance3D", true, false):
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.55, 0.55, 0.55)
			mat.roughness = 1.0
			mat.metallic_specular = 0.0
			mesh.material_override = mat
		await _capture("isolated_" + key + "_clay")
		key_light.visible = false
		environment.ambient_light_energy = 1.0
		await _capture("isolated_" + key + "_ambient")
		instance.queue_free()
		await process_frame
	print("BQ_ISOLATED_DIAGNOSTIC_COMPLETE")
	quit()

## Measure imported world-space geometry so both source versions use equivalent framing.
func _bounds(node: Node3D) -> AABB:
	var result: AABB
	var initialized: bool = false
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		var item: AABB = mesh.global_transform * mesh.get_aabb()
		if initialized:
			result = result.merge(item)
		else:
			result = item
			initialized = true
	return result

## Write an isolated rendered comparison after temporal rendering has settled.
func _capture(label: String) -> void:
	await create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://captures/blackridge_quarantine/" + label + ".png")
