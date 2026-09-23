@tool
extends RefCounted

## Binding behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

static func bind(host: MTSStudioViewport, p_board: BoardDocument, p_library: AssetLibrary, p_factory: SurfaceMaterialFactory, p_undo: EditorUndoRedoManager) -> void:
	host.board = p_board
	host.library = p_library
	host.material_factory = p_factory
	host._height_undo_redo = p_undo
	if host.surface_material_paint != null:
		host.surface_material_paint.bind_profile(
			p_board.material_blend if p_board != null else null
		)
	host.placement.board = p_board
	host.placement.library = p_library
	host.placement.material_factory = p_factory
	# Placement picks terrain through the renderer's one face-picking routine, so
	# a prop lands on exactly the face a paint stroke would hit.
	host.placement.terrain_renderer = host.terrain_renderer
	host.placement.undo_redo = p_undo
	host.placement.current_y = host.current_y
	host.placement.slice_mode = host.slice_mode
	host.gameplay_markers.board = p_board
	host.gameplay_markers.terrain_renderer = host.terrain_renderer
	host.gameplay_markers.undo_redo = p_undo
	host.gameplay_markers.current_y = host.current_y
	host.occupancy_overlay.board = p_board
	host.occupancy_overlay.library = p_library

	# The look follows the document. Connecting here rather than in the panel
	# means a profile change from any source -- panel, load, reset, generated
	# content -- reaches the viewport.
	if p_board != null:
		if p_board.look_changed.is_connected(host.apply_look):
			p_board.look_changed.disconnect(host.apply_look)
		if not p_board.look_changed.is_connected(host._on_board_look_changed):
			p_board.look_changed.connect(host._on_board_look_changed)
	# An empty startup document owns no level resources. Exact field allocation
	# waits for an explicit New or Open action with authored board state.
	host._reset_world_surface_field_coverage()
	if p_factory != null:
		p_factory.aesthetics = p_board.aesthetics if p_board != null else null
		p_factory.world_fields = host.world_surface_fields
		p_factory.apply_global_effects(p_board.aesthetics if p_board != null else null)
	host._renderer_settings_signature = host._current_renderer_settings_signature()

	host.apply_lighting_profile()
	host.apply_grade()
	# The sculptor holds a direct reference to the bound board's canonical grid,
	# so it is rebuilt here rather than lazily on the first stroke.
	host._bind_terrain_sculptor()
	host.refresh_terrain()
	if p_board != null and not p_board.is_empty():
		host.rebuild_board()
	else:
		host.request_render()


## Bind the project particle library to the viewport's one emitter factory and authoring controller.
static func bind_particles(host: MTSStudioViewport,
	p_library: ParticleEffectLibrary,
	p_undo: EditorUndoRedoManager
) -> void:
	host.particle_library = p_library
	host.particle_factory = ParticleEffectFactory.new()
	host.particle_effects.board = host.board
	host.particle_effects.library = p_library
	host.particle_effects.terrain_renderer = host.terrain_renderer
	host.particle_effects.undo_redo = p_undo
	host.particle_effects.current_y = host.current_y
	host._rebuild_particle_effect_visuals()
