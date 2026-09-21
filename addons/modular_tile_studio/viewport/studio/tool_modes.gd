@tool
extends RefCounted

## Tool modes behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Switch between painting and erasing.
##
## Erase is a real mode, not only the right-mouse gesture it used to be. Right
## click still erases, and always did -- but an unlabelled gesture is not a
## feature anyone can find, and the tool needs a visible answer to "how do I
## delete this". In erase mode the LEFT button erases too, and drags across
## cells, which is what makes clearing a mistaken sweep practical.
## Select the visible camera mode while keeping the editor's placement tools available.
static func set_camera_mode(host: MTSStudioViewport, camera_mode: int) -> void:
	if host.camera == null:
		push_error("[Tile Studio] Camera mode requested before the viewport camera was created.")
		return
	if host.camera.mode == camera_mode:
		return

	# A camera transition must not retain an unfinished authored shape
	# behind the next pointer event; the selected tool remains active on return.
	host._painting = false
	host._erasing = false
	host._end_height_sculpt()
	if host.placement != null and host.placement.has_fill_vertices():
		host.placement.cancel_fill()
	host.camera.end_pan()
	# Both isometric modes reserve Q/E for the camera, and rotatable mode stores
	# held-key state, so every camera-mode boundary clears any stale key press.
	host._keys_down.clear()
	host.camera.set_camera_mode(camera_mode)

	# Camera changes preserve the current pointer owner and its visible preview.
	host._refresh_placement_visibility()
	host._emit_status()
	host.request_render()


## Recompute whether the placement controller owns a visible targeting preview.
##
## Particle, marker, and circular material modes own the pointer exclusively. Terrain
## drag tools hide ordinary placement ghosts, but Fill must keep this controller visible
## because its path, polygon, candidate outlines, and blocked stamps all live beneath it.
static func _refresh_placement_visibility(host: MTSStudioViewport) -> void:
	if host.placement == null:
		return
	var exclusive_pointer_owner := (
		host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE
		or (host.particle_effects != null and host.particle_effects.active)
		or (host.gameplay_markers != null and host.gameplay_markers.active)
	)
	var terrain_drag_tool_active := (
		host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE
		or host.footprint_tool != MTSStudioViewport.FootprintTool.NONE
	)
	host.placement.visible = (
		not exclusive_pointer_owner
		and (
			not terrain_drag_tool_active
			or host.placement.tool == MTSPlacementController.Tool.FILL
		)
	)


## Switch between painting and erasing while retaining the current camera mode.
static func set_tool(host: MTSStudioViewport, p_tool: int) -> void:
	# Selecting a placement tool deliberately leaves the terrain tool alone. The
	# two are separate authoring choices, and clearing terrain here made Fill
	# unusable with terrain at all: arming Fill switched the terrain tool off, so
	# the pair could never be active together. Pointer precedence in _gui_input()
	# is what decides which one receives a gesture, and the status bar names it.
	host._sync_terrain_fill_arming(p_tool)
	# Delegated rather than duplicated. The controller owns `tool` and changes it
	# from paths this class never sees (picking a brush leaves erase mode), so it
	# is the thing that announces the change; this just forwards the request and
	# lets the signal come back through _on_tool_changed.
	host.placement.set_tool(p_tool)
	# Visibility is derived after the controller owns the new tool, avoiding the
	# stale PAINT state that previously hid terrain Fill's complete preview tree.
	host._refresh_placement_visibility()


## Select the visible open-path or closed-polygon Fill interpretation.
static func set_fill_shape(host: MTSStudioViewport, fill_shape: int) -> void:
	host.placement.set_fill_shape(fill_shape)
	host._emit_status()
	host.request_render()


## Re-announce a tool change and refresh the status line.
##
## The controller is the source of truth, but the toolbar listens to this class,
## so the signal is forwarded rather than having the UI reach past the viewport
## into the controller.
static func _on_tool_changed(host: MTSStudioViewport, tool: int) -> void:
	host.tool_changed.emit(tool)
	host._emit_status()
	host.request_render()


static func is_erasing(host: MTSStudioViewport) -> bool:
	return host.placement.tool == MTSPlacementController.Tool.ERASE


## Show or hide the grid drawn by the terrain's own top-face shader.
static func set_grid_visible(host: MTSStudioViewport, value: bool) -> void:
	host._terrain_top_grid_visible = value
	host._refresh_terrain_grid_visibility()
	host.request_render()


## Show or hide the grid drawn by the terrain's own side-face shader.
static func set_lattice_visible(host: MTSStudioViewport, value: bool) -> void:
	host._terrain_side_grid_visible = value
	host._refresh_terrain_grid_visibility()
	host.request_render()


## Update only live terrain material uniforms when either grid toggle changes.
static func _refresh_terrain_grid_visibility(host: MTSStudioViewport) -> void:
	if host.terrain_renderer == null:
		return
	for material: ShaderMaterial in host.terrain_renderer.terrain_shader_materials():
		material.set_shader_parameter(
			"terrain_show_top_grid",
			host._terrain_top_grid_visible
		)
		material.set_shader_parameter(
			"terrain_show_side_grid",
			host._terrain_side_grid_visible
		)


## Enable the dedicated particle-effect input path and disable competing paint brushes.
static func set_particle_effect_mode(host: MTSStudioViewport, enabled: bool) -> void:
	if host.particle_effects == null:
		return
	if enabled:
		host.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
		host.placement.clear_brush()
		if host.gameplay_markers != null:
			host.gameplay_markers.set_active(false)
	host.particle_effects.set_active(enabled)
	host._refresh_placement_visibility()
	host._painting = false
	host._erasing = false
	host._emit_status()
	host.request_render()


## Store the reusable preset ID used by the particle placement preview and next click.
static func set_particle_effect_preset(host: MTSStudioViewport, preset_id: String) -> void:
	if host.particle_effects == null:
		return
	host.particle_effects.set_preset(preset_id)
	host.particle_effects.update_hover(host.camera, host._last_mouse)
	host.request_render()


## Select how the next placed emitter resolves its height against the terrain.
static func set_particle_effect_attachment(host: MTSStudioViewport, attachment: int) -> void:
	if host.particle_effects == null:
		return
	host.particle_effects.set_attachment(attachment)


## Select the visible particle panel's explicit place or erase operation.
static func set_particle_effect_erase_mode(host: MTSStudioViewport, enabled: bool) -> void:
	if host.particle_effects == null:
		return
	host.particle_effects.set_erase_mode(enabled)
	host.particle_effects.update_hover(host.camera, host._last_mouse)
	host.request_render()


## Enable the dedicated gameplay-marker input path and disable competing paint brushes.
static func set_gameplay_marker_mode(host: MTSStudioViewport, enabled: bool) -> void:
	if host.gameplay_markers == null:
		return
	if enabled:
		host.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
		host.placement.clear_brush()
		if host.particle_effects != null:
			host.particle_effects.set_active(false)
	if host.gameplay_markers_root != null:
		host.gameplay_markers_root.visible = enabled
	host.gameplay_markers.set_active(enabled)
	host._refresh_placement_visibility()
	host._painting = false
	host._erasing = false
	host._emit_status()
	host.request_render()


## Store the exact Gameplay panel fields in the dedicated marker controller.
static func set_gameplay_marker_brush(host: MTSStudioViewport,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
) -> void:
	if host.gameplay_markers == null:
		return
	host.gameplay_markers.set_brush(
		marker_type,
		note,
		monster_id,
		pack_id
	)
	host.gameplay_markers.update_hover(host.camera, host._last_mouse)
	host.request_render()
