@tool
extends SceneTree

## Drive the complete authoring workflow the user described, end to end.
##
## Draws an L-shaped footprint, blocks out verticality with the step brush,
## sculpts rounded relief over it, converts a region to angular architecture,
## paints the terrain, and checks the derived gameplay grid, rendering, undo,
## and persistence at each stage -- the exact order a user works in.
func _init() -> void:
	var failures := 0
	var library := AssetLibrary.new()
	var board := BoardDocument.new()
	board.bind_library(library)
	# MTSStudioViewport is an editor Control that requires the plugin's live UI
	# tree, so this drives the same canonical calls its handlers make.
	var fields := MTSWorldSurfaceFields.new()
	var paint := MTSSurfaceMaterialPaint.new()
	paint.bind_profile(board.material_blend)
	var renderer := MTSTerrainRenderer.new()
	var sculptor: TerrainSculptor = null
	var brush := TerrainSculptor.Settings.new()

	# --- 1. Draw an L-shaped encounter footprint --------------------------
	# Footprint drawing allocates the grid and fills cells, exactly as the
	# viewport's _apply_footprint_cell does for each cell a drag resolves.
	board.terrain = TerrainMesh.create(Vector2i(0, 0), Vector2i(30, 20))
	for z: int in 20:
		for x: int in 30:
			var in_long_arm := x < 12
			var in_foot := z < 8
			if in_long_arm or in_foot:
				board.terrain.set_cell_filled(Vector2i(x, z), true)
	sculptor = TerrainSculptor.new(board.terrain)
	var drawn_cells := board.terrain.filled_cell_count()
	print("footprint cells: ", drawn_cells)
	failures += _expect(drawn_cells == 384, "L footprint has 384 cells, got %d" % drawn_cells)
	failures += _expect(
		board.terrain.is_cell_filled(Vector2i(2, 2))
			and not board.terrain.is_cell_filled(Vector2i(20, 15)),
		"footprint fills the L and leaves its notch empty"
	)

	# --- 2. Block out verticality with the step brush ----------------------
	brush.mode = TerrainSculptor.Mode.STEP_UP
	brush.size_m = 2.0
	brush.step_m = 0.5
	sculptor.configure(brush)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(4.0, 4.0))
	sculptor.finish_stroke()
	var stepped: float = board.terrain.cell_walk_height(Vector2i(4, 4))
	print("stepped cell: ", stepped)
	failures += _expect(
		is_equal_approx(stepped, 0.5),
		"one step stroke lands on exactly one 0.5 m level, got %f" % stepped
	)
	# The step must have produced real walls where the raised block meets the
	# untouched ground. They stand on the block's BOUNDARY: cells in its interior
	# have no drop to any neighbour, which is exactly why the block reads as a
	# plateau rather than a mound.
	var walls := 0
	for probe_z: int in range(0, 12):
		for probe_x: int in range(0, 12):
			for edge: int in 4:
				if board.terrain.has_side_face(Vector2i(probe_x, probe_z), edge):
					walls += 1
	failures += _expect(
		walls > 0,
		"the step brush produced real vertical walls, got %d" % walls
	)
	failures += _expect(
		not board.terrain.has_side_face(Vector2i(4, 4), TerrainMesh.EDGE_NORTH),
		"a cell inside the raised block has no wall against its equally raised neighbour"
	)
	failures += _expect(
		board.terrain.is_cell_level(Vector2i(4, 4)),
		"stepped cells stay perfectly flat and upright"
	)
	failures += _expect(
		board.terrain.classify_cell(Vector2i(4, 4)) == TerrainMesh.CellForm.FLAT,
		"a stepped cell derives as FLAT for gameplay"
	)

	# --- 3. Sculpt rounded relief over the blocked-out ground -------------
	brush.mode = TerrainSculptor.Mode.RAISE
	brush.size_m = 3.0
	brush.strength = 1.0
	brush.hardness = 0.4
	sculptor.configure(brush)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(4.0, 4.0))
	sculptor.stamp_segment(Vector2(4.0, 4.0), Vector2(6.0, 6.0))
	sculptor.finish_stroke()
	var blended: float = board.terrain.lattice_top_height(Vector2i(4, 4))
	print("after rounded pass: ", blended)
	failures += _expect(
		blended > 0.5,
		"rounded sculpting raises the SAME corners the step brush set, got %f" % blended
	)
	var graded := false
	for probe_z: int in range(2, 10):
		for probe_x: int in range(2, 11):
			if board.terrain.cell_relief(Vector2i(probe_x, probe_z)) > 0.01:
				graded = true
	failures += _expect(graded, "rounded sculpting produces graded relief")
	# Slope-family sculpting is what puts non-flat cells into the gameplay grid,
	# so the derived forms are sampled here, before the angular pass deliberately
	# flattens this region back into architecture.
	var sloped_forms: Dictionary = {}
	for entry: Dictionary in board.gameplay_grid():
		sloped_forms[String(entry["form_name"])] = true
	print("forms after rounded pass: ", sloped_forms.keys())
	failures += _expect(
		sloped_forms.has("Flat") and (sloped_forms.has("Ramp") or sloped_forms.has("Saddle")),
		"slope sculpting produces both flat and sloped gameplay cells, got %s"
			% str(sloped_forms.keys())
	)

	# --- 4. Convert a region to angular architecture ----------------------
	brush.mode = TerrainSculptor.Mode.QUANTIZE
	brush.size_m = 4.0
	sculptor.configure(brush)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(5.0, 5.0))
	sculptor.finish_stroke()
	var angular: float = board.terrain.cell_walk_height(Vector2i(5, 5))
	var nearest := roundf(angular / 0.5) * 0.5
	print("angular corner: ", angular)
	failures += _expect(
		absf(angular - nearest) <= TerrainMesh.LEVEL_EPSILON_M,
		"angular mode snaps sculpted ground onto the level lattice, got %f" % angular
	)

	# --- 5. The derived gameplay grid follows all of it -------------------
	var gameplay := board.gameplay_grid()
	failures += _expect(
		gameplay.size() == board.terrain.filled_cell_count(),
		"gameplay grid covers every footprint cell"
	)
	var forms: Dictionary = {}
	for entry: Dictionary in gameplay:
		forms[String(entry["form_name"])] = true
		failures += _expect(
			is_equal_approx(
				float(entry["walk_height_m"]),
				board.terrain.cell_walk_height(entry["cell"])
			),
			"gameplay height always matches the sculpted surface"
		)
	print("derived cell forms: ", forms.keys())
	# The angular pass snapped every cell it covered onto the level lattice, which
	# is the whole point of that brush: organic relief becomes architecture, and
	# the drops between the resulting levels become real walls rather than smears.
	failures += _expect(
		forms.has("Flat"),
		"the angular pass leaves flat architectural cells, got %s" % str(forms.keys())
	)

	# --- 6. Terrain renders, collides, and reaches the shader -------------
	failures += _expect(
		renderer.rebuild(board.terrain, 8, paint, board),
		"the terrain builds a mesh"
	)
	failures += _expect(
		not renderer.chunk_instances().is_empty(),
		"the terrain renders as one mesh per paint chunk"
	)
	fields.configure(Vector2(-4.0, -4.0), Vector2(40.0, 32.0), Vector2i(256, 256), false)
	fields.project_terrain(board.terrain)
	failures += _expect(
		fields.sample_height_world(Vector2(4.5, 4.5)) > 0.4,
		"the sculpted terrain reaches the GPU height projection the shader reads"
	)

	# --- 7. Paint the terrain without generating mesh ---------------------
	var surface_count_before := board.surfaces.size()
	# Ground is painted per chunk, at the profile's full texel density.
	var ground_uid := TerrainMesh.cell_top_uid(Vector2i(4, 4))
	var painted := paint.brush_segment(
		ground_uid,
		Vector2i.ONE,
		Vector2(0.30, 0.30),
		Vector2(0.34, 0.34),
		0.5,
		0.75,
		1.0,
		0,
		false
	)
	failures += _expect(painted, "terrain accepts a stroke from the shared paint system")
	failures += _expect(
		board.surfaces.size() == surface_count_before,
		"painting terrain creates NO surface geometry"
	)

	# --- 8. Undo restores the exact prior corners -------------------------
	var before_undo: float = board.terrain.cell_walk_height(Vector2i(5, 5))
	brush.mode = TerrainSculptor.Mode.STEP_UP
	sculptor.configure(brush)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(5.0, 5.0))
	var undo_patch := sculptor.finish_stroke()
	var cells_value: Variant = undo_patch.get("cells", PackedVector2Array())
	var before_value: Variant = undo_patch.get("before_tops", PackedFloat32Array())
	var before_sides: Variant = undo_patch.get("before_sides", {})
	failures += _expect(
		(cells_value as PackedVector2Array).size() > 0,
		"a stroke produces an undo patch"
	)
	sculptor.apply_patch(cells_value, before_value, before_sides)
	failures += _expect(
		is_equal_approx(board.terrain.cell_walk_height(Vector2i(5, 5)), before_undo),
		"undo restores the exact prior cell height"
	)

	# --- 9. The whole map survives a save/load round trip -----------------
	var restored := BoardDocument.new()
	failures += _expect(restored.from_json(board.to_json()) == OK, "board reloads")
	failures += _expect(
		restored.terrain.filled_cell_count() == board.terrain.filled_cell_count()
			and is_equal_approx(
				restored.terrain.cell_walk_height(Vector2i(5, 5)),
				board.terrain.cell_walk_height(Vector2i(5, 5))
			),
		"the authored encounter map round-trips exactly"
	)
	failures += _expect(
		restored.gameplay_grid().size() == board.gameplay_grid().size(),
		"the reloaded board derives the same gameplay grid"
	)

	renderer.free()
	if failures == 0:
		print("WORKFLOW OK")
		quit(0)
	else:
		print("WORKFLOW FAILURES: ", failures)
		quit(1)


## Report one expectation and return its failure count.
func _expect(condition: bool, message: String) -> int:
	if condition:
		return 0
	print("FAIL: ", message)
	return 1
