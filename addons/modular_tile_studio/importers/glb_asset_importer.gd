@tool
class_name GLBAssetImporter
extends RefCounted

## Full GLB prop pipeline.
##
##   GLB -> raw bounds -> grid-first sizing plan -> canonical Y-up pose -> voxelize (collision) -> TileAsset -> library
##
## The source GLB is copied in and never modified, and it stays on disk so a
## rebuild can always start from truth rather than from a previous derivation,
## and so it can be loaded fresh and placed as real geometry at runtime
## (MTSStudioViewport._build_prop_node). There is no rendered/shelled
## representation any more: a placed prop IS the source mesh, posed and oriented
## only by its editor placement, shadowed and occluded by Godot's own 3D pipeline. The only
## thing derived and persisted here is the 1 m voxel proxy used for collision.

const K := preload("../utils/mts_constants.gd")
const Canonicalizer := preload("glb_canonicalizer.gd")
const Proxy := preload("proxy_generator.gd")
const RuntimeOptimizer := preload("glb_runtime_optimizer.gd")

var canonicalizer := Canonicalizer.new()
var proxy_generator := Proxy.new()
var runtime_optimizer := RuntimeOptimizer.new()


## Load a GLB into the same MeshInstance3D hierarchy used by the rest of the pipeline.
##
## External files need GLTFDocument only during their first inspection. Once an
## asset lives at res://, Godot's normal importer owns it and this function
## instantiates the imported PackedScene instead of reparsing the source file.
func load_model(source_path: String) -> Node3D:
	if source_path.begins_with("res://"):
		return _load_project_model(source_path)
	return _load_external_model(source_path)


## Instantiate one project-owned GLB through Godot's normal imported PackedScene.
func _load_project_model(source_path: String) -> Node3D:
	var packed_scene := ResourceLoader.load(source_path, "PackedScene") as PackedScene
	if packed_scene == null:
		push_error(
			"[Tile Studio] Godot could not load project GLB '%s' as an imported PackedScene."
			% source_path
		)
		return null
	var scene := packed_scene.instantiate() as Node3D
	if scene == null:
		push_error(
			"[Tile Studio] Godot imported GLB '%s' but did not produce a Node3D scene."
			% source_path
		)
		return null
	return scene


## Decode an external GLB only long enough to calculate its initial canonical asset data.
func _load_external_model(source_path: String) -> Node3D:
	var global_path := ProjectSettings.globalize_path(source_path)
	if not FileAccess.file_exists(global_path):
		global_path = source_path
	if not FileAccess.file_exists(global_path):
		push_error("[Tile Studio] GLB not found: %s" % source_path)
		return null

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(global_path, state)
	if err != OK:
		push_error("[Tile Studio] could not read GLB '%s' (%s)" % [source_path, error_string(err)])
		return null
	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		push_error("[Tile Studio] GLB '%s' did not generate a Node3D scene." % source_path)
		return null
	# Normalise the external scene at the ingestion boundary. GLTFDocument
	# yields ImporterMeshInstance3D nodes, while bounds and voxelization operate
	# on MeshInstance3D. Project-owned files never take this path.
	_convert_importer_meshes(scene)
	return scene


## Replace ImporterMeshInstance3D nodes with real MeshInstance3D nodes in place.
func _convert_importer_meshes(node: Node) -> void:
	for child in node.get_children():
		_convert_importer_meshes(child)

	if not node.is_class("ImporterMeshInstance3D"):
		return
	var parent := node.get_parent()
	if parent == null:
		return

	var replacement := MeshInstance3D.new()
	replacement.name = node.name
	var source_3d := node as Node3D
	if source_3d != null:
		replacement.transform = source_3d.transform
		replacement.visible = source_3d.visible

	var importer_mesh: Variant = node.get("mesh")
	if importer_mesh != null and importer_mesh.has_method("get_mesh"):
		replacement.mesh = importer_mesh.get_mesh()
	var skin: Variant = node.get("skin")
	if skin != null:
		replacement.skin = skin

	# Carry any surface material overrides across.
	if replacement.mesh != null:
		for surface in replacement.mesh.get_surface_count():
			var material := replacement.mesh.surface_get_material(surface)
			if material != null:
				replacement.set_surface_override_material(surface, material)

	# Move the converted node's children over before swapping it in.
	for child in node.get_children():
		node.remove_child(child)
		replacement.add_child(child)

	var index := node.get_index()
	parent.remove_child(node)
	parent.add_child(replacement)
	parent.move_child(replacement, index)
	node.queue_free()


## Inspect a GLB without importing it, for the import dialog's size fields.
func inspect(source_path: String) -> Dictionary:
	var model := load_model(source_path)
	if model == null:
		return {}
	var bounds := canonicalizer.compute_bounds(model)
	var info := {
		"bounds": bounds,
		"size": bounds.size,
		"suggested_grid": canonicalizer.suggest_grid_bounds(bounds.size),
	}
	info.merge(runtime_optimizer.inspect_scene(model), true)
	model.queue_free()
	return info


## Compute the canonical prop pose and voxelize it for collision.
##
## The pose is pure geometry (scale plus centering, with no placement rotation).
## PropPlacement applies its selected complete orientation to this same pose at
## placement time, so no alternate facing artifacts are built here.
##
## TWO scans are taken, because a right angle maps the cubic lattice onto itself
## and 45 degrees does not:
##
##   canonical (0 deg)  -> every cardinal heading, by right-angle turns
##   diagonal  (45 deg) -> every diagonal heading, by right-angle turns
##
## Deriving the diagonal case from the canonical scan instead means rotating loose
## cubes and reserving each one's axis-aligned overlap, which claimed roughly twice
## the volume the mesh really fills. One extra scan removes that guess entirely, and
## it is paid here at import rather than anywhere near the authoring loop.
func _build_prop_geometry(
	model: Node3D,
	raw_bounds: AABB,
	plan: Dictionary
) -> Dictionary:

	var grid_bounds: Vector3i = plan["grid_size"]
	var scale: Vector3 = plan["scale"]

	var pose: Dictionary = canonicalizer.compute_pose(raw_bounds, scale, grid_bounds)
	var transform: Transform3D = pose["transform"]

	var voxel_report := proxy_generator.voxelize_report(
		model,
		transform,
		grid_bounds
	)
	var voxels: Array[Vector3i] = []
	voxels.assign(voxel_report.get("voxels", []))
	if voxels.is_empty():
		return {
			"ok": false,
			"error": "canonical voxel scan found no occupied cells in its grid box",
		}

	# The diagonal scan uses exactly the transform a diagonal placement poses the
	# real mesh with, so the measured cells are the cells the artwork stands in.
	var diagonal_pose: Dictionary = K.diagonal_scan_orientation()
	var diagonal_transform: Transform3D = K.prop_box_transform(
		grid_bounds,
		int(diagonal_pose["forward_face"]),
		int(diagonal_pose["roll_quarters"]),
		int(diagonal_pose["yaw_eighths"])
	) * transform
	var diagonal_voxel_report := proxy_generator.voxelize_report(
		model,
		diagonal_transform,
		K.diagonal_scan_bounds(grid_bounds)
	)
	var diagonal_voxels: Array[Vector3i] = []
	diagonal_voxels.assign(diagonal_voxel_report.get("voxels", []))
	if diagonal_voxels.is_empty():
		return {
			"ok": false,
			"error": "45-degree voxel scan found no occupied cells in its grid box",
		}

	return {
		"ok": true,
		"pose": pose,
		"voxels": voxels,
		"voxel_triangle_shares_percent": voxel_report.get(
			"triangle_shares_percent",
			PackedFloat32Array()
		),
		"diagonal_voxels": diagonal_voxels,
		"diagonal_voxel_triangle_shares_percent": diagonal_voxel_report.get(
			"triangle_shares_percent",
			PackedFloat32Array()
		),
		"collision_triangle_count": int(voxel_report.get("triangle_count", 0)),
	}



## Render a lit square thumbnail from the canonical GLB pose.
## The model stays the source of truth: this image is only a library presentation
## artifact, and the same source mesh remains responsible for runtime rendering.
func _render_thumbnail(
	model: Node3D,
	pose_transform: Transform3D,
	output_size: int = 128
) -> Image:
	if model == null:
		return null
	if DisplayServer.get_name() == "headless":
		push_error("[Tile Studio] GLB thumbnails require the graphical editor renderer")
		return null

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		push_error("[Tile Studio] GLB thumbnail needs an active editor SceneTree")
		return null

	var viewport := SubViewport.new()
	viewport.size = Vector2i(output_size, output_size)
	viewport.transparent_bg = false
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	tree.root.add_child(viewport)

	var scene_root := Node3D.new()
	viewport.add_child(scene_root)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.07, 0.08, 0.11, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.65, 0.68, 0.75)
	environment.ambient_light_energy = 0.9
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene_root.add_child(world_environment)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-50, -35, 0)
	key_light.light_energy = 1.4
	key_light.shadow_enabled = false
	scene_root.add_child(key_light)

	var pivot := Node3D.new()
	pivot.transform = pose_transform
	scene_root.add_child(pivot)

	var original_parent: Node = model.get_parent()
	if original_parent != null:
		original_parent.remove_child(model)
	pivot.add_child(model)

	var actual_bounds := _render_bounds(pivot)
	if actual_bounds.size.length() <= 0.0001:
		_restore_thumbnail_scene(viewport, pivot, model, original_parent)
		push_error("[Tile Studio] GLB thumbnail has no renderable mesh")
		return null

	var frame_world := maxf(actual_bounds.size.length(), 0.25) * 1.15
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = frame_world
	camera.near = 0.01
	camera.far = 1000.0
	scene_root.add_child(camera)
	camera.position = (
		actual_bounds.get_center()
		+ K.ISO_CAMERA_DIRECTION.normalized() * (frame_world * 4.0 + 5.0)
	)
	camera.look_at(actual_bounds.get_center(), Vector3.UP)
	camera.current = true

	await tree.process_frame
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image: Image = null
	var texture := viewport.get_texture()
	if texture != null:
		image = texture.get_image()
	if image == null or image.is_empty():
		_restore_thumbnail_scene(viewport, pivot, model, original_parent)
		push_error("[Tile Studio] GLB thumbnail render returned an empty image")
		return null

	_restore_thumbnail_scene(viewport, pivot, model, original_parent)
	return image


## Calculate the bounds of the actual mesh hierarchy in the thumbnail scene.
## Measuring the rendered hierarchy avoids blank thumbnails caused by assuming
## the imported root is already centred at the origin.
func _render_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var found := false
	for mesh_instance: MeshInstance3D in _all_meshes(root):
		if mesh_instance.mesh == null:
			continue
		var mesh_bounds := mesh_instance.get_aabb()
		if mesh_instance.is_inside_tree():
			mesh_bounds = mesh_instance.global_transform * mesh_bounds
		else:
			mesh_bounds = mesh_instance.transform * mesh_bounds
		if not found:
			bounds = mesh_bounds
			found = true
		else:
			bounds = bounds.merge(mesh_bounds)
	return bounds


## Collect every mesh instance in the imported hierarchy for bounds measurement.
func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		meshes.append(mesh_instance)
	for child in node.get_children():
		meshes.append_array(_all_meshes(child))
	return meshes


## Detach the temporary thumbnail scene while leaving the source model for the
## caller to dispose or continue processing.
func _restore_thumbnail_scene(
	viewport: SubViewport,
	pivot: Node3D,
	model: Node3D,
	original_parent: Node
) -> void:
	if pivot != null and model != null and model.get_parent() == pivot:
		pivot.remove_child(model)
	if original_parent != null and is_instance_valid(original_parent):
		original_parent.add_child(model)
	if viewport != null:
		viewport.queue_free()


## Import a GLB as a prop asset.
##
## `settings` accepts: asset_id, display_name, biome, grid_size (Vector3i),
## driver_axis (0/1/2), stretch_to_grid (bool), optimize_mesh (bool),
## mesh_target_ratio (0.5/0.25/0.125), and max_texture_size (0/4096/2048).
##
## Sizing is grid-first: the caller names integer cells, and the actual mesh
## size follows from them.
func import_glb(
	source_path: String,
	settings: Dictionary,
	library: AssetLibrary
) -> TileAsset:

	var model := load_model(source_path)

	if model == null:
		return null


	var raw_bounds := canonicalizer.compute_bounds(model)
	var original_size := raw_bounds.size


	var requested_grid: Vector3i = settings.get(
		"grid_size",
		canonicalizer.suggest_grid_bounds(original_size)
	)

	var driver_axis := int(settings.get("driver_axis", 1))
	var stretch := bool(settings.get("stretch_to_grid", false))
	var optimize_mesh := bool(settings.get("optimize_mesh", false))
	var mesh_target_ratio := float(settings.get("mesh_target_ratio", 0.125))
	var max_texture_size := int(settings.get("max_texture_size", 2048))


	var plan := canonicalizer.compute_grid_plan(
		original_size,
		requested_grid,
		driver_axis,
		stretch
	)


	var desired_id := String(
		settings.get("asset_id", source_path.get_file().get_basename())
	)

	if desired_id.is_empty():
		desired_id = source_path.get_file().get_basename()

	var asset_id := library.make_unique_id(desired_id)


	var asset_dir := K.ASSETS_DIR.path_join(asset_id)
	var source_dir := asset_dir.path_join("source")
	var derived_dir := asset_dir.path_join("derived")

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(source_dir))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(derived_dir))


	var stored_source := source_dir.path_join(source_path.get_file())

	if _copy_file(source_path, stored_source) != OK:
		model.queue_free()
		return null


	var build_id := str(Time.get_ticks_usec())

	var generated := _build_prop_geometry(model, raw_bounds, plan)

	if not bool(generated.get("ok", false)):
		push_error(
			"[Tile Studio] GLB build failed: %s"
			% String(generated.get("error", "unknown error"))
		)
		model.queue_free()
		return null

	var pose: Dictionary = generated["pose"]
	var thumbnail_image: Image = await _render_thumbnail(
		model,
		pose["transform"],
		128
	)
	if thumbnail_image == null:
		model.queue_free()
		return null

	var thumbnail_path := derived_dir.path_join("thumbnail.png")
	if thumbnail_image.save_png(ProjectSettings.globalize_path(thumbnail_path)) != OK:
		push_error("[Tile Studio] could not save GLB thumbnail '%s'" % thumbnail_path)
		model.queue_free()
		return null

	var source_metrics := runtime_optimizer.inspect_scene(model)
	model.free()
	model = null

	var runtime_path := derived_dir.path_join("runtime_optimized.glb")
	var runtime_build: Dictionary = {
		"ok": true,
		"source": source_metrics,
		"output": {},
		"status": "disabled",
	}
	if optimize_mesh:
		runtime_build = runtime_optimizer.build_from_source(
			stored_source,
			runtime_path,
			mesh_target_ratio,
			max_texture_size
		)
		if not bool(runtime_build.get("ok", false)):
			return null

	var asset := TileAsset.new()

	asset.asset_id = asset_id
	asset.display_name = String(settings.get("display_name", asset_id.capitalize()))
	asset.source_type = K.SourceType.GLB_PROP
	# Derived from source_type, never supplied: see TileAsset.category.
	asset.category = K.category_name(K.SourceType.GLB_PROP)
	asset.biome = String(settings.get("biome", ""))

	asset.source_path = stored_source
	asset.derived_dir = derived_dir
	asset.thumbnail_path = thumbnail_path
	asset.prop_mesh_optimization_enabled = optimize_mesh
	asset.prop_mesh_target_ratio = mesh_target_ratio
	asset.prop_max_texture_size = max_texture_size
	asset.prop_runtime_path = runtime_path if optimize_mesh else ""
	asset.prop_runtime_metrics = runtime_build

	asset.source_size_m = original_size
	asset.requested_grid_size = plan["grid_size"]
	asset.grid_bounds = plan["grid_size"]
	asset.visual_size_m = plan["actual_size"]
	asset.size_driver_axis = driver_axis
	asset.stretch_to_grid = stretch

	asset.prop_pose_transform = pose["transform"]
	asset.prop_voxels.assign(generated["voxels"])
	asset.prop_voxel_triangle_shares_percent = generated[
		"voxel_triangle_shares_percent"
	]
	asset.prop_voxels_diagonal.assign(generated["diagonal_voxels"])
	asset.prop_voxel_diagonal_triangle_shares_percent = generated[
		"diagonal_voxel_triangle_shares_percent"
	]

	asset.processing = {
		"importer": "glb",
		"imported_at": Time.get_datetime_string_from_system(),
		"original_source": source_path,
		"original_size": [original_size.x, original_size.y, original_size.z],
		"grid_size": [
			asset.requested_grid_size.x,
			asset.requested_grid_size.y,
			asset.requested_grid_size.z,
		],
		"driver_axis": driver_axis,
		"stretch_to_grid": stretch,
		"optimize_mesh": optimize_mesh,
		"mesh_target_ratio": mesh_target_ratio,
		"max_texture_size": max_texture_size,
		"runtime_path": asset.prop_runtime_path,
		"collision_triangle_count": int(generated.get("collision_triangle_count", 0)),
		"generation_id": build_id,
	}

	var save_path := asset_dir.path_join("asset.tres")

	if ResourceSaver.save(asset, save_path) == OK:
		asset.take_over_path(save_path)


	library.add_asset(asset)

	return asset



## Re-measure one prop's canonical and diagonal collision scans from its stored source.
##
## This explicit maintenance operation updates only source-derived pose and raw
## collision measurements. It never rebuilds the optimized runtime GLB or
## thumbnail, so the board-wide filter can be prepared without changing artwork.
func refresh_collision_measurements(asset: TileAsset) -> bool:
	if asset == null or not asset.is_prop():
		return false
	var source := asset.source_path
	if source.is_empty() or not FileAccess.file_exists(ProjectSettings.globalize_path(source)):
		push_error(
			"[Tile Studio] cannot measure '%s': stored source GLB is missing"
			% asset.asset_id
		)
		return false
	var model := load_model(source)
	if model == null:
		return false
	var raw_bounds := canonicalizer.compute_bounds(model)
	var plan := canonicalizer.compute_grid_plan(
		raw_bounds.size,
		asset.requested_grid_size,
		asset.size_driver_axis,
		asset.stretch_to_grid
	)
	var generated := _build_prop_geometry(model, raw_bounds, plan)
	model.queue_free()
	if not bool(generated.get("ok", false)):
		push_error(
			"[Tile Studio] collision measurement failed for '%s': %s"
			% [asset.asset_id, String(generated.get("error", "unknown error"))]
		)
		return false

	var pose: Dictionary = generated["pose"]
	asset.source_size_m = raw_bounds.size
	asset.requested_grid_size = plan["grid_size"]
	asset.grid_bounds = plan["grid_size"]
	asset.visual_size_m = plan["actual_size"]
	asset.prop_pose_transform = pose["transform"]
	asset.prop_voxels.assign(generated["voxels"])
	asset.prop_voxel_triangle_shares_percent = generated[
		"voxel_triangle_shares_percent"
	]
	asset.prop_voxels_diagonal.assign(generated["diagonal_voxels"])
	asset.prop_voxel_diagonal_triangle_shares_percent = generated[
		"diagonal_voxel_triangle_shares_percent"
	]
	asset.processing["collision_triangle_count"] = int(
		generated.get("collision_triangle_count", 0)
	)
	asset.processing["collision_measured_at"] = Time.get_datetime_string_from_system()
	asset.processing["generation_id"] = str(Time.get_ticks_usec())
	if asset.resource_path.is_empty():
		return true
	var save_error := ResourceSaver.save(asset, asset.resource_path)
	if save_error != OK:
		push_error(
			"[Tile Studio] measured '%s' but could not save its asset resource (%s)."
			% [asset.asset_id, error_string(save_error)]
		)
		return false
	return true


## Rebuild prop geometry and/or its selected runtime GLB from canonical source.
##
## Apply Size requests source-derived pose and voxel geometry as well as the
## runtime artifact. Rebuild Optimized Asset requests only the runtime artifact,
## preserving authored voxel collision. Asset fields change only after every
## requested derivation succeeds.
func rebuild_prop(
	asset: TileAsset,
	settings: Dictionary
) -> bool:
	if asset == null or not asset.is_prop():
		return false

	var source := asset.source_path
	if source.is_empty() or not FileAccess.file_exists(ProjectSettings.globalize_path(source)):
		push_error(
			"[Tile Studio] cannot rebuild '%s': stored source GLB is missing"
			% asset.asset_id
		)
		return false

	var requested_grid: Vector3i = settings.get(
		"grid_size",
		asset.requested_grid_size
	)
	var driver_axis := int(settings.get("driver_axis", asset.size_driver_axis))
	var stretch := bool(settings.get("stretch_to_grid", asset.stretch_to_grid))
	var rebuild_geometry := bool(settings.get("rebuild_geometry", true))
	var optimize_mesh := bool(settings.get(
		"optimize_mesh",
		asset.prop_mesh_optimization_enabled
	))
	var mesh_target_ratio := float(settings.get(
		"mesh_target_ratio",
		asset.prop_mesh_target_ratio
	))
	var max_texture_size := int(settings.get(
		"max_texture_size",
		asset.prop_max_texture_size
	))

	var original_size := asset.source_size_m
	var plan := {
		"grid_size": asset.requested_grid_size,
		"actual_size": asset.visual_size_m,
	}
	var generated: Dictionary = {"ok": true}
	if rebuild_geometry:
		var model := load_model(source)
		if model == null:
			return false
		var raw_bounds := canonicalizer.compute_bounds(model)
		original_size = raw_bounds.size
		plan = canonicalizer.compute_grid_plan(
			original_size,
			requested_grid,
			driver_axis,
			stretch
		)
		generated = _build_prop_geometry(model, raw_bounds, plan)
		model.queue_free()
		if not bool(generated.get("ok", false)):
			push_error(
				"[Tile Studio] GLB rebuild failed: %s"
				% String(generated.get("error", "unknown error"))
			)
			return false

	var runtime_path := asset.derived_dir.path_join("runtime_optimized.glb")
	var runtime_build: Dictionary = {
		"ok": true,
		"source": asset.prop_runtime_metrics.get("source", {}),
		"output": {},
		"status": "disabled",
	}
	if optimize_mesh:
		runtime_build = runtime_optimizer.build_from_source(
			source,
			runtime_path,
			mesh_target_ratio,
			max_texture_size
		)
		if not bool(runtime_build.get("ok", false)):
			return false

	var build_id := str(Time.get_ticks_usec())
	if rebuild_geometry:
		var pose: Dictionary = generated["pose"]
		asset.source_size_m = original_size
		asset.requested_grid_size = plan["grid_size"]
		asset.grid_bounds = plan["grid_size"]
		asset.visual_size_m = plan["actual_size"]
		asset.size_driver_axis = driver_axis
		asset.stretch_to_grid = stretch
		asset.prop_pose_transform = pose["transform"]
		asset.prop_voxels.assign(generated["voxels"])
		asset.prop_voxel_triangle_shares_percent = generated[
			"voxel_triangle_shares_percent"
		]
		asset.prop_voxels_diagonal.assign(generated["diagonal_voxels"])
		asset.prop_voxel_diagonal_triangle_shares_percent = generated[
			"diagonal_voxel_triangle_shares_percent"
		]

	asset.prop_mesh_optimization_enabled = optimize_mesh
	asset.prop_mesh_target_ratio = mesh_target_ratio
	asset.prop_max_texture_size = max_texture_size
	asset.prop_runtime_path = runtime_path if optimize_mesh else ""
	asset.prop_runtime_metrics = runtime_build

	asset.processing["grid_size"] = [
		asset.requested_grid_size.x,
		asset.requested_grid_size.y,
		asset.requested_grid_size.z,
	]
	asset.processing["driver_axis"] = asset.size_driver_axis
	asset.processing["stretch_to_grid"] = asset.stretch_to_grid
	asset.processing["optimize_mesh"] = optimize_mesh
	asset.processing["mesh_target_ratio"] = mesh_target_ratio
	asset.processing["max_texture_size"] = max_texture_size
	asset.processing["runtime_path"] = asset.prop_runtime_path
	if rebuild_geometry:
		asset.processing["collision_triangle_count"] = int(
			generated.get("collision_triangle_count", 0)
		)
	asset.processing["generation_id"] = build_id
	asset.processing["rederived_at"] = Time.get_datetime_string_from_system()

	if not asset.resource_path.is_empty():
		var save_error := ResourceSaver.save(asset, asset.resource_path)
		if save_error != OK:
			push_error("[Tile Studio] Rebuilt '%s' but could not save its asset resource (%s)." % [
				asset.asset_id,
				error_string(save_error),
			])
			return false
	return true

## Copy the untouched source GLB into the asset-owned source directory so every later rebuild starts from a stable canonical file.
func _copy_file(from: String, to: String) -> Error:
	var src := ProjectSettings.globalize_path(from)
	if not FileAccess.file_exists(src):
		src = from
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		return ERR_FILE_CANT_READ
	var file := FileAccess.open(ProjectSettings.globalize_path(to), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	file.close()
	return OK
