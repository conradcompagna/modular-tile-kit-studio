@tool
class_name MTSStudioViewport
extends SubViewportContainer

const LifecycleFeature := preload("studio/lifecycle.gd")
const PickingFeature := preload("studio/picking.gd")
const SelectionFeature := preload("studio/selection.gd")
const EnvironmentFeature := preload("studio/environment.gd")
const BindingFeature := preload("studio/binding.gd")
const LookFeature := preload("studio/look.gd")
const WorldFieldsFeature := preload("studio/world_fields.gd")
const SynchronizationFeature := preload("studio/synchronization.gd")
const RegionalUpdatesFeature := preload("studio/regional_updates.gd")
const AssetUpdatesFeature := preload("studio/asset_updates.gd")
const GameplayFeature := preload("studio/gameplay.gd")
const WorldContactsFeature := preload("studio/world_contacts.gd")
const SurfacesFeature := preload("studio/surfaces.gd")
const MaterialPreviewFeature := preload("studio/material_preview.gd")
const MaterialProfilesFeature := preload("studio/material_profiles.gd")
const SplatmapImportFeature := preload("studio/splatmap_import.gd")
const PaintResolutionFeature := preload("studio/paint_resolution.gd")
const PaintHistoryFeature := preload("studio/paint_history.gd")
const DocumentLoadingFeature := preload("studio/document_loading.gd")
const TerrainMaterialsFeature := preload("studio/terrain_materials.gd")
const TerrainLifecycleFeature := preload("studio/terrain_lifecycle.gd")
const ContactGeometryFeature := preload("studio/contact_geometry.gd")
const PropSupportFeature := preload("studio/prop_support.gd")
const PropNodesFeature := preload("studio/prop_nodes.gd")
const PropBatchesFeature := preload("studio/prop_batches.gd")
const RendererSettingsFeature := preload("studio/renderer_settings.gd")
const VisibilityFeature := preload("studio/visibility.gd")
const MovementGridFeature := preload("studio/movement_grid.gd")
const LightingFeature := preload("studio/lighting.gd")
const LightHandlesFeature := preload("studio/light_handles.gd")
const LightInteractionFeature := preload("studio/light_interaction.gd")
const ToolModesFeature := preload("studio/tool_modes.gd")
const SculptSettingsFeature := preload("studio/sculpt_settings.gd")
const SculptPreviewFeature := preload("studio/sculpt_preview.gd")
const SculptStrokesFeature := preload("studio/sculpt_strokes.gd")
const FootprintFeature := preload("studio/footprint.gd")
const MaterialBrushFeature := preload("studio/material_brush.gd")
const SplatmapProjectionFeature := preload("studio/splatmap_projection.gd")
const MaterialTargetsFeature := preload("studio/material_targets.gd")
const MaterialStrokesFeature := preload("studio/material_strokes.gd")
const InputFeature := preload("studio/input.gd")
const ProcessFeature := preload("studio/process.gd")
const FramingFeature := preload("studio/framing.gd")

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
	LifecycleFeature._ready(self)


func request_render() -> void:
	LifecycleFeature.request_render(self)


func _placement_root_from_collider(collider: Node) -> Node3D:
	return PickingFeature._placement_root_from_collider(self, collider)


func _ray_distance_to_aabb(
	ray_origin: Vector3,
	ray_direction: Vector3,
	bounds: AABB
) -> float:
	return PickingFeature._ray_distance_to_aabb(self, ray_origin, ray_direction, bounds)


func _ray_distance_to_collision_voxels(
	ray_origin: Vector3,
	ray_direction: Vector3,
	voxels: Array[Vector3i],
	world_origin: Vector3 = Vector3.ZERO
) -> float:
	return PickingFeature._ray_distance_to_collision_voxels(self, ray_origin, ray_direction, voxels, world_origin)


func _placement_collision_voxels(placement_record: Resource) -> Array[Vector3i]:
	return PickingFeature._placement_collision_voxels(self, placement_record)


func _placement_collision_origin(placement_record: Resource) -> Vector3:
	return PickingFeature._placement_collision_origin(self, placement_record)


func _placement_collision_points(placement_record: Resource) -> PackedVector3Array:
	return PickingFeature._placement_collision_points(self, placement_record)


func _placement_collision_aabb(placement_record: Resource) -> AABB:
	return PickingFeature._placement_collision_aabb(self, placement_record)


func _decal_at_terrain_hit(terrain_face: Dictionary, world_point: Vector3) -> SurfacePlacement:
	return PickingFeature._decal_at_terrain_hit(self, terrain_face, world_point)


func _placement_at_pointer(mouse_pos: Vector2) -> Resource:
	return PickingFeature._placement_at_pointer(self, mouse_pos)


func _refresh_selection_highlights() -> void:
	SelectionFeature._refresh_selection_highlights(self)


func _placement_intersects_screen_rect(
	placement_record: Resource,
	screen_rect: Rect2
) -> bool:
	return SelectionFeature._placement_intersects_screen_rect(self, placement_record, screen_rect)


func _placements_in_screen_rect(screen_rect: Rect2) -> Array[Resource]:
	return SelectionFeature._placements_in_screen_rect(self, screen_rect)


func _begin_select_interaction(mouse_pos: Vector2, additive: bool) -> void:
	SelectionFeature._begin_select_interaction(self, mouse_pos, additive)


func _continue_select_interaction(mouse_pos: Vector2) -> void:
	SelectionFeature._continue_select_interaction(self, mouse_pos)


func _end_select_interaction(mouse_pos: Vector2, additive: bool) -> void:
	SelectionFeature._end_select_interaction(self, mouse_pos, additive)


func _build_environment() -> void:
	EnvironmentFeature._build_environment(self)


func bind(p_board: BoardDocument, p_library: AssetLibrary, p_factory: SurfaceMaterialFactory, p_undo: EditorUndoRedoManager) -> void:
	BindingFeature.bind(self, p_board, p_library, p_factory, p_undo)


func bind_particles(
	p_library: ParticleEffectLibrary,
	p_undo: EditorUndoRedoManager
) -> void:
	BindingFeature.bind_particles(self, p_library, p_undo)


func _on_board_look_changed() -> void:
	LookFeature._on_board_look_changed(self)


func apply_look() -> void:
	LookFeature.apply_look(self)


func apply_grade() -> void:
	LookFeature.apply_grade(self)


func _grade_ramp(look: AestheticProfile) -> GradientTexture1D:
	return LookFeature._grade_ramp(self, look)


func _required_world_surface_field_rect() -> Rect2:
	return WorldFieldsFeature._required_world_surface_field_rect(self)


func _required_world_surface_field_rect_for(source_board: BoardDocument) -> Rect2:
	return WorldFieldsFeature._required_world_surface_field_rect_for(self, source_board)


func _world_surface_field_rect_for_bounds(board_bounds: AABB) -> Rect2:
	return WorldFieldsFeature._world_surface_field_rect_for_bounds(self, board_bounds)


func _reset_world_surface_field_coverage() -> void:
	WorldFieldsFeature._reset_world_surface_field_coverage(self)


func _world_surface_field_resolution(required_rect: Rect2) -> Vector2i:
	return WorldFieldsFeature._world_surface_field_resolution(self, required_rect)


func _ensure_world_surface_field_coverage() -> bool:
	return WorldFieldsFeature._ensure_world_surface_field_coverage(self)


func _placement_spatial_signature(placement_record: Resource) -> String:
	return SynchronizationFeature._placement_spatial_signature(self, placement_record)


func rebuild_board(frame_after: bool = false) -> void:
	SynchronizationFeature.rebuild_board(self, frame_after)


func _sync_board_incremental(
	mutation_mask: int = PlacementController.BoardMutation.ALL
) -> void:
	SynchronizationFeature._sync_board_incremental(self, mutation_mask)

func _sync_contact_prop_nodes(
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement]
) -> Dictionary:
	return RegionalUpdatesFeature._sync_contact_prop_nodes(self, support_props, added_props, removed_props)


func _refresh_world_contacts_for_terrain_regions(
	regions: Array[Rect2i],
	removed_prop_contact_ids: PackedStringArray,
	props_to_stamp: Array[PropPlacement]
) -> void:
	RegionalUpdatesFeature._refresh_world_contacts_for_terrain_regions(self, regions, removed_prop_contact_ids, props_to_stamp)


func _discard_released_terrain_paint(released: PackedStringArray) -> void:
	RegionalUpdatesFeature._discard_released_terrain_paint(self, released)


func _refresh_gameplay_markers_for_terrain_regions(
	regions: Array[Rect2i]
) -> void:
	RegionalUpdatesFeature._refresh_gameplay_markers_for_terrain_regions(self, regions)


func _refresh_particle_effects_for_terrain_regions(
	regions: Array[Rect2i]
) -> void:
	RegionalUpdatesFeature._refresh_particle_effects_for_terrain_regions(self, regions)


func _refresh_regional_material_height_range() -> void:
	RegionalUpdatesFeature._refresh_regional_material_height_range(self)


func _sync_prop_terrain_regions(
	regions: Array[Rect2i],
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	terrain_paint_uids: PackedStringArray
) -> void:
	RegionalUpdatesFeature._sync_prop_terrain_regions(self, regions, support_props, added_props, removed_props, terrain_paint_uids)


func refresh_board_changes() -> void:
	AssetUpdatesFeature.refresh_board_changes(self)


func refresh_asset_instances(
	asset_id: String,
	geometry_changed: bool = false
) -> void:
	AssetUpdatesFeature.refresh_asset_instances(self, asset_id, geometry_changed)


func _refresh_terrain_materials_for_asset(asset_id: String) -> void:
	AssetUpdatesFeature._refresh_terrain_materials_for_asset(self, asset_id)


func _terrain_surface_uses_asset(
	surface: Dictionary,
	asset_id: String,
	used_palette_indices: Dictionary
) -> bool:
	return AssetUpdatesFeature._terrain_surface_uses_asset(self, surface, asset_id, used_palette_indices)


func apply_asset_contact_flatten(asset_id: String) -> int:
	return AssetUpdatesFeature.apply_asset_contact_flatten(self, asset_id)


func refresh_gameplay_visuals() -> void:
	GameplayFeature.refresh_gameplay_visuals(self)


func refresh_level_asset_references() -> void:
	GameplayFeature.refresh_level_asset_references(self)


func _sync_gameplay_marker_mutation() -> void:
	GameplayFeature._sync_gameplay_marker_mutation(self)


func _sync_particle_effect_mutation() -> void:
	GameplayFeature._sync_particle_effect_mutation(self)


func _particle_effect_position(placement_record: ParticleEffectPlacement) -> Vector3:
	return GameplayFeature._particle_effect_position(self, placement_record)

func _rebuild_particle_effect_visuals() -> void:
	GameplayFeature._rebuild_particle_effect_visuals(self)


func refresh_particle_effects() -> void:
	GameplayFeature.refresh_particle_effects(self)


func _rebuild_gameplay_marker_visuals() -> void:
	GameplayFeature._rebuild_gameplay_marker_visuals(self)


func _build_enemy_pack_net(
	pack: EnemyPack,
	members: Array,
	layer_y: int
) -> Node3D:
	return GameplayFeature._build_enemy_pack_net(self, pack, members, layer_y)


func _add_enemy_pack_net_segment(
	immediate_mesh: ImmediateMesh,
	start: Vector3,
	end: Vector3,
	width: float
) -> void:
	GameplayFeature._add_enemy_pack_net_segment(self, immediate_mesh, start, end, width)


func _marker_stand_position(marker: GameplayMarker) -> Vector3:
	return GameplayFeature._marker_stand_position(self, marker)


func _build_gameplay_marker_visual(marker: GameplayMarker) -> Node3D:
	return GameplayFeature._build_gameplay_marker_visual(self, marker)


func _instantiate_monster_visual(monster_id: String, asset: TileAsset) -> Node3D:
	return GameplayFeature._instantiate_monster_visual(self, monster_id, asset)


func _add_gameplay_marker_label(
	root: Node3D,
	title: String,
	color: Color,
	height_m: float
) -> void:
	GameplayFeature._add_gameplay_marker_label(self, root, title, color, height_m)
func _rebuild_world_contacts() -> void:
	WorldContactsFeature._rebuild_world_contacts(self)
func _rebuild_world_contact_textures() -> bool:
	return WorldContactsFeature._rebuild_world_contact_textures(self)
func _update_world_contacts(
	added_surfaces: Array[SurfacePlacement],
	removed_prop_contact_ids: PackedStringArray,
	added_props: Array[PropPlacement]
) -> void:
	WorldContactsFeature._update_world_contacts(self, added_surfaces, removed_prop_contact_ids, added_props)


func _terrain_cells_for_surface(surface: SurfacePlacement) -> Array[Vector2i]:
	return WorldContactsFeature._terrain_cells_for_surface(self, surface)


func _build_surface_node(
	surface: SurfacePlacement,
	asset: TileAsset
) -> Node3D:
	return SurfacesFeature._build_surface_node(self, surface, asset)


func _decal_projection_depth_m(
	surface: SurfacePlacement,
	local_surface_transform: Transform3D,
	outward_normal: Vector3
) -> float:
	return SurfacesFeature._decal_projection_depth_m(self, surface, local_surface_transform, outward_normal)


func _build_decal_node(
	surface: SurfacePlacement,
	asset: TileAsset,
	local_surface_transform: Transform3D
) -> Decal:
	return SurfacesFeature._build_decal_node(self, surface, asset, local_surface_transform)


func _configure_native_decal(
	decal: Decal,
	surface: SurfacePlacement,
	asset: TileAsset
) -> bool:
	return SurfacesFeature._configure_native_decal(self, decal, surface, asset)


func _native_decal_palette_adjustment(surface: SurfacePlacement) -> Dictionary:
	return SurfacesFeature._native_decal_palette_adjustment(self, surface)


func _shader_decal_palette_adjustment(surface: SurfacePlacement) -> Dictionary:
	return SurfacesFeature._shader_decal_palette_adjustment(self, surface)


func _refresh_material_mask_ranges(update_existing_materials: bool = true) -> void:
	MaterialPreviewFeature._refresh_material_mask_ranges(self, update_existing_materials)


func _all_surface_shader_materials() -> Array[ShaderMaterial]:
	return MaterialPreviewFeature._all_surface_shader_materials(self)

func set_material_mask_preview(enabled: bool, palette_index: int) -> void:
	MaterialPreviewFeature.set_material_mask_preview(self, enabled, palette_index)

func _apply_material_mask_preview_to_material(material: ShaderMaterial) -> void:
	MaterialPreviewFeature._apply_material_mask_preview_to_material(self, material)


func _refresh_material_paint_batch(batch_key: String) -> void:
	MaterialPreviewFeature._refresh_material_paint_batch(self, batch_key)

func _on_material_palette_slots_changed(placement_uid: String) -> void:
	MaterialPreviewFeature._on_material_palette_slots_changed(self, placement_uid)


func _flush_material_palette_slot_changes() -> void:
	MaterialPreviewFeature._flush_material_palette_slot_changes(self)


func assign_material_palette_to_all_faces(palette_index: int) -> Dictionary:
	return MaterialProfilesFeature.assign_material_palette_to_all_faces(self, palette_index)


func refresh_material_blend_materials() -> void:
	MaterialProfilesFeature.refresh_material_blend_materials(self)


func refresh_material_profile_change(
	before_json: Dictionary,
	splatmap_projection_already_valid: bool = false
) -> bool:
	return MaterialProfilesFeature.refresh_material_profile_change(self, before_json, splatmap_projection_already_valid)


static func _material_layer_requires_texture_rebind(
	before_layer: Dictionary,
	after_layer: Dictionary
) -> bool:
	return MaterialProfilesFeature._material_layer_requires_texture_rebind(before_layer, after_layer)


static func _material_layer_uses_world_height(material_layer: Dictionary) -> bool:
	return MaterialProfilesFeature._material_layer_uses_world_height(material_layer)


func _used_palette_indices_for_profile(
	candidate_profile: MaterialBlendProfile
) -> PackedInt32Array:
	return MaterialProfilesFeature._used_palette_indices_for_profile(self, candidate_profile)


func _reconfigure_existing_material_blends(
	palette_indices: PackedInt32Array = PackedInt32Array()
) -> void:
	MaterialProfilesFeature._reconfigure_existing_material_blends(self, palette_indices)


func _refresh_splatmap_material_controls() -> void:
	MaterialProfilesFeature._refresh_splatmap_material_controls(self)


func refresh_thin_side_texture_seeds() -> void:
	MaterialProfilesFeature.refresh_thin_side_texture_seeds(self)


func refresh_material_blend_layer_controls(layer_index: int) -> void:
	MaterialProfilesFeature.refresh_material_blend_layer_controls(self, layer_index)

func clear_surface_material_paint(record_undo: bool = false) -> void:
	MaterialProfilesFeature.clear_surface_material_paint(self, record_undo)


func _palette_index_for_splat_asset(
	profile: MaterialBlendProfile,
	asset_id: String
) -> int:
	return SplatmapImportFeature._palette_index_for_splat_asset(self, profile, asset_id)


func import_terrain_splatmap(
	source_image: Image,
	slot_asset_ids: PackedStringArray,
	source_path: String
) -> Dictionary:
	return SplatmapImportFeature.import_terrain_splatmap(self, source_image, slot_asset_ids, source_path)


func paint_entire_terrain_from_splatmap() -> bool:
	return SplatmapImportFeature.paint_entire_terrain_from_splatmap(self)


func apply_material_paint_resolution(
	texels_per_metre: int,
	maximum_edge_px: int
) -> bool:
	return PaintResolutionFeature.apply_material_paint_resolution(self, texels_per_metre, maximum_edge_px)


func _rebuild_material_paint_resolution_from_json(profile_json: Dictionary) -> void:
	PaintResolutionFeature._rebuild_material_paint_resolution_from_json(self, profile_json)


func _restore_material_paint_resolution_snapshot(
	profile_json: Dictionary,
	snapshot: Dictionary
) -> void:
	PaintResolutionFeature._restore_material_paint_resolution_snapshot(self, profile_json, snapshot)


func _commit_material_paint_resolution(
	profile_json: Dictionary,
	prepared: Dictionary
) -> bool:
	return PaintResolutionFeature._commit_material_paint_resolution(self, profile_json, prepared)


func register_material_profile_undo(
	before_json: Dictionary,
	after_json: Dictionary,
	action_name: String,
	merge_mode: int = UndoRedo.MERGE_DISABLE,
	paint_patches: Dictionary = {}
) -> void:
	PaintHistoryFeature.register_material_profile_undo(self, before_json, after_json, action_name, merge_mode, paint_patches)


func replay_material_profile_and_patches(
	profile_json: Dictionary,
	paint_patch_steps: Array,
	value_key: String,
	reverse_patches: bool = false
) -> void:
	PaintHistoryFeature.replay_material_profile_and_patches(self, profile_json, paint_patch_steps, value_key, reverse_patches)


func _apply_material_profile_json(profile_json: Dictionary) -> void:
	PaintHistoryFeature._apply_material_profile_json(self, profile_json)


func save_surface_material_paint(board_path: String) -> Dictionary:
	return DocumentLoadingFeature.save_surface_material_paint(self, board_path)


func prepare_surface_material_paint(
	board_path: String,
	metadata: Dictionary
) -> Dictionary:
	return DocumentLoadingFeature.prepare_surface_material_paint(self, board_path, metadata)


func commit_prepared_surface_material_paint(prepared: Dictionary) -> bool:
	return DocumentLoadingFeature.commit_prepared_surface_material_paint(self, prepared)


func commit_prepared_board_load(
	prepared_board: BoardDocument,
	prepared_paint: Dictionary,
	apply_prepared_look: bool = true
) -> bool:
	return DocumentLoadingFeature.commit_prepared_board_load(self, prepared_board, prepared_paint, apply_prepared_look)


func refresh_terrain() -> void:
	TerrainMaterialsFeature.refresh_terrain(self)


func set_terrain_skirt_depth(depth_m: float) -> void:
	TerrainMaterialsFeature.set_terrain_skirt_depth(self, depth_m)


func _apply_terrain_material() -> void:
	TerrainMaterialsFeature._apply_terrain_material(self)


func _splatmap_source_overlay_requested() -> bool:
	return TerrainMaterialsFeature._splatmap_source_overlay_requested(self)


func _apply_terrain_material_chunks(chunks_to_apply: Array[Vector2i]) -> void:
	TerrainMaterialsFeature._apply_terrain_material_chunks(self, chunks_to_apply)


func _terrain_surface_material(
	chunk: Vector2i,
	surface: Dictionary
) -> Material:
	return TerrainMaterialsFeature._terrain_surface_material(self, chunk, surface)


func _terrain_chunk_material(
	batch_key: String,
	asset_id: String,
	is_top: bool,
	slot_materials: PackedInt32Array
) -> Material:
	return TerrainMaterialsFeature._terrain_chunk_material(self, batch_key, asset_id, is_top, slot_materials)


func _configure_terrain_grid_material(material: Material, is_top: bool) -> Material:
	return TerrainMaterialsFeature._configure_terrain_grid_material(self, material, is_top)


func terrain_chunk_cells() -> int:
	return TerrainLifecycleFeature.terrain_chunk_cells(self)


func terrain_summary_counts() -> Dictionary:
	return TerrainLifecycleFeature.terrain_summary_counts(self)


func terrain_cached_height_range() -> Vector2:
	return TerrainLifecycleFeature.terrain_cached_height_range(self)


func adopt_imported_terrain(imported: TerrainMesh) -> bool:
	return TerrainLifecycleFeature.adopt_imported_terrain(self, imported)


func _apply_terrain_grid(grid: TerrainMesh) -> void:
	TerrainLifecycleFeature._apply_terrain_grid(self, grid)


func clear_terrain() -> void:
	TerrainLifecycleFeature.clear_terrain(self)


func reset_world_heightfield() -> void:
	TerrainLifecycleFeature.reset_world_heightfield(self)


func configure_world_surface_fields(origin_xz: Vector2, size_xz: Vector2, resolution: Vector2i = Vector2i(1024, 1024)) -> void:
	WorldContactsFeature.configure_world_surface_fields(self, origin_xz, size_xz, resolution)


func _on_world_surface_fields_changed(_kind: String) -> void:
	WorldContactsFeature._on_world_surface_fields_changed(self, _kind)


func _prop_contact_id(prop: PropPlacement) -> String:
	return WorldContactsFeature._prop_contact_id(self, prop)


func _stamp_wall_floor_contacts(upload: bool = true) -> void:
	WorldContactsFeature._stamp_wall_floor_contacts(self, upload)


func _wall_contact_segment(cell: Vector3i, face: int) -> PackedVector2Array:
	return WorldContactsFeature._wall_contact_segment(self, cell, face)
func _stamp_prop_contact(prop: PropPlacement, asset: TileAsset, upload: bool = true) -> void:
	WorldContactsFeature._stamp_prop_contact(self, prop, asset, upload)


func _prop_contact_cache_key(prop: PropPlacement, asset: TileAsset) -> String:
	return ContactGeometryFeature._prop_contact_cache_key(self, prop, asset)


func _prop_contact_polygons(prop: PropPlacement, asset: TileAsset) -> Array[PackedVector2Array]:
	return ContactGeometryFeature._prop_contact_polygons(self, prop, asset)
func _build_local_prop_contact_polygons(
	prop: PropPlacement,
	asset: TileAsset
) -> Array[PackedVector2Array]:
	return ContactGeometryFeature._build_local_prop_contact_polygons(self, prop, asset)


func _contact_polygon_quantum_m() -> float:
	return ContactGeometryFeature._contact_polygon_quantum_m(self)


func _compact_contact_polygons(
	polygons: Array[PackedVector2Array],
	quantum_m: float
) -> Array[PackedVector2Array]:
	return ContactGeometryFeature._compact_contact_polygons(self, polygons, quantum_m)


func _collect_transformed_mesh_triangles(
	node: Node,
	parent_transform: Transform3D,
	out_triangles: Array[PackedVector3Array]
) -> void:
	ContactGeometryFeature._collect_transformed_mesh_triangles(self, node, parent_transform, out_triangles)


func _clip_triangle_below_y(triangle: PackedVector3Array, maximum_y: float) -> PackedVector3Array:
	return ContactGeometryFeature._clip_triangle_below_y(self, triangle, maximum_y)


func _prop_model_for_asset(asset: TileAsset) -> Node3D:
	return PropSupportFeature._prop_model_for_asset(self, asset)


func _prop_placement_base_position(prop: PropPlacement) -> Vector3:
	return PropSupportFeature._prop_placement_base_position(self, prop)


func _prop_base_position(root: Node3D) -> Vector3:
	return PropSupportFeature._prop_base_position(self, root)


func _prop_slice_level(prop: PropPlacement) -> int:
	return PropSupportFeature._prop_slice_level(self, prop)


func _apply_prop_support_offset(root: Node3D) -> bool:
	return PropSupportFeature._apply_prop_support_offset(self, root)


func _sync_prop_support_offsets() -> void:
	PropSupportFeature._sync_prop_support_offsets(self)


func _surface_bounds(surface: SurfacePlacement, _asset: TileAsset) -> AABB:
	return PropNodesFeature._surface_bounds(self, surface, _asset)


func _build_prop_node(
	prop: PropPlacement,
	asset: TileAsset
) -> Node3D:
	return PropNodesFeature._build_prop_node(self, prop, asset)


func _prop_batch_keys(prop: PropPlacement, asset: TileAsset) -> PackedStringArray:
	return PropBatchesFeature._prop_batch_keys(self, prop, asset)


func _rebuild_prop_art_batches() -> void:
	PropBatchesFeature._rebuild_prop_art_batches(self)


func _sync_prop_art_batches(affected_keys: Dictionary = {}) -> void:
	PropBatchesFeature._sync_prop_art_batches(self, affected_keys)


func _collect_prop_batch_groups(affected_keys: Dictionary = {}) -> Dictionary:
	return PropBatchesFeature._collect_prop_batch_groups(self, affected_keys)


func _prop_mesh_components(source_model: Node3D) -> Array[Dictionary]:
	return PropBatchesFeature._prop_mesh_components(self, source_model)


func _append_prop_mesh_components(
	node: Node,
	parent_transform: Transform3D,
	parent_visible: bool,
	components: Array[Dictionary]
) -> void:
	PropBatchesFeature._append_prop_mesh_components(self, node, parent_transform, parent_visible, components)


func _prop_render_mesh(source: MeshInstance3D) -> Mesh:
	return PropBatchesFeature._prop_render_mesh(self, source)


func _prop_batch_material(source: MeshInstance3D, surface_index: int) -> Material:
	return PropBatchesFeature._prop_batch_material(self, source, surface_index)


func _prop_batch_key(prop: PropPlacement, asset: TileAsset, source_mesh: MeshInstance3D) -> String:
	return PropBatchesFeature._prop_batch_key(self, prop, asset, source_mesh)


func _configure_prop_batch(
	batch: MultiMeshInstance3D,
	key: String,
	group: Dictionary
) -> void:
	PropBatchesFeature._configure_prop_batch(self, batch, key, group)


func _set_cast_shadow_recursive(node: Node, setting: int) -> void:
	RendererSettingsFeature._set_cast_shadow_recursive(self, node, setting)


func _backface_culling_enabled() -> bool:
	return RendererSettingsFeature._backface_culling_enabled(self)


func _visible_shadow_cast_setting() -> int:
	return RendererSettingsFeature._visible_shadow_cast_setting(self)


func _current_renderer_settings_signature() -> String:
	return RendererSettingsFeature._current_renderer_settings_signature(self)


func _apply_renderer_settings_to_existing_geometry() -> void:
	RendererSettingsFeature._apply_renderer_settings_to_existing_geometry(self)


func _set_backface_culling_recursive(node: Node, enabled: bool) -> void:
	RendererSettingsFeature._set_backface_culling_recursive(self, node, enabled)


func _set_mesh_backface_culling(mesh_instance: MeshInstance3D, enabled: bool) -> void:
	RendererSettingsFeature._set_mesh_backface_culling(self, mesh_instance, enabled)


func refresh_brush_preview() -> void:
	VisibilityFeature.refresh_brush_preview(self)


func _apply_slice() -> void:
	VisibilityFeature._apply_slice(self)


func _apply_slice_to_node(node: Node3D) -> void:
	VisibilityFeature._apply_slice_to_node(self, node)


func set_movement_grid_mode(active: bool) -> void:
	MovementGridFeature.set_movement_grid_mode(self, active)


func movement_grid_mode_active() -> bool:
	return MovementGridFeature.movement_grid_mode_active(self)


func set_movement_grid_tool(tool: int) -> void:
	MovementGridFeature.set_movement_grid_tool(self, tool)


func set_movement_ground_effect_label(label: String) -> void:
	MovementGridFeature.set_movement_ground_effect_label(self, label)


func apply_movement_collision_threshold(threshold_percent: float) -> Dictionary:
	return MovementGridFeature.apply_movement_collision_threshold(self, threshold_percent)


func _apply_movement_collision_threshold(threshold_percent: float) -> void:
	MovementGridFeature._apply_movement_collision_threshold(self, threshold_percent)


func refresh_movement_grid_collision() -> void:
	MovementGridFeature.refresh_movement_grid_collision(self)


func _handle_movement_grid_input(event: InputEvent) -> bool:
	return MovementGridFeature._handle_movement_grid_input(self, event)


func _movement_grid_hit(mouse_position: Vector2) -> Dictionary:
	return MovementGridFeature._movement_grid_hit(self, mouse_position)


func _update_movement_grid_hover(mouse_position: Vector2) -> void:
	MovementGridFeature._update_movement_grid_hover(self, mouse_position)


func _commit_movement_grid_cell(mouse_position: Vector2) -> void:
	MovementGridFeature._commit_movement_grid_cell(self, mouse_position)


func _apply_movement_cell_state(cell: Vector2i, state: Dictionary) -> void:
	MovementGridFeature._apply_movement_cell_state(self, cell, state)


func set_occupancy_mode(p_mode: int) -> void:
	VisibilityFeature.set_occupancy_mode(self, p_mode)


func occupancy_mode_name() -> String:
	return VisibilityFeature.occupancy_mode_name(self)


func set_slice_mode(mode: int) -> void:
	VisibilityFeature.set_slice_mode(self, mode)


func set_painting_light_override_enabled(enabled: bool) -> void:
	LightingFeature.set_painting_light_override_enabled(self, enabled)


func _apply_painting_light_override() -> void:
	LightingFeature._apply_painting_light_override(self)


func apply_lighting_profile() -> void:
	LightingFeature.apply_lighting_profile(self)

func _rebuild_reflection_probe(profile: LightingProfile) -> void:
	LightingFeature._rebuild_reflection_probe(self, profile)


func _rebuild_local_lights(profile: LightingProfile) -> void:
	LightingFeature._rebuild_local_lights(self, profile)


func set_light_handles_visible(visible: bool) -> void:
	LightHandlesFeature.set_light_handles_visible(self, visible)


func begin_local_light_placement() -> void:
	LightHandlesFeature.begin_local_light_placement(self)


func select_local_light_handle(index: int) -> void:
	LightHandlesFeature.select_local_light_handle(self, index)


func _sync_light_handles_from_profile() -> void:
	LightHandlesFeature._sync_light_handles_from_profile(self)


func _create_light_handle(light_index: int) -> Node3D:
	return LightHandlesFeature._create_light_handle(self, light_index)


func _update_light_handle_transform(light_index: int) -> void:
	LightHandlesFeature._update_light_handle_transform(self, light_index)


func _refresh_light_handle_appearance() -> void:
	LightHandlesFeature._refresh_light_handle_appearance(self)


func _make_light_handle_material(
	color: Color,
	alpha: float,
	emission_energy: float
) -> StandardMaterial3D:
	return LightHandlesFeature._make_light_handle_material(self, color, alpha, emission_energy)


func _clear_light_handles() -> void:
	LightHandlesFeature._clear_light_handles(self)


func _handle_light_handle_input(event: InputEvent) -> bool:
	return LightInteractionFeature._handle_light_handle_input(self, event)


func _place_local_light_on_surface(screen_position: Vector2) -> bool:
	return LightInteractionFeature._place_local_light_on_surface(self, screen_position)


func _begin_light_handle_drag(screen_position: Vector2) -> bool:
	return LightInteractionFeature._begin_light_handle_drag(self, screen_position)


func _continue_light_handle_drag(screen_position: Vector2) -> void:
	LightInteractionFeature._continue_light_handle_drag(self, screen_position)


func _finish_light_handle_drag() -> void:
	LightInteractionFeature._finish_light_handle_drag(self)


func _apply_authored_light_transform(
	light_index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	LightInteractionFeature._apply_authored_light_transform(self, light_index, surface_position, height_offset)


func _preview_local_light_transform(
	light_index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	LightInteractionFeature._preview_local_light_transform(self, light_index, surface_position, height_offset)


func _local_light_surface_hit(screen_position: Vector2) -> Dictionary:
	return LightInteractionFeature._local_light_surface_hit(self, screen_position)


func _pick_light_handle(screen_position: Vector2) -> int:
	return LightInteractionFeature._pick_light_handle(self, screen_position)


func _authored_light_surface_position(light_index: int) -> Vector3:
	return LightInteractionFeature._authored_light_surface_position(self, light_index)


func _authored_light_height_offset(light_index: int) -> float:
	return LightInteractionFeature._authored_light_height_offset(self, light_index)


func _light_name(light_index: int) -> String:
	return LightInteractionFeature._light_name(self, light_index)


func _profile() -> LightingProfile:
	return LightInteractionFeature._profile(self)


func set_camera_mode(camera_mode: int) -> void:
	ToolModesFeature.set_camera_mode(self, camera_mode)


func _refresh_placement_visibility() -> void:
	ToolModesFeature._refresh_placement_visibility(self)


func set_tool(p_tool: int) -> void:
	ToolModesFeature.set_tool(self, p_tool)


func set_fill_shape(fill_shape: int) -> void:
	ToolModesFeature.set_fill_shape(self, fill_shape)


func _on_tool_changed(tool: int) -> void:
	ToolModesFeature._on_tool_changed(self, tool)


func is_erasing() -> bool:
	return ToolModesFeature.is_erasing(self)


func set_grid_visible(value: bool) -> void:
	ToolModesFeature.set_grid_visible(self, value)


func set_lattice_visible(value: bool) -> void:
	ToolModesFeature.set_lattice_visible(self, value)


func _refresh_terrain_grid_visibility() -> void:
	ToolModesFeature._refresh_terrain_grid_visibility(self)


func set_particle_effect_mode(enabled: bool) -> void:
	ToolModesFeature.set_particle_effect_mode(self, enabled)


func set_particle_effect_preset(preset_id: String) -> void:
	ToolModesFeature.set_particle_effect_preset(self, preset_id)


func set_particle_effect_attachment(attachment: int) -> void:
	ToolModesFeature.set_particle_effect_attachment(self, attachment)


func set_particle_effect_erase_mode(enabled: bool) -> void:
	ToolModesFeature.set_particle_effect_erase_mode(self, enabled)


func set_gameplay_marker_mode(enabled: bool) -> void:
	ToolModesFeature.set_gameplay_marker_mode(self, enabled)


func set_gameplay_marker_brush(
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> void:
	ToolModesFeature.set_gameplay_marker_brush(self, marker_type, note, monster_id, pack_id)


func set_height_sculpt_tool(tool: int) -> void:
	SculptSettingsFeature.set_height_sculpt_tool(self, tool)


func _sync_terrain_fill_arming(p_placement_tool: int = -1) -> void:
	SculptSettingsFeature._sync_terrain_fill_arming(self, p_placement_tool)


func _commit_terrain_fill(origins: Array[Vector3i]) -> void:
	SculptSettingsFeature._commit_terrain_fill(self, origins)


func _sample_terrain_flatten_target(origins: Array[Vector3i]) -> float:
	return SculptSettingsFeature._sample_terrain_flatten_target(self, origins)


func _commit_footprint_fill(origins: Array[Vector3i]) -> void:
	SculptSettingsFeature._commit_footprint_fill(self, origins)


func set_terrain_protect_walls(enabled: bool) -> void:
	SculptSettingsFeature.set_terrain_protect_walls(self, enabled)


func set_terrain_step(step_m: float) -> void:
	SculptSettingsFeature.set_terrain_step(self, step_m)


func set_height_brush_strength(strength: float) -> void:
	SculptSettingsFeature.set_height_brush_strength(self, strength)


func set_footprint_tool(tool: int) -> void:
	SculptSettingsFeature.set_footprint_tool(self, tool)


func footprint_tool_name() -> String:
	return SculptSettingsFeature.footprint_tool_name(self)


func height_sculpt_tool_name() -> String:
	return SculptSettingsFeature.height_sculpt_tool_name(self)


func _height_brush_pick(mouse_pos: Vector2) -> Dictionary:
	return SculptPreviewFeature._height_brush_pick(self, mouse_pos)


func _build_height_brush_preview() -> void:
	SculptPreviewFeature._build_height_brush_preview(self)


func _hide_height_brush_preview() -> void:
	SculptPreviewFeature._hide_height_brush_preview(self)


func _update_active_terrain_brush_preview(mouse_position: Vector2) -> Dictionary:
	return SculptPreviewFeature._update_active_terrain_brush_preview(self, mouse_position)


func _update_height_brush_preview(mouse_position: Vector2) -> Dictionary:
	return SculptPreviewFeature._update_height_brush_preview(self, mouse_position)


func _draw_height_brush_preview(pick: Dictionary) -> void:
	SculptPreviewFeature._draw_height_brush_preview(self, pick)


func _draw_height_cell_targets(
	immediate_mesh: ImmediateMesh,
	targets: PackedVector2Array,
	valid: bool = true
) -> void:
	SculptPreviewFeature._draw_height_cell_targets(self, immediate_mesh, targets, valid)


func _height_preview_cell_points(cell: Vector2i) -> PackedVector3Array:
	return SculptPreviewFeature._height_preview_cell_points(self, cell)


func _bind_terrain_sculptor() -> void:
	SculptStrokesFeature._bind_terrain_sculptor(self)


func _push_terrain_brush_settings(flatten_target_m: float = 0.0) -> void:
	SculptStrokesFeature._push_terrain_brush_settings(self, flatten_target_m)


func _sculptor_mode_for_tool(tool: int) -> int:
	return SculptStrokesFeature._sculptor_mode_for_tool(self, tool)


func _begin_height_sculpt(mouse_pos: Vector2) -> void:
	SculptStrokesFeature._begin_height_sculpt(self, mouse_pos)

func _queue_height_sculpt_motion(mouse_pos: Vector2) -> void:
	SculptStrokesFeature._queue_height_sculpt_motion(self, mouse_pos)


func _flush_pending_height_sculpt_motion() -> void:
	SculptStrokesFeature._flush_pending_height_sculpt_motion(self)


func _continue_height_sculpt(mouse_pos: Vector2) -> void:
	SculptStrokesFeature._continue_height_sculpt(self, mouse_pos)


func _end_height_sculpt() -> void:
	SculptStrokesFeature._end_height_sculpt(self)

func _refresh_dynamic_skirt(previous_base_m: float) -> void:
	SculptStrokesFeature._refresh_dynamic_skirt(self, previous_base_m)


func _register_terrain_sculpt_undo(stroke: Dictionary) -> void:
	SculptStrokesFeature._register_terrain_sculpt_undo(self, stroke)


func _apply_terrain_sculpt_patch(
	cells: PackedVector2Array,
	tops: PackedFloat32Array,
	sides: Dictionary
) -> void:
	SculptStrokesFeature._apply_terrain_sculpt_patch(self, cells, tops, sides)

func _apply_height_sculpt_stamp(world_xz: Vector2) -> void:
	SculptStrokesFeature._apply_height_sculpt_stamp(self, world_xz)

func _apply_height_sculpt_segment(start_world_xz: Vector2, end_world_xz: Vector2) -> void:
	SculptStrokesFeature._apply_height_sculpt_segment(self, start_world_xz, end_world_xz)

func _accumulate_terrain_dirty_cells(touched: Rect2i) -> void:
	SculptStrokesFeature._accumulate_terrain_dirty_cells(self, touched)


func _preview_terrain_stroke(affected_cells: Rect2i) -> void:
	SculptStrokesFeature._preview_terrain_stroke(self, affected_cells)


func _reconcile_terrain_paint(affected_cells: Rect2i = Rect2i()) -> void:
	SculptStrokesFeature._reconcile_terrain_paint(self, affected_cells)


func _finalize_terrain_region() -> void:
	SculptStrokesFeature._finalize_terrain_region(self)

func _footprint_pick(mouse_pos: Vector2) -> Dictionary:
	return FootprintFeature._footprint_pick(self, mouse_pos)


func _footprint_targets(
	start_world_xz: Vector2,
	end_world_xz: Vector2
) -> PackedVector2Array:
	return FootprintFeature._footprint_targets(self, start_world_xz, end_world_xz)


func _update_footprint_brush_preview(mouse_position: Vector2) -> Dictionary:
	return FootprintFeature._update_footprint_brush_preview(self, mouse_position)


func _draw_footprint_brush_preview(pick: Dictionary) -> void:
	FootprintFeature._draw_footprint_brush_preview(self, pick)


func _begin_footprint_stroke(mouse_pos: Vector2, erase: bool) -> void:
	FootprintFeature._begin_footprint_stroke(self, mouse_pos, erase)

func _continue_footprint_stroke(mouse_pos: Vector2) -> void:
	FootprintFeature._continue_footprint_stroke(self, mouse_pos)


func _apply_footprint_targets(targets: PackedVector2Array) -> void:
	FootprintFeature._apply_footprint_targets(self, targets)

func _end_footprint_stroke() -> void:
	FootprintFeature._end_footprint_stroke(self)

func _apply_footprint_patch(
	cells: PackedVector2Array,
	values: PackedByteArray
) -> void:
	FootprintFeature._apply_footprint_patch(self, cells, values)

func _build_material_brush_preview() -> void:
	MaterialBrushFeature._build_material_brush_preview(self)


func _hide_material_brush_preview() -> void:
	MaterialBrushFeature._hide_material_brush_preview(self)


func _update_material_brush_preview(mouse_position: Vector2) -> Dictionary:
	return MaterialBrushFeature._update_material_brush_preview(self, mouse_position)


func _rebuild_material_brush_preview_mesh(radius_m: float) -> void:
	MaterialBrushFeature._rebuild_material_brush_preview_mesh(self, radius_m)


func _draw_material_brush_preview(hit: Dictionary) -> void:
	MaterialBrushFeature._draw_material_brush_preview(self, hit)


func arm_native_decal_brush(
	asset: TileAsset,
	match_underlying_palette: bool,
	edge_mode_enabled: bool = false
) -> void:
	MaterialBrushFeature.arm_native_decal_brush(self, asset, match_underlying_palette, edge_mode_enabled)


func arm_shader_decal_brush(
	asset: TileAsset,
	match_underlying_palette: bool,
	edge_mode_enabled: bool = false
) -> void:
	MaterialBrushFeature.arm_shader_decal_brush(self, asset, match_underlying_palette, edge_mode_enabled)


func disarm_native_decal_brush() -> void:
	MaterialBrushFeature.disarm_native_decal_brush(self)


func set_material_paint_tool(tool: int) -> void:
	MaterialBrushFeature.set_material_paint_tool(self, tool)


func set_surface_grid_stroke_size(size_m: float) -> void:
	MaterialBrushFeature.set_surface_grid_stroke_size(self, size_m)


func set_material_brush_radius(radius_m: float) -> void:
	MaterialBrushFeature.set_material_brush_radius(self, radius_m)


func set_material_brush_opacity(opacity: float) -> void:
	MaterialBrushFeature.set_material_brush_opacity(self, opacity)


func set_material_brush_hardness(hardness: float) -> void:
	MaterialBrushFeature.set_material_brush_hardness(self, hardness)


func set_material_brush_palette_index(palette_index: int) -> void:
	MaterialBrushFeature.set_material_brush_palette_index(self, palette_index)


func set_material_layer_brush_asset(asset: TileAsset) -> void:
	MaterialBrushFeature.set_material_layer_brush_asset(self, asset)


func clear_material_layer_brush_asset() -> void:
	MaterialBrushFeature.clear_material_layer_brush_asset(self)


func material_layer_rotation_quarters() -> int:
	return MaterialBrushFeature.material_layer_rotation_quarters(self)


static func _splatmap_face_for_projection(projection: int) -> int:
	return MaterialBrushFeature._splatmap_face_for_projection(projection)


func _splatmap_projection_face() -> int:
	return SplatmapProjectionFeature._splatmap_projection_face(self)


func splatmap_projection_available(projection: int) -> bool:
	return SplatmapProjectionFeature.splatmap_projection_available(self, projection)


func refresh_splatmap_projection() -> bool:
	return SplatmapProjectionFeature.refresh_splatmap_projection(self)


func refresh_splatmap_live_settings(rebuild_source: bool) -> bool:
	return SplatmapProjectionFeature.refresh_splatmap_live_settings(self, rebuild_source)


func _invalidate_splatmap_projection() -> void:
	SplatmapProjectionFeature._invalidate_splatmap_projection(self)


func _splatmap_active_channels() -> PackedByteArray:
	return SplatmapProjectionFeature._splatmap_active_channels(self)


func _build_splatmap_projection_cache(
	prepared_source: Image,
	targets: Array[Dictionary],
	bounds_result: Dictionary,
	active_channels: PackedByteArray
) -> Dictionary:
	return SplatmapProjectionFeature._build_splatmap_projection_cache(self, prepared_source, targets, bounds_result, active_channels)


func _install_splatmap_projection_cache(cache: Dictionary) -> void:
	SplatmapProjectionFeature._install_splatmap_projection_cache(self, cache)


func _ensure_splatmap_projection() -> bool:
	return SplatmapProjectionFeature._ensure_splatmap_projection(self)


func _splatmap_tile_weights(projection_cell: Vector2i) -> Image:
	return SplatmapProjectionFeature._splatmap_tile_weights(self, projection_cell)


func set_splatmap_tile_paint_enabled(enabled: bool) -> void:
	MaterialTargetsFeature.set_splatmap_tile_paint_enabled(self, enabled)


func set_material_tile_paint_enabled(enabled: bool) -> void:
	MaterialTargetsFeature.set_material_tile_paint_enabled(self, enabled)


func _refresh_terrain_material_tile_targeter() -> void:
	MaterialTargetsFeature._refresh_terrain_material_tile_targeter(self)


func _validate_material_tile_targets(
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool
) -> Dictionary:
	return MaterialTargetsFeature._validate_material_tile_targets(self, target_uids, erase, _replace_existing)


func _validate_splatmap_tile_targets(
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool
) -> Dictionary:
	return MaterialTargetsFeature._validate_splatmap_tile_targets(self, target_uids, erase, _replace_existing)


func _begin_terrain_material_tile_stroke() -> bool:
	return MaterialTargetsFeature._begin_terrain_material_tile_stroke(self)


func _end_terrain_material_tile_stroke() -> void:
	MaterialTargetsFeature._end_terrain_material_tile_stroke(self)


func _on_terrain_material_tile_paint_requested(
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool,
	finish_stroke: bool
) -> void:
	MaterialTargetsFeature._on_terrain_material_tile_paint_requested(self, target_uids, erase, _replace_existing, finish_stroke)


func set_material_pressure_controls(size_enabled: bool, opacity_enabled: bool) -> void:
	MaterialStrokesFeature.set_material_pressure_controls(self, size_enabled, opacity_enabled)


func _material_surface_hit(mouse_position: Vector2) -> Dictionary:
	return MaterialStrokesFeature._material_surface_hit(self, mouse_position)


func _terrain_paint_hit(ray_origin: Vector3, _ray_end: Vector3) -> Dictionary:
	return MaterialStrokesFeature._terrain_paint_hit(self, ray_origin, _ray_end)


func _terrain_surface_stamps(
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	return MaterialStrokesFeature._terrain_surface_stamps(self, start_world, end_world, radius_m)


func _material_surface_stamps(
	reference_hit: Dictionary,
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	return MaterialStrokesFeature._material_surface_stamps(self, reference_hit, start_world, end_world, radius_m)


func _begin_material_paint(
	mouse_position: Vector2,
	pressure: float = 1.0,
	force_erase: bool = false,
	prepared_hit: Dictionary = {}
) -> void:
	MaterialStrokesFeature._begin_material_paint(self, mouse_position, pressure, force_erase, prepared_hit)


func _continue_material_paint(
	mouse_position: Vector2,
	pressure: float,
	pen_inverted: bool,
	prepared_hit: Dictionary = {}
) -> void:
	MaterialStrokesFeature._continue_material_paint(self, mouse_position, pressure, pen_inverted, prepared_hit)


func _flush_pending_material_paint() -> void:
	MaterialStrokesFeature._flush_pending_material_paint(self)


func _apply_material_paint_hit(
	mouse_position: Vector2,
	pressure: float,
	force_erase: bool,
	prepared_hit: Dictionary = {}
) -> void:
	MaterialStrokesFeature._apply_material_paint_hit(self, mouse_position, pressure, force_erase, prepared_hit)

func _end_material_paint() -> void:
	MaterialStrokesFeature._end_material_paint(self)


func _register_material_paint_undo(
	stroke: Dictionary,
	action_name: String = ""
) -> void:
	MaterialStrokesFeature._register_material_paint_undo(self, stroke, action_name)


func _apply_material_paint_patch(patches: Dictionary, value_key: String) -> void:
	MaterialStrokesFeature._apply_material_paint_patch(self, patches, value_key)


func _gui_input(event: InputEvent) -> void:
	InputFeature._gui_input(self, event)


func _handle_key(key: InputEventKey) -> void:
	InputFeature._handle_key(self, key)


func _nudge_selected_light_height(direction: int) -> void:
	InputFeature._nudge_selected_light_height(self, direction)


func _rotate_selection_or_brush(axis: Vector3i, positive: bool) -> void:
	InputFeature._rotate_selection_or_brush(self, axis, positive)


func _set_brush_face(face: int) -> void:
	InputFeature._set_brush_face(self, face)


func _clear_stuck_input_state() -> void:
	ProcessFeature._clear_stuck_input_state(self)


func _advance_height_sculpt_hold(delta: float) -> void:
	ProcessFeature._advance_height_sculpt_hold(self, delta)


func _process(delta: float) -> void:
	ProcessFeature._process(self, delta)

func _frame_selection() -> void:
	FramingFeature._frame_selection(self)


func _find_visual(target: Resource) -> Node3D:
	return FramingFeature._find_visual(self, target)


func frame_board() -> void:
	FramingFeature.frame_board(self)


func _frame_board_from_bounds(bounds: AABB) -> void:
	FramingFeature._frame_board_from_bounds(self, bounds)


func _board_bounds() -> AABB:
	return FramingFeature._board_bounds(self)


func _on_hover_changed(cell: Vector3i, valid: bool, reason: String) -> void:
	FramingFeature._on_hover_changed(self, cell, valid, reason)


func _on_particle_hover_changed(
	position: Vector3,
	valid: bool,
	reason: String
) -> void:
	FramingFeature._on_particle_hover_changed(self, position, valid, reason)


func _emit_status() -> void:
	FramingFeature._emit_status(self)
