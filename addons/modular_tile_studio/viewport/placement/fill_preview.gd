@tool
extends RefCounted

## Fill preview behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

static func _update_fill_preview(host: MTSPlacementController) -> void:
	if host._fill_preview_root == null:
		return
	if host._fill_preview_vertices.is_empty():
		host._clear_fill_preview()
		return

	if host._fill_targets_terrain():
		# Terrain Fill owns no asset and no occupancy volume, so its preview is the
		# outlined cell footprint alone. The guide pass below already draws exactly
		# that from the same origins the commit consumes.
		if host._fill_preview_texture != null:
			host._fill_preview_texture.mesh = null
			host._fill_preview_texture.visible = false
		if host._fill_preview_texture_outline != null:
			host._fill_preview_texture_outline.mesh = null
			host._fill_preview_texture_outline.visible = false
		host._set_fill_preview_batch(host._fill_preview_valid, [], Color.WHITE)
		host._set_fill_preview_batch(host._fill_preview_blocked, [], Color.WHITE)
		host._update_fill_preview_guides()
		host._fill_preview_root.visible = true
		return

	if host.brush_is_surface() and host.brush_asset != null:
		host._set_texture_fill_preview(
			host._fill_preview_texture_placement,
			not host._fill_preview_valid_origins.is_empty()
		)
		host._update_fill_preview_guides()
		host._fill_preview_root.visible = true
		return
	if host._fill_preview_texture != null:
		host._fill_preview_texture.mesh = null
		host._fill_preview_texture.visible = false
	if host._fill_preview_texture_outline != null:
		host._fill_preview_texture_outline.mesh = null
		host._fill_preview_texture_outline.visible = false

	host._set_fill_preview_batch(
		host._fill_preview_valid,
		host._fill_preview_valid_origins,
		Color(0.08, 0.88, 1.0, 0.34)
	)
	host._set_fill_preview_batch(
		host._fill_preview_blocked,
		host._fill_preview_blocked_origins,
		Color(1.0, 0.12, 0.12, 0.42)
	)
	host._update_fill_preview_guides()
	host._fill_preview_root.visible = true


## Set one batch of prop Fill origins.
##
## Direct PNG textures never enter this function; their exact terrain triangles
## are drawn by _set_texture_fill_preview().
static func _set_fill_preview_batch(host: MTSPlacementController,
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
	if host.brush_is_surface():
		push_error("[Tile Studio] direct-texture Fill preview must use heightfield faces.")
		target.multimesh = null
		target.visible = false
		return
	if host.brush_is_prop():
		preview_mesh = (
			MTSPlacementController.ProxyMeshBuilder.collision_preview_meshes(host._brush_prop_preview_voxels())["volume"]
			as Mesh
		)
		preview_material = host._build_prop_fill_preview_material(tint)
	else:
		var box := BoxMesh.new()
		box.size = Vector3(host._brush_prop_canonical_bounds())
		preview_mesh = box
		preview_material = host._build_prop_fill_preview_material(tint)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = preview_mesh
	multimesh.instance_count = origins.size()
	for index in origins.size():
		var instance_transform := Transform3D.IDENTITY
		if host.brush_is_surface():
			instance_transform = MTSPlacementController.surface_transform(
				origins[index],
				host.brush_face,
				host.brush_quarters,
				host.brush_asset
			)
		elif host.brush_is_prop():
			instance_transform.origin = Vector3(origins[index])
		else:
			instance_transform = host._brush_prop_center_transform(origins[index])
		multimesh.set_instance_transform(index, instance_transform)

	target.multimesh = multimesh
	target.material_override = preview_material
	target.visible = true


## Create exact direct-texture Fill preview nodes once, including after live reloads.
static func _ensure_texture_fill_preview_nodes(host: MTSPlacementController) -> void:
	if host._fill_preview_root == null:
		return
	if host._fill_preview_texture == null:
		host._fill_preview_texture = MeshInstance3D.new()
		host._fill_preview_texture.name = "TextureFaces"
		host._fill_preview_texture.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host._fill_preview_root.add_child(host._fill_preview_texture)
	if host._fill_preview_texture_outline == null:
		host._fill_preview_texture_outline = MeshInstance3D.new()
		host._fill_preview_texture_outline.name = "TextureFaceContours"
		host._fill_preview_texture_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var outline_material := StandardMaterial3D.new()
		outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		outline_material.albedo_color = Color(0.03, 0.04, 0.06, 1.0)
		outline_material.no_depth_test = true
		outline_material.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY + 2
		host._fill_preview_texture_outline.material_override = outline_material
		host._fill_preview_root.add_child(host._fill_preview_texture_outline)


## Draw the merged direct-texture Fill on its exact top or side heightfield faces.
static func _set_texture_fill_preview(host: MTSPlacementController, placement: SurfacePlacement, is_valid: bool) -> void:
	host._ensure_texture_fill_preview_nodes()
	host._fill_preview_valid.multimesh = null
	host._fill_preview_blocked.multimesh = null
	host._fill_preview_valid.visible = false
	host._fill_preview_blocked.visible = false
	if (
		placement == null
		or placement.terrain_face_uids.is_empty()
		or host.terrain_renderer == null
	):
		host._fill_preview_texture.mesh = null
		host._fill_preview_texture_outline.mesh = null
		host._fill_preview_texture.visible = false
		host._fill_preview_texture_outline.visible = false
		return
	var preview_geometry := host.terrain_renderer.surface_preview_meshes(
		placement,
		host.brush_asset
	)
	host._fill_preview_texture.mesh = preview_geometry.get("mesh", null) as Mesh
	host._fill_preview_texture_outline.mesh = preview_geometry.get("outline", null) as Mesh
	var tint := Color(0.08, 0.88, 1.0, 0.55) if is_valid else Color(1.0, 0.12, 0.12, 0.62)
	host._fill_preview_texture.material_override = host._build_surface_brush_material(tint)
	host._fill_preview_texture.visible = host._fill_preview_texture.mesh != null
	host._fill_preview_texture_outline.visible = host._fill_preview_texture_outline.mesh != null


## Create the Fill guide overlay once, including after a live script reload.
##
## Editor tool scripts can reload without re-running _ready() on their existing
## controller, so this idempotent owner keeps the new preview available immediately.
static func _ensure_fill_preview_guides(host: MTSPlacementController) -> void:
	if host._fill_preview_guides != null or host._fill_preview_root == null:
		return
	# The guide mesh gives every stamp a crisp footprint boundary and keeps the
	# clicked point sequence legible independently of the selected asset texture.
	host._fill_preview_guides = MeshInstance3D.new()
	host._fill_preview_guides.name = "StampOutlinesAndPath"
	host._fill_preview_guides.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var guide_material := StandardMaterial3D.new()
	guide_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	guide_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	guide_material.vertex_color_use_as_albedo = true
	guide_material.no_depth_test = true
	guide_material.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY + 1
	host._fill_preview_guides.material_override = guide_material
	host._fill_preview_root.add_child(host._fill_preview_guides)


## Rebuild occupancy outlines plus the clicked point path above the Fill result.
##
## Direct textures use exact terrain contours; this guide mesh keeps the clicked
## path and non-texture occupancy stamps distinct.
static func _update_fill_preview_guides(host: MTSPlacementController) -> void:
	host._ensure_fill_preview_guides()
	if host._fill_preview_guides == null:
		return
	if host._fill_preview_origins.is_empty():
		host._fill_preview_guides.mesh = null
		host._fill_preview_guides.visible = false
		return

	var guides := ImmediateMesh.new()
	guides.surface_begin(Mesh.PRIMITIVE_LINES)
	# Direct textures already expose exact terrain-triangle contours; the old
	# planar stamp boxes are retained only for slots and prop occupancy previews.
	if not (host.brush_is_surface() and host.brush_asset != null) or host._fill_targets_terrain():
		for origin: Vector3i in host._fill_preview_valid_origins:
			host._add_fill_stamp_outline(guides, origin, Color(0.1, 1.0, 0.95, 0.95))
		for origin: Vector3i in host._fill_preview_blocked_origins:
			host._add_fill_stamp_outline(guides, origin, Color(1.0, 0.15, 0.15, 0.98))
	host._add_fill_control_path(guides)
	guides.surface_end()
	host._fill_preview_guides.mesh = guides
	host._fill_preview_guides.visible = true


## Add the real oriented footprint boundary for one pending Fill stamp.
static func _add_fill_stamp_outline(host: MTSPlacementController,
	guides: ImmediateMesh,
	origin: Vector3i,
	color: Color
) -> void:
	if host._fill_targets_terrain():
		# One flat square per stamp, drawn on the ground plane at the exact cell
		# footprint the Brush width implies. Height follows the live terrain so the
		# outline reads on sculpted ground instead of floating at a fixed level.
		var stamp := host._fill_stamp_size()
		# TerrainSculptor.brush_cell_targets() CENTRES its square on the anchor
		# cell, so the outline has to start from the same lower corner or a wide
		# brush would preview one cell away from the cells it actually edits.
		var lower_offset := float((stamp.x - 1) / 2)
		var base := Vector2(
			float(origin.x) - lower_offset,
			float(origin.z) - lower_offset
		)
		var terrain: TerrainMesh = host.board.terrain if host.board != null else null
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
			host._add_fill_guide_line(
				guides,
				outline[corner_index],
				outline[(corner_index + 1) % outline.size()],
				color
			)
		return

	if host.brush_is_surface():
		var stamp_transform := MTSPlacementController.surface_transform(
			origin,
			host.brush_face,
			host.brush_quarters,
			host.brush_asset
		)
		var footprint := host._brush_surface_footprint()
		var half_width := float(footprint.x) * 0.5
		var half_height := float(footprint.y) * 0.5
		var separation := Vector3(MTSPlacementController.K.face_normal(host.brush_face)) * 0.035
		var corners: Array[Vector3] = [
			stamp_transform * Vector3(-half_width, -half_height, 0.0) + separation,
			stamp_transform * Vector3(half_width, -half_height, 0.0) + separation,
			stamp_transform * Vector3(half_width, half_height, 0.0) + separation,
			stamp_transform * Vector3(-half_width, half_height, 0.0) + separation,
		]
		for corner_index in corners.size():
			host._add_fill_guide_line(
				guides,
				corners[corner_index],
				corners[(corner_index + 1) % corners.size()],
				color
			)
		return

	if host.brush_is_prop():
		var prop_preview := host._prop_placement_for_origin(origin)
		var prop_world_origin := host._prop_preview_world_origin(prop_preview)
		var voxel_edges: Array[Vector2i] = [
			Vector2i(0, 1), Vector2i(1, 3), Vector2i(3, 2), Vector2i(2, 0),
			Vector2i(4, 5), Vector2i(5, 7), Vector2i(7, 6), Vector2i(6, 4),
			Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
		]
		for voxel: Vector3i in host._brush_prop_preview_voxels():
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
				host._add_fill_guide_line(
					guides,
					voxel_corners[voxel_edge.x],
					voxel_corners[voxel_edge.y],
					color
				)
		return

	var canonical_bounds := Vector3(host._brush_prop_canonical_bounds())
	var transform := host._brush_prop_transform_for_origin(origin)
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
		host._add_fill_guide_line(guides, corners[edge.x], corners[edge.y], color)


## Add clicked point markers and connect them in the selected Path or Polygon order.
static func _add_fill_control_path(host: MTSPlacementController, guides: ImmediateMesh) -> void:
	if host._fill_preview_vertices.is_empty():
		return

	var axes := host._fill_plane_axes()
	var axis_u := Vector3(axes[0]) * 0.28
	var axis_v := Vector3(axes[1]) * 0.28
	var point_color := Color(1.0, 0.8, 0.08, 1.0)
	var path_color := Color(1.0, 0.62, 0.05, 0.95)
	for vertex: Vector3i in host._fill_preview_vertices:
		var centre := host._fill_stamp_centre(vertex)
		host._add_fill_guide_line(guides, centre - axis_u, centre + axis_u, point_color)
		host._add_fill_guide_line(guides, centre - axis_v, centre + axis_v, point_color)

	for index in range(1, host._fill_preview_vertices.size()):
		host._add_fill_guide_line(
			guides,
			host._fill_stamp_centre(host._fill_preview_vertices[index - 1]),
			host._fill_stamp_centre(host._fill_preview_vertices[index]),
			path_color
		)
	if host.fill_shape == MTSPlacementController.FillShape.POLYGON and host._fill_preview_vertices.size() >= 3:
		host._add_fill_guide_line(
			guides,
			host._fill_stamp_centre(host._fill_preview_vertices[-1]),
			host._fill_stamp_centre(host._fill_preview_vertices[0]),
			path_color
		)


## Return the visible centre used to connect one clicked Fill origin.
static func _fill_stamp_centre(host: MTSPlacementController, origin: Vector3i) -> Vector3:
	if host.brush_is_surface():
		return (
			MTSPlacementController.surface_transform(
				origin,
				host.brush_face,
				host.brush_quarters,
				host.brush_asset
			).origin
			+ Vector3(MTSPlacementController.K.face_normal(host.brush_face)) * 0.055
		)
	if host.brush_is_prop():
		var collision_bounds := host._brush_prop_preview_bounds()
		var prop_preview := host._prop_placement_for_origin(origin)
		return (
			host._prop_preview_world_origin(prop_preview)
			+ collision_bounds.position
			+ collision_bounds.size * 0.5
		)
	return host._brush_prop_center_transform(origin).origin


## Append one colored line segment to the dynamic Fill guide mesh.
static func _add_fill_guide_line(host: MTSPlacementController,
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
static func _build_prop_fill_preview_material(host: MTSPlacementController, tint: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY
	mat.albedo_color = tint
	return mat


## Build a translucent surface preview from the active brush asset.
static func _build_surface_brush_material(host: MTSPlacementController, tint: Color) -> Material:
	return host._build_surface_preview_material(host.brush_asset, tint)


## Build a two-sided orientation ghost of the selected surface art.
##
## The preview receives the factory-resolved visible albedo, so source/analyzed
## blending and cutout alpha match the committed material. Its dedicated
## unshaded shader keeps the authored front bright and darkens the back by a
## fixed factor; the cue therefore remains explicit while board lighting changes.
static func _build_surface_preview_material(host: MTSPlacementController, asset: TileAsset, tint: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = MTSPlacementController.SURFACE_PREVIEW_SHADER
	mat.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY

	var albedo: Texture2D = null
	if host.material_factory != null:
		albedo = host.material_factory.get_visible_albedo(asset)
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
static func _clear_fill_preview(host: MTSPlacementController) -> void:
	if host._fill_preview_valid == null or host._fill_preview_blocked == null:
		return
	host._fill_preview_texture_placement = null
	host._fill_preview_valid.multimesh = null
	host._fill_preview_blocked.multimesh = null
	host._fill_preview_valid.visible = false
	host._fill_preview_blocked.visible = false
	if host._fill_preview_texture != null:
		host._fill_preview_texture.mesh = null
		host._fill_preview_texture.visible = false
	if host._fill_preview_texture_outline != null:
		host._fill_preview_texture_outline.mesh = null
		host._fill_preview_texture_outline.visible = false
	if host._fill_preview_guides != null:
		host._fill_preview_guides.mesh = null
		host._fill_preview_guides.visible = false
	host._fill_preview_root.visible = false
