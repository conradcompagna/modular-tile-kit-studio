@tool
class_name MTSStudioViewport
extends SubViewportContainer

## The isometric editing viewport (spec 4).
##
## Owns its own World3D so the studio is independent of whatever scene the user
## happens to have open in Godot. Board data lives in BoardDocument; the nodes
## built here are only a manifestation of it and are synchronized from the
## document, never read back as truth. Normal placement edits update only their
## affected nodes and batches; full rebuilds are reserved for bind/load/recovery.

const K := preload("../utils/mts_constants.gd")
const PlacementController := preload("placement_controller.gd")
const CameraController := preload("camera_controller.gd")
const OccupancyOverlay := preload("occupancy_overlay.gd")
const ProxyMeshBuilder := preload("../rendering/proxy_mesh_builder.gd")
const WorldSurfaceFields := preload("../rendering/world_surface_fields.gd")
const GLBImporter := preload("../importers/glb_asset_importer.gd")
var _surface_material_paint_script: Script = load("res://addons/modular_tile_studio/rendering/surface_material_paint.gd")
var _surface_palette_matcher_script: Script = load("res://addons/modular_tile_studio/rendering/surface_palette_matcher.gd")

## Transient sculpt modes for the canonical terrain corners.
##
## Each value maps to exactly one TerrainSculptor.Mode; the viewport stores no
## second brush definition. STEP_UP/STEP_DOWN block out verticality in fixed
## levels, RAISE/LOWER/SMOOTH shape organic relief, and QUANTIZE snaps sculpted
## ground onto the level lattice to produce angular architecture.
enum HeightSculptTool {
	NONE,
	STEP_UP,
	STEP_DOWN,
	RAISE,
	LOWER,
	FLATTEN,
	SMOOTH,
	QUANTIZE,
	STEP_FLATTEN,
	STEP_SMOOTH,
	FLATTEN_FOOTPRINT,
}
## Flatten footprint always targets the canonical world-zero terrain plane.
const FOOTPRINT_FLATTEN_HEIGHT_M: float = 0.0

## Footprint editing decides which cells exist before any sculpting occurs.
enum FootprintTool { NONE, DRAW, ERASE }
## Material painting targets direct PNG surface placements and never GLB instances.
enum MaterialPaintTool { NONE, PAINT, ERASE }
## Movement-grid actions edit only the selected canonical terrain cell.
enum MovementGridTool { BLOCK, RESTORE_AUTO, SET_EFFECT, CLEAR_EFFECT }


signal status_changed(text: String)
signal hover_changed(cell: Vector3i, valid: bool, reason: String)
signal particle_hover_changed(position: Vector3, valid: bool, reason: String)
signal selection_changed(placement: Resource)
signal height_sculpt_tool_changed(tool: int)
signal footprint_tool_changed(tool: int)
## Emitted after the authored terrain changes so panels can show the derived
## cell counts and levels without polling the board every frame.
signal terrain_changed()
signal material_paint_tool_changed(tool: int)
signal material_profile_replayed(profile_json: Dictionary)
## Emitted after one movement cell changes so the panel can show its saved state.
signal movement_grid_cell_changed(cell: Vector2i, state: Dictionary)
## Emitted whenever the active tool changes, so the toolbar's erase toggle
## reflects reality even when the tool was switched from the keyboard or by
## picking a brush.
signal tool_changed(tool: int)
## Emitted when a visible light glob selects its exact LightingProfile entry.
signal local_light_handle_selected(index: int)
## Emitted during a light-glob drag so the visible XYZ controls mirror authored state.
signal local_light_handle_changed(
	index: int,
	surface_position: Vector3,
	height_offset: float
)

var board: BoardDocument
var library: AssetLibrary
var particle_library: ParticleEffectLibrary
var material_factory: SurfaceMaterialFactory
var particle_factory: ParticleEffectFactory

var sub_viewport: SubViewport
var world_root: Node3D
var camera: MTSCameraController
var placement: MTSPlacementController
var gameplay_markers: MTSGameplayMarkerController
var particle_effects: MTSParticleEffectController
var occupancy_overlay: MTSOccupancyOverlay

## The one visible encounter surface, rebuilt from board.terrain.
var terrain_renderer: MTSTerrainRenderer
## Visible toolbar state consumed directly by terrain materials.
var _terrain_top_grid_visible: bool = true
var _terrain_side_grid_visible: bool = false
var surfaces_root: Node3D
var surface_art_root: Node3D
var props_root: Node3D
## Shared real-GLB artwork. Placement roots retain only spatial/collision state.
var prop_art_root: Node3D
## Transient high-contrast bounds derived from the currently selected placements.
var selection_highlight_root: Node3D
## Derived gameplay marker and enemy-pack visuals rebuilt from canonical records.
var gameplay_markers_root: Node3D
## Derived GPUParticles3D emitters rebuilt from canonical board placements and reusable presets.
var particle_effects_root: Node3D

## Pack nets are thin editor-only ribbons slightly above each authored grid layer.
const PACK_NET_HEIGHT_M: float = 0.08
const PACK_NET_WIDTH_M: float = 0.055
const PACK_NET_HUB_RADIUS_M: float = 0.24

## Spatial batches bound MultiMesh all-or-nothing culling to a small fixed-camera region.
const SURFACE_BATCH_CHUNK_SIZE_M: int = 16
const ORIGINAL_MATERIAL_STATE_META: StringName = &"mts_original_material_state"

## Placement instance id -> derived scene node; these maps never own board truth.
var _surface_nodes_by_placement_id: Dictionary = {}
var _prop_nodes_by_placement_id: Dictionary = {}
## asset/mesh/renderer-state key -> derived GLB mesh whose materials match the active renderer settings.
var _prop_render_mesh_cache: Dictionary = {}
## asset/layer/chunk/component key -> reusable real-GLB MultiMesh node.
var _prop_batches_by_key: Dictionary = {}
var _renderer_settings_signature: String = ""
## A load suppresses the document's final look notification because its one rebuild already applied it.
var _skip_next_look_apply: bool = false
## A load defers reflection fitting until geometry has been rebuilt from the committed document.
var _defer_reflection_probe_rebuild: bool = false
## One full rebuild reuses the same authoritative board bounds in every dependent phase.
var _full_rebuild_bounds: AABB = AABB()
var _full_rebuild_has_bounds: bool = false

## Board-wide visual fields. They are renderer state, not placement state: the
## board still contains only simple modular tile/prop records.
var world_surface_fields: MTSWorldSurfaceFields
## Canonical sparse RGBA paint images feed only existing terrain face batches.
var surface_material_paint: MTSSurfaceMaterialPaint
## Last action-scoped synchronization timings remain inspectable for performance regressions.
var _last_incremental_profile_ms: Dictionary = {}
## Contact subphase timings identify any accidental return to board-wide work.
var _last_contact_profile_ms: Dictionary = {}

## Voxel proxy meshes, keyed by asset+facing+generation.
##
## Keyed on the generation id so a rebuilt asset never reuses the previous
## generation's geometry: an Apply Size that changed the box would otherwise
## keep sorting against the shape it used to have.
var _voxel_mesh_cache: Dictionary = {}
## Keyed by TileAsset.prop_model_path() so every placement shares the one explicitly
## selected source or optimized render artifact without crossing between them.
var _real_mesh_cache: Dictionary = {}
## Parsed mesh components are reused by batching and contact extraction for every placement of one source model.
var _prop_mesh_components_cache: Dictionary = {}
## Visual low-band contact polygons are cached by asset generation, orientation, and field texel size.
##
## The field texel size is part of the key because sub-texel source triangles
## are compacted only to the resolution the current contact texture can retain.
var _prop_contact_polygon_cache: Dictionary = {}
## Only geometry within this distance of a GLB's true lowest point contacts terrain.
const PROP_CONTACT_BAND_M: float = 0.08

# --- Lighting rig ---------------------------------------------------------
#
# The rig holds no settings of its own. Every value comes from the bound board's
# LightingProfile, so the look belongs to the level being worked on rather than
# to the application, and switching boards switches the light with it.
var world_environment: WorldEnvironment
var key_light: DirectionalLight3D
var lights_root: Node3D
var reflection_probe: ReflectionProbe
## The uniform painting light is transient viewport state and never enters BoardDocument data.
var _painting_light_override_enabled: bool = false

## Light handles are editor-only manifestations of canonical surface anchors and heights.
enum LocalLightDragMode {
	NONE,
	SURFACE,
}

var light_handles_root: Node3D
var _light_handle_nodes: Array[Node3D] = []
var _light_handles_visible: bool = false
var _selected_light_handle: int = -1
var _local_light_placement_pending: bool = false
var _light_drag_mode: int = LocalLightDragMode.NONE
var _light_drag_index: int = -1
var _light_drag_start_surface_position: Vector3 = Vector3.ZERO
var _light_drag_start_height_offset: float = 0.0
const LIGHT_HANDLE_PICK_RADIUS_PX: float = 18.0
const LIGHT_HANDLE_RADIUS_M: float = 0.22
const LIGHT_SURFACE_ANCHOR_RADIUS_M: float = 0.085
const LIGHT_STEM_RADIUS_M: float = 0.018
const LIGHT_HEIGHT_KEY_STEP_M: float = 0.1
const LIGHT_INDEX_META: StringName = &"mts_light_index"

var slice_mode: int = K.SliceMode.ALL
var current_y: int = 0:
	set(value):
		current_y = value
		if placement != null:
			placement.current_y = value
		if gameplay_markers != null:
			gameplay_markers.current_y = value
		if particle_effects != null:
			particle_effects.current_y = value
		_apply_slice()
		_emit_status()

var _keys_down: Dictionary = {}
var _painting: bool = false
var _erasing: bool = false
var _last_mouse: Vector2 = Vector2.ZERO
## Movement editing exists only while its visible top-level panel owns the mode.
var _movement_grid_active: bool = false
var _movement_grid_tool: int = MovementGridTool.BLOCK
var _movement_ground_effect_label: String = ""

## Selection dragging keeps only transient pointer state; BoardDocument changes
## once on release through PlacementController's undoable group-move operation.
var _select_dragging: bool = false
var _select_drag_start: Vector2 = Vector2.ZERO
var _select_drag_target: Resource = null
var _select_drag_start_cell: Vector3i = Vector3i.ZERO
var _select_drag_has_start_cell: bool = false
var _select_drag_last_valid_delta: Vector3i = Vector3i.ZERO
const SELECT_DRAG_THRESHOLD_PX: float = 6.0

## The Blockout panel's visible checkbox owns this transient display setting.
const BLOCKOUT_HOVER_RAY_LENGTH_M: float = 10000.0
const BLOCKOUT_HOVER_MARGIN_PX: float = 4.0
const BLOCKOUT_HOVER_OFFSET_PX: Vector2 = Vector2(14.0, 14.0)
const BLOCKOUT_HOVER_MAX_WIDTH_PX: float = 280.0
const BLOCKOUT_HOVER_MAX_SKIPPED_COLLIDERS: int = 64

## Terrain sculpt controls are transient; board.terrain owns the canonical corners.
##
## The tool selects which brush behaviour a stroke applies, and the brush values
## below are pushed into the sculptor before each stroke so the UI and the
## canonical edit always agree on exactly one set of settings.
var height_sculpt_tool: int = HeightSculptTool.NONE
var terrain_step_m: float = 0.5
var height_brush_strength: float = 0.5
## When true the slope brushes refuse to move any lattice corner that a real
## vertical side face stands on, so sculpting cannot flatten authored walls.
##
## Only the slope family (Raise/Lower/Flatten/Smooth) can destroy a wall: it moves
## every cell meeting one grid corner to the same height, which is precisely the
## operation that closes a vertical drop. The step family moves whole cells and
## creates walls rather than removing them, so this setting does not affect it.
var terrain_protect_walls: bool = false
## The editor's global history receives one compact action per completed stroke.
var _height_undo_redo: EditorUndoRedoManager
var _height_sculpting: bool = false
## Raw pointer motion is coalesced into one latest swept sample per rendered frame.
var _height_pending_motion: bool = false
var _height_pending_mouse_position: Vector2 = Vector2.ZERO
var _last_height_stamp_xz: Vector2 = Vector2(INF, INF)
## Fixed-time repetition makes a held brush independent of pointer event frequency.
var _height_repeat_elapsed_seconds: float = 0.0
## A separate hold phase prevents an ordinary click from becoming multiple sculpt pulses.
var _height_hold_repeating: bool = false
## Sculpts the live board terrain. Rebuilt whenever a different board is bound.
var _terrain_sculptor: TerrainSculptor
## Cells whose geometry one in-progress stroke has already invalidated.
var _terrain_dirty_cells: Rect2i = Rect2i()
## Chunk keys touched by the active edit are finalized once when the stroke ends.
var _terrain_dirty_chunks: Dictionary = {}
## One transient overlay displays the exact terrain footprint under the pointer.
var _height_brush_preview: MeshInstance3D
var _height_brush_fill_material: StandardMaterial3D
var _height_brush_line_material: StandardMaterial3D
## The base at stroke start reveals whether the derived global skirt moved.
var _height_stroke_start_skirt_base_m: float = 0.0

## Footprint drawing is the first authoring step: it decides which cells exist
## before any sculpting can happen.
var footprint_tool: int = FootprintTool.NONE
var _footprint_drawing: bool = false
var _footprint_erasing: bool = false
## Cells the active footprint drag has already committed, so one drag over the
## same cell cannot register repeated undo entries.
var _footprint_stroke_cells: Dictionary = {}
var _footprint_stroke_before: Dictionary = {}
var _last_footprint_stamp_xz: Vector2 = Vector2(INF, INF)
var _footprint_stroke_start_skirt_base_m: float = 0.0

## Direct texture grid-stroke width is transient toolbar state measured in whole metres.
var surface_grid_stroke_size_m: int = 1
## Material pen state is transient; only sparse RGBA placement images are persisted.
var material_paint_tool: int = MaterialPaintTool.NONE
var material_brush_radius_m: float = 0.5
var material_brush_opacity: float = 1.0
var material_brush_hardness: float = 0.75
var material_brush_palette_index: int = 0
## The selected overlay PNG shares PlacementController's regular surface orientation.
var material_layer_brush_asset: TileAsset = null
## True only while imported RGBA weights own the existing terrain tile targeter.
var splatmap_tile_paint_enabled: bool = false
## True only while one mask-blended material channel uses that same tile targeter.
var material_tile_paint_enabled: bool = false
## The control image is projected across the selected face direction's exact lattice bounds.
##
## Only the prepared source, those bounds, and stable face-UID records are cached. A tile's
## weights are sampled from the projection when that tile is actually painted, so arming the
## mode never precomputes per-face images and nothing scales with terrain area.
var _splatmap_source_image: Image = null
var _splatmap_source_texture: Texture2D = null
## The selected face plane's two-dimensional lattice bounds, not an implicit XZ rectangle.
var _splatmap_terrain_bounds: Rect2i = Rect2i()
## Retains every directional target because several wall planes may share one projected cell.
var _splatmap_targets: Array[Dictionary] = []
## Maps each stable paint UID to its one canonical directional projection record.
var _splatmap_target_by_uid: Dictionary = {}
var _splatmap_source_valid: bool = false
## Which of the four channels currently own an assigned material, for the guide overlay.
var _splatmap_channel_mask: Vector4 = Vector4.ONE
## One transaction flag is shared by imported RGBA and masked single-channel tile strokes.
var _terrain_material_tile_stroke_active: bool = false
var material_pressure_size_enabled: bool = true
var material_pressure_opacity_enabled: bool = true
## The visible checkbox owns this transient shader-only eligibility overlay.
var material_mask_preview_enabled: bool = false
var material_mask_preview_palette_index: int = 0
## Face cells whose palette mapping changed are regrouped once at the end of the frame.
var _pending_material_slot_cells: Rect2i = Rect2i()
var _material_slot_refresh_queued: bool = false
## One transient mesh displays the exact world-space radius over the paintable heightfield.
var _material_brush_preview: MeshInstance3D
var _material_brush_preview_material: StandardMaterial3D
var _material_brush_preview_mesh_radius_m: float = -1.0
var _material_painting: bool = false
var _material_has_last_sample: bool = false
var _material_last_world_position: Vector3 = Vector3.ZERO
var _material_last_plane_normal: Vector3 = Vector3.ZERO
## Raw pointer motion is coalesced into one latest exact capsule endpoint per rendered frame.
var _material_pending_sample: bool = false
var _material_pending_mouse_position: Vector2 = Vector2.ZERO
var _material_pending_pressure: float = 1.0
var _material_pending_force_erase: bool = false
var _material_pending_hit: Dictionary = {}
var _material_stroke_force_erase: bool = false
var _material_pointer_pressure: float = 1.0
var _material_pointer_inverted: bool = false
var _material_world_height_range: Vector2 = Vector2.ZERO
var _material_world_elevation_range: Vector2 = Vector2(0.0, 1.0)

const HEIGHT_BRUSH_PREVIEW_OFFSET_M: float = 0.025
## Mouse-down always stamps immediately; repetition begins only after deliberate holding.
const HEIGHT_SCULPT_HOLD_DELAY_SECONDS: float = 0.25
## Held sculpting refreshes at 20 Hz so deformation reads as continuous without frame-rate coupling.
const HEIGHT_SCULPT_REPEAT_SECONDS: float = 0.05
const MATERIAL_BRUSH_PREVIEW_SEGMENTS: int = 48
const MATERIAL_BRUSH_PREVIEW_OFFSET_M: float = 0.012

## Board-derived field coverage keeps sixteen exact samples per metre on initial binding.
const WORLD_HEIGHT_TEXELS_PER_METER: float = 16.0
## One metre beyond canonical board bounds keeps edge brush and contact samples available.
const WORLD_HEIGHT_COVERAGE_MARGIN_M: float = 1.0


func _ready() -> void:
	stretch = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Keyboard shortcuts only reach _gui_input while this Control has focus.
	# Taking focus on hover means zoom/rotate/layer keys work as soon as the
	# cursor is over the map, instead of silently doing nothing until a click.
	mouse_entered.connect(func() -> void:
		if not has_focus():
			grab_focus())
	mouse_exited.connect(_hide_height_brush_preview)
	mouse_exited.connect(_hide_material_brush_preview)
	resized.connect(request_render)

	sub_viewport = SubViewport.new()
	sub_viewport.name = "SubViewport"
	sub_viewport.handle_input_locally = false
	# Static editor content renders on demand. UPDATE_ONCE automatically becomes
	# disabled after the requested frame, eliminating idle GPU work.
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	sub_viewport.own_world_3d = true
	sub_viewport.transparent_bg = false
	add_child(sub_viewport)

	world_root = Node3D.new()
	world_root.name = "WorldRoot"
	sub_viewport.add_child(world_root)

	world_surface_fields = WorldSurfaceFields.new(false)
	world_surface_fields.fields_changed.connect(_on_world_surface_fields_changed)
	surface_material_paint = _surface_material_paint_script.new() as MTSSurfaceMaterialPaint
	surface_material_paint.batch_texture_changed.connect(_refresh_material_paint_batch)
	surface_material_paint.palette_slots_changed.connect(_on_material_palette_slots_changed)

	_build_environment()

	# The terrain is the ground everything else sits on, so it is created before
	# the placement roots that layer over it.
	terrain_renderer = MTSTerrainRenderer.new()
	world_root.add_child(terrain_renderer)

	surfaces_root = Node3D.new()
	surfaces_root.name = "SurfacePlacements"
	world_root.add_child(surfaces_root)

	surface_art_root = Node3D.new()
	surface_art_root.name = "SurfaceArtBatches"
	world_root.add_child(surface_art_root)


	props_root = Node3D.new()
	props_root.name = "PropPlacements"
	world_root.add_child(props_root)

	prop_art_root = Node3D.new()
	prop_art_root.name = "PropArtBatches"
	world_root.add_child(prop_art_root)

	gameplay_markers_root = Node3D.new()
	gameplay_markers_root.name = "GameplayMarkers"
	# Saved markers stay out of the level-building view until Gameplay owns input.
	gameplay_markers_root.visible = false
	world_root.add_child(gameplay_markers_root)

	particle_effects_root = Node3D.new()
	particle_effects_root.name = "ParticleEffects"
	world_root.add_child(particle_effects_root)


	selection_highlight_root = Node3D.new()
	selection_highlight_root.name = "SelectionHighlights"
	world_root.add_child(selection_highlight_root)

	_build_height_brush_preview()
	_build_material_brush_preview()

	# Spatial-truth overlay. Lives beside the art rather than inside it so it
	# is never affected by the Y-slice or the occlusion fade -- a diagnostic
	# that hides itself when you need it is worthless.
	occupancy_overlay = OccupancyOverlay.new()
	occupancy_overlay.name = "OccupancyOverlay"
	world_root.add_child(occupancy_overlay)

	placement = PlacementController.new()
	placement.name = "PlacementController"
	placement.set_surface_grid_stroke_size(surface_grid_stroke_size_m)
	world_root.add_child(placement)
	placement.hover_changed.connect(_on_hover_changed)
	# Fill owns the shape; terrain mutation and undo stay here.
	placement.terrain_fill_committed.connect(_commit_terrain_fill)
	# Both material tile modes reuse the same base-coat targets, while this viewport
	# remains the one canonical owner of RGBA images and their undo transaction.
	placement.terrain_material_tile_paint_requested.connect(_on_terrain_material_tile_paint_requested)
	placement.selection_changed.connect(func(p: Resource) -> void:
		_refresh_selection_highlights()
		selection_changed.emit(p)
	)
	placement.board_mutated.connect(func(mutation_mask: int) -> void:
		_sync_board_incremental(mutation_mask)
		_refresh_selection_highlights()
	)
	placement.prop_terrain_regions_mutated.connect(_sync_prop_terrain_regions)
	placement.tool_changed.connect(_on_tool_changed)
	placement.current_y = current_y
	placement.slice_mode = slice_mode

	var gameplay_marker_controller_script: Script = load(
		"res://addons/modular_tile_studio/viewport/gameplay_marker_controller.gd"
	)
	gameplay_markers = (
		gameplay_marker_controller_script.new()
		as MTSGameplayMarkerController
	)
	gameplay_markers.name = "GameplayMarkerController"
	world_root.add_child(gameplay_markers)
	gameplay_markers.hover_changed.connect(_on_hover_changed)
	gameplay_markers.board_mutated.connect(_sync_gameplay_marker_mutation)
	gameplay_markers.current_y = current_y

	var particle_controller_script: Script = load(
		"res://addons/modular_tile_studio/viewport/particle_effect_controller.gd"
	)
	particle_effects = (
		particle_controller_script.new()
		as MTSParticleEffectController
	)
	particle_effects.name = "ParticleEffectController"
	world_root.add_child(particle_effects)
	particle_effects.hover_changed.connect(_on_particle_hover_changed)
	particle_effects.board_mutated.connect(_sync_particle_effect_mutation)
	particle_effects.current_y = current_y

	camera = CameraController.new()
	camera.name = "Camera3D"
	world_root.add_child(camera)
	camera.current = true
	camera.view_changed.connect(request_render)

	set_process(true)
	request_render()


## Request one new frame without interrupting an active continuous interaction.
func request_render() -> void:
	if (
		sub_viewport != null
		and sub_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS
	):
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Walk from a physics collider to the placement root carrying canonical metadata.
func _placement_root_from_collider(collider: Node) -> Node3D:
	var current := collider
	while current != null and current != world_root:
		if current.has_meta("mts_placement"):
			return current as Node3D
		current = current.get_parent()
	return null


## Return the nearest non-negative distance from a ray to one exact box.
##
## GLB selection calls this once per occupied voxel, so empty cells inside an
## asset's broad grid bounds never become invisible selection blockers.
func _ray_distance_to_aabb(
	ray_origin: Vector3,
	ray_direction: Vector3,
	bounds: AABB
) -> float:
	var near_distance := -INF
	var far_distance := INF
	for axis in 3:
		var origin_component := ray_origin[axis]
		var direction_component := ray_direction[axis]
		var minimum_component := bounds.position[axis]
		var maximum_component := bounds.end[axis]
		if is_zero_approx(direction_component):
			if origin_component < minimum_component or origin_component > maximum_component:
				return INF
			continue
		var first_distance := (minimum_component - origin_component) / direction_component
		var second_distance := (maximum_component - origin_component) / direction_component
		near_distance = maxf(near_distance, minf(first_distance, second_distance))
		far_distance = minf(far_distance, maxf(first_distance, second_distance))
		if near_distance > far_distance:
			return INF
	if far_distance < 0.0:
		return INF
	return maxf(near_distance, 0.0)


## Return the nearest ray distance to a placement's voxel volume at its world pose.
##
## Voxel addresses are local to the placement and world_origin is BoardDocument's
## one canonical pose for it, so picking tests the same boxes the physics shapes
## occupy rather than an integer-height copy of them.
func _ray_distance_to_collision_voxels(
	ray_origin: Vector3,
	ray_direction: Vector3,
	voxels: Array[Vector3i],
	world_origin: Vector3 = Vector3.ZERO
) -> float:
	var closest_distance := INF
	for cell: Vector3i in voxels:
		var distance := _ray_distance_to_aabb(
			ray_origin,
			ray_direction,
			AABB(Vector3(cell) + world_origin, Vector3.ONE)
		)
		closest_distance = minf(closest_distance, distance)
	return closest_distance


## Return one solid placement's measured voxel volume in its own local cell space.
##
## Local rather than world: there is no separate collision address space any more.
## The volume is the asset's oriented voxel scan and its position is
## _placement_collision_origin, which is the same pose the artwork is built at.
func _placement_collision_voxels(placement_record: Resource) -> Array[Vector3i]:
	if placement_record is PropPlacement:
		return board.prop_local_voxels(placement_record as PropPlacement)
	return []


## Return the world position a placement's local collision voxels are measured from.
func _placement_collision_origin(placement_record: Resource) -> Vector3:
	if placement_record is PropPlacement:
		return board.prop_world_origin(placement_record as PropPlacement)
	return Vector3.ZERO


## Return exact collision vertices for marquee tests and camera framing.
##
## Solid records contribute every voxel corner at the placement's canonical world
## pose, the same pose its physics shapes stand at. PNG records contribute only
## their zero-thickness quad, matching picking instead of inventing a box.
func _placement_collision_points(placement_record: Resource) -> PackedVector3Array:
	var points := PackedVector3Array()
	if placement_record is SurfacePlacement:
		# Terrain paint contributes the real vertices of the faces it covers, so
		# marquee tests and framing match the visible art rather than a proxy quad.
		var surface := placement_record as SurfacePlacement
		var asset := board.resolve_surface_asset(surface)
		if asset == null or terrain_renderer == null:
			return points
		var preview_geometry := terrain_renderer.surface_preview_meshes(surface, asset)
		var terrain_mesh := preview_geometry.get("mesh", null) as Mesh
		if terrain_mesh != null:
			for point: Vector3 in terrain_mesh.get_faces():
				if not points.has(point):
					points.append(point)
		return points

	var collision_origin := _placement_collision_origin(placement_record)
	for cell: Vector3i in _placement_collision_voxels(placement_record):
		var minimum := Vector3(cell) + collision_origin
		var maximum := minimum + Vector3.ONE
		for x: float in [minimum.x, maximum.x]:
			for y: float in [minimum.y, maximum.y]:
				for z: float in [minimum.z, maximum.z]:
					points.append(Vector3(x, y, z))
	return points


## Return the minimal world AABB derived from a placement's exact collision points.
func _placement_collision_aabb(placement_record: Resource) -> AABB:
	var points := _placement_collision_points(placement_record)
	if points.is_empty():
		return AABB()
	var minimum := points[0]
	var maximum := points[0]
	for point: Vector3 in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum)


## Return the topmost visible decal whose saved projector contains one terrain hit.
##
## Receiver UIDs establish the exact terrain attachment, while the canonical
## placement transform limits selection to the projected image footprint. Reverse
## authored order makes a later decal selectable when several native decals overlap.
func _decal_at_terrain_hit(terrain_face: Dictionary, world_point: Vector3) -> SurfacePlacement:
	if board == null:
		return null
	var paint_uid := String(terrain_face.get("paint_uid", ""))
	if paint_uid.is_empty():
		return null
	for surface_index: int in range(board.surfaces.size() - 1, -1, -1):
		var surface := board.surfaces[surface_index]
		if not surface.is_overlay() or not surface.terrain_face_uids.has(paint_uid):
			continue
		var visual := _find_visual(surface)
		if visual == null or not visual.is_visible_in_tree():
			continue
		var asset := board.resolve_surface_asset(surface)
		if asset == null:
			continue
		var footprint := surface.canonical_footprint(asset)
		var surface_transform := SurfacePlacement.transform_for_size(
			surface.origin,
			surface.face,
			surface.rotation_quarters,
			footprint,
			surface.grid_anchor
		)
		var local_point := surface_transform.affine_inverse() * world_point
		if (
			absf(local_point.x) <= float(footprint.x) * 0.5
			and absf(local_point.y) <= float(footprint.y) * 0.5
		):
			return surface
	return null


## Ray-pick the closest visible placement from its canonical authored geometry.
##
## Solid placements use the same occupied voxels as collision. PNG surfaces and
## decals resolve from the one terrain hit, with decals limited to their projector.
func _placement_at_pointer(mouse_pos: Vector2) -> Resource:
	if camera == null or board == null or not Rect2(Vector2.ZERO, size).has_point(mouse_pos):
		return null
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_direction := camera.project_ray_normal(mouse_pos)
	var closest_distance := INF
	var closest_placement: Resource = null
	if terrain_renderer != null:
		var terrain_hit := terrain_renderer.pick_face(ray_origin, ray_direction)
		if not terrain_hit.is_empty():
			var terrain_face: Dictionary = terrain_hit["face"]
			var terrain_point: Vector3 = terrain_hit["point"]
			var texture_surface := _decal_at_terrain_hit(terrain_face, terrain_point)
			if texture_surface == null:
				texture_surface = board.surface_at_paint_uid(
					String(terrain_face["paint_uid"])
				)
			if texture_surface != null and not texture_surface.asset_id.is_empty():
				closest_distance = ray_origin.distance_to(terrain_point)
				closest_placement = texture_surface

	for prop: PropPlacement in board.props:
		var visual := _find_visual(prop)
		if visual == null or not visual.is_visible_in_tree():
			continue
		var distance := _ray_distance_to_collision_voxels(
			ray_origin,
			ray_direction,
			_placement_collision_voxels(prop),
			_placement_collision_origin(prop)
		)
		if distance < closest_distance:
			closest_distance = distance
			closest_placement = prop

	# Terrain paint owns no independent ray geometry. It is selected through the
	# terrain hit resolved above, which names the exact painted face.
	return closest_placement


## Rebuild selection from the same collision-derived preview pair used by placement.
##
## PNG surfaces retain their real plane collider. Props and surfaced boxes pass
## their exact occupied voxels to ProxyMeshBuilder, with no visual AABB substitute.
func _refresh_selection_highlights() -> void:
	if selection_highlight_root == null:
		return
	selection_highlight_root.position = Vector3.ZERO
	for child: Node in selection_highlight_root.get_children():
		# Detach first so a same-frame rotation refresh can reuse the stable names
		# consumed by tests and diagnostics instead of receiving Godot's auto-suffix.
		selection_highlight_root.remove_child(child)
		child.queue_free()
	if placement == null or board == null:
		return
	var volume_material := StandardMaterial3D.new()
	volume_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	volume_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	volume_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	volume_material.albedo_color = Color(0.1, 0.8, 1.0, 0.16)
	volume_material.no_depth_test = true
	volume_material.render_priority = 12
	var outline_material := StandardMaterial3D.new()
	outline_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	outline_material.albedo_color = Color(0.1, 0.8, 1.0, 0.95)
	outline_material.no_depth_test = true
	outline_material.render_priority = 13

	for placement_record: Resource in placement.selected_resources():
		var visual := _find_visual(placement_record)
		# Slice state belongs to the placement visual itself. Ancestor Control
		# visibility must not suppress construction of the collision overlay, which
		# is also exercised while the editor panel is off-screen or headless.
		if visual == null or not visual.visible:
			continue
		if placement_record is SurfacePlacement:
			# The highlight traces the exact terrain faces the paint covers, so a
			# selection on sloped or stepped ground follows the real surface
			# instead of floating a flat rectangle over it.
			var surface := placement_record as SurfacePlacement
			var asset := board.resolve_surface_asset(surface)
			if asset == null or terrain_renderer == null:
				continue
			var preview_geometry := terrain_renderer.surface_preview_meshes(surface, asset)
			var outline_mesh := preview_geometry.get("outline", null) as Mesh
			if outline_mesh == null:
				continue
			var surface_contours := MeshInstance3D.new()
			surface_contours.name = "SelectionCollisionContours"
			surface_contours.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			surface_contours.mesh = outline_mesh
			# The offset is display-only and leaves the collider on the exact face.
			surface_contours.position += Vector3(K.face_normal(surface.face)) * 0.02
			surface_contours.material_override = outline_material
			selection_highlight_root.add_child(surface_contours)
			continue

		var collision_voxels := _placement_collision_voxels(placement_record)
		if collision_voxels.is_empty():
			continue
		var collision_preview := ProxyMeshBuilder.collision_preview_meshes(collision_voxels)
		# The mesh is built from the placement's local voxel volume, so both nodes
		# stand at its one canonical world pose -- the same pose the physics shapes
		# and the artwork are posed at.
		var collision_origin := _placement_collision_origin(placement_record)

		var collision_volume := MeshInstance3D.new()
		collision_volume.name = "SelectionCollisionVolume"
		collision_volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		collision_volume.mesh = collision_preview["volume"] as Mesh
		collision_volume.position = collision_origin
		collision_volume.material_override = volume_material
		selection_highlight_root.add_child(collision_volume)

		var collision_contours := MeshInstance3D.new()
		collision_contours.name = "SelectionCollisionContours"
		collision_contours.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		collision_contours.mesh = collision_preview["contours"] as Mesh
		collision_contours.position = collision_origin
		collision_contours.material_override = outline_material
		selection_highlight_root.add_child(collision_contours)


## Return whether exact projected collision geometry overlaps a marquee rectangle.
func _placement_intersects_screen_rect(
	placement_record: Resource,
	screen_rect: Rect2
) -> bool:
	if camera == null:
		return false
	var visual := _find_visual(placement_record)
	if visual == null or not visual.is_visible_in_tree():
		return false
	var collision_points := _placement_collision_points(placement_record)
	if collision_points.is_empty():
		return false
	var projected_minimum := Vector2(INF, INF)
	var projected_maximum := Vector2(-INF, -INF)
	var projected_point_count := 0
	for point: Vector3 in collision_points:
		if camera.is_position_behind(point):
			continue
		var projected := camera.unproject_position(point)
		projected_minimum = projected_minimum.min(projected)
		projected_maximum = projected_maximum.max(projected)
		projected_point_count += 1
	if projected_point_count == 0:
		return false
	return screen_rect.intersects(
		Rect2(projected_minimum, projected_maximum - projected_minimum),
		true
	)


## Resolve the complete visible placement group covered by one screen-space marquee.
func _placements_in_screen_rect(screen_rect: Rect2) -> Array[Resource]:
	var found: Array[Resource] = []
	if board == null:
		return found
	for surface: SurfacePlacement in board.surfaces:
		if _placement_intersects_screen_rect(surface, screen_rect):
			found.append(surface)
	for prop: PropPlacement in board.props:
		if _placement_intersects_screen_rect(prop, screen_rect):
			found.append(prop)
	return found


## Start either a placement drag or an empty-space marquee without changing board data.
func _begin_select_interaction(mouse_pos: Vector2, additive: bool) -> void:
	_select_dragging = true
	_select_drag_start = mouse_pos
	_select_drag_target = _placement_at_pointer(mouse_pos)
	_select_drag_has_start_cell = false
	_select_drag_last_valid_delta = Vector3i.ZERO
	if selection_highlight_root != null:
		selection_highlight_root.position = Vector3.ZERO
	if _select_drag_target == null:
		return
	if additive:
		placement.toggle_selected_placement(_select_drag_target)
	elif not placement.is_selected(_select_drag_target):
		placement.set_selected_placements([_select_drag_target], _select_drag_target)
	var pick := placement.pick_cell(camera, mouse_pos)
	if bool(pick.get("hit", false)):
		_select_drag_start_cell = pick.get("cell", Vector3i.ZERO)
		_select_drag_has_start_cell = true


## Move the existing collision preview to the last valid snapped drag location.
##
## No placement data changes here. Mouse-up passes this accepted delta to the
## normal move operation once, so dragging cannot create a parallel transform path.
func _continue_select_interaction(mouse_pos: Vector2) -> void:
	if not _select_dragging or _select_drag_target == null or not _select_drag_has_start_cell:
		return
	var pick := placement.pick_cell(camera, mouse_pos)
	if not bool(pick.get("hit", false)):
		return
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	var requested_delta := cell - _select_drag_start_cell
	var rejection := (
		""
		if requested_delta == Vector3i.ZERO
		else placement.selection_move_error(requested_delta)
	)
	if rejection.is_empty():
		_select_drag_last_valid_delta = requested_delta
		if selection_highlight_root != null:
			selection_highlight_root.position = Vector3(requested_delta)
		hover_changed.emit(cell, true, "Drop %d selected placement%s at %s" % [
			placement.selected_resources().size(),
			"" if placement.selected_resources().size() == 1 else "s",
			requested_delta,
		])
	else:
		hover_changed.emit(cell, false, "%s; last valid delta %s" % [
			rejection,
			_select_drag_last_valid_delta,
		])
	request_render()


## Finish a click, marquee, or one collision-validated selection drop.
func _end_select_interaction(mouse_pos: Vector2, additive: bool) -> void:
	if not _select_dragging:
		return
	var dragged := _select_drag_start.distance_to(mouse_pos) >= SELECT_DRAG_THRESHOLD_PX
	if _select_drag_target != null and dragged and _select_drag_has_start_cell:
		_continue_select_interaction(mouse_pos)
		if selection_highlight_root != null:
			selection_highlight_root.position = Vector3.ZERO
		placement.move_selection_by(_select_drag_last_valid_delta)
	elif _select_drag_target == null and dragged:
		var marquee := Rect2(_select_drag_start, mouse_pos - _select_drag_start).abs()
		var marquee_selection := _placements_in_screen_rect(marquee)
		if additive:
			marquee_selection.append_array(placement.selected_resources())
		placement.set_selected_placements(marquee_selection)
	elif _select_drag_target == null:
		placement.clear_selection()
	if selection_highlight_root != null:
		selection_highlight_root.position = Vector3.ZERO
	_select_dragging = false
	_select_drag_target = null
	_select_drag_has_start_cell = false
	_select_drag_last_valid_delta = Vector3i.ZERO
	_emit_status()
	request_render()


## Build the native environment and light containers before a board profile is bound.
func _build_environment() -> void:
	# The rig is built empty and then filled from the board's LightingProfile by
	# apply_lighting_profile(). Nothing about the look is hard-coded here: a
	# value that only existed in this function could never be tuned or reset.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.fog_mode = Environment.FOG_MODE_DEPTH

	world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = env
	world_root.add_child(world_environment)

	key_light = DirectionalLight3D.new()
	key_light.name = "KeyLight"
	world_root.add_child(key_light)

	# Local lights live under their own node so rebuilding them cannot disturb
	# the key light or anything else in the world.
	lights_root = Node3D.new()
	lights_root.name = "LocalLights"
	world_root.add_child(lights_root)

	# These transient globs mirror profile positions only while Lighting is open.
	# They never become board data and therefore cannot create a second source of truth.
	light_handles_root = Node3D.new()
	light_handles_root.name = "LocalLightHandles"
	light_handles_root.visible = false
	world_root.add_child(light_handles_root)

	# Defaults until a board is bound, so the viewport is never black on open.
	var startup := LightingProfile.defaults()
	env.background_color = startup.background_color
	env.ambient_light_color = startup.ambient_color
	env.ambient_light_energy = startup.ambient_energy
	env.tonemap_mode = startup.tonemap_mode as Environment.ToneMapper
	env.tonemap_white = startup.tonemap_white
	key_light.light_energy = startup.sun_energy
	key_light.light_color = startup.sun_color
	key_light.rotation_degrees = startup.sun_rotation_degrees()


func bind(p_board: BoardDocument, p_library: AssetLibrary, p_factory: SurfaceMaterialFactory, p_undo: EditorUndoRedoManager) -> void:
	board = p_board
	library = p_library
	material_factory = p_factory
	_height_undo_redo = p_undo
	if surface_material_paint != null:
		surface_material_paint.bind_profile(
			p_board.material_blend if p_board != null else null
		)
	placement.board = p_board
	placement.library = p_library
	placement.material_factory = p_factory
	# Placement picks terrain through the renderer's one face-picking routine, so
	# a prop lands on exactly the face a paint stroke would hit.
	placement.terrain_renderer = terrain_renderer
	placement.undo_redo = p_undo
	placement.current_y = current_y
	placement.slice_mode = slice_mode
	gameplay_markers.board = p_board
	gameplay_markers.terrain_renderer = terrain_renderer
	gameplay_markers.undo_redo = p_undo
	gameplay_markers.current_y = current_y
	occupancy_overlay.board = p_board
	occupancy_overlay.library = p_library

	# The look follows the document. Connecting here rather than in the panel
	# means a profile change from any source -- panel, load, reset, generated
	# content -- reaches the viewport.
	if p_board != null:
		if p_board.look_changed.is_connected(apply_look):
			p_board.look_changed.disconnect(apply_look)
		if not p_board.look_changed.is_connected(_on_board_look_changed):
			p_board.look_changed.connect(_on_board_look_changed)
	# An empty startup document owns no level resources. Exact field allocation
	# waits for an explicit New or Open action with authored board state.
	_reset_world_surface_field_coverage()
	if p_factory != null:
		p_factory.aesthetics = p_board.aesthetics if p_board != null else null
		p_factory.world_fields = world_surface_fields
		p_factory.apply_global_effects(p_board.aesthetics if p_board != null else null)
	_renderer_settings_signature = _current_renderer_settings_signature()

	apply_lighting_profile()
	apply_grade()
	# The sculptor holds a direct reference to the bound board's canonical grid,
	# so it is rebuilt here rather than lazily on the first stroke.
	_bind_terrain_sculptor()
	refresh_terrain()
	if p_board != null and not p_board.is_empty():
		rebuild_board()
	else:
		request_render()


## Bind the project particle library to the viewport's one emitter factory and authoring controller.
func bind_particles(
	p_library: ParticleEffectLibrary,
	p_undo: EditorUndoRedoManager
) -> void:
	particle_library = p_library
	particle_factory = ParticleEffectFactory.new()
	particle_effects.board = board
	particle_effects.library = p_library
	particle_effects.terrain_renderer = terrain_renderer
	particle_effects.undo_redo = p_undo
	particle_effects.current_y = current_y
	_rebuild_particle_effect_visuals()


## Re-apply only the renderer state owned by each changed look control.
##
## Shader-global controls remain uniform updates. Geometry, terrain supports and
## Apply document look notifications unless an atomic load already applied the same state.
func _on_board_look_changed() -> void:
	if _skip_next_look_apply:
		return
	apply_look()


## GLB buffers are touched only when their explicit input signatures change.
func apply_look() -> void:
	apply_lighting_profile()
	apply_grade()

	var renderer_signature := _current_renderer_settings_signature()
	var renderer_settings_changed := renderer_signature != _renderer_settings_signature
	if material_factory != null:
		material_factory.aesthetics = board.aesthetics if board != null else null
		material_factory.world_fields = world_surface_fields
		material_factory.apply_global_effects(board.aesthetics if board != null else null)
		if renderer_settings_changed:
			material_factory.clear_cache()

	if renderer_settings_changed:
		_apply_renderer_settings_to_existing_geometry()
		_renderer_settings_signature = renderer_signature

	request_render()


## The colour grade, applied to the whole viewport rather than per material.
##
## Ported from Plate Level Studio's grade_color(), which ran as shader uniforms
## on its single plate. Here the board is many materials, so grading each one
## would both multiply the work and produce seams where a tile happened to miss
## a channel. Godot's Environment adjustment stack grades the composed image
## instead, which is what the plate shader was approximating in the first place.
##
## Exposure sits on tonemap_exposure, before the tonemapper, so it behaves as a
## real exposure rather than a post multiply. Shadow lift and highlight
## compression have no direct Environment control, so they are expressed through
## the adjustment colour-correction ramp built below.
func apply_grade() -> void:
	if world_environment == null or world_environment.environment == null or board == null:
		return
	var look := board.aesthetics
	var env := world_environment.environment
	if _painting_light_override_enabled:
		env.tonemap_exposure = 1.0
		env.adjustment_enabled = false
		return

	env.tonemap_exposure = maxf(look.exposure, 0.0)
	env.adjustment_enabled = true
	env.adjustment_contrast = look.contrast
	env.adjustment_saturation = look.saturation
	env.adjustment_brightness = 1.0
	env.adjustment_color_correction = _grade_ramp(look)


## A 1D colour-correction ramp encoding shadow lift and highlight compression.
##
## Both are curve shapes, not scalars, so there is no Environment property that
## expresses them; a gradient texture is the mechanism Godot provides for
## exactly this. Rebuilt only when the grade changes, never per frame.
func _grade_ramp(look: AestheticProfile) -> GradientTexture1D:
	# A neutral grade needs no lookup at all, and skipping it avoids paying for
	# a texture fetch on every fragment of an untouched board.
	if is_zero_approx(look.shadow_lift) and is_zero_approx(look.highlight_compression):
		return null

	const STEPS := 32
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for step in STEPS:
		var x := float(step) / float(STEPS - 1)
		# Shadow lift: blend toward sqrt, which raises darks far more than
		# lights, for a flatter painterly base. Same curve the plate shader used.
		var value: float = lerpf(x, sqrt(x), clampf(look.shadow_lift, 0.0, 1.0))
		# Highlight compression: a Reinhard roll-off, so bright values converge
		# instead of clipping.
		value = value / (1.0 + value * maxf(look.highlight_compression, 0.0))
		offsets.append(x)
		colors.append(Color(value, value, value))

	# Assigned wholesale rather than built with add_point(): a Gradient is seeded
	# with stops at offset 0 and 1, which add_point() would collide with at
	# exactly the two ends of this ramp.
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors

	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	texture.width = 256
	return texture


# --- Board -> scene -------------------------------------------------------

## Return one world XZ rectangle derived from the board's canonical placement bounds.
##
## BoardDocument.compute_bounds() resolves terrain and every placement through one
## canonical result, so field coverage never depends on placement source type.
func _required_world_surface_field_rect() -> Rect2:
	if board == null:
		return Rect2(WorldSurfaceFields.DEFAULT_ORIGIN, WorldSurfaceFields.DEFAULT_SIZE)
	return _required_world_surface_field_rect_for(board)


## Calculate exact editable height coverage for one detached or live board document.
func _required_world_surface_field_rect_for(source_board: BoardDocument) -> Rect2:
	if source_board == null or source_board.is_empty():
		return Rect2(WorldSurfaceFields.DEFAULT_ORIGIN, WorldSurfaceFields.DEFAULT_SIZE)
	var board_bounds := (
		_board_bounds()
		if source_board == board
		else source_board.compute_bounds()
	)
	return _world_surface_field_rect_for_bounds(board_bounds)


## Convert one authoritative board bound into the editable XZ field rectangle.
func _world_surface_field_rect_for_bounds(board_bounds: AABB) -> Rect2:
	var board_end := board_bounds.end
	var minimum := Vector2(
		floorf(board_bounds.position.x - WORLD_HEIGHT_COVERAGE_MARGIN_M),
		floorf(board_bounds.position.z - WORLD_HEIGHT_COVERAGE_MARGIN_M)
	)
	var maximum := Vector2(
		ceilf(board_end.x + WORLD_HEIGHT_COVERAGE_MARGIN_M),
		ceilf(board_end.z + WORLD_HEIGHT_COVERAGE_MARGIN_M)
	)
	return Rect2(minimum, maximum - minimum)


## Initialize a newly bound board's terrain field directly from its canonical world bounds.
func _reset_world_surface_field_coverage() -> void:
	if world_surface_fields == null or board == null or board.is_empty():
		return
	var required_rect := _required_world_surface_field_rect()
	world_surface_fields.configure(
		required_rect.position,
		required_rect.size,
		_world_surface_field_resolution(required_rect),
		false
	)


## Return the canonical texture resolution for one visible world-field rectangle.
func _world_surface_field_resolution(required_rect: Rect2) -> Vector2i:
	return Vector2i(
		ceili(required_rect.size.x * WORLD_HEIGHT_TEXELS_PER_METER) + 1,
		ceili(required_rect.size.y * WORLD_HEIGHT_TEXELS_PER_METER) + 1
	)


## Initialize or expand terrain coverage for board mutations while preserving authored sculpt pixels.
func _ensure_world_surface_field_coverage() -> bool:
	if world_surface_fields == null or board == null:
		return false
	var required_rect := _required_world_surface_field_rect()
	if (
		world_surface_fields.height_source_image == null
		or world_surface_fields.height_source_image.is_empty()
	):
		# The first paint turns an intentionally empty startup board into authored
		# state. Configure that first canonical field directly; expansion requires
		# an existing image and therefore cannot represent this state transition.
		world_surface_fields.configure(
			required_rect.position,
			required_rect.size,
			_world_surface_field_resolution(required_rect),
			false
		)
		return true
	return world_surface_fields.ensure_coverage(required_rect)


## Serialize one canonical placement record for derived-node change detection.
##
## Resource identity remains stable while Select moves or asset switching edit the
## record in place, so the derived node stores this value-only snapshot instead.
func _placement_spatial_signature(placement_record: Resource) -> String:
	if placement_record is SurfacePlacement:
		return JSON.stringify((placement_record as SurfacePlacement).to_json())
	if placement_record is PropPlacement:
		return JSON.stringify({
			"placement": (placement_record as PropPlacement).to_json(),
			"movement_collision_min_triangle_share_percent": (
				board.movement_collision_min_triangle_share_percent
				if board != null
				else 0.0
			),
		})
	push_error("[Tile Studio] cannot sign an unsupported placement Resource.")
	return ""


## Rebuild every derived visual for bind, load, reset, or explicit recovery.
##
## Normal painting does not call this path; _sync_board_incremental() preserves
## unrelated nodes and surface batches while BoardDocument remains authoritative.
func rebuild_board(frame_after: bool = false) -> void:
	if board == null:
		return
	if not _full_rebuild_has_bounds:
		_full_rebuild_bounds = board.compute_bounds()
		_full_rebuild_has_bounds = true

	for root: Node3D in [
		surfaces_root,
		surface_art_root,
		props_root,
		prop_art_root,
		gameplay_markers_root,
		particle_effects_root,
	]:
		if root == null:
			continue
		for child in root.get_children():
			root.remove_child(child)
			child.queue_free()

	_surface_nodes_by_placement_id.clear()
	_prop_nodes_by_placement_id.clear()
	_prop_batches_by_key.clear()

	for surface: SurfacePlacement in board.surfaces:
		var surface_asset := board.resolve_surface_asset(surface)
		if surface_asset == null:
			push_error("[Tile Studio] surface has no resolvable asset.")
			continue
		var surface_node := _build_surface_node(surface, surface_asset)
		surfaces_root.add_child(surface_node)
		_surface_nodes_by_placement_id[surface.get_instance_id()] = surface_node

	for prop: PropPlacement in board.props:
		var prop_asset := board.resolve_prop_asset(prop)
		if prop_asset == null:
			push_error("[Tile Studio] prop has no resolvable asset.")
			continue
		var prop_node := _build_prop_node(prop, prop_asset)
		props_root.add_child(prop_node)
		_prop_nodes_by_placement_id[prop.get_instance_id()] = prop_node

	# Coverage changes emit synchronously and refresh terrain-supported GLB art.
	# Every prop root must therefore exist before coverage is allowed to change.
	_ensure_world_surface_field_coverage()
	_rebuild_world_contacts()
	_rebuild_prop_art_batches()
	_rebuild_gameplay_marker_visuals()
	_rebuild_particle_effect_visuals()
	_rebuild_reflection_probe(_profile())

	if occupancy_overlay != null:
		occupancy_overlay.rebuild()
	if placement != null:
		# Rebuild the existing brush preview from the changed data without
		# reselecting that brush or changing Select/Paint ownership.
		placement.refresh_brush_preview()

	_apply_slice()
	if frame_after:
		_frame_board_from_bounds(_full_rebuild_bounds)
	_emit_status()
	request_render()
	_full_rebuild_has_bounds = false


## Synchronize only placement-derived nodes affected by the latest board mutation.
##
## BoardDocument remains authoritative. The instance-id maps are derived lookup
## tables that let an add/remove preserve every unrelated collision node, prop
## hierarchy, and surface batch.
func _sync_board_incremental(
	mutation_mask: int = PlacementController.BoardMutation.ALL
) -> void:
	if board == null or library == null:
		return
	if (mutation_mask & PlacementController.BoardMutation.ALL) == 0:
		push_error("[Tile Studio] incremental sync received no board category.")
		return
	var terrain_changed_in_action := (
		mutation_mask & PlacementController.BoardMutation.TERRAIN
	) != 0
	if terrain_changed_in_action:
		refresh_terrain()
	var sync_started_usec := Time.get_ticks_usec()

	# Coverage is expanded only after new roots exist. The field's changed signal
	# may then synchronize terrain support without observing a half-built board.
	var world_field_expanded := false
	var current_surface_ids: Dictionary = {}
	var added_surfaces: Array[SurfacePlacement] = []
	var removed_surfaces: Array[SurfacePlacement] = []

	if (mutation_mask & PlacementController.BoardMutation.SURFACES) != 0:
		for surface: SurfacePlacement in board.surfaces:
			var placement_id := surface.get_instance_id()
			current_surface_ids[placement_id] = true
			var existing_surface_node := _surface_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(existing_surface_node):
				var current_signature := _placement_spatial_signature(surface)
				if (
					String(existing_surface_node.get_meta("mts_spatial_signature", ""))
					== current_signature
				):
					continue
				removed_surfaces.append(surface)
				surfaces_root.remove_child(existing_surface_node)
				existing_surface_node.queue_free()
				_surface_nodes_by_placement_id.erase(placement_id)

			var surface_asset := board.resolve_surface_asset(surface)
			if surface_asset == null:
				push_error("[Tile Studio] added surface has no resolvable asset.")
				continue
			var surface_node := _build_surface_node(surface, surface_asset)
			surfaces_root.add_child(surface_node)
			_surface_nodes_by_placement_id[placement_id] = surface_node
			added_surfaces.append(surface)
			_apply_slice_to_node(surface_node)

		for placement_id_value: Variant in _surface_nodes_by_placement_id.keys():
			var placement_id := int(placement_id_value)
			if current_surface_ids.has(placement_id):
				continue
			var surface_node := _surface_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(surface_node):
				var removed_surface := surface_node.get_meta(
					"mts_placement",
					null
				) as SurfacePlacement
				if removed_surface != null:
					removed_surfaces.append(removed_surface)
				surfaces_root.remove_child(surface_node)
				surface_node.queue_free()
			_surface_nodes_by_placement_id.erase(placement_id)

	var current_prop_ids: Dictionary = {}
	var added_props: Array[PropPlacement] = []
	var removed_props: Array[PropPlacement] = []
	var removed_prop_contact_ids := PackedStringArray()
	var affected_prop_batch_keys: Dictionary = {}

	if (mutation_mask & PlacementController.BoardMutation.PROPS) != 0:
		for prop: PropPlacement in board.props:
			var placement_id := prop.get_instance_id()
			current_prop_ids[placement_id] = true
			var existing_prop_node := _prop_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(existing_prop_node):
				var current_signature := _placement_spatial_signature(prop)
				if (
					String(existing_prop_node.get_meta("mts_spatial_signature", ""))
					== current_signature
				):
					continue
				for batch_key: String in (
					existing_prop_node.get_meta("mts_batch_keys", PackedStringArray())
					as PackedStringArray
				):
					affected_prop_batch_keys[batch_key] = true
				var previous_contact_id := String(
					existing_prop_node.get_meta("mts_contact_id", "")
				)
				if not previous_contact_id.is_empty():
					removed_prop_contact_ids.append(previous_contact_id)
				removed_props.append(prop)
				props_root.remove_child(existing_prop_node)
				existing_prop_node.queue_free()
				_prop_nodes_by_placement_id.erase(placement_id)

			var prop_asset := board.resolve_prop_asset(prop)
			if prop_asset == null:
				push_error("[Tile Studio] added prop has no resolvable asset.")
				continue
			var prop_node := _build_prop_node(prop, prop_asset)
			props_root.add_child(prop_node)
			_prop_nodes_by_placement_id[placement_id] = prop_node
			for batch_key: String in (
				prop_node.get_meta("mts_batch_keys", PackedStringArray())
				as PackedStringArray
			):
				affected_prop_batch_keys[batch_key] = true
			added_props.append(prop)
			_apply_slice_to_node(prop_node)

		for placement_id_value: Variant in _prop_nodes_by_placement_id.keys():
			var placement_id := int(placement_id_value)
			if current_prop_ids.has(placement_id):
				continue
			var prop_node := _prop_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(prop_node):
				for batch_key: String in (
					prop_node.get_meta("mts_batch_keys", PackedStringArray())
					as PackedStringArray
				):
					affected_prop_batch_keys[batch_key] = true
				var previous_contact_id := String(
					prop_node.get_meta("mts_contact_id", "")
				)
				if not previous_contact_id.is_empty():
					removed_prop_contact_ids.append(previous_contact_id)
				var removed_prop := prop_node.get_meta(
					"mts_placement",
					null
				) as PropPlacement
				if removed_prop != null:
					removed_props.append(removed_prop)
				props_root.remove_child(prop_node)
				prop_node.queue_free()
			_prop_nodes_by_placement_id.erase(placement_id)

	world_field_expanded = _ensure_world_surface_field_coverage()
	var surfaces_changed := not added_surfaces.is_empty() or not removed_surfaces.is_empty()
	var props_changed := not added_props.is_empty() or not removed_props.is_empty()
	var terrain_paint_cells := Rect2i()
	var ordinary_added_surfaces: Array[SurfacePlacement] = []
	var ordinary_removed_surfaces: Array[SurfacePlacement] = []
	for entry: Array in [[added_surfaces, ordinary_added_surfaces], [removed_surfaces, ordinary_removed_surfaces]]:
		for surface: SurfacePlacement in entry[0] as Array:
			var terrain_cells := _terrain_cells_for_surface(surface)
			if terrain_cells.is_empty():
				(entry[1] as Array[SurfacePlacement]).append(surface)
				continue
			for terrain_cell: Vector2i in terrain_cells:
				var cell_rect := Rect2i(terrain_cell, Vector2i.ONE)
				terrain_paint_cells = (
					cell_rect
					if terrain_paint_cells.size.x <= 0
					else terrain_paint_cells.merge(cell_rect)
				)
	if terrain_paint_cells.size.x > 0 and terrain_renderer != null:
		var terrain_paint_chunks := terrain_renderer.refresh_paint_for_cells(
			terrain_paint_cells,
			surface_material_paint,
			board
		)
		_apply_terrain_material_chunks(terrain_paint_chunks)

	var contacts_started_usec := Time.get_ticks_usec()
	if (
		terrain_changed_in_action
		or world_field_expanded
		or not ordinary_removed_surfaces.is_empty()
	):
		_rebuild_world_contacts()
	elif (
		not ordinary_added_surfaces.is_empty()
		or not removed_prop_contact_ids.is_empty()
		or not added_props.is_empty()
	):
		_update_world_contacts(
			ordinary_added_surfaces,
			removed_prop_contact_ids,
			added_props
		)
	var contacts_finished_usec := Time.get_ticks_usec()

	if props_changed:
		_sync_prop_art_batches(affected_prop_batch_keys)
	var batches_finished_usec := Time.get_ticks_usec()

	if (
		occupancy_overlay != null
		and occupancy_overlay.mode != OccupancyOverlay.Mode.OFF
		and (surfaces_changed or props_changed or terrain_changed_in_action)
	):
		occupancy_overlay.rebuild()
	if surfaces_changed or props_changed or terrain_changed_in_action:
		_rebuild_reflection_probe(_profile())

	var sync_finished_usec := Time.get_ticks_usec()
	_last_incremental_profile_ms = {
		"scan_and_nodes": float(contacts_started_usec - sync_started_usec) / 1000.0,
		"contacts": float(contacts_finished_usec - contacts_started_usec) / 1000.0,
		"prop_batches": float(batches_finished_usec - contacts_finished_usec) / 1000.0,
		"finalize": float(sync_finished_usec - batches_finished_usec) / 1000.0,
		"total": float(sync_finished_usec - sync_started_usec) / 1000.0,
	}
	_emit_status()
	request_render()

## Synchronize only prop roots named by one GLB contact transaction.
func _sync_contact_prop_nodes(
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement]
) -> Dictionary:
	var affected_batch_keys: Dictionary = {}
	var removed_contact_ids := PackedStringArray()
	var props_to_stamp: Array[PropPlacement] = []
	var removed_ids: Dictionary = {}
	for prop: PropPlacement in removed_props:
		if prop == null:
			continue
		removed_ids[prop.get_instance_id()] = true
		var root := _prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if not is_instance_valid(root):
			continue
		for key: String in (
			root.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		):
			affected_batch_keys[key] = true
		var contact_id := String(root.get_meta("mts_contact_id", ""))
		if not contact_id.is_empty():
			removed_contact_ids.append(contact_id)
		props_root.remove_child(root)
		root.queue_free()
		_prop_nodes_by_placement_id.erase(prop.get_instance_id())

	for prop: PropPlacement in support_props:
		if prop == null or removed_ids.has(prop.get_instance_id()):
			continue
		var root := _prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if not is_instance_valid(root):
			continue
		var old_keys := (
			root.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		)
		var old_contact_id := String(root.get_meta("mts_contact_id", ""))
		var moved := _apply_prop_support_offset(root)
		var asset := board.resolve_prop_asset(prop)
		if asset == null:
			continue
		var current_keys := _prop_batch_keys(prop, asset)
		root.set_meta("mts_batch_keys", current_keys)
		root.set_meta("mts_spatial_signature", _placement_spatial_signature(prop))
		var current_contact_id := (
			_prop_contact_id(prop)
			if prop.support != PropPlacement.SUPPORT_WALL
			else ""
		)
		root.set_meta("mts_contact_id", current_contact_id)
		if moved:
			for key: String in old_keys:
				affected_batch_keys[key] = true
			for key: String in current_keys:
				affected_batch_keys[key] = true
		if old_contact_id != current_contact_id:
			if not old_contact_id.is_empty():
				removed_contact_ids.append(old_contact_id)
			if not current_contact_id.is_empty():
				props_to_stamp.append(prop)

	for prop: PropPlacement in added_props:
		if prop == null:
			continue
		var asset := board.resolve_prop_asset(prop)
		if asset == null:
			push_error("[Tile Studio] added contact prop has no resolvable asset.")
			continue
		var root := _build_prop_node(prop, asset)
		props_root.add_child(root)
		_prop_nodes_by_placement_id[prop.get_instance_id()] = root
		for key: String in (
			root.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		):
			affected_batch_keys[key] = true
		if prop.support != PropPlacement.SUPPORT_WALL:
			props_to_stamp.append(prop)
		_apply_slice_to_node(root)

	if not affected_batch_keys.is_empty():
		_sync_prop_art_batches(affected_batch_keys)
	return {
		"removed_contact_ids": removed_contact_ids,
		"props_to_stamp": props_to_stamp,
	}


## Refresh wall and prop contact contributors only inside changed terrain regions.
func _refresh_world_contacts_for_terrain_regions(
	regions: Array[Rect2i],
	removed_prop_contact_ids: PackedStringArray,
	props_to_stamp: Array[PropPlacement]
) -> void:
	if world_surface_fields == null or board == null or board.terrain == null:
		return
	var removed_wall_ids: Dictionary = {}
	for region: Rect2i in regions:
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				var cell := region.position + Vector2i(local_x, local_z)
				for edge: int in 4:
					var source_id := "wall|%s" % TerrainMesh.band_uid(cell, edge, 0)
					if removed_wall_ids.has(source_id):
						continue
					removed_wall_ids[source_id] = true
					world_surface_fields.remove_contact_source(source_id, false)
	for contact_id: String in removed_prop_contact_ids:
		world_surface_fields.remove_contact_source(contact_id, false)

	var stamped_wall_ids: Dictionary = {}
	for region: Rect2i in regions:
		for face: Dictionary in board.terrain.terrain_faces(
			terrain_chunk_cells(),
			region
		):
			if (
				int(face["kind"]) != TerrainMesh.FaceKind.SIDE
				or int(face["band"]) != 0
			):
				continue
			var source_id := "wall|%s" % String(face["paint_uid"])
			if stamped_wall_ids.has(source_id):
				continue
			stamped_wall_ids[source_id] = true
			var segment := _wall_contact_segment(
				face["grid_cell"] as Vector3i,
				int(face["face"])
			)
			if segment.is_empty():
				continue
			world_surface_fields.stamp_contact_segment(
				segment[0],
				segment[1],
				0.08,
				0.35,
				1.0,
				false,
				source_id
			)
	var stamped_props: Dictionary = {}
	for prop: PropPlacement in props_to_stamp:
		if prop == null or stamped_props.has(prop.get_instance_id()):
			continue
		stamped_props[prop.get_instance_id()] = true
		var asset := board.resolve_prop_asset(prop)
		if asset != null:
			_stamp_prop_contact(prop, asset, false)
	world_surface_fields.upload_interaction()


## Drop released terrain-paint pixels from the live image cache and sidecar metadata.
func _discard_released_terrain_paint(released: PackedStringArray) -> void:
	if released.is_empty():
		return
	if surface_material_paint != null:
		surface_material_paint.discard_paint_for_uids(released)
	var surviving: Array = []
	for entry_value: Variant in board.surface_material_paint.get("surfaces", []) as Array:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		if not released.has(String(entry.get("uid", ""))):
			surviving.append(entry)
	if board.surface_material_paint.has("surfaces"):
		board.surface_material_paint["surfaces"] = surviving


## Reposition only gameplay marker visuals whose cells touch changed terrain.
func _refresh_gameplay_markers_for_terrain_regions(
	regions: Array[Rect2i]
) -> void:
	if gameplay_markers_root == null or board == null:
		return
	var changed_cells: Dictionary = {}
	for region: Rect2i in regions:
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				changed_cells[
					region.position + Vector2i(local_x, local_z)
				] = true
	for child_value: Node in gameplay_markers_root.get_children():
		var root := child_value as Node3D
		if root == null:
			continue
		var marker := root.get_meta("mts_placement", null) as GameplayMarker
		if marker == null:
			continue
		var cell := Vector2i(marker.origin.x, marker.origin.z)
		if not changed_cells.has(cell):
			continue
		var previous_position := root.position
		root.position = _marker_stand_position(marker)
		var bounds_value: Variant = root.get_meta("mts_bounds", null)
		if bounds_value is AABB:
			var bounds := bounds_value as AABB
			bounds.position += root.position - previous_position
			root.set_meta("mts_bounds", bounds)
		_apply_slice_to_node(root)


## Reposition only terrain-attached particle roots whose cells changed.
func _refresh_particle_effects_for_terrain_regions(
	regions: Array[Rect2i]
) -> void:
	if particle_effects_root == null or board == null:
		return
	var changed_cells: Dictionary = {}
	for region: Rect2i in regions:
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				changed_cells[
					region.position + Vector2i(local_x, local_z)
				] = true
	for child_value: Node in particle_effects_root.get_children():
		var root := child_value as Node3D
		if root == null:
			continue
		var placement := root.get_meta(
			"mts_particle_placement",
			null
		) as ParticleEffectPlacement
		if (
			placement == null
			or placement.attachment != ParticleEffectPlacement.Attachment.TERRAIN
		):
			continue
		var cell := Vector2i(
			floori(placement.position.x),
			floori(placement.position.z)
		)
		if not changed_cells.has(cell):
			continue
		root.position = _particle_effect_position(placement)
		root.set_meta("mts_layer_y", int(floorf(root.position.y)))
		_apply_slice_to_node(root)


## Refresh only the height-range shader input changed by regional terrain contact.
func _refresh_regional_material_height_range() -> void:
	if world_surface_fields == null:
		return
	_material_world_height_range = world_surface_fields.height_value_range()
	for material: ShaderMaterial in _all_surface_shader_materials():
		material.set_shader_parameter(
			"material_world_height_range",
			_material_world_height_range
		)


## Synchronize one atomic GLB contact patch without any board-wide rebuild.
func _sync_prop_terrain_regions(
	regions: Array[Rect2i],
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	terrain_paint_uids: PackedStringArray
) -> void:
	if board == null or board.terrain == null or regions.is_empty():
		return
	var changed_chunks: Array[Vector2i] = []
	if terrain_renderer != null:
		changed_chunks = terrain_renderer.refresh_visual_regions(
			board.terrain,
			regions,
			surface_material_paint,
			board
		)
		terrain_renderer.finalize_collision_chunks(changed_chunks)
		_apply_terrain_material_chunks(changed_chunks)
	var released := board.prune_terrain_paint_uids(terrain_paint_uids)
	_discard_released_terrain_paint(released)
	if world_surface_fields != null:
		world_surface_fields.project_terrain_regions(board.terrain, regions)

	var prop_sync := _sync_contact_prop_nodes(
		support_props,
		added_props,
		removed_props
	)
	_refresh_world_contacts_for_terrain_regions(
		regions,
		prop_sync.get("removed_contact_ids", PackedStringArray()),
		prop_sync.get("props_to_stamp", []) as Array[PropPlacement]
	)
	_refresh_gameplay_markers_for_terrain_regions(regions)
	_refresh_particle_effects_for_terrain_regions(regions)
	_refresh_regional_material_height_range()
	if occupancy_overlay != null and occupancy_overlay.mode != OccupancyOverlay.Mode.OFF:
		# The diagnostic is intentionally monolithic; only an explicitly visible
		# overlay pays its complete redraw, while ordinary contact edits stay local.
		occupancy_overlay.rebuild()
	if not added_props.is_empty() or not removed_props.is_empty():
		_rebuild_reflection_probe(_profile())
	_refresh_selection_highlights()
	terrain_changed.emit()
	_emit_status()
	request_render()


## Synchronize an externally committed board mutation through incremental derived state.
func refresh_board_changes() -> void:
	_sync_board_incremental()


## Refresh only placements and render batches that consume one edited asset.
##
## Geometry edits invalidate that asset's cached GLB source and mark its spatial
## roots stale. Material-only edits retain collision nodes and reconfigure only
## the matching surface or prop batches.
func refresh_asset_instances(
	asset_id: String,
	geometry_changed: bool = false
) -> void:
	if board == null or library == null or asset_id.is_empty():
		return
	var asset := library.get_asset(asset_id)
	if geometry_changed and asset != null:
		# Either authored path may have been selected before this change, so invalidate
		# both exact cache entries while leaving every unrelated GLB resident.
		_real_mesh_cache.erase(asset.source_path)
		_real_mesh_cache.erase(asset.prop_runtime_path)
		_prop_mesh_components_cache.clear()
		_prop_render_mesh_cache.clear()
		_prop_contact_polygon_cache.clear()

	var affected_prop_batch_keys: Dictionary = {}
	var stale_spatial_root := false
	var terrain_material_changed := false
	for layer_index: int in board.material_blend.layer_count():
		if String(board.material_blend.layer(layer_index).get("asset_id", "")) == asset_id:
			terrain_material_changed = true
	for surface: SurfacePlacement in board.surfaces:
		if surface.asset_id != asset_id:
			continue
		if not surface.terrain_face_uids.is_empty():
			terrain_material_changed = true
		var node := _surface_nodes_by_placement_id.get(
			surface.get_instance_id(),
			null
		) as Node3D
		if geometry_changed and is_instance_valid(node):
			node.set_meta("mts_spatial_signature", "stale-asset")
			stale_spatial_root = true
		elif is_instance_valid(node) and surface.is_decal() and asset != null:
			# A native Decal holds its textures and mix values on the node itself
			# rather than reading a material, and only a geometry change rebuilds
			# that node. Without this, an edit to the asset's maps, strengths, or
			# biases would leave every placed decal showing its creation-time state.
			var projector := node.get_node_or_null("Projection") as Decal
			if projector != null:
				_configure_native_decal(projector, surface, asset)

	for prop: PropPlacement in board.props:
		if prop.asset_id != asset_id:
			continue
		var node := _prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if not is_instance_valid(node):
			continue
		for batch_key: String in (
			node.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		):
			affected_prop_batch_keys[batch_key] = true
		if geometry_changed:
			node.set_meta("mts_spatial_signature", "stale-asset")
			stale_spatial_root = true

	if stale_spatial_root:
		_sync_board_incremental()
	if not affected_prop_batch_keys.is_empty() and not geometry_changed:
		_sync_prop_art_batches(affected_prop_batch_keys)
	if terrain_material_changed:
		# The factory cache was invalidated before this call, so only terrain
		# surfaces that visibly consume this asset need new batch materials.
		_refresh_terrain_materials_for_asset(asset_id)
	_emit_status()
	request_render()


## Recreate only terrain batch materials that visibly consume one edited asset.
func _refresh_terrain_materials_for_asset(asset_id: String) -> void:
	if (
		asset_id.is_empty()
		or terrain_renderer == null
		or board == null
		or board.material_blend == null
	):
		return
	var used_palette_indices: Dictionary = {}
	for palette_index: int in _used_palette_indices_for_profile(board.material_blend):
		used_palette_indices[palette_index] = true
	for chunk_value: Variant in terrain_renderer.chunks():
		var chunk := chunk_value as Vector2i
		for surface: Dictionary in terrain_renderer.chunk_surfaces(chunk):
			if not _terrain_surface_uses_asset(
				surface,
				asset_id,
				used_palette_indices
			):
				continue
			var material := _terrain_surface_material(chunk, surface)
			if material == null:
				continue
			terrain_renderer.set_chunk_surface_material(
				chunk,
				int(surface["surface_index"]),
				material
			)


## Return whether one terrain surface visibly consumes the selected base, layer, or decal asset.
func _terrain_surface_uses_asset(
	surface: Dictionary,
	asset_id: String,
	used_palette_indices: Dictionary
) -> bool:
	if String(surface.get("asset_id", "")) == asset_id:
		return true
	var shader_decal := surface.get("shader_decal", null) as SurfacePlacement
	if shader_decal != null and shader_decal.asset_id == asset_id:
		return true
	var slots_value: Variant = surface.get("slot_materials", PackedInt32Array())
	var slots: PackedInt32Array = (
		slots_value as PackedInt32Array
		if slots_value is PackedInt32Array
		else PackedInt32Array()
	)
	if slots.is_empty():
		for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			slots.append(slot_index)
	for palette_index: int in slots:
		if (
			not used_palette_indices.has(palette_index)
			or palette_index < 0
			or palette_index >= board.material_blend.layer_count()
		):
			continue
		if (
			String(board.material_blend.layer(palette_index).get("asset_id", ""))
			== asset_id
		):
			return true
	return false


## Apply one GLB asset's current contact setting to all of its existing instances.
func apply_asset_contact_flatten(asset_id: String) -> int:
	if placement == null:
		return 0
	return placement.apply_asset_contact_flatten(asset_id)


## Rebuild only gameplay-derived visuals after an external gameplay edit.
func refresh_gameplay_visuals() -> void:
	_rebuild_gameplay_marker_visuals()
	_emit_status()
	request_render()


## Rebuild every derived view that can reference an asset removed from the open board.
func refresh_level_asset_references() -> void:
	_sync_board_incremental(
		PlacementController.BoardMutation.SURFACES
		| PlacementController.BoardMutation.PROPS
	)
	refresh_gameplay_visuals()
	refresh_material_blend_materials()


## Synchronize only gameplay marker visuals after a gameplay-tool mutation.
func _sync_gameplay_marker_mutation() -> void:
	_rebuild_gameplay_marker_visuals()
	_emit_status()
	request_render()


## Synchronize only particle visuals after a particle-tool mutation.
func _sync_particle_effect_mutation() -> void:
	_rebuild_particle_effect_visuals()
	_emit_status()
	request_render()


## Rebuild every derived particle node from the board's stable preset references.
## Return where one particle effect actually sits given its attachment mode.
##
## TERRAIN effects keep their authored X and Z and take Y from the canonical
## heightfield, so raising the ground under a campfire raises the campfire. WORLD
## effects keep the authored Y verbatim. An effect over unfilled terrain has no
## ground to attach to, so it keeps its authored position rather than snapping to
## an invented elevation.
func _particle_effect_position(placement_record: ParticleEffectPlacement) -> Vector3:
	return placement_record.world_position(board.terrain if board != null else null)

## Rebuild every derived particle emitter from canonical board placements.
func _rebuild_particle_effect_visuals() -> void:
	if particle_effects_root == null:
		return
	for child: Node in particle_effects_root.get_children():
		particle_effects_root.remove_child(child)
		child.queue_free()
	if board == null or particle_library == null or particle_factory == null:
		return
	for placement_record: ParticleEffectPlacement in board.particle_effects:
		if placement_record == null:
			push_error("[Tile Studio] Particle placement record is null.")
			continue
		var preset := particle_library.preset_by_id(placement_record.preset_id)
		if preset == null:
			push_error(
				"[Tile Studio] Particle placement '%s' references missing preset '%s'."
				% [placement_record.placement_id, placement_record.preset_id]
			)
			continue
		var emitter := particle_factory.build_emitter(preset, placement_record)
		if emitter == null:
			continue
		# A terrain-attached effect takes its height from the canonical heightfield
		# so sculpting moves it with the ground; a world effect keeps its authored Y.
		var emitter_position := _particle_effect_position(placement_record)
		emitter.position = emitter_position
		emitter.set_meta("mts_layer_y", int(floorf(emitter_position.y)))
		particle_effects_root.add_child(emitter)
		_apply_slice_to_node(emitter)


## Rebuild particle visuals after an explicit preset edit without changing board placement data.
func refresh_particle_effects() -> void:
	_rebuild_particle_effect_visuals()
	_emit_status()
	request_render()


## Rebuild every derived marker gizmo from canonical gameplay marker resources.
func _rebuild_gameplay_marker_visuals() -> void:
	if gameplay_markers_root == null:
		return
	for child: Node in gameplay_markers_root.get_children():
		gameplay_markers_root.remove_child(child)
		child.queue_free()
	if board == null:
		return
	for pack: EnemyPack in board.enemy_packs:
		if pack == null:
			push_error("[Tile Studio] enemy pack record is null.")
			continue
		var members_by_layer: Dictionary = {}
		for marker: GameplayMarker in board.gameplay_markers:
			if (
				marker == null
				or marker.marker_type != GameplayMarker.TYPE_ENEMY
				or marker.pack_id != pack.pack_id
			):
				continue
			var layer_y := marker.origin.y
			var layer_members: Array = members_by_layer.get(layer_y, [])
			layer_members.append(marker)
			members_by_layer[layer_y] = layer_members
		var sorted_layers: Array = members_by_layer.keys()
		sorted_layers.sort()
		for layer_value: Variant in sorted_layers:
			var layer_y := int(layer_value)
			var members: Array = members_by_layer[layer_y]
			var net := _build_enemy_pack_net(pack, members, layer_y)
			gameplay_markers_root.add_child(net)
	for marker: GameplayMarker in board.gameplay_markers:
		if marker == null:
			push_error("[Tile Studio] gameplay marker record is null.")
			continue
		gameplay_markers_root.add_child(_build_gameplay_marker_visual(marker))


## Build one compact net whose only input is canonical pack membership on one layer.
func _build_enemy_pack_net(
	pack: EnemyPack,
	members: Array,
	layer_y: int
) -> Node3D:
	var root := Node3D.new()
	root.name = "EnemyPackNet_%s_Y%d" % [pack.pack_id, layer_y]
	root.set_meta("mts_pack_id", pack.pack_id)
	root.set_meta("mts_layer_y", layer_y)

	var points: Array[Vector3] = []
	var hub := Vector3(0.0, float(layer_y) + PACK_NET_HEIGHT_M, 0.0)
	for member_value: Variant in members:
		var marker := member_value as GameplayMarker
		if marker == null:
			continue
		var point := Vector3(marker.origin) + Vector3(
			0.5,
			PACK_NET_HEIGHT_M,
			0.5
		)
		points.append(point)
		hub += point
	if points.is_empty():
		return root
	hub /= float(points.size())

	var color := MTSGameplayMarkerController.pack_color(pack.pack_id)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(color.r, color.g, color.b, 0.78)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 2

	var immediate_mesh := ImmediateMesh.new()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for point: Vector3 in points:
		_add_enemy_pack_net_segment(
			immediate_mesh,
			point,
			hub,
			PACK_NET_WIDTH_M
		)
	var hub_points: Array[Vector3] = [
		hub + Vector3(PACK_NET_HUB_RADIUS_M, 0.0, 0.0),
		hub + Vector3(0.0, 0.0, PACK_NET_HUB_RADIUS_M),
		hub + Vector3(-PACK_NET_HUB_RADIUS_M, 0.0, 0.0),
		hub + Vector3(0.0, 0.0, -PACK_NET_HUB_RADIUS_M),
	]
	for hub_index in hub_points.size():
		_add_enemy_pack_net_segment(
			immediate_mesh,
			hub_points[hub_index],
			hub_points[(hub_index + 1) % hub_points.size()],
			PACK_NET_WIDTH_M
		)
	immediate_mesh.surface_end()

	var net_mesh := MeshInstance3D.new()
	net_mesh.name = "Net"
	net_mesh.mesh = immediate_mesh
	net_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(net_mesh)
	_apply_slice_to_node(root)
	return root


## Add one flat ribbon segment so a pack connection stays legible on the grid.
func _add_enemy_pack_net_segment(
	immediate_mesh: ImmediateMesh,
	start: Vector3,
	end: Vector3,
	width: float
) -> void:
	var direction := end - start
	var horizontal_direction := Vector3(direction.x, 0.0, direction.z)
	if horizontal_direction.length_squared() <= 0.000001:
		return
	var side := Vector3(
		-horizontal_direction.z,
		0.0,
		horizontal_direction.x
	).normalized() * width * 0.5
	var start_left := start - side
	var start_right := start + side
	var end_left := end - side
	var end_right := end + side
	for vertex: Vector3 in [
		start_left,
		start_right,
		end_right,
		start_left,
		end_right,
		end_left,
	]:
		immediate_mesh.surface_add_vertex(vertex)


## Build one readable marker or its explicitly assigned GLB at the authored cell minimum.
## Return where one marker actually stands on the canonical terrain.
##
## The marker's authored address is its integer lattice cell, but the ground under
## that cell is at a real elevation the lattice cannot express. Deriving the drawn
## height from the terrain each rebuild is what keeps a marker on the surface after
## the heightfield beneath it is sculpted, instead of leaving it buried or floating.
## A marker over unfilled terrain has no ground to stand on, so it keeps its
## authored level rather than being silently relocated.
func _marker_stand_position(marker: GameplayMarker) -> Vector3:
	var cell := Vector2i(marker.origin.x, marker.origin.z)
	if board == null or not board.terrain.is_cell_filled(cell):
		return Vector3(marker.origin)
	return Vector3(
		float(marker.origin.x),
		board.terrain.cell_walk_height(cell),
		float(marker.origin.z)
	)


func _build_gameplay_marker_visual(marker: GameplayMarker) -> Node3D:
	var root := Node3D.new()
	root.name = "GameplayMarker_%s" % marker.marker_id
	var stand_position := _marker_stand_position(marker)
	root.position = stand_position
	root.set_meta("mts_placement", marker)
	# The lattice level stays the marker's canonical address for slicing, while the
	# drawn height comes from the terrain so sculpting carries the marker with it.
	root.set_meta("mts_layer_y", marker.origin.y)
	root.set_meta(
		"mts_bounds",
		AABB(
			stand_position + Vector3(0.2, 0.0, 0.2),
			Vector3(0.6, 1.5, 0.6)
		)
	)

	var color := MTSGameplayMarkerController.marker_color(marker.marker_type)
	if marker.marker_type == GameplayMarker.TYPE_ENEMY and not marker.pack_id.is_empty():
		color = MTSGameplayMarkerController.pack_color(marker.pack_id)
	# Enemy pins identify the reusable monster type instead of an incidental
	# placement sequence such as enemy_1; other marker labels keep their ID.
	var marker_title := (
		marker.monster_id
		if marker.marker_type == GameplayMarker.TYPE_ENEMY
		else marker.marker_id
	)

	var visual_asset_id := ""
	if board != null and marker.marker_type == GameplayMarker.TYPE_ENEMY:
		visual_asset_id = board.monster_visual_asset_id(marker.monster_id)
	if not visual_asset_id.is_empty():
		var visual_asset := board.resolve_monster_visual_asset(marker.monster_id)
		if visual_asset == null:
			_add_gameplay_marker_label(root, marker_title, Color(1.0, 0.25, 0.2), 1.28)
			_apply_slice_to_node(root)
			return root
		var monster_visual := _instantiate_monster_visual(marker.monster_id, visual_asset)
		if monster_visual == null:
			_add_gameplay_marker_label(root, marker_title, Color(1.0, 0.25, 0.2), 1.28)
			_apply_slice_to_node(root)
			return root
		root.add_child(monster_visual)
		root.set_meta(
			"mts_bounds",
			AABB(stand_position, Vector3(visual_asset.grid_bounds))
		)
		_add_gameplay_marker_label(
			root,
			marker_title,
			color,
			maxf(visual_asset.visual_size_m.y + 0.25, 1.28)
		)
		_apply_slice_to_node(root)
		return root

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	material.render_priority = 3

	# The saved origin is the unit cell minimum. Local X/Z values of 0.5 derive
	# the visible cell centre while the canonical placement root stays unchanged.
	var stem := MeshInstance3D.new()
	stem.name = "Stem"
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = 0.08
	stem_mesh.bottom_radius = 0.08
	stem_mesh.height = 0.7
	stem_mesh.radial_segments = 12
	stem.mesh = stem_mesh
	stem.position = Vector3(0.5, 0.35, 0.5)
	stem.material_override = material
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(stem)

	var head := MeshInstance3D.new()
	head.name = "Head"
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.26
	head_mesh.height = 0.52
	head_mesh.radial_segments = 16
	head_mesh.rings = 8
	head.mesh = head_mesh
	head.position = Vector3(0.5, 0.82, 0.5)
	head.material_override = material
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)

	_add_gameplay_marker_label(root, marker_title, color, 1.28)
	_apply_slice_to_node(root)
	return root


## Instantiate one project-owned monster GLB from the same canonical pose used by prop sizing.
func _instantiate_monster_visual(monster_id: String, asset: TileAsset) -> Node3D:
	var source_model := _prop_model_for_asset(asset)
	if source_model == null:
		push_error("[Tile Studio] monster '%s' GLB could not be loaded." % monster_id)
		return null
	var visual := source_model.duplicate() as Node3D
	if visual == null:
		push_error("[Tile Studio] monster '%s' GLB hierarchy could not be instantiated." % monster_id)
		return null
	visual.name = "MonsterVisual"
	visual.transform = asset.prop_pose_transform
	_set_backface_culling_recursive(
		visual,
		board.aesthetics.backface_culling_enabled
	)
	return visual


## Add the one-title-only label shared by pin and GLB monster presentations.
func _add_gameplay_marker_label(
	root: Node3D,
	title: String,
	color: Color,
	height_m: float
) -> void:
	var label := Label3D.new()
	label.name = "MarkerLabel"
	label.position = Vector3(0.5, height_m, 0.5)
	label.text = title
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.no_depth_test = true
	label.font_size = 16
	label.outline_size = 5
	label.pixel_size = 0.003
	label.modulate = color
	root.add_child(label)
## Rebuild the complete derived grime texture without moving canonical prop roots.
func _rebuild_world_contacts() -> void:
	_rebuild_world_contact_textures()
## Restamp visual contact grime without rebuilding geometry.
func _rebuild_world_contact_textures() -> bool:
	if world_surface_fields == null or board == null or library == null:
		push_error("[Tile Studio] cannot rebuild contact textures without bound board fields.")
		return false
	world_surface_fields.clear_contacts(false)
	_stamp_wall_floor_contacts(false)
	for prop: PropPlacement in board.props:
		var prop_asset := board.resolve_prop_asset(prop)
		if prop_asset == null:
			continue
		_stamp_prop_contact(prop, prop_asset, false)
	world_surface_fields.upload_interaction()
	return true
## Update visual grime from only the structural and GLB contributors that changed.
func _update_world_contacts(
	added_surfaces: Array[SurfacePlacement],
	removed_prop_contact_ids: PackedStringArray,
	added_props: Array[PropPlacement]
) -> void:
	if world_surface_fields == null or board == null or library == null:
		push_error("[Tile Studio] cannot update contacts without bound world fields.")
		return
	var contact_started_usec := Time.get_ticks_usec()
	for contact_id: String in removed_prop_contact_ids:
		world_surface_fields.remove_contact_source(contact_id, false)
	if not added_surfaces.is_empty():
		# A new floor can create contact under an existing wall. Wall contributors
		# retain stable ids, so restamping them changes only their own field pixels.
		_stamp_wall_floor_contacts(false)
	var removed_finished_usec := Time.get_ticks_usec()
	for prop: PropPlacement in added_props:
		var prop_asset := board.resolve_prop_asset(prop)
		if prop_asset != null:
			_stamp_prop_contact(prop, prop_asset, false)
	var stamped_finished_usec := Time.get_ticks_usec()
	world_surface_fields.upload_interaction()
	var uploaded_finished_usec := Time.get_ticks_usec()
	_last_contact_profile_ms = {
		"remove": float(removed_finished_usec - contact_started_usec) / 1000.0,
		"stamp": float(stamped_finished_usec - removed_finished_usec) / 1000.0,
		"interaction_upload": float(uploaded_finished_usec - stamped_finished_usec) / 1000.0,
	}


## Return the exact XZ terrain cells covered by one surface placement.
##
## Occupied-face records are the canonical footprint, so large and clipped
## stamps never collapse back to their origin cell for paint invalidation.
func _terrain_cells_for_surface(surface: SurfacePlacement) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if board == null or terrain_renderer == null or surface == null:
		return cells
	# Paint identifies its faces by stable UID, so the terrain renderer resolves
	# each one to the cell it currently occupies rather than trusting a stored
	# lattice address that sculpting may since have moved.
	for uid: String in surface.terrain_face_uids:
		var located: Dictionary = terrain_renderer.cell_for_paint_uid(uid)
		if located.is_empty():
			continue
		var cell_xz: Vector2i = located["cell"]
		if not cells.has(cell_xz):
			cells.append(cell_xz)
	return cells


## Build one placement-owned node while canonical terrain supplies painted geometry.
##
## Terrain paint is material state on the heightfield and therefore contributes
## no mesh, decal, or collider of its own. This node exists purely so selection,
## slice visibility, and bounds have one record per placement to read.
func _build_surface_node(
	surface: SurfacePlacement,
	asset: TileAsset
) -> Node3D:
	var root := Node3D.new()
	root.name = "Surface_%s" % surface.asset_id
	root.position = Vector3(surface.origin)

	# Only a native Decal owns a node of its own. A shader decal is an ordinary
	# placement-local layer on the receiving terrain material, so it contributes no
	# child here for the same reason ordinary terrain paint does not.
	if surface.is_decal():
		var local_transform := SurfacePlacement.transform_for_size(
			surface.origin,
			surface.face,
			surface.rotation_quarters,
			surface.canonical_footprint(asset),
			surface.grid_anchor
		)
		local_transform.origin -= root.position
		var decal := _build_decal_node(surface, asset, local_transform)
		if decal != null:
			root.add_child(decal)

	root.set_meta("mts_placement", surface)
	root.set_meta("mts_spatial_signature", _placement_spatial_signature(surface))
	root.set_meta("mts_layer_y", surface.origin.y)
	root.set_meta("mts_bounds", _surface_bounds(surface, asset))
	return root


## Return the projection depth one native decal needs to reach its real receivers.
##
## A Decal affects only fragments INSIDE its box. A fixed thin slab therefore works
## on perfectly flat ground and nowhere else: the moment the surface slopes or
## steps, it leaves the slab and the stamp is clipped away, which reads as the
## decal refusing to follow the terrain.
##
## The depth is derived from how far the placement's OWN receiver faces actually
## depart from its plane, so it is exactly as deep as the relief under it and no
## deeper. The box stays centred on the plane, so it is sized to twice the larger
## departure plus a margin, covering both directions without being re-centred.
##
## Bleed-through stays bounded for the same reason: depth never exceeds the relief
## genuinely beneath the stamp, and normal_fade still rejects the far side of a
## wall, whose surface faces away from the projection axis.
func _decal_projection_depth_m(
	surface: SurfacePlacement,
	local_surface_transform: Transform3D,
	outward_normal: Vector3
) -> float:
	# Enough to absorb float error and the shallow relief of an almost-flat cell.
	const MINIMUM_DEPTH_M := 0.25
	# Terrain relief can be arbitrarily tall; past this a projector stops being a
	# stamp and starts painting unrelated geometry, so it is reported and clamped.
	const MAXIMUM_DEPTH_M := 32.0
	const MARGIN_M := 0.1
	if terrain_renderer == null:
		return MINIMUM_DEPTH_M
	# The node's local frame is the world frame less the placement root offset, and
	# the surface root sits at the placement origin, so the world plane point is
	# recovered by adding it back.
	var world_plane_point := local_surface_transform.origin + Vector3(surface.origin)
	var extent := terrain_renderer.receiver_extent_along_axis(
		surface.terrain_face_uids,
		world_plane_point,
		outward_normal
	)
	if extent.is_empty():
		return MINIMUM_DEPTH_M
	var reach := maxf(
		absf(float(extent["minimum"])),
		absf(float(extent["maximum"]))
	)
	var depth := reach * 2.0 + MARGIN_M
	if depth > MAXIMUM_DEPTH_M:
		push_warning(
			"[Tile Studio] decal '%s' spans %.2f m of relief; clamping its projection to %.1f m."
			% [surface.asset_id, reach * 2.0, MAXIMUM_DEPTH_M]
		)
		return MAXIMUM_DEPTH_M
	return maxf(depth, MINIMUM_DEPTH_M)


## Build one Godot-native Decal from the saved surface transform and PBR map set.
##
## Surface placement uses local XY with +Z outward, while Decal uses local XZ
## and projects along -Y. Reordering those same basis axes preserves image-right
## and image-up without changing the placement root's exact authored origin.
func _build_decal_node(
	surface: SurfacePlacement,
	asset: TileAsset,
	local_surface_transform: Transform3D
) -> Decal:
	if material_factory == null:
		push_error("[Tile Studio] Cannot build decal '%s' without a material factory." % surface.asset_id)
		return null
	if asset == null:
		push_error("[Tile Studio] Cannot build decal for a missing surface asset.")
		return null

	var surface_basis := local_surface_transform.basis.orthonormalized()
	var outward_normal := surface_basis.z
	var projector_basis := Basis(
		surface_basis.x,
		outward_normal,
		-surface_basis.y
	)
	var footprint := surface.canonical_footprint(asset)
	var decal := Decal.new()
	decal.name = "Projection"
	decal.size = Vector3(
		float(footprint.x),
		_decal_projection_depth_m(surface, local_surface_transform, outward_normal),
		float(footprint.y)
	)
	decal.transform = Transform3D(projector_basis, local_surface_transform.origin)
	if not _configure_native_decal(decal, surface, asset):
		decal.free()
		return null
	return decal


## Configure one native Decal from the original maps and its optional palette tint.
##
## Palette matching multiplies the node's existing authored tint after material
## configuration, so the albedo texture itself remains full-resolution and untouched.
func _configure_native_decal(
	decal: Decal,
	surface: SurfacePlacement,
	asset: TileAsset
) -> bool:
	var palette_adjustment: Dictionary = {}
	if surface.match_underlying_palette:
		palette_adjustment = _native_decal_palette_adjustment(surface)
		if palette_adjustment.is_empty():
			return false
	if not material_factory.configure_decal(decal, asset):
		return false
	if not palette_adjustment.is_empty():
		var palette_modulate := palette_adjustment["modulate"] as Color
		decal.modulate = Color(
			decal.modulate.r * palette_modulate.r,
			decal.modulate.g * palette_modulate.g,
			decal.modulate.b * palette_modulate.b,
			decal.modulate.a
		)
	return true


## Return the fixed-cost palette adjustment for one native decal placement.
func _native_decal_palette_adjustment(surface: SurfacePlacement) -> Dictionary:
	if surface == null or not surface.match_underlying_palette:
		return {}
	if (
		board == null
		or library == null
		or material_factory == null
		or _surface_palette_matcher_script == null
	):
		push_error("[Tile Studio] Native decal palette matching is missing required render data.")
		return {}
	return _surface_palette_matcher_script.call(
		"native_adjustment",
		surface,
		board,
		library,
		material_factory,
		surface_material_paint
	) as Dictionary


## Return the affine palette adjustment for one direct shader-decal layer.
##
## Only small color statistics are analyzed; the GPU still samples every original
## source texture at its imported resolution without creating a processed copy.
func _shader_decal_palette_adjustment(surface: SurfacePlacement) -> Dictionary:
	if surface == null or not surface.match_underlying_palette:
		return {}
	if (
		board == null
		or library == null
		or material_factory == null
		or _surface_palette_matcher_script == null
	):
		push_error("[Tile Studio] Shader decal palette matching is missing required render data.")
		return {}
	return _surface_palette_matcher_script.call(
		"shader_adjustment",
		surface,
		board,
		library,
		material_factory,
		surface_material_paint
	) as Dictionary


## Refresh percentage-mask ranges from canonical height blocks and board bounds.
##
## Existing materials receive two scalar pairs only when requested; no mesh,
## texture array, contact field, collision, or GLB data is rebuilt.
func _refresh_material_mask_ranges(update_existing_materials: bool = true) -> void:
	_material_world_height_range = (
		world_surface_fields.height_value_range()
		if world_surface_fields != null
		else Vector2.ZERO
	)
	if board != null:
		var bounds := _board_bounds()
		_material_world_elevation_range = Vector2(
			bounds.position.y,
			bounds.end.y
		)
	else:
		_material_world_elevation_range = Vector2(0.0, 1.0)
	if is_equal_approx(
		_material_world_elevation_range.x,
		_material_world_elevation_range.y
	):
		_material_world_elevation_range.y += 1.0
	if not update_existing_materials:
		return
	for material: ShaderMaterial in _all_surface_shader_materials():
		material.set_shader_parameter(
			"material_world_height_range",
			_material_world_height_range
		)
		material.set_shader_parameter(
			"material_world_elevation_range",
			_material_world_elevation_range
		)


## Return the live terrain materials without scene-wide scans.
##
## Terrain owns every visible surface material now, so this is simply the
## terrain renderer's batch materials with duplicates removed.
func _all_surface_shader_materials() -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = []
	if terrain_renderer == null:
		return materials
	var seen: Dictionary = {}
	for material: ShaderMaterial in terrain_renderer.terrain_shader_materials():
		if seen.has(material.get_instance_id()):
			continue
		seen[material.get_instance_id()] = true
		materials.append(material)
	return materials

## Apply the visible transient mask-preview choice to existing batch materials in place.
##
## The stored selection is a board palette index, while each batch receives a dedicated
## preview recipe that never consumes or changes one of its four authored RGBA slots.
func set_material_mask_preview(enabled: bool, palette_index: int) -> void:
	material_mask_preview_enabled = enabled
	material_mask_preview_palette_index = maxi(palette_index, 0)
	for material: ShaderMaterial in _all_surface_shader_materials():
		_apply_material_mask_preview_to_material(material)
	request_render()

## Bind the selected recipe to one batch's transient preview uniforms.
func _apply_material_mask_preview_to_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	var preview_ready := false
	if (
		material_mask_preview_enabled
		and material_factory != null
		and board != null
		and material_mask_preview_palette_index < board.material_blend.layer_count()
	):
		preview_ready = material_factory.configure_material_mask_preview(
			material,
			material_mask_preview_palette_index,
			board.material_blend
		)
	material.set_shader_parameter(
		"material_mask_preview_enabled",
		material_mask_preview_enabled and preview_ready
	)


## Rebind one terrain batch after its first sparse control array is allocated.
##
## Only the heavy shader's control-array binding changes; terrain geometry,
## collision, contacts, other batches, and GLBs remain untouched.
func _refresh_material_paint_batch(batch_key: String) -> void:
	if not MTSTerrainRenderer.is_terrain_batch_key(batch_key):
		push_error(
			"[Tile Studio] material paint reported non-terrain batch '%s'." % batch_key
		)
		return
	# Layer indices are assigned when the terrain batch is registered, even while
	# its control array is neutral. Allocating the first real array therefore
	# changes only the heavy shader binding; geometry and collision stay resident.
	if terrain_renderer != null and surface_material_paint != null:
		var chunk := MTSTerrainRenderer.chunk_from_batch_key(batch_key)
		for surface: Dictionary in terrain_renderer.chunk_surfaces(chunk):
			if String(surface["key"]) != batch_key:
				continue
			var material := _terrain_surface_material(chunk, surface)
			if material != null:
				terrain_renderer.set_chunk_surface_material(
					chunk,
					int(surface["surface_index"]),
					material
				)
	request_render()

## Queue one face-local palette change for a single batched visual refresh this frame.
func _on_material_palette_slots_changed(placement_uid: String) -> void:
	if terrain_renderer == null:
		return
	var cell_record := terrain_renderer.cell_for_paint_uid(placement_uid)
	if cell_record.is_empty():
		return
	var cell: Vector2i = cell_record["cell"]
	var changed_cell := Rect2i(cell, Vector2i.ONE)
	_pending_material_slot_cells = (
		changed_cell
		if _pending_material_slot_cells.size == Vector2i.ZERO
		else _pending_material_slot_cells.merge(changed_cell)
	)
	if _material_slot_refresh_queued:
		return
	_material_slot_refresh_queued = true
	call_deferred("_flush_material_palette_slot_changes")


## Regroup only chunks whose faces changed RGBA palette meaning.
##
## Collision and canonical terrain remain resident. Multiple face assignments in one
## input frame merge into this one visual-batch rebuild, bounding the draw-call update.
func _flush_material_palette_slot_changes() -> void:
	_material_slot_refresh_queued = false
	var changed_cells := _pending_material_slot_cells
	_pending_material_slot_cells = Rect2i()
	if (
		changed_cells.size == Vector2i.ZERO
		or terrain_renderer == null
		or surface_material_paint == null
		or board == null
	):
		return
	var changed_chunks := terrain_renderer.refresh_paint_for_cells(
		changed_cells,
		surface_material_paint,
		board
	)
	_apply_terrain_material_chunks(changed_chunks)
	request_render()


## Assign one palette entry to every terrain face without accepting a partial pass.
func assign_material_palette_to_all_faces(palette_index: int) -> Dictionary:
	if terrain_renderer == null or surface_material_paint == null:
		return {"error": ERR_UNCONFIGURED, "face_uid": "", "patches": {}}
	return surface_material_paint.assign_palette_to_faces(
		palette_index,
		terrain_renderer.paint_uids()
	)


## Recreate every terrain material after a level-wide material invalidation.
##
## This is intentionally the exceptional path: terrain lifecycle rebuilds and
## board-wide asset removal can invalidate every batch at once. Ordinary profile
## controls, mask choices, splatmap settings, and single-asset edits use the
## scoped functions below and preserve existing ShaderMaterial instances.
func refresh_material_blend_materials() -> void:
	if surface_material_paint != null:
		surface_material_paint.bind_profile(
			board.material_blend if board != null else null
		)
	_refresh_material_mask_ranges(false)
	_apply_terrain_material()
	request_render()


## Apply one committed profile change with the narrowest valid live-material update.
##
## Scalar and mask edits change uniforms in place. Texture recipes are rebound only
## on batches where canonical paint actually uses the changed palette entry. The
## optional import flag preserves a source projection that was validated atomically
## before the profile was installed.
func refresh_material_profile_change(
	before_json: Dictionary,
	splatmap_projection_already_valid: bool = false
) -> bool:
	if board == null or board.material_blend == null or material_factory == null:
		push_error("[Tile Studio] Cannot refresh a material profile without an active board and factory.")
		return false
	var before_profile := MaterialBlendProfile.new()
	before_profile.from_json(before_json)
	var after_profile := board.material_blend
	var after_json := after_profile.to_json().duplicate(true)
	if surface_material_paint != null:
		surface_material_paint.bind_profile(after_profile)

	var before_layers_value: Variant = before_json.get("layers", [])
	var after_layers_value: Variant = after_json.get("layers", [])
	var before_layers: Array = before_layers_value as Array if before_layers_value is Array else []
	var after_layers: Array = after_layers_value as Array if after_layers_value is Array else []
	var texture_rebind_candidates: Dictionary = {}
	var control_only_indices: PackedInt32Array = PackedInt32Array()
	for layer_index: int in maxi(before_layers.size(), after_layers.size()):
		var before_layer: Dictionary = (
			(before_layers[layer_index] as Dictionary)
			if layer_index < before_layers.size() and before_layers[layer_index] is Dictionary
			else {}
		)
		var after_layer: Dictionary = (
			(after_layers[layer_index] as Dictionary)
			if layer_index < after_layers.size() and after_layers[layer_index] is Dictionary
			else {}
		)
		if before_layer == after_layer:
			continue
		var introduces_world_height := (
			not _material_layer_uses_world_height(before_layer)
			and _material_layer_uses_world_height(after_layer)
		)
		if (
			_material_layer_requires_texture_rebind(before_layer, after_layer)
			or introduces_world_height
		):
			texture_rebind_candidates[layer_index] = true
		else:
			control_only_indices.append(layer_index)

	var reconfigure_every_material := (
		int(before_profile.debug_view) != MaterialBlendProfile.DebugView.WORLD_HEIGHT
		and int(after_profile.debug_view) == MaterialBlendProfile.DebugView.WORLD_HEIGHT
	)
	if (
		not before_profile.uses_world_height()
		and after_profile.uses_world_height()
		and material_mask_preview_enabled
		and material_mask_preview_palette_index < after_profile.layer_count()
		and _material_layer_uses_world_height(
			after_profile.layer(material_mask_preview_palette_index)
		)
	):
		reconfigure_every_material = true
	if not before_profile.enabled and after_profile.enabled:
		for used_index: int in _used_palette_indices_for_profile(after_profile):
			texture_rebind_candidates[used_index] = true

	if reconfigure_every_material:
		_reconfigure_existing_material_blends()
	elif not texture_rebind_candidates.is_empty():
		var used_indices: Dictionary = {}
		for used_index: int in _used_palette_indices_for_profile(before_profile):
			used_indices[used_index] = true
		for used_index: int in _used_palette_indices_for_profile(after_profile):
			used_indices[used_index] = true
		var indices_to_rebind := PackedInt32Array()
		var ordered_candidates := texture_rebind_candidates.keys()
		ordered_candidates.sort()
		for index_value: Variant in ordered_candidates:
			var palette_index := int(index_value)
			if used_indices.has(palette_index):
				indices_to_rebind.append(palette_index)
		if not indices_to_rebind.is_empty():
			_reconfigure_existing_material_blends(indices_to_rebind)

	for layer_index: int in control_only_indices:
		if layer_index >= 0 and layer_index < after_profile.layer_count():
			refresh_material_blend_layer_controls(layer_index)

	for material: ShaderMaterial in _all_surface_shader_materials():
		material.set_shader_parameter("material_blend_enabled", after_profile.enabled)
		material.set_shader_parameter("material_blend_mode", int(after_profile.blend_mode))
		material.set_shader_parameter("material_debug_view", int(after_profile.debug_view))
		material_factory.configure_splatmap_channel_strengths(material, after_profile)
		_apply_material_mask_preview_to_material(material)

	var source_projection_changed := false
	for key: String in [
		"splatmap_source_path",
		"splatmap_palette_indices",
		"splatmap_projection",
		"splatmap_fill_empty_regions",
		"splatmap_empty_region_channel",
	]:
		if before_json.get(key, null) != after_json.get(key, null):
			source_projection_changed = true
			break
	var overlay_changed := (
		bool(before_json.get("splatmap_overlay_enabled", false))
		!= after_profile.splatmap_overlay_enabled
	)
	if source_projection_changed and not splatmap_projection_already_valid:
		_invalidate_splatmap_projection()
		if (
			not after_profile.splatmap_source_path.is_empty()
			and not _ensure_splatmap_projection()
		):
			return false
	if source_projection_changed or overlay_changed:
		if (
			after_profile.splatmap_overlay_enabled
			and not after_profile.splatmap_source_path.is_empty()
			and not _ensure_splatmap_projection()
		):
			return false
		_refresh_splatmap_material_controls()

	if (
		bool(before_json.get("auto_texture_thin_side_slivers", false))
		!= after_profile.auto_texture_thin_side_slivers
	):
		refresh_thin_side_texture_seeds()
	request_render()
	return true


## Return whether one layer edit changes textures, enablement, or application ownership.
static func _material_layer_requires_texture_rebind(
	before_layer: Dictionary,
	after_layer: Dictionary
) -> bool:
	for key: String in ["enabled", "asset_id", "application_mode"]:
		if before_layer.get(key, null) != after_layer.get(key, null):
			return true
	return false


## Return whether one stored layer recipe consumes the world-height field.
static func _material_layer_uses_world_height(material_layer: Dictionary) -> bool:
	if not bool(material_layer.get("enabled", false)):
		return false
	var rules_value: Variant = material_layer.get("masks", [])
	if not rules_value is Array:
		return false
	for rule_value: Variant in rules_value as Array:
		if (
			rule_value is Dictionary
			and int((rule_value as Dictionary).get("source", -1))
			== MaterialBlendProfile.MaskSource.WORLD_HEIGHT
		):
			return true
	return false


## Resolve visible palette entries against one candidate recipe without rebinding it globally.
func _used_palette_indices_for_profile(
	candidate_profile: MaterialBlendProfile
) -> PackedInt32Array:
	if surface_material_paint == null:
		return PackedInt32Array()
	return surface_material_paint.used_palette_indices_for_profile(candidate_profile)


## Rebind PBR textures and shader features on existing materials that use selected palette entries.
##
## An empty filter means every live material genuinely requires a shader-feature
## transition. Material objects, terrain meshes, collision, and control images remain resident.
func _reconfigure_existing_material_blends(
	palette_indices: PackedInt32Array = PackedInt32Array()
) -> void:
	if board == null or board.material_blend == null or material_factory == null:
		return
	var filter_indices: Dictionary = {}
	for palette_index: int in palette_indices:
		filter_indices[palette_index] = true
	for material: ShaderMaterial in _all_surface_shader_materials():
		var slots_value: Variant = material.get_meta(
			SurfaceMaterialFactory.SURFACE_BLEND_SLOT_MATERIALS_META,
			PackedInt32Array()
		)
		var slots: PackedInt32Array = (
			slots_value as PackedInt32Array
			if slots_value is PackedInt32Array
			else PackedInt32Array()
		)
		if not filter_indices.is_empty():
			var matches_filter := false
			for palette_index: int in slots:
				if filter_indices.has(palette_index):
					matches_filter = true
					break
			if not matches_filter:
				continue
		var is_top := bool(material.get_shader_parameter("terrain_grid_is_top"))
		var control_texture := (
			material.get_shader_parameter("material_control_tex") as Texture2DArray
		)
		material_factory.configure_material_blend(
			material,
			control_texture,
			board.material_blend,
			library,
			_material_world_height_range,
			_material_world_elevation_range,
			slots
		)
		_apply_material_mask_preview_to_material(material)
		_configure_terrain_grid_material(material, is_top)


## Refresh source-overlay and strength uniforms without replacing terrain materials.
func _refresh_splatmap_material_controls() -> void:
	if board == null or board.material_blend == null or material_factory == null:
		return
	for material: ShaderMaterial in _all_surface_shader_materials():
		material_factory.configure_splatmap_channel_strengths(
			material,
			board.material_blend
		)
		_configure_terrain_grid_material(
			material,
			bool(material.get_shader_parameter("terrain_grid_is_top"))
		)


## Re-resolve only terrain material batches after changing thin side-strip seeding.
##
## This updates direct PNG grouping and derived splat-array source links across the
## board without rebuilding canonical terrain geometry, collision, or gameplay state.
func refresh_thin_side_texture_seeds() -> void:
	if board == null or terrain_renderer == null:
		return
	var terrain_cells := board.terrain.filled_bounds_cells()
	if terrain_cells.size.x <= 0 or terrain_cells.size.y <= 0:
		return
	var changed_chunks := terrain_renderer.refresh_paint_for_cells(
		terrain_cells,
		surface_material_paint,
		board
	)
	_apply_terrain_material_chunks(changed_chunks)
	request_render()


## Update one layer's live scalar and mask uniforms without recreating batch materials or reloading PBR maps.
func refresh_material_blend_layer_controls(layer_index: int) -> void:
	if board == null or board.material_blend == null or material_factory == null:
		push_error("[Tile Studio] Cannot refresh material controls without an active board and factory.")
		return
	if layer_index < 0 or layer_index >= board.material_blend.layer_count():
		push_error(
			"[Tile Studio] Material palette index %d is outside 0..%d."
			% [layer_index, board.material_blend.layer_count() - 1]
		)
		return
	if surface_material_paint != null:
		surface_material_paint.bind_profile(board.material_blend)
	for material: ShaderMaterial in _all_surface_shader_materials():
		material_factory.configure_material_layer_controls(
			material,
			layer_index,
			board.material_blend,
			library
		)
		# The preview recipe is independent of authored face slots and must follow
		# live mask-slider edits even on faces that do not carry this palette entry.
		_apply_material_mask_preview_to_material(material)
	request_render()

## Clear only authored material-control pixels and optionally register their sparse undo patch.
func clear_surface_material_paint(record_undo: bool = false) -> void:
	if surface_material_paint == null:
		return
	var patches := surface_material_paint.clear_all_paint()
	if board != null:
		board.surface_material_paint.clear()
	request_render()
	if record_undo and _height_undo_redo != null and not patches.is_empty():
		_height_undo_redo.create_action(
			"Clear brush material paint",
			UndoRedo.MERGE_DISABLE,
			null,
			false
		)
		_height_undo_redo.add_do_method(self, "clear_surface_material_paint", false)
		_height_undo_redo.add_undo_method(self, "_apply_material_paint_patch", patches, "before")
		_height_undo_redo.commit_action(false)


## Return or append the brush palette entry selected for one splatmap channel.
func _palette_index_for_splat_asset(
	profile: MaterialBlendProfile,
	asset_id: String
) -> int:
	for palette_index: int in profile.layer_count():
		var layer := profile.layer(palette_index)
		if (
			String(layer.get("asset_id", "")) == asset_id
			and int(layer.get("application_mode", -1))
			== MaterialBlendProfile.ApplicationMode.BRUSH
		):
			return palette_index
	for palette_index: int in profile.layer_count():
		if String(profile.layer(palette_index).get("asset_id", "")).is_empty():
			return palette_index
	return profile.add_layer(MaterialBlendProfile.default_layer(profile.layer_count()))


## Load one directional RGBA control source and assign its four visible material slots.
##
## Loading prepares the optional base-filled source and guide texture, but deliberately leaves
## canonical terrain paint untouched until the base-coat brush or whole-terrain action runs.
func import_terrain_splatmap(
	source_image: Image,
	slot_asset_ids: PackedStringArray,
	source_path: String
) -> Dictionary:
	if (
		board == null
		or board.material_blend == null
		or surface_material_paint == null
		or terrain_renderer == null
	):
		push_error("[Tile Studio] Cannot load a splatmap without active terrain and paint state.")
		return {"error": ERR_UNCONFIGURED}
	if slot_asset_ids.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("[Tile Studio] Splatmap loading requires exactly four visible slot assignments.")
		return {"error": ERR_INVALID_PARAMETER}
	if source_path.is_empty() or not FileAccess.file_exists(source_path):
		push_error("[Tile Studio] Splatmap loading requires its visible source image path.")
		return {"error": ERR_FILE_NOT_FOUND}
	var before_json := board.material_blend.to_json().duplicate(true)
	var target_profile := MaterialBlendProfile.new()
	target_profile.from_json(before_json)
	var active_channels := PackedByteArray([0, 0, 0, 0])
	var splatmap_palette_indices := PackedInt32Array([-1, -1, -1, -1])
	var has_active_splat_slot := false
	# Literal RGBA channels point into the unbounded board palette without
	# overwriting its first four entries. Painting the splatmap later installs this
	# exact mapping on each targeted face alongside the replacement RGBA weights.
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var asset_id := slot_asset_ids[channel_index]
		if asset_id.is_empty():
			continue
		var asset := library.get_asset(asset_id) if library != null else null
		if asset == null or not asset.is_surface():
			push_error(
				"[Tile Studio] Splatmap slot %d requires a valid PNG surface asset '%s'."
				% [channel_index + 1, asset_id]
			)
			return {"error": ERR_INVALID_DATA}
		var palette_index := _palette_index_for_splat_asset(target_profile, asset_id)
		var layer := MaterialBlendProfile.default_layer(palette_index)
		layer["asset_id"] = asset_id
		layer["application_mode"] = MaterialBlendProfile.ApplicationMode.BRUSH
		layer["enabled"] = true
		layer["opacity_percent"] = 100.0
		layer["masks"] = [
			MaterialBlendProfile.default_rule(
				MaterialBlendProfile.MaskSource.PAINT,
				palette_index
			)
		]
		target_profile.set_layer(palette_index, layer)
		splatmap_palette_indices[channel_index] = palette_index
		active_channels[channel_index] = 1
		has_active_splat_slot = true
	target_profile.splatmap_palette_indices = splatmap_palette_indices
	target_profile.enabled = target_profile.has_active_layers()
	target_profile.blend_mode = MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
	target_profile.splatmap_source_path = source_path
	target_profile.splatmap_mode_enabled = true
	target_profile.splatmap_overlay_enabled = false
	target_profile.debug_view = MaterialBlendProfile.DebugView.FINAL_MATERIAL
	if not has_active_splat_slot:
		push_error("[Tile Studio] Splatmap loading needs at least one assigned material slot.")
		return {"error": ERR_INVALID_PARAMETER}
	var projection_face := _splatmap_face_for_projection(target_profile.splatmap_projection)
	var targets := terrain_renderer.splatmap_targets(projection_face)
	# Validate the projection against the live terrain before the profile is replaced,
	# so a control image that cannot be projected leaves the current materials intact.
	var bounds_result := surface_material_paint.splatmap_terrain_bounds(targets)
	if int(bounds_result.get("error", FAILED)) != OK:
		return {"error": int(bounds_result.get("error", FAILED))}
	var prepared_source := surface_material_paint.prepare_splatmap_source(
		source_image,
		active_channels,
		target_profile.splatmap_fill_empty_regions,
		target_profile.splatmap_empty_region_channel
	)
	if prepared_source == null:
		return {"error": ERR_CANT_CREATE}
	var projection_cache := _build_splatmap_projection_cache(
		prepared_source,
		targets,
		bounds_result,
		active_channels
	)
	if projection_cache.is_empty():
		return {"error": ERR_CANT_CREATE}
	var after_json := target_profile.to_json().duplicate(true)
	board.material_blend.from_json(after_json)
	surface_material_paint.bind_profile(board.material_blend)
	# Install the already validated cache only after the profile commit, so a failed
	# source or projection never exposes a partially changed material configuration.
	_install_splatmap_projection_cache(projection_cache)
	if not refresh_material_profile_change(before_json, true):
		push_error("[Tile Studio] The validated splatmap profile could not refresh live materials.")
		board.material_blend.from_json(before_json)
		if not refresh_material_profile_change(after_json):
			push_error("[Tile Studio] The previous material profile could not be restored visibly.")
		return {"error": ERR_CANT_CREATE}
	material_profile_replayed.emit(after_json.duplicate(true))
	register_material_profile_undo(
		before_json,
		after_json,
		"Load terrain RGBA splatmap"
	)
	request_render()
	return {
		"error": OK,
		"terrain_bounds": _splatmap_terrain_bounds,
		"face_count": int(bounds_result.get("face_count", 0)),
	}


## Paint every indexed face in the selected projection as one base-coat action.
##
## The action replaces all four RGBA weights only on that visible direction and uses the same
## sparse stroke history as ordinary square-brush base-coat painting.
func paint_entire_terrain_from_splatmap() -> bool:
	if not _ensure_splatmap_projection() or surface_material_paint == null:
		push_error("[Tile Studio] Load an RGBA splatmap before painting the entire terrain.")
		return false
	_end_terrain_material_tile_stroke()
	surface_material_paint.begin_stroke()
	var changed := false
	for target: Dictionary in _splatmap_targets:
		var uid := String(target.get("uid", ""))
		var projection_cell: Vector2i = target.get("projection_cell", Vector2i.ZERO)
		var weights := _splatmap_tile_weights(projection_cell)
		if (
			weights != null
			and surface_material_paint.stamp_splatmap_tile(
				uid,
				weights,
				board.material_blend.splatmap_palette_indices,
				false
			)
		):
			changed = true
	var stroke := surface_material_paint.finish_stroke()
	_register_material_paint_undo(stroke, "Paint entire terrain from RGBA splatmap")
	if changed:
		request_render()
	return true


## Apply one explicit canonical paint-resolution change and retain an exact compressed undo snapshot when global history is available.
##
## Existing images and all derived arrays are prepared before any live state changes, so allocation
## failure leaves the board and its current paint untouched.
func apply_material_paint_resolution(
	texels_per_metre: int,
	maximum_edge_px: int
) -> bool:
	if (
		board == null
		or board.material_blend == null
		or surface_material_paint == null
	):
		push_error("[Tile Studio] Cannot rebuild paint resolution without an active board painter.")
		return false
	var before_json := board.material_blend.to_json().duplicate(true)
	var target_profile := MaterialBlendProfile.new()
	target_profile.from_json(before_json)
	target_profile.paint_texels_per_metre = clampi(
		texels_per_metre,
		MaterialBlendProfile.MIN_TEXELS_PER_METRE,
		MaterialBlendProfile.MAX_TEXELS_PER_METRE
	)
	target_profile.maximum_surface_edge_px = clampi(
		maximum_edge_px,
		MaterialBlendProfile.MIN_SURFACE_EDGE_PX,
		MaterialBlendProfile.MAX_SURFACE_EDGE_PX
	)
	var after_json := target_profile.to_json().duplicate(true)
	if before_json == after_json:
		return true
	var snapshot := surface_material_paint.capture_png_snapshot()
	if int(snapshot.get("error", FAILED)) != OK:
		return false
	var prepared := surface_material_paint.prepare_resolution_rebuild(target_profile)
	if int(prepared.get("error", FAILED)) != OK:
		return false
	if not _commit_material_paint_resolution(after_json, prepared):
		return false
	if _height_undo_redo != null:
		_height_undo_redo.create_action(
			"Rebuild paint mask resolution",
			UndoRedo.MERGE_DISABLE,
			null,
			false
		)
		_height_undo_redo.add_do_method(
			self,
			"_rebuild_material_paint_resolution_from_json",
			after_json.duplicate(true)
		)
		_height_undo_redo.add_undo_method(
			self,
			"_restore_material_paint_resolution_snapshot",
			before_json.duplicate(true),
			snapshot
		)
		_height_undo_redo.commit_action(false)
	return true


## Rebuild current canonical images to one saved profile during resolution redo.
func _rebuild_material_paint_resolution_from_json(profile_json: Dictionary) -> void:
	if surface_material_paint == null:
		push_error("[Tile Studio] Cannot redo paint resolution without its image owner.")
		return
	var target_profile := MaterialBlendProfile.new()
	target_profile.from_json(profile_json)
	var prepared := surface_material_paint.prepare_resolution_rebuild(target_profile)
	if int(prepared.get("error", FAILED)) != OK:
		push_error("[Tile Studio] Paint resolution redo could not prepare its images.")
		return
	_commit_material_paint_resolution(profile_json, prepared)


## Restore exact pre-resize PNG weights and their saved profile during resolution undo.
func _restore_material_paint_resolution_snapshot(
	profile_json: Dictionary,
	snapshot: Dictionary
) -> void:
	if surface_material_paint == null:
		push_error("[Tile Studio] Cannot undo paint resolution without its image owner.")
		return
	var prepared := surface_material_paint.prepare_png_snapshot(snapshot)
	if int(prepared.get("error", FAILED)) != OK:
		push_error("[Tile Studio] Paint resolution undo could not decode its exact snapshot.")
		return
	_commit_material_paint_resolution(profile_json, prepared)


## Commit a prepared image replacement before publishing its matching visible profile.
func _commit_material_paint_resolution(
	profile_json: Dictionary,
	prepared: Dictionary
) -> bool:
	if board == null or board.material_blend == null or surface_material_paint == null:
		push_error("[Tile Studio] Cannot commit paint resolution without an active board.")
		return false
	if not surface_material_paint.commit_prepared_images(prepared):
		return false
	board.material_blend.from_json(profile_json)
	_invalidate_splatmap_projection()
	surface_material_paint.bind_profile(board.material_blend)
	material_profile_replayed.emit(profile_json.duplicate(true))
	request_render()
	return true


## Register an already-applied material-profile edit with optional sparse channel removal.
##
## Procedural rules store only small JSON dictionaries, while a removed painted channel carries
## sparse changed pixels, so undo never snapshots geometry, GLBs, or complete board textures.
func register_material_profile_undo(
	before_json: Dictionary,
	after_json: Dictionary,
	action_name: String,
	merge_mode: int = UndoRedo.MERGE_DISABLE,
	paint_patches: Dictionary = {}
) -> void:
	if _height_undo_redo == null:
		return
	if before_json == after_json and paint_patches.is_empty():
		return
	_height_undo_redo.create_action(action_name, merge_mode, null, false)
	_height_undo_redo.add_do_method(self, "_apply_material_profile_json", after_json.duplicate(true))
	if not paint_patches.is_empty():
		_height_undo_redo.add_do_method(
			self,
			"_apply_material_paint_patch",
			paint_patches.duplicate(true),
			"after"
		)
	_height_undo_redo.add_undo_method(self, "_apply_material_profile_json", before_json.duplicate(true))
	if not paint_patches.is_empty():
		_height_undo_redo.add_undo_method(
			self,
			"_apply_material_paint_patch",
			paint_patches.duplicate(true),
			"before"
		)
	_height_undo_redo.commit_action(false)


## Replay one material profile and its ordered sparse paint edits for board-wide undo or redo.
##
## Undo reverses the patch order because several removed palette entries may have
## touched the same face-local slots during the original atomic operation.
func replay_material_profile_and_patches(
	profile_json: Dictionary,
	paint_patch_steps: Array,
	value_key: String,
	reverse_patches: bool = false
) -> void:
	_apply_material_profile_json(profile_json)
	var ordered_steps := paint_patch_steps.duplicate(true)
	if reverse_patches:
		ordered_steps.reverse()
	for patches_value: Variant in ordered_steps:
		if not patches_value is Dictionary:
			push_error("[Tile Studio] Material removal undo contains an invalid paint patch.")
			continue
		_apply_material_paint_patch(patches_value as Dictionary, value_key)
	request_render()


## Apply one saved material profile during undo or redo through the same scoped refresh planner.
func _apply_material_profile_json(profile_json: Dictionary) -> void:
	if board == null or board.material_blend == null:
		push_error("[Tile Studio] Cannot replay a material profile without an active board.")
		return
	var before_json := board.material_blend.to_json().duplicate(true)
	board.material_blend.from_json(profile_json)
	if not refresh_material_profile_change(before_json):
		push_error("[Tile Studio] Material profile replay could not refresh its visible source projection.")
	material_profile_replayed.emit(profile_json.duplicate(true))


## Save immutable sparse PNG paint sidecars for the active board path.
func save_surface_material_paint(board_path: String) -> Dictionary:
	if surface_material_paint == null:
		return {"error": ERR_UNAVAILABLE}
	var active_uids: Dictionary = {}
	if board != null:
		for surface: SurfacePlacement in board.surfaces:
			active_uids[surface.ensure_uid()] = true
	if terrain_renderer != null:
		for terrain_uid: String in terrain_renderer.paint_uids():
			active_uids[terrain_uid] = true
	return surface_material_paint.save_sidecars(board_path, active_uids)


## Validate paint sidecars without mutating the currently visible board.
func prepare_surface_material_paint(
	board_path: String,
	metadata: Dictionary
) -> Dictionary:
	if surface_material_paint == null:
		return {"error": ERR_UNAVAILABLE}
	return surface_material_paint.prepare_sidecars(board_path, metadata)


## Commit already-validated paint images before the derived batch rebuild.
func commit_prepared_surface_material_paint(prepared: Dictionary) -> bool:
	if surface_material_paint == null:
		return false
	return surface_material_paint.commit_prepared_sidecars(prepared)


## Commit one validated board and its detached resources, then manifest it exactly once.
func commit_prepared_board_load(
	prepared_board: BoardDocument,
	prepared_paint: Dictionary,
	apply_prepared_look: bool = true
) -> bool:
	if board == null or prepared_board == null:
		push_error("[Tile Studio] Cannot commit a board load without both documents.")
		return false
	if int(prepared_paint.get("error", FAILED)) != OK:
		push_error("[Tile Studio] Cannot commit a board load with invalid prepared resources.")
		return false

	# The height field is derived, so a loading board allocates a clean one sized
	# to hold both its placements and its authored terrain, then projects the
	# terrain into it once the document is live.
	var next_world_fields := WorldSurfaceFields.new(false) as MTSWorldSurfaceFields
	var required_rect := Rect2(
		WorldSurfaceFields.DEFAULT_ORIGIN,
		WorldSurfaceFields.DEFAULT_SIZE
	)
	if not prepared_board.is_empty():
		required_rect = _world_surface_field_rect_for_bounds(prepared_board.compute_bounds())
	if not prepared_board.terrain.is_empty():
		required_rect = required_rect.merge(prepared_board.terrain.world_rect())
	var required_resolution := Vector2i(
		ceili(required_rect.size.x * WORLD_HEIGHT_TEXELS_PER_METER) + 1,
		ceili(required_rect.size.y * WORLD_HEIGHT_TEXELS_PER_METER) + 1
	)
	next_world_fields.configure(
		required_rect.position,
		required_rect.size,
		required_resolution,
		false
	)

	var next_surface_paint := (
		_surface_material_paint_script.new()
		as MTSSurfaceMaterialPaint
	)
	next_surface_paint.bind_profile(prepared_board.material_blend)
	if not next_surface_paint.commit_prepared_sidecars(prepared_paint):
		return false
	if not board.commit_prepared_load(prepared_board):
		return false

	if (
		world_surface_fields != null
		and world_surface_fields.fields_changed.is_connected(
			_on_world_surface_fields_changed
		)
	):
		world_surface_fields.fields_changed.disconnect(_on_world_surface_fields_changed)
	if (
		surface_material_paint != null
		and surface_material_paint.batch_texture_changed.is_connected(
			_refresh_material_paint_batch
		)
	):
		surface_material_paint.batch_texture_changed.disconnect(
			_refresh_material_paint_batch
		)
	if (
		surface_material_paint != null
		and surface_material_paint.palette_slots_changed.is_connected(
			_on_material_palette_slots_changed
		)
	):
		surface_material_paint.palette_slots_changed.disconnect(
			_on_material_palette_slots_changed
		)
	world_surface_fields = next_world_fields
	surface_material_paint = next_surface_paint
	world_surface_fields.fields_changed.connect(_on_world_surface_fields_changed)
	surface_material_paint.batch_texture_changed.connect(_refresh_material_paint_batch)
	surface_material_paint.palette_slots_changed.connect(_on_material_palette_slots_changed)

	if material_factory != null:
		material_factory.aesthetics = board.aesthetics
		material_factory.world_fields = world_surface_fields
		material_factory.clear_cache()
		if apply_prepared_look:
			material_factory.apply_global_effects(board.aesthetics)
	_renderer_settings_signature = _current_renderer_settings_signature()

	if apply_prepared_look:
		_defer_reflection_probe_rebuild = true
		apply_lighting_profile()
		_defer_reflection_probe_rebuild = false
		apply_grade()
	_full_rebuild_bounds = AABB() if board.is_empty() else board.compute_bounds()
	_full_rebuild_has_bounds = true
	# The loaded terrain is canonical, so its mesh, collision, projected fields,
	# and terrain-shader grid state are ready before the board is announced.
	_bind_terrain_sculptor()
	refresh_terrain()
	rebuild_board(true)

	_skip_next_look_apply = true
	board.announce_loaded_state(apply_prepared_look)
	_skip_next_look_apply = false
	return true




# --- Live board-wide surface fields ---------------------------------------

## Rebuild every derived artifact after the canonical terrain changed.
##
## This explicit whole-board path is reserved for load/import/clear so the
## visible mesh, GPU material projection, and collision begin from one snapshot.
func refresh_terrain() -> void:
	if board == null:
		return
	_invalidate_splatmap_projection()
	if terrain_renderer != null:
		# Geometry, collision and the paintable 1 m units are rebuilt together from
		# the same faces, so the surface on screen, the surface a token collides
		# with and the surface a brush writes into cannot diverge.
		terrain_renderer.rebuild(
			board.terrain,
			terrain_chunk_cells(),
			surface_material_paint,
			board
		)
		_apply_terrain_material()
	if world_surface_fields != null:
		# Material percentage masks consume the same projected corners used by the
		# visible terrain mesh.
		world_surface_fields.project_terrain(board.terrain)
	_sync_prop_support_offsets()
	_refresh_material_mask_ranges(true)
	terrain_changed.emit()
	request_render()


## Change the authored skirt depth and rebuild only chunks that own boundary shell faces.
##
## The absolute base remains derived from the live lowest terrain point, so this
## control changes shell thickness without creating a second spatial truth.
func set_terrain_skirt_depth(depth_m: float) -> void:
	if board == null or board.terrain == null:
		return
	if not is_finite(depth_m) or depth_m <= 0.0:
		push_error("Terrain skirt depth must be a positive finite distance.")
		return
	if is_equal_approx(board.terrain.skirt_depth_m, depth_m):
		return
	board.terrain.skirt_depth_m = depth_m
	if terrain_renderer != null:
		var changed_chunks := terrain_renderer.refresh_visual_chunks(
			board.terrain,
			terrain_renderer.boundary_chunks(),
			surface_material_paint,
			board
		)
		terrain_renderer.finalize_collision_chunks(changed_chunks)
		_apply_terrain_material_chunks(changed_chunks)
	board.board_changed.emit()
	terrain_changed.emit()
	request_render()


## Apply the board's chosen ground material to the terrain surface.
##
## The terrain deliberately resolves its material through the same factory every
## PNG surface uses, so it inherits the project's one visible material pipeline.
func _apply_terrain_material() -> void:
	if terrain_renderer == null:
		return
	var all_chunks: Array[Vector2i] = []
	for chunk_value: Variant in terrain_renderer.chunks():
		all_chunks.append(chunk_value as Vector2i)
	_apply_terrain_material_chunks(all_chunks)


## Return whether the visible profile explicitly requests the source-map guide.
func _splatmap_source_overlay_requested() -> bool:
	return (
		board != null
		and board.material_blend != null
		and board.material_blend.splatmap_overlay_enabled
	)


## Apply terrain materials only to the visual chunks one scoped edit changed.
func _apply_terrain_material_chunks(chunks_to_apply: Array[Vector2i]) -> void:
	if terrain_renderer == null or material_factory == null or board == null:
		return
	if _splatmap_source_overlay_requested() and not _ensure_splatmap_projection():
		push_error(
			"[Tile Studio] The requested splatmap overlay could not load; current terrain materials were preserved."
		)
		return
	for chunk: Vector2i in chunks_to_apply:
		for surface: Dictionary in terrain_renderer.chunk_surfaces(chunk):
			var material := _terrain_surface_material(chunk, surface)
			if material == null:
				continue
			terrain_renderer.set_chunk_surface_material(
				chunk,
				int(surface["surface_index"]),
				material
			)


## Build one ordinary terrain batch and bind its optional direct shader-decal layer.
##
## The decal is not rasterized or composited into another image. Its original PBR
## textures, authored transform, and Asset UI footprint are bound to the same
## ShaderMaterial that already renders the base coat and painted material layers.
func _terrain_surface_material(
	chunk: Vector2i,
	surface: Dictionary
) -> Material:
	var material := _terrain_chunk_material(
		String(surface["key"]),
		String(surface["asset_id"]),
		surface["is_top"] == true,
		surface["slot_materials"] as PackedInt32Array
	)
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return material
	var shader_decal := surface.get("shader_decal", null) as SurfacePlacement
	if shader_decal == null:
		if not material_factory.configure_shader_decal(shader_material, null, null, {}):
			return null
		return material
	if library == null:
		push_error(
			"[Tile Studio] chunk %s cannot resolve shader decal '%s' without the asset library."
			% [chunk, shader_decal.asset_id]
		)
		return null
	var decal_asset := library.get_asset(shader_decal.asset_id)
	if decal_asset == null or not decal_asset.is_surface():
		push_error(
			"[Tile Studio] chunk %s shader decal asset '%s' is missing or is not a surface asset."
			% [chunk, shader_decal.asset_id]
		)
		return null
	var palette_adjustment: Dictionary = {}
	if shader_decal.match_underlying_palette:
		palette_adjustment = _shader_decal_palette_adjustment(shader_decal)
		if palette_adjustment.is_empty():
			return null
	if not material_factory.configure_shader_decal(
		shader_material,
		shader_decal,
		decal_asset,
		palette_adjustment
	):
		return null
	return material


## Build one terrain chunk surface's ordinary material, bound to that chunk's weights.
##
## Every terrain batch follows this one base-material path. The optional one-shot
## shader decal is subsequently bound as one more layer on this same ShaderMaterial.
func _terrain_chunk_material(
	batch_key: String,
	asset_id: String,
	is_top: bool,
	slot_materials: PackedInt32Array
) -> Material:
	if material_factory == null or board == null:
		return null
	# A face-local Terrain Paint PNG is produced only by authored painting. There
	# is no separate board-wide base texture to override or fill in this result.
	if not asset_id.is_empty():
		if library == null:
			push_error(
				"[Tile Studio] terrain material '%s' cannot resolve without the asset library."
				% asset_id
			)
			return null
		var asset := library.get_asset(asset_id)
		if asset == null:
			push_error(
				"[Tile Studio] terrain material asset '%s' is missing from the library."
				% asset_id
			)
			return null
		var control_texture: Texture2DArray = (
			surface_material_paint.batch_texture(batch_key)
			if surface_material_paint != null
			else null
		)
		var asset_material := material_factory.get_asset_material_for_terrain_batch(
			asset,
			control_texture,
			board.material_blend,
			library,
			_material_world_height_range,
			_material_world_elevation_range,
			slot_materials
		)
		_apply_material_mask_preview_to_material(asset_material as ShaderMaterial)
		return _configure_terrain_grid_material(asset_material, is_top)

	# An unpainted batch keeps a neutral material because the top/side grid
	# classification is presentation state on this exact terrain surface.
	var control_texture: Texture2DArray = (
		surface_material_paint.batch_texture(batch_key)
		if (
			board.material_blend != null
			and board.material_blend.enabled
			and surface_material_paint != null
		)
		else null
	)
	var neutral_material := material_factory.get_material_for_terrain_batch(
		control_texture,
		board.material_blend,
		library,
		_material_world_height_range,
		_material_world_elevation_range,
		slot_materials
	)
	_apply_material_mask_preview_to_material(neutral_material as ShaderMaterial)
	return _configure_terrain_grid_material(neutral_material, is_top)


## Bind grid presentation to one exact terrain batch without creating geometry.
func _configure_terrain_grid_material(material: Material, is_top: bool) -> Material:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return material
	shader_material.set_shader_parameter("terrain_grid_is_top", is_top)
	shader_material.set_shader_parameter(
		"terrain_show_top_grid",
		_terrain_top_grid_visible
	)
	shader_material.set_shader_parameter(
		"terrain_show_side_grid",
		_terrain_side_grid_visible
	)
	var projection_is_top := _splatmap_projection_face() == K.Face.POS_Y
	var source_overlay_enabled := (
		is_top == projection_is_top
		and _splatmap_source_overlay_requested()
		and _splatmap_source_texture != null
		and _splatmap_terrain_bounds.size.x > 0
		and _splatmap_terrain_bounds.size.y > 0
	)
	shader_material.set_shader_parameter(
		"splatmap_source_overlay_enabled",
		source_overlay_enabled
	)
	if source_overlay_enabled:
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_tex",
			_splatmap_source_texture
		)
		# One projected cell is one metre in the selected face plane, so these
		# coordinates are the exact two-dimensional rectangle sampled by the brush.
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_rect",
			Vector4(
				float(_splatmap_terrain_bounds.position.x),
				float(_splatmap_terrain_bounds.position.y),
				float(_splatmap_terrain_bounds.size.x),
				float(_splatmap_terrain_bounds.size.y)
			)
		)
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_channel_mask",
			_splatmap_channel_mask
		)
		shader_material.set_shader_parameter(
			"splatmap_source_overlay_projection",
			int(board.material_blend.splatmap_projection)
		)
	return shader_material


## Return the paint chunk edge in cells the board's profile implies.
##
## Derived from the visible paint resolution so a chunk's ground image is exactly
## as large as the profile allows without being downscaled, which is what keeps
## terrain painting at the authored texel density. The Terrain panel shows it.
func terrain_chunk_cells() -> int:
	return MTSTerrainMeshBuilder.chunk_cells_for(
		board.material_blend if board != null else null
	)


## Return cached renderer counts for the Terrain panel's inexpensive readout.
func terrain_summary_counts() -> Dictionary:
	return terrain_renderer.summary_counts() if terrain_renderer != null else {}


## Return the cached projected terrain height range without scanning every cell.
func terrain_cached_height_range() -> Vector2:
	return (
		world_surface_fields.height_value_range()
		if world_surface_fields != null
		else Vector2.ZERO
	)


## Replace the board's terrain with one imported from a heightfield GLB.
##
## The imported grid is already canonical terrain, so it is adopted whole and
## every sculpt brush and paint tool applies to it immediately. The replacement
## is one undo step, and the previous terrain is restored exactly on undo.
func adopt_imported_terrain(imported: TerrainMesh) -> bool:
	if board == null:
		push_error("[Tile Studio] Cannot import terrain without a bound board.")
		return false
	if imported == null or imported.is_empty():
		push_error("[Tile Studio] Imported terrain is empty.")
		return false
	var previous := board.terrain.duplicate_terrain()
	_apply_terrain_grid(imported.duplicate_terrain())
	if _height_undo_redo == null:
		return true
	_height_undo_redo.create_action(
		"Import terrain heightfield",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	_height_undo_redo.add_do_method(
		self,
		"_apply_terrain_grid",
		imported.duplicate_terrain()
	)
	_height_undo_redo.add_undo_method(
		self,
		"_apply_terrain_grid",
		previous
	)
	# The import is already applied, so committing without execution avoids
	# decoding and rebuilding the same GLB twice.
	_height_undo_redo.commit_action(false)
	return true


## Adopt one complete canonical terrain grid.
func _apply_terrain_grid(grid: TerrainMesh) -> void:
	if board == null or grid == null:
		return
	board.terrain = grid
	_bind_terrain_sculptor()
	refresh_terrain()


## Erase all authored terrain, leaving the board with no encounter footprint.
##
## This is destructive and undoable: the caller registers the history action.
func clear_terrain() -> void:
	if board == null:
		return
	if _terrain_sculptor != null and _terrain_sculptor.is_stroke_active():
		_terrain_sculptor.cancel_stroke()
	_height_sculpting = false
	_height_pending_motion = false
	board.terrain = TerrainMesh.new()
	# Every face is gone, so every material authored on terrain is released with it
	# rather than surviving as metadata that would reappear under new footprint.
	_reconcile_terrain_paint()
	_bind_terrain_sculptor()
	refresh_terrain()


## Reset to a clean field derived only from the currently loaded board's bounds.
func reset_world_heightfield() -> void:
	if world_surface_fields == null:
		return
	world_surface_fields.configure(
		WorldSurfaceFields.DEFAULT_ORIGIN,
		WorldSurfaceFields.DEFAULT_SIZE,
		WorldSurfaceFields.DEFAULT_RESOLUTION,
		false
	)
	_reset_world_surface_field_coverage()


## Reconfigure the editable field coverage for unusually large boards. This is
## an editor/rendering operation, deliberately absent from LLM placement JSON.
func configure_world_surface_fields(origin_xz: Vector2, size_xz: Vector2, resolution: Vector2i = Vector2i(1024, 1024)) -> void:
	if world_surface_fields != null:
		world_surface_fields.configure(origin_xz, size_xz, resolution)
		rebuild_board()


## Refresh material consumers after a world-field texture changes.
##
## World fields are derived rendering data. They never move placement roots,
## collision, selection bounds, or GLB batches.
func _on_world_surface_fields_changed(_kind: String) -> void:
	if material_factory != null:
		material_factory.world_fields = world_surface_fields
		material_factory.apply_global_effects(board.aesthetics if board != null else null)
	request_render()



## Build one stable support identifier from the prop's canonical placement record.
func _prop_contact_id(prop: PropPlacement) -> String:
	if prop == null:
		return ""
	return "%s|%d,%d,%d|%s" % [
		prop.asset_id,
		prop.origin.x,
		prop.origin.y,
		prop.origin.z,
		prop.orientation_key(),
	]


## Stamp grime lines where a terrain wall meets the ground at its base.
##
## Contacts derive from the terrain's own side faces rather than from whether a
## PNG happened to be painted there, so an unpainted wall and a painted wall of
## identical geometry produce identical grime. Only the lowest band of each wall
## is stamped, because that is the band that actually touches the floor.
func _stamp_wall_floor_contacts(upload: bool = true) -> void:
	if world_surface_fields == null or board == null or board.terrain == null:
		return
	if board.terrain.is_empty():
		if upload:
			world_surface_fields.upload_interaction()
		return
	for face: Dictionary in board.terrain.terrain_faces(terrain_chunk_cells()):
		if int(face["kind"]) != TerrainMesh.FaceKind.SIDE:
			continue
		if int(face["band"]) != 0:
			continue
		var cell: Vector2i = face["cell"]
		var grid_face := int(face["face"])
		var grid_cell := Vector3i(
			cell.x,
			TerrainMesh.level_of_height(float(face["bottom_m"])),
			cell.y
		)
		var segment := _wall_contact_segment(grid_cell, grid_face)
		if segment.is_empty():
			continue
		world_surface_fields.stamp_contact_segment(
			segment[0],
			segment[1],
			0.08,
			0.35,
			1.0,
			false,
			"wall|%s" % String(face["paint_uid"])
		)
	if upload:
		world_surface_fields.upload_interaction()


## Convert one occupied wall cell into its exact one-metre world XZ base segment.
func _wall_contact_segment(cell: Vector3i, face: int) -> PackedVector2Array:
	match face:
		K.Face.POS_X:
			var positive_x := float(cell.x + 1)
			return PackedVector2Array([
				Vector2(positive_x, float(cell.z)),
				Vector2(positive_x, float(cell.z + 1)),
			])
		K.Face.NEG_X:
			var negative_x := float(cell.x)
			return PackedVector2Array([
				Vector2(negative_x, float(cell.z)),
				Vector2(negative_x, float(cell.z + 1)),
			])
		K.Face.POS_Z:
			var positive_z := float(cell.z + 1)
			return PackedVector2Array([
				Vector2(float(cell.x), positive_z),
				Vector2(float(cell.x + 1), positive_z),
			])
		_:
			var negative_z := float(cell.z)
			return PackedVector2Array([
				Vector2(float(cell.x), negative_z),
				Vector2(float(cell.x + 1), negative_z),
			])
## Stamp only the visual low-mesh contact grime for one floor prop.
func _stamp_prop_contact(prop: PropPlacement, asset: TileAsset, upload: bool = true) -> void:
	if (
		world_surface_fields == null
		or board == null
		or board.aesthetics == null
		or prop == null
		or asset == null
	):
		return
	# A wall-mounted prop keeps its explicit face attachment and has no floor contact.
	if prop.support == PropPlacement.SUPPORT_WALL:
		return
	var contact_polygons := _prop_contact_polygons(prop, asset)
	if contact_polygons.is_empty():
		push_error(
			"[Tile Studio] '%s' produced no real contact silhouette; contact was not replaced with its grid box."
			% asset.asset_id
		)
		return
	world_surface_fields.stamp_contact_polygons(
		contact_polygons,
		0.35,
		1.0,
		upload,
		_prop_contact_id(prop)
	)



## Return the stable cache key for one prop's visual contact silhouette.
func _prop_contact_cache_key(prop: PropPlacement, asset: TileAsset) -> String:
	return "%s|%s|%s|field=%.6f" % [
		asset.asset_id,
		prop.orientation_key(),
		String(asset.processing.get("generation_id", "")),
		_contact_polygon_quantum_m(),
	]


## Return cached local contact polygons translated to this placement's canonical XZ origin.
func _prop_contact_polygons(prop: PropPlacement, asset: TileAsset) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	if prop == null or asset == null:
		return out
	var cache_key := _prop_contact_cache_key(prop, asset)
	var local_polygons: Array[PackedVector2Array] = []
	var cached_value: Variant = _prop_contact_polygon_cache.get(cache_key, null)
	if cached_value != null:
		for cached_polygon: PackedVector2Array in cached_value:
			local_polygons.append(cached_polygon)
	else:
		local_polygons = _build_local_prop_contact_polygons(prop, asset)
		if not local_polygons.is_empty():
			_prop_contact_polygon_cache[cache_key] = local_polygons

	var translation := Vector2(float(prop.origin.x), float(prop.origin.z))
	for local_polygon: PackedVector2Array in local_polygons:
		var world_polygon := PackedVector2Array()
		for point: Vector2 in local_polygon:
			world_polygon.append(point + translation)
		out.append(world_polygon)
	return out
## Derive the visual base-contact triangles from one oriented source GLB.
func _build_local_prop_contact_polygons(
	prop: PropPlacement,
	asset: TileAsset
) -> Array[PackedVector2Array]:
	var polygons: Array[PackedVector2Array] = []
	if prop == null:
		return polygons
	var source_model := _prop_model_for_asset(asset)
	if source_model == null:
		return polygons
	var prop_pose := prop.orientation_transform(asset) * asset.prop_pose_transform
	var triangles: Array[PackedVector3Array] = []
	_collect_transformed_mesh_triangles(source_model, prop_pose, triangles)
	if triangles.is_empty():
		push_error("[Tile Studio] '%s' source GLB contains no readable mesh triangles." % asset.asset_id)
		return polygons

	var lowest_y := INF
	for triangle: PackedVector3Array in triangles:
		for vertex: Vector3 in triangle:
			lowest_y = minf(lowest_y, vertex.y)
	var quantum_m := _contact_polygon_quantum_m()
	var cutoff_y := lowest_y + PROP_CONTACT_BAND_M
	for triangle: PackedVector3Array in triangles:
		var clipped := _clip_triangle_below_y(triangle, cutoff_y)
		if clipped.size() < 3:
			continue
		for index in range(1, clipped.size() - 1):
			polygons.append(PackedVector2Array([
				Vector2(clipped[0].x, clipped[0].z),
				Vector2(clipped[index].x, clipped[index].z),
				Vector2(clipped[index + 1].x, clipped[index + 1].z),
			]))
	return _compact_contact_polygons(polygons, quantum_m)



## Return the smallest world-space contact texel used to preserve a GLB silhouette.
func _contact_polygon_quantum_m() -> float:
	if world_surface_fields == null:
		return 1.0 / 16.0
	var pixel_counts := world_surface_fields.resolution - Vector2i.ONE
	if pixel_counts.x <= 0 or pixel_counts.y <= 0:
		push_error("[Tile Studio] contact texture resolution must exceed one pixel per axis.")
		return 1.0 / 16.0
	var pixel_size := world_surface_fields.world_size_xz / Vector2(pixel_counts)
	return minf(pixel_size.x, pixel_size.y)


## Merge only sub-texel source triangles into occupied contact cells before caching.
##
## Large triangles stay exact. Tiny triangles contribute their vertices and
## centroid to texel cells, so the union keeps holes and concave boundaries at
## the contact texture's actual resolution without retaining hundreds of
## thousands of distinctions the shader cannot display.
func _compact_contact_polygons(
	polygons: Array[PackedVector2Array],
	quantum_m: float
) -> Array[PackedVector2Array]:
	var compacted: Array[PackedVector2Array] = []
	if quantum_m <= 0.0:
		push_error("[Tile Studio] contact polygon quantum must be positive.")
		return compacted
	var occupied_cells: Dictionary = {}
	for polygon: PackedVector2Array in polygons:
		if polygon.is_empty():
			continue
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		var centroid := Vector2.ZERO
		for point: Vector2 in polygon:
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.y)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.y)
			centroid += point
		if maximum.x - minimum.x > quantum_m or maximum.y - minimum.y > quantum_m:
			compacted.append(polygon)
			continue
		for point: Vector2 in polygon:
			var cell := Vector2i(
				floori(point.x / quantum_m),
				floori(point.y / quantum_m)
			)
			occupied_cells[cell] = true
		centroid /= float(polygon.size())
		occupied_cells[Vector2i(
			floori(centroid.x / quantum_m),
			floori(centroid.y / quantum_m)
		)] = true

	for cell_value: Variant in occupied_cells.keys():
		var cell: Vector2i = cell_value
		var minimum := Vector2(cell) * quantum_m
		var maximum := minimum + Vector2.ONE * quantum_m
		compacted.append(PackedVector2Array([
			minimum,
			Vector2(maximum.x, minimum.y),
			maximum,
			Vector2(minimum.x, maximum.y),
		]))
	return compacted


## Collect triangle vertices after applying the same source hierarchy and canonical prop pose used by rendering.
func _collect_transformed_mesh_triangles(
	node: Node,
	parent_transform: Transform3D,
	out_triangles: Array[PackedVector3Array]
) -> void:
	var current_transform := parent_transform
	var spatial := node as Node3D
	if spatial != null:
		current_transform = parent_transform * spatial.transform

	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		var mesh := mesh_instance.mesh
		for surface_index in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
				push_error(
					"[Tile Studio] contact extraction requires triangle surfaces; '%s' surface %d is unsupported."
					% [mesh_instance.name, surface_index]
				)
				continue
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices_value: Variant = arrays[Mesh.ARRAY_VERTEX]
			if not vertices_value is PackedVector3Array:
				push_error(
					"[Tile Studio] contact extraction found no vertex array on '%s' surface %d."
					% [mesh_instance.name, surface_index]
				)
				continue
			var vertices: PackedVector3Array = vertices_value
			var indices := PackedInt32Array()
			var indices_value: Variant = arrays[Mesh.ARRAY_INDEX]
			if indices_value is PackedInt32Array:
				indices = indices_value
			elif indices_value != null:
				push_error(
					"[Tile Studio] contact extraction found an invalid index array on '%s' surface %d."
					% [mesh_instance.name, surface_index]
				)
				continue
			if indices.is_empty():
				for vertex_index in range(0, vertices.size() - 2, 3):
					out_triangles.append(PackedVector3Array([
						current_transform * vertices[vertex_index],
						current_transform * vertices[vertex_index + 1],
						current_transform * vertices[vertex_index + 2],
					]))
			else:
				for index_offset in range(0, indices.size() - 2, 3):
					out_triangles.append(PackedVector3Array([
						current_transform * vertices[indices[index_offset]],
						current_transform * vertices[indices[index_offset + 1]],
						current_transform * vertices[indices[index_offset + 2]],
					]))

	for child: Node in node.get_children():
		_collect_transformed_mesh_triangles(child, current_transform, out_triangles)


## Clip one triangle against the horizontal contact-band ceiling without inventing geometry.
func _clip_triangle_below_y(triangle: PackedVector3Array, maximum_y: float) -> PackedVector3Array:
	var output := PackedVector3Array()
	if triangle.is_empty():
		return output
	var previous := triangle[triangle.size() - 1]
	var previous_inside := previous.y <= maximum_y
	for current: Vector3 in triangle:
		var current_inside := current.y <= maximum_y
		if current_inside != previous_inside:
			var denominator := current.y - previous.y
			if not is_zero_approx(denominator):
				var ratio := (maximum_y - previous.y) / denominator
				output.append(previous.lerp(current, ratio))
		if current_inside:
			output.append(current)
		previous = current
		previous_inside = current_inside
	return output


## Load and cache the prop GLB explicitly selected by its persistent optimization settings.
##
## TileAsset owns the source-versus-optimized decision; the viewport must not repeat that
## decision or silently substitute the source when a required optimized artifact is missing.
func _prop_model_for_asset(asset: TileAsset) -> Node3D:
	if asset == null:
		push_error("[Tile Studio] Cannot load a prop model for a null asset.")
		return null
	var model_path := asset.prop_model_path()
	if model_path.is_empty():
		push_error("[Tile Studio] '%s' has no selected render GLB on disk." % asset.asset_id)
		return null
	var prop_model: Node3D = _real_mesh_cache.get(model_path, null)
	if prop_model != null:
		return prop_model
	prop_model = GLBImporter.new().load_model(model_path)
	if prop_model == null:
		push_error("[Tile Studio] '%s' selected render GLB failed to load: %s" % [asset.asset_id, model_path])
		return null
	_real_mesh_cache[model_path] = prop_model
	return prop_model


## Return the exact canonical world position of one prop placement.
##
## BoardDocument owns the support calculation. The editor root consumes that answer
## directly so artwork, voxel proxy, physics, picking, and bounds have no second pose.
func _prop_placement_base_position(prop: PropPlacement) -> Vector3:
	if prop == null or board == null:
		return Vector3.ZERO
	return board.prop_world_origin(prop)


## Return the exact canonical world position of one existing prop root.
func _prop_base_position(root: Node3D) -> Vector3:
	if root == null or board == null:
		return Vector3.ZERO
	var prop := root.get_meta("mts_placement", null) as PropPlacement
	if prop == null:
		return root.position
	return _prop_placement_base_position(prop)


## Return the editor slice containing a prop's exact world origin.
##
## This integer is only a visibility and batching address; it never positions the
## prop artwork, collision, proxy, selection bounds, or gameplay obstruction.
func _prop_slice_level(prop: PropPlacement) -> int:
	if prop == null or board == null:
		return 0
	return TerrainMesh.level_of_height(board.prop_world_origin(prop).y)


## Apply one prop's exact canonical floor-or-wall world position.
##
## The placement root carries the complete world translation. TerrainSupport remains
## an identity grouping node for the proxy and physics children and never contributes
## another placement offset.
func _apply_prop_support_offset(root: Node3D) -> bool:
	if root == null:
		return false
	var support_root := root.get_node_or_null("TerrainSupport") as Node3D
	if not is_instance_valid(support_root):
		push_error("[Tile Studio] prop root '%s' has no TerrainSupport child." % root.name)
		return false
	var world_position := _prop_base_position(root)
	if (
		root.position.is_equal_approx(world_position)
		and support_root.position.is_equal_approx(Vector3.ZERO)
	):
		return false
	root.position = world_position
	support_root.position = Vector3.ZERO
	# Slice metadata is an integer lookup derived from the exact physical position.
	root.set_meta("mts_layer_y", TerrainMesh.level_of_height(world_position.y))
	_apply_slice_to_node(root)
	var bounds_value: Variant = root.get_meta("mts_bounds", null)
	if bounds_value is AABB:
		var bounds := bounds_value as AABB
		bounds.position = world_position
		root.set_meta("mts_bounds", bounds)
	return true


## Synchronize every existing prop after terrain or derived contact inputs change.
func _sync_prop_support_offsets() -> void:
	var affected_batch_keys: Dictionary = {}
	for root_value: Variant in _prop_nodes_by_placement_id.values():
		var root := root_value as Node3D
		if not is_instance_valid(root):
			continue
		# Read BEFORE the pose is applied. A batch key embeds the prop's derived slice,
		# so ground that carries a prop across a slice boundary changes which batch its
		# artwork belongs to; both the old and new groups must be resynchronized.
		var previous_keys: Variant = root.get_meta("mts_batch_keys", PackedStringArray())
		if not _apply_prop_support_offset(root):
			continue
		if previous_keys is PackedStringArray:
			for batch_key: String in previous_keys as PackedStringArray:
				affected_batch_keys[batch_key] = true
		var prop := root.get_meta("mts_placement", null) as PropPlacement
		if prop == null:
			continue
		var asset := board.resolve_prop_asset(prop)
		if asset == null:
			continue
		var current_keys := _prop_batch_keys(prop, asset)
		root.set_meta("mts_batch_keys", current_keys)
		for batch_key: String in current_keys:
			affected_batch_keys[batch_key] = true
		# The node now matches the reconciled record, so refresh the snapshot the
		# incremental sync compares against instead of leaving it looking edited.
		root.set_meta("mts_spatial_signature", _placement_spatial_signature(prop))
	if not affected_batch_keys.is_empty():
		_sync_prop_art_batches(affected_batch_keys)



## Return the world bounds occupied by one terrain surface placement.
func _surface_bounds(surface: SurfacePlacement, _asset: TileAsset) -> AABB:
	# Bounds come from the same terrain faces the paint renders on, so selection
	# framing follows sloped and stepped ground instead of a flat rectangle.
	var terrain_points := _placement_collision_points(surface)
	if terrain_points.is_empty():
		return AABB(Vector3(surface.origin), Vector3.ZERO)
	var terrain_bounds := AABB(terrain_points[0], Vector3.ZERO)
	for point_index: int in range(1, terrain_points.size()):
		terrain_bounds = terrain_bounds.expand(terrain_points[point_index])
	return terrain_bounds


## A prop is placed as its OWN real source mesh: no rendered card, no
## decimated shell, no separate shadow stand-in (AGENTS.md 1.2). It renders
## with its own imported GLB materials and casts/receives real Godot shadows
## from its own triangles. Visibility is determined by Godot's normal depth
## buffer. The invisible voxel proxy remains
## collision/navigation-only, where a blocky approximation is the correct
## answer. Every displayed pose is the same source mesh and the same canonical
## voxel set transformed by PropPlacement's explicit cube orientation, so turning,
## flipping, and rolling never create competing asset representations.
## Build one placement-owned spatial root while shared MultiMesh batches render the asset artwork.
func _build_prop_node(
	prop: PropPlacement,
	asset: TileAsset
) -> Node3D:
	var root := Node3D.new()
	var reference_id := prop.asset_id
	root.name = "Prop_%s" % reference_id
	root.set_meta("mts_placement", prop)
	# The root itself owns the complete physical pose shared by every representation.
	var world_origin := board.prop_world_origin(prop)
	root.position = world_origin
	root.set_meta("mts_spatial_signature", _placement_spatial_signature(prop))

	# This identity child groups proxy and physics nodes without changing their pose.
	var support_root := Node3D.new()
	support_root.name = "TerrainSupport"
	root.add_child(support_root)

	var grid_bounds := prop.oriented_bounds(asset)
	var voxels := board.prop_local_voxels(prop)
	var orientation_transform := prop.orientation_transform(asset)
	var generation_id := String(asset.processing.get("generation_id", ""))
	var cache_key := "%s|%s|%s|%.6f" % [
		reference_id,
		prop.orientation_key(),
		generation_id,
		board.movement_collision_min_triangle_share_percent,
	]

	var voxel_mesh: Mesh = _voxel_mesh_cache.get(cache_key, null)
	if voxel_mesh == null:
		voxel_mesh = ProxyMeshBuilder.voxel_mesh(voxels)
		_voxel_mesh_cache[cache_key] = voxel_mesh

	var proxy := MeshInstance3D.new()
	proxy.name = "SpatialProxy"
	proxy.mesh = voxel_mesh
	proxy.visible = false
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	support_root.add_child(proxy)

	# Real GLB artwork is emitted into shared MultiMesh batches from this same
	# exact root transform; collision, proxy, and bounds remain coincident with it.
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.set_meta("mts_placement", prop)
	for voxel in voxels:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3.ONE
		collision.shape = shape
		collision.position = Vector3(voxel) + Vector3(0.5, 0.5, 0.5)
		body.add_child(collision)
	support_root.add_child(body)

	root.set_meta("mts_layer_y", _prop_slice_level(prop))
	root.set_meta("mts_bounds", AABB(
		root.position,
		Vector3(grid_bounds)
	))
	root.set_meta("mts_batch_keys", _prop_batch_keys(prop, asset))
	root.set_meta(
		"mts_contact_id",
		_prop_contact_id(prop)
		if asset != null and prop.support != PropPlacement.SUPPORT_WALL
		else ""
	)
	return root


## Return the exact GLB batch keys touched by one canonical prop placement.
func _prop_batch_keys(prop: PropPlacement, asset: TileAsset) -> PackedStringArray:
	var keys := PackedStringArray()
	if prop == null or asset == null:
		return keys
	var source_model := _prop_model_for_asset(asset)
	if source_model == null:
		return keys
	for component: Dictionary in _prop_mesh_components(source_model):
		var source_mesh := component["mesh_instance"] as MeshInstance3D
		if source_mesh != null:
			keys.append(_prop_batch_key(prop, asset, source_mesh))
	return keys


## Rebuild every derived real-GLB batch after a full board rebuild or recovery.
func _rebuild_prop_art_batches() -> void:
	if prop_art_root == null:
		return
	for child in prop_art_root.get_children():
		prop_art_root.remove_child(child)
		child.queue_free()
	_prop_batches_by_key.clear()
	_sync_prop_art_batches()


## Reconcile only GLB MultiMesh groups touched by the latest prop mutation.
##
## An empty affected set means an intentional full rebuild. Ordinary placement,
## drag, rotation, and deletion pass exact old/new keys so unrelated batches
## retain both their nodes and GPU instance buffers.
func _sync_prop_art_batches(affected_keys: Dictionary = {}) -> void:
	if prop_art_root == null:
		return
	var groups := _collect_prop_batch_groups(affected_keys)
	var keys_to_sync := affected_keys.duplicate()
	if keys_to_sync.is_empty():
		for key_value: Variant in groups.keys():
			keys_to_sync[String(key_value)] = true
		for key_value: Variant in _prop_batches_by_key.keys():
			keys_to_sync[String(key_value)] = true

	for key_value: Variant in keys_to_sync.keys():
		var key := String(key_value)
		var batch := _prop_batches_by_key.get(key, null) as MultiMeshInstance3D
		if not groups.has(key):
			if is_instance_valid(batch):
				prop_art_root.remove_child(batch)
				batch.queue_free()
			_prop_batches_by_key.erase(key)
			continue
		if not is_instance_valid(batch):
			batch = MultiMeshInstance3D.new()
			prop_art_root.add_child(batch)
			_prop_batches_by_key[key] = batch
		_configure_prop_batch(batch, key, groups[key])


## Collect transforms only for requested GLB batches, or every batch for an explicit full rebuild.
##
## Filtering uses batch keys cached on each prop root, so unrelated high-poly GLB
## source hierarchies are never traversed by a local terrain edit.
func _collect_prop_batch_groups(affected_keys: Dictionary = {}) -> Dictionary:
	var groups: Dictionary = {}
	if board == null or library == null:
		return groups

	for prop: PropPlacement in board.props:
		var asset := board.resolve_prop_asset(prop)
		if asset == null:
			continue
		var prop_root := _prop_nodes_by_placement_id.get(prop.get_instance_id(), null) as Node3D
		if not is_instance_valid(prop_root):
			push_error("[Tile Studio] GLB batch has no spatial root for prop '%s'." % asset.asset_id)
			continue
		if not affected_keys.is_empty():
			var cached_keys_value: Variant = prop_root.get_meta(
				"mts_batch_keys",
				PackedStringArray()
			)
			var touches_affected_batch := false
			if cached_keys_value is PackedStringArray:
				for cached_key: String in cached_keys_value as PackedStringArray:
					if affected_keys.has(cached_key):
						touches_affected_batch = true
						break
			if not touches_affected_batch:
				continue
		var source_model := _prop_model_for_asset(asset)
		if source_model == null:
			continue
		# Artwork begins at the same exact root transform as proxy and collision.
		var placement_transform := (
			prop_root.transform
			* prop.orientation_transform(asset)
			* asset.prop_pose_transform
		)
		for component: Dictionary in _prop_mesh_components(source_model):
			var source_mesh := component["mesh_instance"] as MeshInstance3D
			var key := _prop_batch_key(prop, asset, source_mesh)
			if not affected_keys.is_empty() and not affected_keys.has(key):
				continue
			var render_mesh := _prop_render_mesh(source_mesh)
			if render_mesh == null:
				continue
			if not groups.has(key):
				groups[key] = {
					"asset": asset,
					"mesh": render_mesh,
					"layer_y": _prop_slice_level(prop),
					"chunk_x": floori(float(prop.origin.x) / float(SURFACE_BATCH_CHUNK_SIZE_M)),
					"chunk_z": floori(float(prop.origin.z) / float(SURFACE_BATCH_CHUNK_SIZE_M)),
					"transforms": [],
				}
			var group: Dictionary = groups[key]
			var transforms: Array = group["transforms"]
			var component_transform: Transform3D = component["transform"]
			transforms.append(placement_transform * component_transform)

	return groups


## Gather static mesh components with transforms relative to the imported GLB root.
func _prop_mesh_components(source_model: Node3D) -> Array[Dictionary]:
	var components: Array[Dictionary] = []
	if source_model == null:
		return components
	var cache_key := source_model.get_instance_id()
	if _prop_mesh_components_cache.has(cache_key):
		var cached_components: Array[Dictionary] = _prop_mesh_components_cache[cache_key]
		return cached_components
	for child in source_model.get_children():
		_append_prop_mesh_components(
			child,
			Transform3D.IDENTITY,
			source_model.visible,
			components
		)
	_prop_mesh_components_cache[cache_key] = components
	return components


## Preserve nested mesh transforms and visibility while rejecting animated data a static MultiMesh cannot represent.
func _append_prop_mesh_components(
	node: Node,
	parent_transform: Transform3D,
	parent_visible: bool,
	components: Array[Dictionary]
) -> void:
	var node_transform := parent_transform
	var node_visible := parent_visible
	var node_3d := node as Node3D
	if node_3d != null:
		node_transform = parent_transform * node_3d.transform
		node_visible = parent_visible and node_3d.visible

	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and node_visible:
		if mesh_instance.skin != null:
			push_error(
				"[Tile Studio] GLB mesh '%s' uses skinning and cannot be rendered as a static MultiMesh prop."
				% mesh_instance.name
			)
		elif mesh_instance.mesh != null:
			components.append({
				"mesh_instance": mesh_instance,
				"transform": node_transform,
			})

	for child in node.get_children():
		_append_prop_mesh_components(child, node_transform, node_visible, components)


## Return the derived material-preserving mesh used by one GLB component batch.
func _prop_render_mesh(source: MeshInstance3D) -> Mesh:
	if source == null or source.mesh == null:
		return null
	var cache_key := "%d|%d|cull=%s" % [
		source.get_instance_id(),
		source.mesh.get_instance_id(),
		str(_backface_culling_enabled()),
	]
	var cached := _prop_render_mesh_cache.get(cache_key, null) as Mesh
	if cached != null:
		return cached

	var render_mesh := source.mesh.duplicate(false) as Mesh
	if render_mesh == null:
		push_error("[Tile Studio] Could not duplicate GLB mesh '%s' for MultiMesh rendering." % source.name)
		return null
	for surface_index in render_mesh.get_surface_count():
		render_mesh.surface_set_material(
			surface_index,
			_prop_batch_material(source, surface_index)
		)
	_prop_render_mesh_cache[cache_key] = render_mesh
	return render_mesh


## Return the exact authored material for one surface, optionally with the user-selected culling mode.
func _prop_batch_material(source: MeshInstance3D, surface_index: int) -> Material:
	var material: Material = source.material_override
	if material == null:
		material = source.get_surface_override_material(surface_index)
	if material == null and source.mesh != null:
		material = source.mesh.surface_get_material(surface_index)
	if material == null or not _backface_culling_enabled():
		return material

	var base_material := material as BaseMaterial3D
	if base_material == null:
		push_warning(
			"[Tile Studio] Back-face culling cannot override custom GLB material '%s' on '%s'."
			% [material.resource_path, source.name]
		)
		return material
	var culled_material := base_material.duplicate() as BaseMaterial3D
	if culled_material == null:
		push_error(
			"[Tile Studio] Failed to duplicate GLB material '%s' on '%s'."
			% [material.resource_path, source.name]
		)
		return null
	culled_material.cull_mode = BaseMaterial3D.CULL_BACK
	return culled_material


## Return the stable component batch key for one asset, Y layer, horizontal cull chunk, and source component.
func _prop_batch_key(prop: PropPlacement, asset: TileAsset, source_mesh: MeshInstance3D) -> String:
	var chunk_x := floori(float(prop.origin.x) / float(SURFACE_BATCH_CHUNK_SIZE_M))
	var chunk_z := floori(float(prop.origin.z) / float(SURFACE_BATCH_CHUNK_SIZE_M))
	var model_path := asset.prop_model_path()
	if model_path.is_empty():
		return ""
	return "%s|component=%d|y=%d|chunk=%d,%d" % [
		model_path,
		source_mesh.get_instance_id(),
		_prop_slice_level(prop),
		chunk_x,
		chunk_z,
	]


## Configure one reusable MultiMesh node with the canonical transforms of one GLB component group.
func _configure_prop_batch(
	batch: MultiMeshInstance3D,
	key: String,
	group: Dictionary
) -> void:
	var mesh := group["mesh"] as Mesh
	var transforms: Array = group["transforms"]
	var multimesh := batch.multimesh
	if multimesh == null:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		batch.multimesh = multimesh
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index] as Transform3D)

	var asset := group["asset"] as TileAsset
	batch.name = "PropBatch_%s_y%d_c%d_%d_m%d" % [
		asset.asset_id,
		int(group["layer_y"]),
		int(group["chunk_x"]),
		int(group["chunk_z"]),
		mesh.get_instance_id(),
	]
	batch.material_override = null
	batch.cast_shadow = _visible_shadow_cast_setting()
	batch.extra_cull_margin = 8.0
	batch.set_meta("mts_batch_key", key)
	batch.set_meta("mts_asset_id", asset.asset_id)
	batch.set_meta("mts_layer_y", int(group["layer_y"]))
	_apply_slice_to_node(batch)


## Apply `setting` to every MeshInstance3D/GeometryInstance3D in `node`'s tree.
##
## A duplicated GLTF scene is a hierarchy of many mesh nodes, not one -- unlike
## the single-quad Art card, cast_shadow has to be set on each of them for the
## whole prop to actually cast.
func _set_cast_shadow_recursive(node: Node, setting: int) -> void:
	var instance := node as GeometryInstance3D
	if instance != null:
		instance.cast_shadow = setting
	for child in node.get_children():
		_set_cast_shadow_recursive(child, setting)


## Return whether the active board explicitly enables back-face culling.
func _backface_culling_enabled() -> bool:
	return (
		board != null
		and board.aesthetics != null
		and board.aesthetics.backface_culling_enabled
	)


## Return the visible-geometry shadow mode selected in the Rendering window.
func _visible_shadow_cast_setting() -> int:
	if (
		board != null
		and board.aesthetics != null
		and board.aesthetics.one_sided_shadows_enabled
	):
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED


## Return a compact signature for renderer options that require live geometry updates.
func _current_renderer_settings_signature() -> String:
	if board == null or board.aesthetics == null:
		return ""
	return "%s|%s" % [
		str(board.aesthetics.backface_culling_enabled),
		str(board.aesthetics.one_sided_shadows_enabled),
	]


## Apply the visible renderer toggles without rebuilding placement nodes or batches.
func _apply_renderer_settings_to_existing_geometry() -> void:
	# Terrain visuals own their own cast-shadow state through the terrain
	# renderer, so only the GLB batches need reconciling here.
	# GLB batch meshes are derived from the original per-surface materials,
	# so a renderer-toggle rebuild is required to replace the material copies.
	_sync_prop_art_batches()
	request_render()


## Apply back-face culling to compatible materials in one duplicated GLB hierarchy.
func _set_backface_culling_recursive(node: Node, enabled: bool) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		_set_mesh_backface_culling(mesh_instance, enabled)
	for child in node.get_children():
		_set_backface_culling_recursive(child, enabled)


## Derive per-instance GLB material overrides while preserving exact authored materials for disable.
func _set_mesh_backface_culling(mesh_instance: MeshInstance3D, enabled: bool) -> void:
	if mesh_instance.mesh == null:
		return

	var state_value: Variant = (
		mesh_instance.get_meta(ORIGINAL_MATERIAL_STATE_META)
		if mesh_instance.has_meta(ORIGINAL_MATERIAL_STATE_META)
		else null
	)
	var state: Dictionary
	if state_value is Dictionary:
		state = state_value
	else:
		var surface_overrides: Array = []
		for surface_index in mesh_instance.mesh.get_surface_count():
			surface_overrides.append(
				mesh_instance.get_surface_override_material(surface_index)
			)
		state = {
			"material_override": mesh_instance.material_override,
			"surface_overrides": surface_overrides,
		}
		mesh_instance.set_meta(ORIGINAL_MATERIAL_STATE_META, state)

	var original_override := state.get("material_override", null) as Material
	var original_surface_overrides: Array = state.get("surface_overrides", [])
	mesh_instance.material_override = original_override
	for surface_index in mini(
		mesh_instance.mesh.get_surface_count(),
		original_surface_overrides.size()
	):
		mesh_instance.set_surface_override_material(
			surface_index,
			original_surface_overrides[surface_index] as Material
		)

	if not enabled:
		return

	if original_override != null:
		var override_base := original_override as BaseMaterial3D
		if override_base == null:
			push_warning(
				"[Tile Studio] Back-face culling cannot override custom material '%s' on '%s'."
				% [original_override.resource_path, mesh_instance.name]
			)
			return
		var culled_override := override_base.duplicate() as BaseMaterial3D
		if culled_override == null:
			push_error("[Tile Studio] Failed to duplicate GLB material override on '%s'." % mesh_instance.name)
			return
		culled_override.cull_mode = BaseMaterial3D.CULL_BACK
		mesh_instance.material_override = culled_override
		return

	for surface_index in mesh_instance.mesh.get_surface_count():
		var source_material: Material = null
		if surface_index < original_surface_overrides.size():
			source_material = original_surface_overrides[surface_index] as Material
		if source_material == null:
			source_material = mesh_instance.mesh.surface_get_material(surface_index)
		if source_material == null:
			continue
		var source_base := source_material as BaseMaterial3D
		if source_base == null:
			push_warning(
				"[Tile Studio] Back-face culling cannot override custom material '%s' on '%s' surface %d."
				% [source_material.resource_path, mesh_instance.name, surface_index]
			)
			continue
		var culled_surface := source_base.duplicate() as BaseMaterial3D
		if culled_surface == null:
			push_error(
				"[Tile Studio] Failed to duplicate GLB material on '%s' surface %d."
				% [mesh_instance.name, surface_index]
			)
			continue
		culled_surface.cull_mode = BaseMaterial3D.CULL_BACK
		mesh_instance.set_surface_override_material(surface_index, culled_surface)


## Re-read the brush asset and redraw the painting overlay in place.
##
## The brush holds a live TileAsset reference, so an inspector edit (size, face,
## facing, anchor) changes the data the overlay is built from without the
## controller ever being told. Called by the plugin after any such edit, this is
## what makes a resize or an axis change show up under the cursor immediately
## instead of on the next brush reselect.
func refresh_brush_preview() -> void:
	if placement == null:
		return
	placement.refresh_brush()
	# The overlay is only repositioned on mouse motion, so a change made while
	# the cursor is parked over the board would otherwise not move until the
	# user jiggles the mouse. Re-picking under the current cursor redraws it now.
	if camera != null and is_visible_in_tree():
		placement.update_hover(camera, _last_mouse)
	_emit_status()
	request_render()


## Editor-only Y visibility (spec 7). Hides nodes; never deletes data.
## Apply the editor's Y visibility rule to logical surfaces, batched art, and
## real GLB props without deleting any authored placements.
func _apply_slice() -> void:
	for root: Node3D in [
		surfaces_root,
		surface_art_root,
		props_root,
		prop_art_root,
		gameplay_markers_root,
		particle_effects_root,
	]:
		if root == null:
			continue
		for child in root.get_children():
			var node := child as Node3D
			if node != null:
				_apply_slice_to_node(node)
	request_render()


## Apply the current Y-slice rule to one newly created or existing visual node.
func _apply_slice_to_node(node: Node3D) -> void:
	var layer: int = node.get_meta("mts_layer_y", 0)
	match slice_mode:
		K.SliceMode.ALL:
			node.visible = true
		K.SliceMode.CURRENT_AND_BELOW:
			node.visible = layer <= current_y
		K.SliceMode.CURRENT_ONLY:
			node.visible = layer == current_y


## Activate movement-cell authoring and its temporary shaded grid overlay.
##
## Closing the panel disables this mode, ensuring the shading is editor chrome
## rather than hidden board rendering state.
func set_movement_grid_mode(active: bool) -> void:
	_movement_grid_active = active
	set_occupancy_mode(
		OccupancyOverlay.Mode.MOVEMENT_GRID
		if active
		else OccupancyOverlay.Mode.OFF
	)
	if active:
		_update_movement_grid_hover(_last_mouse)


## Return whether the movement panel currently owns cell input.
func movement_grid_mode_active() -> bool:
	return _movement_grid_active


## Select the next movement-cell action without mutating the board.
func set_movement_grid_tool(tool: int) -> void:
	_movement_grid_tool = clampi(
		tool,
		MovementGridTool.BLOCK,
		MovementGridTool.CLEAR_EFFECT
	)
	if _movement_grid_active:
		_update_movement_grid_hover(_last_mouse)


## Stage the plain ground-effect label used by the Set Effect action.
func set_movement_ground_effect_label(label: String) -> void:
	_movement_ground_effect_label = label.strip_edges()
	if _movement_grid_active:
		_update_movement_grid_hover(_last_mouse)


## Validate and atomically apply the board-wide GLB collision threshold.
func apply_movement_collision_threshold(threshold_percent: float) -> Dictionary:
	if board == null:
		return {"valid": false, "errors": PackedStringArray(["No board is bound."])}
	var report := board.movement_collision_filter_report(threshold_percent)
	if not bool(report.get("valid", false)):
		status_changed.emit("Movement collision filter was not applied.")
		return report
	var before := board.movement_collision_min_triangle_share_percent
	var after := float(report["threshold_percent"])
	if is_equal_approx(before, after):
		return report
	if _height_undo_redo == null:
		_apply_movement_collision_threshold(after)
		return report
	_height_undo_redo.create_action(
		"Set global movement collision filter",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	_height_undo_redo.add_do_method(
		self,
		"_apply_movement_collision_threshold",
		after
	)
	_height_undo_redo.add_undo_method(
		self,
		"_apply_movement_collision_threshold",
		before
	)
	_height_undo_redo.commit_action()
	return report


## Apply one collision threshold during direct editing, undo, or redo.
func _apply_movement_collision_threshold(threshold_percent: float) -> void:
	if board == null:
		return
	var report := board.set_movement_collision_min_triangle_share_percent(
		threshold_percent
	)
	if not bool(report.get("valid", false)):
		push_error("[Tile Studio] movement collision threshold replay failed.")
		return
	refresh_movement_grid_collision()


## Rebuild only prop spatial roots and the movement overlay after collision filtering.
##
## Terrain meshes, surface materials, lighting, and unrelated assets remain
## untouched; every placed prop root is marked stale because the rule is global.
func refresh_movement_grid_collision() -> void:
	if board == null:
		return
	board.rebuild_indexes()
	_voxel_mesh_cache.clear()
	for prop: PropPlacement in board.props:
		var node := _prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if is_instance_valid(node):
			node.set_meta("mts_spatial_signature", "stale-movement-collision")
	_sync_board_incremental(PlacementController.BoardMutation.PROPS)
	if occupancy_overlay != null:
		occupancy_overlay.rebuild()
	_emit_status()
	request_render()


## Consume movement-grid pointer input before ordinary placement tools.
func _handle_movement_grid_input(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		if camera != null and camera.is_panning():
			return false
		var motion := event as InputEventMouseMotion
		_last_mouse = motion.position
		_update_movement_grid_hover(motion.position)
		return true
	if not event is InputEventMouseButton:
		return false
	var button := event as InputEventMouseButton
	if button.button_index in [
		MOUSE_BUTTON_MIDDLE,
		MOUSE_BUTTON_WHEEL_UP,
		MOUSE_BUTTON_WHEEL_DOWN,
	]:
		return false
	if button.button_index == MOUSE_BUTTON_LEFT:
		_last_mouse = button.position
		_update_movement_grid_hover(button.position)
		if button.pressed:
			_commit_movement_grid_cell(button.position)
		return true
	if button.button_index == MOUSE_BUTTON_RIGHT:
		return true
	return false


## Pick one top terrain cell through the renderer's canonical triangle data.
func _movement_grid_hit(mouse_position: Vector2) -> Dictionary:
	if (
		camera == null
		or terrain_renderer == null
		or board == null
		or board.terrain.is_empty()
		or not Rect2(Vector2.ZERO, size).has_point(mouse_position)
	):
		return {}
	var pick := terrain_renderer.pick_face(
		camera.project_ray_origin(mouse_position),
		camera.project_ray_normal(mouse_position)
	)
	if pick.is_empty() or bool(pick.get("is_wall", false)):
		return {}
	var face := pick["face"] as Dictionary
	var grid_cell: Vector3i = face["grid_cell"]
	var cell := Vector2i(grid_cell.x, grid_cell.z)
	if not board.movement_cell_exists(cell):
		return {}
	return {
		"cell": cell,
		"point": pick["point"],
	}


## Publish movement state for the exact terrain cell under the pointer.
func _update_movement_grid_hover(mouse_position: Vector2) -> void:
	var hit := _movement_grid_hit(mouse_position)
	if hit.is_empty():
		hover_changed.emit(Vector3i.ZERO, false, "Move over a terrain top cell.")
		request_render()
		return
	var cell: Vector2i = hit["cell"]
	var state := board.movement_cell_state(cell)
	var reason := (
		"Movement cell (%d, %d): %s"
		% [
			cell.x,
			cell.y,
			"manually unwalkable"
			if bool(state.get("unwalkable", false))
			else "automatic walkability",
		]
	)
	var effect := String(state.get("ground_effect", ""))
	if not effect.is_empty():
		reason += " | effect: %s" % effect
	hover_changed.emit(
		Vector3i(
			cell.x,
			TerrainMesh.level_of_height(float((hit["point"] as Vector3).y)),
			cell.y
		),
		true,
		reason
	)
	request_render()


## Turn the current movement action into one undoable canonical cell edit.
func _commit_movement_grid_cell(mouse_position: Vector2) -> void:
	var hit := _movement_grid_hit(mouse_position)
	if hit.is_empty():
		status_changed.emit("Movement Grid: click a terrain top cell.")
		return
	var cell: Vector2i = hit["cell"]
	var before := board.movement_cell_state(cell)
	var after := before.duplicate(true)
	match _movement_grid_tool:
		MovementGridTool.BLOCK:
			after["unwalkable"] = true
		MovementGridTool.RESTORE_AUTO:
			after["unwalkable"] = false
		MovementGridTool.SET_EFFECT:
			if _movement_ground_effect_label.is_empty():
				status_changed.emit("Movement Grid: enter a ground-effect label first.")
				return
			after["ground_effect"] = _movement_ground_effect_label
		MovementGridTool.CLEAR_EFFECT:
			after["ground_effect"] = ""
	if before == after:
		movement_grid_cell_changed.emit(cell, before)
		return
	if _height_undo_redo == null:
		_apply_movement_cell_state(cell, after)
		return
	_height_undo_redo.create_action(
		"Edit movement cell",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	_height_undo_redo.add_do_method(
		self,
		"_apply_movement_cell_state",
		cell,
		after
	)
	_height_undo_redo.add_undo_method(
		self,
		"_apply_movement_cell_state",
		cell,
		before
	)
	_height_undo_redo.commit_action()


## Replay one movement cell from canonical state during direct editing, undo, or redo.
func _apply_movement_cell_state(cell: Vector2i, state: Dictionary) -> void:
	if board == null:
		return
	board.apply_movement_cell_state(cell, state)
	if occupancy_overlay != null:
		occupancy_overlay.rebuild()
	movement_grid_cell_changed.emit(cell, board.movement_cell_state(cell))
	_update_movement_grid_hover(_last_mouse)
	request_render()


## Show the selected collision or movement diagnostic over live board artwork.
func set_occupancy_mode(p_mode: int) -> void:
	if occupancy_overlay == null:
		return
	occupancy_overlay.set_mode(p_mode)

	if surfaces_root != null:
		surfaces_root.visible = true
	if surface_art_root != null:
		surface_art_root.visible = true
	if props_root != null:
		props_root.visible = true
	if prop_art_root != null:
		prop_art_root.visible = true
	_emit_status()
	request_render()


func occupancy_mode_name() -> String:
	return occupancy_overlay.mode_name() if occupancy_overlay != null else "OFF"


## Synchronize slice visibility with structural-floor picking before applying
## the new visibility state, so hidden floors cannot steal prop clicks.
func set_slice_mode(mode: int) -> void:
	slice_mode = mode
	if placement != null:
		placement.slice_mode = mode
	_apply_slice()
	_emit_status()
	request_render()


## Enable or disable the editor-only uniform light used while painting obscured faces.
##
## Reapplying both lighting and grade makes the switch reversible from the board's
## canonical profiles without storing a backup copy or mutating authored data.
func set_painting_light_override_enabled(enabled: bool) -> void:
	if _painting_light_override_enabled == enabled:
		return
	_painting_light_override_enabled = enabled
	apply_lighting_profile()
	apply_grade()
	request_render()


## Apply neutral ambient illumination and disable every effect that can darken a face.
##
## Ambient light has no direction, so all building sides remain readable without a
## camera-relative light or a hidden azimuth correction. Direct lights are hidden,
## which guarantees this comfort preview cannot cast dynamic shadows.
func _apply_painting_light_override() -> void:
	if world_environment != null and world_environment.environment != null:
		var env := world_environment.environment
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color.WHITE
		env.ambient_light_energy = 1.0
		env.ambient_light_sky_contribution = 0.0
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
		env.sdfgi_enabled = false
		env.ssao_enabled = false
		env.ssil_enabled = false
		env.ssr_enabled = false
		env.glow_enabled = false
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.tonemap_exposure = 1.0
		env.adjustment_enabled = false
	if key_light != null:
		key_light.visible = false
	if lights_root != null:
		lights_root.visible = false
	if reflection_probe != null:
		reflection_probe.visible = false


## Apply the board's lighting profile to the live rig.
##
## Called whenever the board emits look_changed, which the Look panel triggers on
## every knob move, so the viewport is always showing exactly what is saved.
## The temporary painting override is editor comfort state; every authored value
## remains on the document and is reapplied verbatim when that override is off.
func apply_lighting_profile() -> void:
	var profile := _profile()
	if profile == null:
		return

	# The authored-value mapping lives on LightingProfile so the editor preview and the
	# runtime game apply identical lighting from one place.
	if world_environment != null:
		profile.apply_to_environment(world_environment.environment)
	profile.apply_to_sun(key_light)

	if _painting_light_override_enabled:
		_apply_painting_light_override()
		_sync_light_handles_from_profile()
		return

	if not _defer_reflection_probe_rebuild:
		_rebuild_reflection_probe(profile)
	_rebuild_local_lights(profile)
	if lights_root != null:
		lights_root.visible = true
	if reflection_probe != null:
		reflection_probe.visible = true
	_sync_light_handles_from_profile()

## Keep one UPDATE_ONCE ReflectionProbe synchronized to exact board bounds.
##
## Ordinary mutations update the existing probe in place. Recreating the node
## would force an unrelated reflection capture and SceneTree churn on every drag.
func _rebuild_reflection_probe(profile: LightingProfile) -> void:
	var should_exist := (
		profile != null
		and profile.reflection_probe_enabled
		and board != null
		and not board.is_empty()
	)
	if not should_exist:
		if reflection_probe != null:
			if reflection_probe.get_parent() != null:
				reflection_probe.get_parent().remove_child(reflection_probe)
			reflection_probe.queue_free()
			reflection_probe = null
		if (
			profile != null
			and profile.reflection_probe_enabled
			and board != null
			and board.is_empty()
		):
			push_warning(
				"[Tile Studio] Reflection probe is enabled but the current board has no geometry to bound."
			)
		return

	var bounds := _board_bounds()
	var padding := maxf(0.0, profile.reflection_probe_padding_m)
	var probe_size := bounds.size + Vector3.ONE * padding * 2.0
	probe_size.x = maxf(probe_size.x, 0.1)
	probe_size.y = maxf(probe_size.y, 0.1)
	probe_size.z = maxf(probe_size.z, 0.1)
	if reflection_probe == null:
		reflection_probe = ReflectionProbe.new()
		reflection_probe.name = "BoardReflectionProbe"
		reflection_probe.update_mode = ReflectionProbe.UPDATE_ONCE
		world_root.add_child(reflection_probe)
	reflection_probe.position = bounds.get_center()
	reflection_probe.size = probe_size
	reflection_probe.intensity = profile.reflection_probe_intensity
	reflection_probe.box_projection = profile.reflection_probe_box_projection
	reflection_probe.enable_shadows = profile.reflection_probe_shadows


## Local lights are rebuilt from the profile so node type and projector cannot leave stale state.
##
## Ported from the Blackledger runtime, which fed up to eight lights into a
## shader uniform array. Here they become real OmniLight3D nodes, so they light
## props and surfaces through the same path as the key light and cast real
## shadows. Rebuilding rather than diffing keeps this honest: at eight lights the
## cost is nil, and there is no stale-node class of bug.
func _rebuild_local_lights(profile: LightingProfile) -> void:
	if lights_root == null:
		return
	for child in lights_root.get_children():
		lights_root.remove_child(child)
		child.queue_free()
	# LightingProfile builds the nodes so the editor and the runtime game produce
	# identical lights from one authored entry list.
	for light: Light3D in profile.build_local_lights():
		lights_root.add_child(light)


## Show or remove transient surface anchors without changing any authored light value.
func set_light_handles_visible(visible: bool) -> void:
	if not visible and _light_drag_mode != LocalLightDragMode.NONE:
		_finish_light_handle_drag()
	if not visible:
		_local_light_placement_pending = false
	_light_handles_visible = visible
	if light_handles_root == null:
		return
	light_handles_root.visible = visible
	if visible:
		_sync_light_handles_from_profile()
	else:
		_clear_light_handles()
	request_render()


## Enter a one-click mode that creates the next light on actual level geometry.
func begin_local_light_placement() -> void:
	if not _light_handles_visible or board == null:
		push_error("[Tile Studio] Open Lighting before placing a local light.")
		return
	if board.lighting.lights.size() >= LightingProfile.MAX_LIGHTS:
		status_changed.emit(
			"This rig supports at most %d local lights." % LightingProfile.MAX_LIGHTS
		)
		return
	if _light_drag_mode != LocalLightDragMode.NONE:
		_finish_light_handle_drag()
	_local_light_placement_pending = true
	status_changed.emit(
		"Click authored terrain geometry to anchor the new light; right-click cancels."
	)


## Select one authored local light and update only its temporary handle appearance.
func select_local_light_handle(index: int) -> void:
	var light_count: int = board.lighting.lights.size() if board != null else 0
	_selected_light_handle = clampi(index, 0, light_count - 1) if light_count > 0 else -1
	_refresh_light_handle_appearance()
	request_render()


## Synchronize every temporary handle from the exact profile anchor, height, colour, and enabled state.
func _sync_light_handles_from_profile() -> void:
	if not _light_handles_visible or light_handles_root == null or board == null:
		return
	var lights: Array[Dictionary] = board.lighting.lights
	if _light_handle_nodes.size() != lights.size():
		_clear_light_handles()
		for light_index: int in lights.size():
			_light_handle_nodes.append(_create_light_handle(light_index))
	for light_index: int in lights.size():
		_update_light_handle_transform(light_index)
	_refresh_light_handle_appearance()
	request_render()


## Build one x-ray surface anchor, emitter glob, and visible height stem.
func _create_light_handle(light_index: int) -> Node3D:
	var handle := Node3D.new()
	handle.name = "LocalLightHandle_%d" % light_index
	handle.set_meta(LIGHT_INDEX_META, light_index)
	light_handles_root.add_child(handle)

	var surface_mesh := SphereMesh.new()
	surface_mesh.radius = LIGHT_SURFACE_ANCHOR_RADIUS_M
	surface_mesh.height = LIGHT_SURFACE_ANCHOR_RADIUS_M * 2.0
	surface_mesh.radial_segments = 12
	surface_mesh.rings = 6
	var surface_anchor := MeshInstance3D.new()
	surface_anchor.name = "SurfaceAnchor"
	surface_anchor.mesh = surface_mesh
	surface_anchor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface_anchor.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(surface_anchor)

	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = LIGHT_STEM_RADIUS_M
	stem_mesh.bottom_radius = LIGHT_STEM_RADIUS_M
	stem_mesh.height = 0.01
	stem_mesh.radial_segments = 8
	var stem := MeshInstance3D.new()
	stem.name = "HeightStem"
	stem.mesh = stem_mesh
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stem.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(stem)

	var core_mesh := SphereMesh.new()
	core_mesh.radius = LIGHT_HANDLE_RADIUS_M
	core_mesh.height = LIGHT_HANDLE_RADIUS_M * 2.0
	core_mesh.radial_segments = 16
	core_mesh.rings = 8
	var core := MeshInstance3D.new()
	core.name = "Core"
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(core)

	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = LIGHT_HANDLE_RADIUS_M * 1.55
	halo_mesh.height = LIGHT_HANDLE_RADIUS_M * 3.1
	halo_mesh.radial_segments = 16
	halo_mesh.rings = 8
	var halo := MeshInstance3D.new()
	halo.name = "Halo"
	halo.mesh = halo_mesh
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(halo)

	return handle


## Position every derived handle part from the canonical surface anchor and height offset.
func _update_light_handle_transform(light_index: int) -> void:
	if board == null or light_index < 0 or light_index >= board.lighting.lights.size():
		return
	if light_index >= _light_handle_nodes.size():
		return
	var entry: Dictionary = board.lighting.lights[light_index]
	var surface_position: Vector3 = entry.get("surface_position", Vector3.ZERO)
	var height_offset := _authored_light_height_offset(light_index)
	var emitter_local := Vector3.UP * height_offset
	var handle: Node3D = _light_handle_nodes[light_index]
	handle.position = surface_position

	var core := handle.get_node_or_null("Core") as MeshInstance3D
	var halo := handle.get_node_or_null("Halo") as MeshInstance3D
	if core != null:
		core.position = emitter_local
	if halo != null:
		halo.position = emitter_local

	var stem := handle.get_node_or_null("HeightStem") as MeshInstance3D
	if stem != null:
		stem.position = Vector3.UP * height_offset * 0.5
		var stem_mesh := stem.mesh as CylinderMesh
		if stem_mesh != null:
			stem_mesh.height = maxf(height_offset, 0.01)


## Replace derived handle materials so selection and enabled state remain visually explicit.
func _refresh_light_handle_appearance() -> void:
	if board == null:
		return
	var lights: Array[Dictionary] = board.lighting.lights
	for light_index: int in mini(lights.size(), _light_handle_nodes.size()):
		var entry: Dictionary = lights[light_index]
		var color: Color = entry.get("color", Color.WHITE)
		var enabled: bool = bool(entry.get("enabled", true))
		var selected: bool = light_index == _selected_light_handle
		var handle: Node3D = _light_handle_nodes[light_index]
		handle.scale = Vector3.ONE
		var core := handle.get_node_or_null("Core") as MeshInstance3D
		var halo := handle.get_node_or_null("Halo") as MeshInstance3D
		var surface_anchor := handle.get_node_or_null("SurfaceAnchor") as MeshInstance3D
		var stem := handle.get_node_or_null("HeightStem") as MeshInstance3D
		if core != null:
			core.scale = Vector3.ONE * (1.25 if selected else 1.0)
			core.material_override = _make_light_handle_material(
				color,
				0.95 if enabled else 0.45,
				2.8 if enabled else 0.6
			)
		if halo != null:
			halo.scale = Vector3.ONE * (1.25 if selected else 1.0)
			var halo_color := Color(1.0, 0.82, 0.22) if selected else color
			halo.material_override = _make_light_handle_material(
				halo_color,
				0.42 if selected else 0.16,
				1.8 if selected else 0.8
			)
		if surface_anchor != null:
			surface_anchor.visible = selected
			surface_anchor.material_override = _make_light_handle_material(
				Color(1.0, 0.82, 0.22),
				0.9,
				1.5
			)
		var height_color := Color(0.18, 0.88, 1.0)
		if stem != null:
			stem.visible = selected and _authored_light_height_offset(light_index) > 0.01
			stem.material_override = _make_light_handle_material(height_color, 0.75, 1.3)


## Create an unshaded no-depth material so an editor handle cannot disappear inside level art.
func _make_light_handle_material(
	color: Color,
	alpha: float,
	emission_energy: float
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = emission_energy
	material.render_priority = 127
	return material


## Free every temporary handle and leave the authored LightingProfile untouched.
func _clear_light_handles() -> void:
	if light_handles_root == null:
		_light_handle_nodes.clear()
		return
	for child: Node in light_handles_root.get_children():
		light_handles_root.remove_child(child)
		child.queue_free()
	_light_handle_nodes.clear()


## Route surface placement, handle clicks, and active drags ahead of ordinary authoring tools.
func _handle_light_handle_input(event: InputEvent) -> bool:
	if not _light_handles_visible or board == null:
		return false
	if event is InputEventMouseMotion and _light_drag_mode != LocalLightDragMode.NONE:
		_continue_light_handle_drag((event as InputEventMouseMotion).position)
		return true
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if (
			button.button_index == MOUSE_BUTTON_RIGHT
			and button.pressed
			and _local_light_placement_pending
		):
			_local_light_placement_pending = false
			status_changed.emit("Local-light placement cancelled.")
			return true
		if button.button_index != MOUSE_BUTTON_LEFT:
			return false
		if button.pressed:
			if _local_light_placement_pending:
				return _place_local_light_on_surface(button.position)
			return _begin_light_handle_drag(button.position)
		if _light_drag_mode != LocalLightDragMode.NONE:
			_finish_light_handle_drag()
			return true
	return false


## Create a light at the exact first collision point under the cursor.
func _place_local_light_on_surface(screen_position: Vector2) -> bool:
	var hit := _local_light_surface_hit(screen_position)
	if hit.is_empty():
		status_changed.emit(
			"No authored terrain under the cursor; the new light was not created."
		)
		return true
	var new_index := board.lighting.add_light(
		hit["position"] as Vector3,
		LightingProfile.DEFAULT_LOCAL_LIGHT_HEIGHT_M
	)
	if new_index < 0:
		_local_light_placement_pending = false
		status_changed.emit(
			"This rig supports at most %d local lights." % LightingProfile.MAX_LIGHTS
		)
		return true
	_local_light_placement_pending = false
	_selected_light_handle = new_index
	board.notify_look_changed()
	_sync_light_handles_from_profile()
	local_light_handle_selected.emit(new_index)
	local_light_handle_changed.emit(
		new_index,
		_authored_light_surface_position(new_index),
		_authored_light_height_offset(new_index)
	)
	status_changed.emit(
		"Created '%s' on authored terrain; drag the cyan grip to set height."
		% _light_name(new_index)
	)
	return true


## Start one unambiguous map-position drag from the picked emitter glob.
func _begin_light_handle_drag(screen_position: Vector2) -> bool:
	var light_index := _pick_light_handle(screen_position)
	if light_index < 0:
		return false
	select_local_light_handle(light_index)
	local_light_handle_selected.emit(light_index)
	_light_drag_mode = LocalLightDragMode.SURFACE
	_light_drag_index = light_index
	_light_drag_start_surface_position = _authored_light_surface_position(light_index)
	_light_drag_start_height_offset = _authored_light_height_offset(light_index)
	# A pointer drag owns continuous rendering until release; UPDATE_ONCE can
	# otherwise disable the SubViewport between mouse-motion samples.
	if sub_viewport != null:
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	status_changed.emit(
		"Moving '%s' smoothly across authored terrain — release to commit."
		% _light_name(light_index)
	)
	return true


## Preview the exact continuous terrain point under the map-position pointer.
func _continue_light_handle_drag(screen_position: Vector2) -> void:
	if _light_drag_index < 0 or _light_drag_mode != LocalLightDragMode.SURFACE:
		return
	var hit := _local_light_surface_hit(screen_position)
	if hit.is_empty():
		return
	_preview_local_light_transform(
		_light_drag_index,
		hit["position"] as Vector3,
		_authored_light_height_offset(_light_drag_index)
	)


## Finish one already-applied surface or height drag as a single editor undo action.
func _finish_light_handle_drag() -> void:
	if _light_drag_mode == LocalLightDragMode.NONE:
		return
	var light_index := _light_drag_index
	var before_surface := _light_drag_start_surface_position
	var before_height := _light_drag_start_height_offset
	var after_surface := _authored_light_surface_position(light_index)
	var after_height := _authored_light_height_offset(light_index)
	_light_drag_mode = LocalLightDragMode.NONE
	_light_drag_index = -1
	if sub_viewport != null:
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if (
		before_surface.is_equal_approx(after_surface)
		and is_equal_approx(before_height, after_height)
	):
		return
	board.notify_look_changed()
	if _height_undo_redo != null:
		_height_undo_redo.create_action(
			"Move local light on terrain: %s" % _light_name(light_index),
			UndoRedo.MERGE_DISABLE,
			null,
			false
		)
		_height_undo_redo.add_do_method(
			self,
			"_apply_authored_light_transform",
			light_index,
			after_surface,
			after_height
		)
		_height_undo_redo.add_undo_method(
			self,
			"_apply_authored_light_transform",
			light_index,
			before_surface,
			before_height
		)
		# The profile already owns the final pointer values, so history records
		# the action without applying the same lighting rebuild a second time.
		_height_undo_redo.commit_action(false)
	status_changed.emit(
		"Placed '%s' at surface (%.2f, %.2f, %.2f), height %.2f m."
		% [
			_light_name(light_index),
			after_surface.x,
			after_surface.y,
			after_surface.z,
			after_height,
		]
	)


## Apply one exact local-light anchor and height for undo, redo, or another explicit action.
func _apply_authored_light_transform(
	light_index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	if board == null or light_index < 0 or light_index >= board.lighting.lights.size():
		push_error("[Tile Studio] Cannot move missing local light index %d." % light_index)
		return
	var lights: Array[Dictionary] = board.lighting.lights
	var entry: Dictionary = lights[light_index]
	entry["surface_position"] = surface_position
	entry["height_offset"] = clampf(
		height_offset,
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)
	lights[light_index] = entry
	board.notify_look_changed()
	select_local_light_handle(light_index)
	local_light_handle_changed.emit(
		light_index,
		surface_position,
		float(entry["height_offset"])
	)


## Update canonical transform values and their two derived viewport manifestations during drag.
func _preview_local_light_transform(
	light_index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	if board == null or light_index < 0 or light_index >= board.lighting.lights.size():
		return
	var lights: Array[Dictionary] = board.lighting.lights
	var entry: Dictionary = lights[light_index]
	entry["surface_position"] = surface_position
	entry["height_offset"] = clampf(
		height_offset,
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)
	lights[light_index] = entry
	_update_light_handle_transform(light_index)
	var emitter_position := LightingProfile.local_light_world_position(entry)
	for child: Node in lights_root.get_children():
		if int(child.get_meta(LIGHT_INDEX_META, -1)) == light_index and child is Light3D:
			(child as Light3D).position = emitter_position
			break
	local_light_handle_changed.emit(
		light_index,
		surface_position,
		float(entry["height_offset"])
	)
	request_render()


## Pick the exact displayed terrain triangle continuously under the pointer.
##
## Light placement shares MTSTerrainRenderer's canonical face picker with prop
## placement and material painting. Sparse placement collision bodies caused
## freezes across gaps and multi-metre snaps when the next body was reached.
func _local_light_surface_hit(screen_position: Vector2) -> Dictionary:
	if (
		camera == null
		or terrain_renderer == null
		or board == null
		or board.terrain.is_empty()
		or not Rect2(Vector2.ZERO, size).has_point(screen_position)
	):
		return {}
	var pick := terrain_renderer.pick_face(
		camera.project_ray_origin(screen_position),
		camera.project_ray_normal(screen_position)
	)
	if pick.is_empty():
		return {}
	return {
		"position": pick["point"],
		"normal": pick["normal"],
		"terrain_face": pick["face"],
	}


## Return the nearest visible emitter glob inside its fixed screen-space click radius.
func _pick_light_handle(screen_position: Vector2) -> int:
	if camera == null:
		return -1
	var picked: int = -1
	var closest_squared := LIGHT_HANDLE_PICK_RADIUS_PX * LIGHT_HANDLE_PICK_RADIUS_PX
	for light_index: int in _light_handle_nodes.size():
		var core := _light_handle_nodes[light_index].get_node_or_null("Core") as MeshInstance3D
		if core == null:
			continue
		var world_position := core.global_position
		if camera.is_position_behind(world_position):
			continue
		var handle_screen := camera.unproject_position(world_position)
		var distance_squared := screen_position.distance_squared_to(handle_screen)
		if distance_squared <= closest_squared:
			closest_squared = distance_squared
			picked = light_index
	return picked


## Return one exact authored surface anchor without consulting derived scene nodes.
func _authored_light_surface_position(light_index: int) -> Vector3:
	if board == null or light_index < 0 or light_index >= board.lighting.lights.size():
		return Vector3.ZERO
	return board.lighting.lights[light_index].get("surface_position", Vector3.ZERO)


## Return one exact authored height offset clamped to the visible panel's range.
func _authored_light_height_offset(light_index: int) -> float:
	if board == null or light_index < 0 or light_index >= board.lighting.lights.size():
		return 0.0
	return clampf(
		float(board.lighting.lights[light_index].get("height_offset", 0.0)),
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)


## Return a readable name for status and undo text without inventing a fallback light.
func _light_name(light_index: int) -> String:
	if board == null or light_index < 0 or light_index >= board.lighting.lights.size():
		return "missing light"
	return String(board.lighting.lights[light_index].get("name", "Light"))


## Return the current board's single authoritative lighting profile.
func _profile() -> LightingProfile:
	return board.lighting if board != null else null


## Switch between painting and erasing.
##
## Erase is a real mode, not only the right-mouse gesture it used to be. Right
## click still erases, and always did -- but an unlabelled gesture is not a
## feature anyone can find, and the tool needs a visible answer to "how do I
## delete this". In erase mode the LEFT button erases too, and drags across
## cells, which is what makes clearing a mistaken sweep practical.
## Select the visible camera mode while keeping the editor's placement tools available.
func set_camera_mode(camera_mode: int) -> void:
	if camera == null:
		push_error("[Tile Studio] Camera mode requested before the viewport camera was created.")
		return
	if camera.mode == camera_mode:
		return

	# A camera transition must not retain an unfinished authored shape
	# behind the next pointer event; the selected tool remains active on return.
	_painting = false
	_erasing = false
	_end_height_sculpt()
	if placement != null and placement.has_fill_vertices():
		placement.cancel_fill()
	camera.end_pan()
	# Both isometric modes reserve Q/E for the camera, and rotatable mode stores
	# held-key state, so every camera-mode boundary clears any stale key press.
	_keys_down.clear()
	camera.set_camera_mode(camera_mode)

	# Camera changes preserve the current pointer owner and its visible preview.
	_refresh_placement_visibility()
	_emit_status()
	request_render()


## Recompute whether the placement controller owns a visible targeting preview.
##
## Particle, marker, and circular material modes own the pointer exclusively. Terrain
## drag tools hide ordinary placement ghosts, but Fill must keep this controller visible
## because its path, polygon, candidate outlines, and blocked stamps all live beneath it.
func _refresh_placement_visibility() -> void:
	if placement == null:
		return
	var exclusive_pointer_owner := (
		material_paint_tool != MaterialPaintTool.NONE
		or (particle_effects != null and particle_effects.active)
		or (gameplay_markers != null and gameplay_markers.active)
	)
	var terrain_drag_tool_active := (
		height_sculpt_tool != HeightSculptTool.NONE
		or footprint_tool != FootprintTool.NONE
	)
	placement.visible = (
		not exclusive_pointer_owner
		and (
			not terrain_drag_tool_active
			or placement.tool == MTSPlacementController.Tool.FILL
		)
	)


## Switch between painting and erasing while retaining the current camera mode.
func set_tool(p_tool: int) -> void:
	# Selecting a placement tool deliberately leaves the terrain tool alone. The
	# two are separate authoring choices, and clearing terrain here made Fill
	# unusable with terrain at all: arming Fill switched the terrain tool off, so
	# the pair could never be active together. Pointer precedence in _gui_input()
	# is what decides which one receives a gesture, and the status bar names it.
	_sync_terrain_fill_arming(p_tool)
	# Delegated rather than duplicated. The controller owns `tool` and changes it
	# from paths this class never sees (picking a brush leaves erase mode), so it
	# is the thing that announces the change; this just forwards the request and
	# lets the signal come back through _on_tool_changed.
	placement.set_tool(p_tool)
	# Visibility is derived after the controller owns the new tool, avoiding the
	# stale PAINT state that previously hid terrain Fill's complete preview tree.
	_refresh_placement_visibility()


## Select the visible open-path or closed-polygon Fill interpretation.
func set_fill_shape(fill_shape: int) -> void:
	placement.set_fill_shape(fill_shape)
	_emit_status()
	request_render()


## Re-announce a tool change and refresh the status line.
##
## The controller is the source of truth, but the toolbar listens to this class,
## so the signal is forwarded rather than having the UI reach past the viewport
## into the controller.
func _on_tool_changed(tool: int) -> void:
	tool_changed.emit(tool)
	_emit_status()
	request_render()


func is_erasing() -> bool:
	return placement.tool == MTSPlacementController.Tool.ERASE


## Show or hide the grid drawn by the terrain's own top-face shader.
func set_grid_visible(value: bool) -> void:
	_terrain_top_grid_visible = value
	_refresh_terrain_grid_visibility()
	request_render()


## Show or hide the grid drawn by the terrain's own side-face shader.
func set_lattice_visible(value: bool) -> void:
	_terrain_side_grid_visible = value
	_refresh_terrain_grid_visibility()
	request_render()


## Update only live terrain material uniforms when either grid toggle changes.
func _refresh_terrain_grid_visibility() -> void:
	if terrain_renderer == null:
		return
	for material: ShaderMaterial in terrain_renderer.terrain_shader_materials():
		material.set_shader_parameter(
			"terrain_show_top_grid",
			_terrain_top_grid_visible
		)
		material.set_shader_parameter(
			"terrain_show_side_grid",
			_terrain_side_grid_visible
		)


## Enable the dedicated particle-effect input path and disable competing paint brushes.
func set_particle_effect_mode(enabled: bool) -> void:
	if particle_effects == null:
		return
	if enabled:
		set_height_sculpt_tool(HeightSculptTool.NONE)
		placement.clear_brush()
		if gameplay_markers != null:
			gameplay_markers.set_active(false)
	particle_effects.set_active(enabled)
	_refresh_placement_visibility()
	_painting = false
	_erasing = false
	_emit_status()
	request_render()


## Store the reusable preset ID used by the particle placement preview and next click.
func set_particle_effect_preset(preset_id: String) -> void:
	if particle_effects == null:
		return
	particle_effects.set_preset(preset_id)
	particle_effects.update_hover(camera, _last_mouse)
	request_render()


## Select how the next placed emitter resolves its height against the terrain.
func set_particle_effect_attachment(attachment: int) -> void:
	if particle_effects == null:
		return
	particle_effects.set_attachment(attachment)


## Select the visible particle panel's explicit place or erase operation.
func set_particle_effect_erase_mode(enabled: bool) -> void:
	if particle_effects == null:
		return
	particle_effects.set_erase_mode(enabled)
	particle_effects.update_hover(camera, _last_mouse)
	request_render()


## Enable the dedicated gameplay-marker input path and disable competing paint brushes.
func set_gameplay_marker_mode(enabled: bool) -> void:
	if gameplay_markers == null:
		return
	if enabled:
		set_height_sculpt_tool(HeightSculptTool.NONE)
		placement.clear_brush()
		if particle_effects != null:
			particle_effects.set_active(false)
	if gameplay_markers_root != null:
		gameplay_markers_root.visible = enabled
	gameplay_markers.set_active(enabled)
	_refresh_placement_visibility()
	_painting = false
	_erasing = false
	_emit_status()
	request_render()


## Store the exact Gameplay panel fields in the dedicated marker controller.
func set_gameplay_marker_brush(
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> void:
	if gameplay_markers == null:
		return
	gameplay_markers.set_brush(
		marker_type,
		note,
		monster_id,
		pack_id
	)
	gameplay_markers.update_hover(camera, _last_mouse)
	request_render()


## Select one explicit terrain sculpt mode.
##
## Selecting a sculpt tool leaves the footprint and material tools, because the
## three are separate authoring steps that must not receive the same drag.
func set_height_sculpt_tool(tool: int) -> void:
	_end_height_sculpt()
	height_sculpt_tool = clampi(tool, HeightSculptTool.NONE, HeightSculptTool.FLATTEN_FOOTPRINT)
	if height_sculpt_tool == HeightSculptTool.NONE:
		_hide_height_brush_preview()
	else:
		_update_height_brush_preview(_last_mouse)
	if height_sculpt_tool != HeightSculptTool.NONE:
		if material_paint_tool != MaterialPaintTool.NONE:
			_end_material_paint()
			material_paint_tool = MaterialPaintTool.NONE
			_hide_material_brush_preview()
			material_paint_tool_changed.emit(material_paint_tool)
		if footprint_tool != FootprintTool.NONE:
			_end_footprint_stroke()
			footprint_tool = FootprintTool.NONE
			footprint_tool_changed.emit(footprint_tool)
	_push_terrain_brush_settings()
	_sync_terrain_fill_arming()
	_refresh_placement_visibility()
	if placement != null and placement.visible:
		placement.update_hover(camera, _last_mouse)
	# Picking a sculpt tool deliberately changes NO look setting. Terrain elevation
	# is real geometry now, so it is visible whether or not placed surfaces are
	# configured to follow the ground; silently flipping a rendering toggle here was
	# hidden state the UI never showed.
	height_sculpt_tool_changed.emit(height_sculpt_tool)
	_emit_status()
	request_render()


## Tell the placement controller whether Fill should commit a terrain shape.
##
## Terrain Fill is armed exactly when a terrain tool is selected, so the Terrain
## panel's visible tool is the single thing that decides what Fill will do. Only
## Footprint Draw may create cells; every other terrain tool edits existing ones.
##
## `p_placement_tool` is passed explicitly because set_tool() calls this BEFORE
## delegating to the controller, so the controller's own `tool` is still stale.
func _sync_terrain_fill_arming(p_placement_tool: int = -1) -> void:
	if placement == null:
		return
	var active_tool := (
		p_placement_tool
		if p_placement_tool >= 0
		else placement.tool
	)
	var terrain_active := (
		height_sculpt_tool != HeightSculptTool.NONE
		or footprint_tool != FootprintTool.NONE
	)
	placement.set_terrain_fill(
		terrain_active and active_tool == MTSPlacementController.Tool.FILL,
		footprint_tool == FootprintTool.DRAW
	)


## Apply one committed terrain Fill shape as a single undoable stroke.
##
## Fill reuses the ordinary stroke machinery rather than a parallel edit path: the
## same sculptor, the same dirty-region rebuild, and the same undo patch a dragged
## stroke produces. Each cell receives exactly ONE application, so filling with
## Raise moves every cell by one increment just as one click of the brush would.
func _commit_terrain_fill(origins: Array[Vector3i]) -> void:
	if board == null or origins.is_empty():
		return
	if footprint_tool != FootprintTool.NONE:
		_commit_footprint_fill(origins)
		return
	if height_sculpt_tool == HeightSculptTool.NONE:
		return
	if _terrain_sculptor == null:
		_bind_terrain_sculptor()
	if _terrain_sculptor == null:
		return

	# Flatten samples its target once for the whole shape, exactly as a drag does
	# at mouse-down, so every filled cell converges on one plane.
	# Fill mode obeys the same explicit zero plane as an ordinary flatten-footprint stroke.
	var flatten_target := (
		FOOTPRINT_FLATTEN_HEIGHT_M
		if height_sculpt_tool == HeightSculptTool.FLATTEN_FOOTPRINT
		else _sample_terrain_flatten_target(origins)
	)
	_push_terrain_brush_settings(flatten_target)
	var previous_skirt_base := board.terrain.skirt_base_m
	_terrain_dirty_cells = Rect2i()
	_terrain_dirty_chunks.clear()
	_terrain_sculptor.begin_stroke()
	for origin: Vector3i in origins:
		# The centre of the cell, because the sculptor addresses brush samples in
		# world XZ and its own footprint expansion re-derives the square from there.
		var centre := Vector2(float(origin.x) + 0.5, float(origin.z) + 0.5)
		_accumulate_terrain_dirty_cells(_terrain_sculptor.stamp(centre))
	var stroke := _terrain_sculptor.finish_stroke()
	_preview_terrain_stroke(_terrain_dirty_cells)
	_refresh_dynamic_skirt(previous_skirt_base)
	_finalize_terrain_region()
	_register_terrain_sculpt_undo(stroke)
	_emit_status()


## Return the level a filled Flatten shape converges on: its first editable cell.
##
## One sample for the whole shape is what makes Fill + Flatten produce a single
## plane. Sampling per cell would flatten each cell to its own height, which is
## no change at all.
func _sample_terrain_flatten_target(origins: Array[Vector3i]) -> float:
	for origin: Vector3i in origins:
		var cell := Vector2i(origin.x, origin.z)
		if board.terrain.is_cell_filled(cell):
			return board.terrain.cell_walk_height(cell)
	return 0.0


## Apply one committed Fill shape as a footprint draw or erase stroke.
func _commit_footprint_fill(origins: Array[Vector3i]) -> void:
	# Each Fill origin is one brush stamp, so it expands through the SAME canonical
	# square a dragged footprint stroke uses. Passing the bare origins would have
	# made a wide brush fill a sparse lattice instead of a solid region.
	var targets := PackedVector2Array()
	var included: Dictionary = {}
	for origin: Vector3i in origins:
		var centre := Vector2(float(origin.x) + 0.5, float(origin.z) + 0.5)
		for target: Vector2 in _footprint_targets(centre, centre):
			var cell := Vector2i(target)
			if included.has(cell):
				continue
			included[cell] = true
			targets.append(target)
	if targets.is_empty():
		return
	# _end_footprint_stroke() is the one place that builds the footprint undo entry
	# and finalizes the region, so the Fill commit enters and leaves through the
	# same drag state rather than duplicating that logic.
	_footprint_drawing = true
	_footprint_erasing = footprint_tool == FootprintTool.ERASE
	_footprint_stroke_cells.clear()
	_footprint_stroke_before.clear()
	_footprint_stroke_start_skirt_base_m = board.terrain.skirt_base_m
	_terrain_dirty_cells = Rect2i()
	_terrain_dirty_chunks.clear()
	_apply_footprint_targets(targets)
	_end_footprint_stroke()
	_emit_status()


## Set whether the slope brushes are forbidden from moving corners that carry walls.
func set_terrain_protect_walls(enabled: bool) -> void:
	terrain_protect_walls = enabled
	_push_terrain_brush_settings()
	_emit_status()


## Clamp the fixed level increment used by the step and quantize modes.
##
## This is the sculpt level height: every stepped corner lands on an exact
## multiple of it, which is what lets separately drawn areas meet flush.
func set_terrain_step(step_m: float) -> void:
	terrain_step_m = clampf(step_m, 0.05, 8.0)
	_push_terrain_brush_settings()
	_emit_status()


## Clamp the blend strength used by the continuous sculpt modes.
func set_height_brush_strength(strength: float) -> void:
	height_brush_strength = clampf(strength, 0.01, 1.0)
	_push_terrain_brush_settings()
	_emit_status()


## Select one explicit footprint drawing mode.
func set_footprint_tool(tool: int) -> void:
	_end_footprint_stroke()
	footprint_tool = clampi(tool, FootprintTool.NONE, FootprintTool.ERASE)
	if footprint_tool != FootprintTool.NONE:
		# Footprint editing and sculpting are separate authoring steps, so
		# entering one always leaves the other.
		if height_sculpt_tool != HeightSculptTool.NONE:
			set_height_sculpt_tool(HeightSculptTool.NONE)
		if material_paint_tool != MaterialPaintTool.NONE:
			_end_material_paint()
			material_paint_tool = MaterialPaintTool.NONE
			_hide_material_brush_preview()
			material_paint_tool_changed.emit(material_paint_tool)
	_sync_terrain_fill_arming()
	_refresh_placement_visibility()
	if footprint_tool == FootprintTool.NONE:
		_hide_height_brush_preview()
	else:
		_update_footprint_brush_preview(_last_mouse)
	footprint_tool_changed.emit(footprint_tool)
	_emit_status()
	request_render()


## Return a stable display name for the active footprint mode.
func footprint_tool_name() -> String:
	match footprint_tool:
		FootprintTool.DRAW:
			return "DRAW"
		FootprintTool.ERASE:
			return "ERASE"
		_:
			return "OFF"


## Return a stable display name for the active transient sculpt mode.
func height_sculpt_tool_name() -> String:
	match height_sculpt_tool:
		HeightSculptTool.STEP_UP:
			return "STEPPED RAISE"
		HeightSculptTool.STEP_DOWN:
			return "STEPPED LOWER"
		HeightSculptTool.STEP_FLATTEN:
			return "STEPPED FLATTEN"
		HeightSculptTool.STEP_SMOOTH:
			return "STEPPED SMOOTH"
		HeightSculptTool.FLATTEN_FOOTPRINT:
			return "FLATTEN FOOTPRINT"
		HeightSculptTool.RAISE:
			return "RAISE"
		HeightSculptTool.LOWER:
			return "LOWER"
		HeightSculptTool.FLATTEN:
			return "FLATTEN"
		HeightSculptTool.SMOOTH:
			return "SMOOTH"
		HeightSculptTool.QUANTIZE:
			return "ANGULAR"
		_:
			return "OFF"


## Project a viewport point onto the canonical terrain address used by its brush family.
##
## Slope tools retain the continuous hit point; the canonical square query then uses
## lattice corners. Cell-based tools anchor to the picked cell centre so a click
## near a shared corner cannot accidentally step all four neighbouring cells.
func _height_brush_pick(mouse_pos: Vector2) -> Dictionary:
	if placement == null or camera == null:
		return {"hit": false}
	var pick := placement.pick_cell(camera, mouse_pos)
	if not bool(pick.get("hit", false)):
		return {"hit": false}
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	var point: Vector3 = pick.get("point", Vector3.ZERO)
	var world_xz := Vector2(point.x, point.z)
	if TerrainSculptor.mode_is_cell_based(_sculptor_mode_for_tool(height_sculpt_tool)):
		world_xz = Vector2(float(cell.x) + 0.5, float(cell.z) + 0.5)
	return {"hit": true, "xz": world_xz, "cell": cell, "point": point}


## Build the transient sculpt targeter without adding state to the saved board.
func _build_height_brush_preview() -> void:
	_height_brush_fill_material = StandardMaterial3D.new()
	_height_brush_fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_height_brush_fill_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_height_brush_fill_material.albedo_color = Color(0.12, 0.86, 1.0, 0.22)
	_height_brush_fill_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_height_brush_fill_material.no_depth_test = true
	_height_brush_fill_material.render_priority = 10
	_height_brush_line_material = StandardMaterial3D.new()
	_height_brush_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_height_brush_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_height_brush_line_material.albedo_color = Color(0.12, 0.86, 1.0, 1.0)
	_height_brush_line_material.no_depth_test = true
	_height_brush_line_material.render_priority = 11
	_height_brush_preview = MeshInstance3D.new()
	_height_brush_preview.name = "TerrainBrushPreview"
	_height_brush_preview.mesh = ImmediateMesh.new()
	_height_brush_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_height_brush_preview.visible = false
	world_root.add_child(_height_brush_preview)


## Hide the sculpt targeter whenever its tool or pointer has no valid receiver.
func _hide_height_brush_preview() -> void:
	if is_instance_valid(_height_brush_preview) and _height_brush_preview.visible:
		_height_brush_preview.visible = false
		request_render()


## Redraw whichever terrain authoring tool currently owns the shared targeter.
func _update_active_terrain_brush_preview(mouse_position: Vector2) -> Dictionary:
	if footprint_tool != FootprintTool.NONE:
		return _update_footprint_brush_preview(mouse_position)
	return _update_height_brush_preview(mouse_position)


## Pick terrain and redraw the exact live sculpt target under the pointer.
func _update_height_brush_preview(mouse_position: Vector2) -> Dictionary:
	if height_sculpt_tool == HeightSculptTool.NONE or board == null or board.terrain.is_empty():
		_hide_height_brush_preview()
		return {}
	var pick := _height_brush_pick(mouse_position)
	if not bool(pick.get("hit", false)):
		_hide_height_brush_preview()
		return {}
	_draw_height_brush_preview(pick)
	return pick


## Draw the exact square cell targets shared by every terrain brush family.
##
## The preview queries the configured sculptor, so footprint membership cannot
## diverge from the cells whose shared corners a smooth stroke will move.
func _draw_height_brush_preview(pick: Dictionary) -> void:
	if not is_instance_valid(_height_brush_preview) or board == null:
		return
	var immediate_mesh := _height_brush_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	if _terrain_sculptor == null:
		_bind_terrain_sculptor()
	if _terrain_sculptor == null:
		_hide_height_brush_preview()
		return
	var targets := _terrain_sculptor.cell_targets(pick["xz"])
	if targets.is_empty():
		_hide_height_brush_preview()
		return
	_draw_height_cell_targets(immediate_mesh, targets)
	_height_brush_preview.visible = immediate_mesh.get_surface_count() > 0
	request_render()


## Add translucent tops and cyan borders for every whole cell the active tool targets.
func _draw_height_cell_targets(
	immediate_mesh: ImmediateMesh,
	targets: PackedVector2Array,
	valid: bool = true
) -> void:
	# A blocked splat target remains visible in red, matching the ordinary
	# base-coat preview instead of disappearing and looking like no brush exists.
	_height_brush_fill_material.albedo_color = (
		Color(0.12, 0.86, 1.0, 0.22)
		if valid
		else Color(1.0, 0.18, 0.12, 0.22)
	)
	_height_brush_line_material.albedo_color = (
		Color(0.12, 0.86, 1.0, 1.0)
		if valid
		else Color(1.0, 0.18, 0.12, 1.0)
	)
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _height_brush_fill_material)
	for target: Vector2 in targets:
		var cell := Vector2i(target)
		var points := _height_preview_cell_points(cell)
		for index: int in [0, 2, 3, 0, 3, 1]:
			immediate_mesh.surface_add_vertex(points[index])
	immediate_mesh.surface_end()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _height_brush_line_material)
	for target: Vector2 in targets:
		var points := _height_preview_cell_points(Vector2i(target))
		for edge: Array in [[0, 1], [1, 3], [3, 2], [2, 0]]:
			immediate_mesh.surface_add_vertex(points[int(edge[0])])
			immediate_mesh.surface_add_vertex(points[int(edge[1])])
	immediate_mesh.surface_end()


## Return one cell's four canonical top corners raised just above the visible surface.
func _height_preview_cell_points(cell: Vector2i) -> PackedVector3Array:
	var heights := board.terrain.cell_top(cell)
	var points := PackedVector3Array()
	for corner: int in 4:
		var offset: Vector2i = TerrainMesh.CORNER_OFFSETS[corner]
		points.append(Vector3(
			float(cell.x + offset.x),
			heights[corner] + HEIGHT_BRUSH_PREVIEW_OFFSET_M,
			float(cell.y + offset.y)
		))
	return points


## Bind a sculptor to the live board terrain.
##
## The sculptor holds a direct reference to the canonical grid, so it is rebuilt
## whenever the board or its terrain resource is replaced.
func _bind_terrain_sculptor() -> void:
	if board == null:
		_terrain_sculptor = null
		return
	_terrain_sculptor = TerrainSculptor.new(board.terrain)
	_push_terrain_brush_settings()


## Push the visible brush values into the sculptor before a stroke uses them.
##
## Settings live in exactly one place at edit time: the UI writes these viewport
## fields, and this is the only path by which they reach a sculpt operation.
func _push_terrain_brush_settings(flatten_target_m: float = 0.0) -> void:
	if _terrain_sculptor == null:
		return
	var settings := TerrainSculptor.Settings.new()
	settings.mode = _sculptor_mode_for_tool(height_sculpt_tool)
	# One canonical brush width: the toolbar's Brush width drives terrain targeting
	# and direct-texture stamping alike, so there is no second terrain-only size
	# that could disagree with the width the user can actually see.
	settings.size_m = float(surface_grid_stroke_size_m)
	settings.step_m = terrain_step_m
	settings.strength = height_brush_strength
	settings.flatten_target_m = flatten_target_m
	settings.protect_walls = terrain_protect_walls
	_terrain_sculptor.configure(settings)


## Map one viewport sculpt tool to its single corresponding sculptor mode.
func _sculptor_mode_for_tool(tool: int) -> int:
	match tool:
		HeightSculptTool.STEP_UP:
			return TerrainSculptor.Mode.STEP_UP
		HeightSculptTool.STEP_DOWN:
			return TerrainSculptor.Mode.STEP_DOWN
		HeightSculptTool.STEP_FLATTEN, HeightSculptTool.FLATTEN_FOOTPRINT:
			return TerrainSculptor.Mode.STEP_FLATTEN
		HeightSculptTool.STEP_SMOOTH:
			return TerrainSculptor.Mode.STEP_SMOOTH
		HeightSculptTool.LOWER:
			return TerrainSculptor.Mode.LOWER
		HeightSculptTool.FLATTEN:
			return TerrainSculptor.Mode.FLATTEN
		HeightSculptTool.SMOOTH:
			return TerrainSculptor.Mode.SMOOTH
		HeightSculptTool.QUANTIZE:
			return TerrainSculptor.Mode.QUANTIZE
		_:
			return TerrainSculptor.Mode.RAISE


## Begin one sculpt stroke and apply its first sample.
func _begin_height_sculpt(mouse_pos: Vector2) -> void:
	var pick := _update_height_brush_preview(mouse_pos)
	if not bool(pick.get("hit", false)):
		return
	if board == null or board.terrain.is_empty():
		push_error("[Tile Studio] Draw an encounter footprint before sculpting terrain.")
		return
	if _terrain_sculptor == null:
		_bind_terrain_sculptor()
	if _terrain_sculptor == null:
		push_error("[Tile Studio] Terrain sculpt requested without a bound sculptor.")
		return
	var world_xz: Vector2 = pick["xz"]
	# Flatten samples its target once at stroke start so a drag pulls the whole
	# stroke toward the level the user actually clicked on.
	# Flatten footprint deliberately ignores the sampled elevation and returns the square to world zero.
	var flatten_target := (
		FOOTPRINT_FLATTEN_HEIGHT_M
		if height_sculpt_tool == HeightSculptTool.FLATTEN_FOOTPRINT
		else board.terrain.sample_world_height(world_xz, 0.0)
	)
	_push_terrain_brush_settings(flatten_target)
	_height_sculpting = true
	_height_pending_motion = false
	_height_repeat_elapsed_seconds = 0.0
	_height_hold_repeating = false
	_height_stroke_start_skirt_base_m = board.terrain.skirt_base_m
	_last_height_stamp_xz = Vector2(INF, INF)
	_terrain_dirty_cells = Rect2i()
	_terrain_dirty_chunks.clear()
	_terrain_sculptor.begin_stroke()
	_apply_height_sculpt_stamp(world_xz)
	_draw_height_brush_preview(pick)
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	hover_changed.emit(cell, true, "Terrain %s" % height_sculpt_tool_name().to_lower())

## Queue the latest sculpt pointer position for one bounded update this frame.
##
## Godot can deliver several mouse-motion events between rendered frames. Keeping
## only the newest endpoint avoids rebuilding the same terrain chunk repeatedly;
## the swept segment still covers every cell between the last applied point and it.
func _queue_height_sculpt_motion(mouse_pos: Vector2) -> void:
	if not _height_sculpting:
		_update_height_brush_preview(mouse_pos)
		return
	_height_pending_motion = true
	_height_pending_mouse_position = mouse_pos


## Apply the latest queued pointer endpoint without changing the held cadence.
##
## Mouse devices can emit motion events while effectively stationary. The hold
## timer remains independent of that event rate so one cell keeps receiving
## pulses until the button is released.
func _flush_pending_height_sculpt_motion() -> void:
	if not _height_pending_motion:
		return
	var mouse_position := _height_pending_mouse_position
	_height_pending_motion = false
	_continue_height_sculpt(mouse_position)


## Continue one stroke through an exact swept segment between rendered samples.
func _continue_height_sculpt(mouse_pos: Vector2) -> void:
	var pick := _update_height_brush_preview(mouse_pos)
	if not _height_sculpting or pick.is_empty():
		return
	var world_xz: Vector2 = pick["xz"]
	if _last_height_stamp_xz.x == INF:
		_apply_height_sculpt_stamp(world_xz)
	elif not _last_height_stamp_xz.is_equal_approx(world_xz):
		_apply_height_sculpt_segment(_last_height_stamp_xz, world_xz)
	_draw_height_brush_preview(pick)
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	hover_changed.emit(cell, true, "Terrain %s" % height_sculpt_tool_name().to_lower())


## End the active stroke and register one compact undo action for it.
func _end_height_sculpt() -> void:
	if not _height_sculpting:
		return
	# Commit the newest pointer endpoint before closing the stroke so releasing
	# between rendered frames cannot drop the visible tail of the gesture.
	_flush_pending_height_sculpt_motion()
	_height_sculpting = false
	_height_pending_motion = false
	_height_repeat_elapsed_seconds = 0.0
	_height_hold_repeating = false
	_last_height_stamp_xz = Vector2(INF, INF)
	if _terrain_sculptor == null:
		return
	var stroke := _terrain_sculptor.finish_stroke()
	_refresh_dynamic_skirt(_height_stroke_start_skirt_base_m)
	_finalize_terrain_region()
	_register_terrain_sculpt_undo(stroke)

## Rebuild every boundary chunk once when a terrain edit moves the derived base.
func _refresh_dynamic_skirt(previous_base_m: float) -> void:
	if terrain_renderer == null or board == null:
		return
	if is_equal_approx(previous_base_m, board.terrain.skirt_base_m):
		return
	var changed_chunks := terrain_renderer.refresh_visual_chunks(
		board.terrain,
		terrain_renderer.boundary_chunks(),
		surface_material_paint,
		board
	)
	for chunk: Vector2i in changed_chunks:
		_terrain_dirty_chunks[chunk] = true
	_apply_terrain_material_chunks(changed_chunks)


## Register one already-applied stroke with the editor's global history.
func _register_terrain_sculpt_undo(stroke: Dictionary) -> void:
	if _height_undo_redo == null or stroke.is_empty():
		return
	# A sculpt edit changes two things at once: the cells' own top faces and the
	# side faces along every seam around them. Both halves travel in the patch so
	# undo RESTORES the walls that were there rather than re-deriving walls from the
	# corner heights, which would quietly rewrite an imported map's authored walls.
	var cells_value: Variant = stroke.get("cells", PackedVector2Array())
	var before_tops: Variant = stroke.get("before_tops", PackedFloat32Array())
	var after_tops: Variant = stroke.get("after_tops", PackedFloat32Array())
	var before_sides: Variant = stroke.get("before_sides", {})
	var after_sides: Variant = stroke.get("after_sides", {})
	if (
		not cells_value is PackedVector2Array
		or not before_tops is PackedFloat32Array
		or not after_tops is PackedFloat32Array
		or not before_sides is Dictionary
		or not after_sides is Dictionary
	):
		push_error("[Tile Studio] Terrain stroke produced an invalid undo patch.")
		return
	var cells: PackedVector2Array = cells_value
	if cells.is_empty() and (before_sides as Dictionary).is_empty():
		return
	_height_undo_redo.create_action(
		"Sculpt terrain: %s" % height_sculpt_tool_name(),
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	_height_undo_redo.add_do_method(
		self,
		"_apply_terrain_sculpt_patch",
		cells,
		after_tops,
		after_sides
	)
	_height_undo_redo.add_undo_method(
		self,
		"_apply_terrain_sculpt_patch",
		cells,
		before_tops,
		before_sides
	)
	# The live stroke is already canonical, so committing without execution avoids
	# redoing the writes and the terrain rebuild that followed them.
	_height_undo_redo.commit_action(false)


## Apply one undo/redo terrain patch to only its affected terrain chunks.
func _apply_terrain_sculpt_patch(
	cells: PackedVector2Array,
	tops: PackedFloat32Array,
	sides: Dictionary
) -> void:
	if board == null:
		push_error("[Tile Studio] Cannot replay a terrain patch without a bound board.")
		return
	if _terrain_sculptor == null:
		_bind_terrain_sculptor()
	if _terrain_sculptor == null:
		return
	var previous_skirt_base := board.terrain.skirt_base_m
	var affected_cells := _terrain_sculptor.apply_patch(cells, tops, sides)
	_terrain_dirty_cells = affected_cells
	_terrain_dirty_chunks.clear()
	_preview_terrain_stroke(affected_cells)
	_refresh_dynamic_skirt(previous_skirt_base)
	_finalize_terrain_region()

## Apply one brush sample to the canonical terrain corners.
func _apply_height_sculpt_stamp(world_xz: Vector2) -> void:
	if _terrain_sculptor == null:
		return
	var touched := _terrain_sculptor.stamp(world_xz)
	_accumulate_terrain_dirty_cells(touched)
	_last_height_stamp_xz = world_xz
	_preview_terrain_stroke(touched)

## Apply one continuous swept segment to the canonical terrain corners.
func _apply_height_sculpt_segment(start_world_xz: Vector2, end_world_xz: Vector2) -> void:
	if _terrain_sculptor == null:
		return
	var touched := _terrain_sculptor.stamp_segment(start_world_xz, end_world_xz)
	_accumulate_terrain_dirty_cells(touched)
	_last_height_stamp_xz = end_world_xz
	_preview_terrain_stroke(touched)

## Grow the cell rectangle one in-progress stroke has invalidated.
func _accumulate_terrain_dirty_cells(touched: Rect2i) -> void:
	if touched.size.x <= 0 or touched.size.y <= 0:
		return
	if _terrain_dirty_cells.size.x <= 0 or _terrain_dirty_cells.size.y <= 0:
		_terrain_dirty_cells = touched
	else:
		_terrain_dirty_cells = _terrain_dirty_cells.merge(touched)


## Show the in-progress stroke without paying for the full derived rebuild.
##
## Material mask ranges are deliberately deferred to stroke end because they
## depend on the finished surface; recomputing them per pointer event would make
## a drag progressively slower on a large encounter map.
func _preview_terrain_stroke(affected_cells: Rect2i) -> void:
	if terrain_renderer == null or board == null:
		return
	var changed_chunks := terrain_renderer.refresh_visual_region(
		board.terrain,
		affected_cells,
		surface_material_paint,
		board
	)
	for chunk: Vector2i in changed_chunks:
		_terrain_dirty_chunks[chunk] = true
	_apply_terrain_material_chunks(changed_chunks)
	request_render()


## Release authored material whose terrain face disappeared in an optional cell scope.
##
## Sculpting supplies its dirty rectangle so paint cleanup remains local. Clearing
## the complete terrain omits the scope because every face must then be reconciled.
func _reconcile_terrain_paint(affected_cells: Rect2i = Rect2i()) -> void:
	if board == null:
		return
	var released := board.prune_orphaned_terrain_paint(affected_cells)
	if released.is_empty():
		return
	if surface_material_paint != null:
		surface_material_paint.discard_paint_for_uids(released)
	# The board's saved sidecar metadata is rebuilt from live images on save, but
	# dropping the entries now keeps the in-memory document honest immediately.
	var surviving: Array = []
	for entry_value: Variant in board.surface_material_paint.get("surfaces", []) as Array:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		if not released.has(String(entry.get("uid", ""))):
			surviving.append(entry)
	if board.surface_material_paint.has("surfaces"):
		board.surface_material_paint["surfaces"] = surviving


## Finalize collision and derived regional data once for the completed edit.
func _finalize_terrain_region() -> void:
	if board == null:
		return
	var changed_chunks: Array[Vector2i] = []
	for chunk_value: Variant in _terrain_dirty_chunks.keys():
		changed_chunks.append(chunk_value as Vector2i)
	if terrain_renderer != null:
		terrain_renderer.finalize_collision_chunks(changed_chunks)
	# Sculpting can remove side bands without deleting top cells. Reconcile only the
	# dirty rectangle so vanished wall paint is released without a full-board scan.
	_reconcile_terrain_paint(_terrain_dirty_cells)
	if world_surface_fields != null and _terrain_dirty_cells.size.x > 0:
		var coverage_expanded := _ensure_world_surface_field_coverage()
		if coverage_expanded:
			# A resized texture changes every UV, so repopulating it is the one
			# explicit case where a complete projection is actually required.
			world_surface_fields.project_terrain(board.terrain)
		elif not board.terrain.is_empty():
			world_surface_fields.project_terrain_region(
				board.terrain,
				_terrain_dirty_cells
			)
	# The ground moved, so every prop's derived base level may have moved with it.
	# Re-deriving the occupancy index here keeps the solid voxels, the stored base
	# levels and the artwork re-posed below on one answer; without it a later removal
	# would compute different keys from the ones the prop was indexed under.
	board.rebuild_indexes()
	_sync_prop_support_offsets()
	# A shader decal needs no geometry resync: its derived face arrays are rebuilt
	# when the terrain material is rebound, and its relief remains material parallax
	# over the canonical terrain triangles.
	# Markers and ground-attached effects derive their height from the terrain, so
	# they are re-derived here for the same reason prop support is re-synced above.
	_rebuild_gameplay_marker_visuals()
	_rebuild_particle_effect_visuals()
	_refresh_material_mask_ranges(true)
	terrain_changed.emit()
	_terrain_dirty_cells = Rect2i()
	_terrain_dirty_chunks.clear()
	request_render()

## Return the cell-centred footprint address under one viewport point.
func _footprint_pick(mouse_pos: Vector2) -> Dictionary:
	var pick := _height_brush_pick(mouse_pos)
	if not bool(pick.get("hit", false)):
		return {"hit": false}
	var point: Vector3 = pick.get("point", Vector3.ZERO)
	var cell := Vector2i(floori(point.x), floori(point.z))
	return {
		"hit": true,
		"cell": cell,
		"xz": Vector2(cell) + Vector2(0.5, 0.5),
		"point": point,
	}


## Return the one canonical cell footprint used by preview and mutation.
func _footprint_targets(
	start_world_xz: Vector2,
	end_world_xz: Vector2
) -> PackedVector2Array:
	return TerrainSculptor.brush_cell_targets(
		start_world_xz,
		end_world_xz,
		float(surface_grid_stroke_size_m)
	)


## Pick and display Footprint Draw/Erase with the shared terrain targeter look.
func _update_footprint_brush_preview(mouse_position: Vector2) -> Dictionary:
	if footprint_tool == FootprintTool.NONE or board == null:
		_hide_height_brush_preview()
		return {}
	var pick := _footprint_pick(mouse_position)
	if not bool(pick.get("hit", false)):
		_hide_height_brush_preview()
		return {}
	_draw_footprint_brush_preview(pick)
	return pick


## Draw exactly the cells one stationary footprint stamp would commit.
func _draw_footprint_brush_preview(pick: Dictionary) -> void:
	if not is_instance_valid(_height_brush_preview):
		return
	var targets := _footprint_targets(pick["xz"], pick["xz"])
	var immediate_mesh := _height_brush_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	if targets.is_empty():
		_hide_height_brush_preview()
		return
	_draw_height_cell_targets(immediate_mesh, targets)
	_height_brush_preview.visible = true
	request_render()


## Begin one footprint drag that draws or erases encounter cells.
func _begin_footprint_stroke(mouse_pos: Vector2, erase: bool) -> void:
	if board == null:
		return
	var pick := _update_footprint_brush_preview(mouse_pos)
	if pick.is_empty():
		return
	_footprint_drawing = true
	_footprint_erasing = erase
	_footprint_stroke_cells.clear()
	_footprint_stroke_before.clear()
	_last_footprint_stamp_xz = pick["xz"]
	_footprint_stroke_start_skirt_base_m = board.terrain.skirt_base_m
	_terrain_dirty_cells = Rect2i()
	_terrain_dirty_chunks.clear()
	_apply_footprint_targets(_footprint_targets(pick["xz"], pick["xz"]))
	_draw_footprint_brush_preview(pick)

## Continue one footprint drag across every cell the pointer crosses.
func _continue_footprint_stroke(mouse_pos: Vector2) -> void:
	var pick := _update_footprint_brush_preview(mouse_pos)
	if not _footprint_drawing or pick.is_empty():
		return
	var world_xz: Vector2 = pick["xz"]
	_apply_footprint_targets(_footprint_targets(_last_footprint_stamp_xz, world_xz))
	_last_footprint_stamp_xz = world_xz
	_draw_footprint_brush_preview(pick)


## Draw or erase the exact canonical target list, expanding only for Draw.
func _apply_footprint_targets(targets: PackedVector2Array) -> void:
	if board == null or targets.is_empty():
		return
	var area := Rect2i(Vector2i(targets[0]), Vector2i.ONE)
	for target: Vector2 in targets:
		area = area.merge(Rect2i(Vector2i(target), Vector2i.ONE))
	if not _footprint_erasing:
		# Drawing outside the allocated lattice grows it; erasing never does,
		# because removing cells cannot require new storage.
		if board.terrain.is_empty():
			board.terrain = TerrainMesh.create(area.position, area.size)
			_bind_terrain_sculptor()
		else:
			board.terrain.expand_to_include(area)
	var changed_cells := Rect2i()
	for target: Vector2 in targets:
		var cell := Vector2i(target)
		if _footprint_stroke_cells.has(cell):
			continue
		_footprint_stroke_cells[cell] = true
		var was_filled := board.terrain.is_cell_filled(cell)
		if board.terrain.set_cell_filled(cell, not _footprint_erasing):
			_footprint_stroke_before[cell] = was_filled
			var cell_rect := Rect2i(cell, Vector2i.ONE)
			changed_cells = (
				cell_rect
				if changed_cells.size.x <= 0
				else changed_cells.merge(cell_rect)
			)
	if changed_cells.size.x > 0:
		# Occupancy changes affect the edited cells plus cardinal wall/skirt owners.
		var affected_cells := changed_cells.grow(1)
		_accumulate_terrain_dirty_cells(affected_cells)
		_preview_terrain_stroke(affected_cells)

## Finish one footprint drag and register it as a single undo action.
func _end_footprint_stroke() -> void:
	if not _footprint_drawing:
		return
	_footprint_drawing = false
	_last_footprint_stamp_xz = Vector2(INF, INF)
	var edited_cells := PackedVector2Array()
	var before_values := PackedByteArray()
	var after_values := PackedByteArray()
	for key: Variant in _footprint_stroke_before.keys():
		var cell: Vector2i = key
		edited_cells.append(Vector2(cell))
		before_values.append(1 if bool(_footprint_stroke_before[key]) else 0)
		after_values.append(0 if _footprint_erasing else 1)
	_footprint_stroke_cells.clear()
	_footprint_stroke_before.clear()
	_refresh_dynamic_skirt(_footprint_stroke_start_skirt_base_m)
	_finalize_terrain_region()
	if edited_cells.is_empty() or _height_undo_redo == null:
		return
	_height_undo_redo.create_action(
		"Erase footprint" if _footprint_erasing else "Draw footprint",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	_height_undo_redo.add_do_method(
		self,
		"_apply_footprint_patch",
		edited_cells,
		after_values
	)
	_height_undo_redo.add_undo_method(
		self,
		"_apply_footprint_patch",
		edited_cells,
		before_values
	)
	_height_undo_redo.commit_action(false)

## Apply one undo/redo footprint patch to only its affected terrain chunks.
func _apply_footprint_patch(
	cells: PackedVector2Array,
	values: PackedByteArray
) -> void:
	if board == null or cells.size() != values.size():
		push_error("[Tile Studio] Cannot replay an invalid footprint patch.")
		return
	var previous_skirt_base := board.terrain.skirt_base_m
	var changed_cells := Rect2i()
	for index: int in cells.size():
		var cell := Vector2i(cells[index])
		if not board.terrain.set_cell_filled(cell, values[index] != 0):
			continue
		var cell_rect := Rect2i(cell, Vector2i.ONE)
		changed_cells = (
			cell_rect
			if changed_cells.size.x <= 0
			else changed_cells.merge(cell_rect)
		)
	if changed_cells.size.x <= 0:
		return
	var affected_cells := changed_cells.grow(1)
	_terrain_dirty_cells = affected_cells
	_terrain_dirty_chunks.clear()
	_preview_terrain_stroke(affected_cells)
	_refresh_dynamic_skirt(previous_skirt_base)
	_finalize_terrain_region()

## Build one lightweight editor-only ring owner that never enters board or placement data.
func _build_material_brush_preview() -> void:
	_material_brush_preview_material = StandardMaterial3D.new()
	_material_brush_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material_brush_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material_brush_preview_material.albedo_color = Color(0.12, 0.86, 1.0, 0.92)
	_material_brush_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material_brush_preview_material.no_depth_test = true
	_material_brush_preview_material.render_priority = 10
	_material_brush_preview = MeshInstance3D.new()
	_material_brush_preview.name = "MaterialBrushPreview"
	_material_brush_preview.mesh = ImmediateMesh.new()
	_material_brush_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material_brush_preview.visible = false
	world_root.add_child(_material_brush_preview)
	_rebuild_material_brush_preview_mesh(material_brush_radius_m)


## Hide the transient ring without touching the active tool or any authored image.
func _hide_material_brush_preview() -> void:
	if is_instance_valid(_material_brush_preview) and _material_brush_preview.visible:
		_material_brush_preview.visible = false
		request_render()


## Ray-pick once, update the visible ring, and return the same hit for an active stroke.
func _update_material_brush_preview(mouse_position: Vector2) -> Dictionary:
	if material_paint_tool == MaterialPaintTool.NONE:
		_hide_material_brush_preview()
		_hide_height_brush_preview()
		return {}
	var hit := _material_surface_hit(mouse_position)
	if hit.is_empty():
		_hide_material_brush_preview()
		_hide_height_brush_preview()
		return {}
	_draw_material_brush_preview(hit)
	return hit


## Rebuild the cursor's local ring only when its visible physical radius changes.
func _rebuild_material_brush_preview_mesh(radius_m: float) -> void:
	if not is_instance_valid(_material_brush_preview):
		return
	var immediate_mesh := _material_brush_preview.mesh as ImmediateMesh
	if immediate_mesh == null:
		return
	var radius := maxf(radius_m, 0.01)
	var band := clampf(radius * 0.12, 0.008, 0.06)
	var inner_radius := maxf(radius - band, radius * 0.35)
	var outer_radius := radius + band
	immediate_mesh.clear_surfaces()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _material_brush_preview_material)
	for segment: int in MATERIAL_BRUSH_PREVIEW_SEGMENTS:
		var angle_a := TAU * float(segment) / float(MATERIAL_BRUSH_PREVIEW_SEGMENTS)
		var angle_b := TAU * float(segment + 1) / float(MATERIAL_BRUSH_PREVIEW_SEGMENTS)
		var direction_a := Vector3(cos(angle_a), sin(angle_a), 0.0)
		var direction_b := Vector3(cos(angle_b), sin(angle_b), 0.0)
		var inner_a := direction_a * inner_radius
		var outer_a := direction_a * outer_radius
		var inner_b := direction_b * inner_radius
		var outer_b := direction_b * outer_radius
		for vertex: Vector3 in [inner_a, outer_a, outer_b, inner_a, outer_b, inner_b]:
			immediate_mesh.surface_add_vertex(vertex)
	immediate_mesh.surface_end()
	_material_brush_preview_mesh_radius_m = radius


## Draw the circular pen on the exact terrain plane under the pointer.
func _draw_material_brush_preview(hit: Dictionary) -> void:
	if not is_instance_valid(_material_brush_preview):
		return
	_hide_height_brush_preview()
	var radius := maxf(material_brush_radius_m, 0.01)
	if not is_equal_approx(_material_brush_preview_mesh_radius_m, radius):
		_rebuild_material_brush_preview_mesh(radius)
	var center: Vector3 = hit.get("world_position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal_world", Vector3.UP).normalized()
	var tangent: Vector3 = hit.get("tangent_world", Vector3.RIGHT).normalized()
	var binormal: Vector3 = hit.get("binormal_world", Vector3.FORWARD).normalized()
	center += normal * MATERIAL_BRUSH_PREVIEW_OFFSET_M
	_material_brush_preview.global_transform = Transform3D(
		Basis(tangent, binormal, normal).orthonormalized(),
		center
	)
	_material_brush_preview.visible = true
	request_render()


## Arm a surface asset for one-click Godot-native decal placement.
##
## Native decals use the ordinary placement controller, and the palette choice is
## copied into each saved placement so its appearance remains inspectable.
func arm_native_decal_brush(
	asset: TileAsset,
	match_underlying_palette: bool,
	edge_mode_enabled: bool = false
) -> void:
	set_material_paint_tool(MaterialPaintTool.NONE)
	if placement == null:
		push_error("[Tile Studio] Cannot arm a decal brush without placement controls.")
		return
	if placement.brush_asset != asset:
		placement.set_brush(asset)
	placement.set_surface_palette_matching(match_underlying_palette)
	placement.set_surface_presentation(SurfacePlacement.Presentation.DECAL)
	placement.set_surface_edge_mode(edge_mode_enabled)
	placement.set_tool(MTSPlacementController.Tool.PAINT)
	# A mode change invalidates the prior primitive, so the stationary cursor is
	# immediately repicked as either a canonical edge or an ordinary cell.
	placement.update_hover(camera, _last_mouse)


## Arm a surface asset for one-click terrain-material stamping.
##
## Shader decals are saved placements whose maps are composed into the receiving
## face arrays. They therefore use the ordinary terrain draw and its complete
## lighting and parallax pipeline instead of a separate transparent surface.
func arm_shader_decal_brush(
	asset: TileAsset,
	match_underlying_palette: bool,
	edge_mode_enabled: bool = false
) -> void:
	set_material_paint_tool(MaterialPaintTool.NONE)
	if placement == null:
		push_error("[Tile Studio] Cannot arm a shader decal brush without placement controls.")
		return
	if placement.brush_asset != asset:
		placement.set_brush(asset)
	placement.set_surface_palette_matching(match_underlying_palette)
	placement.set_surface_presentation(SurfacePlacement.Presentation.SHADER_DECAL)
	placement.set_surface_edge_mode(edge_mode_enabled)
	placement.set_tool(MTSPlacementController.Tool.PAINT)
	# Shader decals use the same explicit edge primitive as native decals.
	placement.update_hover(camera, _last_mouse)


## Return the ordinary surface brush to terrain-material paint presentation.
func disarm_native_decal_brush() -> void:
	if placement != null:
		placement.set_surface_presentation(SurfacePlacement.Presentation.TERRAIN_PAINT)
		placement.set_surface_edge_mode(false)


## Select the transient material pen while keeping input ownership explicit.
func set_material_paint_tool(tool: int) -> void:
	_end_material_paint()
	material_paint_tool = clampi(tool, MaterialPaintTool.NONE, MaterialPaintTool.ERASE)
	if material_paint_tool != MaterialPaintTool.NONE and height_sculpt_tool != HeightSculptTool.NONE:
		_end_height_sculpt()
		_hide_height_brush_preview()
		height_sculpt_tool = HeightSculptTool.NONE
		height_sculpt_tool_changed.emit(height_sculpt_tool)
	_refresh_placement_visibility()
	if material_paint_tool == MaterialPaintTool.NONE:
		_hide_material_brush_preview()
		_hide_height_brush_preview()
	else:
		_update_material_brush_preview(_last_mouse)
	material_paint_tool_changed.emit(material_paint_tool)
	_emit_status()
	request_render()


## Set the one canonical square brush width shared by texture stamping and terrain.
##
## This single toolbar value is the width for direct PNG placement, Fill stamping,
## and every terrain brush. The terrain panel deliberately owns no second size
## control, so the width the user sets is always the width a sculpt stroke uses.
func set_surface_grid_stroke_size(size_m: float) -> void:
	surface_grid_stroke_size_m = clampi(roundi(size_m), 1, 100)
	if placement != null:
		placement.set_surface_grid_stroke_size(surface_grid_stroke_size_m)
	# Terrain reads this width through _push_terrain_brush_settings(), so the live
	# sculptor and the on-screen targeter both have to be refreshed here.
	_push_terrain_brush_settings()
	_update_active_terrain_brush_preview(_last_mouse)
	_emit_status()


## Set the Materials-owned circular pen radius independently from grid placement.
func set_material_brush_radius(radius_m: float) -> void:
	material_brush_radius_m = clampf(radius_m, 0.01, 100.0)
	if material_paint_tool != MaterialPaintTool.NONE:
		_update_material_brush_preview(_last_mouse)


## Set the maximum pen opacity applied by one completed stroke.
func set_material_brush_opacity(opacity: float) -> void:
	material_brush_opacity = clampf(opacity, 0.0, 1.0)


## Set the pen edge hardness while preserving the same physical outer radius.
func set_material_brush_hardness(hardness: float) -> void:
	material_brush_hardness = clampf(hardness, 0.0, 1.0)


## Select which palette material the brush paints.
##
## This is a board palette index, not one of the four texel slots: the slot a stroke
## writes is resolved per face at paint time, because different faces may carry
## different four-material sets.
func set_material_brush_palette_index(palette_index: int) -> void:
	material_brush_palette_index = maxi(palette_index, 0)


## Arm one overlay PNG through the same brush state used by regular tile painting.
func set_material_layer_brush_asset(asset: TileAsset) -> void:
	if asset == null or not asset.is_surface():
		push_error("[Tile Studio] layered material painting requires a valid PNG surface asset.")
		return
	material_layer_brush_asset = asset
	if placement == null:
		return
	if placement.brush_asset != asset:
		placement.set_brush(asset)
	placement.set_surface_presentation(SurfacePlacement.Presentation.TERRAIN_PAINT)


## Disarm the layered PNG brush without leaving an ordinary tile targeter visible.
func clear_material_layer_brush_asset() -> void:
	var previous_asset := material_layer_brush_asset
	material_layer_brush_asset = null
	if placement != null and placement.brush_asset == previous_asset:
		placement.clear_brush()


## Return the regular PNG brush quarter-turn consumed by both Pen and Tile writes.
func material_layer_rotation_quarters() -> int:
	if placement == null or material_layer_brush_asset == null:
		return 0
	return K.normalized_quarters(placement.brush_quarters)


## Convert the visible projection enum into the one canonical terrain face it addresses.
static func _splatmap_face_for_projection(projection: int) -> int:
	match projection:
		MaterialBlendProfile.SplatmapProjection.TOP:
			return K.Face.POS_Y
		MaterialBlendProfile.SplatmapProjection.NORTH:
			return K.Face.NEG_Z
		MaterialBlendProfile.SplatmapProjection.SOUTH:
			return K.Face.POS_Z
		MaterialBlendProfile.SplatmapProjection.EAST:
			return K.Face.POS_X
		MaterialBlendProfile.SplatmapProjection.WEST:
			return K.Face.NEG_X
	push_error("[Tile Studio] Splatmap projection is outside Top/North/South/East/West.")
	return K.Face.POS_Y


## Return the currently stored projection face used by preview, brush sampling, and overlay.
func _splatmap_projection_face() -> int:
	if board == null or board.material_blend == null:
		return K.Face.POS_Y
	return _splatmap_face_for_projection(board.material_blend.splatmap_projection)


## Return whether the live terrain contains at least one face in a proposed visible direction.
func splatmap_projection_available(projection: int) -> bool:
	if terrain_renderer == null:
		return false
	return not terrain_renderer.splatmap_targets(
		_splatmap_face_for_projection(projection)
	).is_empty()


## Rebuild the source cache and update only overlay uniforms after projection changes.
func refresh_splatmap_projection() -> bool:
	_end_terrain_material_tile_stroke()
	_invalidate_splatmap_projection()
	var projected := _ensure_splatmap_projection()
	if splatmap_tile_paint_enabled:
		_refresh_terrain_material_tile_targeter()
	if projected:
		_refresh_splatmap_material_controls()
	request_render()
	return projected


## Apply main-panel splatmap controls immediately without rebuilding canonical paint images.
##
## Empty-region extension rebuilds only the active source guide and future brush sampler.
## Strength changes update shader uniforms in place, so already-painted terrain responds live.
func refresh_splatmap_live_settings(rebuild_source: bool) -> bool:
	if (
		board == null
		or board.material_blend == null
		or material_factory == null
		or surface_material_paint == null
	):
		return false
	surface_material_paint.bind_profile(board.material_blend)
	if rebuild_source:
		_invalidate_splatmap_projection()
		if (
			not board.material_blend.splatmap_source_path.is_empty()
			and not _ensure_splatmap_projection()
		):
			return false
	_refresh_splatmap_material_controls()
	request_render()
	return true


## Discard the cached control projection after the terrain or its visible inputs change.
func _invalidate_splatmap_projection() -> void:
	_splatmap_source_image = null
	_splatmap_source_texture = null
	_splatmap_targets.clear()
	_splatmap_target_by_uid.clear()
	_splatmap_terrain_bounds = Rect2i()
	_splatmap_channel_mask = Vector4.ONE
	_splatmap_source_valid = false


## Return which of the four channels currently own an assigned, enabled material.
##
## Painting and the guide overlay both read this, so an unassigned slot can never
## contribute weight in one of them while staying visible in the other.
func _splatmap_active_channels() -> PackedByteArray:
	var active_channels := PackedByteArray([0, 0, 0, 0])
	if board == null or board.material_blend == null:
		return active_channels
	# Splatmap mode alone has literal R/G/B/A identities; each channel names the
	# palette entry selected in its visible setup dialog.
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var palette_index := board.material_blend.splatmap_palette_indices[channel_index]
		if palette_index < 0 or palette_index >= board.material_blend.layer_count():
			continue
		var layer := board.material_blend.layer(palette_index)
		if (
			bool(layer.get("enabled", false))
			and not String(layer.get("asset_id", "")).is_empty()
		):
			active_channels[channel_index] = 1
	return active_channels


## Build a complete directional projection cache without mutating the live board state.
##
## Import uses this before committing its material profile so invalid faces or a failed guide
## texture leave the previous authored setup intact.
func _build_splatmap_projection_cache(
	prepared_source: Image,
	targets: Array[Dictionary],
	bounds_result: Dictionary,
	active_channels: PackedByteArray
) -> Dictionary:
	var bounds_value: Variant = bounds_result.get("terrain_bounds", null)
	if (
		int(bounds_result.get("error", FAILED)) != OK
		or not bounds_value is Rect2i
		or active_channels.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
	):
		return {}
	var indexed_targets: Array[Dictionary] = []
	var target_by_uid: Dictionary = {}
	for target: Dictionary in targets:
		var uid := String(target.get("uid", ""))
		var cell_value: Variant = target.get("projection_cell", null)
		var grid_value: Variant = target.get("grid_cell", null)
		if uid.is_empty() or not cell_value is Vector2i or not grid_value is Vector3i:
			push_error("[Tile Studio] Splatmap projection has an invalid terrain target.")
			return {}
		var indexed_target := target.duplicate(true)
		indexed_targets.append(indexed_target)
		target_by_uid[uid] = indexed_target
	# The guide samples the same prepared image as authored strokes, so preview and paint
	# cannot disagree about empty-region extension or source texel weights.
	var source_texture := ImageTexture.create_from_image(prepared_source)
	if source_texture == null:
		push_error("[Tile Studio] The prepared splatmap guide texture could not be created.")
		return {}
	return {
		"source_image": prepared_source,
		"source_texture": source_texture,
		"terrain_bounds": bounds_value,
		"targets": indexed_targets,
		"target_by_uid": target_by_uid,
		"channel_mask": Vector4(
			float(active_channels[0]),
			float(active_channels[1]),
			float(active_channels[2]),
			float(active_channels[3])
		),
	}


## Install one previously validated projection cache as the active preview and brush source.
func _install_splatmap_projection_cache(cache: Dictionary) -> void:
	_invalidate_splatmap_projection()
	_splatmap_source_image = cache["source_image"]
	_splatmap_source_texture = cache["source_texture"]
	_splatmap_terrain_bounds = cache["terrain_bounds"]
	_splatmap_targets.assign(cache["targets"])
	_splatmap_target_by_uid = cache["target_by_uid"]
	_splatmap_channel_mask = cache["channel_mask"]
	_splatmap_source_valid = true


## Project the saved control image across the current terrain's directional face rectangle.
##
## This resolves the prepared source, its exact directional bounds, and stable face-UID
## records. It produces no tile weights, so arming scales only with matching terrain faces.
func _ensure_splatmap_projection() -> bool:
	if _splatmap_source_valid:
		return true
	if (
		board == null
		or board.material_blend == null
		or terrain_renderer == null
		or surface_material_paint == null
	):
		return false
	var source_path := board.material_blend.splatmap_source_path
	if source_path.is_empty():
		return false
	if not FileAccess.file_exists(source_path):
		push_error(
			"[Tile Studio] Splatmap control image is missing: '%s'." % source_path
		)
		return false
	var source := Image.new()
	var load_error := source.load(source_path)
	if load_error != OK:
		push_error(
			"[Tile Studio] Splatmap control image '%s' could not be loaded (%s)."
			% [source_path, error_string(load_error)]
		)
		return false
	var active_channels := _splatmap_active_channels()
	var prepared_source := surface_material_paint.prepare_splatmap_source(
		source,
		active_channels,
		board.material_blend.splatmap_fill_empty_regions,
		board.material_blend.splatmap_empty_region_channel
	)
	if prepared_source == null:
		_invalidate_splatmap_projection()
		return false
	var projection_face := _splatmap_projection_face()
	var targets := terrain_renderer.splatmap_targets(projection_face)
	var bounds_result := surface_material_paint.splatmap_terrain_bounds(targets)
	var projection_cache := _build_splatmap_projection_cache(
		prepared_source,
		targets,
		bounds_result,
		active_channels
	)
	if projection_cache.is_empty():
		_invalidate_splatmap_projection()
		return false
	_install_splatmap_projection_cache(projection_cache)
	return true


## Return the RGBA weights one directional projection cell takes from the control image.
func _splatmap_tile_weights(projection_cell: Vector2i) -> Image:
	if not _splatmap_source_valid or surface_material_paint == null:
		return null
	return surface_material_paint.build_splatmap_tile(
		_splatmap_source_image,
		_splatmap_terrain_bounds,
		projection_cell,
		_splatmap_active_channels()
	)


## Give imported RGBA weights exclusive ownership of the existing terrain tile targeter.
func set_splatmap_tile_paint_enabled(enabled: bool) -> void:
	var changed := splatmap_tile_paint_enabled != enabled
	if enabled:
		material_tile_paint_enabled = false
	splatmap_tile_paint_enabled = enabled
	_refresh_terrain_material_tile_targeter()
	if changed and enabled and placement != null:
		placement.set_tool(MTSPlacementController.Tool.PAINT)
	_emit_status()
	request_render()


## Give the selected mask-blended material channel ownership of the same tile targeter.
func set_material_tile_paint_enabled(enabled: bool) -> void:
	var changed := material_tile_paint_enabled != enabled
	if enabled:
		splatmap_tile_paint_enabled = false
	material_tile_paint_enabled = enabled
	_refresh_terrain_material_tile_targeter()
	if changed and enabled and placement != null:
		placement.set_tool(MTSPlacementController.Tool.PAINT)
	_emit_status()
	request_render()


## Arm one explicit tile-paint owner while leaving the circular pen as a separate input path.
func _refresh_terrain_material_tile_targeter() -> void:
	if placement == null:
		return
	var enabled := splatmap_tile_paint_enabled or material_tile_paint_enabled
	if not enabled:
		_end_terrain_material_tile_stroke()
		placement.set_terrain_splat_paint(false)
		_hide_height_brush_preview()
		_refresh_placement_visibility()
		return
	# The base-coat controller is the only pointer owner in either tile mode.
	if material_paint_tool != MaterialPaintTool.NONE:
		set_material_paint_tool(MaterialPaintTool.NONE)
	if height_sculpt_tool != HeightSculptTool.NONE:
		set_height_sculpt_tool(HeightSculptTool.NONE)
	if footprint_tool != FootprintTool.NONE:
		set_footprint_tool(FootprintTool.NONE)
	disarm_native_decal_brush()
	# Explicit Tile modes are drawn only by PlacementController's canonical preview.
	_hide_height_brush_preview()
	var validator := Callable(self, "_validate_splatmap_tile_targets")
	var face := _splatmap_projection_face()
	var follow_hover_face := false
	if material_tile_paint_enabled:
		validator = Callable(self, "_validate_material_tile_targets")
		face = K.Face.POS_Y
		follow_hover_face = true
	placement.set_terrain_splat_paint(
		true,
		validator,
		face,
		follow_hover_face,
		material_tile_paint_enabled
	)
	_refresh_placement_visibility()
	# Re-evaluate the parked pointer so switching modes displays the exact next target.
	if camera != null:
		placement.update_hover(camera, _last_mouse)


## Validate one canonical base-coat target set for masked-channel tile painting.
func _validate_material_tile_targets(
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool
) -> Dictionary:
	if not material_tile_paint_enabled or surface_material_paint == null:
		return {"valid": false, "reason": "Masked material Tile brush is off."}
	if board == null or board.material_blend == null:
		return {"valid": false, "reason": "Open a board before painting material tiles."}
	var layer := board.material_blend.layer(material_brush_palette_index)
	if (
		not bool(layer.get("enabled", false))
		or String(layer.get("asset_id", "")).is_empty()
	):
		return {"valid": false, "reason": "Choose a material and mask before painting tiles."}
	for uid: String in target_uids:
		if not uid.is_empty() and (not erase or surface_material_paint.has_image(uid)):
			return {"valid": true, "reason": ""}
	return {
		"valid": false,
		"reason": (
			"No painted material tiles are inside this brush."
			if erase
			else "This tile brush covers no terrain faces."
		),
	}


## Validate one base-coat stamp against the terrain faces the brush actually covers.
##
## Restamping a tile from the control map is the normal operation, not an overwrite
## hazard: the weights come from the projection, so painting the same square twice is
## idempotent. Only erase needs existing paint, so only erase is gated on finding it.
func _validate_splatmap_tile_targets(
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool
) -> Dictionary:
	if not splatmap_tile_paint_enabled:
		return {"valid": false, "reason": "Splatmap Terrain Mode is off."}
	if not _ensure_splatmap_projection():
		return {
			"valid": false,
			"reason": "Load an RGBA control map before painting splatmap tiles.",
		}
	var has_mutable_cell := false
	for uid: String in target_uids:
		if not _splatmap_target_by_uid.has(uid):
			continue
		if not erase or surface_material_paint.has_image(uid):
			has_mutable_cell = true
			break
	if has_mutable_cell:
		return {"valid": true, "reason": ""}
	return {
		"valid": false,
		"reason": (
			"No painted splat tiles are inside this brush."
			if erase
			else "This brush covers no terrain faces in the selected projection."
		),
	}


## Begin one tile-material stroke so dragged Paint, Erase, Path, and Fill share one undo action.
func _begin_terrain_material_tile_stroke() -> bool:
	if _terrain_material_tile_stroke_active:
		return true
	if surface_material_paint == null:
		return false
	if splatmap_tile_paint_enabled and not _ensure_splatmap_projection():
		return false
	if not splatmap_tile_paint_enabled and not material_tile_paint_enabled:
		return false
	surface_material_paint.begin_stroke()
	_terrain_material_tile_stroke_active = true
	return true


## Finish one tile-material stroke and register its exact sparse RGBA change with global undo.
func _end_terrain_material_tile_stroke() -> void:
	if not _terrain_material_tile_stroke_active:
		return
	_terrain_material_tile_stroke_active = false
	var stroke := surface_material_paint.finish_stroke()
	var action := (
		"Paint splatmap base coat"
		if splatmap_tile_paint_enabled
		else "Paint masked material tiles"
	)
	_register_material_paint_undo(stroke, action)


## Apply the face UIDs already resolved by the canonical base-coat targeter.
func _on_terrain_material_tile_paint_requested(
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool,
	finish_stroke: bool
) -> void:
	if (
		target_uids.is_empty()
		or (not splatmap_tile_paint_enabled and not material_tile_paint_enabled)
	):
		return
	if not _begin_terrain_material_tile_stroke():
		return
	var changed := false
	for uid: String in target_uids:
		if uid.is_empty() or (erase and not surface_material_paint.has_image(uid)):
			continue
		if splatmap_tile_paint_enabled:
			# Imported RGBA weights are sampled only after the shared targeter identifies the face.
			var target: Dictionary = _splatmap_target_by_uid.get(uid, {})
			if target.is_empty():
				continue
			var cell: Vector2i = target.get("projection_cell", Vector2i.ZERO)
			var weights := null if erase else _splatmap_tile_weights(cell)
			if not erase and weights == null:
				continue
			if surface_material_paint.stamp_splatmap_tile(
				uid,
				weights,
				board.material_blend.splatmap_palette_indices,
				erase
			):
				changed = true
		elif surface_material_paint.stamp_material_tile(
			uid,
			material_brush_palette_index,
			material_brush_opacity,
			material_layer_rotation_quarters(),
			erase
		):
			# The shader applies the selected world-space mask to this full-tile gate.
			changed = true
	if changed:
		request_render()
	if finish_stroke:
		_end_terrain_material_tile_stroke()


## Enable native stylus pressure independently for pen size and opacity.
func set_material_pressure_controls(size_enabled: bool, opacity_enabled: bool) -> void:
	material_pressure_size_enabled = size_enabled
	material_pressure_opacity_enabled = opacity_enabled
	if board != null and board.material_blend != null:
		board.material_blend.pressure_controls_size = size_enabled
		board.material_blend.pressure_controls_opacity = opacity_enabled


## Return the exact canonical heightfield face under the material pointer.
##
## Painting writes only splat weights on the terrain receiver. A miss stays empty,
## so no other geometry can become an alternate target.
func _material_surface_hit(mouse_position: Vector2) -> Dictionary:
	if camera == null or board == null or not Rect2(Vector2.ZERO, size).has_point(mouse_position):
		return {}
	var ray_origin := camera.project_ray_origin(mouse_position)
	var ray_end := ray_origin + camera.project_ray_normal(mouse_position) * 10000.0
	# Material painting has exactly one receiver: the canonical heightfield.
	# A terrain miss remains empty instead of falling through to legacy PNG bodies.
	return _terrain_paint_hit(ray_origin, ray_end)


## Return a paint hit on the terrain surface, or an empty dictionary.
##
## The ray is intersected against the terrain's own collision faces, which are
## built from the same corner lattice as the visible mesh, so the brush lands
## exactly where the ground is drawn.
##
## The reported footprint is the whole encounter grid rather than any tile size:
## that is what frees terrain painting from stepping in tile-sized increments.
func _terrain_paint_hit(ray_origin: Vector3, _ray_end: Vector3) -> Dictionary:
	if terrain_renderer == null or board == null or board.terrain.is_empty():
		return {}
	var pick: Dictionary = terrain_renderer.pick_face(
		ray_origin,
		(_ray_end - ray_origin).normalized()
	)
	if pick.is_empty():
		return {}
	var face: Dictionary = pick["face"]
	var uid := String(pick["uid"])
	var hit_normal: Vector3 = pick["normal"]
	var is_wall := bool(pick["is_wall"])
	return {
		# Paint is addressed by the terrain face's own canonical UID. No placement
		# record stands in for the face: terrain art comes from the painted palette
		# written against that identity, never from a base image.
		"terrain_face": face,
		"uid": uid,
		"footprint": terrain_renderer.paint_footprint_for_uid(uid),
		"uv": (pick["local_uv"] as Vector2).clamp(Vector2.ZERO, Vector2.ONE),
		"world_position": pick["point"],
		"normal_world": hit_normal,
		# The brush is projected along the face it actually hit, so a stroke keeps a
		# constant world size on a wall as well as on the ground.
		"paint_plane_normal_world": hit_normal,
		"tangent_world": (
			Vector3(-hit_normal.z, 0.0, hit_normal.x).normalized()
			if is_wall
			else Vector3.RIGHT
		),
		"binormal_world": Vector3.UP if is_wall else Vector3.BACK,
	}


## Return every terrain face one world-space brush capsule touches.
##
## The terrain equivalent of the PNG branch below: a stroke is one continuous
## world capsule, so it must write EVERY 1 m unit it crosses rather than clipping
## at the face under the cursor. Local UV endpoints are deliberately left
## unbounded so a stroke that starts on one unit and continues onto the next stays
## one capsule instead of becoming two square edge stamps.
func _terrain_surface_stamps(
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	var stamps: Array[Dictionary] = []
	if terrain_renderer == null:
		return stamps
	for face: Dictionary in terrain_renderer.faces_near_segment(
		start_world,
		end_world,
		radius_m
	):
		var uid := String(face["paint_uid"])
		stamps.append({
			"uid": uid,
			"footprint": terrain_renderer.paint_footprint_for_uid(uid),
			"start_uv": terrain_renderer.local_uv_for_face(face, start_world),
			"end_uv": terrain_renderer.local_uv_for_face(face, end_world),
		})
	return stamps


## Return every exact terrain face touched by one world-space brush capsule.
func _material_surface_stamps(
	reference_hit: Dictionary,
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	if (reference_hit.get("terrain_face", {}) as Dictionary).is_empty():
		return [] as Array[Dictionary]
	return _terrain_surface_stamps(start_world, end_world, radius_m)


## Begin one sparse stroke and apply its first metric brush stamp.
func _begin_material_paint(
	mouse_position: Vector2,
	pressure: float = 1.0,
	force_erase: bool = false,
	prepared_hit: Dictionary = {}
) -> void:
	if material_paint_tool == MaterialPaintTool.NONE or surface_material_paint == null:
		return
	surface_material_paint.begin_stroke()
	_material_painting = true
	_material_has_last_sample = false
	_material_pending_sample = false
	_material_pending_hit.clear()
	_material_stroke_force_erase = force_erase
	_apply_material_paint_hit(mouse_position, pressure, force_erase, prepared_hit)


## Retain only the latest raw pointer endpoint because the next capsule covers the full intervening path.
func _continue_material_paint(
	mouse_position: Vector2,
	pressure: float,
	pen_inverted: bool,
	prepared_hit: Dictionary = {}
) -> void:
	if not _material_painting:
		return
	_material_pending_sample = true
	_material_pending_mouse_position = mouse_position
	_material_pending_pressure = pressure
	_material_pending_force_erase = pen_inverted or _material_stroke_force_erase
	_material_pending_hit = prepared_hit.duplicate()


## Apply at most one queued pointer endpoint before this frame's one dirty-layer upload.
func _flush_pending_material_paint() -> void:
	if not _material_painting or not _material_pending_sample:
		return
	var mouse_position := _material_pending_mouse_position
	var pressure := _material_pending_pressure
	var force_erase := _material_pending_force_erase
	var hit := _material_pending_hit
	_material_pending_sample = false
	_material_pending_hit = {}
	if hit.is_empty():
		hit = _update_material_brush_preview(mouse_position)
	else:
		_draw_material_brush_preview(hit)
	_apply_material_paint_hit(mouse_position, pressure, force_erase, hit)


## Apply one pointer sample as one world-space circular capsule across tile seams.
func _apply_material_paint_hit(
	mouse_position: Vector2,
	pressure: float,
	force_erase: bool,
	prepared_hit: Dictionary = {}
) -> void:
	var hit := prepared_hit if not prepared_hit.is_empty() else _material_surface_hit(mouse_position)
	if hit.is_empty():
		_material_has_last_sample = false
		return
	var normalized_pressure := pressure if pressure > 0.0 else 1.0
	var radius := material_brush_radius_m
	var opacity := material_brush_opacity
	if material_pressure_size_enabled:
		radius *= normalized_pressure
	if material_pressure_opacity_enabled:
		opacity *= normalized_pressure
	var erase := (
		material_paint_tool == MaterialPaintTool.ERASE
		or force_erase
	)
	var terrain_face: Dictionary = hit.get("terrain_face", {})
	if placement != null and not terrain_face.is_empty():
		placement.align_surface_brush_face(int(terrain_face.get("face", K.Face.POS_Y)))
	var rotation_quarters := material_layer_rotation_quarters()
	var world_position: Vector3 = hit.get("world_position", Vector3.ZERO)
	var plane_normal: Vector3 = hit.get(
		"paint_plane_normal_world",
		hit.get("normal_world", Vector3.UP)
	)
	plane_normal = plane_normal.normalized()
	var start_world := world_position
	if (
		_material_has_last_sample
		and plane_normal.dot(_material_last_plane_normal) > 0.9999
		and absf(
			plane_normal.dot(world_position - _material_last_world_position)
		) <= 0.001
	):
		start_world = _material_last_world_position
	var changed := false
	for stamp: Dictionary in _material_surface_stamps(
		hit,
		start_world,
		world_position,
		radius
	):
		if surface_material_paint.brush_segment(
			String(stamp["uid"]),
			stamp["footprint"],
			stamp["start_uv"],
			stamp["end_uv"],
			radius,
			material_brush_hardness,
			opacity,
			material_brush_palette_index,
			rotation_quarters,
			erase
		):
			changed = true
	if changed:
		request_render()
	_material_has_last_sample = true
	_material_last_world_position = world_position
	_material_last_plane_normal = plane_normal

## Finish one stroke and register only its modified pixels with global undo.
func _end_material_paint() -> void:
	if not _material_painting:
		return
	_flush_pending_material_paint()
	_material_painting = false
	_material_pending_sample = false
	_material_pending_hit.clear()
	_material_stroke_force_erase = false
	var stroke := (
		surface_material_paint.finish_stroke()
		if surface_material_paint != null
		else {}
	)
	_material_has_last_sample = false
	_register_material_paint_undo(stroke)


## Register an already-applied sparse material stroke without replaying it.
func _register_material_paint_undo(
	stroke: Dictionary,
	action_name: String = ""
) -> void:
	if _height_undo_redo == null or stroke.is_empty():
		return
	var patches_value: Variant = stroke.get("patches", {})
	if not patches_value is Dictionary:
		push_error("[Tile Studio] Material stroke produced an invalid undo patch.")
		return
	var patches: Dictionary = patches_value
	if patches.is_empty():
		return
	var resolved_action_name := (
		action_name
		if not action_name.is_empty()
		else "Paint material layer %d" % (material_brush_palette_index + 1)
	)
	_height_undo_redo.create_action(
		resolved_action_name,
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	_height_undo_redo.add_do_method(
		self,
		"_apply_material_paint_patch",
		patches,
		"after"
	)
	_height_undo_redo.add_undo_method(
		self,
		"_apply_material_paint_patch",
		patches,
		"before"
	)
	_height_undo_redo.commit_action(false)


## Apply one sparse undo/redo patch and queue only its touched array layers.
func _apply_material_paint_patch(patches: Dictionary, value_key: String) -> void:
	if surface_material_paint == null:
		push_error("[Tile Studio] Cannot replay material paint without its image owner.")
		return
	surface_material_paint.apply_patch(patches, value_key)
	request_render()


# --- Input ----------------------------------------------------------------

## Route editor input to camera navigation, modular placement, or the selected paint/sculpt tool.
func _gui_input(event: InputEvent) -> void:
	if _movement_grid_active and _handle_movement_grid_input(event):
		accept_event()
		return
	if _handle_light_handle_input(event):
		accept_event()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_last_mouse = motion.position
		_material_pointer_pressure = motion.pressure if motion.pressure > 0.0 else 1.0
		_material_pointer_inverted = motion.pen_inverted
		if camera.is_panning():
			camera.pan_screen(motion.relative)
		elif particle_effects != null and particle_effects.active:
			particle_effects.update_hover(camera, motion.position)
		elif gameplay_markers != null and gameplay_markers.active:
			gameplay_markers.update_hover(camera, motion.position)
		elif _select_dragging:
			_continue_select_interaction(motion.position)
		elif material_paint_tool != MaterialPaintTool.NONE:
			if _material_painting:
				_continue_material_paint(
					motion.position,
					motion.pressure,
					motion.pen_inverted
				)
			else:
				_update_material_brush_preview(motion.position)
		elif (
			placement.tool == MTSPlacementController.Tool.FILL
			and (
				placement.terrain_fill_enabled
				or placement.terrain_splat_paint_enabled
			)
		):
			# Mirrors the button handler: under Fill the pointer is defining a
			# shape, so it feeds the Fill hover rather than sculpting directly.
			placement.update_hover(camera, motion.position)
		elif height_sculpt_tool != HeightSculptTool.NONE:
			_queue_height_sculpt_motion(motion.position)
		elif footprint_tool != FootprintTool.NONE:
			_continue_footprint_stroke(motion.position)
		else:
			placement.update_hover(camera, motion.position)
			if _painting:
				placement.paint_at_hover()
			elif _erasing:
				placement.erase_at_hover()
		accept_event()

	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		_last_mouse = button.position
		match button.button_index:
			MOUSE_BUTTON_MIDDLE:
				if button.pressed:
					camera.begin_pan()
				else:
					camera.end_pan()
				accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					camera.zoom_in()
				accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					camera.zoom_out()
				accept_event()
			MOUSE_BUTTON_LEFT:
				grab_focus()
				if particle_effects != null and particle_effects.active:
					particle_effects.update_hover(camera, button.position)
					if button.pressed:
						if particle_effects.erase_mode:
							particle_effects.erase_at_hover()
						else:
							particle_effects.place_at_hover()
					accept_event()
					return
				if gameplay_markers != null and gameplay_markers.active:
					gameplay_markers.update_hover(camera, button.position)
					if button.pressed:
						gameplay_markers.place_at_hover()
					accept_event()
					return
				if material_paint_tool != MaterialPaintTool.NONE:
					if button.pressed:
						var material_hit := _update_material_brush_preview(button.position)
						_begin_material_paint(
							button.position,
							_material_pointer_pressure,
							_material_pointer_inverted,
							material_hit
						)
					else:
						_end_material_paint()
					accept_event()
					return
				# Fill outranks the terrain drag tools. Arming Fill is an explicit
				# statement that the next clicks define a shape rather than paint
				# one, so a terrain tool under Fill collects vertices and commits
				# on Enter instead of sculpting directly under the cursor.
				if (
					placement.tool == MTSPlacementController.Tool.FILL
					and (
						placement.terrain_fill_enabled
						or placement.terrain_splat_paint_enabled
					)
				):
					placement.update_hover(camera, button.position)
					if button.pressed:
						if placement.add_fill_vertex_at_hover():
							_emit_status()
						request_render()
					accept_event()
					return
				if height_sculpt_tool != HeightSculptTool.NONE:
					if button.pressed:
						_begin_height_sculpt(button.position)
					else:
						_end_height_sculpt()
					accept_event()
					return
				if footprint_tool != FootprintTool.NONE:
					if button.pressed:
						_begin_footprint_stroke(
							button.position,
							footprint_tool == FootprintTool.ERASE
						)
					else:
						_end_footprint_stroke()
					accept_event()
					return
				if placement.tool == MTSPlacementController.Tool.SELECT:
					var additive_selection := button.shift_pressed or button.ctrl_pressed
					if button.pressed:
						_begin_select_interaction(button.position, additive_selection)
					else:
						_end_select_interaction(button.position, additive_selection)
					accept_event()
					return
				placement.update_hover(camera, button.position)
				if button.pressed:
					if placement.tool == MTSPlacementController.Tool.FILL:
						_painting = false
						_erasing = false
						if placement.add_fill_vertex_at_hover():
							_emit_status()
						request_render()
					elif placement.tool == MTSPlacementController.Tool.ERASE:
						# Erase always drags. Unlike painting there is no
						# prop/surface distinction to make: removing is removing,
						# and sweeping away a bad stroke is the reason the mode
						# exists.
						_erasing = true
						if (
							placement.terrain_splat_paint_enabled
							and not _begin_terrain_material_tile_stroke()
						):
							_erasing = false
						else:
							placement.erase_at_hover()
					elif placement.has_brush() or placement.terrain_splat_paint_enabled:
						# Drag-painting is a SURFACE affordance: sweeping a floor
						# brush across cells is the whole point. Both material tile modes use
						# this exact base-coat path and differ only in the RGBA values written.
						_painting = (
							placement.terrain_splat_paint_enabled
							or (
								placement.brush_is_surface()
								and placement.brush_surface_presentation
								== SurfacePlacement.Presentation.TERRAIN_PAINT
							)
						)
						if (
							placement.terrain_splat_paint_enabled
							and not _begin_terrain_material_tile_stroke()
						):
							_painting = false
						else:
							placement.paint_at_hover()
					else:
						placement.select_at_hover()
				else:
					var finished_surface_drag := _painting or _erasing
					_painting = false
					_erasing = false
					if finished_surface_drag and placement.terrain_splat_paint_enabled:
						_end_terrain_material_tile_stroke()
				accept_event()
			MOUSE_BUTTON_RIGHT:
				if particle_effects != null and particle_effects.active:
					particle_effects.update_hover(camera, button.position)
					if button.pressed:
						particle_effects.erase_at_hover()
					accept_event()
					return
				if gameplay_markers != null and gameplay_markers.active:
					gameplay_markers.update_hover(camera, button.position)
					if button.pressed:
						gameplay_markers.erase_at_hover()
					accept_event()
					return
				if material_paint_tool != MaterialPaintTool.NONE:
					if button.pressed:
						var material_hit := _update_material_brush_preview(button.position)
						_begin_material_paint(
							button.position,
							1.0,
							true,
							material_hit
						)
					else:
						_end_material_paint()
					accept_event()
					return
				if height_sculpt_tool != HeightSculptTool.NONE:
					accept_event()
					return
				if footprint_tool != FootprintTool.NONE:
					# Right-drag always erases while the footprint tool is active,
					# so cutting an L out of a drawn rectangle needs no mode switch.
					if button.pressed:
						_begin_footprint_stroke(button.position, true)
					else:
						_end_footprint_stroke()
					accept_event()
					return
				if placement.tool == MTSPlacementController.Tool.SELECT:
					if button.pressed:
						placement.clear_selection()
					accept_event()
					return
				placement.update_hover(camera, button.position)
				if placement.tool == MTSPlacementController.Tool.FILL:
					if button.pressed and placement.remove_last_fill_vertex():
						_emit_status()
						request_render()
					_erasing = false
				elif button.pressed:
					_erasing = true
					if (
						placement.terrain_splat_paint_enabled
						and not _begin_terrain_material_tile_stroke()
					):
						_erasing = false
					else:
						placement.erase_at_hover()
				else:
					var finished_tile_erase := _erasing and placement.terrain_splat_paint_enabled
					_erasing = false
					if finished_tile_erase:
						_end_terrain_material_tile_stroke()
				accept_event()

	elif event is InputEventKey:
		_handle_key(event as InputEventKey)


func _handle_key(key: InputEventKey) -> void:
	# Lighting owns vertical arrows contextually while its handles are visible;
	# this keeps map dragging and height editing as two unambiguous operations.
	if (
		key.pressed
		and _light_handles_visible
		and _selected_light_handle >= 0
		and key.keycode in [KEY_UP, KEY_DOWN]
	):
		_nudge_selected_light_height(1 if key.keycode == KEY_UP else -1)
		accept_event()
		return

	# Fixed Isometric reserves Q/E for one exact quarter-turn per press. Releases
	# are consumed too, so E cannot leak through to the authoring-tool shortcut.
	if camera != null and camera.is_isometric() and key.keycode in [KEY_Q, KEY_E]:
		if key.pressed and not key.echo:
			camera.step_fixed_isometric_direction(key.keycode == KEY_Q)
			_emit_status()
		accept_event()
		return

	# Rotatable Isometric reserves held Q/E for continuous camera orbit; all other
	# gestures continue through the existing keyboard and mouse routes.
	if camera != null and camera.is_rotatable_isometric() and key.keycode in [KEY_Q, KEY_E]:
		_keys_down[key.keycode] = key.pressed
		accept_event()
		return

	# Held zoom is integrated in _process so one press does not require repeated taps.
	if key.pressed and key.keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_MINUS, KEY_KP_SUBTRACT]:
		accept_event()
		return

	if key.pressed and not key.echo:
		match key.keycode:
			KEY_E:
				# Toggle, not a one-way switch: the same key that reaches for
				# the eraser puts it back down, so erasing a stray tile mid-sweep
				# costs two taps and never leaves the user stuck in a mode.
				set_tool(
					MTSPlacementController.Tool.PAINT if is_erasing()
					else MTSPlacementController.Tool.ERASE
				)
				accept_event()
			KEY_B:
				set_tool(MTSPlacementController.Tool.PAINT)
				accept_event()
			KEY_V:
				# V is unused by camera navigation, unlike S which remains reserved
				# for ground panning while the viewport has focus.
				set_tool(MTSPlacementController.Tool.SELECT)
				accept_event()
			KEY_G:
				set_tool(
					MTSPlacementController.Tool.PAINT
					if placement.tool == MTSPlacementController.Tool.FILL
					else MTSPlacementController.Tool.FILL
				)
				accept_event()
			KEY_ENTER, KEY_KP_ENTER:
				if placement.tool == MTSPlacementController.Tool.FILL:
					placement.commit_fill()
					_emit_status()
					request_render()
					accept_event()
			KEY_BACKSPACE:
				if placement.tool == MTSPlacementController.Tool.FILL:
					if placement.remove_last_fill_vertex():
						_emit_status()
						request_render()
					accept_event()
			KEY_ESCAPE:
				if placement.tool == MTSPlacementController.Tool.SELECT:
					# Escape cancels the transient selection interaction and clears the
					# canonical selection that produces the visible bounding boxes.
					_select_dragging = false
					_select_drag_target = null
					_select_drag_has_start_cell = false
					placement.clear_selection()
					_emit_status()
					request_render()
				elif (
					placement.tool == MTSPlacementController.Tool.FILL
					and placement.has_fill_vertices()
				):
					placement.cancel_fill()
					_emit_status()
					request_render()
				else:
					placement.clear_brush()
				accept_event()
			KEY_F:
				if (
					placement.tool == MTSPlacementController.Tool.SELECT
					and key.shift_pressed
				):
					# Flip commits through the same selected-orientation validator as
					# arrow rotation; plain F retains its existing framing behavior.
					placement.flip_selection()
					_emit_status()
					request_render()
				else:
					_frame_selection()
				accept_event()
			KEY_HOME:
				frame_board()
				accept_event()
			# Direct face selection. Building a stair step means switching a floor
			# brush onto a vertical face and back constantly; hunting for it with
			# arrow-key rotation is far too slow.
			KEY_1:
				_set_brush_face(K.Face.POS_Y)
				accept_event()
			KEY_2:
				_set_brush_face(K.Face.NEG_Y)
				accept_event()
			KEY_3:
				_set_brush_face(K.Face.POS_X)
				accept_event()
			KEY_4:
				_set_brush_face(K.Face.NEG_X)
				accept_event()
			KEY_5:
				_set_brush_face(K.Face.POS_Z)
				accept_event()
			KEY_6:
				_set_brush_face(K.Face.NEG_Z)
				accept_event()
			KEY_DELETE:
				placement.delete_selection()
				accept_event()
			KEY_LEFT:
				# Shift swaps the rotation axis to world Z (spec 14).
				_rotate_selection_or_brush(K.DIR_SOUTH if key.shift_pressed else K.DIR_UP, true)
				accept_event()
			KEY_RIGHT:
				_rotate_selection_or_brush(K.DIR_SOUTH if key.shift_pressed else K.DIR_UP, false)
				accept_event()
			KEY_UP:
				_rotate_selection_or_brush(K.DIR_EAST, true)
				accept_event()
			KEY_DOWN:
				_rotate_selection_or_brush(K.DIR_EAST, false)
				accept_event()

	if key.keycode in [KEY_W, KEY_A, KEY_S, KEY_D]:
		_keys_down[key.keycode] = key.pressed
		accept_event()


## Adjust only the selected light's height offset as one mergeable undo action.
func _nudge_selected_light_height(direction: int) -> void:
	if (
		board == null
		or _selected_light_handle < 0
		or _selected_light_handle >= board.lighting.lights.size()
	):
		return
	var light_index := _selected_light_handle
	var surface_position := _authored_light_surface_position(light_index)
	var before_height := _authored_light_height_offset(light_index)
	var after_height := clampf(
		snappedf(
			before_height + signi(direction) * LIGHT_HEIGHT_KEY_STEP_M,
			0.01
		),
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)
	if is_equal_approx(before_height, after_height):
		return
	if _height_undo_redo == null:
		_apply_authored_light_transform(light_index, surface_position, after_height)
	else:
		_height_undo_redo.create_action(
			"Adjust local light height: %s" % _light_name(light_index),
			UndoRedo.MERGE_ENDS,
			self
		)
		_height_undo_redo.add_do_method(
			self,
			"_apply_authored_light_transform",
			light_index,
			surface_position,
			after_height
		)
		_height_undo_redo.add_undo_method(
			self,
			"_apply_authored_light_transform",
			light_index,
			surface_position,
			before_height
		)
		_height_undo_redo.commit_action()
	status_changed.emit(
		"Height for '%s': %.2f m." % [_light_name(light_index), after_height]
	)


## Route the existing arrow-key orientation gesture to the active editable state.
func _rotate_selection_or_brush(axis: Vector3i, positive: bool) -> void:
	if placement.tool == MTSPlacementController.Tool.SELECT:
		placement.rotate_selection(axis, positive)
	else:
		placement.rotate_brush(axis, positive)
	_emit_status()
	request_render()


## Point the active surface brush straight at a face without stepping through rotations.
func _set_brush_face(face: int) -> void:
	if not placement.brush_is_surface():
		return
	placement.set_brush_face(face)
	placement.update_hover(camera, _last_mouse)
	_emit_status()


## Force-clear any drag/held-key state whose real OS input is no longer
## pressed, so a missed release event (mouse button released outside this
## control, focus lost mid-drag to a popup/dialog, Alt-Tab while WASD panning)
## cannot leave the camera stuck panning forever.
##
## _gui_input only ever SETS these flags on press and clears them on the
## matching release, and that release event can be lost -- Godot's mouse
## capture/gui-input routing does not guarantee a Control still receives a
## button-up that occurred after the pointer left it, or while another window
## had focus. Reading Input's live button/key state here removes the
## possibility of drift: whatever the flags say, this brings them back into
## agreement with reality at least once per frame, at negligible cost.
func _clear_stuck_input_state() -> void:
	if camera != null and camera.is_panning() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		camera.end_pan()
	if _painting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_painting = false
	if _erasing and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_erasing = false
	if _height_sculpting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_height_sculpt()
	if _material_painting and (
		not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	):
		_end_material_paint()
	if _select_dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_select_interaction(_last_mouse, false)
	for keycode in _keys_down.keys():
		if _keys_down[keycode] and not Input.is_key_pressed(keycode):
			_keys_down[keycode] = false


## Apply held sculpt pulses only after the pointer has remained down deliberately.
##
## Mouse-down already applies the first stamp synchronously. The separate initial
## delay keeps a normal click at exactly one stamp, while the shorter repeat
## interval makes an intentional hold feel continuous and independent of frame rate.
func _advance_height_sculpt_hold(delta: float) -> void:
	if not _height_sculpting or _terrain_sculptor == null:
		return
	var pulse_threshold := (
		HEIGHT_SCULPT_REPEAT_SECONDS
		if _height_hold_repeating
		else HEIGHT_SCULPT_HOLD_DELAY_SECONDS
	)
	_height_repeat_elapsed_seconds = minf(
		_height_repeat_elapsed_seconds + delta,
		pulse_threshold + HEIGHT_SCULPT_REPEAT_SECONDS
	)
	if _height_repeat_elapsed_seconds < pulse_threshold:
		return
	_height_repeat_elapsed_seconds -= pulse_threshold
	_height_hold_repeating = true
	if _last_height_stamp_xz.x == INF:
		return
	_terrain_sculptor.begin_pulse()
	_apply_height_sculpt_stamp(_last_height_stamp_xz)
	var cell := Vector2i(floori(_last_height_stamp_xz.x), floori(_last_height_stamp_xz.y))
	_draw_height_brush_preview({
		"xz": _last_height_stamp_xz,
		"cell": Vector3i(cell.x, 0, cell.y),
		"point": Vector3(
			_last_height_stamp_xz.x,
			board.terrain.sample_world_height(_last_height_stamp_xz, 0.0),
			_last_height_stamp_xz.y
		),
	})


## Advance live sculpt previews and camera navigation once per frame.
func _process(delta: float) -> void:
	_flush_pending_material_paint()
	if surface_material_paint != null and surface_material_paint.upload_dirty() > 0:
		request_render()
	if camera == null:
		return
	var active_visual_input := (
		camera.is_panning()
		or _painting
		or _erasing
		or _height_sculpting
		or _select_dragging
	)
	_clear_stuck_input_state()
	_flush_pending_height_sculpt_motion()
	_advance_height_sculpt_hold(delta)

	var moved: bool = false
	if camera.is_rotatable_isometric():
		if _keys_down.get(KEY_Q, false):
			camera.rotate_isometric(true, delta)
			moved = true
		if _keys_down.get(KEY_E, false):
			camera.rotate_isometric(false, delta)
			moved = true

	var ground_direction := Vector2.ZERO
	if _keys_down.get(KEY_D, false):
		ground_direction.x += 1.0
	if _keys_down.get(KEY_A, false):
		ground_direction.x -= 1.0
	if _keys_down.get(KEY_W, false):
		ground_direction.y += 1.0
	if _keys_down.get(KEY_S, false):
		ground_direction.y -= 1.0
	if ground_direction != Vector2.ZERO:
		camera.pan_ground(ground_direction.normalized(), delta)
		moved = true

	# Integrate held zoom as a small logarithmic rate, matching the continuous
	# cadence of orbit and pan. A full button-sized factor per frame made a held
	# key traverse the entire zoom range almost instantly.
	var zoom_rate: float = 0.0
	if Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_PLUS) or Input.is_key_pressed(KEY_KP_ADD):
		zoom_rate = -K.ISO_ZOOM_RATE_PER_SECOND
	elif Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT):
		zoom_rate = K.ISO_ZOOM_RATE_PER_SECOND
	if not is_zero_approx(zoom_rate):
		camera.zoom_by_factor(exp(zoom_rate * delta))
		moved = true

	if active_visual_input or moved:
		request_render()

## Frame the primary selection from exact collision-derived geometry.
func _frame_selection() -> void:
	if placement.selected != null:
		var collision_points := _placement_collision_points(placement.selected)
		if not collision_points.is_empty():
			camera.frame_aabb(_placement_collision_aabb(placement.selected))
			return
	camera.frame_point(Vector3(placement.hovered_cell) + Vector3(0.5, 0, 0.5))


func _find_visual(target: Resource) -> Node3D:
	for root: Node3D in [
		surfaces_root,
		props_root,
		gameplay_markers_root,
	]:
		for child in root.get_children():
			var node := child as Node3D
			if node != null and node.get_meta("mts_placement", null) == target:
				return node
	return null


func frame_board() -> void:
	_frame_board_from_bounds(_board_bounds())


## Frame one supplied board bound so a full rebuild does not calculate it again.
func _frame_board_from_bounds(bounds: AABB) -> void:
	if board == null or board.is_empty():
		camera.frame_point(Vector3.ZERO, K.ISO_DEFAULT_ORTHO_SIZE)
		return
	camera.frame_aabb(bounds)


## Return the rebuild-scoped board bounds or calculate them for an independent action.
func _board_bounds() -> AABB:
	if _full_rebuild_has_bounds:
		return _full_rebuild_bounds
	return board.compute_bounds() if board != null else AABB()


## Forward the canonical PlacementController hover state to the editor shell.
func _on_hover_changed(cell: Vector3i, valid: bool, reason: String) -> void:
	hover_changed.emit(cell, valid, reason)
	request_render()


## Forward exact particle preview coordinates to the editor status bar.
func _on_particle_hover_changed(
	position: Vector3,
	valid: bool,
	reason: String
) -> void:
	particle_hover_changed.emit(position, valid, reason)
	request_render()


func _emit_status() -> void:
	var counts := "0 surfaces / 0 props / 0 markers / 0 particles"
	if board != null:
		counts = "%d surfaces / %d props / %d markers / %d packs / %d particles" % [
			board.surfaces.size(),
			board.props.size(),
			board.gameplay_markers.size(),
			board.enemy_packs.size(),
			board.particle_effects.size(),
		]
	var overlay := ""
	if occupancy_overlay != null and occupancy_overlay.mode != OccupancyOverlay.Mode.OFF:
		overlay = " | occupancy %s" % occupancy_overlay.mode_name()
	# Non-default placement modes state both their behavior and current data.
	if particle_effects != null and particle_effects.active:
		overlay += " | PARTICLE %s" % (
			"ERASE" if particle_effects.erase_mode else "PLACE"
		)
	elif gameplay_markers != null and gameplay_markers.active:
		overlay += " | GAMEPLAY MARKERS"
	elif (splatmap_tile_paint_enabled or material_tile_paint_enabled) and placement != null:
		var tile_mode_name := (
			"SPLATMAP BASE COAT | all RGBA channels"
			if splatmap_tile_paint_enabled
			else "LAYER MATERIAL TILE | selected RGBA slot"
		)
		overlay += " | %s width=%dm" % [tile_mode_name, surface_grid_stroke_size_m]
		if material_tile_paint_enabled:
			overlay += " | PNG rotation=%d°" % (material_layer_rotation_quarters() * 90)
		overlay += " | REPLACE %s" % ("ON" if placement.replace_enabled else "OFF")
		if placement.tool == MTSPlacementController.Tool.FILL:
			overlay += " | FILL %s | %d points | %d ready / %d blocked" % [
				placement.fill_shape_name(),
				placement.fill_vertex_count(),
				placement.fill_valid_count(),
				placement.fill_blocked_count(),
			]
			overlay += " | Enter commit | right-click/Backspace undo | Esc cancel"
		elif placement.tool == MTSPlacementController.Tool.ERASE:
			overlay += " | ERASE"
		else:
			overlay += " | left paint | right erase"
	elif placement != null and placement.tool == MTSPlacementController.Tool.ERASE:
		overlay += " | ERASE"
	elif placement != null and placement.tool == MTSPlacementController.Tool.SELECT:
		overlay += (
			" | SELECT %d | drag move | Left/Right yaw 45 | Up/Down pitch 90"
			+ " | Shift+Left/Right roll 90 | Shift+F flip | Delete remove"
		) % placement.selected_resources().size()
	elif placement != null and placement.tool == MTSPlacementController.Tool.FILL:
		overlay += " | FILL %s | %d points | %d ready / %d blocked" % [
			placement.fill_shape_name(),
			placement.fill_vertex_count(),
			placement.fill_valid_count(),
			placement.fill_blocked_count(),
		]
		overlay += " | Enter commit | right-click/Backspace undo | Esc cancel"
	if footprint_tool != FootprintTool.NONE:
		overlay += " | FOOTPRINT %s | %d cells" % [
			footprint_tool_name(),
			board.terrain.filled_cell_count() if board != null else 0,
		]
	if height_sculpt_tool != HeightSculptTool.NONE:
		overlay += " | TERRAIN %s width=%dm step=%.2fm strength=%.2f%s" % [
			height_sculpt_tool_name(),
			surface_grid_stroke_size_m,
			terrain_step_m,
			height_brush_strength,
			" | WALLS PROTECTED" if terrain_protect_walls else "",
		]
	if material_paint_tool != MaterialPaintTool.NONE:
		overlay += " | MATERIAL BRUSH r=%.2fm | PNG rotation=%d° | left paint | right erase" % [
			material_brush_radius_m,
			material_layer_rotation_quarters() * 90,
		]
	if camera != null:
		if camera.is_isometric():
			overlay += " | CAMERA FIXED ISO %d/%d (%s) | Q/E TURN" % [
				camera.get_fixed_isometric_direction_index() + 1,
				MTSCameraController.FIXED_ISOMETRIC_DIRECTION_COUNT,
				camera.get_fixed_isometric_direction_label(),
			]
		elif camera.is_rotatable_isometric():
			overlay += " | CAMERA ROTATABLE ISO"
		elif camera.is_top_down():
			overlay += " | CAMERA TOP DOWN"
	var terrain_summary := "no terrain"
	if board != null and not board.terrain.is_empty():
		terrain_summary = "terrain %d cells" % board.terrain.filled_cell_count()
	status_changed.emit("%s | %s%s" % [terrain_summary, counts, overlay])
