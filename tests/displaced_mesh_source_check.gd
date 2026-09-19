extends SceneTree

var gbuffer_script: Script
var asset_script: Script
var material_factory_script: Script
var aesthetics_script: Script
var world_fields_script: Script
var viewport_script: Script
var placement_controller_script: GDScript
var failures: int = 0


## Load the production classes before running the material-parallax and contact checks.
func _init() -> void:
	gbuffer_script = load("res://addons/modular_tile_studio/data/gbuffer_map_set.gd")
	asset_script = load("res://addons/modular_tile_studio/data/tile_asset.gd")
	material_factory_script = load("res://addons/modular_tile_studio/rendering/surface_material_factory.gd")
	aesthetics_script = load("res://addons/modular_tile_studio/data/aesthetic_profile.gd")
	world_fields_script = load("res://addons/modular_tile_studio/rendering/world_surface_fields.gd")
	viewport_script = load("res://addons/modular_tile_studio/viewport/studio_viewport.gd")
	placement_controller_script = load("res://addons/modular_tile_studio/viewport/placement_controller.gd")
	call_deferred("_run_checks")


## Record one focused assertion with enough context to diagnose a regression.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("GPU SURFACE FIELD CHECK FAILED: %s" % message)


## Exercise material parallax scale, terrain projection, and visual contact grime.
func _run_checks() -> void:
	_check_undo_refresh_order()
	_check_material_parallax_scale()
	_check_sculpt_and_contact_fields()
	_check_prop_geometry_contact()
	_clear_static_test_textures()
	print("surface_parallax_source_check: %d failures" % failures)
	quit(failures)


## Prove every placement action mutates BoardDocument before observers rebuild on undo.
##
## A reverse undo order would notify the viewport before removing or restoring a
## placement. The following action would then rebuild from that stale observation.
func _check_undo_refresh_order() -> void:
	var source := placement_controller_script.source_code
	var ordered_action := "undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)"
	_check(source.count(ordered_action) == 9, "all nine placement actions should preserve mutation-then-refresh undo order")
	_check(not source.contains("undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, true)"), "placement actions must never reverse their undo operations")

	var undo_redo := UndoRedo.new()
	var events: Array[String] = []
	undo_redo.create_action("Placement transaction", UndoRedo.MERGE_DISABLE, false)
	undo_redo.add_do_method(_record_undo_event.bind(events, "mutation"))
	undo_redo.add_undo_method(_record_undo_event.bind(events, "inverse mutation"))
	undo_redo.add_do_method(_record_undo_event.bind(events, "refresh"))
	undo_redo.add_undo_method(_record_undo_event.bind(events, "refresh"))
	undo_redo.commit_action()
	events.clear()
	undo_redo.undo()
	_check(
		events.size() == 2 and events[0] == "inverse mutation" and events[1] == "refresh",
		"undo must refresh only after the BoardDocument inverse mutation"
	)


## Record one action stage for the UndoRedo ordering assertion.
func _record_undo_event(events: Array[String], event_name: String) -> void:
	events.append(event_name)


## Prove terrain parallax uses source image size and the visible metres-per-source-pixel setting.
func _check_material_parallax_scale() -> void:
	var fixture_path := "user://gpu_surface_chord_height.png"
	var fixture := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	for y in fixture.get_height():
		for x in fixture.get_width():
			var value := float(x + y) / 10.0
			fixture.set_pixel(x, y, Color(value, value, value, 1.0))
	_check(fixture.save_png(fixture_path) == OK, "parallax fixture should save")

	var maps: GBufferMapSet = gbuffer_script.new()
	maps.set_channel("albedo", fixture_path)
	maps.set_channel("height", fixture_path)
	# One fixture can stand in for each ORM component here because this assertion
	# verifies the packed-map binding and sampling path, not map artistry.
	maps.set_channel("orm", fixture_path)
	maps.set_strength("height", 0.5)

	var asset: TileAsset = asset_script.new()
	asset.asset_id = "PARALLAX_SCALE_TEST"
	asset.grid_bounds = Vector3i(8, 4, 1)
	asset.gbuffer = maps

	var look: AestheticProfile = aesthetics_script.new()
	look.height_metres_per_source_pixel = 0.002
	var factory: SurfaceMaterialFactory = material_factory_script.new()
	factory.aesthetics = look

	var short_edge_px: float = material_factory_script.height_image_short_edge_px(asset)
	_check(is_equal_approx(short_edge_px, 4.0), "height short edge should come from the 8x4 image")

	var material := factory.get_material(asset) as ShaderMaterial
	_check(material != null, "parallax asset should build the unified GPU material")
	if material != null:
		var responsive_px := float(material.get_shader_parameter("parallax_source_short_edge_px"))
		# Scalar board settings are native shader globals. Headless RenderingServer
		# can enumerate them but cannot reliably read their queued values, so this
		# test validates the project declaration and registration instead.
		var declaration: Variant = ProjectSettings.get_setting("shader_globals/mts_height_metres_per_source_pixel", null)
		var globals: Array[StringName] = RenderingServer.global_shader_parameter_get_list()
		_check(is_equal_approx(responsive_px, 2.0), "Height response should scale the source short-edge pixel count")
		_check(material.get_shader_parameter("has_orm") == true, "a supplied ORM map should select the packed material path")
		_check(material.get_shader_parameter("orm_tex") != null, "the packed ORM texture should reach the shader material")
		var shader_code := material.shader.code
		_check(shader_code.contains("BENT_NORMAL_MAP = normalize"), "bent normals should use Godot's dedicated output")
		_check(not shader_code.contains("tangent_normal = combine_tangent_normals(tangent_normal, bent_n"), "bent normals must not be merged into the visible surface normal")
		_check(shader_code.contains("AO_LIGHT_AFFECT = 0.0"), "baked AO should leave direct light unaffected")
		_check(not shader_code.contains("g_seam_"), "the material shader must not contain the retired seam-atlas path")
		_check(not shader_code.contains("VERTEX +="), "height maps must not displace terrain vertices")
		_check(shader_code.contains("parallax_sample_world_pos"), "terrain height must enter the material parallax lookup")
		_check(declaration is Dictionary and String((declaration as Dictionary).get("type", "")) == "float", "height metres per source pixel should be declared as a project shader global")
		_check(globals.has(&"mts_height_metres_per_source_pixel"), "height metres per source pixel should register with RenderingServer")
		_check(is_equal_approx(responsive_px * look.height_metres_per_source_pixel, 0.004), "parallax travel scale should remain visibly non-zero")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture_path))
## Prove projected terrain and visual contact grime remain separate derived fields.
func _check_sculpt_and_contact_fields() -> void:
	var fields: MTSWorldSurfaceFields = world_fields_script.new()
	var field_origin := Vector2.ZERO
	var field_size := Vector2(4.0, 4.0)
	var field_resolution := Vector2i(65, 65)
	fields.configure(field_origin, field_size, field_resolution)

	var projection_grid := _terrain_covering(Vector2i(0, 0), Vector2i(4, 4))
	_raise_terrain(fields, projection_grid, Vector2(1.0, 1.0), 1.0, 1.0)
	_check(
		fields.sample_height_world(Vector2(1.0, 1.0)) > 0.9,
		"projected terrain should reach the field in real metres"
	)
	_raise_terrain(fields, projection_grid, Vector2(1.0, 1.0), 1.0, 0.5)
	_check(
		fields.sample_height_world(Vector2(1.0, 1.0)) < 0.6,
		"lowering terrain should reproject the field downward"
	)
	_raise_terrain(fields, projection_grid, Vector2(1.0, 1.0), 1.0, 0.75)
	_check(
		is_equal_approx(fields.sample_height_world(Vector2(1.0, 1.0)), 0.75),
		"flattened terrain should project its exact level"
	)

	var triangle: Array[PackedVector2Array] = [
		PackedVector2Array([
			Vector2(0.5, 0.5),
			Vector2(3.5, 0.5),
			Vector2(0.5, 3.5),
		])
	]
	fields.stamp_contact_polygons(triangle, 0.0, 1.0, false, "triangle_contact")
	_check(
		fields.interaction_image.get_format() == Image.FORMAT_RF,
		"contact grime should occupy one scalar channel"
	)
	_check(
		_interaction_at(fields.interaction_image, Vector2(1.0, 1.0), field_origin, field_size) > 0.9,
		"real triangle interior should receive contact grime"
	)
	_check(
		_interaction_at(fields.interaction_image, Vector2(3.0, 3.0), field_origin, field_size) < 0.01,
		"empty corner of the triangle's bounding box must remain untouched"
	)
	fields.remove_contact_source("triangle_contact", false)
	_check(
		_interaction_at(fields.interaction_image, Vector2(1.0, 1.0), field_origin, field_size) < 0.01,
		"removing one contact source should clear only its visual grime"
	)

	fields.stamp_contact_segment(
		Vector2(0.5, 0.5),
		Vector2(3.5, 0.5),
		0.1,
		0.0,
		1.0,
		false
	)
	_check(
		_interaction_at(fields.interaction_image, Vector2(2.0, 0.5), field_origin, field_size) > 0.9,
		"wall/floor seam segment should receive contact grime"
	)
	_check(
		_interaction_at(fields.interaction_image, Vector2(2.0, 1.5), field_origin, field_size) < 0.01,
		"wall/floor grime should not darken the surrounding grid"
	)
## Prove the true lowest source triangles define visual GLB contact grime.
func _check_prop_geometry_contact() -> void:
	var source_model := Node3D.new()
	var mesh_instance := MeshInstance3D.new()
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface_tool.add_vertex(Vector3(0.0, 0.0, 0.0))
	surface_tool.add_vertex(Vector3(1.0, 0.0, 0.0))
	surface_tool.add_vertex(Vector3(0.0, 0.0, 1.0))
	surface_tool.add_vertex(Vector3(0.0, 1.0, 0.0))
	surface_tool.add_vertex(Vector3(1.0, 1.0, 0.0))
	surface_tool.add_vertex(Vector3(0.0, 1.0, 1.0))
	mesh_instance.mesh = surface_tool.commit()
	source_model.add_child(mesh_instance)

	var asset: TileAsset = asset_script.new()
	asset.asset_id = "TRIANGLE_FOOT_PROP"
	asset.source_type = MTSConstants.SourceType.GLB_PROP
	asset.source_path = "res://tests/triangle_foot_fixture.glb"
	asset.grid_bounds = Vector3i.ONE
	asset.prop_voxels = [Vector3i.ZERO]
	asset.processing["generation_id"] = "triangle-foot-test"

	var prop := PropPlacement.create(asset.asset_id, Vector3i(1, 0, 1))
	var viewport: MTSStudioViewport = viewport_script.new()
	viewport._real_mesh_cache[asset.source_path] = source_model
	var polygons: Array[PackedVector2Array] = viewport._prop_contact_polygons(prop, asset)
	_check(polygons.size() == 1, "only the true lowest source triangle should define prop contact")

	var fields: MTSWorldSurfaceFields = world_fields_script.new()
	var field_origin := Vector2.ZERO
	var field_size := Vector2(4.0, 4.0)
	fields.configure(field_origin, field_size, Vector2i(65, 65))
	fields.stamp_contact_polygons(
		polygons,
		0.0,
		1.0,
		false,
		viewport._prop_contact_id(prop)
	)
	_check(
		_interaction_at(fields.interaction_image, Vector2(1.2, 1.2), field_origin, field_size) > 0.9,
		"source triangle interior should become prop contact grime"
	)
	_check(
		_interaction_at(fields.interaction_image, Vector2(1.8, 1.8), field_origin, field_size) < 0.01,
		"source triangle bounding-box corner must not become prop contact"
	)

	viewport._real_mesh_cache.clear()
	viewport.free()
	source_model.free()



## Build a flat terrain grid covering one world rectangle for support tests.
##
## Height is no longer authored as an image, so tests that need raised ground
## sculpt the canonical corners and project them exactly as the editor does.
func _terrain_covering(origin_cell: Vector2i, size_cells: Vector2i) -> TerrainMesh:
	var grid := TerrainMesh.create(origin_cell, size_cells)
	for z: int in size_cells.y:
		for x: int in size_cells.x:
			grid.set_cell_filled(origin_cell + Vector2i(x, z), true)
	return grid


## Raise one square terrain region to an exact level and project it into a field.
func _raise_terrain(
	fields: MTSWorldSurfaceFields,
	grid: TerrainMesh,
	centre_xz: Vector2,
	half_extent_m: float,
	height_m: float
) -> void:
	var sculptor := TerrainSculptor.new(grid)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.FLATTEN
	settings.size_m = half_extent_m
	settings.strength = 1.0
	settings.flatten_target_m = height_m
	sculptor.configure(settings)
	sculptor.begin_stroke()
	sculptor.stamp(centre_xz)
	sculptor.finish_stroke()
	fields.project_terrain(grid)


## Release factory-owned one-pixel textures so headless renderer leak checks stay meaningful.
func _clear_static_test_textures() -> void:
	SurfaceMaterialFactory._gpu_white = null
	SurfaceMaterialFactory._gpu_black = null
	SurfaceMaterialFactory._gpu_normal = null
	SurfaceMaterialFactory._gpu_error = null


## Sample R or G from a public field image using the same nearest-pixel mapping as world stamps.
func _interaction_at(
	image: Image,
	world_xz: Vector2,
	origin_xz: Vector2,
	size_xz: Vector2,
	channel: int = 0
) -> float:
	if image == null or image.is_empty():
		return 0.0
	var uv := (world_xz - origin_xz) / size_xz
	var pixel := Vector2i(
		clampi(roundi(uv.x * float(image.get_width() - 1)), 0, image.get_width() - 1),
		clampi(roundi(uv.y * float(image.get_height() - 1)), 0, image.get_height() - 1)
	)
	var value := image.get_pixel(pixel.x, pixel.y)
	return value.g if channel == 1 else value.r
