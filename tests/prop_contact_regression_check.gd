extends SceneTree

const K := preload("res://addons/modular_tile_studio/utils/mts_constants.gd")
const TileAssetScript := preload("res://addons/modular_tile_studio/data/tile_asset.gd")
const AssetLibraryScript := preload("res://addons/modular_tile_studio/data/asset_library.gd")
const BoardDocumentScript := preload("res://addons/modular_tile_studio/data/board_document.gd")
const PropPlacementScript := preload("res://addons/modular_tile_studio/data/prop_placement.gd")
const PlacementControllerScript := preload("res://addons/modular_tile_studio/viewport/placement_controller.gd")
const TerrainSculptorScript := preload("res://addons/modular_tile_studio/generation/terrain_sculptor.gd")
const AssetInspectorPanelScript := preload("res://addons/modular_tile_studio/ui/asset_inspector_panel.gd")

var failures: int = 0


## Start the focused contact regression after controls can enter the SceneTree.
func _init() -> void:
	call_deferred("_run")


## Record one focused assertion and preserve a nonzero process result on failure.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("PROP CONTACT CHECK FAILED: %s" % message)


## Create one canonical one-voxel GLB asset for every contact fixture.
func _prop_asset() -> TileAsset:
	var asset: TileAsset = TileAssetScript.new()
	asset.asset_id = "CONTACT_PROP"
	asset.display_name = "Contact Prop"
	asset.source_type = K.SourceType.GLB_PROP
	asset.grid_bounds = Vector3i.ONE
	asset.requested_grid_size = Vector3i.ONE
	asset.prop_voxels = [Vector3i.ZERO]
	return asset


## Return one filled rectangular heightfield with every top initially at zero.
func _filled_terrain(origin: Vector2i, size: Vector2i) -> TerrainMesh:
	var terrain := TerrainMesh.create(origin, size)
	for z: int in range(origin.y, origin.y + size.y):
		for x: int in range(origin.x, origin.x + size.x):
			terrain.set_cell_filled(Vector2i(x, z), true)
			terrain.set_cell_top_level(Vector2i(x, z), 0.0)
	return terrain


## Find the three-choice Off/Smooth/Stepped contact selector.
func _find_contact_mode(node: Node) -> OptionButton:
	if node is OptionButton:
		var option := node as OptionButton
		if (
			option.item_count == 3
			and option.get_item_text(0) == "Off"
			and option.get_item_text(1) == "Smooth"
			and option.get_item_text(2) == "Stepped"
		):
			return option
	for child: Node in node.get_children():
		var match := _find_contact_mode(child)
		if match != null:
			return match
	return null


## Find the explicit contact Apply button without matching unrelated asset actions.
func _find_contact_apply_button(node: Node) -> Button:
	if node is Button:
		var button := node as Button
		if button.text.begins_with("Apply ") and button.text.ends_with(" to All Instances"):
			return button
	for child: Node in node.get_children():
		var match := _find_contact_apply_button(child)
		if match != null:
			return match
	return null


## Exercise local wall ownership, fractional collision support, live reapply, and UI ownership.
func _run() -> void:
	var asset := _prop_asset()
	var library: AssetLibrary = AssetLibraryScript.new()
	library.assets.append(asset)
	library.rebuild_index()
	var board: BoardDocument = BoardDocumentScript.new()
	board.bind_library(library)

	# A real wall stands on the footprint quad's east seam. The pad levels onto the
	# requested plane and the drop that survives is rebuilt as a shorter wall rather
	# than left as an open hole beside a stale side face.
	var wall_terrain := _filled_terrain(Vector2i.ZERO, Vector2i(2, 1))
	wall_terrain.set_cell_top(
		Vector2i.ZERO,
		PackedFloat32Array([0.0, 2.0, 0.0, 2.0])
	)
	wall_terrain.rebuild_side_faces_for_cell(Vector2i.ZERO)
	wall_terrain.rebuild_side_faces_for_cell(Vector2i(1, 0))
	_check(
		wall_terrain.seam_carries_side_face(Vector2i.ZERO, TerrainMesh.EDGE_EAST),
		"the fixture should begin with one real wall on the footprint's east seam"
	)
	var sculptor := TerrainSculptorScript.new(wall_terrain)
	sculptor.begin_stroke()
	sculptor.flatten_cells([Vector2i.ZERO], 1.0)
	sculptor.finish_stroke()
	_check(
		wall_terrain.cell_relief(Vector2i.ZERO) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(wall_terrain.cell_walk_height(Vector2i.ZERO), 1.0),
		"the complete footprint quad should reach the requested plane"
	)
	_check(
		wall_terrain.seam_carries_side_face(Vector2i.ZERO, TerrainMesh.EDGE_EAST)
		and is_equal_approx(wall_terrain.cell_walk_height(Vector2i(1, 0)), 0.0),
		"the surviving drop should be rebuilt as a real wall instead of a hole"
	)

	# Cursor collision must stand at BoardDocument's complete-footprint support,
	# even when the exact pointed triangle has a different height.
	board.terrain = _filled_terrain(Vector2i.ZERO, Vector2i.ONE)
	board.terrain.set_cell_top(
		Vector2i.ZERO,
		PackedFloat32Array([0.2, 1.6, 0.2, 0.2])
	)
	asset.prop_contact_flatten = false
	var controller: MTSPlacementController = PlacementControllerScript.new()
	controller.board = board
	controller.library = library
	controller.set_brush(asset)
	get_root().add_child(controller)
	controller._apply_hover_pick({
		"hit": true,
		"cell": Vector3i.ZERO,
		"point": Vector3(0.25, 0.2, 0.25),
		"terrain_face": {"face": K.Face.POS_Y},
	})
	var preview_prop := controller._prop_placement_for_origin(Vector3i.ZERO)
	var expected_support := board.prop_terrain_support_height(preview_prop)
	_check(
		is_equal_approx(controller._preview_box.transform.origin.y, expected_support)
		and not is_equal_approx(expected_support, 0.2),
		"pink collision voxels should use the same fractional support as committed art"
	)
	_check(
		is_equal_approx(board.prop_world_origin(preview_prop).y, expected_support),
		"the canonical world pose should be that same support height"
	)
	asset.prop_contact_flatten = true
	controller._apply_hover_pick({
		"hit": true,
		"cell": Vector3i.ZERO,
		"point": Vector3(0.25, 0.2, 0.25),
		"terrain_face": {"face": K.Face.POS_Y},
	})
	# Ordinary placement decides where the GLB stands and the pad is levelled to it
	# afterwards, so enabling the setting must not move the preview at all.
	_check(
		is_equal_approx(controller._preview_box.transform.origin.y, expected_support),
		"enabling flatten must level the pad to the GLB, not move the GLB to a new plane"
	)

	# Turning the asset setting on after placement must process every instance.
	board.props.clear()
	board.terrain = _filled_terrain(Vector2i.ZERO, Vector2i(3, 1))
	board.terrain.set_lattice_corner_height(Vector2i(0, 0), 2.0)
	board.terrain.set_lattice_corner_height(Vector2i(3, 1), 3.0)
	var first := PropPlacementScript.create(
		asset.asset_id,
		Vector3i.ZERO,
		K.Face.POS_Z,
		0,
		0
	) as PropPlacement
	var second := PropPlacementScript.create(
		asset.asset_id,
		Vector3i(2, 0, 0),
		K.Face.POS_Z,
		0,
		0
	) as PropPlacement
	first.support = PropPlacement.SUPPORT_FLOOR
	second.support = PropPlacement.SUPPORT_FLOOR
	var existing: Array[PropPlacement] = [first, second]
	board.add_props_bulk(existing)
	asset.prop_contact_flatten = true
	asset.prop_contact_flatten_smooth = false
	_check(
		controller.apply_asset_contact_flatten(asset.asset_id) == 2,
		"enabling the asset toggle should process both existing instances"
	)
	_check(
		board.terrain.cell_relief(Vector2i.ZERO) <= TerrainMesh.LEVEL_EPSILON_M
		and board.terrain.cell_relief(Vector2i(2, 0)) <= TerrainMesh.LEVEL_EPSILON_M,
		"both existing instance footprints should be level after reapply"
	)
	# The pad is levelled to the height the props already stand at, so re-deriving
	# that height afterwards returns the same answer and there is nothing left to do.
	_check(
		controller.apply_asset_contact_flatten(asset.asset_id) == 0,
		"a second reapply should find nothing left to level"
	)

	# Distant instances stay as separate dirty regions; the span between them must
	# never become one merged map-wide calculation or viewport rebuild.
	var regional_board: BoardDocument = BoardDocumentScript.new()
	regional_board.bind_library(library)
	regional_board.terrain = _filled_terrain(Vector2i.ZERO, Vector2i(64, 5))
	regional_board.terrain.set_cell_top(
		Vector2i(4, 2),
		PackedFloat32Array([0.0, 1.0, 0.0, 1.0])
	)
	regional_board.terrain.set_cell_top(
		Vector2i(56, 2),
		PackedFloat32Array([0.0, 2.0, 0.0, 2.0])
	)
	var regional_first := PropPlacementScript.create(
		asset.asset_id,
		Vector3i(4, 0, 2),
		K.Face.POS_Z,
		0,
		0
	) as PropPlacement
	var regional_second := PropPlacementScript.create(
		asset.asset_id,
		Vector3i(56, 0, 2),
		K.Face.POS_Z,
		0,
		0
	) as PropPlacement
	regional_first.support = PropPlacement.SUPPORT_FLOOR
	regional_second.support = PropPlacement.SUPPORT_FLOOR
	regional_board.add_props_bulk([regional_first, regional_second])
	controller.board = regional_board
	var emitted_regions: Array[Rect2i] = []
	controller.prop_terrain_regions_mutated.connect(
		func(
			regions: Array[Rect2i],
			_support_props: Array[PropPlacement],
			_added_props: Array[PropPlacement],
			_removed_props: Array[PropPlacement],
			_paint_uids: PackedStringArray
		) -> void:
			emitted_regions.assign(regions)
	)
	_check(
		controller.apply_asset_contact_flatten(asset.asset_id) == 2,
		"the regional fixture should process both distant instances"
	)
	var middle_was_dirtied := false
	for region: Rect2i in emitted_regions:
		if region.has_point(Vector2i(30, 2)):
			middle_was_dirtied = true
	_check(
		emitted_regions.size() == 2 and not middle_was_dirtied,
		"distant instances should emit two local regions without the terrain between them"
	)

	# The no-tear invariant, in both modes. A GLB lands on an uneven raised plateau
	# whose every seam carries a wall. Afterwards each seam must still be either a
	# real side face or genuinely flush: writing corners without rebuilding is what
	# left moved quads beside walls that no longer reached them.
	for smooth_mode: bool in [false, true]:
		var mode_name := "smooth" if smooth_mode else "stepped"
		var plateau := _filled_terrain(Vector2i.ZERO, Vector2i(3, 3))
		plateau.set_cell_top_level(Vector2i.ONE, 1.5)
		plateau.set_cell_top(
			Vector2i.ONE,
			PackedFloat32Array([1.5, 1.5, 1.5, 0.9])
		)
		plateau.rebuild_side_faces_for_cell(Vector2i.ONE)
		var plateau_sculptor := TerrainSculptorScript.new(plateau)
		plateau_sculptor.begin_stroke()
		# 1.35 m is the mean of those four corners, which is the height
		# prop_terrain_support_height would stand the GLB at.
		if smooth_mode:
			plateau_sculptor.flatten_cells_smooth([Vector2i.ONE], 1.35)
		else:
			plateau_sculptor.flatten_cells([Vector2i.ONE], 1.35)
		plateau_sculptor.finish_stroke()
		_check(
			plateau.cell_relief(Vector2i.ONE) <= TerrainMesh.LEVEL_EPSILON_M
			and is_equal_approx(plateau.cell_walk_height(Vector2i.ONE), 1.35),
			"%s mode should level the whole footprint quad onto the placed height" % mode_name
		)
		_check(
			_terrain_walls_match_heights(plateau, Vector2i(3, 3)),
			"%s mode must leave no wall describing heights that moved" % mode_name
		)

	# With no wall on the boundary, smooth mode shares the footprint's corners with
	# the surrounding quads, so they slope away and the seam between them goes flush.
	var ramp := _filled_terrain(Vector2i.ZERO, Vector2i(2, 1))
	ramp.set_lattice_corner_height(Vector2i(1, 0), 1.0)
	ramp.set_lattice_corner_height(Vector2i(1, 1), 1.0)
	var ramp_sculptor := TerrainSculptorScript.new(ramp)
	ramp_sculptor.begin_stroke()
	ramp_sculptor.flatten_cells_smooth([Vector2i.ZERO], 0.5)
	ramp_sculptor.finish_stroke()
	_check(
		ramp.cell_relief(Vector2i.ZERO) <= TerrainMesh.LEVEL_EPSILON_M,
		"smooth mode should level the whole footprint quad on open ground"
	)
	_check(
		ramp.cell_relief(Vector2i(1, 0)) > TerrainMesh.LEVEL_EPSILON_M
		and not ramp.seam_carries_side_face(Vector2i.ZERO, TerrainMesh.EDGE_EAST),
		"smooth mode should slope the neighbour through the now-shared corners"
	)
	_check(
		_terrain_walls_match_heights(ramp, Vector2i(2, 1)),
		"the smooth transition must leave no stale wall profile"
	)

	# The GLB inspector stages one explicit state and mutates terrain only on Apply.
	asset.prop_contact_flatten = false
	asset.prop_contact_flatten_smooth = false
	var inspector: AssetInspectorPanel = AssetInspectorPanelScript.new()
	get_root().add_child(inspector)
	inspector.set_asset(asset)
	var contact_mode := _find_contact_mode(inspector)
	var apply_button := _find_contact_apply_button(inspector)
	_check(
		contact_mode != null and apply_button != null,
		"the selected GLB inspector should expose Off/Smooth/Stepped and an Apply button"
	)
	if contact_mode != null and apply_button != null:
		_check(
			contact_mode.selected == 0 and apply_button.text == "Apply Off to All Instances",
			"a disabled asset should display the exact stored Off state"
		)
		contact_mode.select(1)
		contact_mode.item_selected.emit(1)
		_check(
			not asset.prop_contact_flatten and not asset.prop_contact_flatten_smooth,
			"selecting Smooth should stage the mode without changing stored terrain behavior"
		)
		_check(
			apply_button.text == "Apply Smooth to All Instances",
			"the Apply label should expose the exact staged Smooth mode"
		)
		apply_button.pressed.emit()
		_check(
			asset.prop_contact_flatten and asset.prop_contact_flatten_smooth,
			"Apply should commit Smooth as the selected GLB's stored contact mode"
		)
		contact_mode.select(0)
		contact_mode.item_selected.emit(0)
		_check(
			asset.prop_contact_flatten and asset.prop_contact_flatten_smooth,
			"selecting Off should remain staged until Apply is pressed"
		)
		_check(
			apply_button.text == "Apply Off to All Instances",
			"the Apply label should expose the exact staged Off state"
		)
		apply_button.pressed.emit()
		_check(
			not asset.prop_contact_flatten and not asset.prop_contact_flatten_smooth,
			"Apply Off should disable terrain contact for the GLB and all instances"
		)

	get_root().remove_child(inspector)
	inspector.free()
	get_root().remove_child(controller)
	controller.free()
	print("prop_contact_regression_check: %d failures" % failures)
	quit(failures)


## Return whether one stored side-face profile matches another exactly.
func _profiles_match(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for index: int in first.size():
		if not is_equal_approx(float(first[index]), float(second[index])):
			return false
	return true


## Return whether every stored wall still describes the heights around it.
##
## The direct test, because the tear was never a missing wall: it was a wall whose
## stored bottom/top profile still described corners that had moved out from under
## it, so the face no longer reached the ground and the surface read as ripped.
## Re-deriving every seam on a duplicate and comparing catches that, a wall left
## standing where the drop has closed, and a drop left with no wall at all.
func _terrain_walls_match_heights(terrain: TerrainMesh, size: Vector2i) -> bool:
	var rebuilt := terrain.duplicate_terrain()
	for z: int in size.y:
		for x: int in size.x:
			rebuilt.rebuild_side_faces_for_cell(Vector2i(x, z))
	var intact := true
	var keys: Dictionary = {}
	for key: Variant in terrain.side_faces:
		keys[key] = true
	for key: Variant in rebuilt.side_faces:
		keys[key] = true
	for key: Variant in keys:
		var stored: Array = terrain.side_faces.get(key, [])
		var derived: Array = rebuilt.side_faces.get(key, [])
		if _profiles_match(stored, derived):
			continue
		push_error(
			"side face %s stores %s but the current heights imply %s"
			% [key, stored, derived]
		)
		intact = false
	return intact
