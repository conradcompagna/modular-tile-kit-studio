@tool
extends RefCounted

## Lifecycle behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

static func _ready(host: MTSStudioViewport) -> void:
	host.stretch = true
	host.focus_mode = Control.FOCUS_ALL
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	# Keyboard shortcuts only reach _gui_input while this Control has focus.
	# Taking focus on hover means zoom/rotate/layer keys work as soon as the
	# cursor is over the map, instead of silently doing nothing until a click.
	host.mouse_entered.connect(func() -> void:
		if not host.has_focus():
			host.grab_focus())
	host.mouse_exited.connect(host._hide_height_brush_preview)
	host.mouse_exited.connect(host._hide_material_brush_preview)
	host.resized.connect(host.request_render)

	host.sub_viewport = SubViewport.new()
	host.sub_viewport.name = "SubViewport"
	host.sub_viewport.handle_input_locally = false
	# Static editor content renders on demand. UPDATE_ONCE automatically becomes
	# disabled after the requested frame, eliminating idle GPU work.
	host.sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	host.sub_viewport.own_world_3d = true
	host.sub_viewport.transparent_bg = false
	host.add_child(host.sub_viewport)

	host.world_root = Node3D.new()
	host.world_root.name = "WorldRoot"
	host.sub_viewport.add_child(host.world_root)

	host.world_surface_fields = MTSStudioViewport.WorldSurfaceFields.new(false)
	host.world_surface_fields.fields_changed.connect(host._on_world_surface_fields_changed)
	host.surface_material_paint = host._surface_material_paint_script.new() as MTSSurfaceMaterialPaint
	host.surface_material_paint.batch_texture_changed.connect(host._refresh_material_paint_batch)
	host.surface_material_paint.palette_slots_changed.connect(host._on_material_palette_slots_changed)

	host._build_environment()

	# The terrain is the ground everything else sits on, so it is created before
	# the placement roots that layer over it.
	host.terrain_renderer = MTSTerrainRenderer.new()
	host.world_root.add_child(host.terrain_renderer)

	host.surfaces_root = Node3D.new()
	host.surfaces_root.name = "SurfacePlacements"
	host.world_root.add_child(host.surfaces_root)

	host.surface_art_root = Node3D.new()
	host.surface_art_root.name = "SurfaceArtBatches"
	host.world_root.add_child(host.surface_art_root)


	host.props_root = Node3D.new()
	host.props_root.name = "PropPlacements"
	host.world_root.add_child(host.props_root)

	host.prop_art_root = Node3D.new()
	host.prop_art_root.name = "PropArtBatches"
	host.world_root.add_child(host.prop_art_root)

	host.gameplay_markers_root = Node3D.new()
	host.gameplay_markers_root.name = "GameplayMarkers"
	# Saved markers stay out of the level-building view until Gameplay owns input.
	host.gameplay_markers_root.visible = false
	host.world_root.add_child(host.gameplay_markers_root)

	host.particle_effects_root = Node3D.new()
	host.particle_effects_root.name = "ParticleEffects"
	host.world_root.add_child(host.particle_effects_root)


	host.selection_highlight_root = Node3D.new()
	host.selection_highlight_root.name = "SelectionHighlights"
	host.world_root.add_child(host.selection_highlight_root)

	host._build_height_brush_preview()
	host._build_material_brush_preview()

	# Spatial-truth overlay. Lives beside the art rather than inside it so it
	# is never affected by the Y-slice or the occlusion fade -- a diagnostic
	# that hides itself when you need it is worthless.
	host.occupancy_overlay = MTSStudioViewport.OccupancyOverlay.new()
	host.occupancy_overlay.name = "OccupancyOverlay"
	host.world_root.add_child(host.occupancy_overlay)

	host.placement = MTSStudioViewport.PlacementController.new()
	host.placement.name = "PlacementController"
	host.placement.set_surface_grid_stroke_size(host.surface_grid_stroke_size_m)
	host.world_root.add_child(host.placement)
	host.placement.hover_changed.connect(host._on_hover_changed)
	# Fill owns the shape; terrain mutation and undo stay here.
	host.placement.terrain_fill_committed.connect(host._commit_terrain_fill)
	# Both material tile modes reuse the same base-coat targets, while this viewport
	# remains the one canonical owner of RGBA images and their undo transaction.
	host.placement.terrain_material_tile_paint_requested.connect(host._on_terrain_material_tile_paint_requested)
	host.placement.selection_changed.connect(func(p: Resource) -> void:
		host._refresh_selection_highlights()
		host.selection_changed.emit(p)
	)
	host.placement.board_mutated.connect(func(mutation_mask: int) -> void:
		host._sync_board_incremental(mutation_mask)
		host._refresh_selection_highlights()
	)
	host.placement.prop_terrain_regions_mutated.connect(host._sync_prop_terrain_regions)
	host.placement.tool_changed.connect(host._on_tool_changed)
	host.placement.current_y = host.current_y
	host.placement.slice_mode = host.slice_mode

	var gameplay_marker_controller_script: Script = load(
		"res://addons/modular_tile_studio/viewport/gameplay_marker_controller.gd"
	)
	host.gameplay_markers = (
		gameplay_marker_controller_script.new()
		as MTSGameplayMarkerController
	)
	host.gameplay_markers.name = "GameplayMarkerController"
	host.world_root.add_child(host.gameplay_markers)
	host.gameplay_markers.hover_changed.connect(host._on_hover_changed)
	host.gameplay_markers.board_mutated.connect(host._sync_gameplay_marker_mutation)
	host.gameplay_markers.current_y = host.current_y

	var particle_controller_script: Script = load(
		"res://addons/modular_tile_studio/viewport/particle_effect_controller.gd"
	)
	host.particle_effects = (
		particle_controller_script.new()
		as MTSParticleEffectController
	)
	host.particle_effects.name = "ParticleEffectController"
	host.world_root.add_child(host.particle_effects)
	host.particle_effects.hover_changed.connect(host._on_particle_hover_changed)
	host.particle_effects.board_mutated.connect(host._sync_particle_effect_mutation)
	host.particle_effects.current_y = host.current_y

	host.camera = MTSStudioViewport.CameraController.new()
	host.camera.name = "Camera3D"
	host.world_root.add_child(host.camera)
	host.camera.current = true
	host.camera.view_changed.connect(host.request_render)

	host.set_process(true)
	host.request_render()


## Request one new frame without interrupting an active continuous interaction.
static func request_render(host: MTSStudioViewport) -> void:
	if (
		host.sub_viewport != null
		and host.sub_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS
	):
		host.sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
