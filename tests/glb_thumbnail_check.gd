extends SceneTree

var importer_script
var canonicalizer_script


## Load the project importer and run one real offscreen GLB thumbnail capture.
func _init() -> void:
	importer_script = load("res://addons/modular_tile_studio/importers/glb_asset_importer.gd")
	canonicalizer_script = load("res://addons/modular_tile_studio/importers/glb_canonicalizer.gd")
	call_deferred("_run_check")


## Render an existing GLB and fail if the returned image is empty or uniform.
func _run_check() -> void:
	if DisplayServer.get_name() == "headless":
		print("glb_thumbnail_check: skipped (headless renderer has no safe offscreen 3D capture)")
		quit(0)
		return

	var source := "res://tile_library/assets/FOUNTAIN_REAL/source/Meshy_AI_Ancient_Stone_Fountai_0723053905_texture.glb"
	var importer = importer_script.new()
	var canonicalizer = canonicalizer_script.new()
	var model: Node3D = importer.load_model(source)
	if model == null:
		push_error("GLB thumbnail check could not load the fixture")
		quit(1)
		return

	var raw_bounds: AABB = canonicalizer.compute_bounds(model)
	var grid_bounds: Vector3i = canonicalizer.suggest_grid_bounds(raw_bounds.size)
	var plan: Dictionary = canonicalizer.compute_grid_plan(
		raw_bounds.size,
		grid_bounds,
		1,
		false
	)
	var pose: Dictionary = canonicalizer.compute_pose(
		raw_bounds,
		plan["scale"],
		plan["grid_size"]
	)
	var image: Image = await importer._render_thumbnail(
		model,
		pose["transform"],
		128
	)
	model.queue_free()

	if image == null or image.is_empty():
		push_error("GLB thumbnail check returned an empty image")
		quit(1)
		return

	var background := image.get_pixel(0, 0)
	var differing_pixels := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			var colour_delta := absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b)
			if colour_delta > 0.06:
				differing_pixels += 1

	var output := "user://glb_thumbnail_check.png"
	var save_error := image.save_png(ProjectSettings.globalize_path(output))
	print("glb_thumbnail_check: %dx%d, differing_pixels=%d, save_error=%s" % [
		image.get_width(),
		image.get_height(),
		differing_pixels,
		error_string(save_error),
	])
	if save_error != OK or differing_pixels == 0:
		quit(1)
		return
	quit(0)
