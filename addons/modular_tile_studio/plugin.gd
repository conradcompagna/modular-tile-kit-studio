@tool
extends EditorPlugin

## Modular Tile Kit Studio entry point (spec 2).
##
## Registers a main-screen workspace beside 2D / 3D / Script / Game, owns the
## authoritative BoardDocument and AssetLibrary, and connects to ComfyUI at
## startup so analysis is ready without the user wiring anything up.
##
## Every subsystem stays usable when ComfyUI is absent: the connection is probed
## in the background and failure only greys out the analysis buttons (spec 19).

const K := preload("utils/mts_constants.gd")
const TileStudioMainScene := preload("ui/tile_studio_main.gd")
const ComfyProvider := preload("analysis/comfyui_provider.gd")
const DerivedPipeline := preload("analysis/derived_map_pipeline.gd")
const ImageImporter := preload("importers/image_asset_importer.gd")
const Remover := preload("importers/background_remover.gd")
const GLBImporter := preload("importers/glb_asset_importer.gd")
const StudioBridge := preload("mcp/studio_bridge.gd")

var main_panel: TileStudioMain
var board: BoardDocument
var library: AssetLibrary
var particle_library: ParticleEffectLibrary
var material_factory: SurfaceMaterialFactory
var provider: ComfyUIProvider
var derived_pipeline: DerivedMapPipeline
var image_importer: ImageAssetImporter
var glb_importer: GLBAssetImporter
## Reads already-authored 1 m heightfield GLBs straight into the terrain grid.
var terrain_glb_importer: TerrainGLBImporter

var _current_board_path: String = ""
var bridge: MTSStudioBridge = null
var _poll_timer: Timer = null
var _poll_attempts: int = 0
var _channel_target: TileAsset = null
var _channel_name: String = ""
var _channel_dialog: FileDialog


func _enter_tree() -> void:
	_register_settings()

	library = AssetLibrary.load_or_create()
	_repair_missing_alpha_channels()
	var particle_library_script: Script = load(
		"res://addons/modular_tile_studio/data/particle_effect_library.gd"
	)
	particle_library = particle_library_script.new() as ParticleEffectLibrary
	if particle_library == null or not particle_library.load_or_create():
		push_error("[Tile Studio] Custom particle library could not be loaded.")
		return
	board = BoardDocument.new()
	board.bind_library(library)
	material_factory = SurfaceMaterialFactory.new()
	derived_pipeline = DerivedPipeline.new()
	image_importer = ImageImporter.new()
	glb_importer = GLBImporter.new()
	var terrain_glb_importer_script: Script = load(
		"res://addons/modular_tile_studio/importers/terrain_glb_importer.gd"
	)
	terrain_glb_importer = terrain_glb_importer_script.new() as TerrainGLBImporter

	main_panel = TileStudioMainScene.new()
	EditorInterface.get_editor_main_screen().add_child(main_panel)
	main_panel.hide()

	main_panel.viewport.bind(board, library, material_factory, get_undo_redo())
	main_panel.viewport.bind_particles(particle_library, get_undo_redo())
	main_panel.library_panel.bind(
		library,
		board,
		main_panel.viewport.surface_material_paint
	)
	main_panel.bind_material_paint(board, library)
	main_panel.bind_gameplay(board, library)
	main_panel.bind_particles(board, particle_library)
	main_panel.set_board_name(board.board_name)

	_connect_ui()
	_setup_provider()

	# Command bus so an external agent drives this exact workspace.
	bridge = StudioBridge.new()
	bridge.name = "MTSStudioBridge"
	bridge.plugin = self
	bridge.main_panel = main_panel
	main_panel.add_child(bridge)
	bridge.start(int(ProjectSettings.get_setting(K.SETTING_BRIDGE_PORT, StudioBridge.DEFAULT_PORT)))

	print("[Tile Studio] Modular Tile Kit Studio ready. 1 unit = 1 metre; fixed isometric camera.")


func _exit_tree() -> void:
	_stop_polling()
	if is_instance_valid(bridge):
		bridge.stop()
	if is_instance_valid(main_panel):
		main_panel.queue_free()
	main_panel = null


# --- Main screen plumbing -------------------------------------------------

func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Tile Studio"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("GridMap", "EditorIcons")


func _make_visible(visible: bool) -> void:
	if is_instance_valid(main_panel):
		main_panel.visible = visible


# --- Settings -------------------------------------------------------------

## Register project settings with defaults pointing at this machine's ComfyUI,
## so analysis works out of the box rather than needing manual configuration.
func _register_settings() -> void:
	_add_setting(K.SETTING_COMFY_URL, "http://127.0.0.1:8188", TYPE_STRING)
	_add_setting(K.SETTING_COMFY_RECIPES, "res://addons/modular_tile_studio/analysis/recipes", TYPE_STRING)
	_add_setting(K.SETTING_COMFY_TIMEOUT, 600.0, TYPE_FLOAT)
	_add_setting(K.SETTING_COMFY_AUTOSTART, false, TYPE_BOOL)
	_add_setting(K.SETTING_COMFY_PYTHON, "", TYPE_STRING)
	_add_setting(K.SETTING_COMFY_MAIN, "", TYPE_STRING)
	_add_setting(K.SETTING_COMFY_EXTRA_ARGS, "", TYPE_STRING)
	_add_setting(K.SETTING_BRIDGE_PORT, 47850, TYPE_INT)


func _add_setting(key: String, default_value: Variant, type: int) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.add_property_info({
		"name": key,
		"type": type,
	})


# --- ComfyUI --------------------------------------------------------------

## Bring the analysis backend up at plugin load.
##
## The probe is asynchronous and non-fatal: the editor is fully usable while it
## resolves, and a failed probe only means the analysis buttons stay disabled.
func _setup_provider() -> void:
	provider = ComfyProvider.new()
	provider.set_host(main_panel)
	provider.server_url = String(ProjectSettings.get_setting(K.SETTING_COMFY_URL, "http://127.0.0.1:8188"))
	provider.recipe_dir = String(ProjectSettings.get_setting(K.SETTING_COMFY_RECIPES, provider.recipe_dir))
	provider.timeout_seconds = float(ProjectSettings.get_setting(K.SETTING_COMFY_TIMEOUT, 600.0))

	provider.availability_changed.connect(_on_comfy_availability_changed)
	provider.probe_finished.connect(_on_comfy_probe_finished)
	provider.job_started.connect(_on_job_started)
	provider.job_progress.connect(_on_job_progress)
	provider.job_finished.connect(_on_job_finished)
	provider.job_failed.connect(_on_job_failed)

	main_panel.set_comfy_status(false, "connecting to %s" % provider.base_url())
	main_panel.inspector.set_recipes(provider.list_recipes())

	# Optionally start a local server, then probe either way.
	if bool(ProjectSettings.get_setting(K.SETTING_COMFY_AUTOSTART, false)):
		var extra := String(ProjectSettings.get_setting(K.SETTING_COMFY_EXTRA_ARGS, ""))
		var args := PackedStringArray()
		if not extra.strip_edges().is_empty():
			args = extra.split(" ", false)
		provider.try_autostart(
			String(ProjectSettings.get_setting(K.SETTING_COMFY_PYTHON, "")),
			String(ProjectSettings.get_setting(K.SETTING_COMFY_MAIN, "")),
			args
		)

	_begin_connection_polling()


## Poll until connected, then back off. An autostarting server takes a while to
## load its models, so the retry window is generous but bounded.
##
## Driven by a Timer node rather than `await create_timer(...)`: an awaited
## SceneTreeTimer keeps a pending coroutine alive across editor shutdown, which
## leaks. A Timer child dies with the panel.
func _begin_connection_polling() -> void:
	provider.check_connection()

	_poll_attempts = 0
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 5.0
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll_tick)
	main_panel.add_child(_poll_timer)
	_poll_timer.start()


func _on_poll_tick() -> void:
	if not is_instance_valid(main_panel) or provider == null:
		_stop_polling()
		return
	if provider.is_available():
		_stop_polling()
		return

	provider.check_connection()
	_poll_attempts += 1

	# Keep waiting while an autostarted server is still loading; otherwise stop
	# nagging after a few tries. The status label stays clickable for a retry.
	var give_up := not provider.is_autostarting() and _poll_attempts >= 3
	if _poll_attempts >= 40 or give_up:
		_stop_polling()
		if is_instance_valid(main_panel) and not provider.is_available():
			main_panel.set_comfy_status(false, "offline (click to retry)")


func _stop_polling() -> void:
	if is_instance_valid(_poll_timer):
		_poll_timer.stop()
		_poll_timer.queue_free()
	_poll_timer = null


func _on_comfy_availability_changed(available: bool) -> void:
	if not is_instance_valid(main_panel):
		return
	var detail := "connected" if available else "offline (click to retry)"
	main_panel.set_comfy_status(available, detail)
	main_panel.inspector.set_provider_state(available, detail)
	if available:
		main_panel.inspector.set_recipes(provider.list_recipes())


## Resolve the status label after every probe.
##
## availability_changed only fires on a TRANSITION, so clicking retry while the
## server is down produced no signal at all and the label sat on
## "reconnecting..." indefinitely. This always lands on a final answer.
func _on_comfy_probe_finished(available: bool) -> void:
	if not is_instance_valid(main_panel):
		return
	var detail := "connected" if available else "offline (click to retry)"
	main_panel.set_comfy_status(available, detail)
	main_panel.inspector.set_provider_state(available, detail)


func _on_job_started(_job_id: String, asset_id: String) -> void:
	print("[Tile Studio] analysis started for %s" % asset_id)


func _on_job_progress(_job_id: String, message: String, fraction: float) -> void:
	if is_instance_valid(main_panel):
		main_panel.set_comfy_status(true, "%s (%d%%)" % [message, int(fraction * 100.0)])


## Assign returned maps, then run the deterministic derived stage.
##
## The asset is only touched once outputs actually arrived, so a failed job
## never corrupts it (spec 19).
func _on_job_finished(_job_id: String, asset_id: String, outputs: Dictionary) -> void:
	var asset := library.get_asset(asset_id)
	if asset == null:
		return
	if asset.gbuffer == null:
		asset.gbuffer = GBufferMapSet.new()

	# The metrics side-channel (see ComfyUIProvider._collect_outputs_main) is
	# not a map path, so it is pulled out before the remaining entries are
	# assigned as channels and before the status line below lists what was
	# received -- leaving it in either would put "__moge_metrics" in a
	# gbuffer slot or in the user-facing analysis status text.
	var moge_metrics: Dictionary = outputs.get("__moge_metrics", {})
	outputs = outputs.duplicate()
	outputs.erase("__moge_metrics")

	for channel: String in outputs:
		asset.gbuffer.set_channel(channel, String(outputs[channel]))

	# MoGe reports this asset's own point-cloud extent directly -- no
	# derivation needed here. Absent (empty dict) leaves moge_extent_m at
	# whatever it already was, e.g. zero for a first analysis that failed to
	# report metrics, which SurfaceMaterialFactory treats as "not measured"
	# rather than as zero relief.
	if not moge_metrics.is_empty():
		asset.moge_extent_m = Vector3(
			float(moge_metrics.get("x_extent_m", 0.0)),
			float(moge_metrics.get("y_extent_m", 0.0)),
			float(moge_metrics.get("z_extent_m", 0.0))
		)

	# Make freshly written files visible to the resource system before the
	# material factory tries to load them.
	EditorInterface.get_resource_filesystem().scan()

	asset.analysis_status = "deriving maps..."
	main_panel.inspector.set_asset(asset)

	var derived := await _run_derived_async(asset)
	asset.analysis_status = "analyzed (%s)" % ", ".join(outputs.keys())
	if derived.size() > 0:
		asset.analysis_status += " + derived (%s)" % ", ".join(derived)

	_save_asset(asset)
	material_factory.invalidate(asset.asset_id)
	main_panel.viewport.refresh_asset_instances(asset.asset_id)
	main_panel.inspector.set_asset(asset)
	main_panel.set_comfy_status(true, "connected")
	print("[Tile Studio] analysis complete for %s: %s" % [asset_id, asset.analysis_status])


func _on_job_failed(_job_id: String, asset_id: String, reason: String) -> void:
	push_warning("[Tile Studio] analysis failed for %s: %s" % [asset_id, reason])
	if is_instance_valid(main_panel):
		main_panel.set_comfy_status(provider.is_available(), "job failed: %s" % reason.substr(0, 60))


# --- UI wiring ------------------------------------------------------------

func _connect_ui() -> void:
	main_panel.import_image_selected.connect(_on_import_image_selected)
	main_panel.import_glb_selected.connect(_on_import_glb_selected)
	main_panel.movement_collision_measure_requested.connect(
		_on_measure_placed_glb_collision
	)
	main_panel.import_terrain_glb_selected.connect(_on_import_terrain_glb_selected)
	main_panel.monster_glb_selected.connect(_on_monster_glb_selected)
	main_panel.new_board_requested.connect(_on_new_board)
	main_panel.open_board_requested.connect(_on_open_board)
	main_panel.save_board_requested.connect(_on_save_board)
	main_panel.export_json_requested.connect(_on_export_json)
	main_panel.rename_board_requested.connect(_on_rename_board)
	main_panel.comfy_reconnect_requested.connect(func() -> void:
		main_panel.set_comfy_status(false, "reconnecting...")
		provider.check_connection())

	main_panel.image_dialog.import_confirmed.connect(_on_image_import_confirmed)
	main_panel.glb_dialog.import_confirmed.connect(_on_glb_import_confirmed)

	main_panel.inspector.analyze_requested.connect(_on_analyze)
	main_panel.inspector.regenerate_derived_requested.connect(_on_regenerate_derived)
	main_panel.inspector.prop_rebuild_requested.connect(_on_prop_rebuild_requested)
	main_panel.inspector.channel_attach_requested.connect(_on_channel_attach)
	main_panel.inspector.channel_clear_requested.connect(_on_channel_clear)
	main_panel.inspector.remove_background_requested.connect(_on_remove_background)
	main_panel.inspector.asset_edited.connect(_on_asset_edited)
	main_panel.inspector.prop_contact_flatten_changed.connect(
		_on_prop_contact_flatten_changed
	)
	main_panel.inspector.restore_background_requested.connect(_on_restore_background)
	main_panel.library_panel.delete_asset_requested.connect(_on_delete_asset)
	main_panel.library_panel.remove_asset_from_level_requested.connect(
		_on_remove_asset_from_level
	)
	main_panel.name_dialog.name_confirmed.connect(_on_board_name_confirmed)

	main_panel.gameplay_marker_update_requested.connect(update_gameplay_marker)
	main_panel.gameplay_marker_delete_requested.connect(delete_gameplay_marker)
	main_panel.enemy_pack_create_requested.connect(create_enemy_pack)
	main_panel.enemy_pack_update_requested.connect(update_enemy_pack)
	main_panel.enemy_pack_delete_requested.connect(delete_enemy_pack)
	main_panel.enemy_pack_assign_requested.connect(assign_enemy_markers_to_pack)
	main_panel.monster_visual_assign_requested.connect(assign_monster_visual)
	main_panel.monster_visual_clear_requested.connect(clear_monster_visual)


# --- Blockout authoring ----------------------------------------------------


# --- Gameplay marker authoring --------------------------------------------


## Create one exact saved enemy pack from the visible panel or live API.
func create_enemy_pack(pack_id: String, note: String) -> Dictionary:
	var enemy_pack_script: Script = load(
		"res://addons/modular_tile_studio/data/enemy_pack.gd"
	)
	var pack := enemy_pack_script.create(pack_id, note) as EnemyPack
	var result := board.add_enemy_pack(pack)
	main_panel.show_gameplay_result(result)
	return result


## Update one existing pack's note while preserving its stable id and membership.
func update_enemy_pack(pack_id: String, note: String) -> Dictionary:
	var result := board.update_enemy_pack(pack_id, note)
	main_panel.show_gameplay_result(result)
	return result


## Delete one pack only through BoardDocument's explicit membership guard.
func delete_enemy_pack(pack_id: String) -> Dictionary:
	var result := board.remove_enemy_pack(pack_id)
	main_panel.show_gameplay_result(result)
	return result


## Assign one dragged enemy selection to one pack and rebuild its visible labels once.
func assign_enemy_markers_to_pack(
	marker_ids: PackedStringArray,
	pack_id: String
) -> Dictionary:
	var result := board.assign_enemy_markers_to_pack(marker_ids, pack_id)
	if bool(result.get("valid", false)):
		main_panel.viewport.refresh_gameplay_visuals()
	main_panel.show_gameplay_result(result)
	return result


## Assign one existing project GLB to every placement with the exact Monster ID.
func assign_monster_visual(monster_id: String, asset_id: String) -> Dictionary:
	var result := board.set_monster_visual_asset(monster_id, asset_id)
	if bool(result.get("valid", false)):
		main_panel.viewport.refresh_gameplay_visuals()
		main_panel.gameplay_panel.select_monster_id(monster_id)
	main_panel.show_gameplay_result(result)
	return result


## Clear one Monster ID's GLB assignment while leaving its placements untouched.
func clear_monster_visual(monster_id: String) -> Dictionary:
	var result := board.clear_monster_visual_asset(monster_id)
	if bool(result.get("valid", false)):
		main_panel.viewport.refresh_gameplay_visuals()
		main_panel.gameplay_panel.select_monster_id(monster_id)
	main_panel.show_gameplay_result(result)
	return result


## Atomically update the selected marker fields without moving its grid cell.
func update_gameplay_marker(
	marker_id: String,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> Dictionary:
	var result := board.update_gameplay_marker(
		marker_id,
		marker_type,
		note,
		monster_id,
		pack_id
	)
	if bool(result.get("valid", false)):
		main_panel.viewport.refresh_gameplay_visuals()
		main_panel.select_gameplay_marker(marker_id)
	main_panel.show_gameplay_result(result)
	return result


## Delete one exact marker id and preserve every unrelated pack and marker.
func delete_gameplay_marker(marker_id: String) -> Dictionary:
	var marker := board.get_gameplay_marker(marker_id)
	if marker == null:
		var missing := {
			"valid": false,
			"reason": "unknown gameplay marker '%s'" % marker_id,
		}
		main_panel.show_gameplay_result(missing)
		return missing
	board.remove_gameplay_marker(marker)
	main_panel.viewport.refresh_gameplay_visuals()
	var result := {"valid": true, "reason": "", "marker": marker_id}
	main_panel.show_gameplay_result(result)
	return result


# --- Import ---------------------------------------------------------------

func _on_import_image_selected(path: String) -> void:
	main_panel.image_dialog.setup(path, library.make_unique_id(path.get_file().get_basename()))
	main_panel.image_dialog.popup_centered()


func _on_image_import_confirmed(source_path: String, settings: Dictionary) -> void:
	var asset := image_importer.import_image(source_path, settings, library)
	if asset == null:
		return
	library.save()
	# Note the import against the open level before the panel redraws, so the level
	# view can account for it whether or not it is ever placed.
	board.note_imported_asset(asset.asset_id)
	main_panel.library_panel.refresh()
	main_panel.library_panel.select_asset(asset)
	# Selecting it as the brush is the point: it must be paintable immediately.
	main_panel.inspector.set_asset(asset)
	main_panel.viewport.placement.set_brush(asset)
	_request_filesystem_scan()
	print("[Tile Studio] imported surface '%s' (%d x %d m)" % [
		asset.asset_id, asset.grid_bounds.x, asset.grid_bounds.y
	])


func _on_import_glb_selected(path: String) -> void:
	_prepare_glb_import(path, "")


## Explicitly measure raw collision shares for placed legacy GLBs that lack them.
##
## Assets are deduplicated before scanning, then every instance and runtime
## collision refreshes through the board's one global threshold.
func _on_measure_placed_glb_collision() -> void:
	var assets_to_measure: Dictionary = {}
	for placement: PropPlacement in board.props:
		var asset := board.resolve_prop_asset(placement)
		if asset != null and not asset.prop_collision_measurements_ready():
			assets_to_measure[asset.asset_id] = asset
	if assets_to_measure.is_empty():
		main_panel.set_status("Movement Grid: every placed GLB is already measured.")
		if main_panel.movement_grid_panel != null:
			main_panel.movement_grid_panel.show_collision_result(
				board.movement_collision_filter_report()
			)
		return

	var measured := 0
	var failed := PackedStringArray()
	for asset_value: Variant in assets_to_measure.values():
		var asset := asset_value as TileAsset
		main_panel.set_status(
			"Movement Grid: measuring collision for %s..." % asset.asset_id
		)
		if glb_importer.refresh_collision_measurements(asset):
			measured += 1
		else:
			failed.append(asset.asset_id)
	library.save()
	board.rebuild_indexes()
	main_panel.viewport.refresh_movement_grid_collision()
	main_panel.library_panel.refresh()
	if main_panel.movement_grid_panel != null:
		main_panel.movement_grid_panel.show_collision_result(
			board.movement_collision_filter_report()
		)
	if failed.is_empty():
		main_panel.set_status(
			"Movement Grid: measured %d placed GLB assets." % measured
		)
	else:
		main_panel.set_status(
			"Movement Grid: measured %d; failed: %s."
			% [measured, ", ".join(failed)]
		)


## Adopt one already-authored heightfield GLB as board terrain.
##
## The decoder preserves its exact 1 m cell tops, slope corners, wall profiles,
## and boundary base in TerrainMesh, which is the same canonical terrain used by
## painting, prop placement, collision, picking, and gameplay data.
func _on_import_terrain_glb_selected(path: String) -> void:
	var result := terrain_glb_importer.read(path)
	if not bool(result.get("ok", false)):
		main_panel.set_status("Terrain import failed: %s" % String(result.get("error", "")))
		return
	var grid := result.get("terrain", null) as TerrainMesh
	if not main_panel.viewport.adopt_imported_terrain(grid):
		main_panel.set_status("Terrain import failed: the board rejected the decoded terrain.")
		return
	var size_cells: Vector2i = result.get("size_cells", Vector2i.ZERO)
	main_panel.set_status(
		"Imported terrain '%s': %d x %d m, %d cells, %d sloped." % [
			path.get_file(),
			size_cells.x,
			size_cells.y,
			int(result.get("filled_cells", 0)),
			int(result.get("sloped_cells", 0)),
		]
	)
	print(
		"[Tile Studio] imported terrain GLB '%s' (%d x %d m, %d cells)"
		% [
			path.get_file(),
			size_cells.x,
			size_cells.y,
			int(result.get("filled_cells", 0)),
		]
	)


## Open the normal grid-first GLB sizing dialog with one explicit Monster ID context.
func _on_monster_glb_selected(path: String, monster_id: String) -> void:
	_prepare_glb_import(path, monster_id)


## Inspect an external GLB before any project asset or monster assignment is mutated.
func _prepare_glb_import(path: String, monster_id: String) -> void:
	var info: Dictionary = glb_importer.inspect(path)
	if info.is_empty():
		push_error("[Tile Studio] could not inspect '%s'" % path)
		return
	main_panel.glb_dialog.setup(
		path,
		library.make_unique_id(path.get_file().get_basename()),
		info,
		monster_id
	)
	main_panel.glb_dialog.popup_centered()


## Import one project-owned GLB and optionally assign it to the contextual Monster ID.
func _on_glb_import_confirmed(source_path: String, settings: Dictionary) -> void:
	var assignment_monster_id := String(settings.get("_monster_visual_id", ""))
	var importer_settings := settings.duplicate(true)
	importer_settings.erase("_monster_visual_id")
	var asset: TileAsset = await glb_importer.import_glb(
		source_path,
		importer_settings,
		library
	)
	if asset == null:
		push_error("[Tile Studio] GLB import produced no asset")
		return
	library.save()
	# Note the import against the open level before the panel redraws, so the level
	# view can account for it whether or not it is ever placed.
	board.note_imported_asset(asset.asset_id)

	# Refresh the UI before scanning because the imported library is authoritative
	# and a concurrent filesystem reimport must not hide a completed asset.
	main_panel.library_panel.refresh()
	if not assignment_monster_id.is_empty():
		var result := board.set_monster_visual_asset(
			assignment_monster_id,
			asset.asset_id
		)
		main_panel.show_gameplay_result(result)
		if bool(result.get("valid", false)):
			main_panel.viewport.refresh_gameplay_visuals()
			main_panel.gameplay_panel.select_monster_id(assignment_monster_id)
		_request_filesystem_scan()
		print(
			"[Tile Studio] imported monster visual '%s' for '%s' (%.2f x %.2f x %.2f m)"
			% [
				asset.asset_id,
				assignment_monster_id,
				asset.visual_size_m.x,
				asset.visual_size_m.y,
				asset.visual_size_m.z,
			]
		)
		return

	main_panel.library_panel.select_asset(asset)
	main_panel.inspector.set_asset(asset)
	main_panel.viewport.placement.set_brush(asset)
	_request_filesystem_scan()
	print("[Tile Studio] imported prop '%s' (%.2f x %.2f x %.2f m, %d voxels)" % [
		asset.asset_id, asset.visual_size_m.x, asset.visual_size_m.y, asset.visual_size_m.z,
		asset.prop_voxels.size()
	])

# --- Board ----------------------------------------------------------------

## Replace the current document with a blank untitled board immediately.
##
## Naming is deliberately deferred until Save, so New Board is a reversible authoring
## transition in the UI rather than a naming workflow that can leave the old level
## visible while the user is still deciding what to call the new one.
func _on_new_board() -> void:
	board.clear()
	# BoardDocument replaces the canonical TerrainMesh during clear. Route that
	# replacement through the viewport's explicit clear path as well so the live
	# sculptor, mesh, collision, and target preview cannot retain the old level.
	main_panel.viewport.clear_terrain()
	board.reset_look()
	board.board_name = "Untitled Board"
	_current_board_path = ""

	main_panel.bind_look_panels(board)
	main_panel.bind_particles(board, particle_library)
	main_panel.viewport.reset_world_heightfield()
	main_panel.viewport.clear_surface_material_paint()
	main_panel.viewport.rebuild_board()
	main_panel.set_board_name(board.board_name)


## Open a board through the loader required by its explicit JSON representation.
##
## Blockout interchange documents contain declarative geometry, so they compile
## atomically before replacing the live board. Standard board saves already hold
## Open only the explicitly selected JSON and keep the live level unchanged until preparation succeeds.
func _on_open_board() -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.json", "Board JSON")
	main_panel.add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_error("[Tile Studio] cannot open board '%s'." % path)
			dialog.queue_free()
			return
		var text := file.get_as_text()
		var read_error := file.get_error()
		file.close()
		if read_error != OK:
			push_error(
				"[Tile Studio] cannot read board '%s' (%s)."
				% [path, error_string(read_error)]
			)
			dialog.queue_free()
			return

		var parsed_value: Variant = JSON.parse_string(text)
		if not parsed_value is Dictionary:
			push_error("[Tile Studio] board '%s' is not a JSON object." % path)
			dialog.queue_free()
			return
		var parsed: Dictionary = parsed_value
		var prepared_board: BoardDocument = null
		var report: Dictionary = {}
		var apply_prepared_look := true

		var preparation := board.prepare_json(parsed)
		var prepare_error := int(preparation.get("error", FAILED))
		if prepare_error != OK:
			push_error(
				"[Tile Studio] board '%s' could not be prepared (%s)."
				% [path, error_string(prepare_error)]
			)
		else:
			prepared_board = preparation.get("board", null) as BoardDocument
			report = preparation.get("report", {})

		if prepared_board != null:
			# Terrain travels inside the board JSON and was already validated by
			# the board parser, so only sparse material paint needs preflighting.
			var prepared_paint := main_panel.viewport.prepare_surface_material_paint(
				path,
				prepared_board.surface_material_paint
			)
			var paint_error := int(prepared_paint.get("error", FAILED))
			if paint_error != OK:
				push_error(
					"[Tile Studio] board '%s' was not loaded because its material paint failed (%s)."
					% [path, error_string(paint_error)]
				)
			elif main_panel.viewport.commit_prepared_board_load(
				prepared_board,
				prepared_paint,
				apply_prepared_look
			):
				_current_board_path = path
				# Atomic loading replaces the paint owner, so every level-derived asset
				# query must immediately follow the newly committed paint pixels.
				main_panel.library_panel.set_material_paint(
					main_panel.viewport.surface_material_paint
				)
				main_panel.set_board_name(board.board_name)
				if not bool(report.get("valid", true)):
					# Missing ordinary-board assets remain a visible warning,
					# while the already validated document still opens.
					push_warning("[Tile Studio] board loaded with issues: %s %s" % [
						report.get("errors", PackedStringArray()),
						report.get("missing_assets", PackedStringArray()),
					])
				if apply_prepared_look:
					main_panel.bind_look_panels(board)
			else:
				push_error(
					"[Tile Studio] prepared board could not replace the current level."
				)

		dialog.queue_free()
	)
	dialog.popup_centered_ratio(0.6)


func _on_save_board() -> void:
	if _current_board_path.is_empty():
		var suggested := ""
		if board.board_name != "Untitled Board":
			suggested = board.board_name

		main_panel.name_dialog.ask(
			"save",
			suggested,
			"Name this level before saving:"
		)
		return

	_save_current_board()


func _on_rename_board() -> void:
	main_panel.name_dialog.ask(
		"rename",
		board.board_name,
		"Rename this level:"
	)


func _on_board_name_confirmed(new_name: String, purpose: String) -> void:
	var clean := new_name.strip_edges()
	if clean.is_empty():
		return

	match purpose:
		"save":
			board.board_name = clean
			_current_board_path = _board_path_for_name(clean)
			main_panel.set_board_name(clean)
			_save_current_board()

		"rename":
			board.board_name = clean

			# An unsaved board gets a filename from its new name.
			if _current_board_path.is_empty():
				_current_board_path = _board_path_for_name(clean)

			main_panel.set_board_name(clean)
			_save_current_board()


func _board_path_for_name(board_name: String) -> String:
	var filename := board_name.to_snake_case()
	if filename.is_empty():
		filename = "board"
	return "res://boards/%s.json" % filename


## Save the board, whose JSON already carries the canonical terrain grid.
##
## Only sparse material paint still needs an adjacent sidecar, so it is written
## first and the board JSON is pointed at it in one atomic step.
func _save_current_board() -> void:
	if _current_board_path.is_empty():
		return

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_current_board_path.get_base_dir())
	)
	var paint_result := main_panel.viewport.save_surface_material_paint(_current_board_path)
	var paint_error := int(paint_result.get("error", FAILED))
	if paint_error != OK:
		push_error(
			"[Tile Studio] board save stopped because material-paint persistence failed (%s)."
			% error_string(paint_error)
		)
		return
	var paint_metadata_value: Variant = paint_result.get("metadata", {})
	if not paint_metadata_value is Dictionary:
		push_error("[Tile Studio] board save stopped because material-paint metadata is invalid.")
		return
	var previous_paint := board.surface_material_paint.duplicate(true)
	board.surface_material_paint = (paint_metadata_value as Dictionary).duplicate(true)
	var save_error := board.save_json(_current_board_path)
	if save_error != OK:
		board.surface_material_paint = previous_paint
		return
	print("[Tile Studio] board, terrain, and sparse material paint saved to %s" % _current_board_path)
	EditorInterface.get_resource_filesystem().scan()


## Export board JSON, which carries the canonical terrain grid inside it.
func _on_export_json() -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	dialog.add_filter("*.json", "Board JSON")
	dialog.current_file = "%s.json" % board.board_name.to_snake_case()
	main_panel.add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:

		var paint_result := main_panel.viewport.save_surface_material_paint(path)
		var paint_error := int(paint_result.get("error", FAILED))
		if paint_error != OK:
			push_error(
				"[Tile Studio] export stopped because material paint failed (%s)."
				% error_string(paint_error)
			)
			dialog.queue_free()
			return
		var paint_metadata_value: Variant = paint_result.get("metadata", {})
		if not paint_metadata_value is Dictionary:
			push_error("[Tile Studio] export stopped because material-paint metadata is invalid.")
			dialog.queue_free()
			return
		var previous_paint := board.surface_material_paint.duplicate(true)
		board.surface_material_paint = (paint_metadata_value as Dictionary).duplicate(true)
		var save_error := board.save_json(path)
		board.surface_material_paint = previous_paint
		if save_error == OK:
			print("[Tile Studio] exported board JSON, terrain, and material paint to %s" % path)
		dialog.queue_free())
	dialog.popup_centered_ratio(0.6)


# --- Inspector actions ----------------------------------------------------

func _on_analyze(asset: TileAsset, recipe: Dictionary) -> void:
	if not provider.is_available():
		push_warning("[Tile Studio] ComfyUI is not reachable at %s" % provider.base_url())
		return
	asset.analysis_status = "queued"
	main_panel.inspector.set_asset(asset)
	provider.analyze(asset, recipe)


## Apply Size: rebuild a prop from its untouched source GLB.
##
## Everything -- box, voxels, images -- is regenerated together, and the asset
## is only touched once all four facings have succeeded. A failure leaves the
## previous generation exactly as it was.
func _on_prop_rebuild_requested(asset: TileAsset, settings: Dictionary) -> void:
	if asset == null or not asset.is_prop():
		return

	main_panel.set_comfy_status(provider.is_available(), "rebuilding GLB...")

	var ok: bool = glb_importer.rebuild_prop(asset, settings)

	if not ok:
		push_error(
			"[Tile Studio] rebuild failed for '%s'; old asset left untouched."
			% asset.asset_id
		)
		main_panel.set_comfy_status(provider.is_available(), "GLB rebuild failed")
		return

	library.save()
	board.rebuild_indexes()

	# The rebuild replaced every image the materials were built from.
	material_factory.invalidate(asset.asset_id)

	main_panel.library_panel.refresh()
	main_panel.inspector.set_asset(asset)
	main_panel.viewport.refresh_asset_instances(asset.asset_id, true)
	main_panel.viewport.refresh_brush_preview()

	EditorInterface.get_resource_filesystem().scan()
	main_panel.set_comfy_status(provider.is_available(), "connected")

	print("[Tile Studio] rebuilt '%s' from source GLB" % asset.asset_id)


func _on_regenerate_derived(asset: TileAsset) -> void:
	var derived := await _run_derived_async(asset)

	if derived.is_empty():
		push_warning("[Tile Studio] nothing to derive for '%s' -- attach a depth or height channel first" % asset.asset_id)
		return
	EditorInterface.get_resource_filesystem().scan()
	_save_asset(asset)
	material_factory.invalidate(asset.asset_id)
	main_panel.viewport.refresh_asset_instances(asset.asset_id)
	main_panel.inspector.set_asset(asset)
	print("[Tile Studio] derived maps for %s: %s" % [asset.asset_id, ", ".join(derived)])


## Run derived-map generation on a detached worker copy of the asset.
##
## SceneTree/Resource access never leaves the editor thread; only filesystem
## math and image operations happen in the worker.
func _run_derived_async(asset: TileAsset) -> PackedStringArray:
	# Deep copy because the worker must not mutate the live resource that
	# the editor and renderer are using.
	var worker_asset := asset.duplicate(true) as TileAsset

	if worker_asset == null:
		return PackedStringArray()

	var worker := Thread.new()

	var start_error := worker.start(
		func() -> PackedStringArray:
			var pipeline := DerivedPipeline.new()
			return pipeline.process(worker_asset)
	)

	if start_error != OK:
		push_warning("[Tile Studio] could not start derived-map worker")
		return PackedStringArray()

	while worker.is_alive():
		await main_panel.get_tree().process_frame

	var result_variant := worker.wait_to_finish()
	var written := PackedStringArray()

	if result_variant is PackedStringArray:
		written = result_variant

	# Worker is finished. Copy only its resulting paths back to the live
	# asset, now on the main thread. Props have no gbuffer to derive maps for
	# any more -- they render from their own imported GLB materials -- so this
	# only ever applies to surfaces.
	if worker_asset.gbuffer != null:
		if asset.gbuffer == null:
			asset.gbuffer = GBufferMapSet.new()

		for channel: String in GBufferMapSet.CHANNELS:
			var path := worker_asset.gbuffer.get_channel(channel)
			if not path.is_empty():
				asset.gbuffer.set_channel(channel, path)

	return written


## Persist an inspector edit.
##
## A geometry change (tile size or surface presentation) alters structural
## occupancy, so the board indexes are rebuilt and revalidated. Existing placements
## are kept when a conflict remains because an explicit warning is safer than
## silently deleting the user's work.
func _on_asset_edited(asset: TileAsset, geometry_changed: bool) -> void:
	_save_asset(asset)
	material_factory.invalidate(asset.asset_id)
	library.save()

	if geometry_changed:
		board.rebuild_indexes()
		var report := board.validate_all()
		if not report["valid"]:
			push_warning("[Tile Studio] editing '%s' left invalid placements: %s" % [
				asset.asset_id, report["errors"]
			])

	main_panel.viewport.refresh_asset_instances(asset.asset_id, geometry_changed)
	# The brush may BE this asset, so the hover preview must re-read it or
	# the user keeps hovering the pre-edit footprint and places the wrong size.
	main_panel.viewport.refresh_brush_preview()
	main_panel.library_panel.refresh()


## Persist one edited GLB's exact Off, Smooth, or Stepped contact state.
## Enabled modes then apply locally to every existing floor instance; Off performs no terrain write.
func _on_prop_contact_flatten_changed(asset: TileAsset) -> void:
	if asset == null or not asset.is_prop() or main_panel == null:
		return
	# The staged contact controls commit only here, so choosing a dropdown item
	# never mutates terrain or leaves the asset's saved mode ahead of the board.
	_save_asset(asset)
	library.save()
	if asset.prop_contact_flatten:
		main_panel.viewport.apply_asset_contact_flatten(asset.asset_id)


## Rebuild the canonical alpha channel for surfaces whose cut was never bound to one.
##
## Assets imported before background removal wrote a standalone `alpha` channel
## recorded the cut ONLY in processing["background_removed"], which nothing
## rendered from. Their transparency was then destroyed outright the first time
## map analysis rewrote the derived albedo as RGB, which is why a
## background-removed decal rendered as an opaque black rectangle.
##
## The cut image is still on disk, so the mask is re-derived from it rather than
## re-running removal: this restores exactly the coverage the user already
## authored instead of recomputing a new one. Assets that already have an alpha
## channel are left completely alone, and every repair is logged.
func _repair_missing_alpha_channels() -> void:
	if library == null:
		return
	var repaired := 0
	for asset: TileAsset in library.assets:
		if asset == null or not asset.is_surface() or asset.gbuffer == null:
			continue
		if asset.gbuffer.has_channel("alpha"):
			continue
		var report: Dictionary = asset.processing.get("background_removed", {})
		var cut_path := String(report.get("path", ""))
		if cut_path.is_empty():
			continue
		var cut := Image.new()
		if cut.load(ProjectSettings.globalize_path(cut_path)) != OK:
			push_warning(
				"[Tile Studio] '%s' records a removed background at '%s' but it could not be read."
				% [asset.asset_id, cut_path]
			)
			continue
		var alpha_path := asset.derived_dir.path_join("alpha.png")
		if not Remover.write_alpha_mask(cut, alpha_path):
			continue
		asset.gbuffer.set_channel("alpha", alpha_path)
		report["alpha_path"] = alpha_path
		asset.processing["background_removed"] = report
		_save_asset(asset)
		repaired += 1
	if repaired > 0:
		library.save()
		print(
			"[Tile Studio] restored the alpha channel on %d surface(s) whose removed background was never bound to one."
			% repaired
		)


## Strip the flat background plate off an already-imported surface.
##
## Writes a NEW file beside the asset's derived maps and repoints the albedo at
## it; the stored source is never touched. That is what makes the operation
## reversible, and it means a bad cut costs the user nothing but a click of
## Restore.
func _on_remove_background(asset: TileAsset) -> void:
	if asset == null or not asset.is_surface():
		return

	var source := asset.processing.get("background_source", asset.source_path)
	var image := Image.new()
	if image.load(ProjectSettings.globalize_path(source)) != OK:
		push_warning("[Tile Studio] could not read '%s'" % source)
		return

	# Uncropped: the asset's metre size is already set, and cropping would
	# re-frame the art inside cells it was authored to fill.
	var result := Remover.remove_background(image, false)
	if not result.ok():
		push_warning("[Tile Studio] background removal failed for '%s': %s" % [asset.asset_id, result.error])
		return
	if result.removed_pixels == 0:
		push_warning("[Tile Studio] '%s' has no flat background at its border; nothing removed" % asset.asset_id)
		return

	var out := asset.derived_dir.path_join("albedo_nobg.png")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(asset.derived_dir))
	if result.image.save_png(ProjectSettings.globalize_path(out)) != OK:
		push_warning("[Tile Studio] could not write '%s'" % out)
		return

	# Remember which image the cut was taken FROM, so Restore has somewhere to
	# go back to even for an asset imported with the background already removed.
	# Written as a standalone channel as well as into the cut image: map analysis
	# rewrites the derived albedo as RGB, so transparency held only inside the
	# albedo is destroyed the first time this asset is analyzed.
	var alpha_path := asset.derived_dir.path_join("alpha.png")
	if not Remover.write_alpha_mask(result.image, alpha_path):
		alpha_path = ""

	asset.processing["background_source"] = source
	asset.processing["background_removed"] = {
		"path": out,
		"alpha_path": alpha_path,
		"removed_pixels": result.removed_pixels,
		"removed_fraction": result.removed_fraction(),
		"background": result.background_description(),
	}
	if asset.gbuffer == null:
		asset.gbuffer = GBufferMapSet.new()
	if alpha_path.is_empty():
		asset.gbuffer.clear_channel("alpha")
	else:
		asset.gbuffer.set_channel("alpha", alpha_path)
	_apply_albedo(asset, out)
	print("[Tile Studio] removed background from '%s' (%d px, %.0f%%)" % [
		asset.asset_id, result.removed_pixels, result.removed_fraction() * 100.0
	])


## Point a surface back at its untouched source art.
##
## The cut file is left on disk rather than deleted: removing the background
## again is then instant, and nothing the user might still want is thrown away.
func _on_restore_background(asset: TileAsset) -> void:
	if asset == null:
		return
	var original := String(asset.processing.get("background_source", asset.source_path))
	asset.processing.erase("background_removed")
	# Restoring the backdrop means there is no authored cut any more, so the
	# coverage channel is dropped rather than left masking art the user just
	# asked to see again.
	if asset.gbuffer != null:
		asset.gbuffer.clear_channel("alpha")
	_apply_albedo(asset, original)
	print("[Tile Studio] restored original background art for '%s'" % asset.asset_id)


## Repoint an asset's albedo at `path` and refresh everything that draws it.
##
## Shared by remove and restore so the two directions cannot drift apart: both
## have to rewrite the same channel, the same thumbnail, and invalidate the same
## cached material, or the board keeps showing the previous image.
func _apply_albedo(asset: TileAsset, path: String) -> void:
	if asset.gbuffer == null:
		asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", path)

	# The thumbnail is what the library grid shows, so it has to follow the art
	# or the user picks a brush by an image the board no longer uses.
	var thumb := Image.new()
	if thumb.load(ProjectSettings.globalize_path(path)) == OK:
		thumb.resize(128, 128, Image.INTERPOLATE_LANCZOS)
		var thumb_path := asset.derived_dir.path_join("thumbnail.png")
		if thumb.save_png(ProjectSettings.globalize_path(thumb_path)) == OK:
			asset.thumbnail_path = thumb_path

	_save_asset(asset)
	library.save()
	material_factory.invalidate(asset.asset_id)
	_request_filesystem_scan()
	main_panel.viewport.refresh_asset_instances(asset.asset_id)
	main_panel.viewport.refresh_brush_preview()
	main_panel.library_panel.refresh()
	main_panel.inspector.set_asset(asset)


## Remove every reference to one asset from the open board and register one atomic undo action.
func _on_remove_asset_from_level(asset: TileAsset) -> void:
	if asset == null or board == null or not is_instance_valid(main_panel):
		return
	var paint_owner := main_panel.viewport.surface_material_paint
	if paint_owner == null or board.material_blend == null:
		push_error("[Tile Studio] Cannot remove a level asset without its material paint owner.")
		return
	var matching_surfaces: Array[SurfacePlacement] = []
	for placement: SurfacePlacement in board.surfaces:
		if placement != null and placement.asset_id == asset.asset_id:
			matching_surfaces.append(placement)
	var matching_props: Array[PropPlacement] = []
	for placement: PropPlacement in board.props:
		if placement != null and placement.asset_id == asset.asset_id:
			matching_props.append(placement)
	var matching_monsters := PackedStringArray()
	for monster_value: Variant in board.monster_visual_assets.keys():
		var monster_id := String(monster_value)
		if board.monster_visual_asset_id(monster_id) == asset.asset_id:
			matching_monsters.append(monster_id)
	var matching_palette_indices := PackedInt32Array()
	board.material_blend.ensure_layers()
	for palette_index: int in board.material_blend.layer_count():
		if (
			String(board.material_blend.layer(palette_index).get("asset_id", ""))
			== asset.asset_id
		):
			matching_palette_indices.append(palette_index)
	var was_imported := board.imported_asset_ids.has(asset.asset_id)
	if (
		matching_surfaces.is_empty()
		and matching_props.is_empty()
		and matching_monsters.is_empty()
		and matching_palette_indices.is_empty()
		and not was_imported
	):
		return

	var before_profile_json := board.material_blend.to_json()
	var paint_patch_steps: Array[Dictionary] = []
	for palette_index: int in matching_palette_indices:
		var patches := paint_owner.clear_palette_material(palette_index)
		if not patches.is_empty():
			paint_patch_steps.append(patches)
		board.material_blend.set_layer(
			palette_index,
			MaterialBlendProfile.default_layer(palette_index)
		)
	for slot_index: int in board.material_blend.splatmap_palette_indices.size():
		if matching_palette_indices.has(
			board.material_blend.splatmap_palette_indices[slot_index]
		):
			board.material_blend.splatmap_palette_indices[slot_index] = -1
	board.material_blend.enabled = board.material_blend.has_active_layers()
	board.material_blend.emit_changed()
	var after_profile_json := board.material_blend.to_json()

	board.remove_surfaces_bulk(matching_surfaces)
	board.remove_props_bulk(matching_props)
	for monster_id: String in matching_monsters:
		board.clear_monster_visual_asset(monster_id)
	if was_imported:
		board.forget_imported_asset(asset.asset_id)
	var snapshot := {
		"asset_id": asset.asset_id,
		"surfaces": matching_surfaces,
		"props": matching_props,
		"monster_ids": matching_monsters,
		"was_imported": was_imported,
		"before_profile": before_profile_json,
		"after_profile": after_profile_json,
		"paint_patch_steps": paint_patch_steps,
	}
	main_panel.viewport.replay_material_profile_and_patches(
		after_profile_json,
		[],
		"after"
	)
	main_panel.viewport.refresh_level_asset_references()
	main_panel.library_panel.refresh()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Remove %s from level" % asset.display_name, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(self, "_apply_level_asset_removal", snapshot, true)
	undo_redo.add_undo_method(self, "_apply_level_asset_removal", snapshot, false)
	undo_redo.commit_action(false)


## Apply or reverse one captured level-asset removal without touching the library asset itself.
func _apply_level_asset_removal(snapshot: Dictionary, removing: bool) -> void:
	if board == null or not is_instance_valid(main_panel):
		return
	var surfaces: Array[SurfacePlacement] = snapshot.get("surfaces", [])
	var props: Array[PropPlacement] = snapshot.get("props", [])
	var monster_ids: PackedStringArray = snapshot.get("monster_ids", PackedStringArray())
	var asset_id := String(snapshot.get("asset_id", ""))
	if removing:
		board.remove_surfaces_bulk(surfaces)
		board.remove_props_bulk(props)
		for monster_id: String in monster_ids:
			board.clear_monster_visual_asset(monster_id)
		if bool(snapshot.get("was_imported", false)):
			board.forget_imported_asset(asset_id)
		main_panel.viewport.replay_material_profile_and_patches(
			snapshot.get("after_profile", {}),
			snapshot.get("paint_patch_steps", []),
			"after"
		)
	else:
		board.add_surfaces_bulk(surfaces)
		board.add_props_bulk(props)
		for monster_id: String in monster_ids:
			board.set_monster_visual_asset(monster_id, asset_id)
		if bool(snapshot.get("was_imported", false)):
			board.remember_imported_asset(asset_id)
		main_panel.viewport.replay_material_profile_and_patches(
			snapshot.get("before_profile", {}),
			snapshot.get("paint_patch_steps", []),
			"before",
			true
		)
	main_panel.viewport.refresh_level_asset_references()
	main_panel.library_panel.refresh()


## Permanently delete an asset and every file it owns.
##
## Confirmed before it runs: this removes the source GLB/PNG and all derived
## renders, which is not recoverable from inside the tool. Placements that
## referenced the asset are left in the board and simply stop resolving -- the
## rebuild reports them -- rather than being silently deleted along with it.
func _on_delete_asset(asset: TileAsset) -> void:
	if asset == null:
		return
	var monster_users := PackedStringArray()
	for monster_value: Variant in board.monster_visual_assets.keys():
		if board.monster_visual_asset_id(String(monster_value)) == asset.asset_id:
			monster_users.append(String(monster_value))
	if not monster_users.is_empty():
		push_warning(
			"[Tile Studio] cannot delete '%s'; monster visuals still use it: %s"
			% [asset.asset_id, ", ".join(monster_users)]
		)
		return
	var confirm := ConfirmationDialog.new()
	confirm.title = "Delete asset"
	confirm.dialog_text = "Permanently delete '%s' and every file it owns?

This removes the stored source and all derived renders from disk. It cannot be undone." % asset.asset_id
	confirm.ok_button_text = "Delete"
	main_panel.add_child(confirm)
	confirm.confirmed.connect(func() -> void:
		var id := asset.asset_id
		var freed := library.delete_asset_files(id)
		library.save()
		material_factory.invalidate(id)
		# The board must stop naming an asset whose files have just been deleted.
		board.forget_imported_asset(id)
		board.rebuild_indexes()
		main_panel.viewport.refresh_asset_instances(id, true)
		main_panel.library_panel.refresh()
		main_panel.inspector.set_asset(null)
		_request_filesystem_scan()
		print("[Tile Studio] deleted '%s', freed %.1f MB" % [id, float(freed) / 1048576.0]))
	confirm.visibility_changed.connect(func() -> void:
		if not confirm.visible:
			confirm.queue_free())
	confirm.popup_centered()


func _on_channel_attach(asset: TileAsset, channel: String) -> void:
	_channel_target = asset
	_channel_name = channel
	if _channel_dialog == null:
		# FileDialog rather than EditorFileDialog so map files outside the project
		# get real thumbnails -- picking a normal vs an AO map by filename alone
		# is guesswork. See tile_studio_main._build_dialogs for why.
		_channel_dialog = FileDialog.new()
		_channel_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_channel_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_channel_dialog.use_native_dialog = false
		_channel_dialog.display_mode = FileDialog.DISPLAY_THUMBNAILS
		if is_instance_valid(main_panel):
			_channel_dialog.set_get_thumbnail_callback(main_panel._thumbnail_for)
		_channel_dialog.add_filter("*.png,*.jpg,*.exr", "Texture maps")
		_channel_dialog.file_selected.connect(_on_channel_file_selected)
		main_panel.add_child(_channel_dialog)
	_channel_dialog.title = "Attach '%s' map" % channel
	_channel_dialog.popup_centered_ratio(0.6)


func _on_channel_file_selected(path: String) -> void:
	if _channel_target == null:
		return
	if _channel_target.gbuffer == null:
		_channel_target.gbuffer = GBufferMapSet.new()
	_channel_target.gbuffer.set_channel(_channel_name, path)
	_save_asset(_channel_target)
	material_factory.invalidate(_channel_target.asset_id)
	main_panel.viewport.refresh_asset_instances(_channel_target.asset_id)
	main_panel.inspector.set_asset(_channel_target)
	print("[Tile Studio] attached %s -> %s" % [_channel_name, path])


func _on_channel_clear(asset: TileAsset, channel: String) -> void:
	if asset.gbuffer == null:
		return
	asset.gbuffer.clear_channel(channel)
	_save_asset(asset)
	material_factory.invalidate(asset.asset_id)
	main_panel.viewport.refresh_asset_instances(asset.asset_id)
	main_panel.inspector.set_asset(asset)


## Ask the editor to rescan, tolerating a scan already being in flight.
##
## Never call this before UI work: a failing reimport can abort the calling
## function, and losing the refresh is far worse than a stale filesystem dock.
func _request_filesystem_scan() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null or filesystem.is_scanning():
		return
	filesystem.scan()


## Save one changed library asset back to its canonical .tres resource path.
func _save_asset(asset: TileAsset) -> void:
	if asset.resource_path.is_empty():
		return
	if ResourceSaver.save(asset, asset.resource_path) != OK:
		push_warning("[Tile Studio] could not save asset '%s'" % asset.asset_id)
