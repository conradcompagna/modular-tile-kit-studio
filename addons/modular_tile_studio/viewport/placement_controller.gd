@tool
class_name MTSPlacementController
extends Node3D

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


## Return the exact placement-category mask represented by canonical resources.
func _mutation_mask_for_resources(resources: Array[Resource]) -> int:
	var mutation_mask := 0
	for resource: Resource in resources:
		if resource is SurfacePlacement:
			mutation_mask |= BoardMutation.SURFACES
		elif resource is PropPlacement:
			mutation_mask |= BoardMutation.PROPS
		else:
			push_error("[Tile Studio] cannot classify an unsupported placement mutation.")
	return mutation_mask

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
	_preview_root = Node3D.new()
	_preview_root.name = "PlacementPreview"
	add_child(_preview_root)

	# The preview is HUD, not scene geometry. It displays the factory-resolved
	# albedo as a ghost overlay, so casting must be switched off explicitly --
	# otherwise the hovering cursor throws a shadow onto the board.
	_preview_mesh = MeshInstance3D.new()
	_preview_mesh.name = "PreviewQuad"
	_preview_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_mesh)

	_preview_surface_outline = MeshInstance3D.new()
	_preview_surface_outline.name = "PreviewQuadContours"
	_preview_surface_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_surface_outline)

	_preview_box = MeshInstance3D.new()
	_preview_box.name = "PreviewBox"
	_preview_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_box)

	_preview_box_outline = MeshInstance3D.new()
	_preview_box_outline.name = "PreviewBoxContours"
	_preview_box_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var outline_material := StandardMaterial3D.new()
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.albedo_color = Color(0.03, 0.04, 0.06, 1.0)
	outline_material.no_depth_test = true
	outline_material.render_priority = PREVIEW_RENDER_PRIORITY + 2
	_preview_box_outline.material_override = outline_material
	_preview_root.add_child(_preview_box_outline)
	_preview_surface_outline.material_override = outline_material

	# The shared placement preview needs a neutral fill when a material channel,
	# rather than one TileAsset texture, is being painted onto the selected faces.
	_terrain_tile_preview_material = StandardMaterial3D.new()
	_terrain_tile_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_terrain_tile_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_terrain_tile_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_terrain_tile_preview_material.no_depth_test = true
	_terrain_tile_preview_material.render_priority = PREVIEW_RENDER_PRIORITY
	_terrain_tile_preview_material.albedo_color = Color(0.12, 0.86, 1.0, 0.22)

	# Geometry alone cannot expose every orientation: symmetric props hide their
	# facing, while a PNG quad hides which edge is the authored image top. The
	# arrow is the common explicit orientation readout for both asset types.
	_preview_arrow = MeshInstance3D.new()
	_preview_arrow.name = "PreviewFacingArrow"
	_preview_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_arrow)

	_fill_preview_root = Node3D.new()
	_fill_preview_root.name = "FillPreview"
	_preview_root.add_child(_fill_preview_root)

	_fill_preview_valid = MultiMeshInstance3D.new()
	_fill_preview_valid.name = "ValidStamps"
	_fill_preview_valid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fill_preview_root.add_child(_fill_preview_valid)

	_fill_preview_blocked = MultiMeshInstance3D.new()
	_fill_preview_blocked.name = "BlockedStamps"
	_fill_preview_blocked.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fill_preview_root.add_child(_fill_preview_blocked)

	_ensure_texture_fill_preview_nodes()
	_ensure_fill_preview_guides()

	_preview_root.visible = false

	# A brush set before this controller entered the tree had nothing to draw
	# into. Now that the nodes exist, build the overlay from that brush state so
	# it is never silently missing.
	if has_brush():
		_rebuild_preview()


# --- Brush ----------------------------------------------------------------

## Select one asset and reset its transient placement orientation to canonical Y-up.
##
## PNG surfaces begin on +Y with no spin, while GLB props retain their untouched
## source pose with local forward -Z and no roll. Only editor rotation commands
## change these values; the asset resource contains no competing default.
func set_brush(asset: TileAsset) -> void:
	_reset_fill_state()
	brush_asset = asset
	if asset != null:
		brush_face = K.Face.POS_Y
		brush_quarters = 0
		brush_surface_presentation = SurfacePlacement.Presentation.TERRAIN_PAINT
		brush_surface_edge_mode = false
		_surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
		brush_prop_forward_face = K.Face.NEG_Z
		brush_prop_roll_quarters = 0
		brush_prop_yaw_eighths = 0
		brush_prop_support = (
			PropPlacement.SUPPORT_FLOOR
			if asset.is_prop()
			else PropPlacement.SUPPORT_NONE
		)
		_active_prop_support_face = K.Face.POS_Y

		if tool == Tool.ERASE or tool == Tool.SELECT:
			set_tool(Tool.PAINT)

	_rebuild_preview()
	update_preview_visibility()


## Set the palette choice copied onto subsequently stamped decals.
##
## This transient value comes from the visible Texture Paint toggle and is copied
## into each placement, so changing the brush cannot alter authored stamps.
func set_surface_palette_matching(match_underlying_palette: bool) -> void:
	brush_match_underlying_palette = match_underlying_palette


## Set whether subsequently stamped decals use the dedicated lattice-edge targeter.
func set_surface_edge_mode(enabled: bool) -> void:
	if brush_surface_edge_mode == enabled:
		return
	brush_surface_edge_mode = enabled
	_surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
	# Changing target primitives invalidates the previous hover completely. The
	# viewport immediately performs a fresh ray pick through the selected route.
	if _preview_root != null:
		_preview_root.visible = false


## Set the surface presentation used by subsequently stamped image assets.
##
## This transient brush choice is set by the visible Texture Paint control and
## copied directly into each saved SurfacePlacement at commit time.
func set_surface_presentation(presentation: int) -> void:
	# Bounded against the LAST enum value rather than a named one, so adding a
	# render role cannot leave this guard silently rejecting it.
	if (
		presentation < SurfacePlacement.Presentation.TERRAIN_PAINT
		or presentation > SurfacePlacement.Presentation.SHADER_DECAL
	):
		push_error(
			"[Tile Studio] surface presentation %d is not one of the %d render roles."
			% [presentation, SurfacePlacement.Presentation.size()]
		)
		return
	if brush_surface_presentation == presentation:
		return
	brush_surface_presentation = presentation
	if presentation == SurfacePlacement.Presentation.TERRAIN_PAINT:
		brush_surface_edge_mode = false
		_surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
	if brush_is_surface():
		_evaluate_hover()
		_position_preview()


## Set the explicit structural support stored on subsequently painted props.
func set_prop_support(support: String) -> void:
	if support != PropPlacement.SUPPORT_FLOOR and support != PropPlacement.SUPPORT_WALL:
		push_error("[Tile Studio] prop support must be 'floor' or 'wall'.")
		return
	brush_prop_support = support
	if brush_is_prop():
		_evaluate_hover()
		_position_preview()
		if has_fill_vertices():
			_refresh_fill_candidates()


## Return whether a canonical brush asset is active.
func has_brush() -> bool:
	return brush_asset != null


## Return whether Fill currently has something to apply: a brush, or terrain.
##
## Terrain Fill needs no asset, so every Fill gate asks this rather than
## Return whether Fill targets terrain cells instead of asset placements.
func _fill_targets_terrain() -> bool:
	return terrain_fill_enabled or terrain_splat_paint_enabled


## Report whether Fill has one visible tool capable of committing its generated origins.
##
## Splatmap mode intentionally needs no single asset brush because one commit writes
## every assigned RGBA channel through the viewport paint owner.
func _fill_is_armed() -> bool:
	return _fill_targets_terrain() or has_brush()


## Arm or disarm terrain Fill to match the viewport's visible terrain tool.
##
## Changing what Fill would commit invalidates any half-drawn shape, so the
## pending vertices are discarded rather than silently re-interpreted.
func set_terrain_fill(enabled: bool, allows_new_cells: bool) -> void:
	if (
		terrain_fill_enabled == enabled
		and terrain_fill_allows_new_cells == allows_new_cells
	):
		return
	terrain_fill_enabled = enabled
	terrain_fill_allows_new_cells = allows_new_cells
	if enabled:
		terrain_splat_paint_enabled = false
		_terrain_material_target_validator = Callable()
	_reset_fill_state()
	update_preview_visibility()


## Arm the existing base-coat controller as the exclusive terrain material tile brush.
##
## Imported RGBA splatmaps retain the neutral target, while secondary PNG paint reuses
## the regular surface brush asset, face, quarter-turn, textured preview, and arrow.
func set_terrain_splat_paint(
	enabled: bool,
	target_validator: Callable = Callable(),
	projection_face: int = K.Face.POS_Y,
	follow_hover_face: bool = false,
	uses_surface_brush: bool = false
) -> void:
	if enabled and not target_validator.is_valid():
		push_error("MTSPlacementController: terrain material tile paint needs a cell validator.")
		return
	if enabled and projection_face not in [
		K.Face.POS_Y,
		K.Face.NEG_Z,
		K.Face.POS_Z,
		K.Face.POS_X,
		K.Face.NEG_X,
	]:
		push_error("MTSPlacementController: terrain material paint requires a visible face.")
		return
	if (
		terrain_splat_paint_enabled == enabled
		and (
			not enabled
			or (
				_terrain_material_target_validator == target_validator
				and _terrain_splat_face == projection_face
				and _terrain_splat_follow_hover_face == follow_hover_face
				and _terrain_splat_uses_surface_brush == uses_surface_brush
			)
		)
	):
		return
	terrain_splat_paint_enabled = enabled
	_terrain_material_target_validator = target_validator if enabled else Callable()
	_terrain_splat_face = projection_face if enabled else K.Face.POS_Y
	_terrain_splat_follow_hover_face = follow_hover_face if enabled else false
	_terrain_splat_uses_surface_brush = uses_surface_brush if enabled else false
	if enabled:
		terrain_fill_enabled = false
		terrain_fill_allows_new_cells = false
	_reset_fill_state()
	_evaluate_hover()
	if enabled:
		_position_preview()
	elif has_brush():
		_rebuild_preview()
	update_preview_visibility()


## Return the face direction currently owned by the visible material tile targeter.
func terrain_splat_paint_face() -> int:
	return _terrain_splat_face


## Return stable face UIDs from the established base-coat tile targeter.
##
## Direct texture placement and both RGBA material modes call the same renderer route,
## so wall-plane axes, even-width centring, and face isolation have one owner.
func terrain_material_target_uids(origin: Vector3i, face: int) -> PackedStringArray:
	if terrain_renderer == null:
		return PackedStringArray()
	return terrain_renderer.surface_face_uids_for_grid_stroke(
		origin,
		face,
		surface_grid_stroke_size_m
	)


## Resolve and deduplicate one Paint or Fill gesture through the same tile targeter.
func terrain_material_target_uids_for_origins(
	origins: Array[Vector3i],
	face: int
) -> PackedStringArray:
	var unique_uids: Dictionary = {}
	for origin: Vector3i in origins:
		for uid: String in terrain_material_target_uids(origin, face):
			unique_uids[uid] = true
	var target_uids := PackedStringArray()
	for uid_value: Variant in unique_uids.keys():
		target_uids.append(String(uid_value))
	target_uids.sort()
	return target_uids


## Return whether one terrain origin passes the viewport's canonical material-tile rules.
func _validate_terrain_splat_origin(
	origin: Vector3i,
	erase: bool,
	replace_existing: bool
) -> Dictionary:
	if not terrain_splat_paint_enabled or not _terrain_material_target_validator.is_valid():
		return {"valid": false, "reason": "terrain material tile paint is not armed"}
	if _active_prop_support_face != _terrain_splat_face:
		return {
			"valid": false,
			"reason": "Point at a terrain face matching the active tile-paint direction.",
		}
	var target_uids := terrain_material_target_uids(origin, _terrain_splat_face)
	var result: Variant = _terrain_material_target_validator.call(
		target_uids,
		erase,
		replace_existing
	)
	if not result is Dictionary:
		push_error("MTSPlacementController: material tile validator returned invalid data.")
		return {"valid": false, "reason": "material tile validation failed"}
	var validated_result: Dictionary = result as Dictionary
	# Commit consumes the exact UIDs validation approved, so one click cannot be
	# retargeted by a second coordinate conversion after the preview was accepted.
	validated_result["target_uids"] = target_uids
	return validated_result


## Return whether the active asset is a surface.
func brush_is_surface() -> bool:
	return brush_asset != null and brush_asset.is_surface()


## Return whether the active asset is a prop.
func brush_is_prop() -> bool:
	return brush_asset != null and brush_asset.is_prop()


## Return whether the active brush claims canonical solid voxels.
func brush_is_volume() -> bool:
	return brush_is_prop()


## Return the active surface brush's canonical unrotated footprint.
func _brush_surface_footprint() -> Vector2i:
	if brush_asset != null:
		return brush_asset.surface_footprint()
	return Vector2i.ZERO


## Return the active surface footprint after its visible quarter-turn.
func _brush_rotated_surface_footprint() -> Vector2i:
	var footprint := _brush_surface_footprint()
	if K.normalized_quarters(brush_quarters) % 2 == 1:
		return Vector2i(footprint.y, footprint.x)
	return footprint


## Build one surface placement from the active brush asset.
func _surface_placement_for_origin(origin: Vector3i) -> SurfacePlacement:
	var placement := SurfacePlacement.create(
		brush_asset.asset_id,
		origin,
		brush_face,
		brush_quarters
	)
	placement.presentation = brush_surface_presentation
	placement.grid_anchor = (
		_surface_grid_anchor
		if placement.is_overlay()
		else SurfacePlacement.GridAnchor.CELL
	)
	# Copied, not referenced: each placement records the visible palette choice
	# used when stamped rather than reading mutable global brush state later.
	placement.match_underlying_palette = brush_match_underlying_palette
	_conform_texture_surface_to_terrain(placement)
	return placement


## Assign the exact canonical heightfield faces receiving one surface stamp.
##
## Returning an error instead of a planar fallback makes the heightfield a hard
## prerequisite and keeps painted regions and native decals in true address space.
func _conform_texture_surface_to_terrain(placement: SurfacePlacement) -> String:
	if placement == null or placement.asset_id.is_empty():
		return ""
	if board == null or board.terrain == null or board.terrain.is_empty():
		placement.terrain_face_uids.clear()
		return "surface stamping requires a heightfield"
	if terrain_renderer == null:
		placement.terrain_face_uids.clear()
		return "surface stamping cannot access the heightfield renderer"
	var asset := board.resolve_surface_asset(placement)
	if asset == null or not asset.is_surface():
		placement.terrain_face_uids.clear()
		return "surface stamping requires a valid PNG surface asset"
	placement.terrain_face_uids = terrain_renderer.surface_face_uids_for_placement(
		placement,
		asset,
		surface_grid_stroke_size_m
	)
	if placement.terrain_face_uids.is_empty():
		return "surface stamp touches no heightfield faces"
	return ""


## Return whether the explicit Wall brush is aimed at a vertical terrain grid face.
##
## The visible support selector and the literal clicked face must both say wall.
## This prevents an intercepted side triangle from turning a Floor placement into
## hidden wall support, while a ground click can never satisfy the wall contract.
func _prop_is_wall_supported() -> bool:
	return (
		brush_prop_support == PropPlacement.SUPPORT_WALL
		and Vector3(K.face_normal(_active_prop_support_face)).y == 0.0
	)


## Return the single prop forward face authored by the rotation controls.
##
## Terrain support selects only where the prop lands; top and side targets never
## rewrite the orientation that the arrow, preview, collision, and GLB all share.
func _resolved_prop_forward_face() -> int:
	return brush_prop_forward_face


## Return the single prop yaw authored by the rotation controls.
func _resolved_prop_yaw_eighths() -> int:
	return brush_prop_yaw_eighths


## Build one prop placement from the active brush asset.
func _prop_placement_for_origin(origin: Vector3i) -> PropPlacement:
	var forward_face := _resolved_prop_forward_face()
	var yaw_eighths := _resolved_prop_yaw_eighths()
	var placement := PropPlacement.create(
		brush_asset.asset_id,
		origin,
		forward_face,
		brush_prop_roll_quarters,
		yaw_eighths
	)
	# Support and orientation are independent canonical facts. Recording the
	# targeted terrain kind and exact hit face prevents a wall click from becoming
	# hidden rotation or losing the plane needed for real-mesh contact.
	placement.support = (
		PropPlacement.SUPPORT_WALL
		if _prop_is_wall_supported()
		else PropPlacement.SUPPORT_FLOOR
	)
	placement.support_face = (
		_active_prop_support_face
		if placement.support == PropPlacement.SUPPORT_WALL
		else K.Face.POS_Y
	)
	# The elevation a floor prop rests at is derived from the canonical terrain
	# whenever it is needed rather than stored here, so sculpting the ground under
	# a prop cannot leave a stale height recorded against it.
	return placement


## Return the canonical preview tint used by every brush.
func _brush_color() -> Color:
	return Color(0.4, 0.9, 1.0)

## Switch the active tool, announcing the change exactly once.
##
## Fill is a generic placement mode for surfaces and GLB props. Leaving it
## discards only its transient point-defined shape.
func set_tool(p_tool: int) -> void:
	if tool == p_tool:
		return

	if tool == Tool.FILL and p_tool != Tool.FILL:
		_reset_fill_state()

	tool = p_tool
	update_preview_visibility()
	tool_changed.emit(tool)


## Set the square direct-texture stamp width and immediately refresh its exact preview.
func set_surface_grid_stroke_size(size_m: float) -> void:
	surface_grid_stroke_size_m = clampi(roundi(size_m), 1, 100)
	if (
		board != null
		and (
			terrain_splat_paint_enabled
			or (has_brush() and brush_is_surface() and brush_asset != null)
		)
	):
		_evaluate_hover()
		if _preview_root != null:
			_position_preview()
		update_preview_visibility()


## Change whether occupancy conflicts are replaced by the active brush.
##
## The setting is intentionally independent from the paint, Fill, and Erase
## tools: the toolbar shows this exact boolean, while every placement path reads
## it through _validate_placement before any BoardDocument mutation occurs.
func set_replace_enabled(enabled: bool) -> void:
	if replace_enabled == enabled:
		return
	replace_enabled = enabled
	if board != null and (has_brush() or terrain_splat_paint_enabled):
		_evaluate_hover()
		if _preview_root != null:
			_position_preview()
		if has_fill_vertices():
			_refresh_fill_candidates()
		update_preview_visibility()
	replace_mode_changed.emit(replace_enabled)
func set_fill_shape(p_fill_shape: int) -> void:
	if p_fill_shape != FillShape.PATH and p_fill_shape != FillShape.POLYGON:
		push_error("[Tile Studio] Fill shape must be PATH or POLYGON.")
		return
	if fill_shape == p_fill_shape:
		return
	_reset_fill_state()
	fill_shape = p_fill_shape
	update_preview_visibility()


## Return the visible label for the current Fill interpretation.
func fill_shape_name() -> String:
	return "PATH" if fill_shape == FillShape.PATH else "POLYGON"


## Clear the brush and discard any transient Fill state.

func clear_brush() -> void:
	_reset_fill_state()
	brush_asset = null
	_active_prop_support_face = K.Face.POS_Y
	if _preview_root != null:
		_preview_root.visible = false

## Show the cursor ghost together with every active Fill stamp batch.
##
## The cursor ghost remains visible after the first point so the next clicked
## footprint is explicit, while the Fill batches show the complete pending result.
func update_preview_visibility() -> void:
	if _preview_root == null:
		return
	_ensure_cursor_preview_outlines()
	# Terrain Fill has no asset ghost of its own; its cursor is the Terrain panel's
	# own targeter, so only the Fill shape preview below is shown for it.
	var show_terrain_tile_preview := (
		terrain_splat_paint_enabled
		and (tool == Tool.PAINT or tool == Tool.ERASE)
	)
	var show_ordinary_preview := (
		has_brush()
		and not _fill_targets_terrain()
		and (tool == Tool.PAINT or tool == Tool.FILL)
	)
	_preview_root.visible = (
		show_ordinary_preview
		or show_terrain_tile_preview
		or (_fill_targets_terrain() and tool == Tool.FILL)
	)
	_preview_mesh.visible = (
		(show_ordinary_preview and brush_is_surface())
		or show_terrain_tile_preview
	)
	_preview_surface_outline.visible = _preview_mesh.visible
	_preview_box.visible = show_ordinary_preview and brush_is_volume()
	_preview_box_outline.visible = show_ordinary_preview and brush_is_volume()
	_preview_arrow.visible = (
		show_ordinary_preview
		or (show_terrain_tile_preview and _terrain_splat_uses_surface_brush)
	)
	if _fill_preview_root != null:
		_fill_preview_root.visible = (
			tool == Tool.FILL
			and not _fill_preview_vertices.is_empty()
			and (
				not _fill_preview_valid_origins.is_empty()
				or not _fill_preview_blocked_origins.is_empty()
			)
		)


## Rebuild the preview from the current asset values without altering editor orientation.
##
## Size and material edits must update the live ghost, but face, spin, forward,
## and roll belong exclusively to the user's placement controls.

func refresh_brush() -> void:
	if not has_brush():
		return
	_evaluate_hover()
	_rebuild_preview()

## Aim the surface brush directly at a grid face, bypassing stepwise rotation.

func set_brush_face(face: int) -> void:
	if not brush_is_surface():
		return
	if has_fill_vertices():
		_reset_fill_state()
	brush_face = face
	brush_quarters = 0
	_rebuild_preview()


## Align a surface brush to the pointed terrain face without changing its PNG quarter-turn.
func align_surface_brush_face(face: int) -> void:
	if not brush_is_surface() or not K.FACE_NORMALS.has(face):
		return
	if brush_face == face:
		return
	brush_face = face
	if terrain_splat_paint_enabled and _terrain_splat_follow_hover_face:
		_terrain_splat_face = face
	_rebuild_preview()


## Set the active prop brush to one explicit complete orientation.
##
## This is the non-keyboard route used by the bridge and keeps its state on the
## same face, roll, and 45-degree yaw representation used by arrow-key rotation.

func set_prop_orientation(
	forward_face: int,
	roll_quarters: int = 0,
	yaw_eighths: int = 0
) -> void:
	if not brush_is_volume():
		return
	if not K.FACE_NORMALS.has(forward_face):
		push_error("[Tile Studio] prop orientation needs one of the six grid faces.")
		return
	if has_fill_vertices():
		_reset_fill_state()
	brush_prop_forward_face = forward_face
	brush_prop_roll_quarters = K.normalized_quarters(roll_quarters)
	brush_prop_yaw_eighths = K.normalized_yaw_eighths(yaw_eighths)
	_rebuild_preview()

## Rotate the current brush by one keyboard step about its visible yaw-aligned axis.
##
## GLB props use 45-degree horizontal yaw steps for four cardinals plus four
## diagonals; their existing 90-degree flip and roll commands remain explicit.
## Surface placements and surfaced-box slots retain their existing quarter-turn behavior.

func rotate_brush(axis: Vector3i, positive: bool) -> void:
	if not has_brush():
		return
	if has_fill_vertices():
		_reset_fill_state()

	if brush_is_prop():
		var prop_orientation := K.rotate_prop_orientation(
			brush_prop_forward_face,
			brush_prop_roll_quarters,
			axis,
			positive,
			brush_prop_yaw_eighths
		)
		brush_prop_forward_face = int(prop_orientation["forward_face"])
		brush_prop_roll_quarters = int(prop_orientation["roll_quarters"])
		brush_prop_yaw_eighths = int(prop_orientation["yaw_eighths"])
	else:
		var surface_orientation := K.rotate_surface_orientation(
			brush_face,
			brush_quarters,
			axis,
			positive
		)
		brush_face = int(surface_orientation["face"])
		brush_quarters = int(surface_orientation["rotation_quarters"])
		if terrain_splat_paint_enabled and _terrain_splat_uses_surface_brush:
			_terrain_splat_face = brush_face
	_rebuild_preview()

## Build rotated duplicates from the selected canonical placement records.
##
## These records are validation candidates only; they are never inserted into
## BoardDocument or rendered as a second placement representation.
func _rotated_selection_candidates(axis: Vector3i, positive: bool) -> Dictionary:
	var candidates: Dictionary = {}
	for placement_record: Resource in selected_placements:
		if placement_record is SurfacePlacement:
			var surface := (placement_record as SurfacePlacement).duplicate() as SurfacePlacement
			var surface_orientation := K.rotate_surface_orientation(
				surface.face,
				surface.rotation_quarters,
				axis,
				positive
			)
			surface.face = int(surface_orientation["face"])
			surface.rotation_quarters = int(surface_orientation["rotation_quarters"])
			candidates[placement_record.get_instance_id()] = surface
		elif placement_record is PropPlacement:
			var prop := (placement_record as PropPlacement).duplicate() as PropPlacement
			var prop_orientation := K.rotate_prop_orientation(
				prop.forward_face,
				prop.roll_quarters,
				axis,
				positive,
				prop.yaw_eighths
			)
			prop.forward_face = int(prop_orientation["forward_face"])
			prop.roll_quarters = int(prop_orientation["roll_quarters"])
			prop.yaw_eighths = int(prop_orientation["yaw_eighths"])
			candidates[placement_record.get_instance_id()] = prop
	return candidates


## Build one atomic upside-down flip candidate for every selected placement.
##
## A GLB's horizontal diagonal yaw is preserved while its orthogonal base pose
## turns 180 degrees around the base X axis. This makes imported upside-down art
## correctable without committing or collision-testing an intermediate 90-degree
## pose, and without storing a second transform.
func _flipped_selection_candidates() -> Dictionary:
	var candidates: Dictionary = {}
	for placement_record: Resource in selected_placements:
		if placement_record is SurfacePlacement:
			var surface := (placement_record as SurfacePlacement).duplicate() as SurfacePlacement
			for _step in 2:
				var surface_orientation := K.rotate_surface_orientation(
					surface.face,
					surface.rotation_quarters,
					K.DIR_EAST,
					true
				)
				surface.face = int(surface_orientation["face"])
				surface.rotation_quarters = int(surface_orientation["rotation_quarters"])
			candidates[placement_record.get_instance_id()] = surface
		elif placement_record is PropPlacement:
			var prop := (placement_record as PropPlacement).duplicate() as PropPlacement
			var preserved_yaw := prop.yaw_eighths
			# Flip the orthogonal base pose, then restore the same explicit yaw.
			# The final transform remains one canonical forward/roll/yaw record.
			prop.yaw_eighths = 0
			for _step in 2:
				var prop_orientation := K.rotate_prop_orientation(
					prop.forward_face,
					prop.roll_quarters,
					K.DIR_EAST,
					true,
					0
				)
				prop.forward_face = int(prop_orientation["forward_face"])
				prop.roll_quarters = int(prop_orientation["roll_quarters"])
			prop.yaw_eighths = preserved_yaw
			candidates[placement_record.get_instance_id()] = prop
	return candidates


## Capture only the orientation fields consumed by each selected placement type.
func _selection_orientation_states(
	targets: Array[Resource],
	candidate_overrides: Dictionary
) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for target: Resource in targets:
		var source := candidate_overrides.get(target.get_instance_id(), target) as Resource
		if source is SurfacePlacement:
			states.append({
				"face": (source as SurfacePlacement).face,
				"rotation_quarters": (source as SurfacePlacement).rotation_quarters,
				"terrain_face_uids": Array((source as SurfacePlacement).terrain_face_uids),
			})
		elif source is PropPlacement:
			states.append({
				"forward_face": (source as PropPlacement).forward_face,
				"roll_quarters": (source as PropPlacement).roll_quarters,
				"yaw_eighths": (source as PropPlacement).yaw_eighths,
			})
		else:
			states.append({})
	return states


## Apply prevalidated orientation state through the document's scoped spatial path.
func _apply_selection_orientations(
	targets: Array[Resource],
	states: Array[Dictionary]
) -> void:
	if board == null or not board.apply_placement_spatial_states(targets, states):
		push_error("[Tile Studio] could not apply selection orientation state.")
		return
	# Rotation leaves palette and non-spatial board data unchanged, so this one
	# spatial notification is the complete observer surface for the action.
	board_mutated.emit(_mutation_mask_for_resources(targets))


## Commit orientation candidates through the one shared collision and undo path.
func _commit_selection_orientation_candidates(
	candidates: Dictionary,
	action_verb: String
) -> bool:
	if selected_placements.is_empty() or board == null:
		return false
	var error := _selection_spatial_error(candidates)
	if not error.is_empty():
		last_rejection = error
		push_error("[Tile Studio] selection %s rejected: %s." % [action_verb.to_lower(), error])
		return false

	var targets := selected_resources()
	var old_states := _selection_orientation_states(targets, {})
	var new_states := _selection_orientation_states(targets, candidates)
	last_rejection = ""
	var action := "%s %d placement%s" % [
		action_verb,
		targets.size(),
		"" if targets.size() == 1 else "s",
	]
	if undo_redo == null:
		_apply_selection_orientations(targets, new_states)
		return true
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(self, "_apply_selection_orientations", targets, new_states)
	undo_redo.add_undo_method(self, "_apply_selection_orientations", targets, old_states)
	undo_redo.commit_action()
	return true


## Rotate all selected placements in place through the shared collision validator.
func rotate_selection(axis: Vector3i, positive: bool) -> bool:
	return _commit_selection_orientation_candidates(
		_rotated_selection_candidates(axis, positive),
		"Rotate"
	)


## Flip all selected placements upside down as one validated undoable operation.
func flip_selection() -> bool:
	return _commit_selection_orientation_candidates(
		_flipped_selection_candidates(),
		"Flip"
	)


# --- Picking --------------------------------------------------------------

## Grid cell under the mouse, found by intersecting the active camera ray with
## the current Y layer. This works for both fixed and rotatable orthographic
## isometric views without a second placement representation.
## Pick the current editing plane for surfaces, Fill, and empty-space prop clicks.
## Prop brushes first try structural +Y floors so an elevated platform becomes
## the placement origin without sampling any visual height or relief data.
func pick_cell(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null:
		return {"hit": false, "cell": Vector3i.ZERO}

	# Terrain is the ground everything is placed on, so it is picked first and
	# unconditionally. There is no competing layer grid: a prop lands where the
	# sculpted surface actually is, and so do sculpt and paint strokes.
	var terrain_hit := _pick_terrain(camera, mouse_pos)
	if terrain_hit.get("hit", false):
		return terrain_hit

	# Direct PNG brushes have no plane of their own. A miss is a miss, so the
	# cursor cannot invent a paintable quad in empty space.
	if brush_is_surface() and brush_asset != null:
		return {"hit": false, "cell": Vector3i.ZERO}
	# Prop tools retain their explicit current-layer authoring plane.
	return _pick_current_layer(camera, mouse_pos)


## Intersect the camera ray with the authored terrain surface.
##
## The march walks the ray forward in world XZ and detects the step where it
## crosses from above the terrain to below it, then refines that step by
## bisection. Sampling the grid's own bilinear surface means picking agrees
## exactly with the rendered mesh and with the gameplay heights, instead of
## introducing a third opinion about where the ground is.
func _pick_terrain(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null:
		return {"hit": false}
	return pick_terrain_from_ray(
		camera.project_ray_origin(mouse_pos),
		camera.project_ray_normal(mouse_pos)
	)


## Intersect one explicit world-space ray with the authored terrain surface.
##
## Delegates to MTSTerrainRenderer.pick_face(), which tests the real displayed
## faces. This replaced a ray-march over sample_world_height(): that function
## reads only the TOP surface, so it could not see a vertical wall at all and a
## prop could never be placed on a wall band. It also gave painting and placement
## two different opinions about where the ground was. There is now exactly one.
##
## Exposed so material painting resolves its brush against the same faces a
## placement lands on.
func pick_terrain_from_ray(origin: Vector3, direction: Vector3) -> Dictionary:
	if board == null or board.terrain == null or board.terrain.is_empty():
		return {"hit": false}
	if direction.length_squared() <= 0.0 or terrain_renderer == null:
		return {"hit": false}

	var pick: Dictionary = terrain_renderer.pick_face(origin, direction.normalized())
	if pick.is_empty():
		return {"hit": false}
	var face: Dictionary = pick["face"]
	var point: Vector3 = pick["point"]
	if not face.has("grid_cell"):
		push_error("[Tile Studio] picked terrain face has no canonical grid cell.")
		return {"hit": false}
	var grid_cell: Vector3i = face["grid_cell"]
	return {
		"hit": true,
		# A whole terrain face has one stable lattice address. Using the face's
		# canonical minimum corner prevents two clicks on one slope from rounding
		# to different placement layers.
		"cell": grid_cell,
		"point": point,
		"normal": pick["normal"],
		"terrain_face": face,
		"support": null,
		"terrain": true,
	}


## Pick the horizontal plane represented by the current structural editing layer.
func _pick_current_layer(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(mouse_pos)
	var direction := camera.project_ray_normal(mouse_pos)
	var plane_y := float(current_y)

	if absf(direction.y) < 0.0001:
		return {"hit": false, "cell": Vector3i.ZERO}

	var t := (plane_y - origin.y) / direction.y
	if t < 0.0:
		return {"hit": false, "cell": Vector3i.ZERO}

	var point := origin + direction * t
	return {
		"hit": true,
		"cell": Vector3i(
			floori(point.x),
			current_y,
			floori(point.z)
		),
		"point": point,
		"support": null,
	}


## Return whether the active brush requires the dedicated edge target primitive.
func _uses_surface_edge_targeter() -> bool:
	return (
		brush_surface_edge_mode
		and brush_is_surface()
		and brush_surface_presentation != SurfacePlacement.Presentation.TERRAIN_PAINT
	)


## Ray-pick a canonical terrain edge without passing through pick_cell().
func _pick_grid_edge(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null or terrain_renderer == null:
		return {"hit": false}
	var target := terrain_renderer.pick_grid_edge(
		camera.project_ray_origin(mouse_pos),
		camera.project_ray_normal(mouse_pos)
	)
	return target if not target.is_empty() else {"hit": false}


## Update the cursor placement through the target primitive selected by the visible mode.
func update_hover(camera: Camera3D, mouse_pos: Vector2) -> void:
	var pick: Dictionary
	if _uses_surface_edge_targeter():
		pick = _pick_grid_edge(camera, mouse_pos)
	elif tool == Tool.FILL and has_fill_vertices():
		pick = _pick_fill_cell(camera, mouse_pos)
	else:
		pick = pick_cell(camera, mouse_pos)
	_apply_hover_pick(pick)


## Update the cursor placement from one explicit ray through the selected target primitive.
##
## Tests and bridge callers use this entry point, while editor mouse input reaches
## the same _apply_hover_pick() path through update_hover().
func update_hover_from_ray(origin: Vector3, direction: Vector3) -> void:
	var pick: Dictionary
	if _uses_surface_edge_targeter() and terrain_renderer != null:
		pick = terrain_renderer.pick_grid_edge(origin, direction)
		if pick.is_empty():
			pick = {"hit": false}
	else:
		pick = pick_terrain_from_ray(origin, direction)
	_apply_hover_pick(pick)


## Apply one pick record to the transient hover and rebuild the exact preview.
func _apply_hover_pick(pick: Dictionary) -> void:
	if not bool(pick.get("hit", false)):
		_surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
		if _preview_root != null:
			_preview_root.visible = false
		return

	_surface_grid_anchor = (
		int(pick.get("grid_anchor", SurfacePlacement.GridAnchor.CELL))
		if bool(pick.get("grid_edge", false))
		else SurfacePlacement.GridAnchor.CELL
	)
	var picked_cell: Vector3i = pick["cell"]
	var terrain_face: Dictionary = pick.get("terrain_face", {})
	if not terrain_face.is_empty():
		_active_prop_support_face = int(terrain_face["face"])
		if (
			terrain_splat_paint_enabled
			and _terrain_splat_follow_hover_face
			and (tool != Tool.FILL or fill_vertices.is_empty())
		):
			# Masked tile paint follows the pointed terrain face until Fill pins its plane.
			_terrain_splat_face = _active_prop_support_face
		if brush_is_surface() and brush_asset != null:
			# Texture painting follows the face actually hit, so the same cursor
			# naturally targets both top cells and every directed side band.
			brush_face = int(terrain_face["face"])
	elif tool != Tool.FILL or not has_fill_vertices():
		_active_prop_support_face = K.Face.POS_Y

	if brush_is_prop() and _prop_is_wall_supported() and not pick.has("point"):
		hover_valid = false
		hover_reason = "terrain wall pick has no world point"
		push_error("[Tile Studio] terrain wall pick has no world point.")
		if _preview_root != null:
			_preview_root.visible = false
		hover_changed.emit(hovered_cell, false, hover_reason)
		return

	var previous_hovered_cell := hovered_cell
	hovered_cell = _prop_origin_for_pick(picked_cell, pick)
	_evaluate_hover()
	_position_preview()
	if (
		tool == Tool.FILL
		and _fill_is_armed()
		and (
			(_fill_targets_terrain() and fill_vertices.is_empty())
			or (has_fill_vertices() and hovered_cell != previous_hovered_cell)
		)
	):
		# Terrain Fill has no ordinary asset ghost, so its uncommitted hovered cell
		# must enter the same preview pipeline before the first point is clicked.
		_refresh_fill_preview_from_hover()
	update_preview_visibility()
	hover_changed.emit(hovered_cell, hover_valid, hover_reason)


## Convert a terrain face address into a prop's canonical minimum-corner origin.
##
## TOP faces already store their minimum lattice corner. A wall face instead
## stores the terrain cell that owns it, so the exact picked face point determines
## the outside edge of the prop's oriented AABB. No display-only offset is applied.
func _prop_origin_for_pick(
	picked_cell: Vector3i,
	terrain_pick: Dictionary
) -> Vector3i:
	if not brush_is_prop() or not _prop_is_wall_supported():
		return picked_cell

	var origin := picked_cell
	var face_point: Vector3 = terrain_pick["point"]
	var normal := K.face_normal(_active_prop_support_face)
	var bounds := _brush_box()
	if normal.x > 0:
		origin.x = roundi(face_point.x)
	elif normal.x < 0:
		origin.x = roundi(face_point.x) - bounds.x
	elif normal.z > 0:
		origin.z = roundi(face_point.z)
	elif normal.z < 0:
		origin.z = roundi(face_point.z) - bounds.z
	return origin


## Evaluate whether the current hover can be committed without occupancy conflicts.
func _evaluate_hover() -> void:
	if board == null:
		hover_valid = false
		hover_reason = ""
		return
	hover_valid = false
	hover_reason = ""
	if terrain_splat_paint_enabled:
		var splat_result := _validate_terrain_splat_origin(
			hovered_cell,
			tool == Tool.ERASE,
			replace_enabled
		)
		hover_valid = bool(splat_result.get("valid", false))
		hover_reason = String(splat_result.get("reason", ""))
		return
	if not has_brush():
		return
	var candidate := _placement_for_origin(hovered_cell)
	var result := _validate_placement(candidate)
	hover_valid = bool(result["valid"])
	hover_reason = String(result["reason"])

# --- Fill -----------------------------------------------------------------

## Clear the transient point-defined Fill shape without changing the active brush.
##
## Vertices and preview candidates belong only to this controller. BoardDocument
## remains the one authoritative source for placements and changes only on Enter.
func _reset_fill_state() -> void:
	fill_vertices.clear()
	_fill_active_origins.clear()
	_fill_active_valid_origins.clear()
	_fill_active_blocked_origins.clear()
	_fill_first_rejection = ""
	_fill_preview_vertices.clear()
	_fill_preview_origins.clear()
	_fill_preview_valid_origins.clear()
	_fill_preview_blocked_origins.clear()
	_clear_fill_preview()


## Return whether Fill currently has at least one authored point.
func has_fill_vertices() -> bool:
	return not fill_vertices.is_empty()


## Return the number of points defining the current line or polygon.
func fill_vertex_count() -> int:
	return fill_vertices.size()


## Return the number of valid placement stamps in the current Fill preview.
func fill_valid_count() -> int:
	return _fill_active_valid_origins.size()


## Return the number of blocked placement stamps in the current Fill preview.
func fill_blocked_count() -> int:
	return _fill_active_blocked_origins.size()


## Add the hovered cell as the next Fill point and rebuild the complete preview.
##
## One point previews one stamp, two points define a line, and three or more
## points define a closed polygon that is committed only when the user presses Enter.
func add_fill_vertex_at_hover() -> bool:
	if tool != Tool.FILL or not _fill_is_armed() or board == null:
		return false
	if fill_vertices.has(hovered_cell):
		return false

	fill_vertices.append(hovered_cell)
	_refresh_fill_candidates()
	update_preview_visibility()
	return true


## Remove the newest Fill point so the polygon can be corrected before commit.
func remove_last_fill_vertex() -> bool:
	if fill_vertices.is_empty():
		return false
	fill_vertices.pop_back()
	_refresh_fill_candidates()
	update_preview_visibility()
	return true


## Cancel the current Fill shape without mutating BoardDocument.
func cancel_fill() -> void:
	_reset_fill_state()
	update_preview_visibility()


## Commit every valid stamp in the current Fill shape as one undoable action.
##
## Blocked stamps are shown in red before commit and are omitted explicitly; if
## every stamp is blocked, the shape remains available for correction.
func commit_fill() -> bool:
	if fill_vertices.is_empty() or not _fill_is_armed() or board == null:
		return false

	if _fill_targets_terrain():
		# Terrain mutation and its undo entry belong to the viewport, so the shape
		# is handed over rather than applied here. Only the cells this terrain tool
		# can actually edit travel with it; blocked cells were already shown red.
		var terrain_evaluated := _evaluate_terrain_fill_candidates(_fill_active_origins)
		var terrain_origins: Array[Vector3i] = terrain_evaluated["valid_origins"]
		if terrain_origins.is_empty():
			var terrain_reason := String(terrain_evaluated.get("first_rejection", ""))
			if terrain_reason.is_empty():
				terrain_reason = "Fill shape does not contain one editable terrain cell."
			_reject(terrain_reason)
			return false
		if terrain_splat_paint_enabled:
			terrain_material_tile_paint_requested.emit(
				terrain_material_target_uids_for_origins(
					terrain_origins,
					_terrain_splat_face
				),
				false,
				replace_enabled,
				true
			)
		else:
			terrain_fill_committed.emit(terrain_origins)
		_reset_fill_state()
		update_preview_visibility()
		return true

	var evaluated := _evaluate_placement_candidates(_fill_active_origins)
	var placements: Array[Resource] = evaluated["placements"]
	var displaced: Array[Resource] = evaluated["replacements"]
	if placements.is_empty():
		var reason := String(evaluated.get(
			"first_rejection",
			"Fill shape does not contain one complete stamp."
		))
		if reason.is_empty():
			reason = "Fill shape does not contain one complete stamp."
		_reject(reason)
		return false

	var noun := "surfaces" if brush_is_surface() else "props"
	if displaced.is_empty():
		_commit_placements_bulk(
			placements,
			"Fill %d %s" % [placements.size(), noun]
		)
	else:
		_commit_replacements(
			placements,
			displaced,
			"Replace %d %s with Fill" % [displaced.size(), noun]
		)
	_reset_fill_state()
	update_preview_visibility()
	return true


## Pick on the plane locked by the first Fill point.
##
## Surface brushes use their actual face plane, floor props use XZ, and wall-slot
## props use the plane implied by their explicit forward face and support setting.
func _pick_fill_cell(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null:
		return {"hit": false, "cell": Vector3i.ZERO}
	if fill_vertices.is_empty():
		return pick_cell(camera, mouse_pos)

	var anchor := fill_vertices[0]
	var normal := Vector3(K.face_normal(_fill_face()))
	var plane_point := _fill_plane_point(anchor)
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_direction := camera.project_ray_normal(mouse_pos)
	var denominator := normal.dot(ray_direction)
	if absf(denominator) < 0.0001:
		return {"hit": false, "cell": Vector3i.ZERO}

	var distance := normal.dot(plane_point - ray_origin) / denominator
	if distance < 0.0:
		return {"hit": false, "cell": Vector3i.ZERO}

	var point := ray_origin + ray_direction * distance
	var cell := anchor
	for axis: Vector3i in _fill_plane_axes():
		if axis.x != 0:
			cell.x = floori(point.x)
		elif axis.y != 0:
			cell.y = floori(point.y)
		elif axis.z != 0:
			cell.z = floori(point.z)
	return {
		"hit": true,
		"cell": cell,
		"point": point,
		"support": null,
	}


## Return the face whose plane owns Fill coordinates for the active brush.
func _fill_face() -> int:
	if terrain_splat_paint_enabled:
		# Directional splat Fill uses the same explicit plane shown by the dropdown.
		return _terrain_splat_face
	if terrain_fill_enabled:
		# Sculpt and footprint Fill remain ground-plane terrain tools.
		return K.Face.POS_Y
	if brush_is_surface():
		return brush_face
	if brush_is_prop() and _prop_is_wall_supported():
		return _active_prop_support_face
	if brush_is_prop() and brush_prop_support == PropPlacement.SUPPORT_WALL:
		return brush_prop_forward_face
	return K.Face.POS_Y


## Return one point on the exact placement plane locked by the first Fill point.
##
## Positive surface faces and negative wall-prop facings use different box-side
## conventions; the offsets below mirror their canonical placement transforms.
func _fill_plane_point(anchor: Vector3i) -> Vector3:
	var point := Vector3(anchor)
	if brush_is_surface() or terrain_splat_paint_enabled:
		var active_face := _fill_face()
		match active_face:
			K.Face.NEG_Y:
				point.y += 1.0
			K.Face.POS_X:
				point.x += 1.0
			K.Face.POS_Z:
				point.z += 1.0
	elif (
		brush_is_prop() and _prop_is_wall_supported()
	) or (
		brush_is_prop() and brush_prop_support == PropPlacement.SUPPORT_WALL
	):
		var normal := K.face_normal(_fill_face())
		var bounds := _brush_box()
		if normal.x < 0:
			point.x += float(bounds.x)
		elif normal.z < 0:
			point.z += float(bounds.z)
	return point


## Return the two positive lattice axes spanning the active Fill plane.
func _fill_plane_axes() -> Array[Vector3i]:
	var raw_axes := SurfacePlacement.footprint_axes(_fill_face())
	var axes: Array[Vector3i] = []
	for axis: Vector3i in raw_axes:
		axes.append(axis)
	return axes


## Return the explicit grid step along the active Fill plane axes.
##
## Direct textures use the toolbar metre width, while props use their oriented
## occupancy box.
func _fill_stamp_size() -> Vector2i:
	if _fill_targets_terrain():
		# The toolbar Brush width IS the terrain brush width, so a filled line is
		# exactly as thick as a dragged stroke of the same width would have been.
		return Vector2i.ONE * surface_grid_stroke_size_m
	if brush_is_surface() and brush_asset != null:
		# Direct textures advance on the toolbar's metre grid; the PNG footprint
		# remains solely responsible for UV repeat scale.
		return Vector2i.ONE * surface_grid_stroke_size_m
	if brush_is_surface():
		return _brush_rotated_surface_footprint()

	var axes := _fill_plane_axes()
	var bounds := _brush_box()
	return Vector2i(
		maxi(1, _axis_extent(bounds, axes[0])),
		maxi(1, _axis_extent(bounds, axes[1]))
	)


## Return a box extent measured along one positive cardinal lattice axis.
func _axis_extent(bounds: Vector3i, axis: Vector3i) -> int:
	return (
		absi(axis.x) * bounds.x
		+ absi(axis.y) * bounds.y
		+ absi(axis.z) * bounds.z
	)


## Project a cell delta onto one cardinal lattice axis.
func _axis_distance(delta: Vector3i, axis: Vector3i) -> int:
	return delta.x * axis.x + delta.y * axis.y + delta.z * axis.z


## Project one world cell onto integer coordinates in the active Fill plane.
func _cell_to_fill_point(cell: Vector3i) -> Vector2i:
	var axes := _fill_plane_axes()
	return Vector2i(
		_axis_distance(cell, axes[0]),
		_axis_distance(cell, axes[1])
	)


## Convert one Fill-plane point back to a world origin on the locked plane.
func _fill_point_to_cell(point: Vector2i, anchor: Vector3i) -> Vector3i:
	var anchor_point := _cell_to_fill_point(anchor)
	var axes := _fill_plane_axes()
	return (
		anchor
		+ axes[0] * (point.x - anchor_point.x)
		+ axes[1] * (point.y - anchor_point.y)
	)


## Generate size-aligned origins for a point, line, or closed polygon.
func _generate_fill_origins(vertices: Array[Vector3i]) -> Array[Vector3i]:
	if vertices.is_empty() or not _fill_is_armed():
		return []
	if vertices.size() == 1:
		return [vertices[0]]
	if fill_shape == FillShape.PATH or vertices.size() == 2:
		return _generate_polyline_origins(vertices)

	var points := _project_fill_vertices(vertices)
	if _polygon_twice_area(points) == 0:
		return _generate_polyline_origins(vertices)
	return _generate_polygon_origins(points, vertices[0])


## Project every clicked world vertex into the locked two-dimensional Fill plane.
func _project_fill_vertices(vertices: Array[Vector3i]) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	for vertex: Vector3i in vertices:
		points.append(_cell_to_fill_point(vertex))
	return points


## Generate a Bresenham polyline on the active tool's explicit grid lattice.
##
## Direct textures advance by Grid stroke metres; props advance
## by their complete footprint or oriented occupancy box.
func _generate_polyline_origins(vertices: Array[Vector3i]) -> Array[Vector3i]:
	var points := _project_fill_vertices(vertices)
	var anchor_point := points[0]
	var stamp_size := _fill_stamp_size()
	var lattice_points: Array[Vector2i] = []
	for point: Vector2i in points:
		lattice_points.append(Vector2i(
			roundi(float(point.x - anchor_point.x) / float(stamp_size.x)),
			roundi(float(point.y - anchor_point.y) / float(stamp_size.y))
		))

	var origins: Array[Vector3i] = []
	var seen: Dictionary = {}
	for segment_index in lattice_points.size() - 1:
		for lattice_point: Vector2i in _bresenham_points(
			lattice_points[segment_index],
			lattice_points[segment_index + 1]
		):
			var plane_point := Vector2i(
				anchor_point.x + lattice_point.x * stamp_size.x,
				anchor_point.y + lattice_point.y * stamp_size.y
			)
			var origin := _fill_point_to_cell(plane_point, vertices[0])
			var key := K.voxel_key(origin)
			if seen.has(key):
				continue
			seen[key] = true
			origins.append(origin)
	return origins


## Return every integer point on one inclusive Bresenham line.
func _bresenham_points(start: Vector2i, finish: Vector2i) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	var current := start
	var delta_x := absi(finish.x - start.x)
	var step_x := 1 if start.x < finish.x else -1
	var delta_y := absi(finish.y - start.y)
	var step_y := 1 if start.y < finish.y else -1
	var error := delta_x - delta_y

	while true:
		points.append(current)
		if current == finish:
			break
		var doubled_error := error * 2
		if doubled_error > -delta_y:
			error -= delta_y
			current.x += step_x
		if doubled_error < delta_x:
			error += delta_x
			current.y += step_y
	return points


## Return twice the signed polygon area without introducing fractional math.
func _polygon_twice_area(points: Array[Vector2i]) -> int:
	var area := 0
	for index in points.size():
		var current := points[index]
		var following := points[(index + 1) % points.size()]
		area += current.x * following.y - following.x * current.y
	return area


## Generate every complete, size-aligned stamp contained by a closed polygon.
func _generate_polygon_origins(
	points: Array[Vector2i],
	anchor: Vector3i
) -> Array[Vector3i]:
	var min_point := points[0]
	var max_point := points[0]
	for point: Vector2i in points:
		min_point.x = mini(min_point.x, point.x)
		min_point.y = mini(min_point.y, point.y)
		max_point.x = maxi(max_point.x, point.x)
		max_point.y = maxi(max_point.y, point.y)

	var anchor_point := points[0]
	var stamp_size := _fill_stamp_size()
	var min_lattice_x := floori(
		float(min_point.x - anchor_point.x) / float(stamp_size.x)
	)
	var max_lattice_x := ceili(
		float(max_point.x - anchor_point.x) / float(stamp_size.x)
	)
	var min_lattice_y := floori(
		float(min_point.y - anchor_point.y) / float(stamp_size.y)
	)
	var max_lattice_y := ceili(
		float(max_point.y - anchor_point.y) / float(stamp_size.y)
	)
	var origins: Array[Vector3i] = []

	for lattice_y in range(min_lattice_y, max_lattice_y + 1):
		for lattice_x in range(min_lattice_x, max_lattice_x + 1):
			var plane_origin := Vector2i(
				anchor_point.x + lattice_x * stamp_size.x,
				anchor_point.y + lattice_y * stamp_size.y
			)
			if not _stamp_centre_is_inside_polygon(plane_origin, points):
				continue
			origins.append(_fill_point_to_cell(plane_origin, anchor))
	return origins


## Return whether one stamp's visible centre lies inside or on the polygon.
##
## Both the yellow control path and every stamp centre receive the same half-stamp
## translation from their stored origins. Testing their origin coordinates is
## therefore the exact same containment test without fractional coordinate drift.
## Centre sampling avoids the unwanted one-footprint erosion that occurs when every
## covered unit cell is required to fit inside the boundary.
func _stamp_centre_is_inside_polygon(
	origin: Vector2i,
	polygon: Array[Vector2i]
) -> bool:
	return _point_is_in_polygon(Vector2(origin), polygon)


## Test one point against a polygon with an edge-inclusive even-odd rule.
func _point_is_in_polygon(point: Vector2, polygon: Array[Vector2i]) -> bool:
	var inside := false
	var previous_index := polygon.size() - 1
	for index in polygon.size():
		var current := Vector2(polygon[index])
		var previous := Vector2(polygon[previous_index])
		if _point_is_on_segment(point, previous, current):
			return true
		if (current.y > point.y) != (previous.y > point.y):
			var crossing_x := (
				(previous.x - current.x)
				* (point.y - current.y)
				/ (previous.y - current.y)
				+ current.x
			)
			if point.x < crossing_x:
				inside = not inside
		previous_index = index
	return inside


## Return whether a point lies on one finite line segment within grid precision.
func _point_is_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	var segment := finish - start
	var relative := point - start
	if absf(segment.cross(relative)) > 0.0001:
		return false
	var projection := relative.dot(segment)
	return projection >= 0.0 and projection <= segment.length_squared()


## Rebuild the active origins, validation groups, and MultiMesh preview.
func _refresh_fill_candidates() -> void:
	if fill_vertices.is_empty() or not _fill_is_armed() or board == null:
		_fill_active_origins.clear()
		_fill_active_valid_origins.clear()
		_fill_active_blocked_origins.clear()
		_fill_first_rejection = ""
		_fill_preview_vertices.clear()
		_fill_preview_origins.clear()
		_fill_preview_valid_origins.clear()
		_fill_preview_blocked_origins.clear()
		_clear_fill_preview()
		return

	_fill_active_origins = _generate_fill_origins(fill_vertices)
	var evaluated := (
		_evaluate_terrain_fill_candidates(_fill_active_origins)
		if _fill_targets_terrain()
		else _evaluate_placement_candidates(_fill_active_origins)
	)
	_fill_active_valid_origins = evaluated["valid_origins"]
	_fill_active_blocked_origins = evaluated["blocked_origins"]
	_fill_first_rejection = String(evaluated["first_rejection"])
	_refresh_fill_preview_from_hover()


## Classify terrain Fill origins into cells this terrain tool can actually edit.
##
## Sculpting and Footprint Erase can only act on cells that already exist, so an
## origin outside the drawn footprint is reported blocked rather than silently
## skipped. Footprint Draw is the one terrain operation that may create cells, so
## for it every origin inside the addressable lattice is valid.
##
## The returned keys deliberately match _evaluate_placement_candidates() so the
## preview and commit paths need no branch beyond choosing the evaluator.
func _evaluate_terrain_fill_candidates(origins: Array[Vector3i]) -> Dictionary:
	var valid_origins: Array[Vector3i] = []
	var blocked_origins: Array[Vector3i] = []
	var first_rejection := ""
	var terrain: TerrainMesh = board.terrain if board != null else null
	for origin: Vector3i in origins:
		if terrain_splat_paint_enabled:
			var splat_result := _validate_terrain_splat_origin(
				origin,
				false,
				replace_enabled
			)
			if bool(splat_result.get("valid", false)):
				valid_origins.append(origin)
			else:
				blocked_origins.append(origin)
				if first_rejection.is_empty():
					first_rejection = String(splat_result.get(
						"reason",
						"splatmap tile is blocked"
					))
			continue
		var cell := Vector2i(origin.x, origin.z)
		var accepted := false
		if terrain_fill_allows_new_cells:
			# Draw may grow the lattice, so the only limit is the authored maximum.
			accepted = (
				absi(cell.x) < TerrainMesh.MAX_AXIS_CELLS
				and absi(cell.y) < TerrainMesh.MAX_AXIS_CELLS
			)
			if not accepted and first_rejection.is_empty():
				first_rejection = (
					"Cell %s is outside the %d cell authoring limit."
					% [cell, TerrainMesh.MAX_AXIS_CELLS]
				)
		else:
			accepted = terrain != null and terrain.is_cell_filled(cell)
			if not accepted and first_rejection.is_empty():
				first_rejection = (
					"Cell %s is not part of the drawn footprint." % cell
				)
		if accepted:
			valid_origins.append(origin)
		else:
			blocked_origins.append(origin)
	return {
		"valid_origins": valid_origins,
		"blocked_origins": blocked_origins,
		"first_rejection": first_rejection,
	}


## Rebuild every pending preview stamp through the current hovered endpoint.
##
## The hovered point is a visible tentative endpoint. Clicking makes it authored;
## until then it affects only these derived preview arrays, never the commit batch.
func _refresh_fill_preview_from_hover() -> void:
	_fill_preview_vertices.clear()
	_fill_preview_vertices.assign(fill_vertices)
	if _fill_preview_vertices.is_empty():
		if _fill_targets_terrain():
			# This is derived hover state only; Enter still commits clicked vertices.
			_fill_preview_vertices.append(hovered_cell)
	elif hovered_cell != _fill_preview_vertices[-1]:
		_fill_preview_vertices.append(hovered_cell)

	_fill_preview_origins = _generate_fill_origins(_fill_preview_vertices)
	var evaluated := (
		_evaluate_terrain_fill_candidates(_fill_preview_origins)
		if _fill_targets_terrain()
		else _evaluate_placement_candidates(_fill_preview_origins)
	)
	_fill_preview_valid_origins = evaluated["valid_origins"]
	_fill_preview_blocked_origins = evaluated["blocked_origins"]
	_fill_preview_texture_placement = evaluated.get("preview_placement", null) as SurfacePlacement
	_update_fill_preview()


## Build one placement Resource from the active asset-or-slot brush source.
func _placement_for_origin(origin: Vector3i) -> Resource:
	if brush_is_surface():
		return _surface_placement_for_origin(origin)
	return _prop_placement_for_origin(origin)


## Return canonical occupancy keys for one surface, prop, or surfaced-box candidate.
func _placement_occupancy_keys(placement: Resource) -> PackedStringArray:
	if placement is SurfacePlacement:
		return (placement as SurfacePlacement).terrain_face_uids
	if placement is PropPlacement:
		return board.prop_solid_keys(placement as PropPlacement)
	return PackedStringArray()


## Return the existing same-kind placements this candidate would displace.
##
## Direct terrain textures deliberately exclude the same asset: repainting a
## texture over itself is a no-op, while different texture assets may be replaced.
func _replacement_conflicts_for(placement: Resource) -> Array[Resource]:
	var displaced: Array[Resource] = []
	if board == null:
		return displaced
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		for conflicting_surface: SurfacePlacement in board.surface_conflicting_placements(
			surface
		):
			if (
				not surface.asset_id.is_empty()
				and conflicting_surface.asset_id == surface.asset_id
			):
				continue
			displaced.append(conflicting_surface)
	elif placement is PropPlacement:
		for conflicting_prop: PropPlacement in board.prop_conflicting_placements(
			placement as PropPlacement
		):
			displaced.append(conflicting_prop)
	return displaced


## Retain only unpainted terrain faces of one non-replacing surface stamp.
##
## The placement keeps its asset and UV frame while dropping the faces another
## placement already owns, so a partially blocked stroke paints what it can
## instead of being rejected wholesale.
func _retain_available_surface_faces(placement: SurfacePlacement) -> Dictionary:
	var full_result := board.validate_surface(placement)
	if bool(full_result["valid"]) or (full_result["conflicts"] as Array).is_empty():
		return full_result

	var available_uids := PackedStringArray()
	for uid: String in placement.terrain_face_uids:
		var occupant := board.surface_at_paint_uid(uid)
		if occupant == null or occupant == placement:
			available_uids.append(uid)
	if available_uids.is_empty():
		return {
			"valid": false,
			"reason": "",
			"conflicts": [],
			"occupied_surface_no_op": true,
		}
	placement.terrain_face_uids = available_uids
	return board.validate_surface(placement)


## Remove candidate faces that already use the selected direct texture.
##
## Replace mode means "replace other textures"; same-texture faces remain owned by
## their existing placement and are never removed and recreated by the stroke.
func _retain_faces_not_using_brush_asset(placement: SurfacePlacement) -> bool:
	if placement.asset_id.is_empty():
		return true
	var retained_uids := PackedStringArray()
	for uid: String in placement.terrain_face_uids:
		var occupant := board.surface_at_paint_uid(uid)
		if occupant == null or occupant.asset_id != placement.asset_id:
			retained_uids.append(uid)
	placement.terrain_face_uids = retained_uids
	return not retained_uids.is_empty()


## Validate one placement candidate against the current BoardDocument.
func _validate_placement(placement: Resource) -> Dictionary:
	var result: Dictionary
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		# A Fill candidate already owns its union of exact heightfield faces, and
		# single-click candidates are conformed at construction. Anything still
		# unconformed is resolved here so validation never sees empty coverage.
		if not surface.asset_id.is_empty() and surface.terrain_face_uids.is_empty():
			var terrain_error := _conform_texture_surface_to_terrain(surface)
			if not terrain_error.is_empty():
				return {
					"valid": false,
					"reason": terrain_error,
					"conflicts": [],
				}
		if surface.is_overlay():
			# Native decals claim no occupancy, so every stamp remains independently
			# selectable even when its visible pixels overlap another decal.
			return board.validate_surface(surface)
		if not replace_enabled:
			result = _retain_available_surface_faces(surface)
		else:
			if not _retain_faces_not_using_brush_asset(surface):
				return {
					"valid": false,
					"reason": "",
					"conflicts": [],
					"occupied_surface_no_op": true,
				}
			result = board.validate_surface(surface)
	elif placement is PropPlacement:
		result = board.validate_prop(placement as PropPlacement)
	else:
		return {
			"valid": false,
			"reason": "Fill produced an unsupported placement type.",
			"conflicts": [],
		}

	if bool(result["valid"]) or not replace_enabled:
		return result

	var displaced := _replacement_conflicts_for(placement)
	if displaced.is_empty():
		return result
	var noun := "surface"
	if placement is PropPlacement:
		noun = "prop"
	return {
		"valid": true,
		"reason": "will replace %d existing %s%s" % [
			displaced.size(),
			noun,
			"" if displaced.size() == 1 else "s",
		],
		"conflicts": result["conflicts"],
		"replacement_conflicts": displaced,
	}
## Merge every direct-texture Fill stamp into one canonical heightfield placement.
##
## Each toolbar-sized grid origin resolves through TerrainRenderer first, so the
## resulting cell union follows real slope triangles and vertical wall bands.
func _build_texture_fill_candidate(origins: Array[Vector3i]) -> Dictionary:
	if origins.is_empty():
		return {"placement": null, "covered_origins": [], "missed_origins": origins, "error": "Fill contains no grid cells."}
	var combined := SurfacePlacement.create(
		brush_asset.asset_id,
		origins[0],
		brush_face,
		brush_quarters
	)
	var cells_by_key: Dictionary = {}
	var covered_origins: Array[Vector3i] = []
	var missed_origins: Array[Vector3i] = []
	var first_error := ""
	for origin: Vector3i in origins:
		var stamp := SurfacePlacement.create(
			brush_asset.asset_id,
			origin,
			brush_face,
			brush_quarters
		)
		var terrain_error := _conform_texture_surface_to_terrain(stamp)
		if not terrain_error.is_empty():
			missed_origins.append(origin)
			if first_error.is_empty():
				first_error = terrain_error
			continue
		covered_origins.append(origin)
		for uid: String in stamp.terrain_face_uids:
			cells_by_key[uid] = true
	var combined_uids := PackedStringArray()
	for value: Variant in cells_by_key.keys():
		combined_uids.append(String(value))
	combined.terrain_face_uids = combined_uids
	if combined_uids.is_empty():
		return {
			"placement": combined,
			"covered_origins": covered_origins,
			"missed_origins": missed_origins,
			"error": first_error if not first_error.is_empty() else "Fill touches no heightfield faces.",
		}
	return {
		"placement": combined,
		"covered_origins": covered_origins,
		"missed_origins": missed_origins,
		"error": first_error,
	}


## Validate one merged direct-texture Fill placement without quad or per-stamp occupancy paths.
func _evaluate_direct_texture_fill(origins: Array[Vector3i]) -> Dictionary:
	var placements: Array[Resource] = []
	var displaced: Array[Resource] = []
	var built := _build_texture_fill_candidate(origins)
	var candidate := built.get("placement", null) as SurfacePlacement
	var covered_origins: Array[Vector3i] = []
	covered_origins.assign(built.get("covered_origins", []))
	var missed_origins: Array[Vector3i] = []
	missed_origins.assign(built.get("missed_origins", []))
	var first_rejection := String(built.get("error", ""))
	if candidate == null or candidate.terrain_face_uids.is_empty():
		return {
			"placements": placements,
			"replacements": displaced,
			"valid_origins": [],
			"blocked_origins": origins,
			"first_rejection": first_rejection,
			"occupied_surface_no_op": false,
			"preview_placement": candidate,
		}

	var result := _validate_placement(candidate)
	var candidate_valid := bool(result.get("valid", false))
	if candidate_valid:
		placements.append(candidate)
		var reported_replacements: Variant = result.get("replacement_conflicts", [])
		if reported_replacements is Array:
			for reported_placement: Variant in reported_replacements:
				if reported_placement is Resource and not displaced.has(reported_placement):
					displaced.append(reported_placement as Resource)
	elif first_rejection.is_empty():
		first_rejection = String(result.get("reason", "placement is blocked"))
	return {
		"placements": placements,
		"replacements": displaced,
		"valid_origins": covered_origins if candidate_valid else [],
		"blocked_origins": missed_origins if candidate_valid else origins,
		"first_rejection": first_rejection,
		"occupied_surface_no_op": bool(result.get("occupied_surface_no_op", false)),
		"preview_placement": candidate,
	}


## Validate every generated Fill origin, using one explicit face-cell union for direct textures.
func _evaluate_placement_candidates(origins: Array[Vector3i]) -> Dictionary:
	if tool == Tool.FILL and brush_is_surface() and brush_asset != null:
		return _evaluate_direct_texture_fill(origins)
	var placements: Array[Resource] = []
	var displaced: Array[Resource] = []
	var valid_origins: Array[Vector3i] = []
	var blocked_origins: Array[Vector3i] = []
	var reserved: Dictionary = {}
	var first_rejection := ""
	var occupied_surface_no_op := false

	if not has_brush() or board == null:
		return {
			"placements": placements,
			"replacements": displaced,
			"valid_origins": valid_origins,
			"blocked_origins": blocked_origins,
			"first_rejection": "no brush or board",
			"occupied_surface_no_op": false,
		}

	for origin: Vector3i in origins:
		var candidate := _placement_for_origin(origin)
		var result := _validate_placement(candidate)
		var candidate_valid := bool(result["valid"])
		var keys := _placement_occupancy_keys(candidate)
		# Dictionary values are Variant. Copying resource entries avoids treating
		# the ordinary untyped empty fallback as an Array[Resource] at runtime.
		var replacement_conflicts: Array[Resource] = []
		var reported_replacements: Variant = result.get(
			"replacement_conflicts",
			[]
		)
		if reported_replacements is Array:
			for reported_placement: Variant in reported_replacements:
				if reported_placement is Resource:
					replacement_conflicts.append(reported_placement as Resource)

		if candidate_valid:
			for key: String in keys:
				if reserved.has(key):
					candidate_valid = false
					if first_rejection.is_empty():
						first_rejection = "placement overlaps another stamp in this Fill shape"
					break

		if not candidate_valid:
			if bool(result.get("occupied_surface_no_op", false)):
				occupied_surface_no_op = true
				continue
			blocked_origins.append(origin)
			if first_rejection.is_empty():
				first_rejection = String(result.get("reason", "placement is blocked"))
			continue

		for key: String in keys:
			reserved[key] = candidate
		for conflicting_placement: Resource in replacement_conflicts:
			if not displaced.has(conflicting_placement):
				displaced.append(conflicting_placement)
		placements.append(candidate)
		valid_origins.append(origin)

	return {
		"placements": placements,
		"replacements": displaced,
		"valid_origins": valid_origins,
		"blocked_origins": blocked_origins,
		"first_rejection": first_rejection,
		"occupied_surface_no_op": occupied_surface_no_op,
	}
func _update_fill_preview() -> void:
	if _fill_preview_root == null:
		return
	if _fill_preview_vertices.is_empty():
		_clear_fill_preview()
		return

	if _fill_targets_terrain():
		# Terrain Fill owns no asset and no occupancy volume, so its preview is the
		# outlined cell footprint alone. The guide pass below already draws exactly
		# that from the same origins the commit consumes.
		if _fill_preview_texture != null:
			_fill_preview_texture.mesh = null
			_fill_preview_texture.visible = false
		if _fill_preview_texture_outline != null:
			_fill_preview_texture_outline.mesh = null
			_fill_preview_texture_outline.visible = false
		_set_fill_preview_batch(_fill_preview_valid, [], Color.WHITE)
		_set_fill_preview_batch(_fill_preview_blocked, [], Color.WHITE)
		_update_fill_preview_guides()
		_fill_preview_root.visible = true
		return

	if brush_is_surface() and brush_asset != null:
		_set_texture_fill_preview(
			_fill_preview_texture_placement,
			not _fill_preview_valid_origins.is_empty()
		)
		_update_fill_preview_guides()
		_fill_preview_root.visible = true
		return
	if _fill_preview_texture != null:
		_fill_preview_texture.mesh = null
		_fill_preview_texture.visible = false
	if _fill_preview_texture_outline != null:
		_fill_preview_texture_outline.mesh = null
		_fill_preview_texture_outline.visible = false

	_set_fill_preview_batch(
		_fill_preview_valid,
		_fill_preview_valid_origins,
		Color(0.08, 0.88, 1.0, 0.34)
	)
	_set_fill_preview_batch(
		_fill_preview_blocked,
		_fill_preview_blocked_origins,
		Color(1.0, 0.12, 0.12, 0.42)
	)
	_update_fill_preview_guides()
	_fill_preview_root.visible = true


## Set one batch of prop Fill origins.
##
## Direct PNG textures never enter this function; their exact terrain triangles
## are drawn by _set_texture_fill_preview().
func _set_fill_preview_batch(
	target: MultiMeshInstance3D,
	origins: Array[Vector3i],
	tint: Color
) -> void:
	if target == null:
		return
	if origins.is_empty():
		target.multimesh = null
		target.visible = false
		return

	var preview_mesh: Mesh
	var preview_material: Material
	# A surface brush always paints canonical heightfield faces, so a Fill preview
	# built from its own quad would be a second, disagreeing surface representation.
	if brush_is_surface():
		push_error("[Tile Studio] direct-texture Fill preview must use heightfield faces.")
		target.multimesh = null
		target.visible = false
		return
	if brush_is_prop():
		preview_mesh = (
			ProxyMeshBuilder.collision_preview_meshes(_brush_prop_preview_voxels())["volume"]
			as Mesh
		)
		preview_material = _build_prop_fill_preview_material(tint)
	else:
		var box := BoxMesh.new()
		box.size = Vector3(_brush_prop_canonical_bounds())
		preview_mesh = box
		preview_material = _build_prop_fill_preview_material(tint)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = preview_mesh
	multimesh.instance_count = origins.size()
	for index in origins.size():
		var instance_transform := Transform3D.IDENTITY
		if brush_is_surface():
			instance_transform = surface_transform(
				origins[index],
				brush_face,
				brush_quarters,
				brush_asset
			)
		elif brush_is_prop():
			instance_transform.origin = Vector3(origins[index])
		else:
			instance_transform = _brush_prop_center_transform(origins[index])
		multimesh.set_instance_transform(index, instance_transform)

	target.multimesh = multimesh
	target.material_override = preview_material
	target.visible = true


## Create exact direct-texture Fill preview nodes once, including after live reloads.
func _ensure_texture_fill_preview_nodes() -> void:
	if _fill_preview_root == null:
		return
	if _fill_preview_texture == null:
		_fill_preview_texture = MeshInstance3D.new()
		_fill_preview_texture.name = "TextureFaces"
		_fill_preview_texture.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fill_preview_root.add_child(_fill_preview_texture)
	if _fill_preview_texture_outline == null:
		_fill_preview_texture_outline = MeshInstance3D.new()
		_fill_preview_texture_outline.name = "TextureFaceContours"
		_fill_preview_texture_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var outline_material := StandardMaterial3D.new()
		outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		outline_material.albedo_color = Color(0.03, 0.04, 0.06, 1.0)
		outline_material.no_depth_test = true
		outline_material.render_priority = PREVIEW_RENDER_PRIORITY + 2
		_fill_preview_texture_outline.material_override = outline_material
		_fill_preview_root.add_child(_fill_preview_texture_outline)


## Draw the merged direct-texture Fill on its exact top or side heightfield faces.
func _set_texture_fill_preview(placement: SurfacePlacement, is_valid: bool) -> void:
	_ensure_texture_fill_preview_nodes()
	_fill_preview_valid.multimesh = null
	_fill_preview_blocked.multimesh = null
	_fill_preview_valid.visible = false
	_fill_preview_blocked.visible = false
	if (
		placement == null
		or placement.terrain_face_uids.is_empty()
		or terrain_renderer == null
	):
		_fill_preview_texture.mesh = null
		_fill_preview_texture_outline.mesh = null
		_fill_preview_texture.visible = false
		_fill_preview_texture_outline.visible = false
		return
	var preview_geometry := terrain_renderer.surface_preview_meshes(
		placement,
		brush_asset
	)
	_fill_preview_texture.mesh = preview_geometry.get("mesh", null) as Mesh
	_fill_preview_texture_outline.mesh = preview_geometry.get("outline", null) as Mesh
	var tint := Color(0.08, 0.88, 1.0, 0.55) if is_valid else Color(1.0, 0.12, 0.12, 0.62)
	_fill_preview_texture.material_override = _build_surface_brush_material(tint)
	_fill_preview_texture.visible = _fill_preview_texture.mesh != null
	_fill_preview_texture_outline.visible = _fill_preview_texture_outline.mesh != null


## Create the Fill guide overlay once, including after a live script reload.
##
## Editor tool scripts can reload without re-running _ready() on their existing
## controller, so this idempotent owner keeps the new preview available immediately.
func _ensure_fill_preview_guides() -> void:
	if _fill_preview_guides != null or _fill_preview_root == null:
		return
	# The guide mesh gives every stamp a crisp footprint boundary and keeps the
	# clicked point sequence legible independently of the selected asset texture.
	_fill_preview_guides = MeshInstance3D.new()
	_fill_preview_guides.name = "StampOutlinesAndPath"
	_fill_preview_guides.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var guide_material := StandardMaterial3D.new()
	guide_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	guide_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	guide_material.vertex_color_use_as_albedo = true
	guide_material.no_depth_test = true
	guide_material.render_priority = PREVIEW_RENDER_PRIORITY + 1
	_fill_preview_guides.material_override = guide_material
	_fill_preview_root.add_child(_fill_preview_guides)


## Rebuild occupancy outlines plus the clicked point path above the Fill result.
##
## Direct textures use exact terrain contours; this guide mesh keeps the clicked
## path and non-texture occupancy stamps distinct.
func _update_fill_preview_guides() -> void:
	_ensure_fill_preview_guides()
	if _fill_preview_guides == null:
		return
	if _fill_preview_origins.is_empty():
		_fill_preview_guides.mesh = null
		_fill_preview_guides.visible = false
		return

	var guides := ImmediateMesh.new()
	guides.surface_begin(Mesh.PRIMITIVE_LINES)
	# Direct textures already expose exact terrain-triangle contours; the old
	# planar stamp boxes are retained only for slots and prop occupancy previews.
	if not (brush_is_surface() and brush_asset != null) or _fill_targets_terrain():
		for origin: Vector3i in _fill_preview_valid_origins:
			_add_fill_stamp_outline(guides, origin, Color(0.1, 1.0, 0.95, 0.95))
		for origin: Vector3i in _fill_preview_blocked_origins:
			_add_fill_stamp_outline(guides, origin, Color(1.0, 0.15, 0.15, 0.98))
	_add_fill_control_path(guides)
	guides.surface_end()
	_fill_preview_guides.mesh = guides
	_fill_preview_guides.visible = true


## Add the real oriented footprint boundary for one pending Fill stamp.
func _add_fill_stamp_outline(
	guides: ImmediateMesh,
	origin: Vector3i,
	color: Color
) -> void:
	if _fill_targets_terrain():
		# One flat square per stamp, drawn on the ground plane at the exact cell
		# footprint the Brush width implies. Height follows the live terrain so the
		# outline reads on sculpted ground instead of floating at a fixed level.
		var stamp := _fill_stamp_size()
		# TerrainSculptor.brush_cell_targets() CENTRES its square on the anchor
		# cell, so the outline has to start from the same lower corner or a wide
		# brush would preview one cell away from the cells it actually edits.
		var lower_offset := float((stamp.x - 1) / 2)
		var base := Vector2(
			float(origin.x) - lower_offset,
			float(origin.z) - lower_offset
		)
		var terrain: TerrainMesh = board.terrain if board != null else null
		var corners_xz: Array[Vector2] = [
			base,
			base + Vector2(float(stamp.x), 0.0),
			base + Vector2(float(stamp.x), float(stamp.y)),
			base + Vector2(0.0, float(stamp.y)),
		]
		var outline: Array[Vector3] = []
		for corner_xz: Vector2 in corners_xz:
			var height_m := (
				terrain.sample_world_height(corner_xz, float(origin.y))
				if terrain != null
				else float(origin.y)
			)
			# Lifted clear of the surface so the outline is not z-fought by the
			# terrain triangle it sits on.
			outline.append(Vector3(corner_xz.x, height_m + 0.04, corner_xz.y))
		for corner_index in outline.size():
			_add_fill_guide_line(
				guides,
				outline[corner_index],
				outline[(corner_index + 1) % outline.size()],
				color
			)
		return

	if brush_is_surface():
		var stamp_transform := surface_transform(
			origin,
			brush_face,
			brush_quarters,
			brush_asset
		)
		var footprint := _brush_surface_footprint()
		var half_width := float(footprint.x) * 0.5
		var half_height := float(footprint.y) * 0.5
		var separation := Vector3(K.face_normal(brush_face)) * 0.035
		var corners: Array[Vector3] = [
			stamp_transform * Vector3(-half_width, -half_height, 0.0) + separation,
			stamp_transform * Vector3(half_width, -half_height, 0.0) + separation,
			stamp_transform * Vector3(half_width, half_height, 0.0) + separation,
			stamp_transform * Vector3(-half_width, half_height, 0.0) + separation,
		]
		for corner_index in corners.size():
			_add_fill_guide_line(
				guides,
				corners[corner_index],
				corners[(corner_index + 1) % corners.size()],
				color
			)
		return

	if brush_is_prop():
		var prop_preview := _prop_placement_for_origin(origin)
		var prop_world_origin := _prop_preview_world_origin(prop_preview)
		var voxel_edges: Array[Vector2i] = [
			Vector2i(0, 1), Vector2i(1, 3), Vector2i(3, 2), Vector2i(2, 0),
			Vector2i(4, 5), Vector2i(5, 7), Vector2i(7, 6), Vector2i(6, 4),
			Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
		]
		for voxel: Vector3i in _brush_prop_preview_voxels():
			var minimum := prop_world_origin + Vector3(voxel)
			var maximum := minimum + Vector3.ONE
			var voxel_corners: Array[Vector3] = [
				Vector3(minimum.x, minimum.y, minimum.z),
				Vector3(maximum.x, minimum.y, minimum.z),
				Vector3(minimum.x, maximum.y, minimum.z),
				Vector3(maximum.x, maximum.y, minimum.z),
				Vector3(minimum.x, minimum.y, maximum.z),
				Vector3(maximum.x, minimum.y, maximum.z),
				Vector3(minimum.x, maximum.y, maximum.z),
				Vector3(maximum.x, maximum.y, maximum.z),
			]
			for voxel_edge: Vector2i in voxel_edges:
				_add_fill_guide_line(
					guides,
					voxel_corners[voxel_edge.x],
					voxel_corners[voxel_edge.y],
					color
				)
		return

	var canonical_bounds := Vector3(_brush_prop_canonical_bounds())
	var transform := _brush_prop_transform_for_origin(origin)
	var corners: Array[Vector3] = [
		transform * Vector3(0.0, 0.0, 0.0),
		transform * Vector3(canonical_bounds.x, 0.0, 0.0),
		transform * Vector3(canonical_bounds.x, 0.0, canonical_bounds.z),
		transform * Vector3(0.0, 0.0, canonical_bounds.z),
		transform * Vector3(0.0, canonical_bounds.y, 0.0),
		transform * Vector3(canonical_bounds.x, canonical_bounds.y, 0.0),
		transform * Vector3(canonical_bounds.x, canonical_bounds.y, canonical_bounds.z),
		transform * Vector3(0.0, canonical_bounds.y, canonical_bounds.z),
	]
	var edge_indices: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	for edge: Vector2i in edge_indices:
		_add_fill_guide_line(guides, corners[edge.x], corners[edge.y], color)


## Add clicked point markers and connect them in the selected Path or Polygon order.
func _add_fill_control_path(guides: ImmediateMesh) -> void:
	if _fill_preview_vertices.is_empty():
		return

	var axes := _fill_plane_axes()
	var axis_u := Vector3(axes[0]) * 0.28
	var axis_v := Vector3(axes[1]) * 0.28
	var point_color := Color(1.0, 0.8, 0.08, 1.0)
	var path_color := Color(1.0, 0.62, 0.05, 0.95)
	for vertex: Vector3i in _fill_preview_vertices:
		var centre := _fill_stamp_centre(vertex)
		_add_fill_guide_line(guides, centre - axis_u, centre + axis_u, point_color)
		_add_fill_guide_line(guides, centre - axis_v, centre + axis_v, point_color)

	for index in range(1, _fill_preview_vertices.size()):
		_add_fill_guide_line(
			guides,
			_fill_stamp_centre(_fill_preview_vertices[index - 1]),
			_fill_stamp_centre(_fill_preview_vertices[index]),
			path_color
		)
	if fill_shape == FillShape.POLYGON and _fill_preview_vertices.size() >= 3:
		_add_fill_guide_line(
			guides,
			_fill_stamp_centre(_fill_preview_vertices[-1]),
			_fill_stamp_centre(_fill_preview_vertices[0]),
			path_color
		)


## Return the visible centre used to connect one clicked Fill origin.
func _fill_stamp_centre(origin: Vector3i) -> Vector3:
	if brush_is_surface():
		return (
			surface_transform(
				origin,
				brush_face,
				brush_quarters,
				brush_asset
			).origin
			+ Vector3(K.face_normal(brush_face)) * 0.055
		)
	if brush_is_prop():
		var collision_bounds := _brush_prop_preview_bounds()
		var prop_preview := _prop_placement_for_origin(origin)
		return (
			_prop_preview_world_origin(prop_preview)
			+ collision_bounds.position
			+ collision_bounds.size * 0.5
		)
	return _brush_prop_center_transform(origin).origin


## Append one colored line segment to the dynamic Fill guide mesh.
func _add_fill_guide_line(
	guides: ImmediateMesh,
	start: Vector3,
	finish: Vector3,
	color: Color
) -> void:
	guides.surface_set_color(color)
	guides.surface_add_vertex(start)
	guides.surface_set_color(color)
	guides.surface_add_vertex(finish)


## Build the translucent occupancy-box material used by prop Fill previews.
func _build_prop_fill_preview_material(tint: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = PREVIEW_RENDER_PRIORITY
	mat.albedo_color = tint
	return mat


## Build a translucent surface preview from the active brush asset.
func _build_surface_brush_material(tint: Color) -> Material:
	return _build_surface_preview_material(brush_asset, tint)


## Build a two-sided orientation ghost of the selected surface art.
##
## The preview receives the factory-resolved visible albedo, so source/analyzed
## blending and cutout alpha match the committed material. Its dedicated
## unshaded shader keeps the authored front bright and darkens the back by a
## fixed factor; the cue therefore remains explicit while board lighting changes.
func _build_surface_preview_material(asset: TileAsset, tint: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SURFACE_PREVIEW_SHADER
	mat.render_priority = PREVIEW_RENDER_PRIORITY

	var albedo: Texture2D = null
	if material_factory != null:
		albedo = material_factory.get_visible_albedo(asset)
	if albedo == null:
		var asset_label := asset.asset_id if asset != null else "<none>"
		push_error("[Tile Studio] preview for surface '%s' has no usable visible albedo." % asset_label)
		# Magenta is an explicit broken-preview diagnostic, never substitute art.
		mat.set_shader_parameter("has_albedo", false)
		mat.set_shader_parameter("preview_tint", Color(0.95, 0.15, 0.65, tint.a))
		return mat

	mat.set_shader_parameter("preview_albedo", albedo)
	mat.set_shader_parameter("has_albedo", true)
	mat.set_shader_parameter("preview_tint", tint)
	return mat


## Hide every Fill preview representation and discard its transient candidate.
func _clear_fill_preview() -> void:
	if _fill_preview_valid == null or _fill_preview_blocked == null:
		return
	_fill_preview_texture_placement = null
	_fill_preview_valid.multimesh = null
	_fill_preview_blocked.multimesh = null
	_fill_preview_valid.visible = false
	_fill_preview_blocked.visible = false
	if _fill_preview_texture != null:
		_fill_preview_texture.mesh = null
		_fill_preview_texture.visible = false
	if _fill_preview_texture_outline != null:
		_fill_preview_texture_outline.mesh = null
		_fill_preview_texture_outline.visible = false
	if _fill_preview_guides != null:
		_fill_preview_guides.mesh = null
		_fill_preview_guides.visible = false
	_fill_preview_root.visible = false


# --- Preview --------------------------------------------------------------


## Ensure cursor footprint contours exist after live editor script reloads.
##
## Existing @tool controller instances do not rerun _ready() when new preview
## members are introduced, so this idempotent owner creates only missing nodes.
func _ensure_cursor_preview_outlines() -> void:
	if _preview_root == null:
		return

	var outline_material: StandardMaterial3D = null
	if is_instance_valid(_preview_surface_outline):
		outline_material = _preview_surface_outline.material_override as StandardMaterial3D
	elif is_instance_valid(_preview_box_outline):
		outline_material = _preview_box_outline.material_override as StandardMaterial3D
	if outline_material == null:
		outline_material = StandardMaterial3D.new()
		outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		outline_material.albedo_color = Color(0.03, 0.04, 0.06, 1.0)
		outline_material.no_depth_test = true
		outline_material.render_priority = PREVIEW_RENDER_PRIORITY + 2

	if not is_instance_valid(_preview_surface_outline):
		_preview_surface_outline = MeshInstance3D.new()
		_preview_surface_outline.name = "PreviewQuadContours"
		_preview_surface_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_preview_root.add_child(_preview_surface_outline)
	_preview_surface_outline.material_override = outline_material

	if not is_instance_valid(_preview_box_outline):
		_preview_box_outline = MeshInstance3D.new()
		_preview_box_outline.name = "PreviewBoxContours"
		_preview_box_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_preview_root.add_child(_preview_box_outline)
	_preview_box_outline.material_override = outline_material


## Refresh the existing brush preview after its canonical board slot data changes.
##
## This deliberately preserves Tool.SELECT; rebuilding display state must never
## reissue a brush-selection command or change which input mode owns the viewport.
func refresh_brush_preview() -> void:
	_rebuild_preview()


## Rebuild the existing preview nodes from the currently active brush source.
func _rebuild_preview() -> void:
	# The preview nodes are built in _ready(), but the brush can be set before
	# this controller enters the tree. _ready() rebuilds it once nodes exist.
	if _preview_root == null:
		return
	_ensure_cursor_preview_outlines()
	if not has_brush():
		_preview_root.visible = false
		return

	if brush_is_surface():
		_preview_box.visible = false
		_preview_box_outline.visible = false
		_preview_arrow.visible = true
		_preview_mesh.visible = true
		_preview_surface_outline.visible = true
		# A surface brush always has an asset, and its preview is the terrain geometry
		# resolved in _position_preview() once the current face hit is known. There is
		# no quad standing in for the surface any more.
		_preview_mesh.mesh = null
		_preview_surface_outline.mesh = null
		_preview_mesh.material_override = _build_surface_brush_material(
			Color(1, 1, 1, 0.55)
		)

		_preview_arrow.mesh = _build_surface_up_arrow()
		var surface_arrow_mat := StandardMaterial3D.new()
		surface_arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		surface_arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		surface_arrow_mat.no_depth_test = true
		surface_arrow_mat.render_priority = PREVIEW_RENDER_PRIORITY + 1
		surface_arrow_mat.albedo_color = Color(0.05, 0.95, 1.0)
		_preview_arrow.material_override = surface_arrow_mat
	else:
		_preview_mesh.visible = false
		_preview_surface_outline.visible = false
		_preview_box.visible = true
		_preview_box_outline.visible = true
		if brush_is_prop():
			var preview_voxels := _brush_prop_preview_voxels()
			var collision_preview := ProxyMeshBuilder.collision_preview_meshes(preview_voxels)
			_preview_box.mesh = collision_preview["volume"] as Mesh
			_preview_box_outline.mesh = collision_preview["contours"] as Mesh
		else:
			var box := BoxMesh.new()
			var canonical_bounds := _brush_prop_canonical_bounds()
			box.size = Vector3(canonical_bounds)
			_preview_box.mesh = box
			_preview_box_outline.mesh = ProxyMeshBuilder.box_outline_mesh(
				Vector3(canonical_bounds)
			)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var color := _brush_color()
		mat.albedo_color = Color(color.r, color.g, color.b, 0.30)
		mat.no_depth_test = true
		mat.render_priority = PREVIEW_RENDER_PRIORITY
		_preview_box.material_override = mat

		_preview_arrow.visible = true
		_preview_arrow.mesh = _build_facing_arrow()
		var arrow_mat := StandardMaterial3D.new()
		arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		arrow_mat.no_depth_test = true
		arrow_mat.render_priority = PREVIEW_RENDER_PRIORITY + 1
		arrow_mat.albedo_color = Color(1.0, 0.85, 0.15)
		_preview_arrow.material_override = arrow_mat

	_position_preview()


## Position the active preview using the same minimum-corner and face transforms as placement.
func _position_preview() -> void:
	if not has_brush() and not terrain_splat_paint_enabled:
		return
	if _preview_root == null:
		return
	_ensure_cursor_preview_outlines()
	if (
		_preview_mesh == null
		or _preview_box == null
		or _preview_arrow == null
	):
		return
	if terrain_splat_paint_enabled:
		if tool == Tool.FILL:
			return
		# Material Tile and RGBA Tile paint carry only the canonical face addresses;
		# the same renderer geometry route used by base-coat placement draws them.
		var preview_placement := SurfacePlacement.new()
		preview_placement.origin = hovered_cell
		preview_placement.face = _terrain_splat_face
		preview_placement.terrain_face_uids = terrain_material_target_uids(
			hovered_cell,
			_terrain_splat_face
		)
		var preview_geometry := terrain_renderer.surface_preview_meshes(
			preview_placement,
			brush_asset if _terrain_splat_uses_surface_brush else null
		) if terrain_renderer != null else {}
		_preview_mesh.mesh = preview_geometry.get("mesh", null) as Mesh
		_preview_surface_outline.mesh = preview_geometry.get("outline", null) as Mesh
		_preview_mesh.transform = Transform3D.IDENTITY
		_preview_surface_outline.transform = Transform3D.IDENTITY
		if _terrain_splat_uses_surface_brush and brush_is_surface():
			preview_placement.asset_id = brush_asset.asset_id
			preview_placement.rotation_quarters = brush_quarters
			_preview_mesh.material_override = _build_surface_brush_material(
				Color(1, 1, 1, 0.55) if hover_valid else Color(1, 0.25, 0.25, 0.55)
			)
			_preview_arrow.visible = true
			_preview_arrow.transform = surface_transform(
				hovered_cell,
				_terrain_splat_face,
				brush_quarters,
				brush_asset,
				SurfacePlacement.GridAnchor.CELL
			)
		else:
			_preview_mesh.material_override = _terrain_tile_preview_material
			_terrain_tile_preview_material.albedo_color = (
				Color(0.12, 0.86, 1.0, 0.22)
				if hover_valid
				else Color(1.0, 0.2, 0.2, 0.3)
			)
			_preview_arrow.visible = false
		return
	if brush_is_surface():
		# Terrain paint previews the exact faces it will cover, copied from the
		# canonical terrain records, so the preview cannot describe a flat proxy
		# quad that the committed paint would never produce.
		var preview_placement := _surface_placement_for_origin(hovered_cell)
		var preview_geometry := terrain_renderer.surface_preview_meshes(
			preview_placement,
			brush_asset
		) if terrain_renderer != null else {}
		_preview_mesh.mesh = preview_geometry.get("mesh", null) as Mesh
		_preview_surface_outline.mesh = preview_geometry.get("outline", null) as Mesh
		_preview_mesh.transform = Transform3D.IDENTITY
		_preview_surface_outline.transform = Transform3D.IDENTITY
		# The conformed face mesh shows which faces are covered but not which way
		# the image runs across them, so the arrow is the readout for the authored
		# quarter turn. It draws with no_depth_test as a HUD overlay, so sitting on
		# the placement's own plane rather than the slope cannot hide it.
		_preview_arrow.visible = true
		_preview_arrow.transform = surface_transform(
			hovered_cell,
			brush_face,
			brush_quarters,
			brush_asset,
			_surface_grid_anchor
		)
		var shader_preview := _preview_mesh.material_override as ShaderMaterial
		if shader_preview != null:
			var preview_tint := (
				Color(1, 1, 1, 0.55) if hover_valid else Color(1, 0.25, 0.25, 0.55)
			)
			if not bool(shader_preview.get_shader_parameter("has_albedo")):
				preview_tint = Color(0.95, 0.15, 0.65, 0.55)
			shader_preview.set_shader_parameter("preview_tint", preview_tint)
	else:
		var preview_centre := Vector3.ZERO
		var preview_height := 0.0
		if brush_is_prop():
			# The voxel mesh keeps the canonical oriented offsets. The preview uses
			# the same derived floor or wall contact offset as committed art,
			# collision, and proxy geometry.
			var collision_bounds := _brush_prop_preview_bounds()
			var preview_placement := _prop_placement_for_origin(hovered_cell)
			var preview_origin := _prop_preview_world_origin(preview_placement)
			var collision_transform := Transform3D(
				Basis.IDENTITY,
				preview_origin
			)
			_preview_box.transform = collision_transform
			_preview_box_outline.transform = collision_transform
			preview_centre = (
				preview_origin
				+ collision_bounds.position
				+ collision_bounds.size * 0.5
			)
			preview_height = collision_bounds.size.y
		else:
			# Surfaced boxes retain their rigid 90-degree box transform because
			# their collision is the complete authored box rather than sparse voxels.
			var canonical_bounds := _brush_prop_canonical_bounds()
			var corner_transform := _brush_prop_transform_for_origin(hovered_cell)
			var local_centre := Vector3(canonical_bounds) * 0.5
			_preview_box.transform = Transform3D(
				corner_transform.basis,
				corner_transform * local_centre
			)
			_preview_box_outline.transform = corner_transform
			preview_centre = corner_transform * local_centre
			preview_height = float(_brush_box().y)
		var mat := _preview_box.material_override as StandardMaterial3D
		if mat != null:
			var color := _brush_color() if hover_valid else Color(1.0, 0.25, 0.25)
			mat.albedo_color = Color(color.r, color.g, color.b, 0.30 if hover_valid else 0.35)

		_preview_arrow.transform = Transform3D(
			K.prop_orientation_basis(
				_resolved_prop_forward_face(),
				brush_prop_roll_quarters,
				_resolved_prop_yaw_eighths() if brush_is_prop() else 0
			),
			preview_centre + Vector3(0.0, preview_height * 0.5 + 0.05, 0.0)
		)
		var arrow_mat := _preview_arrow.material_override as StandardMaterial3D
		if arrow_mat != null:
			arrow_mat.albedo_color = Color(1.0, 0.85, 0.15) if hover_valid else Color(1.0, 0.35, 0.3)

## Build the PNG orientation arrow in the authored local XY plane.
##
## The tip points along local +Y, which is the top of the source image. A small
## local +Z separation keeps the HUD arrow above the preview without changing
## the placement transform shared by preview, collision, and committed art.
func _build_surface_up_arrow() -> ArrayMesh:
	var tip_y := 0.44
	var head_base_y := 0.12
	var tail_y := -0.34
	var head_half_width := 0.24
	var shaft_half_width := 0.075
	var separation := 0.025

	var verts := PackedVector3Array([
		# Head: the tip is canonical source-image up.
		Vector3(0.0, tip_y, separation),
		Vector3(-head_half_width, head_base_y, separation),
		Vector3(head_half_width, head_base_y, separation),
		# Shaft, as two triangles.
		Vector3(-shaft_half_width, head_base_y, separation),
		Vector3(-shaft_half_width, tail_y, separation),
		Vector3(shaft_half_width, head_base_y, separation),
		Vector3(shaft_half_width, head_base_y, separation),
		Vector3(-shaft_half_width, tail_y, separation),
		Vector3(shaft_half_width, tail_y, separation),
	])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Build a flat chevron marking the prop source model's local front (-Z).
##
## The preview applies the same complete rigid orientation as the placed source
## mesh. It is drawn as raw triangles because its high-contrast silhouette stays
## legible from the fixed isometric camera without adding a second prop model.
func _build_facing_arrow() -> ArrayMesh:
	var length := 0.9
	var half_width := 0.34
	var tail_half := 0.12
	var tail_back := 0.15

	var verts := PackedVector3Array([
		# Head: a triangle whose tip points north.
		Vector3(0.0, 0.0, -length),
		Vector3(-half_width, 0.0, -length + 0.45),
		Vector3(half_width, 0.0, -length + 0.45),
		# Shaft, as two triangles.
		Vector3(-tail_half, 0.0, -length + 0.45),
		Vector3(-tail_half, 0.0, tail_back),
		Vector3(tail_half, 0.0, -length + 0.45),
		Vector3(tail_half, 0.0, -length + 0.45),
		Vector3(-tail_half, 0.0, tail_back),
		Vector3(tail_half, 0.0, tail_back),
	])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Return the canonical box owned by the active prop asset.
func _brush_prop_canonical_bounds() -> Vector3i:
	if brush_asset != null:
		return brush_asset.grid_bounds
	return Vector3i.ONE


## Return the canonical diagonal-aware transform for one brush placement origin.
func _brush_prop_transform_for_origin(origin: Vector3i) -> Transform3D:
	var transform := K.prop_box_transform(
		_brush_prop_canonical_bounds(),
		_resolved_prop_forward_face(),
		brush_prop_roll_quarters,
		_resolved_prop_yaw_eighths() if brush_is_prop() else 0
	)
	transform.origin += Vector3(origin)
	return transform


## Return the centre transform for a BoxMesh that represents one prop footprint.
func _brush_prop_center_transform(origin: Vector3i) -> Transform3D:
	var corner_transform := _brush_prop_transform_for_origin(origin)
	return Transform3D(
		corner_transform.basis,
		corner_transform * (Vector3(_brush_prop_canonical_bounds()) * 0.5)
	)


## Return the exact oriented collision voxels that one prop brush stamp will reserve.
##
## Preview, validation, committed collision, and selection all consume this same
## PropPlacement transform, including 45-degree yaw expansion onto the grid.
func _brush_prop_preview_voxels() -> Array[Vector3i]:
	if not brush_is_prop():
		return []
	var candidate := _prop_placement_for_origin(Vector3i.ZERO)
	return candidate.oriented_voxels(brush_asset)


## Return the smallest axis-aligned box containing every exact preview collision voxel.
func _brush_prop_preview_bounds() -> AABB:
	var voxels := _brush_prop_preview_voxels()
	if voxels.is_empty():
		return AABB()
	var minimum := Vector3(voxels[0])
	var maximum := minimum + Vector3.ONE
	for voxel: Vector3i in voxels:
		minimum = minimum.min(Vector3(voxel))
		maximum = maximum.max(Vector3(voxel) + Vector3.ONE)
	return AABB(minimum, maximum - minimum)


## Return the exact integer AABB occupied by the current volume brush.
func _brush_box() -> Vector3i:
	if brush_is_prop():
		return Vector3i(_brush_prop_preview_bounds().size)
	return K.oriented_prop_grid_bounds(
		_brush_prop_canonical_bounds(),
		brush_prop_forward_face,
		brush_prop_roll_quarters,
		0
	)

## World transform for a surface quad on a given cell + face + rotation.
##
## Shared by the preview and the committed geometry so what the user sees while
## hovering is exactly what lands. Built from the SAME footprint axes that
## get_occupied_faces uses, so the art always covers the cells the placement
## actually claims.
static func surface_transform(
	cell: Vector3i,
	face: int,
	quarters: int,
	asset: TileAsset,
	grid_anchor: int = SurfacePlacement.GridAnchor.CELL
) -> Transform3D:
	if asset == null:
		push_error("[Tile Studio] cannot transform a surface without an asset.")
		return Transform3D.IDENTITY
	var canonical_footprint := asset.surface_footprint()
	return surface_transform_for_size(
		cell,
		face,
		quarters,
		canonical_footprint,
		grid_anchor
	)


## Build a surface transform from one explicit unrotated footprint.
##
## Keeping this pure size path lets placeholders, highlights, collisions, and
## finished art share exactly the same placement math.
static func surface_transform_for_size(
	cell: Vector3i,
	face: int,
	quarters: int,
	canonical_footprint: Vector2i,
	grid_anchor: int = SurfacePlacement.GridAnchor.CELL
) -> Transform3D:
	return SurfacePlacement.transform_for_size(
		cell,
		face,
		quarters,
		canonical_footprint,
		grid_anchor
	)


# --- Mutation -------------------------------------------------------------

## Commit the brush at the hovered cell through the canonical batch pipeline.
##
## Paint passes one origin while Fill passes many, so validation, overlap
## reservation, undo behavior, and document mutation cannot diverge by tool.
func paint_at_hover() -> bool:
	if terrain_splat_paint_enabled:
		var splat_result := _validate_terrain_splat_origin(
			hovered_cell,
			false,
			replace_enabled
		)
		if not bool(splat_result.get("valid", false)):
			_reject(String(splat_result.get("reason", "splatmap tile is blocked")))
			return false
		last_rejection = ""
		var target_uids: PackedStringArray = splat_result.get(
			"target_uids",
			PackedStringArray()
		)
		terrain_material_tile_paint_requested.emit(
			target_uids,
			false,
			replace_enabled,
			false
		)
		return true
	if not has_brush() or board == null:
		last_rejection = "no brush or board"
		return false
	last_rejection = ""

	# Terrain paint is the primary way a PNG reaches the board. The visible brush
	# grid-stroke width owns the mutated face set, while asset size remains only the texture's
	# UV/repeat scale. The material blend palette remains a separate masking workflow.

	var origins: Array[Vector3i] = [hovered_cell]
	var evaluated := _evaluate_placement_candidates(origins)
	var placements: Array[Resource] = evaluated["placements"]
	var displaced: Array[Resource] = evaluated["replacements"]
	if placements.is_empty():
		if bool(evaluated.get("occupied_surface_no_op", false)):
			return true
		_reject(String(evaluated["first_rejection"]))
		return false

	# Every decal kind is stamped rather than painted, so the history entry names
	# them the same way; only terrain paint reads as "Paint surface". Expressed as
	# "not terrain paint" so a new render role cannot be silently mislabelled.
	var stamping_decal := (
		brush_is_surface()
		and brush_surface_presentation != SurfacePlacement.Presentation.TERRAIN_PAINT
	)
	var action := (
		"Stamp decal"
		if stamping_decal
		else "Paint surface" if brush_is_surface() else "Place prop"
	)
	if displaced.is_empty():
		_commit_placements_bulk(placements, action)
	else:
		_commit_replacements(
			placements,
			displaced,
			"Replace %d placement%s" % [
				displaced.size(),
				"" if displaced.size() == 1 else "s",
			]
		)
	return true


## Report a refused placement without committing it.
##
## Re-emits hover state so the preview and status bar show the conflict even
## when the pointer has not moved since the last evaluation -- clicking a second
## time on an occupied cell must still say why nothing happened.
func _reject(reason: String) -> void:
	hover_valid = false
	hover_reason = reason
	last_rejection = reason
	_position_preview()
	hover_changed.emit(hovered_cell, false, reason)
	placement_rejected.emit(hovered_cell, reason)


## Return the terrain paint covering one lattice address, if any.
##
## Editor picking is addressed by lattice position while authored paint is keyed
## by the terrain face's stable UID, so this resolves one to the other through
## the live terrain records rather than assuming the two ever match directly.
func _surface_at_address(cell: Vector3i, face: int) -> SurfacePlacement:
	if board == null or terrain_renderer == null:
		return null
	var paint_uid := terrain_renderer.paint_uid_at(cell, face)
	if paint_uid.is_empty():
		return null
	return board.surface_at_paint_uid(paint_uid)


## Erase the terrain-paint placement or solid occupying the hovered address.
func erase_at_hover() -> void:
	if board == null:
		return
	if terrain_splat_paint_enabled:
		var splat_result := _validate_terrain_splat_origin(
			hovered_cell,
			true,
			replace_enabled
		)
		if not bool(splat_result.get("valid", false)):
			_reject(String(splat_result.get("reason", "splatmap tile is empty")))
			return
		var target_uids: PackedStringArray = splat_result.get(
			"target_uids",
			PackedStringArray()
		)
		terrain_material_tile_paint_requested.emit(
			target_uids,
			true,
			replace_enabled,
			false
		)
		return
	var surface := _surface_at_address(hovered_cell, brush_face)
	if surface == null:
		for face: int in K.FACE_NORMALS:
			surface = _surface_at_address(hovered_cell, face)
			if surface != null:
				break
	if surface != null:
		_commit_remove_surface(surface, "Erase surface")
		return

	var solid := board.solid_placement_at(hovered_cell)
	if solid is PropPlacement:
		_commit_remove_prop(solid as PropPlacement, "Erase prop")


## Add or remove a complete mixed selection with one index rebuild and one board notification.
##
## This is the shared do/undo boundary for Delete, so the visible selection and
## the saved BoardDocument cannot diverge even when several placement types are selected.
func _apply_selection_presence(targets: Array[Resource], present: bool) -> void:
	if board == null:
		return
	for target: Resource in targets:
		if target is SurfacePlacement:
			if present and not board.surfaces.has(target):
				board.surfaces.append(target)
			elif not present:
				board.surfaces.erase(target)
		elif target is PropPlacement:
			if present and not board.props.has(target):
				board.props.append(target)
			elif not present:
				board.props.erase(target)
		else:
			push_error("[Tile Studio] selection delete contains an unsupported placement resource.")
			return
	board.rebuild_indexes()
	board.board_changed.emit()
	board_mutated.emit(_mutation_mask_for_resources(targets))


## Delete every selected canonical placement as one undoable editor action.
func delete_selection() -> void:
	var targets := selected_resources()
	if targets.is_empty():
		return
	# Clear the transient highlight before the document notification rebuilds its
	# derived nodes, so a deleted Resource is never displayed as still selected.
	selected = null
	selected_placements.clear()
	selection_changed.emit(null)

	if undo_redo == null:
		_apply_selection_presence(targets, false)
		return
	var action := "Delete %d placement%s" % [
		targets.size(),
		"" if targets.size() == 1 else "s",
	]
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(self, "_apply_selection_presence", targets, false)
	undo_redo.add_undo_method(self, "_apply_selection_presence", targets, true)
	undo_redo.commit_action()


## Select the terrain-paint placement or solid at the hovered canonical address.
func select_at_hover() -> void:
	if board == null:
		return
	var found: Resource = _surface_at_address(hovered_cell, brush_face)
	if found == null:
		for face: int in K.FACE_NORMALS:
			found = _surface_at_address(hovered_cell, face)
			if found != null:
				break
	if found == null:
		found = board.solid_placement_at(hovered_cell)
	var next_selection: Array[Resource] = []
	if found != null:
		next_selection.append(found)
	set_selected_placements(next_selection)


## Return whether one placement is part of the current explicit group selection.
func is_selected(placement: Resource) -> bool:
	return placement != null and selected_placements.has(placement)


## Return a copy so callers can inspect the current group without owning it.
func selected_resources() -> Array[Resource]:
	return selected_placements.duplicate()


## Replace the group selection with valid board placements and retain one primary item.
##
## The resource records themselves are canonical, so this stores their identities
## rather than a duplicate list of origins or renderer nodes.
func set_selected_placements(placements: Array[Resource], primary: Resource = null) -> void:
	var next_selection: Array[Resource] = []
	for placement_record: Resource in placements:
		if placement_record == null or next_selection.has(placement_record):
			continue
		if placement_record is SurfacePlacement and board != null and board.surfaces.has(placement_record):
			next_selection.append(placement_record)
		elif placement_record is PropPlacement and board != null and board.props.has(placement_record):
			next_selection.append(placement_record)

	selected_placements = next_selection
	selected = primary if primary != null and next_selection.has(primary) else null
	if selected == null and not selected_placements.is_empty():
		selected = selected_placements[0]
	selection_changed.emit(selected)


## Add or remove one placement without changing the remaining group members.
func toggle_selected_placement(placement_record: Resource) -> void:
	if placement_record == null:
		return
	var next_selection := selected_resources()
	if next_selection.has(placement_record):
		next_selection.erase(placement_record)
		set_selected_placements(next_selection)
	else:
		next_selection.append(placement_record)
		set_selected_placements(next_selection, placement_record)


## Clear every selected placement while updating the existing inspector signal.
func clear_selection() -> void:
	var empty_selection: Array[Resource] = []
	set_selected_placements(empty_selection)


## Validate only changed selection candidates against canonical occupancy indexes.
##
## Selected originals are ignored because the whole group moves atomically.
## Candidate-to-candidate dictionaries catch overlaps inside the moved group
## without scanning or reconstructing any unchanged board occupancy.
func _selection_spatial_error(candidate_overrides: Dictionary) -> String:
	if board == null or selected_placements.is_empty():
		return "no selected placement or board"

	var selected_ids: Dictionary = {}
	for selected: Resource in selected_placements:
		selected_ids[selected.get_instance_id()] = true
	var candidate_surface_faces: Dictionary = {}
	var candidate_solid_cells: Dictionary = {}

	for original: Resource in selected_placements:
		var candidate := candidate_overrides.get(
			original.get_instance_id(),
			original
		) as Resource
		if candidate is SurfacePlacement:
			var candidate_surface := candidate as SurfacePlacement
			var terrain_error := _conform_texture_surface_to_terrain(candidate_surface)
			if not terrain_error.is_empty():
				return terrain_error
			for conflict: SurfacePlacement in board.surface_conflicting_placements(
				candidate_surface
			):
				if not selected_ids.has(conflict.get_instance_id()):
					return "selection would overlap an existing surface"
			for uid: String in candidate_surface.terrain_face_uids:
				if candidate_surface_faces.has(uid):
					return "selection would overlap a surface at %s" % uid
				candidate_surface_faces[uid] = true
		elif candidate is PropPlacement:
			for cell: Vector3i in board.prop_occupied_cells(candidate as PropPlacement):
				var solid_key := K.voxel_key(cell)
				var occupant := board.solid_placement_at(cell)
				if occupant != null and not selected_ids.has(occupant.get_instance_id()):
					return "selection would overlap a solid at %s" % solid_key
				if candidate_solid_cells.has(solid_key):
					return "selection would overlap a solid at %s" % solid_key
				candidate_solid_cells[solid_key] = true
		else:
			return "selection contains an unsupported placement resource"
	return ""


## Validate a proposed whole-selection translation through canonical collision occupancy.
func selection_move_error(delta: Vector3i) -> String:
	var candidates: Dictionary = {}
	for placement_record: Resource in selected_placements:
		var candidate := placement_record.duplicate() as Resource
		if candidate is SurfacePlacement:
			(candidate as SurfacePlacement).origin += delta
		elif candidate is PropPlacement:
			(candidate as PropPlacement).origin += delta
		else:
			return "selection contains an unsupported placement resource"
		candidates[placement_record.get_instance_id()] = candidate
	return _selection_spatial_error(candidates)


## Apply selection origins while deriving texture coverage from canonical terrain.
func _apply_selection_origins(
	targets: Array[Resource], origins: Array[Vector3i]
) -> void:
	if board == null or targets.size() != origins.size():
		push_error("[Tile Studio] cannot apply a selection move with mismatched targets and origins.")
		return
	var states: Array[Dictionary] = []
	for index: int in origins.size():
		var state := {"origin": origins[index]}
		var target := targets[index]
		if target is SurfacePlacement:
			var candidate := target.duplicate() as SurfacePlacement
			candidate.origin = origins[index]
			var terrain_error := _conform_texture_surface_to_terrain(candidate)
			if not terrain_error.is_empty():
				push_error("[Tile Studio] cannot move terrain paint: %s." % terrain_error)
				return
			state["terrain_face_uids"] = Array(candidate.terrain_face_uids)
		states.append(state)
	if not board.apply_placement_spatial_states(targets, states):
		push_error("[Tile Studio] could not apply selection origins.")
		return
	# Moving records cannot affect palette definitions or usage counts, so one
	# viewport spatial notification is sufficient after the canonical mutation.
	board_mutated.emit(_mutation_mask_for_resources(targets))


## Move the entire current group by one integer grid delta as a single undo step.
func move_selection_by(delta: Vector3i) -> bool:
	if delta == Vector3i.ZERO:
		return false
	var error := selection_move_error(delta)
	if not error.is_empty():
		last_rejection = error
		push_error("[Tile Studio] selection move rejected: %s." % error)
		return false

	var targets := selected_resources()
	var old_origins: Array[Vector3i] = []
	var new_origins: Array[Vector3i] = []
	for target: Resource in targets:
		var origin := Vector3i.ZERO
		if target is SurfacePlacement:
			origin = (target as SurfacePlacement).origin
		elif target is PropPlacement:
			origin = (target as PropPlacement).origin
		else:
			push_error("[Tile Studio] selection move contains an unsupported placement resource.")
			return false
		old_origins.append(origin)
		new_origins.append(origin + delta)

	var action := "Move %d placement%s" % [targets.size(), "" if targets.size() == 1 else "s"]
	if undo_redo == null:
		_apply_selection_origins(targets, new_origins)
		return true
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(self, "_apply_selection_origins", targets, new_origins)
	undo_redo.add_undo_method(self, "_apply_selection_origins", targets, old_origins)
	undo_redo.commit_action()
	return true


# --- Undo/redo wrappers ---------------------------------------------------
#
# The document exposes plain mutators; the editor layer wraps them so every
# action is undoable from the first commit rather than retrofitted (spec 43).


## Return one prop's existing heightfield footprint as an absolute rectangle.
func _prop_contact_bounds(
	prop: PropPlacement,
	asset: TileAsset,
	terrain: TerrainMesh
) -> Rect2i:
	var bounds := Rect2i()
	if prop == null or asset == null or terrain == null:
		return bounds
	for cell: Vector2i in prop.footprint_cells(asset):
		if not terrain.has_cell(cell):
			continue
		var cell_rect := Rect2i(cell, Vector2i.ONE)
		bounds = cell_rect if bounds.size.x <= 0 else bounds.merge(cell_rect)
	return bounds


## Group contact instances whose local preview neighbourhoods overlap.
##
## Separate groups receive separate bounded TerrainMesh copies, so distant GLBs
## never make atomic patch calculation copy the terrain between them.
func _prop_contact_groups(props: Array[PropPlacement]) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	if board == null or board.terrain == null:
		return groups
	var terrain_rect := Rect2i(
		board.terrain.origin_cell,
		board.terrain.size_cells
	)
	for prop: PropPlacement in props:
		if prop == null or prop.support != PropPlacement.SUPPORT_FLOOR:
			continue
		var asset := board.resolve_prop_asset(prop)
		if asset == null or not asset.prop_contact_flatten:
			continue
		var bounds := _prop_contact_bounds(prop, asset, board.terrain)
		if bounds.size.x <= 0 or bounds.size.y <= 0:
			continue
		var pending_bounds := bounds.grow(2).intersection(terrain_rect)
		var pending_props: Array[PropPlacement] = [prop]
		var group_index := 0
		while group_index < groups.size():
			var group: Dictionary = groups[group_index]
			var group_bounds: Rect2i = group["bounds"]
			if not group_bounds.grow(1).intersects(pending_bounds):
				group_index += 1
				continue
			pending_bounds = pending_bounds.merge(group_bounds)
			for value: Variant in group["props"] as Array:
				var grouped_prop := value as PropPlacement
				if grouped_prop != null and not pending_props.has(grouped_prop):
					pending_props.append(grouped_prop)
			groups.remove_at(group_index)
			group_index = 0
		groups.append({
			"bounds": pending_bounds,
			"props": pending_props,
		})
	return groups


## Return every side-face paint UID whose existence may change in one patch.
func _terrain_paint_uids_for_patch(patch: Dictionary) -> PackedStringArray:
	var side_keys: Dictionary = {}
	for state_name: String in ["before_sides", "after_sides"]:
		for key_value: Variant in (patch.get(state_name, {}) as Dictionary).keys():
			side_keys[String(key_value)] = true
	var result := PackedStringArray()
	for key_value: Variant in side_keys.keys():
		var key := String(key_value)
		var parts := key.split(",")
		if parts.size() != 3:
			continue
		var maximum_band_count := 0
		for state_name: String in ["before_sides", "after_sides"]:
			var profiles: Dictionary = patch.get(state_name, {})
			var profile: Array = profiles.get(key, [])
			if profile.size() != 6:
				continue
			var lowest := minf(float(profile[2]), float(profile[4]))
			var highest := maxf(float(profile[3]), float(profile[5]))
			maximum_band_count = maxi(
				maximum_band_count,
				TerrainMesh.bands_in_span(lowest, highest).size()
			)
		var cell := Vector2i(int(parts[0]), int(parts[1]))
		var edge := int(parts[2])
		for band: int in maximum_band_count:
			result.append(TerrainMesh.band_uid(cell, edge, band))
	return result


## Combine independent local preview patches into one atomic undo record.
func _combine_prop_terrain_patches(patches: Array[Dictionary]) -> Dictionary:
	var cells := PackedVector2Array()
	var before_tops := PackedFloat32Array()
	var after_tops := PackedFloat32Array()
	var before_sides: Dictionary = {}
	var after_sides: Dictionary = {}
	var regions: Array[Rect2i] = []
	var included_cells: Dictionary = {}
	for patch: Dictionary in patches:
		var patch_cells: PackedVector2Array = patch.get(
			"cells",
			PackedVector2Array()
		)
		for cell_value: Vector2 in patch_cells:
			var cell := Vector2i(cell_value)
			if included_cells.has(cell):
				push_error(
					"[Tile Studio] overlapping GLB contact groups produced duplicate terrain cells."
				)
				return {}
			included_cells[cell] = true
		cells.append_array(patch_cells)
		before_tops.append_array(
			patch.get("before_tops", PackedFloat32Array())
		)
		after_tops.append_array(
			patch.get("after_tops", PackedFloat32Array())
		)
		for key_value: Variant in (patch.get("before_sides", {}) as Dictionary).keys():
			var key := String(key_value)
			if before_sides.has(key):
				push_error(
					"[Tile Studio] overlapping GLB contact groups produced duplicate side faces."
				)
				return {}
			before_sides[key] = (patch["before_sides"] as Dictionary)[key]
			after_sides[key] = (patch["after_sides"] as Dictionary).get(key, [])
		for value: Variant in patch.get("terrain_regions", []) as Array:
			if value is Rect2i:
				regions.append(value as Rect2i)
	if cells.is_empty() and before_sides.is_empty():
		return {}
	var combined := {
		"cells": cells,
		"before_tops": before_tops,
		"after_tops": after_tops,
		"before_sides": before_sides,
		"after_sides": after_sides,
		"terrain_regions": regions,
	}
	combined["terrain_paint_uids"] = _terrain_paint_uids_for_patch(combined)
	return combined


## Return the exact disjoint terrain regions stored in one contact patch.
func _patch_terrain_regions(patch: Dictionary) -> Array[Rect2i]:
	var regions: Array[Rect2i] = []
	for value: Variant in patch.get("terrain_regions", []) as Array:
		if value is Rect2i:
			regions.append(value as Rect2i)
	return regions


## Return whether at least one floor prop explicitly requests terrain flattening.
func _props_request_contact_flatten(props: Array[PropPlacement]) -> bool:
	if board == null:
		return false
	for prop: PropPlacement in props:
		if prop == null or prop.support != PropPlacement.SUPPORT_FLOOR:
			continue
		var asset := board.resolve_prop_asset(prop)
		if asset != null and asset.prop_contact_flatten:
			return true
	return false


## Apply each prop asset's selected flatten mode to one supplied terrain instance.
##
## The caller decides whether this is the live terrain or a duplicate. Ordinary
## placement runs first and decides where the GLB stands; this levels the pad to
## that answer afterwards. Reading prop_terrain_support_height from the terrain as
## it is when the prop is reached -- rather than computing a separate maximum
## corner -- is what keeps the model on its own pad: flattening every footprint
## quad to that height leaves the height unchanged when it is re-derived, so the
## operation is stable no matter how many times it runs.
func _flatten_props_on_terrain(
	target_terrain: TerrainMesh,
	props: Array[PropPlacement],
	report_messages: bool
) -> Dictionary:
	if target_terrain == null or target_terrain.is_empty():
		return {}
	var sculptor := TerrainSculptorScript.new(target_terrain)
	var terrain_regions: Array[Rect2i] = []
	sculptor.begin_stroke()
	for prop: PropPlacement in props:
		if prop == null or prop.support != PropPlacement.SUPPORT_FLOOR:
			continue
		var asset := board.resolve_prop_asset(prop)
		if asset == null:
			if report_messages:
				push_error(
					"[Tile Studio] cannot flatten terrain for unresolved GLB '%s'; placement continues unchanged."
					% prop.asset_id
				)
			continue
		if not asset.prop_contact_flatten:
			continue
		var support_height_m := board.prop_terrain_support_height(prop, target_terrain)
		var footprint := prop.footprint_cells(asset)
		var existing_cells: Array[Vector2i] = []
		for cell: Vector2i in footprint:
			if target_terrain.is_cell_filled(cell):
				existing_cells.append(cell)
		if existing_cells.is_empty():
			if report_messages:
				push_warning(
					"[Tile Studio] GLB '%s' has no existing heightfield quads under its voxel footprint; placement continues unchanged."
					% prop.asset_id
				)
			continue
		if report_messages and existing_cells.size() != footprint.size():
			push_warning(
				"[Tile Studio] GLB '%s' overhangs the heightfield; flattened %d of %d voxel-footprint quads and kept placement."
				% [prop.asset_id, existing_cells.size(), footprint.size()]
			)
		var result: Dictionary
		if asset.prop_contact_flatten_smooth:
			result = sculptor.flatten_cells_smooth(
				existing_cells,
				support_height_m
			)
		else:
			result = sculptor.flatten_cells(existing_cells, support_height_m)
		var changed_bounds: Rect2i = result.get("bounds", Rect2i())
		if changed_bounds.size.x > 0 and changed_bounds.size.y > 0:
			# Side-face ownership can change one cell beyond the written tops.
			terrain_regions.append(changed_bounds.grow(1))
	var patch := sculptor.finish_stroke()
	if not patch.is_empty():
		patch["terrain_regions"] = terrain_regions
	return patch


## Build the exact reversible heightfield patch requested by floor GLB assets.
##
## Each overlapping instance neighbourhood is previewed on its own terrain slice,
## then the disjoint sparse patches are combined into one atomic undo record.
func _prop_terrain_flatten_patch(
	props: Array[PropPlacement],
	report_messages: bool = true
) -> Dictionary:
	if board == null or not _props_request_contact_flatten(props):
		return {}
	if board.terrain == null or board.terrain.is_empty():
		if report_messages:
			push_warning(
				"[Tile Studio] GLB terrain flatten is enabled, but the board has no heightfield; placement continues unchanged."
			)
		return {}
	var local_patches: Array[Dictionary] = []
	for group: Dictionary in _prop_contact_groups(props):
		var preview_terrain := board.terrain.duplicate_region(group["bounds"])
		var group_props: Array[PropPlacement] = []
		for value: Variant in group["props"] as Array:
			var prop := value as PropPlacement
			if prop != null:
				group_props.append(prop)
		var patch := _flatten_props_on_terrain(
			preview_terrain,
			group_props,
			report_messages
		)
		if not patch.is_empty():
			local_patches.append(patch)
	return _combine_prop_terrain_patches(local_patches)


## Return the exact world minimum corner shared by a preview's collision voxels and art.
##
## No prediction of the pending flatten happens here any more. Contact flatten now
## levels the pad to wherever ordinary placement already stands the GLB, so the
## canonical pose is unchanged by the commit and the hovering preview shows the
## height the board will actually store.
func _prop_preview_world_origin(prop: PropPlacement) -> Vector3:
	if prop == null:
		return Vector3.ZERO
	if board == null:
		return Vector3(prop.origin)
	return board.prop_world_origin(prop)


## Apply a reversible terrain-only patch and resynchronize local support props.
##
## The sparse height write is followed by targeted support reconciliation so
## observers receive only the instance neighbourhoods whose terrain changed.
func _apply_existing_prop_contact_patch(
	patch: Dictionary,
	use_after_state: bool
) -> void:
	if board == null or board.terrain == null:
		push_error("[Tile Studio] cannot apply an existing GLB flatten without a board heightfield.")
		return
	var regions := _patch_terrain_regions(patch)
	var support_snapshot := board.capture_prop_support_state(regions)
	var cells: PackedVector2Array = patch.get("cells", PackedVector2Array())
	var tops: PackedFloat32Array = patch.get(
		"after_tops" if use_after_state else "before_tops",
		PackedFloat32Array()
	)
	var sides: Dictionary = patch.get(
		"after_sides" if use_after_state else "before_sides",
		{}
	)
	var sculptor := TerrainSculptorScript.new(board.terrain)
	sculptor.apply_patch(cells, tops, sides)
	var support_props := board.reconcile_prop_support_state(support_snapshot)
	board.board_changed.emit()
	var no_props: Array[PropPlacement] = []
	prop_terrain_regions_mutated.emit(
		regions,
		support_props,
		no_props,
		no_props,
		patch.get("terrain_paint_uids", PackedStringArray())
	)


## Apply this asset's enabled flatten mode to every existing floor instance.
##
## Disabling flatten changes future behavior but does not invent pre-flatten terrain
## that the board no longer stores. Enabling it, or changing its smooth mode, commits
## one undoable terrain patch covering every matching instance.
func apply_asset_contact_flatten(asset_id: String) -> int:
	if board == null or asset_id.is_empty():
		return 0
	var asset := board.resolve_asset(asset_id)
	if asset == null or not asset.is_prop():
		push_error("[Tile Studio] cannot apply flatten for unknown GLB asset '%s'." % asset_id)
		return 0
	if not asset.prop_contact_flatten:
		return 0
	var matching_props: Array[PropPlacement] = []
	for prop: PropPlacement in board.props:
		if prop.asset_id == asset_id and prop.support == PropPlacement.SUPPORT_FLOOR:
			matching_props.append(prop)
	if matching_props.is_empty():
		return 0
	var patch := _prop_terrain_flatten_patch(matching_props)
	if patch.is_empty():
		return 0
	var action := "Flatten terrain under %d '%s' instance%s" % [
		matching_props.size(),
		asset.display_name if not asset.display_name.is_empty() else asset.asset_id,
		"" if matching_props.size() == 1 else "s",
	]
	if undo_redo == null:
		_apply_existing_prop_contact_patch(patch, true)
	else:
		undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
		undo_redo.add_do_method(
			self,
			"_apply_existing_prop_contact_patch",
			patch,
			true
		)
		undo_redo.add_undo_method(
			self,
			"_apply_existing_prop_contact_patch",
			patch,
			false
		)
		undo_redo.commit_action()
	return matching_props.size()


## Apply one atomic placement-and-terrain state for do, undo, and redo.
##
## Terrain changes are installed before the placement set changes, so the single
## regional notification exposes a consistent final state to viewport observers.
func _apply_prop_terrain_transaction(
	removed_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	patch: Dictionary,
	use_after_state: bool
) -> void:
	if board == null or board.terrain == null:
		push_error("[Tile Studio] cannot apply a GLB terrain transaction without a board heightfield.")
		return
	var regions := _patch_terrain_regions(patch)
	var support_snapshot := board.capture_prop_support_state(regions)
	var cells: PackedVector2Array = patch.get("cells", PackedVector2Array())
	var tops: PackedFloat32Array = patch.get(
		"after_tops" if use_after_state else "before_tops",
		PackedFloat32Array()
	)
	var sides: Dictionary = patch.get(
		"after_sides" if use_after_state else "before_sides",
		{}
	)
	var sculptor := TerrainSculptorScript.new(board.terrain)
	sculptor.apply_patch(cells, tops, sides)
	var support_props := board.reconcile_prop_support_state(support_snapshot)
	if removed_props.is_empty():
		board.add_props_bulk(added_props)
	elif added_props.is_empty():
		board.remove_props_bulk(removed_props)
	else:
		board.replace_props_bulk(removed_props, added_props)
	prop_terrain_regions_mutated.emit(
		regions,
		support_props,
		added_props,
		removed_props,
		patch.get("terrain_paint_uids", PackedStringArray())
	)


## Commit a native terrain flatten in the same history action as its GLB placement.
func _commit_prop_terrain_transaction(
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	action: String
) -> bool:
	var patch := _prop_terrain_flatten_patch(added_props)
	if patch.is_empty():
		return false
	if undo_redo == null:
		_apply_prop_terrain_transaction(removed_props, added_props, patch, true)
		return true
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(
		self,
		"_apply_prop_terrain_transaction",
		removed_props,
		added_props,
		patch,
		true
	)
	undo_redo.add_undo_method(
		self,
		"_apply_prop_terrain_transaction",
		added_props,
		removed_props,
		patch,
		false
	)
	undo_redo.commit_action()
	return true


## Commit validated surface or prop placements through one bulk undo path.
##
## Typed arrays are created only at the BoardDocument boundary; every caller uses
## the same Resource batch, whether it contains one Paint stamp or a large Fill.
func _commit_placements_bulk(placements: Array[Resource], action: String) -> void:
	if placements.is_empty() or board == null:
		return
	var mutation_mask := _mutation_mask_for_resources(placements)

	var do_method := ""
	var undo_method := ""
	var typed_placements: Array
	var prop_placements: Array[PropPlacement] = []
	if placements[0] is SurfacePlacement:
		var surfaces: Array[SurfacePlacement] = []
		for placement: Resource in placements:
			surfaces.append(placement as SurfacePlacement)
		typed_placements = surfaces
		do_method = "add_surfaces_bulk"
		undo_method = "remove_surfaces_bulk"
	elif placements[0] is PropPlacement:
		for placement: Resource in placements:
			prop_placements.append(placement as PropPlacement)
		typed_placements = prop_placements
		do_method = "add_props_bulk"
		undo_method = "remove_props_bulk"
	else:
		push_error("[Tile Studio] cannot commit an unsupported placement batch.")
		return

	var no_removed_props: Array[PropPlacement] = []
	if (
		not prop_placements.is_empty()
		and _commit_prop_terrain_transaction(
			prop_placements,
			no_removed_props,
			action
		)
	):
		return

	if undo_redo == null:
		board.call(do_method, typed_placements)
		board_mutated.emit(mutation_mask)
		return

	# Board mutation precedes refresh in both directions, so observers always
	# synchronize from the state that the undo history has just established.
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, do_method, typed_placements)
	undo_redo.add_undo_method(board, undo_method, typed_placements)
	undo_redo.add_do_method(self, "_notify_mutated", mutation_mask)
	undo_redo.add_undo_method(self, "_notify_mutated", mutation_mask)
	undo_redo.commit_action()


## Build preserved face-level remnants for displaced direct terrain textures.
##
## A placement may span many heightfield faces, so replacing one brush footprint
## must not delete the untouched faces that happen to share that placement Resource.
func _surface_replacement_residuals(
	replacements: Array[SurfacePlacement],
	displaced: Array[SurfacePlacement]
) -> Array[SurfacePlacement]:
	var residuals: Array[SurfacePlacement] = []
	var replaced_keys: Dictionary = {}
	for replacement: SurfacePlacement in replacements:
		if replacement.asset_id.is_empty():
			continue
		for uid: String in replacement.terrain_face_uids:
			replaced_keys[uid] = true
	for original: SurfacePlacement in displaced:
		if original.asset_id.is_empty() or original.is_overlay():
			# A decal is one authored stamp. Visible-pixel replacement removes that
			# exact prior stamp rather than inventing face-clipped residual copies.
			continue
		var remaining_uids := PackedStringArray()
		for uid: String in original.terrain_face_uids:
			if not replaced_keys.has(uid):
				remaining_uids.append(uid)
		if remaining_uids.is_empty():
			continue
		var residual := original.duplicate() as SurfacePlacement
		residual.terrain_face_uids = remaining_uids
		residuals.append(residual)
	return residuals


## Atomically replace conflicting placements through the same document undo history.
##
## A replacement first removes only the canonical conflicts discovered during
## validation, then adds the new placement batch. Undo executes the inverse
## atomically, so it restores the displaced resources rather than approximating
## their old geometry from the newly painted brush.
func _commit_replacements(
	placements: Array[Resource],
	displaced: Array[Resource],
	action: String
) -> void:
	if placements.is_empty() or displaced.is_empty() or board == null:
		_commit_placements_bulk(placements, action)
		return
	var mutation_mask := _mutation_mask_for_resources(placements)

	var replace_method := ""
	var new_typed: Array
	var displaced_typed: Array
	if placements[0] is SurfacePlacement:
		var new_surfaces: Array[SurfacePlacement] = []
		var displaced_surfaces: Array[SurfacePlacement] = []
		for placement: Resource in placements:
			if not placement is SurfacePlacement:
				push_error("[Tile Studio] replacement mixes surface and prop placements.")
				return
			new_surfaces.append(placement as SurfacePlacement)
		for placement: Resource in displaced:
			if not placement is SurfacePlacement:
				push_error("[Tile Studio] surface replacement cannot remove a prop.")
				return
			displaced_surfaces.append(placement as SurfacePlacement)
		new_surfaces.append_array(_surface_replacement_residuals(
			new_surfaces,
			displaced_surfaces
		))
		replace_method = "replace_surfaces_bulk"
		new_typed = new_surfaces
		displaced_typed = displaced_surfaces
	elif placements[0] is PropPlacement:
		var new_props: Array[PropPlacement] = []
		var displaced_props: Array[PropPlacement] = []
		for placement: Resource in placements:
			if not placement is PropPlacement:
				push_error("[Tile Studio] replacement mixes surface and prop placements.")
				return
			new_props.append(placement as PropPlacement)
		for placement: Resource in displaced:
			if not placement is PropPlacement:
				push_error("[Tile Studio] prop replacement cannot remove a surface.")
				return
			displaced_props.append(placement as PropPlacement)
		if _commit_prop_terrain_transaction(new_props, displaced_props, action):
			return
		replace_method = "replace_props_bulk"
		new_typed = new_props
		displaced_typed = displaced_props
	else:
		push_error("[Tile Studio] cannot replace with an unsupported placement type.")
		return

	if undo_redo == null:
		board.call(replace_method, displaced_typed, new_typed)
		board_mutated.emit(mutation_mask)
		return

	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, replace_method, displaced_typed, new_typed)
	# Undo methods run in reverse registration order. Register notification
	# first so observers see the restored board after the inverse replacement.
	undo_redo.add_undo_method(self, "_notify_mutated", mutation_mask)
	undo_redo.add_undo_method(board, replace_method, new_typed, displaced_typed)
	undo_redo.add_do_method(self, "_notify_mutated", mutation_mask)
	undo_redo.commit_action()


## Remove one surface placement through the global document undo history.
func _commit_remove_surface(placement: SurfacePlacement, action: String) -> void:
	if undo_redo == null:
		board.remove_surface(placement)
		board_mutated.emit(BoardMutation.SURFACES)
		return
	# Pin to the GLOBAL history explicitly.
	#
	# Without a target object EditorUndoRedoManager guesses which history an
	# action belongs to, and board edits are not tied to any scene node -- so they
	# landed in whichever scene history happened to be active and were discarded
	# when the editor switched away from it. That is what made undo appear to only
	# go back a step or two. The board is a document of its own, so its history is
	# the global one.
	# Keep undo replay in insertion order so the board changes before observers rebuild.
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, "remove_surface", placement)
	undo_redo.add_undo_method(board, "add_surface", placement)
	undo_redo.add_do_method(self, "_notify_mutated", BoardMutation.SURFACES)
	undo_redo.add_undo_method(self, "_notify_mutated", BoardMutation.SURFACES)
	undo_redo.commit_action()
func _commit_remove_prop(placement: PropPlacement, action: String) -> void:
	if undo_redo == null:
		board.remove_prop(placement)
		board_mutated.emit(BoardMutation.PROPS)
		return
	# Pin to the GLOBAL history explicitly.
	#
	# Without a target object EditorUndoRedoManager guesses which history an
	# action belongs to, and board edits are not tied to any scene node -- so they
	# landed in whichever scene history happened to be active and were discarded
	# when the editor switched away from it. That is what made undo appear to only
	# go back a step or two. The board is a document of its own, so its history is
	# the global one.
	# Keep undo replay in insertion order so the board changes before observers rebuild.
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, null, false)
	undo_redo.add_do_method(board, "remove_prop", placement)
	undo_redo.add_undo_method(board, "add_prop", placement)
	undo_redo.add_do_method(self, "_notify_mutated", BoardMutation.PROPS)
	undo_redo.add_undo_method(self, "_notify_mutated", BoardMutation.PROPS)
	undo_redo.commit_action()


## Emit one already-classified mutation after its document method completes.
func _notify_mutated(mutation_mask: int) -> void:
	board_mutated.emit(mutation_mask)
