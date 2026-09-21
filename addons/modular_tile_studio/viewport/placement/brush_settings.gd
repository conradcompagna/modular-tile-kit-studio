@tool
extends RefCounted

## Brush settings behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

# --- Brush ----------------------------------------------------------------

## Select one asset and reset its transient placement orientation to canonical Y-up.
##
## PNG surfaces begin on +Y with no spin, while GLB props retain their untouched
## source pose with local forward -Z and no roll. Only editor rotation commands
## change these values; the asset resource contains no competing default.
static func set_brush(host: MTSPlacementController, asset: TileAsset) -> void:
	host._reset_fill_state()
	host.brush_asset = asset
	if asset != null:
		host.brush_face = MTSPlacementController.K.Face.POS_Y
		host.brush_quarters = 0
		host.brush_surface_presentation = SurfacePlacement.Presentation.TERRAIN_PAINT
		host.brush_surface_edge_mode = false
		host._surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
		host.brush_prop_forward_face = MTSPlacementController.K.Face.NEG_Z
		host.brush_prop_roll_quarters = 0
		host.brush_prop_yaw_eighths = 0
		host.brush_prop_support = (
			PropPlacement.SUPPORT_FLOOR
			if asset.is_prop()
			else PropPlacement.SUPPORT_NONE
		)
		host._active_prop_support_face = MTSPlacementController.K.Face.POS_Y

		if host.tool == MTSPlacementController.Tool.ERASE or host.tool == MTSPlacementController.Tool.SELECT:
			host.set_tool(MTSPlacementController.Tool.PAINT)

	host._rebuild_preview()
	host.update_preview_visibility()


## Set the palette choice copied onto subsequently stamped decals.
##
## This transient value comes from the visible Texture Paint toggle and is copied
## into each placement, so changing the brush cannot alter authored stamps.
static func set_surface_palette_matching(host: MTSPlacementController, match_underlying_palette: bool) -> void:
	host.brush_match_underlying_palette = match_underlying_palette


## Set whether subsequently stamped decals use the dedicated lattice-edge targeter.
static func set_surface_edge_mode(host: MTSPlacementController, enabled: bool) -> void:
	if host.brush_surface_edge_mode == enabled:
		return
	host.brush_surface_edge_mode = enabled
	host._surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
	# Changing target primitives invalidates the previous hover completely. The
	# viewport immediately performs a fresh ray pick through the selected route.
	if host._preview_root != null:
		host._preview_root.visible = false


## Set the surface presentation used by subsequently stamped image assets.
##
## This transient brush choice is set by the visible Texture Paint control and
## copied directly into each saved SurfacePlacement at commit time.
static func set_surface_presentation(host: MTSPlacementController, presentation: int) -> void:
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
	if host.brush_surface_presentation == presentation:
		return
	host.brush_surface_presentation = presentation
	if presentation == SurfacePlacement.Presentation.TERRAIN_PAINT:
		host.brush_surface_edge_mode = false
		host._surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
	if host.brush_is_surface():
		host._evaluate_hover()
		host._position_preview()


## Set the explicit structural support stored on subsequently painted props.
static func set_prop_support(host: MTSPlacementController, support: String) -> void:
	if support != PropPlacement.SUPPORT_FLOOR and support != PropPlacement.SUPPORT_WALL:
		push_error("[Tile Studio] prop support must be 'floor' or 'wall'.")
		return
	host.brush_prop_support = support
	if host.brush_is_prop():
		host._evaluate_hover()
		host._position_preview()
		if host.has_fill_vertices():
			host._refresh_fill_candidates()


## Return whether a canonical brush asset is active.
static func has_brush(host: MTSPlacementController) -> bool:
	return host.brush_asset != null


## Return whether Fill currently has something to apply: a brush, or terrain.
##
## Terrain Fill needs no asset, so every Fill gate asks this rather than
## Return whether Fill targets terrain cells instead of asset placements.
static func _fill_targets_terrain(host: MTSPlacementController) -> bool:
	return host.terrain_fill_enabled or host.terrain_splat_paint_enabled


## Report whether Fill has one visible tool capable of committing its generated origins.
##
## Splatmap mode intentionally needs no single asset brush because one commit writes
## every assigned RGBA channel through the viewport paint owner.
static func _fill_is_armed(host: MTSPlacementController) -> bool:
	return host._fill_targets_terrain() or host.has_brush()


## Arm or disarm terrain Fill to match the viewport's visible terrain tool.
##
## Changing what Fill would commit invalidates any half-drawn shape, so the
## pending vertices are discarded rather than silently re-interpreted.
static func set_terrain_fill(host: MTSPlacementController, enabled: bool, allows_new_cells: bool) -> void:
	if (
		host.terrain_fill_enabled == enabled
		and host.terrain_fill_allows_new_cells == allows_new_cells
	):
		return
	host.terrain_fill_enabled = enabled
	host.terrain_fill_allows_new_cells = allows_new_cells
	if enabled:
		host.terrain_splat_paint_enabled = false
		host._terrain_material_target_validator = Callable()
	host._reset_fill_state()
	host.update_preview_visibility()


## Switch the active tool, announcing the change exactly once.
##
## Fill is a generic placement mode for surfaces and GLB props. Leaving it
## discards only its transient point-defined shape.
static func set_tool(host: MTSPlacementController, p_tool: int) -> void:
	if host.tool == p_tool:
		return

	if host.tool == MTSPlacementController.Tool.FILL and p_tool != MTSPlacementController.Tool.FILL:
		host._reset_fill_state()

	host.tool = p_tool
	host.update_preview_visibility()
	host.tool_changed.emit(host.tool)


## Set the square direct-texture stamp width and immediately refresh its exact preview.
static func set_surface_grid_stroke_size(host: MTSPlacementController, size_m: float) -> void:
	host.surface_grid_stroke_size_m = clampi(roundi(size_m), 1, 100)
	if (
		host.board != null
		and (
			host.terrain_splat_paint_enabled
			or (host.has_brush() and host.brush_is_surface() and host.brush_asset != null)
		)
	):
		host._evaluate_hover()
		if host._preview_root != null:
			host._position_preview()
		host.update_preview_visibility()


## Change whether occupancy conflicts are replaced by the active brush.
##
## The setting is intentionally independent from the paint, Fill, and Erase
## tools: the toolbar shows this exact boolean, while every placement path reads
## it through _validate_placement before any BoardDocument mutation occurs.
static func set_replace_enabled(host: MTSPlacementController, enabled: bool) -> void:
	if host.replace_enabled == enabled:
		return
	host.replace_enabled = enabled
	if host.board != null and (host.has_brush() or host.terrain_splat_paint_enabled):
		host._evaluate_hover()
		if host._preview_root != null:
			host._position_preview()
		if host.has_fill_vertices():
			host._refresh_fill_candidates()
		host.update_preview_visibility()
	host.replace_mode_changed.emit(host.replace_enabled)


static func set_fill_shape(host: MTSPlacementController, p_fill_shape: int) -> void:
	if p_fill_shape != MTSPlacementController.FillShape.PATH and p_fill_shape != MTSPlacementController.FillShape.POLYGON:
		push_error("[Tile Studio] Fill shape must be PATH or POLYGON.")
		return
	if host.fill_shape == p_fill_shape:
		return
	host._reset_fill_state()
	host.fill_shape = p_fill_shape
	host.update_preview_visibility()


## Return the visible label for the current Fill interpretation.
static func fill_shape_name(host: MTSPlacementController) -> String:
	return "PATH" if host.fill_shape == MTSPlacementController.FillShape.PATH else "POLYGON"


## Clear the brush and discard any transient Fill state.

static func clear_brush(host: MTSPlacementController) -> void:
	host._reset_fill_state()
	host.brush_asset = null
	host._active_prop_support_face = MTSPlacementController.K.Face.POS_Y
	if host._preview_root != null:
		host._preview_root.visible = false


## Show the cursor ghost together with every active Fill stamp batch.
##
## The cursor ghost remains visible after the first point so the next clicked
## footprint is explicit, while the Fill batches show the complete pending result.
static func update_preview_visibility(host: MTSPlacementController) -> void:
	if host._preview_root == null:
		return
	host._ensure_cursor_preview_outlines()
	# Terrain Fill has no asset ghost of its own; its cursor is the Terrain panel's
	# own targeter, so only the Fill shape preview below is shown for it.
	var show_terrain_tile_preview := (
		host.terrain_splat_paint_enabled
		and (host.tool == MTSPlacementController.Tool.PAINT or host.tool == MTSPlacementController.Tool.ERASE)
	)
	var show_ordinary_preview := (
		host.has_brush()
		and not host._fill_targets_terrain()
		and (host.tool == MTSPlacementController.Tool.PAINT or host.tool == MTSPlacementController.Tool.FILL)
	)
	host._preview_root.visible = (
		show_ordinary_preview
		or show_terrain_tile_preview
		or (host._fill_targets_terrain() and host.tool == MTSPlacementController.Tool.FILL)
	)
	host._preview_mesh.visible = (
		(show_ordinary_preview and host.brush_is_surface())
		or show_terrain_tile_preview
	)
	host._preview_surface_outline.visible = host._preview_mesh.visible
	host._preview_box.visible = show_ordinary_preview and host.brush_is_volume()
	host._preview_box_outline.visible = show_ordinary_preview and host.brush_is_volume()
	host._preview_arrow.visible = (
		show_ordinary_preview
		or (show_terrain_tile_preview and host._terrain_splat_uses_surface_brush)
	)
	if host._fill_preview_root != null:
		host._fill_preview_root.visible = (
			host.tool == MTSPlacementController.Tool.FILL
			and not host._fill_preview_vertices.is_empty()
			and (
				not host._fill_preview_valid_origins.is_empty()
				or not host._fill_preview_blocked_origins.is_empty()
			)
		)


## Rebuild the preview from the current asset values without altering editor orientation.
##
## Size and material edits must update the live ghost, but face, spin, forward,
## and roll belong exclusively to the user's placement controls.

static func refresh_brush(host: MTSPlacementController) -> void:
	if not host.has_brush():
		return
	host._evaluate_hover()
	host._rebuild_preview()


## Aim the surface brush directly at a grid face, bypassing stepwise rotation.

static func set_brush_face(host: MTSPlacementController, face: int) -> void:
	if not host.brush_is_surface():
		return
	if host.has_fill_vertices():
		host._reset_fill_state()
	host.brush_face = face
	host.brush_quarters = 0
	host._rebuild_preview()


## Align a surface brush to the pointed terrain face without changing its PNG quarter-turn.
static func align_surface_brush_face(host: MTSPlacementController, face: int) -> void:
	if not host.brush_is_surface() or not MTSPlacementController.K.FACE_NORMALS.has(face):
		return
	if host.brush_face == face:
		return
	host.brush_face = face
	if host.terrain_splat_paint_enabled and host._terrain_splat_follow_hover_face:
		host._terrain_splat_face = face
	host._rebuild_preview()


## Set the active prop brush to one explicit complete orientation.
##
## This is the non-keyboard route used by the bridge and keeps its state on the
## same face, roll, and 45-degree yaw representation used by arrow-key rotation.

static func set_prop_orientation(host: MTSPlacementController,
	forward_face: int,
	roll_quarters: int = 0,
	yaw_eighths: int = 0
) -> void:
	if not host.brush_is_volume():
		return
	if not MTSPlacementController.K.FACE_NORMALS.has(forward_face):
		push_error("[Tile Studio] prop orientation needs one of the six grid faces.")
		return
	if host.has_fill_vertices():
		host._reset_fill_state()
	host.brush_prop_forward_face = forward_face
	host.brush_prop_roll_quarters = MTSPlacementController.K.normalized_quarters(roll_quarters)
	host.brush_prop_yaw_eighths = MTSPlacementController.K.normalized_yaw_eighths(yaw_eighths)
	host._rebuild_preview()


## Rotate the current brush by one keyboard step about its visible yaw-aligned axis.
##
## GLB props use 45-degree horizontal yaw steps for four cardinals plus four
## diagonals; their existing 90-degree flip and roll commands remain explicit.
## Surface placements and surfaced-box slots retain their existing quarter-turn behavior.

static func rotate_brush(host: MTSPlacementController, axis: Vector3i, positive: bool) -> void:
	if not host.has_brush():
		return
	if host.has_fill_vertices():
		host._reset_fill_state()

	if host.brush_is_prop():
		var prop_orientation := MTSPlacementController.K.rotate_prop_orientation(
			host.brush_prop_forward_face,
			host.brush_prop_roll_quarters,
			axis,
			positive,
			host.brush_prop_yaw_eighths
		)
		host.brush_prop_forward_face = int(prop_orientation["forward_face"])
		host.brush_prop_roll_quarters = int(prop_orientation["roll_quarters"])
		host.brush_prop_yaw_eighths = int(prop_orientation["yaw_eighths"])
	else:
		var surface_orientation := MTSPlacementController.K.rotate_surface_orientation(
			host.brush_face,
			host.brush_quarters,
			axis,
			positive
		)
		host.brush_face = int(surface_orientation["face"])
		host.brush_quarters = int(surface_orientation["rotation_quarters"])
		if host.terrain_splat_paint_enabled and host._terrain_splat_uses_surface_brush:
			host._terrain_splat_face = host.brush_face
	host._rebuild_preview()
