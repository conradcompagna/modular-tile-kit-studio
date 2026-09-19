@tool
extends SceneTree

## Verify the terrain GLB decoder against the real Blender heightfield export.
##
## The decoder's contract is that the file and TerrainMesh are two serializations
## of the same structure, so this asserts the decode is EXACT rather than
## plausible: the authored cell count, four real corners per cell, the interior
## walls, the boundary skirt, and -- the one that matters most -- the vertical
## discontinuities where neighbouring cells hold different heights at the same
## grid corner. A shared-corner model destroys those, and destroying them is
## exactly what flattened imported maps into ramps.
##
## The reference export lives outside the project, so a missing file is reported
## and skipped rather than failing the suite.
const REFERENCE_GLB := "C:/Users/conra/Downloads/mesh_node_heightfield.glb"

## What the reference file itself declares, cross-checked against the decode.
const EXPECTED_CELLS: int = 1267
const EXPECTED_SIZE := Vector2i(38, 37)
const EXPECTED_ORIGIN := Vector2i(-19, -18)
const EXPECTED_WALL_EDGES: int = 452
const EXPECTED_SKIRT_EDGES: int = 152
const EXPECTED_LOGICAL_FACES: int = 3720
const EXPECTED_SKIRT_BASE_M: float = -9.922377586364746


func _init() -> void:
	_run.call_deferred()


## Run the decoder checks after global classes have entered the SceneTree.
func _run() -> void:
	var failures := 0
	failures += _check_contract_is_enforced()
	failures += _check_reference_export()
	if failures == 0:
		print("terrain GLB decoder checks: all passed")
	else:
		printerr("terrain GLB decoder checks: %d FAILED" % failures)
	quit(1 if failures > 0 else 0)


## An ordinary GLB carries no heightfield contract and must be refused by name.
##
## Silently importing arbitrary geometry as terrain would produce a plausible
## grid from a mesh that was never authored on a lattice, which is precisely the
## invention this decoder exists to prevent.
func _check_contract_is_enforced() -> int:
	var failures := 0
	var importer := TerrainGLBImporter.new()
	var missing_error := importer._contract_error(
		"res://does_not_exist_heightfield.glb",
		{}
	)
	failures += _expect(
		not missing_error.is_empty(),
		"a file with no heightfield metadata is refused"
	)
	failures += _expect(
		missing_error.contains("hf_grid_size_m"),
		"the refusal names the missing contract: %s" % missing_error
	)
	return failures


## Decode the real export and assert its exact authored structure survived.
func _check_reference_export() -> int:
	if not FileAccess.file_exists(REFERENCE_GLB):
		print("  skip: reference export not present at %s" % REFERENCE_GLB)
		return 0

	var failures := 0
	var importer := TerrainGLBImporter.new()

	var extras := importer.read_heightfield_extras(REFERENCE_GLB)
	failures += _expect(
		is_equal_approx(float(extras.get("hf_grid_size_m", 0.0)), 1.0),
		"the export declares the 1 m grid this editor is built on"
	)
	failures += _expect(
		int(extras.get("hf_top_cell_count", 0)) == EXPECTED_CELLS,
		"the export declares %d top cells" % EXPECTED_CELLS
	)

	var result := importer.read(REFERENCE_GLB)
	failures += _expect(
		bool(result.get("ok", false)),
		"the reference export decodes: %s" % String(result.get("error", ""))
	)
	if not bool(result.get("ok", false)):
		return failures

	var terrain := result["terrain"] as TerrainMesh
	failures += _expect(
		int(result.get("filled_cells", 0)) == EXPECTED_CELLS,
		"decoded %d cells, expected %d"
			% [int(result.get("filled_cells", 0)), EXPECTED_CELLS]
	)
	failures += _expect(
		terrain.size_cells == EXPECTED_SIZE,
		"the grid spans %s, expected %s" % [terrain.size_cells, EXPECTED_SIZE]
	)
	failures += _expect(
		terrain.origin_cell == EXPECTED_ORIGIN,
		"the grid lands at %s, expected %s" % [terrain.origin_cell, EXPECTED_ORIGIN]
	)
	failures += _expect(
		int(result.get("wall_count", 0)) == EXPECTED_WALL_EDGES,
		"decoded %d interior walls, expected %d"
			% [int(result.get("wall_count", 0)), EXPECTED_WALL_EDGES]
	)
	failures += _expect(
		int(result.get("skirt_edges", 0)) == EXPECTED_SKIRT_EDGES,
		"decoded %d boundary edges, expected %d"
			% [int(result.get("skirt_edges", 0)), EXPECTED_SKIRT_EDGES]
	)
	failures += _expect(
		int(result.get("source_face_count", 0)) == EXPECTED_LOGICAL_FACES,
		"the GLB contains exactly %d authored terrain faces" % EXPECTED_LOGICAL_FACES
	)
	failures += _expect(
		int(result.get("canonical_face_count", 0)) == EXPECTED_LOGICAL_FACES,
		"canonical TerrainMesh preserves the exact %d-face count" % EXPECTED_LOGICAL_FACES
	)
	failures += _expect(
		is_equal_approx(terrain.skirt_base_m, EXPECTED_SKIRT_BASE_M),
		"the imported skirt plane initialized the dynamic base at %.6f"
			% terrain.skirt_base_m
	)

	var tapered_profiles := 0
	var partial_profiles := 0
	for record: Dictionary in terrain.side_face_records():
		if (
			not is_equal_approx(
				float(record["start_bottom_m"]),
				float(record["end_bottom_m"])
			)
			or not is_equal_approx(
				float(record["start_top_m"]),
				float(record["end_top_m"])
			)
		):
			tapered_profiles += 1
		if (
			not is_zero_approx(float(record["start_t"]))
			or not is_equal_approx(float(record["end_t"]), 1.0)
		):
			partial_profiles += 1
	failures += _expect(
		tapered_profiles > 400,
		"the decode retained %d tapered source wall profiles" % tapered_profiles
	)
	failures += _expect(
		partial_profiles == 2,
		"the one crossing wall retained two complementary owned profiles"
	)

	# The decisive check. Adjacent cells must be free to disagree at a shared grid
	# corner; every disagreement is one vertical discontinuity a corner lattice
	# would have flattened into a ramp.
	var disagreements := 0
	for local_z: int in terrain.size_cells.y:
		for local_x: int in terrain.size_cells.x:
			var cell := terrain.origin_cell + Vector2i(local_x, local_z)
			if not terrain.is_cell_filled(cell):
				continue
			# Both grid points along each shared edge are compared. Corner indices
			# are 0=(x,z) 1=(x+1,z) 2=(x,z+1) 3=(x+1,z+1), so the east edge pairs
			# this cell's 1,3 against the neighbour's 0,2, and the south edge pairs
			# 2,3 against 0,1.
			var east := cell + Vector2i(1, 0)
			if terrain.is_cell_filled(east):
				if absf(terrain.cell_corner(cell, 1) - terrain.cell_corner(east, 0)) > 0.001:
					disagreements += 1
				if absf(terrain.cell_corner(cell, 3) - terrain.cell_corner(east, 2)) > 0.001:
					disagreements += 1
			var south := cell + Vector2i(0, 1)
			if terrain.is_cell_filled(south):
				if absf(terrain.cell_corner(cell, 2) - terrain.cell_corner(south, 0)) > 0.001:
					disagreements += 1
				if absf(terrain.cell_corner(cell, 3) - terrain.cell_corner(south, 1)) > 0.001:
					disagreements += 1
	failures += _expect(
		disagreements > 800,
		"the decode preserved %d vertical discontinuities at shared grid corners"
			% disagreements
	)

	# An imported map must be ordinary terrain: sculptable and paintable at once.
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.STEP_UP
	settings.size_m = 0.25
	settings.step_m = 0.5
	sculptor.configure(settings)
	var bounds := terrain.filled_bounds_cells()
	var probe := bounds.position + bounds.size / 2
	if terrain.is_cell_filled(probe):
		var before := terrain.cell_walk_height(probe)
		sculptor.begin_stroke()
		sculptor.stamp(Vector2(probe) + Vector2(0.5, 0.5))
		sculptor.finish_stroke()
		failures += _expect(
			terrain.cell_walk_height(probe) > before,
			"an imported map accepts the step brush immediately"
		)

	var renderer := MTSTerrainRenderer.new()
	failures += _expect(
		renderer.rebuild(terrain, 8, null),
		"the imported terrain builds renderable chunks"
	)
	failures += _expect(
		renderer.chunks().size() > 1,
		"a 38x37 board splits into several 8 m paint chunks, got %d"
			% renderer.chunks().size()
	)
	renderer.free()
	renderer = null
	sculptor = null
	terrain = null
	result.clear()
	importer = null
	return failures


## Report one assertion.
func _expect(condition: bool, message: String) -> int:
	if condition:
		print("  ok: %s" % message)
		return 0
	printerr("  FAIL: %s" % message)
	return 1
