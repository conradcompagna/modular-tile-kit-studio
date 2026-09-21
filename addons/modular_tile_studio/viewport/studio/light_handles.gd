@tool
extends RefCounted

## Light handles behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Show or remove transient surface anchors without changing any authored light value.
static func set_light_handles_visible(host: MTSStudioViewport, visible: bool) -> void:
	if not visible and host._light_drag_mode != MTSStudioViewport.LocalLightDragMode.NONE:
		host._finish_light_handle_drag()
	if not visible:
		host._local_light_placement_pending = false
	host._light_handles_visible = visible
	if host.light_handles_root == null:
		return
	host.light_handles_root.visible = visible
	if visible:
		host._sync_light_handles_from_profile()
	else:
		host._clear_light_handles()
	host.request_render()


## Enter a one-click mode that creates the next light on actual level geometry.
static func begin_local_light_placement(host: MTSStudioViewport) -> void:
	if not host._light_handles_visible or host.board == null:
		push_error("[Tile Studio] Open Lighting before placing a local light.")
		return
	if host.board.lighting.lights.size() >= LightingProfile.MAX_LIGHTS:
		host.status_changed.emit(
			"This rig supports at most %d local lights." % LightingProfile.MAX_LIGHTS
		)
		return
	if host._light_drag_mode != MTSStudioViewport.LocalLightDragMode.NONE:
		host._finish_light_handle_drag()
	host._local_light_placement_pending = true
	host.status_changed.emit(
		"Click authored terrain geometry to anchor the new light; right-click cancels."
	)


## Select one authored local light and update only its temporary handle appearance.
static func select_local_light_handle(host: MTSStudioViewport, index: int) -> void:
	var light_count: int = host.board.lighting.lights.size() if host.board != null else 0
	host._selected_light_handle = clampi(index, 0, light_count - 1) if light_count > 0 else -1
	host._refresh_light_handle_appearance()
	host.request_render()


## Synchronize every temporary handle from the exact profile anchor, height, colour, and enabled state.
static func _sync_light_handles_from_profile(host: MTSStudioViewport) -> void:
	if not host._light_handles_visible or host.light_handles_root == null or host.board == null:
		return
	var lights: Array[Dictionary] = host.board.lighting.lights
	if host._light_handle_nodes.size() != lights.size():
		host._clear_light_handles()
		for light_index: int in lights.size():
			host._light_handle_nodes.append(host._create_light_handle(light_index))
	for light_index: int in lights.size():
		host._update_light_handle_transform(light_index)
	host._refresh_light_handle_appearance()
	host.request_render()


## Build one x-ray surface anchor, emitter glob, and visible height stem.
static func _create_light_handle(host: MTSStudioViewport, light_index: int) -> Node3D:
	var handle := Node3D.new()
	handle.name = "LocalLightHandle_%d" % light_index
	handle.set_meta(MTSStudioViewport.LIGHT_INDEX_META, light_index)
	host.light_handles_root.add_child(handle)

	var surface_mesh := SphereMesh.new()
	surface_mesh.radius = MTSStudioViewport.LIGHT_SURFACE_ANCHOR_RADIUS_M
	surface_mesh.height = MTSStudioViewport.LIGHT_SURFACE_ANCHOR_RADIUS_M * 2.0
	surface_mesh.radial_segments = 12
	surface_mesh.rings = 6
	var surface_anchor := MeshInstance3D.new()
	surface_anchor.name = "SurfaceAnchor"
	surface_anchor.mesh = surface_mesh
	surface_anchor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface_anchor.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(surface_anchor)

	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = MTSStudioViewport.LIGHT_STEM_RADIUS_M
	stem_mesh.bottom_radius = MTSStudioViewport.LIGHT_STEM_RADIUS_M
	stem_mesh.height = 0.01
	stem_mesh.radial_segments = 8
	var stem := MeshInstance3D.new()
	stem.name = "HeightStem"
	stem.mesh = stem_mesh
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stem.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(stem)

	var core_mesh := SphereMesh.new()
	core_mesh.radius = MTSStudioViewport.LIGHT_HANDLE_RADIUS_M
	core_mesh.height = MTSStudioViewport.LIGHT_HANDLE_RADIUS_M * 2.0
	core_mesh.radial_segments = 16
	core_mesh.rings = 8
	var core := MeshInstance3D.new()
	core.name = "Core"
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	handle.add_child(core)

	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = MTSStudioViewport.LIGHT_HANDLE_RADIUS_M * 1.55
	halo_mesh.height = MTSStudioViewport.LIGHT_HANDLE_RADIUS_M * 3.1
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
static func _update_light_handle_transform(host: MTSStudioViewport, light_index: int) -> void:
	if host.board == null or light_index < 0 or light_index >= host.board.lighting.lights.size():
		return
	if light_index >= host._light_handle_nodes.size():
		return
	var entry: Dictionary = host.board.lighting.lights[light_index]
	var surface_position: Vector3 = entry.get("surface_position", Vector3.ZERO)
	var height_offset := host._authored_light_height_offset(light_index)
	var emitter_local := Vector3.UP * height_offset
	var handle: Node3D = host._light_handle_nodes[light_index]
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
static func _refresh_light_handle_appearance(host: MTSStudioViewport) -> void:
	if host.board == null:
		return
	var lights: Array[Dictionary] = host.board.lighting.lights
	for light_index: int in mini(lights.size(), host._light_handle_nodes.size()):
		var entry: Dictionary = lights[light_index]
		var color: Color = entry.get("color", Color.WHITE)
		var enabled: bool = bool(entry.get("enabled", true))
		var selected: bool = light_index == host._selected_light_handle
		var handle: Node3D = host._light_handle_nodes[light_index]
		handle.scale = Vector3.ONE
		var core := handle.get_node_or_null("Core") as MeshInstance3D
		var halo := handle.get_node_or_null("Halo") as MeshInstance3D
		var surface_anchor := handle.get_node_or_null("SurfaceAnchor") as MeshInstance3D
		var stem := handle.get_node_or_null("HeightStem") as MeshInstance3D
		if core != null:
			core.scale = Vector3.ONE * (1.25 if selected else 1.0)
			core.material_override = host._make_light_handle_material(
				color,
				0.95 if enabled else 0.45,
				2.8 if enabled else 0.6
			)
		if halo != null:
			halo.scale = Vector3.ONE * (1.25 if selected else 1.0)
			var halo_color := Color(1.0, 0.82, 0.22) if selected else color
			halo.material_override = host._make_light_handle_material(
				halo_color,
				0.42 if selected else 0.16,
				1.8 if selected else 0.8
			)
		if surface_anchor != null:
			surface_anchor.visible = selected
			surface_anchor.material_override = host._make_light_handle_material(
				Color(1.0, 0.82, 0.22),
				0.9,
				1.5
			)
		var height_color := Color(0.18, 0.88, 1.0)
		if stem != null:
			stem.visible = selected and host._authored_light_height_offset(light_index) > 0.01
			stem.material_override = host._make_light_handle_material(height_color, 0.75, 1.3)


## Create an unshaded no-depth material so an editor handle cannot disappear inside level art.
static func _make_light_handle_material(host: MTSStudioViewport,
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
static func _clear_light_handles(host: MTSStudioViewport) -> void:
	if host.light_handles_root == null:
		host._light_handle_nodes.clear()
		return
	for child: Node in host.light_handles_root.get_children():
		host.light_handles_root.remove_child(child)
		child.queue_free()
	host._light_handle_nodes.clear()
