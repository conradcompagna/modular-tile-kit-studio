@tool
extends SceneTree

## Verify the canonical terrain data model and both sculpt brush families.
##
## The invariant this file exists to protect: a STEP brush must produce a real
## vertical wall, and a SLOPE brush must produce continuous ground. Those are two
## different edits of one surface, and the previous implementation collapsed them
## into one shared-corner operation that could only ever make ramps.
func _init() -> void:
	var failures := 0
	failures += _check_step_makes_walls()
	failures += _check_slope_stays_continuous()
	failures += _check_families_coexist()
	failures += _check_faces_and_skirt()
	failures += _check_round_trip()

	if failures == 0:
		print("terrain data/sculpt checks: all passed")
	else:
		printerr("terrain data/sculpt checks: %d FAILED" % failures)
	quit(1 if failures > 0 else 0)


## Build one flat filled terrain to sculpt against.
func _flat_terrain(size: int, height_m: float = 0.0) -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i.ZERO, Vector2i(size, size))
	for z: int in size:
		for x: int in size:
			var cell := Vector2i(x, z)
			terrain.set_cell_filled(cell, true)
			terrain.set_cell_top(cell, PackedFloat32Array([
				height_m, height_m, height_m, height_m
			]))
	return terrain


## Stepping one cell must lift ONLY that cell and wall every seam around it.
##
## This is the exact failure the rework fixes: the old lattice edit dragged each
## neighbour's inner corners up with the brush, so the seam became a ramp and no
## wall could ever exist.
func _check_step_makes_walls() -> int:
	var failures := 0
	var terrain := _flat_terrain(5)
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.STEP_UP
	# Half a cell reaches exactly one cell centre, so the stroke is unambiguous.
	settings.size_m = 0.25
	settings.step_m = 0.25
	sculptor.configure(settings)

	sculptor.begin_stroke()
	sculptor.stamp(Vector2(2.5, 2.5))
	var stroke := sculptor.finish_stroke()

	var target := Vector2i(2, 2)
	failures += _expect(
		is_equal_approx(terrain.cell_walk_height(target), 0.25),
		"the stepped cell rose exactly one 0.25 m level, got %.4f"
			% terrain.cell_walk_height(target)
	)
	failures += _expect(
		terrain.is_cell_level(target),
		"the stepped cell stayed perfectly flat instead of tilting"
	)

	# The whole point: the neighbours must not have moved at all.
	for edge: int in 4:
		var neighbour: Vector2i = target + TerrainMesh.EDGE_NEIGHBOURS[edge]
		failures += _expect(
			is_equal_approx(terrain.cell_walk_height(neighbour), 0.0),
			"neighbour %s stayed at 0 m, got %.4f"
				% [neighbour, terrain.cell_walk_height(neighbour)]
		)
		failures += _expect(
			terrain.has_side_face(target, edge),
			"a real wall exists on edge %d of the stepped cell" % edge
		)
		var span := terrain.side_face(target, edge)
		if span.size() == 2:
			failures += _expect(
				is_equal_approx(float(span[1]) - float(span[0]), 0.25),
				"the wall on edge %d spans exactly the 0.25 m step, got %.4f"
					% [edge, float(span[1]) - float(span[0])]
			)

	# The undo patch must carry the walls, not just the heights, or undo would
	# re-derive walls instead of restoring the ones that were there.
	failures += _expect(
		not (stroke.get("before_sides", {}) as Dictionary).is_empty(),
		"the sculpt patch recorded the side faces it changed"
	)
	sculptor.apply_patch(
		stroke["cells"],
		stroke["before_tops"],
		stroke["before_sides"]
	)
	failures += _expect(
		is_equal_approx(terrain.cell_walk_height(target), 0.0)
			and not terrain.has_side_face(target, TerrainMesh.EDGE_NORTH),
		"undo restored the flat ground and removed the wall"
	)
	return failures


## A slope brush must move every cell meeting a grid corner, leaving no wall.
func _check_slope_stays_continuous() -> int:
	var failures := 0
	var terrain := _flat_terrain(5)

	# Move one grid corner: all four cells around it must follow it exactly.
	failures += _expect(
		terrain.set_lattice_corner_height(Vector2i(2, 2), 1.0),
		"moving a grid corner reported a change"
	)
	var corner_cells: Array = [
		[Vector2i(1, 1), 3],
		[Vector2i(2, 1), 2],
		[Vector2i(1, 2), 1],
		[Vector2i(2, 2), 0],
	]
	for entry: Array in corner_cells:
		failures += _expect(
			is_equal_approx(terrain.cell_corner(entry[0], int(entry[1])), 1.0),
			"cell %s shares the raised grid corner" % entry[0]
		)
	# Sharing the corner is exactly what makes the surface continuous, so no cell
	# around it may have gained a wall.
	var walled := 0
	for entry: Array in corner_cells:
		for edge: int in 4:
			if terrain.has_side_face(entry[0], edge):
				walled += 1
	failures += _expect(
		walled == 0,
		"a shared-corner slope produced no walls, found %d" % walled
	)
	# One raised corner twists the patch: its diagonals disagree, so it is a
	# SADDLE and deliberately not walkable as a single plane.
	failures += _expect(
		terrain.classify_cell(Vector2i(1, 1)) == TerrainMesh.CellForm.SADDLE,
		"a cell with one raised corner derives as a twisted SADDLE"
	)
	# Raising a whole edge gives a consistent gradient, which is a walkable ramp.
	terrain.set_lattice_corner_height(Vector2i(2, 2), 0.0)
	terrain.set_lattice_corner_height(Vector2i(1, 2), 1.0)
	terrain.set_lattice_corner_height(Vector2i(2, 2), 1.0)
	failures += _expect(
		terrain.classify_cell(Vector2i(1, 1)) == TerrainMesh.CellForm.RAMP,
		"a cell with one raised EDGE derives as a walkable RAMP, got %s"
			% terrain.cell_form_name(terrain.classify_cell(Vector2i(1, 1)))
	)
	return failures


## Both families must edit the same surface and blend without reconciliation.
func _check_families_coexist() -> int:
	var failures := 0
	var terrain := _flat_terrain(6)

	# Step a plateau up, then run a slope brush across it.
	terrain.set_cell_top_level(Vector2i(3, 3), 1.0)
	failures += _expect(
		terrain.has_side_face(Vector2i(3, 3), TerrainMesh.EDGE_WEST),
		"the stepped plateau has a wall before the slope pass"
	)
	terrain.set_lattice_corner_height(Vector2i(3, 3), 0.5)
	failures += _expect(
		is_equal_approx(terrain.cell_corner(Vector2i(3, 3), 0), 0.5)
			and is_equal_approx(terrain.cell_corner(Vector2i(2, 2), 3), 0.5),
		"the slope brush moved the same corner for every cell that meets it"
	)
	failures += _expect(
		is_equal_approx(terrain.cell_corner(Vector2i(3, 3), 3), 1.0),
		"the plateau's far corners kept the level the step brush set"
	)
	return failures


## Faces, bands and the skirt must all derive from the one stored surface.
func _check_faces_and_skirt() -> int:
	var failures := 0
	var terrain := _flat_terrain(4)
	terrain.set_cell_top_level(Vector2i(1, 1), 2.5)

	var faces := terrain.terrain_faces(8)
	var tops := 0
	var sides := 0
	var skirts := 0
	for face: Dictionary in faces:
		match int(face["kind"]):
			TerrainMesh.FaceKind.TOP:
				tops += 1
			TerrainMesh.FaceKind.SIDE:
				sides += 1
			_:
				skirts += 1
	failures += _expect(tops == 16, "one TOP face per filled cell, got %d" % tops)
	# A 2.5 m wall splits into three 1 m paintable bands on each of four edges.
	failures += _expect(
		sides == 12,
		"the 2.5 m wall banded into 3 bands on 4 edges, got %d" % sides
	)
	failures += _expect(skirts > 0, "the boundary emitted a closing skirt")
	failures += _expect(
		is_equal_approx(terrain.skirt_base_m, -1.0),
		"a 1 m skirt depth derives a -1 m base under zero-height terrain"
	)
	for face: Dictionary in faces:
		if int(face["kind"]) != TerrainMesh.FaceKind.SKIRT:
			continue
		failures += _expect(
			is_equal_approx(float(face["bottom_m"]), -1.0)
				and is_equal_approx(float(face["top_m"]), 0.0),
			"flat boundary skirt follows its top from 0 m to -1 m"
		)

	# Every band must address a distinct paint unit, or two walls would share one
	# image and painting either would repaint the other.
	var uids: Dictionary = {}
	for face: Dictionary in faces:
		if int(face["kind"]) != TerrainMesh.FaceKind.TOP:
			uids[String(face["paint_uid"])] = true
	failures += _expect(
		uids.size() == sides + skirts,
		"every band owns its own paint unit: %d units for %d bands"
			% [uids.size(), sides + skirts]
	)

	# Ground shares one paint unit per chunk, which is what keeps its surface
	# coordinate continuous across cells.
	var ground_uids: Dictionary = {}
	for face: Dictionary in faces:
		if int(face["kind"]) == TerrainMesh.FaceKind.TOP:
			ground_uids[String(face["paint_uid"])] = true
	# Ground is painted per CELL, exactly as it was when every cell was its own
	# 1 m quad. That is what keeps a texture at its authored size on the grid.
	failures += _expect(
		ground_uids.size() == tops,
		"every ground cell owns its own paint unit: %d units for %d cells"
			% [ground_uids.size(), tops]
	)

	# Geometry is checked through triangle_records because that is what the live
	# renderer builds its chunks from.
	var top_triangles := MTSTerrainMeshBuilder.triangle_records(
		_faces_of_kind(faces, TerrainMesh.FaceKind.TOP),
		([] as Array[Dictionary])
	)
	var side_triangles := MTSTerrainMeshBuilder.triangle_records(
		([] as Array[Dictionary]),
		_faces_of_kind(faces, TerrainMesh.FaceKind.SIDE)
	)
	failures += _expect(
		not top_triangles.is_empty() and not side_triangles.is_empty(),
		"the chunk emits ground and band geometry"
	)
	# Walls must face outward. Inverted winding lights them from inside the
	# terrain and renders them black.
	var outward := true
	for record: Dictionary in side_triangles:
		if absf((record["normal"] as Vector3).y) > 0.01:
			outward = false
	failures += _expect(outward, "every wall normal is horizontal")
	return failures


## Return only the faces of one kind, as the builder expects them.
func _faces_of_kind(faces: Array[Dictionary], kind: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for face: Dictionary in faces:
		if int(face["kind"]) == kind:
			out.append(face)
	return out


## Saving and reloading must preserve authored terrain without serializing the skirt invariant.
func _check_round_trip() -> int:
	var failures := 0
	var terrain := _flat_terrain(3)
	terrain.set_cell_top_level(Vector2i(1, 1), 1.75)
	var serialized := terrain.to_json()

	var restored := TerrainMesh.from_json(serialized)
	failures += _expect(
		restored.validate_definition().is_empty(),
		"the reloaded terrain validates"
	)
	failures += _expect(
		is_equal_approx(restored.cell_walk_height(Vector2i(1, 1)), 1.75),
		"the reloaded terrain kept its authored height"
	)
	failures += _expect(
		restored.side_faces.size() == terrain.side_faces.size(),
		"the reloaded terrain kept every wall"
	)
	failures += _expect(
		serialized.has("skirt_depth_m")
		and not serialized.has("skirt_base_m")
		and is_equal_approx(float(serialized["skirt_depth_m"]), 1.0),
		"saved terrain stores only the authored skirt depth"
	)

	# Growing the authored area must never move or resample existing terrain.
	var before := terrain.cell_walk_height(Vector2i(1, 1))
	terrain.expand_to_include(Rect2i(Vector2i(-4, -4), Vector2i(12, 12)))
	failures += _expect(
		is_equal_approx(terrain.cell_walk_height(Vector2i(1, 1)), before),
		"expanding the footprint preserved the sculpted cell"
	)
	return failures


## Report one assertion.
func _expect(condition: bool, message: String) -> int:
	if condition:
		print("  ok: %s" % message)
		return 0
	printerr("  FAIL: %s" % message)
	return 1
