@tool
extends SceneTree

## Verify that everything is placed and painted on the heightfield's real faces.
##
## Two failures were reported against the imported-terrain path: props pinned to
## a flat grid instead of sitting on the surface under the cursor, and paint
## strokes landing where flat ground would have been. Both came from picking, so
## this drives the real picking code against sculpted terrain.
##
## It works from explicit world rays rather than a Camera3D. Picking takes a ray,
## so a camera adds nothing but a dependency on a display server -- which is what
## made this file hang under --headless.
func _init() -> void:
	var failures := 0
	failures += _check_picking()
	failures += _check_paint_units()
	if failures == 0:
		print("TERRAIN PLACEMENT OK")
	else:
		printerr("TERRAIN PLACEMENT FAILURES: %d" % failures)
	quit(1 if failures > 0 else 0)


## Build a 10x10 map with a stepped plateau, so it has both tops and real walls.
func _plateau_terrain() -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i(0, 0), Vector2i(10, 10))
	for z: int in 10:
		for x: int in 10:
			terrain.set_cell_filled(Vector2i(x, z), true)
	# Whole cells move, so the plateau's edges become real vertical walls rather
	# than ramps down to the surrounding ground.
	for z: int in range(4, 8):
		for x: int in range(4, 8):
			terrain.set_cell_top_level(Vector2i(x, z), 3.0)
	# One deliberately sloped cell proves a face keeps one lattice address even
	# though different pointer positions intersect it at different float heights.
	terrain.set_cell_top(
		Vector2i(1, 1),
		PackedFloat32Array([0.0, 1.0, 0.0, 1.0])
	)
	return terrain


## Picking must hit the real surface, including the vertical faces.
func _check_picking() -> int:
	var failures := 0
	var terrain := _plateau_terrain()
	var board := BoardDocument.new()
	board.terrain = terrain

	var prop_asset := TileAsset.new()
	prop_asset.asset_id = "TERRAIN_PROP"
	prop_asset.source_type = MTSConstants.SourceType.GLB_PROP
	prop_asset.grid_bounds = Vector3i(2, 1, 3)
	for z: int in prop_asset.grid_bounds.z:
		for y: int in prop_asset.grid_bounds.y:
			for x: int in prop_asset.grid_bounds.x:
				prop_asset.prop_voxels.append(Vector3i(x, y, z))
	var library := AssetLibrary.new()
	library.assets.append(prop_asset)
	library.rebuild_index()
	board.bind_library(library)

	var renderer := MTSTerrainRenderer.new()
	failures += _expect(
		renderer.rebuild(terrain, 8, null),
		"the plateau map builds renderable chunks"
	)

	var controller := MTSPlacementController.new()
	controller.board = board
	controller.library = library
	controller.terrain_renderer = renderer
	root.add_child(controller)
	controller.set_brush(prop_asset)

	# Straight down onto the middle of the plateau.
	var top_pick := controller.pick_terrain_from_ray(
		Vector3(5.5, 40.0, 5.5),
		Vector3.DOWN
	)
	failures += _expect(bool(top_pick.get("hit", false)), "a downward ray hits the terrain")
	if bool(top_pick.get("hit", false)):
		var point: Vector3 = top_pick.get("point", Vector3.ZERO)
		var cell: Vector3i = top_pick.get("cell", Vector3i.ZERO)
		print("plateau pick: ", point, "  cell: ", cell)
		failures += _expect(
			bool(top_pick.get("terrain", false)),
			"the pick reports that it came from terrain, not a flat layer"
		)
		# A flat-grid pick would report y = 0 here, which is exactly the pinning bug.
		failures += _expect(
			point.y > 2.9,
			"the pick lands on the plateau surface, not the flat grid, got y=%f" % point.y
		)
		failures += _expect(
			cell.y == 3,
			"the placement cell takes its layer from the terrain height, got %d" % cell.y
		)

	# Straight down onto the low ground beside the plateau.
	var low_pick := controller.pick_terrain_from_ray(
		Vector3(2.5, 40.0, 1.5),
		Vector3.DOWN
	)
	failures += _expect(
		bool(low_pick.get("hit", false))
			and absf(float((low_pick.get("point", Vector3.ZERO) as Vector3).y)) < 0.01,
		"the low ground beside the plateau picks at its own height"
	)

	# Two different heights on one slope must resolve to its one canonical grid
	# cell instead of rounding the hit point onto competing Y layers.
	var slope_low_pick := controller.pick_terrain_from_ray(
		Vector3(1.2, 40.0, 1.5),
		Vector3.DOWN
	)
	var slope_high_pick := controller.pick_terrain_from_ray(
		Vector3(1.8, 40.0, 1.5),
		Vector3.DOWN
	)
	failures += _expect(
		bool(slope_low_pick.get("hit", false))
			and bool(slope_high_pick.get("hit", false))
			and (slope_low_pick.get("cell", Vector3i(-1, -1, -1)) as Vector3i)
				== Vector3i(1, 0, 1)
			and (slope_high_pick.get("cell", Vector3i(-1, -1, -1)) as Vector3i)
				== Vector3i(1, 0, 1),
		"every point on one slope resolves to its canonical minimum grid corner"
	)
	controller.update_hover_from_ray(Vector3(1.8, 40.0, 1.5), Vector3.DOWN)
	failures += _expect(
		controller.hovered_cell == Vector3i(1, 0, 1),
		"the real hover path retains the slope's canonical grid address"
	)
	failures += _expect(
		controller.paint_at_hover(),
		"a GLB commits through the same slope hover path"
	)
	if not board.props.is_empty():
		var slope_prop: PropPlacement = board.props[-1]
		failures += _expect(
			slope_prop.origin == Vector3i(1, 0, 1),
			"the committed slope GLB retains the exact canonical origin"
		)

	# Horizontally into the plateau's east wall. A heightfield function cannot see
	# a vertical face at all, so this is the check that props and paint can reach
	# a wall band rather than only the walkable top.
	var wall_pick: Dictionary = renderer.pick_face(
		Vector3(9.0, 1.5, 5.5),
		Vector3(-1.0, 0.0, 0.0)
	)
	failures += _expect(not wall_pick.is_empty(), "a horizontal ray reaches the wall face")
	if not wall_pick.is_empty():
		failures += _expect(
			bool(wall_pick.get("is_wall", false)),
			"the ray reported a wall band rather than the ground above it"
		)
		var wall_point: Vector3 = wall_pick.get("point", Vector3.ZERO)
		failures += _expect(
			is_equal_approx(wall_point.x, 8.0),
			"the hit lands on the plateau's east face at x=8, got %.3f" % wall_point.x
		)
		var wall_face: Dictionary = wall_pick.get("face", {})
		failures += _expect(
			int(wall_face.get("kind", -1)) == TerrainMesh.FaceKind.SIDE,
			"the hit face is a real SIDE band"
		)
		# The band's own coordinate, not the ground's top-down projection.
		var uv: Vector2 = wall_pick.get("local_uv", Vector2.ZERO)
		failures += _expect(
			uv.x >= -0.01 and uv.x <= 1.01 and uv.y >= -0.01 and uv.y <= 1.01,
			"the wall's paint coordinate lies inside its own 1 m face, got %s" % uv
		)

	# The editor input path must turn the wall face into an outside minimum
	# corner and persist the outward face; no visual-only offset is allowed.
	controller.update_hover_from_ray(
		Vector3(9.0, 1.5, 5.5),
		Vector3(-1.0, 0.0, 0.0)
	)
	failures += _expect(
		controller.hovered_cell == Vector3i(8, 1, 5),
		"east-wall GLB origin begins exactly at the visible x=8 face"
	)
	failures += _expect(
		controller.paint_at_hover(),
		"a GLB commits through the same wall hover path"
	)
	if not board.props.is_empty():
		var wall_prop: PropPlacement = board.props[-1]
		failures += _expect(
			wall_prop.origin == Vector3i(8, 1, 5)
				and wall_prop.forward_face == MTSConstants.Face.POS_X
				and wall_prop.yaw_eighths == 0,
			"the wall GLB persists its outside origin and outward +X facing"
		)
		var slot := BlockoutSlot.create_prop("WALL_ROOT", prop_asset.grid_bounds)
		var slot_prop := PropPlacement.create_for_slot(
			slot.slot_id,
			wall_prop.origin,
			wall_prop.forward_face,
			wall_prop.roll_quarters,
			PropPlacement.SUPPORT_WALL,
			wall_prop.yaw_eighths
		)
		var viewport := MTSStudioViewport.new()
		var prop_root := viewport._build_prop_node(slot_prop, null, slot)
		failures += _expect(
			prop_root.position == Vector3(slot_prop.origin)
				and prop_root.get_node_or_null("TerrainSupport") == null
				and prop_root.get_node_or_null("Collision") != null,
			"wall art and collision begin at the canonical root with no hidden support offset"
		)
		prop_root.free()
		viewport.free()

	controller.queue_free()
	renderer.free()
	return failures


## A stroke must be accepted by the shared paint system, on ground and on walls.
func _check_paint_units() -> int:
	var failures := 0
	var terrain := _plateau_terrain()
	var board := BoardDocument.new()
	board.terrain = terrain

	var paint := MTSSurfaceMaterialPaint.new()
	paint.bind_profile(board.material_blend)
	var renderer := MTSTerrainRenderer.new()
	renderer.rebuild(terrain, 8, paint, board)

	# Ground is one paint unit per chunk, so it paints at the profile's full
	# texel density instead of one clamped image stretched over the whole board.
	var ground_uid := TerrainMesh.cell_top_uid(Vector2i(1, 1))
	failures += _expect(
		renderer.placement_for_uid(ground_uid) != null,
		"the chunk's ground carries a paint placement"
	)
	failures += _expect(
		renderer.paint_footprint_for_uid(ground_uid) == Vector2i.ONE,
		"the ground unit is exactly one square metre, got %s"
			% renderer.paint_footprint_for_uid(ground_uid)
	)
	failures += _expect(
		paint.brush_segment(
			ground_uid,
			Vector2i.ONE,
			Vector2(0.20, 0.20),
			Vector2(0.24, 0.24),
			0.5,
			0.75,
			1.0,
			0,
			false
		),
		"a ground stroke is accepted by the shared paint system"
	)

	# A wall band is its own 1 m unit, so painting it cannot touch the ground.
	var band_uid := TerrainMesh.band_uid(Vector2i(7, 5), TerrainMesh.EDGE_EAST, 0)
	failures += _expect(
		renderer.placement_for_uid(band_uid) != null,
		"the plateau's east wall band carries its own paint placement"
	)
	failures += _expect(
		renderer.paint_footprint_for_uid(band_uid) == Vector2i.ONE,
		"a wall band is exactly one square metre, got %s"
			% renderer.paint_footprint_for_uid(band_uid)
	)
	failures += _expect(
		paint.brush_segment(
			band_uid,
			Vector2i.ONE,
			Vector2(0.5, 0.5),
			Vector2(0.6, 0.6),
			0.4,
			0.75,
			1.0,
			1,
			false
		),
		"a wall stroke is accepted by the shared paint system"
	)
	failures += _expect(
		paint.has_image(band_uid) and paint.has_image(ground_uid),
		"ground and wall paint are stored under separate canonical uids"
	)
	failures += _expect(
		paint.image_for_uid(band_uid) != paint.image_for_uid(ground_uid),
		"painting a wall never writes into the ground's image"
	)

	# One world-space stroke must reach every unit it crosses, or a brush dragged
	# across a chunk boundary would clip at the first.
	var touched := renderer.faces_near_segment(
		Vector3(7.5, 3.0, 5.5),
		Vector3(9.5, 0.0, 5.5),
		1.0
	)
	failures += _expect(
		touched.size() > 1,
		"a stroke across the plateau edge reaches several faces, got %d" % touched.size()
	)
	var kinds: Dictionary = {}
	for face: Dictionary in touched:
		kinds[int(face["kind"])] = true
	failures += _expect(
		kinds.has(TerrainMesh.FaceKind.TOP) and kinds.has(TerrainMesh.FaceKind.SIDE),
		"that stroke reaches both ground and wall faces"
	)

	# Painting terrain must never create surface geometry.
	failures += _expect(
		board.surfaces.is_empty(),
		"painting terrain creates NO surface placements"
	)
	renderer.free()
	return failures


## Report one assertion.
func _expect(condition: bool, message: String) -> int:
	if condition:
		print("  ok: %s" % message)
		return 0
	printerr("  FAIL: %s" % message)
	return 1
