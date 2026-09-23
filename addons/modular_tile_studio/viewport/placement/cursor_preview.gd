@tool
extends RefCounted

## Cursor preview behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

# --- Preview --------------------------------------------------------------


## Ensure cursor footprint contours exist after live editor script reloads.
##
## Existing @tool controller instances do not rerun _ready() when new preview
## members are introduced, so this idempotent owner creates only missing nodes.
static func _ensure_cursor_preview_outlines(host: MTSPlacementController) -> void:
	if host._preview_root == null:
		return

	var outline_material: StandardMaterial3D = null
	if is_instance_valid(host._preview_surface_outline):
		outline_material = host._preview_surface_outline.material_override as StandardMaterial3D
	elif is_instance_valid(host._preview_box_outline):
		outline_material = host._preview_box_outline.material_override as StandardMaterial3D
	if outline_material == null:
		outline_material = StandardMaterial3D.new()
		outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		outline_material.albedo_color = Color(0.03, 0.04, 0.06, 1.0)
		outline_material.no_depth_test = true
		outline_material.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY + 2

	if not is_instance_valid(host._preview_surface_outline):
		host._preview_surface_outline = MeshInstance3D.new()
		host._preview_surface_outline.name = "PreviewQuadContours"
		host._preview_surface_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host._preview_root.add_child(host._preview_surface_outline)
	host._preview_surface_outline.material_override = outline_material

	if not is_instance_valid(host._preview_box_outline):
		host._preview_box_outline = MeshInstance3D.new()
		host._preview_box_outline.name = "PreviewBoxContours"
		host._preview_box_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host._preview_root.add_child(host._preview_box_outline)
	host._preview_box_outline.material_override = outline_material


## Refresh the existing brush preview after its canonical board slot data changes.
##
## This deliberately preserves Tool.SELECT; rebuilding display state must never
## reissue a brush-selection command or change which input mode owns the viewport.
static func refresh_brush_preview(host: MTSPlacementController) -> void:
	host._rebuild_preview()


## Rebuild the existing preview nodes from the currently active brush source.
static func _rebuild_preview(host: MTSPlacementController) -> void:
	# The preview nodes are built in _ready(), but the brush can be set before
	# this controller enters the tree. _ready() rebuilds it once nodes exist.
	if host._preview_root == null:
		return
	host._ensure_cursor_preview_outlines()
	if not host.has_brush():
		host._preview_root.visible = false
		return

	if host.brush_is_surface():
		host._preview_box.visible = false
		host._preview_box_outline.visible = false
		host._preview_arrow.visible = true
		host._preview_mesh.visible = true
		host._preview_surface_outline.visible = true
		# A surface brush always has an asset, and its preview is the terrain geometry
		# resolved in _position_preview() once the current face hit is known. There is
		# no quad standing in for the surface any more.
		host._preview_mesh.mesh = null
		host._preview_surface_outline.mesh = null
		host._preview_mesh.material_override = host._build_surface_brush_material(
			Color(1, 1, 1, 0.55)
		)

		host._preview_arrow.mesh = host._build_surface_up_arrow()
		var surface_arrow_mat := StandardMaterial3D.new()
		surface_arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		surface_arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		surface_arrow_mat.no_depth_test = true
		surface_arrow_mat.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY + 1
		surface_arrow_mat.albedo_color = Color(0.05, 0.95, 1.0)
		host._preview_arrow.material_override = surface_arrow_mat
	else:
		host._preview_mesh.visible = false
		host._preview_surface_outline.visible = false
		host._preview_box.visible = true
		host._preview_box_outline.visible = true
		if host.brush_is_prop():
			var preview_voxels := host._brush_prop_preview_voxels()
			var collision_preview := MTSPlacementController.ProxyMeshBuilder.collision_preview_meshes(preview_voxels)
			host._preview_box.mesh = collision_preview["volume"] as Mesh
			host._preview_box_outline.mesh = collision_preview["contours"] as Mesh
		else:
			var box := BoxMesh.new()
			var canonical_bounds := host._brush_prop_canonical_bounds()
			box.size = Vector3(canonical_bounds)
			host._preview_box.mesh = box
			host._preview_box_outline.mesh = MTSPlacementController.ProxyMeshBuilder.box_outline_mesh(
				Vector3(canonical_bounds)
			)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var color := host._brush_color()
		mat.albedo_color = Color(color.r, color.g, color.b, 0.30)
		mat.no_depth_test = true
		mat.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY
		host._preview_box.material_override = mat

		host._preview_arrow.visible = true
		host._preview_arrow.mesh = host._build_facing_arrow()
		var arrow_mat := StandardMaterial3D.new()
		arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		arrow_mat.no_depth_test = true
		arrow_mat.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY + 1
		arrow_mat.albedo_color = Color(1.0, 0.85, 0.15)
		host._preview_arrow.material_override = arrow_mat

	host._position_preview()


## Position the active preview using the same minimum-corner and face transforms as placement.
static func _position_preview(host: MTSPlacementController) -> void:
	if not host.has_brush() and not host.terrain_splat_paint_enabled:
		return
	if host._preview_root == null:
		return
	host._ensure_cursor_preview_outlines()
	if (
		host._preview_mesh == null
		or host._preview_box == null
		or host._preview_arrow == null
	):
		return
	if host.terrain_splat_paint_enabled:
		if host.tool == MTSPlacementController.Tool.FILL:
			return
		# Material Tile and RGBA Tile paint carry only the canonical face addresses;
		# the same renderer geometry route used by base-coat placement draws them.
		var preview_placement := SurfacePlacement.new()
		preview_placement.origin = host.hovered_cell
		preview_placement.face = host._terrain_splat_face
		preview_placement.terrain_face_uids = host.terrain_material_target_uids(
			host.hovered_cell,
			host._terrain_splat_face
		)
		var preview_geometry := host.terrain_renderer.surface_preview_meshes(
			preview_placement,
			host.brush_asset if host._terrain_splat_uses_surface_brush else null
		) if host.terrain_renderer != null else {}
		host._preview_mesh.mesh = preview_geometry.get("mesh", null) as Mesh
		host._preview_surface_outline.mesh = preview_geometry.get("outline", null) as Mesh
		host._preview_mesh.transform = Transform3D.IDENTITY
		host._preview_surface_outline.transform = Transform3D.IDENTITY
		if host._terrain_splat_uses_surface_brush and host.brush_is_surface():
			preview_placement.asset_id = host.brush_asset.asset_id
			preview_placement.rotation_quarters = host.brush_quarters
			host._preview_mesh.material_override = host._build_surface_brush_material(
				Color(1, 1, 1, 0.55) if host.hover_valid else Color(1, 0.25, 0.25, 0.55)
			)
			host._preview_arrow.visible = true
			host._preview_arrow.transform = MTSPlacementController.surface_transform(
				host.hovered_cell,
				host._terrain_splat_face,
				host.brush_quarters,
				host.brush_asset,
				SurfacePlacement.GridAnchor.CELL
			)
		else:
			host._preview_mesh.material_override = host._terrain_tile_preview_material
			host._terrain_tile_preview_material.albedo_color = (
				Color(0.12, 0.86, 1.0, 0.22)
				if host.hover_valid
				else Color(1.0, 0.2, 0.2, 0.3)
			)
			host._preview_arrow.visible = false
		return
	if host.brush_is_surface():
		# Terrain paint previews the exact faces it will cover, copied from the
		# canonical terrain records, so the preview cannot describe a flat proxy
		# quad that the committed paint would never produce.
		var preview_placement := host._surface_placement_for_origin(host.hovered_cell)
		var preview_geometry := host.terrain_renderer.surface_preview_meshes(
			preview_placement,
			host.brush_asset
		) if host.terrain_renderer != null else {}
		host._preview_mesh.mesh = preview_geometry.get("mesh", null) as Mesh
		host._preview_surface_outline.mesh = preview_geometry.get("outline", null) as Mesh
		host._preview_mesh.transform = Transform3D.IDENTITY
		host._preview_surface_outline.transform = Transform3D.IDENTITY
		# The conformed face mesh shows which faces are covered but not which way
		# the image runs across them, so the arrow is the readout for the authored
		# quarter turn. It draws with no_depth_test as a HUD overlay, so sitting on
		# the placement's own plane rather than the slope cannot hide it.
		host._preview_arrow.visible = true
		host._preview_arrow.transform = MTSPlacementController.surface_transform(
			host.hovered_cell,
			host.brush_face,
			host.brush_quarters,
			host.brush_asset,
			host._surface_grid_anchor
		)
		var shader_preview := host._preview_mesh.material_override as ShaderMaterial
		if shader_preview != null:
			var preview_tint := (
				Color(1, 1, 1, 0.55) if host.hover_valid else Color(1, 0.25, 0.25, 0.55)
			)
			if not bool(shader_preview.get_shader_parameter("has_albedo")):
				preview_tint = Color(0.95, 0.15, 0.65, 0.55)
			shader_preview.set_shader_parameter("preview_tint", preview_tint)
	else:
		var preview_centre := Vector3.ZERO
		var preview_height := 0.0
		if host.brush_is_prop():
			# The voxel mesh keeps the canonical oriented offsets. The preview uses
			# the same derived floor or wall contact offset as committed art,
			# collision, and proxy geometry.
			var collision_bounds := host._brush_prop_preview_bounds()
			var preview_placement := host._prop_placement_for_origin(host.hovered_cell)
			var preview_origin := host._prop_preview_world_origin(preview_placement)
			var collision_transform := Transform3D(
				Basis.IDENTITY,
				preview_origin
			)
			host._preview_box.transform = collision_transform
			host._preview_box_outline.transform = collision_transform
			preview_centre = (
				preview_origin
				+ collision_bounds.position
				+ collision_bounds.size * 0.5
			)
			preview_height = collision_bounds.size.y
		else:
			# Surfaced boxes retain their rigid 90-degree box transform because
			# their collision is the complete authored box rather than sparse voxels.
			var canonical_bounds := host._brush_prop_canonical_bounds()
			var corner_transform := host._brush_prop_transform_for_origin(host.hovered_cell)
			var local_centre := Vector3(canonical_bounds) * 0.5
			host._preview_box.transform = Transform3D(
				corner_transform.basis,
				corner_transform * local_centre
			)
			host._preview_box_outline.transform = corner_transform
			preview_centre = corner_transform * local_centre
			preview_height = float(host._brush_box().y)
		var mat := host._preview_box.material_override as StandardMaterial3D
		if mat != null:
			var color := host._brush_color() if host.hover_valid else Color(1.0, 0.25, 0.25)
			mat.albedo_color = Color(color.r, color.g, color.b, 0.30 if host.hover_valid else 0.35)

		host._preview_arrow.transform = Transform3D(
			MTSPlacementController.K.prop_orientation_basis(
				host._resolved_prop_forward_face(),
				host.brush_prop_roll_quarters,
				host._resolved_prop_yaw_eighths() if host.brush_is_prop() else 0
			),
			preview_centre + Vector3(0.0, preview_height * 0.5 + 0.05, 0.0)
		)
		var arrow_mat := host._preview_arrow.material_override as StandardMaterial3D
		if arrow_mat != null:
			arrow_mat.albedo_color = Color(1.0, 0.85, 0.15) if host.hover_valid else Color(1.0, 0.35, 0.3)


## Build the PNG orientation arrow in the authored local XY plane.
##
## The tip points along local +Y, which is the top of the source image. A small
## local +Z separation keeps the HUD arrow above the preview without changing
## the placement transform shared by preview, collision, and committed art.
static func _build_surface_up_arrow(host: MTSPlacementController) -> ArrayMesh:
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
static func _build_facing_arrow(host: MTSPlacementController) -> ArrayMesh:
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
