@tool
class_name MTSPlacementController
extends Node3D

const MutationTypesFeature := preload("placement/mutation_types.gd")
const LifecycleFeature := preload("placement/lifecycle.gd")
const BrushSettingsFeature := preload("placement/brush_settings.gd")
const MaterialTargetsFeature := preload("placement/material_targets.gd")
const BrushGeometryFeature := preload("placement/brush_geometry.gd")
const SelectionOrientationFeature := preload("placement/selection_orientation.gd")
const PickingFeature := preload("placement/picking.gd")
const HoverFeature := preload("placement/hover.gd")
const FillActionsFeature := preload("placement/fill_actions.gd")
const FillGeometryFeature := preload("placement/fill_geometry.gd")
const FillCandidatesFeature := preload("placement/fill_candidates.gd")
const CandidatesFeature := preload("placement/candidates.gd")
const FillPreviewFeature := preload("placement/fill_preview.gd")
const CursorPreviewFeature := preload("placement/cursor_preview.gd")
const PaintingFeature := preload("placement/painting.gd")
const SelectionFeature := preload("placement/selection.gd")
const TerrainContactFeature := preload("placement/terrain_contact.gd")
const TransactionsFeature := preload("placement/transactions.gd")

## Turns mouse input into grid-constrained placements (spec 16/38).
##
## Everything here resolves to integer coordinates plus explicit rigid rotations:
## 45-degree horizontal GLB yaw and 90-degree surface/flip/roll steps. There is
## no free placement in the MVP, so origins and reservations stay on the lattice.
## Mutations go through UndoRedo from the outset (spec 43);
## painting was never built "undo later".

const K := preload("../utils/mts_constants.gd")
const ProxyMeshBuilder := preload("../rendering/proxy_mesh_builder.gd")
const TerrainSculptorScript := preload("../generation/terrain_sculptor.gd")
const SURFACE_PREVIEW_SHADER: Shader = preload("../rendering/surface_preview.gdshader")

signal hover_changed(cell: Vector3i, valid: bool, reason: String)
signal selection_changed(placement: Resource)
## Report exactly which canonical placement categories changed.
signal board_mutated(mutation_mask: int)
## Report one atomic GLB contact mutation with its exact disjoint terrain regions.
##
## The viewport receives canonical prop records as well as terrain rectangles so
## it can update only those nodes, batches, contacts, and collision chunks.
signal prop_terrain_regions_mutated(
	regions: Array[Rect2i],
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	terrain_paint_uids: PackedStringArray
)
## Emitted when a placement was refused for overlapping something already there.
signal placement_rejected(cell: Vector3i, reason: String)
## The active tool changed. Emitted from wherever `tool` is set -- including
## set_brush, which leaves erase mode -- so the toolbar toggle can never be
## left showing a mode that is no longer active.
signal tool_changed(tool: int)
## Emitted after the explicit replacement toggle changes its consumed state.
signal replace_mode_changed(enabled: bool)
enum Tool { PAINT, FILL, ERASE, SELECT }
enum FillShape { PATH, POLYGON }
## Emitted when Fill commits a terrain shape, carrying its exact cell origins.
##
## This controller owns Fill geometry; the viewport owns terrain mutation and its
## undo history. Handing over the origins keeps that split intact rather than
## giving the placement controller a second write path into TerrainMesh.
signal terrain_fill_committed(origins: Array[Vector3i])
## Hand the existing tile controller's resolved face UIDs to the canonical RGBA owner.
##
## The pointer, wall plane, grid width, and Fill geometry have already been resolved here,
## so the viewport writes values to these targets without running another target system.
signal terrain_material_tile_paint_requested(
	target_uids: PackedStringArray,
	erase: bool,
	replace_existing: bool,
	finish_stroke: bool
)
## Bit flags let derived systems skip categories untouched by one editor action.
enum BoardMutation { SURFACES = 1, PROPS = 2, TERRAIN = 4, ALL = 7 }


func _mutation_mask_for_resources(resources: Array[Resource]) -> int:
	return MutationTypesFeature._mutation_mask_for_resources(self, resources)

## Preview draws above every piece of board art. It is an overlay describing
## where the brush will land, so scene geometry must never hide it.
##
## Board art now resolves occlusion through the depth buffer and leaves
## render_priority at 0, so any positive value puts the preview above all of it.
## The overlay materials also set no_depth_test, which is what actually lets the
## preview show through a wall; the priority only orders it within that pass.
const PREVIEW_RENDER_PRIORITY: int = 4

var board: BoardDocument
var library: AssetLibrary
var material_factory: SurfaceMaterialFactory
## The live terrain renderer, which owns the one terrain picking routine.
##
## Held rather than re-deriving a second opinion about where the ground is: a
## placement lands on exactly the face a paint stroke would hit, walls included.
var terrain_renderer: MTSTerrainRenderer = null
var undo_redo: EditorUndoRedoManager

## Direct library asset currently loaded into the brush.
var brush_asset: TileAsset = null
## Props expose their required structural support as visible editor state.
var brush_prop_support: String = PropPlacement.SUPPORT_FLOOR
## Surface placements use their painted face normal plus a quarter-turn in that plane.
var brush_face: int = K.Face.POS_Y
## The Texture Paint panel explicitly chooses the stamped placement's render role.
var brush_surface_presentation: int = SurfacePlacement.Presentation.TERRAIN_PAINT
## The visible palette option copied onto either decal presentation.
var brush_match_underlying_palette: bool = false
## Whether the active decal brush targets the nearest grid edge instead of a cell centre.
var brush_surface_edge_mode: bool = false
## The exact cell-centre or shared-junction anchor returned by the selected targeter.
var _surface_grid_anchor: int = SurfacePlacement.GridAnchor.CELL
var brush_quarters: int = 0
## Props use one explicit face/roll orientation plus an inspectable horizontal yaw.
var brush_prop_forward_face: int = K.Face.NEG_Z
var brush_prop_roll_quarters: int = 0
var brush_prop_yaw_eighths: int = 0

var current_y: int = 0
## Slice visibility controls which structural floor levels can receive prop clicks.
var slice_mode: int = K.SliceMode.ALL
var tool: int = Tool.PAINT
## When enabled, painting displaces canonical same-kind occupancy instead of
## rejecting the stroke. This is transient tool state, like Fill and Erase.
var replace_enabled: bool = false
## The toolbar's integer metre width is the canonical square stamp for direct
## textures, Fill, and every terrain brush alike.
var surface_grid_stroke_size_m: int = 1
## Visible Fill interpretation selected by the toolbar.
var fill_shape: int = FillShape.PATH

## Terrain Fill arming, derived from the Terrain panel's visible tool.
##
## The viewport pushes these whenever that tool changes, so Fill can never acquire
## a terrain behaviour the Terrain panel is not currently showing. Nothing here is
## authored state; it mirrors a control the user can see.
var terrain_fill_enabled: bool = false
## True while any visible material workflow delegates square Paint, Replace, Erase,
## Path, and Polygon targets to the canonical RGBA paint owner in the viewport.
var terrain_splat_paint_enabled: bool = false
## Stores the fixed projection or the most recent face followed by masked tile paint.
var _terrain_splat_face: int = K.Face.POS_Y
## Lets masked tile paint follow the terrain face currently under the pointer.
var _terrain_splat_follow_hover_face: bool = false
## True when secondary material paint previews the selected oriented PNG on its target faces.
var _terrain_splat_uses_surface_brush: bool = false
## The viewport validates the canonical target UIDs because it owns their RGBA images.
var _terrain_material_target_validator: Callable
## True only for Footprint Draw, the one terrain operation that may create cells.
var terrain_fill_allows_new_cells: bool = false

var hovered_cell: Vector3i = Vector3i.ZERO
var hover_valid: bool = false
var hover_reason: String = ""
## Reason the most recent paint was refused, or "" if it was committed. Lets a
## non-interactive caller read back what a click could only have seen on screen.
var last_rejection: String = ""
var selected: Resource = null
## The active group is the complete canonical selection; `selected` remains its
## primary item for the existing inspector and selection signal.
var selected_placements: Array[Resource] = []

## The literal terrain grid face currently under a prop hover.
##
## The visible support selector combines with this transient target: Wall requires
## a vertical face, while Floor never becomes wall support. Every face preserves
## the same explicit forward, roll, and yaw state.
var _active_prop_support_face: int = K.Face.POS_Y
var _preview_root: Node3D
var _preview_mesh: MeshInstance3D
var _preview_surface_outline: MeshInstance3D
var _preview_box: MeshInstance3D
var _preview_box_outline: MeshInstance3D
var _preview_arrow: MeshInstance3D
## Material Tile modes use this neutral overlay because their write has no single texture asset.
var _terrain_tile_preview_material: StandardMaterial3D
var _fill_preview_root: Node3D
var _fill_preview_valid: MultiMeshInstance3D
var _fill_preview_blocked: MultiMeshInstance3D
var _fill_preview_texture: MeshInstance3D
var _fill_preview_texture_outline: MeshInstance3D
var _fill_preview_guides: MeshInstance3D

## Clicked Fill vertices are transient editor state and never serialized.
##
## Candidate origins derive deterministically from these points plus the active
## brush size and orientation; BoardDocument changes only when Enter commits.
var fill_vertices: Array[Vector3i] = []
var _fill_active_origins: Array[Vector3i] = []
var _fill_active_valid_origins: Array[Vector3i] = []
var _fill_active_blocked_origins: Array[Vector3i] = []
var _fill_first_rejection: String = ""
## Preview vertices include the current hovered endpoint without making it authored.
##
## Clicking pins that endpoint into fill_vertices; Enter continues to commit only
## pinned points, so cursor motion can never silently change BoardDocument.
var _fill_preview_vertices: Array[Vector3i] = []
var _fill_preview_origins: Array[Vector3i] = []
var _fill_preview_valid_origins: Array[Vector3i] = []
var _fill_preview_blocked_origins: Array[Vector3i] = []
## Direct-texture Fill previews the same explicit face-cell placement that commit consumes.
var _fill_preview_texture_placement: SurfacePlacement


func _ready() -> void:
	LifecycleFeature._ready(self)


func set_brush(asset: TileAsset) -> void:
	BrushSettingsFeature.set_brush(self, asset)


func set_surface_palette_matching(match_underlying_palette: bool) -> void:
	BrushSettingsFeature.set_surface_palette_matching(self, match_underlying_palette)


func set_surface_edge_mode(enabled: bool) -> void:
	BrushSettingsFeature.set_surface_edge_mode(self, enabled)


func set_surface_presentation(presentation: int) -> void:
	BrushSettingsFeature.set_surface_presentation(self, presentation)


func set_prop_support(support: String) -> void:
	BrushSettingsFeature.set_prop_support(self, support)


func has_brush() -> bool:
	return BrushSettingsFeature.has_brush(self)


func _fill_targets_terrain() -> bool:
	return BrushSettingsFeature._fill_targets_terrain(self)


func _fill_is_armed() -> bool:
	return BrushSettingsFeature._fill_is_armed(self)


func set_terrain_fill(enabled: bool, allows_new_cells: bool) -> void:
	BrushSettingsFeature.set_terrain_fill(self, enabled, allows_new_cells)


func set_terrain_splat_paint(
	enabled: bool,
	target_validator: Callable = Callable(),
	projection_face: int = K.Face.POS_Y,
	follow_hover_face: bool = false,
	uses_surface_brush: bool = false
) -> void:
	MaterialTargetsFeature.set_terrain_splat_paint(self, enabled, target_validator, projection_face, follow_hover_face, uses_surface_brush)


func terrain_splat_paint_face() -> int:
	return MaterialTargetsFeature.terrain_splat_paint_face(self)


func terrain_material_target_uids(origin: Vector3i, face: int) -> PackedStringArray:
	return MaterialTargetsFeature.terrain_material_target_uids(self, origin, face)


func terrain_material_target_uids_for_origins(
	origins: Array[Vector3i],
	face: int
) -> PackedStringArray:
	return MaterialTargetsFeature.terrain_material_target_uids_for_origins(self, origins, face)


func _validate_terrain_splat_origin(
	origin: Vector3i,
	erase: bool,
	replace_existing: bool
) -> Dictionary:
	return MaterialTargetsFeature._validate_terrain_splat_origin(self, origin, erase, replace_existing)


func brush_is_surface() -> bool:
	return BrushGeometryFeature.brush_is_surface(self)


func brush_is_prop() -> bool:
	return BrushGeometryFeature.brush_is_prop(self)


func brush_is_volume() -> bool:
	return BrushGeometryFeature.brush_is_volume(self)


func _brush_surface_footprint() -> Vector2i:
	return BrushGeometryFeature._brush_surface_footprint(self)


func _brush_rotated_surface_footprint() -> Vector2i:
	return BrushGeometryFeature._brush_rotated_surface_footprint(self)


func _surface_placement_for_origin(origin: Vector3i) -> SurfacePlacement:
	return BrushGeometryFeature._surface_placement_for_origin(self, origin)


func _conform_texture_surface_to_terrain(placement: SurfacePlacement) -> String:
	return BrushGeometryFeature._conform_texture_surface_to_terrain(self, placement)


func _prop_is_wall_supported() -> bool:
	return BrushGeometryFeature._prop_is_wall_supported(self)


func _resolved_prop_forward_face() -> int:
	return BrushGeometryFeature._resolved_prop_forward_face(self)


func _resolved_prop_yaw_eighths() -> int:
	return BrushGeometryFeature._resolved_prop_yaw_eighths(self)


func _prop_placement_for_origin(origin: Vector3i) -> PropPlacement:
	return BrushGeometryFeature._prop_placement_for_origin(self, origin)


func _brush_color() -> Color:
	return BrushGeometryFeature._brush_color(self)

func set_tool(p_tool: int) -> void:
	BrushSettingsFeature.set_tool(self, p_tool)


func set_surface_grid_stroke_size(size_m: float) -> void:
	BrushSettingsFeature.set_surface_grid_stroke_size(self, size_m)


func set_replace_enabled(enabled: bool) -> void:
	BrushSettingsFeature.set_replace_enabled(self, enabled)
func set_fill_shape(p_fill_shape: int) -> void:
	BrushSettingsFeature.set_fill_shape(self, p_fill_shape)


func fill_shape_name() -> String:
	return BrushSettingsFeature.fill_shape_name(self)


func clear_brush() -> void:
	BrushSettingsFeature.clear_brush(self)

func update_preview_visibility() -> void:
	BrushSettingsFeature.update_preview_visibility(self)


func refresh_brush() -> void:
	BrushSettingsFeature.refresh_brush(self)

func set_brush_face(face: int) -> void:
	BrushSettingsFeature.set_brush_face(self, face)


func align_surface_brush_face(face: int) -> void:
	BrushSettingsFeature.align_surface_brush_face(self, face)


func set_prop_orientation(
	forward_face: int,
	roll_quarters: int = 0,
	yaw_eighths: int = 0
) -> void:
	BrushSettingsFeature.set_prop_orientation(self, forward_face, roll_quarters, yaw_eighths)

func rotate_brush(axis: Vector3i, positive: bool) -> void:
	BrushSettingsFeature.rotate_brush(self, axis, positive)

func _rotated_selection_candidates(axis: Vector3i, positive: bool) -> Dictionary:
	return SelectionOrientationFeature._rotated_selection_candidates(self, axis, positive)


func _flipped_selection_candidates() -> Dictionary:
	return SelectionOrientationFeature._flipped_selection_candidates(self)


func _selection_orientation_states(
	targets: Array[Resource],
	candidate_overrides: Dictionary
) -> Array[Dictionary]:
	return SelectionOrientationFeature._selection_orientation_states(self, targets, candidate_overrides)


func _apply_selection_orientations(
	targets: Array[Resource],
	states: Array[Dictionary]
) -> void:
	SelectionOrientationFeature._apply_selection_orientations(self, targets, states)


func _commit_selection_orientation_candidates(
	candidates: Dictionary,
	action_verb: String
) -> bool:
	return SelectionOrientationFeature._commit_selection_orientation_candidates(self, candidates, action_verb)


func rotate_selection(axis: Vector3i, positive: bool) -> bool:
	return SelectionOrientationFeature.rotate_selection(self, axis, positive)


func flip_selection() -> bool:
	return SelectionOrientationFeature.flip_selection(self)


func pick_cell(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	return PickingFeature.pick_cell(self, camera, mouse_pos)


func _pick_terrain(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	return PickingFeature._pick_terrain(self, camera, mouse_pos)


func pick_terrain_from_ray(origin: Vector3, direction: Vector3) -> Dictionary:
	return PickingFeature.pick_terrain_from_ray(self, origin, direction)


func _pick_current_layer(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	return PickingFeature._pick_current_layer(self, camera, mouse_pos)


func _uses_surface_edge_targeter() -> bool:
	return PickingFeature._uses_surface_edge_targeter(self)


func _pick_grid_edge(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	return PickingFeature._pick_grid_edge(self, camera, mouse_pos)


func update_hover(camera: Camera3D, mouse_pos: Vector2) -> void:
	HoverFeature.update_hover(self, camera, mouse_pos)


func update_hover_from_ray(origin: Vector3, direction: Vector3) -> void:
	HoverFeature.update_hover_from_ray(self, origin, direction)


func _apply_hover_pick(pick: Dictionary) -> void:
	HoverFeature._apply_hover_pick(self, pick)


func _prop_origin_for_pick(
	picked_cell: Vector3i,
	terrain_pick: Dictionary
) -> Vector3i:
	return HoverFeature._prop_origin_for_pick(self, picked_cell, terrain_pick)


func _evaluate_hover() -> void:
	HoverFeature._evaluate_hover(self)

func _reset_fill_state() -> void:
	FillActionsFeature._reset_fill_state(self)


func has_fill_vertices() -> bool:
	return FillActionsFeature.has_fill_vertices(self)


func fill_vertex_count() -> int:
	return FillActionsFeature.fill_vertex_count(self)


func fill_valid_count() -> int:
	return FillActionsFeature.fill_valid_count(self)


func fill_blocked_count() -> int:
	return FillActionsFeature.fill_blocked_count(self)


func add_fill_vertex_at_hover() -> bool:
	return FillActionsFeature.add_fill_vertex_at_hover(self)


func remove_last_fill_vertex() -> bool:
	return FillActionsFeature.remove_last_fill_vertex(self)


func cancel_fill() -> void:
	FillActionsFeature.cancel_fill(self)


func commit_fill() -> bool:
	return FillActionsFeature.commit_fill(self)


func _pick_fill_cell(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	return FillGeometryFeature._pick_fill_cell(self, camera, mouse_pos)


func _fill_face() -> int:
	return FillGeometryFeature._fill_face(self)


func _fill_plane_point(anchor: Vector3i) -> Vector3:
	return FillGeometryFeature._fill_plane_point(self, anchor)


func _fill_plane_axes() -> Array[Vector3i]:
	return FillGeometryFeature._fill_plane_axes(self)


func _fill_stamp_size() -> Vector2i:
	return FillGeometryFeature._fill_stamp_size(self)


func _axis_extent(bounds: Vector3i, axis: Vector3i) -> int:
	return FillGeometryFeature._axis_extent(self, bounds, axis)


func _axis_distance(delta: Vector3i, axis: Vector3i) -> int:
	return FillGeometryFeature._axis_distance(self, delta, axis)


func _cell_to_fill_point(cell: Vector3i) -> Vector2i:
	return FillGeometryFeature._cell_to_fill_point(self, cell)


func _fill_point_to_cell(point: Vector2i, anchor: Vector3i) -> Vector3i:
	return FillGeometryFeature._fill_point_to_cell(self, point, anchor)


func _generate_fill_origins(vertices: Array[Vector3i]) -> Array[Vector3i]:
	return FillGeometryFeature._generate_fill_origins(self, vertices)


func _project_fill_vertices(vertices: Array[Vector3i]) -> Array[Vector2i]:
	return FillGeometryFeature._project_fill_vertices(self, vertices)


func _generate_polyline_origins(vertices: Array[Vector3i]) -> Array[Vector3i]:
	return FillGeometryFeature._generate_polyline_origins(self, vertices)


func _bresenham_points(start: Vector2i, finish: Vector2i) -> Array[Vector2i]:
	return FillGeometryFeature._bresenham_points(self, start, finish)


func _polygon_twice_area(points: Array[Vector2i]) -> int:
	return FillGeometryFeature._polygon_twice_area(self, points)


func _generate_polygon_origins(
	points: Array[Vector2i],
	anchor: Vector3i
) -> Array[Vector3i]:
	return FillGeometryFeature._generate_polygon_origins(self, points, anchor)


func _stamp_centre_is_inside_polygon(
	origin: Vector2i,
	polygon: Array[Vector2i]
) -> bool:
	return FillGeometryFeature._stamp_centre_is_inside_polygon(self, origin, polygon)


func _point_is_in_polygon(point: Vector2, polygon: Array[Vector2i]) -> bool:
	return FillGeometryFeature._point_is_in_polygon(self, point, polygon)


func _point_is_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	return FillGeometryFeature._point_is_on_segment(self, point, start, finish)


func _refresh_fill_candidates() -> void:
	FillCandidatesFeature._refresh_fill_candidates(self)


func _evaluate_terrain_fill_candidates(origins: Array[Vector3i]) -> Dictionary:
	return FillCandidatesFeature._evaluate_terrain_fill_candidates(self, origins)


func _refresh_fill_preview_from_hover() -> void:
	FillCandidatesFeature._refresh_fill_preview_from_hover(self)


func _placement_for_origin(origin: Vector3i) -> Resource:
	return CandidatesFeature._placement_for_origin(self, origin)


func _placement_occupancy_keys(placement: Resource) -> PackedStringArray:
	return CandidatesFeature._placement_occupancy_keys(self, placement)


func _replacement_conflicts_for(placement: Resource) -> Array[Resource]:
	return CandidatesFeature._replacement_conflicts_for(self, placement)


func _retain_available_surface_faces(placement: SurfacePlacement) -> Dictionary:
	return CandidatesFeature._retain_available_surface_faces(self, placement)


func _retain_faces_not_using_brush_asset(placement: SurfacePlacement) -> bool:
	return CandidatesFeature._retain_faces_not_using_brush_asset(self, placement)


func _validate_placement(placement: Resource) -> Dictionary:
	return CandidatesFeature._validate_placement(self, placement)
func _build_texture_fill_candidate(origins: Array[Vector3i]) -> Dictionary:
	return CandidatesFeature._build_texture_fill_candidate(self, origins)


func _evaluate_direct_texture_fill(origins: Array[Vector3i]) -> Dictionary:
	return CandidatesFeature._evaluate_direct_texture_fill(self, origins)


func _evaluate_placement_candidates(origins: Array[Vector3i]) -> Dictionary:
	return CandidatesFeature._evaluate_placement_candidates(self, origins)
func _update_fill_preview() -> void:
	FillPreviewFeature._update_fill_preview(self)


func _set_fill_preview_batch(
	target: MultiMeshInstance3D,
	origins: Array[Vector3i],
	tint: Color
) -> void:
	FillPreviewFeature._set_fill_preview_batch(self, target, origins, tint)


func _ensure_texture_fill_preview_nodes() -> void:
	FillPreviewFeature._ensure_texture_fill_preview_nodes(self)


func _set_texture_fill_preview(placement: SurfacePlacement, is_valid: bool) -> void:
	FillPreviewFeature._set_texture_fill_preview(self, placement, is_valid)


func _ensure_fill_preview_guides() -> void:
	FillPreviewFeature._ensure_fill_preview_guides(self)


func _update_fill_preview_guides() -> void:
	FillPreviewFeature._update_fill_preview_guides(self)


func _add_fill_stamp_outline(
	guides: ImmediateMesh,
	origin: Vector3i,
	color: Color
) -> void:
	FillPreviewFeature._add_fill_stamp_outline(self, guides, origin, color)


func _add_fill_control_path(guides: ImmediateMesh) -> void:
	FillPreviewFeature._add_fill_control_path(self, guides)


func _fill_stamp_centre(origin: Vector3i) -> Vector3:
	return FillPreviewFeature._fill_stamp_centre(self, origin)


func _add_fill_guide_line(
	guides: ImmediateMesh,
	start: Vector3,
	finish: Vector3,
	color: Color
) -> void:
	FillPreviewFeature._add_fill_guide_line(self, guides, start, finish, color)


func _build_prop_fill_preview_material(tint: Color) -> StandardMaterial3D:
	return FillPreviewFeature._build_prop_fill_preview_material(self, tint)


func _build_surface_brush_material(tint: Color) -> Material:
	return FillPreviewFeature._build_surface_brush_material(self, tint)


func _build_surface_preview_material(asset: TileAsset, tint: Color) -> ShaderMaterial:
	return FillPreviewFeature._build_surface_preview_material(self, asset, tint)


func _clear_fill_preview() -> void:
	FillPreviewFeature._clear_fill_preview(self)


func _ensure_cursor_preview_outlines() -> void:
	CursorPreviewFeature._ensure_cursor_preview_outlines(self)


func refresh_brush_preview() -> void:
	CursorPreviewFeature.refresh_brush_preview(self)


func _rebuild_preview() -> void:
	CursorPreviewFeature._rebuild_preview(self)


func _position_preview() -> void:
	CursorPreviewFeature._position_preview(self)

func _build_surface_up_arrow() -> ArrayMesh:
	return CursorPreviewFeature._build_surface_up_arrow(self)


func _build_facing_arrow() -> ArrayMesh:
	return CursorPreviewFeature._build_facing_arrow(self)


func _brush_prop_canonical_bounds() -> Vector3i:
	return BrushGeometryFeature._brush_prop_canonical_bounds(self)


func _brush_prop_transform_for_origin(origin: Vector3i) -> Transform3D:
	return BrushGeometryFeature._brush_prop_transform_for_origin(self, origin)


func _brush_prop_center_transform(origin: Vector3i) -> Transform3D:
	return BrushGeometryFeature._brush_prop_center_transform(self, origin)


func _brush_prop_preview_voxels() -> Array[Vector3i]:
	return BrushGeometryFeature._brush_prop_preview_voxels(self)


func _brush_prop_preview_bounds() -> AABB:
	return BrushGeometryFeature._brush_prop_preview_bounds(self)


func _brush_box() -> Vector3i:
	return BrushGeometryFeature._brush_box(self)

static func surface_transform(
	cell: Vector3i,
	face: int,
	quarters: int,
	asset: TileAsset,
	grid_anchor: int = SurfacePlacement.GridAnchor.CELL
) -> Transform3D:
	return BrushGeometryFeature.surface_transform(cell, face, quarters, asset, grid_anchor)


static func surface_transform_for_size(
	cell: Vector3i,
	face: int,
	quarters: int,
	canonical_footprint: Vector2i,
	grid_anchor: int = SurfacePlacement.GridAnchor.CELL
) -> Transform3D:
	return BrushGeometryFeature.surface_transform_for_size(cell, face, quarters, canonical_footprint, grid_anchor)


func paint_at_hover() -> bool:
	return PaintingFeature.paint_at_hover(self)


func _reject(reason: String) -> void:
	PaintingFeature._reject(self, reason)


func _surface_at_address(cell: Vector3i, face: int) -> SurfacePlacement:
	return PaintingFeature._surface_at_address(self, cell, face)


func erase_at_hover() -> void:
	PaintingFeature.erase_at_hover(self)


func _apply_selection_presence(targets: Array[Resource], present: bool) -> void:
	SelectionFeature._apply_selection_presence(self, targets, present)


func delete_selection() -> void:
	SelectionFeature.delete_selection(self)


func select_at_hover() -> void:
	SelectionFeature.select_at_hover(self)


func is_selected(placement: Resource) -> bool:
	return SelectionFeature.is_selected(self, placement)


func selected_resources() -> Array[Resource]:
	return SelectionFeature.selected_resources(self)


func set_selected_placements(placements: Array[Resource], primary: Resource = null) -> void:
	SelectionFeature.set_selected_placements(self, placements, primary)


func toggle_selected_placement(placement_record: Resource) -> void:
	SelectionFeature.toggle_selected_placement(self, placement_record)


func clear_selection() -> void:
	SelectionFeature.clear_selection(self)


func _selection_spatial_error(candidate_overrides: Dictionary) -> String:
	return SelectionFeature._selection_spatial_error(self, candidate_overrides)


func selection_move_error(delta: Vector3i) -> String:
	return SelectionFeature.selection_move_error(self, delta)


func _apply_selection_origins(
	targets: Array[Resource], origins: Array[Vector3i]
) -> void:
	SelectionFeature._apply_selection_origins(self, targets, origins)


func move_selection_by(delta: Vector3i) -> bool:
	return SelectionFeature.move_selection_by(self, delta)


func _prop_contact_bounds(
	prop: PropPlacement,
	asset: TileAsset,
	terrain: TerrainMesh
) -> Rect2i:
	return TerrainContactFeature._prop_contact_bounds(self, prop, asset, terrain)


func _prop_contact_groups(props: Array[PropPlacement]) -> Array[Dictionary]:
	return TerrainContactFeature._prop_contact_groups(self, props)


func _terrain_paint_uids_for_patch(patch: Dictionary) -> PackedStringArray:
	return TerrainContactFeature._terrain_paint_uids_for_patch(self, patch)


func _combine_prop_terrain_patches(patches: Array[Dictionary]) -> Dictionary:
	return TerrainContactFeature._combine_prop_terrain_patches(self, patches)


func _patch_terrain_regions(patch: Dictionary) -> Array[Rect2i]:
	return TerrainContactFeature._patch_terrain_regions(self, patch)


func _props_request_contact_flatten(props: Array[PropPlacement]) -> bool:
	return TerrainContactFeature._props_request_contact_flatten(self, props)


func _flatten_props_on_terrain(
	target_terrain: TerrainMesh,
	props: Array[PropPlacement],
	report_messages: bool
) -> Dictionary:
	return TerrainContactFeature._flatten_props_on_terrain(self, target_terrain, props, report_messages)


func _prop_terrain_flatten_patch(
	props: Array[PropPlacement],
	report_messages: bool = true
) -> Dictionary:
	return TerrainContactFeature._prop_terrain_flatten_patch(self, props, report_messages)


func _prop_preview_world_origin(prop: PropPlacement) -> Vector3:
	return TerrainContactFeature._prop_preview_world_origin(self, prop)


func _apply_existing_prop_contact_patch(
	patch: Dictionary,
	use_after_state: bool
) -> void:
	TerrainContactFeature._apply_existing_prop_contact_patch(self, patch, use_after_state)


func apply_asset_contact_flatten(asset_id: String) -> int:
	return TerrainContactFeature.apply_asset_contact_flatten(self, asset_id)


func _apply_prop_terrain_transaction(
	removed_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	patch: Dictionary,
	use_after_state: bool
) -> void:
	TransactionsFeature._apply_prop_terrain_transaction(self, removed_props, added_props, patch, use_after_state)


func _commit_prop_terrain_transaction(
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	action: String
) -> bool:
	return TransactionsFeature._commit_prop_terrain_transaction(self, added_props, removed_props, action)


func _commit_placements_bulk(placements: Array[Resource], action: String) -> void:
	TransactionsFeature._commit_placements_bulk(self, placements, action)


func _surface_replacement_residuals(
	replacements: Array[SurfacePlacement],
	displaced: Array[SurfacePlacement]
) -> Array[SurfacePlacement]:
	return TransactionsFeature._surface_replacement_residuals(self, replacements, displaced)


func _commit_replacements(
	placements: Array[Resource],
	displaced: Array[Resource],
	action: String
) -> void:
	TransactionsFeature._commit_replacements(self, placements, displaced, action)


func _commit_remove_surface(placement: SurfacePlacement, action: String) -> void:
	TransactionsFeature._commit_remove_surface(self, placement, action)
func _commit_remove_prop(placement: PropPlacement, action: String) -> void:
	TransactionsFeature._commit_remove_prop(self, placement, action)


func _notify_mutated(mutation_mask: int) -> void:
	TransactionsFeature._notify_mutated(self, mutation_mask)
