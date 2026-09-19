extends SceneTree

## Focused regression for incremental viewport synchronization and fixed-camera renderer options.

var constants_script: Script
var tile_asset_script: Script
var asset_library_script: Script
var board_document_script: Script
var surface_placement_script: Script
var prop_placement_script: Script
var blockout_slot_script: Script
var surface_box_placement_script: Script
var material_factory_script: Script
var viewport_script: Script

var failures: int = 0


## Load the production classes and defer the fixture until the SceneTree can host the viewport.
func _init() -> void:
	constants_script = load("res://addons/modular_tile_studio/utils/mts_constants.gd")
	tile_asset_script = load("res://addons/modular_tile_studio/data/tile_asset.gd")
	asset_library_script = load("res://addons/modular_tile_studio/data/asset_library.gd")
	board_document_script = load("res://addons/modular_tile_studio/data/board_document.gd")
	surface_placement_script = load("res://addons/modular_tile_studio/data/surface_placement.gd")
	prop_placement_script = load("res://addons/modular_tile_studio/data/prop_placement.gd")
	blockout_slot_script = load("res://addons/modular_tile_studio/data/blockout_slot.gd")
	surface_box_placement_script = load("res://addons/modular_tile_studio/data/surface_box_placement.gd")
	material_factory_script = load("res://addons/modular_tile_studio/rendering/surface_material_factory.gd")
	viewport_script = load("res://addons/modular_tile_studio/viewport/studio_viewport.gd")
	call_deferred("_run_checks")


## Record one assertion with a precise failure message.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("VIEWPORT INCREMENTAL CHECK FAILED: %s" % message)


## Quit only after the large fixture coroutine has returned and released its local render resources.
func _finish(exit_code: int) -> void:
	quit(exit_code)


## Emit the normal placement mutation signal after directly changing the fixture board.
func _notify_placement_mutated(
	viewport: MTSStudioViewport,
	mutation_mask: int = MTSPlacementController.BoardMutation.ALL
) -> void:
	viewport.placement.board_mutated.emit(mutation_mask)


## Return the only GLB component batch expected from the one-mesh fixture asset.
func _only_prop_batch(viewport: MTSStudioViewport) -> MultiMeshInstance3D:
	if viewport._prop_batches_by_key.size() != 1:
		return null
	return viewport._prop_batches_by_key.values()[0] as MultiMeshInstance3D


## Exercise surface and prop deltas, spatial chunks, renderer toggles, persistence, and idle rendering.
func _run_checks() -> void:
	var K: Script = constants_script
	var surface_asset := tile_asset_script.new() as TileAsset
	surface_asset.asset_id = "INCREMENTAL_SURFACE"
	surface_asset.source_type = K.SourceType.IMAGE_SURFACE
	surface_asset.grid_bounds = Vector3i.ONE
	surface_asset.source_path = "res://icon.svg"

	var prop_asset := tile_asset_script.new() as TileAsset
	prop_asset.asset_id = "INCREMENTAL_PROP"
	prop_asset.source_type = K.SourceType.GLB_PROP
	prop_asset.source_path = "res://incremental_fixture.glb"
	prop_asset.grid_bounds = Vector3i.ONE
	prop_asset.prop_voxels = [Vector3i.ZERO]
	prop_asset.solid_cells = [Vector3i.ZERO]

	var library := asset_library_script.new() as AssetLibrary
	library.assets.append(surface_asset)
	library.assets.append(prop_asset)
	library.rebuild_index()

	var board := board_document_script.new() as BoardDocument
	board.bind_library(library)
	var material_factory := material_factory_script.new() as SurfaceMaterialFactory
	var viewport := viewport_script.new() as MTSStudioViewport
	get_root().add_child(viewport)

	# A cached in-memory source tree keeps this regression independent of imported
	# GLB files while exercising the exact production duplication/material path.
	var source_model := Node3D.new()
	var source_mesh := MeshInstance3D.new()
	source_mesh.name = "FixtureMesh"
	var fixture_mesh := ArrayMesh.new()
	var fixture_arrays: Array = []
	fixture_arrays.resize(Mesh.ARRAY_MAX)
	fixture_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
	])
	fixture_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	fixture_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fixture_arrays)
	var fixture_material := StandardMaterial3D.new()
	fixture_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	fixture_mesh.surface_set_material(0, fixture_material)
	source_mesh.mesh = fixture_mesh
	source_model.add_child(source_mesh)
	viewport._real_mesh_cache[prop_asset.source_path] = source_model
	viewport.bind(board, library, material_factory, null)

	# A raised wide canopy with one tiny ground stake reproduces the tent failure:
	# visual grime remains local to the stake while support must span the full GLB.
	var stake_asset := tile_asset_script.new() as TileAsset
	stake_asset.asset_id = "LOW_STAKE_WIDE_PROP"
	stake_asset.source_type = K.SourceType.GLB_PROP
	stake_asset.source_path = "res://low_stake_wide_fixture.glb"
	stake_asset.grid_bounds = Vector3i(6, 2, 7)
	var stake_source_model := Node3D.new()
	var stake_source_mesh := MeshInstance3D.new()
	var stake_mesh := ArrayMesh.new()
	var stake_arrays: Array = []
	stake_arrays.resize(Mesh.ARRAY_MAX)
	stake_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.1, 0.0, 0.0),
		Vector3(0.0, 0.0, 0.1),
		Vector3(0.0, 1.0, 0.0),
		Vector3(6.0, 1.0, 0.0),
		Vector3(6.0, 1.0, 7.0),
		Vector3(0.0, 1.0, 7.0),
	])
	stake_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5, 3, 5, 6])
	stake_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, stake_arrays)
	stake_source_mesh.mesh = stake_mesh
	stake_source_model.add_child(stake_source_mesh)
	viewport._real_mesh_cache[stake_asset.source_path] = stake_source_model
	var stake_prop := prop_placement_script.create(
		stake_asset.asset_id,
		Vector3i.ZERO,
		K.Face.NEG_Z,
		0
	) as PropPlacement
	var stake_contact: Array = viewport._prop_contact_polygons(stake_prop, stake_asset)
	var stake_contact_bounds: Rect2 = viewport.world_surface_fields._polygon_union_bounds(stake_contact)
	_check(
		maxf(stake_contact_bounds.size.x, stake_contact_bounds.size.y) < 0.5,
		"visual contact should remain confined to a prop's real low stake"
	)

	# A soft-edged stroke is one continuous capsule. Reapplying its start in the
	# segment must not create a circular double-strength bump.
	viewport.board.terrain = TerrainMesh.create(Vector2i(-8, -8), Vector2i(24, 24))
	for terrain_z: int in 24:
		for terrain_x: int in 24:
			viewport.board.terrain.set_cell_filled(
				Vector2i(terrain_x - 8, terrain_z - 8),
				true
			)
	viewport._bind_terrain_sculptor()
	var sculptor := TerrainSculptor.new(viewport.board.terrain)
	var stroke_settings := TerrainSculptor.Settings.new()
	stroke_settings.mode = TerrainSculptor.Mode.FLATTEN
	stroke_settings.size_m = 1.5
	stroke_settings.strength = 1.0
	stroke_settings.hardness = 1.0
	stroke_settings.flatten_target_m = 1.0
	sculptor.configure(stroke_settings)
	var stroke_start := Vector2(2.0, 2.0)
	var stroke_end := stroke_start + Vector2(2.0, 0.0)
	var stroke_middle := stroke_start.lerp(stroke_end, 0.5)
	sculptor.begin_stroke()
	sculptor.stamp(stroke_start)
	sculptor.stamp_segment(stroke_start, stroke_end)
	var stroke_patch := sculptor.finish_stroke()
	var terrain_grid: TerrainMesh = viewport.board.terrain
	_check(
		terrain_grid.sample_world_height(stroke_start) > 0.9
		and terrain_grid.sample_world_height(stroke_middle) > 0.9
		and terrain_grid.sample_world_height(stroke_end) > 0.9,
		"a swept stroke should be continuous and event-normalized without gaps"
	)
	# A sculpt patch carries the cells' top faces AND the side faces the edit
	# changed, so undo restores the walls that were there rather than re-deriving
	# them from the corner heights.
	var stroke_cells_value: Variant = stroke_patch.get("cells", PackedVector2Array())
	var stroke_before_value: Variant = stroke_patch.get("before_tops", PackedFloat32Array())
	var stroke_after_value: Variant = stroke_patch.get("after_tops", PackedFloat32Array())
	var stroke_before_sides: Variant = stroke_patch.get("before_sides", {})
	var stroke_after_sides: Variant = stroke_patch.get("after_sides", {})
	_check(
		stroke_cells_value is PackedVector2Array
		and stroke_before_value is PackedFloat32Array
		and stroke_after_value is PackedFloat32Array
		and stroke_before_sides is Dictionary
		and stroke_after_sides is Dictionary,
		"a completed stroke should expose one typed sparse undo patch"
	)
	if (
		stroke_cells_value is PackedVector2Array
		and stroke_before_value is PackedFloat32Array
		and stroke_after_value is PackedFloat32Array
	):
		sculptor.apply_patch(stroke_cells_value, stroke_before_value, stroke_before_sides)
		_check(
			absf(terrain_grid.sample_world_height(stroke_middle)) < 0.001,
			"applying the sparse before-values should undo the complete stroke"
		)
		sculptor.apply_patch(stroke_cells_value, stroke_after_value, stroke_after_sides)
		_check(
			terrain_grid.sample_world_height(stroke_middle) > 0.9,
			"applying the sparse after-values should redo the complete stroke"
		)

	# Terrain persists inside the board JSON, so a round trip must restore the
	# exact authored corners rather than reference a separate sidecar file.
	var terrain_board_copy := BoardDocument.new()
	_check(
		terrain_board_copy.from_json(viewport.board.to_json()) == OK
		and terrain_board_copy.terrain.sample_world_height(stroke_middle) > 0.9,
		"board JSON should carry the exact authored terrain"
	)
	viewport.world_surface_fields.project_terrain(terrain_board_copy.terrain)
	_check(
		viewport.world_surface_fields.sample_height_world(stroke_middle) > 0.9,
		"projected terrain should reach the derived GPU field"
	)
	viewport.world_surface_fields.project_terrain(TerrainMesh.new())
	_check(
		absf(viewport.world_surface_fields.sample_height_world(stroke_middle)) < 0.001,
		"a board with no terrain should project a cleared field"
	)

	var first := surface_placement_script.create(
		surface_asset.asset_id,
		Vector3i(0, 0, 0),
		K.Face.POS_Y,
		0
	) as SurfacePlacement
	board.add_surface(first)
	_notify_placement_mutated(viewport)
	var first_node := viewport._surface_nodes_by_placement_id.get(
		first.get_instance_id(),
		null
	) as Node3D
	var first_batch_key: String = viewport._surface_batch_key(first, surface_asset)
	var first_batch := viewport._surface_batches_by_key.get(
		first_batch_key,
		null
	) as MultiMeshInstance3D

	var second := surface_placement_script.create(
		surface_asset.asset_id,
		Vector3i(32, 0, 0),
		K.Face.POS_Y,
		0
	) as SurfacePlacement
	board.add_surface(second)
	_notify_placement_mutated(viewport)
	_check(
		first_node == viewport._surface_nodes_by_placement_id.get(first.get_instance_id(), null),
		"adding a distant surface should preserve the first surface collision node"
	)
	_check(
		first_batch == viewport._surface_batches_by_key.get(first_batch_key, null),
		"adding a distant surface should preserve the first spatial MultiMesh node"
	)
	_check(
		viewport._surface_batches_by_key.size() == 2,
		"surfaces 32 m apart should occupy two cullable chunks"
	)

	var second_batch_key: String = viewport._surface_batch_key(second, surface_asset)
	var second_batch := viewport._surface_batches_by_key.get(
		second_batch_key,
		null
	) as MultiMeshInstance3D
	var third := surface_placement_script.create(
		surface_asset.asset_id,
		Vector3i(33, 0, 0),
		K.Face.POS_Y,
		0
	) as SurfacePlacement
	board.add_surface(third)
	_notify_placement_mutated(viewport)
	_check(
		second_batch == viewport._surface_batches_by_key.get(second_batch_key, null),
		"adding inside a chunk should reuse that chunk's MultiMesh node"
	)
	_check(
		second_batch.multimesh.instance_count == 2,
		"adding inside a chunk should update only its instance buffer"
	)

	board.remove_surface(third)
	_notify_placement_mutated(viewport)
	_check(
		second_batch == viewport._surface_batches_by_key.get(second_batch_key, null),
		"removing inside a non-empty chunk should preserve its MultiMesh node"
	)
	_check(
		second_batch.multimesh.instance_count == 1,
		"removing a surface should shrink only its affected instance buffer"
	)

	var first_prop := prop_placement_script.create(
		prop_asset.asset_id,
		Vector3i(0, 0, 4),
		K.Face.NEG_Z,
		0
	) as PropPlacement
	board.add_prop(first_prop)
	_notify_placement_mutated(viewport)
	var first_prop_node := viewport._prop_nodes_by_placement_id.get(
		first_prop.get_instance_id(),
		null
	) as Node3D
	var first_prop_batch := _only_prop_batch(viewport)
	_check(
		first_prop_batch != null and first_prop_batch.multimesh.instance_count == 1,
		"one GLB prop should create one component MultiMesh with one instance"
	)

	var second_prop := prop_placement_script.create(
		prop_asset.asset_id,
		Vector3i(4, 0, 4),
		K.Face.NEG_Z,
		0
	) as PropPlacement
	board.add_prop(second_prop)
	_notify_placement_mutated(viewport)
	_check(
		first_prop_node == viewport._prop_nodes_by_placement_id.get(first_prop.get_instance_id(), null),
		"adding a prop should preserve every unrelated prop hierarchy"
	)
	_check(
		first_node == viewport._surface_nodes_by_placement_id.get(first.get_instance_id(), null),
		"adding a prop should not rebuild surface collision nodes"
	)
	_check(
		first_batch == viewport._surface_batches_by_key.get(first_batch_key, null),
		"adding a prop should not rebuild surface MultiMeshes"
	)
	var second_prop_batch := _only_prop_batch(viewport)
	_check(
		first_prop_batch == second_prop_batch,
		"adding a matching GLB prop should reuse its component MultiMesh node"
	)
	_check(
		second_prop_batch != null and second_prop_batch.multimesh.instance_count == 2,
		"matching GLB props in one chunk should occupy one MultiMesh instance buffer"
	)


	board.remove_prop(second_prop)
	_notify_placement_mutated(viewport)
	_check(
		first_prop_node == viewport._prop_nodes_by_placement_id.get(first_prop.get_instance_id(), null),
		"removing a prop should preserve every unrelated prop hierarchy"
	)
	_check(
		first_prop_batch == _only_prop_batch(viewport)
		and first_prop_batch.multimesh.instance_count == 1,
		"removing a matching GLB prop should retain the remaining MultiMesh node and transform"
	)


	# Keep a surfaced box present while growing the board because the former
	# mutation path rebuilt every box and every surface for any prop change.
	var wall_slot: Variant = blockout_slot_script.create_surface_box(
		"Incremental wall",
		Vector3i(2, 3, 1)
	)
	_check(bool(board.add_slot(wall_slot)["valid"]), "large-board fixture slot should be valid")
	var wall_box: Variant = surface_box_placement_script.create_for_slot(
		wall_slot.slot_id,
		Vector3i(24, 0, 20)
	)
	board.add_surface_box(wall_box)
	_check(board.surface_boxes.has(wall_box), "large-board fixture box should be valid")
	_notify_placement_mutated(viewport)
	var wall_box_node := viewport._surface_box_nodes_by_placement_id.get(
		wall_box.get_instance_id(),
		null
	) as Node3D

	var large_surfaces: Array[SurfacePlacement] = []
	for surface_x: int in range(20):
		for surface_z: int in range(20, 40):
			large_surfaces.append(surface_placement_script.create(
				surface_asset.asset_id,
				Vector3i(surface_x, 0, surface_z),
				K.Face.POS_Y,
				0
			) as SurfacePlacement)
	board.add_surfaces_bulk(large_surfaces)
	_check(
		board.surfaces.size() >= large_surfaces.size(),
		"large-board fixture surfaces should be valid"
	)
	_notify_placement_mutated(viewport)
	var preserved_surface_node := viewport._surface_nodes_by_placement_id.get(
		first.get_instance_id(),
		null
	) as Node3D
	var preserved_surface_batch := viewport._surface_batches_by_key.get(
		first_batch_key,
		null
	) as MultiMeshInstance3D
	var preserved_wall_box_node := viewport._surface_box_nodes_by_placement_id.get(
		wall_box.get_instance_id(),
		null
	) as Node3D
	_check(
		wall_box_node == preserved_wall_box_node,
		"adding unrelated surfaces should preserve an existing surfaced-box node"
	)

	# Keep one hundred cached GLBs in the live scene so the single-prop mutation
	# checks below prove their work remains independent of total prop geometry.
	var stress_props: Array[PropPlacement] = []
	for prop_x: int in range(2, 13):
		for prop_z: int in range(2, 11):
			if prop_x == 8 and prop_z == 4:
				continue
			stress_props.append(prop_placement_script.create(
				prop_asset.asset_id,
				Vector3i(prop_x, 0, prop_z),
				K.Face.NEG_Z,
				0
			) as PropPlacement)
	stress_props.append(prop_placement_script.create(
		prop_asset.asset_id,
		Vector3i(13, 0, 2),
		K.Face.NEG_Z,
		0
	) as PropPlacement)
	var bulk_prop_started_usec := Time.get_ticks_usec()
	board.add_props_bulk(stress_props)
	_notify_placement_mutated(viewport)
	var bulk_prop_elapsed_ms := float(
		Time.get_ticks_usec() - bulk_prop_started_usec
	) / 1000.0
	_check(board.props.size() == 100, "stress fixture should contain one hundred GLBs")
	_check(
		preserved_surface_node == viewport._surface_nodes_by_placement_id.get(
			first.get_instance_id(),
			null
		)
		and preserved_surface_batch == viewport._surface_batches_by_key.get(
			first_batch_key,
			null
		)
		and preserved_wall_box_node == viewport._surface_box_nodes_by_placement_id.get(
			wall_box.get_instance_id(),
			null
		),
		"adding one hundred GLBs should preserve unrelated map geometry"
	)

	var selected_prop: Array[Resource] = []
	selected_prop.append(first_prop)
	viewport.placement.set_selected_placements(selected_prop, first_prop)
	var rotate_started_usec := Time.get_ticks_usec()
	_check(
		viewport.placement.rotate_selection(Vector3i.UP, true),
		"selection rotation should commit through the canonical placement path"
	)
	var rotate_elapsed_ms := float(Time.get_ticks_usec() - rotate_started_usec) / 1000.0
	var rotate_profile := viewport._last_incremental_profile_ms.duplicate(true)
	var rotate_contact_profile := viewport._last_contact_profile_ms.duplicate(true)
	_check(
		rotate_elapsed_ms < 50.0,
		(
			"rotating one GLB among 100 GLBs and 400 surfaces should stay under 50 ms "
			+ "(%.1f ms)"
		) % rotate_elapsed_ms
	)
	_check(
		preserved_surface_node == viewport._surface_nodes_by_placement_id.get(
			first.get_instance_id(),
			null
		),
		"selection rotation should preserve unrelated surface collision nodes"
	)
	_check(
		preserved_surface_batch == viewport._surface_batches_by_key.get(first_batch_key, null),
		"selection rotation should preserve unrelated surface MultiMeshes"
	)
	_check(
		preserved_wall_box_node == viewport._surface_box_nodes_by_placement_id.get(
			wall_box.get_instance_id(),
			null
		),
		"selection rotation should preserve unrelated surfaced-box nodes"
	)
	_check(
		first_prop_batch == _only_prop_batch(viewport),
		"selection rotation should update the existing GLB component batch"
	)

	var move_started_usec := Time.get_ticks_usec()
	_check(
		viewport.placement.move_selection_by(Vector3i.LEFT),
		"selection dragging should commit through the canonical placement path"
	)
	var move_elapsed_ms := float(Time.get_ticks_usec() - move_started_usec) / 1000.0
	var move_profile := viewport._last_incremental_profile_ms.duplicate(true)
	var move_contact_profile := viewport._last_contact_profile_ms.duplicate(true)
	_check(
		move_elapsed_ms < 50.0,
		(
			"moving one GLB among 100 GLBs and 400 surfaces should stay under 50 ms "
			+ "(%.1f ms)"
		) % move_elapsed_ms
	)
	_check(
		preserved_surface_node == viewport._surface_nodes_by_placement_id.get(
			first.get_instance_id(),
			null
		)
		and preserved_wall_box_node == viewport._surface_box_nodes_by_placement_id.get(
			wall_box.get_instance_id(),
			null
		),
		"selection movement should preserve unrelated surface and surfaced-box nodes"
	)

	var placed_prop := prop_placement_script.create(
		prop_asset.asset_id,
		Vector3i(8, 0, 4),
		K.Face.NEG_Z,
		0
	) as PropPlacement
	var place_started_usec := Time.get_ticks_usec()
	board.add_prop(placed_prop)
	_check(board.props.has(placed_prop), "regular GLB placement should be valid")
	_notify_placement_mutated(
		viewport,
		MTSPlacementController.BoardMutation.PROPS
	)
	var place_elapsed_ms := float(Time.get_ticks_usec() - place_started_usec) / 1000.0
	_check(
		place_elapsed_ms < 50.0,
		(
			"placing one GLB among 100 GLBs and 400 surfaces should stay under 50 ms "
			+ "(%.1f ms)"
		) % place_elapsed_ms
	)
	_check(
		preserved_surface_node == viewport._surface_nodes_by_placement_id.get(
			first.get_instance_id(),
			null
		)
		and preserved_surface_batch == viewport._surface_batches_by_key.get(
			first_batch_key,
			null
		)
		and preserved_wall_box_node == viewport._surface_box_nodes_by_placement_id.get(
			wall_box.get_instance_id(),
			null
		),
		"regular GLB placement should preserve all unrelated surface render state"
	)

	# Local sculpting must update the intersecting support and its existing GLB
	# instance buffer without rebuilding unrelated render or collision nodes.
	board.aesthetics.parallax_master = 1.0
	board.notify_look_changed()
	var sculpt_prop_node := viewport._prop_nodes_by_placement_id.get(
		first_prop.get_instance_id(),
		null
	) as Node3D
	var sculpt_support := (
		sculpt_prop_node.get_node_or_null("TerrainSupport") as Node3D
		if sculpt_prop_node != null
		else null
	)
	var sculpt_support_y_before := sculpt_support.position.y if sculpt_support != null else 0.0
	var sculpt_batch_before := _only_prop_batch(viewport)
	var sculpt_started_usec := Time.get_ticks_usec()
	var sculpt_center := Vector2(
		float(first_prop.origin.x) + 0.5,
		float(first_prop.origin.z) + 0.5
	)
	viewport.brush_world_height(sculpt_center, 1.25, 0.25, 1.0)
	viewport._upload_height_sculpt_preview()
	var sculpt_elapsed_ms := float(Time.get_ticks_usec() - sculpt_started_usec) / 1000.0
	_check(
		sculpt_support != null and sculpt_support.position.y > sculpt_support_y_before,
		"height sculpting should immediately raise the intersecting GLB support"
	)
	var sculpt_collision_points := viewport._placement_collision_points(first_prop)
	var sculpt_collision_min_y := INF
	for collision_point: Vector3 in sculpt_collision_points:
		sculpt_collision_min_y = minf(sculpt_collision_min_y, collision_point.y)
	var sculpt_support_height := board.prop_terrain_support_height(first_prop)
	_check(
		not sculpt_collision_points.is_empty()
		and is_equal_approx(sculpt_collision_min_y, sculpt_support_height),
		"selection, framing, and marquee collision points should share the exact GLB support height"
	)
	viewport._rebuild_selection_highlights()
	var selection_collision_volume := (
		viewport.selection_highlight_root.get_node_or_null("SelectionCollisionVolume")
		as MeshInstance3D
	)
	var selection_collision_bounds := (
		selection_collision_volume.global_transform * selection_collision_volume.get_aabb()
		if selection_collision_volume != null
		else AABB()
	)
	_check(
		selection_collision_volume != null
		and is_equal_approx(selection_collision_bounds.position.y, sculpt_support_height),
		"the visible selection collision volume should share the physics collision transform"
	)
	_check(
		sculpt_batch_before == _only_prop_batch(viewport),
		"height sculpting should update the existing affected GLB component batch"
	)
	_check(
		preserved_surface_node == viewport._surface_nodes_by_placement_id.get(
			first.get_instance_id(),
			null
		)
		and preserved_surface_batch == viewport._surface_batches_by_key.get(
			first_batch_key,
			null
		)
		and preserved_wall_box_node == viewport._surface_box_nodes_by_placement_id.get(
			wall_box.get_instance_id(),
			null
		),
		"height sculpting should preserve unrelated surface and surfaced-box state"
	)
	_check(
		sculpt_elapsed_ms < 100.0,
		"one local sculpt frame should remain interactive in the large fixture (%.1f ms)" % sculpt_elapsed_ms
	)
	viewport._commit_height_sculpt()

	board.aesthetics.backface_culling_enabled = true
	board.aesthetics.one_sided_shadows_enabled = true
	board.notify_look_changed()
	var live_second_batch := viewport._surface_batches_by_key.get(
		second_batch_key,
		null
	) as MultiMeshInstance3D
	var surface_material := (
		live_second_batch.material_override as ShaderMaterial
		if live_second_batch != null
		else null
	)
	_check(
		surface_material != null
		and surface_material.shader.code.contains("render_mode cull_back,"),
		"Back-face culling should select the culled variant of the canonical surface shader"
	)
	_check(
		live_second_batch != null
		and live_second_batch.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"One-sided shadows should set surface batches to SHADOW_CASTING_SETTING_ON"
	)
	_check(
		first_prop_batch != null
		and first_prop_batch.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"One-sided shadows should update GLB component MultiMesh nodes"
	)
	var prop_art_mesh := (
		first_prop_batch.multimesh.mesh
		if first_prop_batch != null and first_prop_batch.multimesh != null
		else null
	)
	var prop_material := (
		prop_art_mesh.surface_get_material(0) as BaseMaterial3D
		if prop_art_mesh != null
		else null
	)
	_check(
		prop_material != null and prop_material.cull_mode == BaseMaterial3D.CULL_BACK,
		"Back-face culling should derive a culled GLB component material for MultiMesh rendering"
	)

	var saved_aesthetics: Dictionary = board.aesthetics.to_json()
	var loaded_aesthetics := AestheticProfile.new()
	loaded_aesthetics.from_json(saved_aesthetics)
	_check(
		loaded_aesthetics.backface_culling_enabled
		and loaded_aesthetics.one_sided_shadows_enabled,
		"board-global renderer options should round-trip through aesthetics JSON"
	)

	viewport.request_render()
	await process_frame
	await process_frame
	_check(
		viewport.sub_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS,
		"the on-demand viewport should never return to continuous UPDATE_ALWAYS mode"
	)

	get_root().remove_child(viewport)
	viewport.free()
	source_model.free()
	stake_source_model.free()
	# Let the headless RenderingServer retire large transient texture resources
	# before process shutdown so Godot 4.6 does not race their final release.
	await process_frame
	await process_frame

	print("incremental phase profile: rotate=%s move=%s" % [rotate_profile, move_profile])
	print(
		"contact phase profile: rotate=%s move=%s"
		% [rotate_contact_profile, move_contact_profile]
	)
	print(
		(
			"viewport_incremental_check: %d failures; 100-GLB bulk %.2f ms; "
			+ "one-GLB rotate %.2f ms; move %.2f ms; sculpt %.2f ms"
		) % [
			failures,
			bulk_prop_elapsed_ms,
			rotate_elapsed_ms,
			move_elapsed_ms,
			sculpt_elapsed_ms,
		]
	)
	call_deferred("_finish", failures)
