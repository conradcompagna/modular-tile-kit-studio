@tool
extends SceneTree

## Verify the terrain integrates with the live board and renderer contracts.
##
## This checks the wiring the editor actually depends on: terrain as canonical
## board state, its save/load round trip, derived gameplay data, and the
## renderer's use of the shared material and paint systems.
func _init() -> void:
	var failures := 0
	var paths := [
		"res://addons/modular_tile_studio/data/board_document.gd",
		"res://addons/modular_tile_studio/viewport/terrain_renderer.gd",
		"res://addons/modular_tile_studio/viewport/studio_viewport.gd",
		"res://addons/modular_tile_studio/rendering/surface_material_paint.gd",
		"res://addons/modular_tile_studio/rendering/surface_material_factory.gd",
		"res://addons/modular_tile_studio/plugin.gd",
	]
	for path: String in paths:
		var script := load(path)
		if script == null:
			print("FAIL load: ", path)
			failures += 1
			continue
		if not (script as GDScript).can_instantiate():
			print("FAIL instantiate: ", path)
			failures += 1
			continue
		print("OK parse ", path)
	if failures > 0:
		quit(1)
		return

	# Instantiating the terrain material forces the shared shader through Godot's
	# resource parser and proves the grid remains presentation on terrain itself.
	var material_factory := SurfaceMaterialFactory.new()
	var terrain_material := material_factory.get_material_for_terrain_batch(
		null,
		null,
		null,
		Vector2.ZERO,
		Vector2.ZERO
	) as ShaderMaterial
	failures += _expect(
		terrain_material != null and terrain_material.shader != null,
		"terrain material loads the unified heightfield shader"
	)
	if terrain_material != null:
		failures += _expect(
			terrain_material.get_shader_parameter("terrain_triangle_instances") == true,
			"terrain material identifies canonical triangle instances"
		)
		failures += _expect(
			terrain_material.get_shader_parameter("terrain_show_top_grid") == true,
			"top grid defaults to a terrain-shader overlay"
		)

	var board := BoardDocument.new()
	failures += _expect(board.terrain != null, "new board owns a terrain grid")
	failures += _expect(board.terrain.is_empty(), "new board terrain starts undrawn")

	# Draw a footprint and sculpt it through the same API the viewport uses.
	board.terrain = TerrainMesh.create(Vector2i(0, 0), Vector2i(12, 12))
	for z: int in 12:
		for x: int in 12:
			board.terrain.set_cell_filled(Vector2i(x, z), true)
	var sculptor := TerrainSculptor.new(board.terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.STEP_UP
	settings.size_m = 2.0
	settings.step_m = 0.5
	sculptor.configure(settings)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(4.0, 4.0))
	sculptor.finish_stroke()

	# The gameplay grid must be derived, complete, and consistent with terrain.
	var gameplay := board.gameplay_grid()
	failures += _expect(
		gameplay.size() == board.terrain.filled_cell_count(),
		"gameplay grid covers every filled cell (%d vs %d)"
			% [gameplay.size(), board.terrain.filled_cell_count()]
	)
	var raised_entries := 0
	for entry: Dictionary in gameplay:
		var cell: Vector2i = entry["cell"]
		failures += _expect(
			is_equal_approx(
				float(entry["walk_height_m"]),
				board.terrain.cell_walk_height(cell)
			),
			"gameplay walk height matches terrain at %s" % cell
		)
		if float(entry["walk_height_m"]) > 0.01:
			raised_entries += 1
	failures += _expect(raised_entries > 0, "stepped cells appear raised in gameplay grid")

	# Editing terrain must immediately change the derived grid with no refresh.
	var probe := Vector2i(4, 4)
	var before_height := board.terrain.cell_walk_height(probe)
	board.terrain.set_cell_top_level(Vector2i(4, 4), before_height + 3.0)
	var after_grid := board.gameplay_grid()
	var after_height := 0.0
	for entry: Dictionary in after_grid:
		if entry["cell"] == probe:
			after_height = float(entry["walk_height_m"])
	failures += _expect(
		after_height > before_height,
		"gameplay grid follows a terrain edit with no separate rebuild"
	)

	# Board persistence must carry terrain exactly.
	var restored := BoardDocument.new()
	var load_error := restored.from_json(board.to_json())
	failures += _expect(load_error == OK, "board with terrain reloads, error %d" % load_error)
	failures += _expect(
		restored.terrain.size_cells == board.terrain.size_cells,
		"board round trip preserves terrain footprint"
	)
	failures += _expect(
		is_equal_approx(
			restored.terrain.cell_walk_height(Vector2i(4, 4)),
			board.terrain.cell_walk_height(Vector2i(4, 4))
		),
		"board round trip preserves sculpted corners"
	)
	failures += _expect(
		restored.gameplay_grid().size() == board.gameplay_grid().size(),
		"restored board derives the same gameplay grid"
	)

	# A board saved before this rework has no terrain key and must still load.
	var legacy := board.to_json()
	legacy.erase("terrain")
	var legacy_board := BoardDocument.new()
	failures += _expect(
		legacy_board.from_json(legacy) == OK,
		"board without a terrain key still loads"
	)
	failures += _expect(
		legacy_board.terrain != null and legacy_board.terrain.is_empty(),
		"missing terrain loads as an undrawn footprint, not an error"
	)

	# The renderer must build real geometry and expose its paint identity.
	var renderer := MTSTerrainRenderer.new()
	var paint := MTSSurfaceMaterialPaint.new()
	paint.bind_profile(board.material_blend)
	failures += _expect(
		renderer.rebuild(board.terrain, 8, paint, board),
		"renderer builds terrain geometry"
	)
	var instances := renderer.chunk_instances()
	failures += _expect(
		not instances.is_empty(),
		"renderer holds visible triangle batches per chunk"
	)
	var visual := (
		instances[0] as MultiMeshInstance3D
		if not instances.is_empty()
		else null
	)
	var multimesh := visual.multimesh if visual != null else null
	failures += _expect(
		multimesh != null and multimesh.use_colors and multimesh.use_custom_data,
		"terrain batches carry paint layers and exact affine face UV data"
	)
	var mesh := multimesh.mesh as ArrayMesh if multimesh != null else null
	if mesh != null:
		var arrays := mesh.surface_get_arrays(0)
		var uvs := arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var uv_in_range := true
		for uv: Vector2 in uvs:
			if uv.x < -0.001 or uv.x > 1.001 or uv.y < -0.001 or uv.y > 1.001:
				uv_in_range = false
				break
		failures += _expect(
			uv_in_range,
			"shared triangle UVs stay in 0..1 for affine terrain sampling"
		)
	# Every terrain face carries a stable paint identity that survives sculpting.
	var ground_uid := TerrainMesh.cell_top_uid(Vector2i(4, 4))
	failures += _expect(
		renderer.placement_for_uid(ground_uid) != null,
		"renderer exposes a stable paint placement per chunk"
	)
	# A board with no ground asset chosen yet must render untextured rather than
	# substituting a stand-in, so a null material is accepted without error.
	renderer.set_chunk_surface_material(Vector2i.ZERO, 0, null)

	var painted := paint.brush_segment(
		ground_uid,
		Vector2i.ONE,
		Vector2(0.5, 0.5),
		Vector2(0.6, 0.6),
		1.0,
		0.5,
		1.0,
		0,
		false
	)
	failures += _expect(painted, "terrain accepts a stroke from the shared paint system")
	failures += _expect(
		paint.has_image(ground_uid),
		"terrain paint is stored under its canonical uid"
	)
	renderer.free()

	if failures == 0:
		print("TERRAIN INTEGRATION OK")
		quit(0)
	else:
		print("TERRAIN INTEGRATION FAILURES: ", failures)
		quit(1)


## Report one expectation and return its failure count.
func _expect(condition: bool, message: String) -> int:
	if condition:
		return 0
	print("FAIL: ", message)
	return 1
