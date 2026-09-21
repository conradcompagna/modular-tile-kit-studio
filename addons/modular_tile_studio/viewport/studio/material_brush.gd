@tool
extends RefCounted

## Material brush behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Build one lightweight editor-only ring owner that never enters board or placement data.
static func _build_material_brush_preview(host: MTSStudioViewport) -> void:
	host._material_brush_preview_material = StandardMaterial3D.new()
	host._material_brush_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	host._material_brush_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	host._material_brush_preview_material.albedo_color = Color(0.12, 0.86, 1.0, 0.92)
	host._material_brush_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	host._material_brush_preview_material.no_depth_test = true
	host._material_brush_preview_material.render_priority = 10
	host._material_brush_preview = MeshInstance3D.new()
	host._material_brush_preview.name = "MaterialBrushPreview"
	host._material_brush_preview.mesh = ImmediateMesh.new()
	host._material_brush_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._material_brush_preview.visible = false
	host.world_root.add_child(host._material_brush_preview)
	host._rebuild_material_brush_preview_mesh(host.material_brush_radius_m)


## Hide the transient ring without touching the active tool or any authored image.
static func _hide_material_brush_preview(host: MTSStudioViewport) -> void:
	if is_instance_valid(host._material_brush_preview) and host._material_brush_preview.visible:
		host._material_brush_preview.visible = false
		host.request_render()


## Ray-pick once, update the visible ring, and return the same hit for an active stroke.
static func _update_material_brush_preview(host: MTSStudioViewport, mouse_position: Vector2) -> Dictionary:
	if host.material_paint_tool == MTSStudioViewport.MaterialPaintTool.NONE:
		host._hide_material_brush_preview()
		host._hide_height_brush_preview()
		return {}
	var hit := host._material_surface_hit(mouse_position)
	if hit.is_empty():
		host._hide_material_brush_preview()
		host._hide_height_brush_preview()
		return {}
	host._draw_material_brush_preview(hit)
	return hit


## Rebuild the cursor's local ring only when its visible physical radius changes.
static func _rebuild_material_brush_preview_mesh(host: MTSStudioViewport, radius_m: float) -> void:
	if not is_instance_valid(host._material_brush_preview):
		return
	var immediate_mesh := host._material_brush_preview.mesh as ImmediateMesh
	if immediate_mesh == null:
		return
	var radius := maxf(radius_m, 0.01)
	var band := clampf(radius * 0.12, 0.008, 0.06)
	var inner_radius := maxf(radius - band, radius * 0.35)
	var outer_radius := radius + band
	immediate_mesh.clear_surfaces()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, host._material_brush_preview_material)
	for segment: int in MTSStudioViewport.MATERIAL_BRUSH_PREVIEW_SEGMENTS:
		var angle_a := TAU * float(segment) / float(MTSStudioViewport.MATERIAL_BRUSH_PREVIEW_SEGMENTS)
		var angle_b := TAU * float(segment + 1) / float(MTSStudioViewport.MATERIAL_BRUSH_PREVIEW_SEGMENTS)
		var direction_a := Vector3(cos(angle_a), sin(angle_a), 0.0)
		var direction_b := Vector3(cos(angle_b), sin(angle_b), 0.0)
		var inner_a := direction_a * inner_radius
		var outer_a := direction_a * outer_radius
		var inner_b := direction_b * inner_radius
		var outer_b := direction_b * outer_radius
		for vertex: Vector3 in [inner_a, outer_a, outer_b, inner_a, outer_b, inner_b]:
			immediate_mesh.surface_add_vertex(vertex)
	immediate_mesh.surface_end()
	host._material_brush_preview_mesh_radius_m = radius


## Draw the circular pen on the exact terrain plane under the pointer.
static func _draw_material_brush_preview(host: MTSStudioViewport, hit: Dictionary) -> void:
	if not is_instance_valid(host._material_brush_preview):
		return
	host._hide_height_brush_preview()
	var radius := maxf(host.material_brush_radius_m, 0.01)
	if not is_equal_approx(host._material_brush_preview_mesh_radius_m, radius):
		host._rebuild_material_brush_preview_mesh(radius)
	var center: Vector3 = hit.get("world_position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal_world", Vector3.UP).normalized()
	var tangent: Vector3 = hit.get("tangent_world", Vector3.RIGHT).normalized()
	var binormal: Vector3 = hit.get("binormal_world", Vector3.FORWARD).normalized()
	center += normal * MTSStudioViewport.MATERIAL_BRUSH_PREVIEW_OFFSET_M
	host._material_brush_preview.global_transform = Transform3D(
		Basis(tangent, binormal, normal).orthonormalized(),
		center
	)
	host._material_brush_preview.visible = true
	host.request_render()


## Arm a surface asset for one-click Godot-native decal placement.
##
## Native decals use the ordinary placement controller, and the palette choice is
## copied into each saved placement so its appearance remains inspectable.
static func arm_native_decal_brush(host: MTSStudioViewport,
	asset: TileAsset,
	match_underlying_palette: bool,
	edge_mode_enabled: bool = false
) -> void:
	host.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	if host.placement == null:
		push_error("[Tile Studio] Cannot arm a decal brush without placement controls.")
		return
	if host.placement.brush_asset != asset:
		host.placement.set_brush(asset)
	host.placement.set_surface_palette_matching(match_underlying_palette)
	host.placement.set_surface_presentation(SurfacePlacement.Presentation.DECAL)
	host.placement.set_surface_edge_mode(edge_mode_enabled)
	host.placement.set_tool(MTSPlacementController.Tool.PAINT)
	# A mode change invalidates the prior primitive, so the stationary cursor is
	# immediately repicked as either a canonical edge or an ordinary cell.
	host.placement.update_hover(host.camera, host._last_mouse)


## Arm a surface asset for one-click terrain-material stamping.
##
## Shader decals are saved placements whose maps are composed into the receiving
## face arrays. They therefore use the ordinary terrain draw and its complete
## lighting and parallax pipeline instead of a separate transparent surface.
static func arm_shader_decal_brush(host: MTSStudioViewport,
	asset: TileAsset,
	match_underlying_palette: bool,
	edge_mode_enabled: bool = false
) -> void:
	host.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	if host.placement == null:
		push_error("[Tile Studio] Cannot arm a shader decal brush without placement controls.")
		return
	if host.placement.brush_asset != asset:
		host.placement.set_brush(asset)
	host.placement.set_surface_palette_matching(match_underlying_palette)
	host.placement.set_surface_presentation(SurfacePlacement.Presentation.SHADER_DECAL)
	host.placement.set_surface_edge_mode(edge_mode_enabled)
	host.placement.set_tool(MTSPlacementController.Tool.PAINT)
	# Shader decals use the same explicit edge primitive as native decals.
	host.placement.update_hover(host.camera, host._last_mouse)


## Return the ordinary surface brush to terrain-material paint presentation.
static func disarm_native_decal_brush(host: MTSStudioViewport) -> void:
	if host.placement != null:
		host.placement.set_surface_presentation(SurfacePlacement.Presentation.TERRAIN_PAINT)
		host.placement.set_surface_edge_mode(false)


## Select the transient material pen while keeping input ownership explicit.
static func set_material_paint_tool(host: MTSStudioViewport, tool: int) -> void:
	host._end_material_paint()
	host.material_paint_tool = clampi(tool, MTSStudioViewport.MaterialPaintTool.NONE, MTSStudioViewport.MaterialPaintTool.ERASE)
	if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE and host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
		host._end_height_sculpt()
		host._hide_height_brush_preview()
		host.height_sculpt_tool = MTSStudioViewport.HeightSculptTool.NONE
		host.height_sculpt_tool_changed.emit(host.height_sculpt_tool)
	host._refresh_placement_visibility()
	if host.material_paint_tool == MTSStudioViewport.MaterialPaintTool.NONE:
		host._hide_material_brush_preview()
		host._hide_height_brush_preview()
	else:
		host._update_material_brush_preview(host._last_mouse)
	host.material_paint_tool_changed.emit(host.material_paint_tool)
	host._emit_status()
	host.request_render()


## Set the one canonical square brush width shared by texture stamping and terrain.
##
## This single toolbar value is the width for direct PNG placement, Fill stamping,
## and every terrain brush. The terrain panel deliberately owns no second size
## control, so the width the user sets is always the width a sculpt stroke uses.
static func set_surface_grid_stroke_size(host: MTSStudioViewport, size_m: float) -> void:
	host.surface_grid_stroke_size_m = clampi(roundi(size_m), 1, 100)
	if host.placement != null:
		host.placement.set_surface_grid_stroke_size(host.surface_grid_stroke_size_m)
	# Terrain reads this width through _push_terrain_brush_settings(), so the live
	# sculptor and the on-screen targeter both have to be refreshed here.
	host._push_terrain_brush_settings()
	host._update_active_terrain_brush_preview(host._last_mouse)
	host._emit_status()


## Set the Materials-owned circular pen radius independently from grid placement.
static func set_material_brush_radius(host: MTSStudioViewport, radius_m: float) -> void:
	host.material_brush_radius_m = clampf(radius_m, 0.01, 100.0)
	if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
		host._update_material_brush_preview(host._last_mouse)


## Set the maximum pen opacity applied by one completed stroke.
static func set_material_brush_opacity(host: MTSStudioViewport, opacity: float) -> void:
	host.material_brush_opacity = clampf(opacity, 0.0, 1.0)


## Set the pen edge hardness while preserving the same physical outer radius.
static func set_material_brush_hardness(host: MTSStudioViewport, hardness: float) -> void:
	host.material_brush_hardness = clampf(hardness, 0.0, 1.0)


## Select which palette material the brush paints.
##
## This is a board palette index, not one of the four texel slots: the slot a stroke
## writes is resolved per face at paint time, because different faces may carry
## different four-material sets.
static func set_material_brush_palette_index(host: MTSStudioViewport, palette_index: int) -> void:
	host.material_brush_palette_index = maxi(palette_index, 0)


## Arm one overlay PNG through the same brush state used by regular tile painting.
static func set_material_layer_brush_asset(host: MTSStudioViewport, asset: TileAsset) -> void:
	if asset == null or not asset.is_surface():
		push_error("[Tile Studio] layered material painting requires a valid PNG surface asset.")
		return
	host.material_layer_brush_asset = asset
	if host.placement == null:
		return
	if host.placement.brush_asset != asset:
		host.placement.set_brush(asset)
	host.placement.set_surface_presentation(SurfacePlacement.Presentation.TERRAIN_PAINT)


## Disarm the layered PNG brush without leaving an ordinary tile targeter visible.
static func clear_material_layer_brush_asset(host: MTSStudioViewport) -> void:
	var previous_asset := host.material_layer_brush_asset
	host.material_layer_brush_asset = null
	if host.placement != null and host.placement.brush_asset == previous_asset:
		host.placement.clear_brush()


## Return the regular PNG brush quarter-turn consumed by both Pen and Tile writes.
static func material_layer_rotation_quarters(host: MTSStudioViewport) -> int:
	if host.placement == null or host.material_layer_brush_asset == null:
		return 0
	return MTSStudioViewport.K.normalized_quarters(host.placement.brush_quarters)


## Convert the visible projection enum into the one canonical terrain face it addresses.
static func _splatmap_face_for_projection(projection: int) -> int:
	match projection:
		MaterialBlendProfile.SplatmapProjection.TOP:
			return MTSStudioViewport.K.Face.POS_Y
		MaterialBlendProfile.SplatmapProjection.NORTH:
			return MTSStudioViewport.K.Face.NEG_Z
		MaterialBlendProfile.SplatmapProjection.SOUTH:
			return MTSStudioViewport.K.Face.POS_Z
		MaterialBlendProfile.SplatmapProjection.EAST:
			return MTSStudioViewport.K.Face.POS_X
		MaterialBlendProfile.SplatmapProjection.WEST:
			return MTSStudioViewport.K.Face.NEG_X
	push_error("[Tile Studio] Splatmap projection is outside Top/North/South/East/West.")
	return MTSStudioViewport.K.Face.POS_Y
