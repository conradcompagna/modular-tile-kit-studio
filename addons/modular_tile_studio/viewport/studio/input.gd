@tool
extends RefCounted

## Input behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

# --- Input ----------------------------------------------------------------

## Route editor input to camera navigation, modular placement, or the selected paint/sculpt tool.
static func _gui_input(host: MTSStudioViewport, event: InputEvent) -> void:
	if host._movement_grid_active and host._handle_movement_grid_input(event):
		host.accept_event()
		return
	if host._handle_light_handle_input(event):
		host.accept_event()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		host._last_mouse = motion.position
		host._material_pointer_pressure = motion.pressure if motion.pressure > 0.0 else 1.0
		host._material_pointer_inverted = motion.pen_inverted
		if host.camera.is_panning():
			host.camera.pan_screen(motion.relative)
		elif host.particle_effects != null and host.particle_effects.active:
			host.particle_effects.update_hover(host.camera, motion.position)
		elif host.gameplay_markers != null and host.gameplay_markers.active:
			host.gameplay_markers.update_hover(host.camera, motion.position)
		elif host._select_dragging:
			host._continue_select_interaction(motion.position)
		elif host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
			if host._material_painting:
				host._continue_material_paint(
					motion.position,
					motion.pressure,
					motion.pen_inverted
				)
			else:
				host._update_material_brush_preview(motion.position)
		elif (
			host.placement.tool == MTSPlacementController.Tool.FILL
			and (
				host.placement.terrain_fill_enabled
				or host.placement.terrain_splat_paint_enabled
			)
		):
			# Mirrors the button handler: under Fill the pointer is defining a
			# shape, so it feeds the Fill hover rather than sculpting directly.
			host.placement.update_hover(host.camera, motion.position)
		elif host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
			host._queue_height_sculpt_motion(motion.position)
		elif host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
			host._continue_footprint_stroke(motion.position)
		else:
			host.placement.update_hover(host.camera, motion.position)
			if host._painting:
				host.placement.paint_at_hover()
			elif host._erasing:
				host.placement.erase_at_hover()
		host.accept_event()

	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		host._last_mouse = button.position
		match button.button_index:
			MOUSE_BUTTON_MIDDLE:
				if button.pressed:
					host.camera.begin_pan()
				else:
					host.camera.end_pan()
				host.accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					host.camera.zoom_in()
				host.accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					host.camera.zoom_out()
				host.accept_event()
			MOUSE_BUTTON_LEFT:
				host.grab_focus()
				if host.particle_effects != null and host.particle_effects.active:
					host.particle_effects.update_hover(host.camera, button.position)
					if button.pressed:
						if host.particle_effects.erase_mode:
							host.particle_effects.erase_at_hover()
						else:
							host.particle_effects.place_at_hover()
					host.accept_event()
					return
				if host.gameplay_markers != null and host.gameplay_markers.active:
					host.gameplay_markers.update_hover(host.camera, button.position)
					if button.pressed:
						host.gameplay_markers.place_at_hover()
					host.accept_event()
					return
				if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
					if button.pressed:
						var material_hit := host._update_material_brush_preview(button.position)
						host._begin_material_paint(
							button.position,
							host._material_pointer_pressure,
							host._material_pointer_inverted,
							material_hit
						)
					else:
						host._end_material_paint()
					host.accept_event()
					return
				# Fill outranks the terrain drag tools. Arming Fill is an explicit
				# statement that the next clicks define a shape rather than paint
				# one, so a terrain tool under Fill collects vertices and commits
				# on Enter instead of sculpting directly under the cursor.
				if (
					host.placement.tool == MTSPlacementController.Tool.FILL
					and (
						host.placement.terrain_fill_enabled
						or host.placement.terrain_splat_paint_enabled
					)
				):
					host.placement.update_hover(host.camera, button.position)
					if button.pressed:
						if host.placement.add_fill_vertex_at_hover():
							host._emit_status()
						host.request_render()
					host.accept_event()
					return
				if host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
					if button.pressed:
						host._begin_height_sculpt(button.position)
					else:
						host._end_height_sculpt()
					host.accept_event()
					return
				if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
					if button.pressed:
						host._begin_footprint_stroke(
							button.position,
							host.footprint_tool == MTSStudioViewport.FootprintTool.ERASE
						)
					else:
						host._end_footprint_stroke()
					host.accept_event()
					return
				if host.placement.tool == MTSPlacementController.Tool.SELECT:
					var additive_selection := button.shift_pressed or button.ctrl_pressed
					if button.pressed:
						host._begin_select_interaction(button.position, additive_selection)
					else:
						host._end_select_interaction(button.position, additive_selection)
					host.accept_event()
					return
				host.placement.update_hover(host.camera, button.position)
				if button.pressed:
					if host.placement.tool == MTSPlacementController.Tool.FILL:
						host._painting = false
						host._erasing = false
						if host.placement.add_fill_vertex_at_hover():
							host._emit_status()
						host.request_render()
					elif host.placement.tool == MTSPlacementController.Tool.ERASE:
						# Erase always drags. Unlike painting there is no
						# prop/surface distinction to make: removing is removing,
						# and sweeping away a bad stroke is the reason the mode
						# exists.
						host._erasing = true
						if (
							host.placement.terrain_splat_paint_enabled
							and not host._begin_terrain_material_tile_stroke()
						):
							host._erasing = false
						else:
							host.placement.erase_at_hover()
					elif host.placement.has_brush() or host.placement.terrain_splat_paint_enabled:
						# Drag-painting is a SURFACE affordance: sweeping a floor
						# brush across cells is the whole point. Both material tile modes use
						# this exact base-coat path and differ only in the RGBA values written.
						host._painting = (
							host.placement.terrain_splat_paint_enabled
							or (
								host.placement.brush_is_surface()
								and host.placement.brush_surface_presentation
								== SurfacePlacement.Presentation.TERRAIN_PAINT
							)
						)
						if (
							host.placement.terrain_splat_paint_enabled
							and not host._begin_terrain_material_tile_stroke()
						):
							host._painting = false
						else:
							host.placement.paint_at_hover()
					else:
						host.placement.select_at_hover()
				else:
					var finished_surface_drag := host._painting or host._erasing
					host._painting = false
					host._erasing = false
					if finished_surface_drag and host.placement.terrain_splat_paint_enabled:
						host._end_terrain_material_tile_stroke()
				host.accept_event()
			MOUSE_BUTTON_RIGHT:
				if host.particle_effects != null and host.particle_effects.active:
					host.particle_effects.update_hover(host.camera, button.position)
					if button.pressed:
						host.particle_effects.erase_at_hover()
					host.accept_event()
					return
				if host.gameplay_markers != null and host.gameplay_markers.active:
					host.gameplay_markers.update_hover(host.camera, button.position)
					if button.pressed:
						host.gameplay_markers.erase_at_hover()
					host.accept_event()
					return
				if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
					if button.pressed:
						var material_hit := host._update_material_brush_preview(button.position)
						host._begin_material_paint(
							button.position,
							1.0,
							true,
							material_hit
						)
					else:
						host._end_material_paint()
					host.accept_event()
					return
				if host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
					host.accept_event()
					return
				if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
					# Right-drag always erases while the footprint tool is active,
					# so cutting an L out of a drawn rectangle needs no mode switch.
					if button.pressed:
						host._begin_footprint_stroke(button.position, true)
					else:
						host._end_footprint_stroke()
					host.accept_event()
					return
				if host.placement.tool == MTSPlacementController.Tool.SELECT:
					if button.pressed:
						host.placement.clear_selection()
					host.accept_event()
					return
				host.placement.update_hover(host.camera, button.position)
				if host.placement.tool == MTSPlacementController.Tool.FILL:
					if button.pressed and host.placement.remove_last_fill_vertex():
						host._emit_status()
						host.request_render()
					host._erasing = false
				elif button.pressed:
					host._erasing = true
					if (
						host.placement.terrain_splat_paint_enabled
						and not host._begin_terrain_material_tile_stroke()
					):
						host._erasing = false
					else:
						host.placement.erase_at_hover()
				else:
					var finished_tile_erase := host._erasing and host.placement.terrain_splat_paint_enabled
					host._erasing = false
					if finished_tile_erase:
						host._end_terrain_material_tile_stroke()
				host.accept_event()

	elif event is InputEventKey:
		host._handle_key(event as InputEventKey)


static func _handle_key(host: MTSStudioViewport, key: InputEventKey) -> void:
	# Lighting owns vertical arrows contextually while its handles are visible;
	# this keeps map dragging and height editing as two unambiguous operations.
	if (
		key.pressed
		and host._light_handles_visible
		and host._selected_light_handle >= 0
		and key.keycode in [KEY_UP, KEY_DOWN]
	):
		host._nudge_selected_light_height(1 if key.keycode == KEY_UP else -1)
		host.accept_event()
		return

	# Fixed Isometric reserves Q/E for one exact quarter-turn per press. Releases
	# are consumed too, so E cannot leak through to the authoring-tool shortcut.
	if host.camera != null and host.camera.is_isometric() and key.keycode in [KEY_Q, KEY_E]:
		if key.pressed and not key.echo:
			host.camera.step_fixed_isometric_direction(key.keycode == KEY_Q)
			host._emit_status()
		host.accept_event()
		return

	# Rotatable Isometric reserves held Q/E for continuous camera orbit; all other
	# gestures continue through the existing keyboard and mouse routes.
	if host.camera != null and host.camera.is_rotatable_isometric() and key.keycode in [KEY_Q, KEY_E]:
		host._keys_down[key.keycode] = key.pressed
		host.accept_event()
		return

	# Held zoom is integrated in _process so one press does not require repeated taps.
	if key.pressed and key.keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_MINUS, KEY_KP_SUBTRACT]:
		host.accept_event()
		return

	if key.pressed and not key.echo:
		match key.keycode:
			KEY_E:
				# Toggle, not a one-way switch: the same key that reaches for
				# the eraser puts it back down, so erasing a stray tile mid-sweep
				# costs two taps and never leaves the user stuck in a mode.
				host.set_tool(
					MTSPlacementController.Tool.PAINT if host.is_erasing()
					else MTSPlacementController.Tool.ERASE
				)
				host.accept_event()
			KEY_B:
				host.set_tool(MTSPlacementController.Tool.PAINT)
				host.accept_event()
			KEY_V:
				# V is unused by camera navigation, unlike S which remains reserved
				# for ground panning while the viewport has focus.
				host.set_tool(MTSPlacementController.Tool.SELECT)
				host.accept_event()
			KEY_G:
				host.set_tool(
					MTSPlacementController.Tool.PAINT
					if host.placement.tool == MTSPlacementController.Tool.FILL
					else MTSPlacementController.Tool.FILL
				)
				host.accept_event()
			KEY_ENTER, KEY_KP_ENTER:
				if host.placement.tool == MTSPlacementController.Tool.FILL:
					host.placement.commit_fill()
					host._emit_status()
					host.request_render()
					host.accept_event()
			KEY_BACKSPACE:
				if host.placement.tool == MTSPlacementController.Tool.FILL:
					if host.placement.remove_last_fill_vertex():
						host._emit_status()
						host.request_render()
					host.accept_event()
			KEY_ESCAPE:
				if host.placement.tool == MTSPlacementController.Tool.SELECT:
					# Escape cancels the transient selection interaction and clears the
					# canonical selection that produces the visible bounding boxes.
					host._select_dragging = false
					host._select_drag_target = null
					host._select_drag_has_start_cell = false
					host.placement.clear_selection()
					host._emit_status()
					host.request_render()
				elif (
					host.placement.tool == MTSPlacementController.Tool.FILL
					and host.placement.has_fill_vertices()
				):
					host.placement.cancel_fill()
					host._emit_status()
					host.request_render()
				else:
					host.placement.clear_brush()
				host.accept_event()
			KEY_F:
				if (
					host.placement.tool == MTSPlacementController.Tool.SELECT
					and key.shift_pressed
				):
					# Flip commits through the same selected-orientation validator as
					# arrow rotation; plain F retains its existing framing behavior.
					host.placement.flip_selection()
					host._emit_status()
					host.request_render()
				else:
					host._frame_selection()
				host.accept_event()
			KEY_HOME:
				host.frame_board()
				host.accept_event()
			# Direct face selection. Building a stair step means switching a floor
			# brush onto a vertical face and back constantly; hunting for it with
			# arrow-key rotation is far too slow.
			KEY_1:
				host._set_brush_face(MTSStudioViewport.K.Face.POS_Y)
				host.accept_event()
			KEY_2:
				host._set_brush_face(MTSStudioViewport.K.Face.NEG_Y)
				host.accept_event()
			KEY_3:
				host._set_brush_face(MTSStudioViewport.K.Face.POS_X)
				host.accept_event()
			KEY_4:
				host._set_brush_face(MTSStudioViewport.K.Face.NEG_X)
				host.accept_event()
			KEY_5:
				host._set_brush_face(MTSStudioViewport.K.Face.POS_Z)
				host.accept_event()
			KEY_6:
				host._set_brush_face(MTSStudioViewport.K.Face.NEG_Z)
				host.accept_event()
			KEY_DELETE:
				host.placement.delete_selection()
				host.accept_event()
			KEY_LEFT:
				# Shift swaps the rotation axis to world Z (spec 14).
				host._rotate_selection_or_brush(MTSStudioViewport.K.DIR_SOUTH if key.shift_pressed else MTSStudioViewport.K.DIR_UP, true)
				host.accept_event()
			KEY_RIGHT:
				host._rotate_selection_or_brush(MTSStudioViewport.K.DIR_SOUTH if key.shift_pressed else MTSStudioViewport.K.DIR_UP, false)
				host.accept_event()
			KEY_UP:
				host._rotate_selection_or_brush(MTSStudioViewport.K.DIR_EAST, true)
				host.accept_event()
			KEY_DOWN:
				host._rotate_selection_or_brush(MTSStudioViewport.K.DIR_EAST, false)
				host.accept_event()

	if key.keycode in [KEY_W, KEY_A, KEY_S, KEY_D]:
		host._keys_down[key.keycode] = key.pressed
		host.accept_event()


## Adjust only the selected light's height offset as one mergeable undo action.
static func _nudge_selected_light_height(host: MTSStudioViewport, direction: int) -> void:
	if (
		host.board == null
		or host._selected_light_handle < 0
		or host._selected_light_handle >= host.board.lighting.lights.size()
	):
		return
	var light_index := host._selected_light_handle
	var surface_position := host._authored_light_surface_position(light_index)
	var before_height := host._authored_light_height_offset(light_index)
	var after_height := clampf(
		snappedf(
			before_height + signi(direction) * MTSStudioViewport.LIGHT_HEIGHT_KEY_STEP_M,
			0.01
		),
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)
	if is_equal_approx(before_height, after_height):
		return
	if host._height_undo_redo == null:
		host._apply_authored_light_transform(light_index, surface_position, after_height)
	else:
		host._height_undo_redo.create_action(
			"Adjust local light height: %s" % host._light_name(light_index),
			UndoRedo.MERGE_ENDS,
			host
		)
		host._height_undo_redo.add_do_method(
			host,
			"_apply_authored_light_transform",
			light_index,
			surface_position,
			after_height
		)
		host._height_undo_redo.add_undo_method(
			host,
			"_apply_authored_light_transform",
			light_index,
			surface_position,
			before_height
		)
		host._height_undo_redo.commit_action()
	host.status_changed.emit(
		"Height for '%s': %.2f m." % [host._light_name(light_index), after_height]
	)


## Route the existing arrow-key orientation gesture to the active editable state.
static func _rotate_selection_or_brush(host: MTSStudioViewport, axis: Vector3i, positive: bool) -> void:
	if host.placement.tool == MTSPlacementController.Tool.SELECT:
		host.placement.rotate_selection(axis, positive)
	else:
		host.placement.rotate_brush(axis, positive)
	host._emit_status()
	host.request_render()


## Point the active surface brush straight at a face without stepping through rotations.
static func _set_brush_face(host: MTSStudioViewport, face: int) -> void:
	if not host.placement.brush_is_surface():
		return
	host.placement.set_brush_face(face)
	host.placement.update_hover(host.camera, host._last_mouse)
	host._emit_status()
