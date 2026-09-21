@tool
extends Node

const Fixture := preload("res://tests/fixtures/public_board.gd")
var failures := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if not Engine.is_editor_hint():
		push_error("Run this test through tools/run_godot_checks.py --suite editor.")
		get_tree().quit(1)
		return
	await get_tree().create_timer(0.2).timeout
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	var library := Fixture.library()
	var board := Fixture.board(library)
	board.resource_path = "user://placement_viewport_fixture.tres"
	var viewport := MTSStudioViewport.new()
	viewport.size = Vector2(640, 480)
	get_tree().root.add_child(viewport)
	await get_tree().process_frame
	var manager := EditorInterface.get_editor_undo_redo()
	viewport.bind(board, library, SurfaceMaterialFactory.new(), manager)
	var controller := viewport.placement
	controller.set_brush(library.get_asset("FIXTURE_STONE"))
	var hit := controller.pick_terrain_from_ray(Vector3(-0.5, 10, 0.5), Vector3.DOWN)
	_check(not hit.is_empty(), "picking reaches the canonical terrain")
	var points := controller._bresenham_points(Vector2i.ZERO, Vector2i(2, 2))
	_check(points == [Vector2i.ZERO, Vector2i(1, 1), Vector2i(2, 2)], "diagonal fill visits exact grid cells")
	var added := SurfacePlacement.create("FIXTURE_STONE", Vector3i(-1, 0, 0), MTSConstants.Face.POS_Y, 0)
	added.placement_uid = "fixture-undo-paint"
	added.terrain_face_uids = PackedStringArray(["t:-1,0"])
	var observed_counts: Array[int] = []
	controller.board_mutated.connect(func(_mask: int) -> void: observed_counts.append(board.surfaces.size()))
	var world_identity := viewport.world_root.get_instance_id()
	var prior_paint := board.surface_at_paint_uid("t:0,0")
	controller._commit_placements_bulk([added], "Fixture terrain paint")
	_check(board.surface_at_paint_uid("t:-1,0") == added, "placement command updates canonical face ownership")
	_check(board.surfaces.size() == 3, "placement command adds exactly one record")
	var history := manager.get_history_undo_redo(manager.get_object_history_id(board))
	history.undo()
	_check(board.surfaces.size() == 2 and board.surface_at_paint_uid("t:-1,0") == null, "undo removes placement and occupancy index")
	history.redo()
	_check(board.surfaces.size() == 3 and board.surface_at_paint_uid("t:-1,0") == added, "redo restores the same resource identity")
	_check(observed_counts == [3, 2, 3], "mutation observers run after canonical state changes in both directions")
	_check(viewport.world_root.get_instance_id() == world_identity, "incremental paint commands retain the viewport world")
	_check(board.surface_at_paint_uid("t:0,0") == prior_paint, "neighboring paint ownership remains intact")
	_check(not viewport.terrain_renderer.chunk_instances().is_empty(), "current heightfield renderer produces terrain batches")
	controller._commit_remove_surface(added, "Fixture remove paint")
	_check(board.surface_at_paint_uid("t:-1,0") == null, "erase command removes only its targeted face")
	history.undo()
	_check(board.surface_at_paint_uid("t:-1,0") == added, "erase undo restores its resource and index")
	history.clear_history()
	viewport.queue_free()
	await get_tree().process_frame
	print("Placement/viewport failures: %d" % failures)
	_finish.call_deferred(1 if failures else 0)


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error(label)


## Let fixture locals release their rendering resources before engine teardown.
func _finish(code: int) -> void:
	get_tree().quit(code)
