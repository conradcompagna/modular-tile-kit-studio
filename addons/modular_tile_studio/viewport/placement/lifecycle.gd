@tool
extends RefCounted

## Lifecycle behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

static func _ready(host: MTSPlacementController) -> void:
	host._preview_root = Node3D.new()
	host._preview_root.name = "PlacementPreview"
	host.add_child(host._preview_root)

	# The preview is HUD, not scene geometry. It displays the factory-resolved
	# albedo as a ghost overlay, so casting must be switched off explicitly --
	# otherwise the hovering cursor throws a shadow onto the board.
	host._preview_mesh = MeshInstance3D.new()
	host._preview_mesh.name = "PreviewQuad"
	host._preview_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._preview_root.add_child(host._preview_mesh)

	host._preview_surface_outline = MeshInstance3D.new()
	host._preview_surface_outline.name = "PreviewQuadContours"
	host._preview_surface_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._preview_root.add_child(host._preview_surface_outline)

	host._preview_box = MeshInstance3D.new()
	host._preview_box.name = "PreviewBox"
	host._preview_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._preview_root.add_child(host._preview_box)

	host._preview_box_outline = MeshInstance3D.new()
	host._preview_box_outline.name = "PreviewBoxContours"
	host._preview_box_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var outline_material := StandardMaterial3D.new()
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.albedo_color = Color(0.03, 0.04, 0.06, 1.0)
	outline_material.no_depth_test = true
	outline_material.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY + 2
	host._preview_box_outline.material_override = outline_material
	host._preview_root.add_child(host._preview_box_outline)
	host._preview_surface_outline.material_override = outline_material

	# The shared placement preview needs a neutral fill when a material channel,
	# rather than one TileAsset texture, is being painted onto the selected faces.
	host._terrain_tile_preview_material = StandardMaterial3D.new()
	host._terrain_tile_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	host._terrain_tile_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	host._terrain_tile_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	host._terrain_tile_preview_material.no_depth_test = true
	host._terrain_tile_preview_material.render_priority = MTSPlacementController.PREVIEW_RENDER_PRIORITY
	host._terrain_tile_preview_material.albedo_color = Color(0.12, 0.86, 1.0, 0.22)

	# Geometry alone cannot expose every orientation: symmetric props hide their
	# facing, while a PNG quad hides which edge is the authored image top. The
	# arrow is the common explicit orientation readout for both asset types.
	host._preview_arrow = MeshInstance3D.new()
	host._preview_arrow.name = "PreviewFacingArrow"
	host._preview_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._preview_root.add_child(host._preview_arrow)

	host._fill_preview_root = Node3D.new()
	host._fill_preview_root.name = "FillPreview"
	host._preview_root.add_child(host._fill_preview_root)

	host._fill_preview_valid = MultiMeshInstance3D.new()
	host._fill_preview_valid.name = "ValidStamps"
	host._fill_preview_valid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._fill_preview_root.add_child(host._fill_preview_valid)

	host._fill_preview_blocked = MultiMeshInstance3D.new()
	host._fill_preview_blocked.name = "BlockedStamps"
	host._fill_preview_blocked.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._fill_preview_root.add_child(host._fill_preview_blocked)

	host._ensure_texture_fill_preview_nodes()
	host._ensure_fill_preview_guides()

	host._preview_root.visible = false

	# A brush set before this controller entered the tree had nothing to draw
	# into. Now that the nodes exist, build the overlay from that brush state so
	# it is never silently missing.
	if host.has_brush():
		host._rebuild_preview()
