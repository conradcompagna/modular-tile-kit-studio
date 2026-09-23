@tool
extends RefCounted

## Process behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Force-clear any drag/held-key state whose real OS input is no longer
## pressed, so a missed release event (mouse button released outside this
## control, focus lost mid-drag to a popup/dialog, Alt-Tab while WASD panning)
## cannot leave the camera stuck panning forever.
##
## _gui_input only ever SETS these flags on press and clears them on the
## matching release, and that release event can be lost -- Godot's mouse
## capture/gui-input routing does not guarantee a Control still receives a
## button-up that occurred after the pointer left it, or while another window
## had focus. Reading Input's live button/key state here removes the
## possibility of drift: whatever the flags say, this brings them back into
## agreement with reality at least once per frame, at negligible cost.
static func _clear_stuck_input_state(host: MTSStudioViewport) -> void:
	if host.camera != null and host.camera.is_panning() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		host.camera.end_pan()
	if host._painting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		host._painting = false
	if host._erasing and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		host._erasing = false
	if host._height_sculpting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		host._end_height_sculpt()
	if host._material_painting and (
		not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	):
		host._end_material_paint()
	if host._select_dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		host._end_select_interaction(host._last_mouse, false)
	for keycode in host._keys_down.keys():
		if host._keys_down[keycode] and not Input.is_key_pressed(keycode):
			host._keys_down[keycode] = false


## Apply held sculpt pulses only after the pointer has remained down deliberately.
##
## Mouse-down already applies the first stamp synchronously. The separate initial
## delay keeps a normal click at exactly one stamp, while the shorter repeat
## interval makes an intentional hold feel continuous and independent of frame rate.
static func _advance_height_sculpt_hold(host: MTSStudioViewport, delta: float) -> void:
	if not host._height_sculpting or host._terrain_sculptor == null:
		return
	var pulse_threshold := (
		MTSStudioViewport.HEIGHT_SCULPT_REPEAT_SECONDS
		if host._height_hold_repeating
		else MTSStudioViewport.HEIGHT_SCULPT_HOLD_DELAY_SECONDS
	)
	host._height_repeat_elapsed_seconds = minf(
		host._height_repeat_elapsed_seconds + delta,
		pulse_threshold + MTSStudioViewport.HEIGHT_SCULPT_REPEAT_SECONDS
	)
	if host._height_repeat_elapsed_seconds < pulse_threshold:
		return
	host._height_repeat_elapsed_seconds -= pulse_threshold
	host._height_hold_repeating = true
	if host._last_height_stamp_xz.x == INF:
		return
	host._terrain_sculptor.begin_pulse()
	host._apply_height_sculpt_stamp(host._last_height_stamp_xz)
	var cell := Vector2i(floori(host._last_height_stamp_xz.x), floori(host._last_height_stamp_xz.y))
	host._draw_height_brush_preview({
		"xz": host._last_height_stamp_xz,
		"cell": Vector3i(cell.x, 0, cell.y),
		"point": Vector3(
			host._last_height_stamp_xz.x,
			host.board.terrain.sample_world_height(host._last_height_stamp_xz, 0.0),
			host._last_height_stamp_xz.y
		),
	})


## Advance live sculpt previews and camera navigation once per frame.
static func _process(host: MTSStudioViewport, delta: float) -> void:
	host._flush_pending_material_paint()
	if host.surface_material_paint != null and host.surface_material_paint.upload_dirty() > 0:
		host.request_render()
	if host.camera == null:
		return
	var active_visual_input := (
		host.camera.is_panning()
		or host._painting
		or host._erasing
		or host._height_sculpting
		or host._select_dragging
	)
	host._clear_stuck_input_state()
	host._flush_pending_height_sculpt_motion()
	host._advance_height_sculpt_hold(delta)

	var moved: bool = false
	if host.camera.is_rotatable_isometric():
		if host._keys_down.get(KEY_Q, false):
			host.camera.rotate_isometric(true, delta)
			moved = true
		if host._keys_down.get(KEY_E, false):
			host.camera.rotate_isometric(false, delta)
			moved = true

	var ground_direction := Vector2.ZERO
	if host._keys_down.get(KEY_D, false):
		ground_direction.x += 1.0
	if host._keys_down.get(KEY_A, false):
		ground_direction.x -= 1.0
	if host._keys_down.get(KEY_W, false):
		ground_direction.y += 1.0
	if host._keys_down.get(KEY_S, false):
		ground_direction.y -= 1.0
	if ground_direction != Vector2.ZERO:
		host.camera.pan_ground(ground_direction.normalized(), delta)
		moved = true

	# Integrate held zoom as a small logarithmic rate, matching the continuous
	# cadence of orbit and pan. A full button-sized factor per frame made a held
	# key traverse the entire zoom range almost instantly.
	var zoom_rate: float = 0.0
	if Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_PLUS) or Input.is_key_pressed(KEY_KP_ADD):
		zoom_rate = -MTSStudioViewport.K.ISO_ZOOM_RATE_PER_SECOND
	elif Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT):
		zoom_rate = MTSStudioViewport.K.ISO_ZOOM_RATE_PER_SECOND
	if not is_zero_approx(zoom_rate):
		host.camera.zoom_by_factor(exp(zoom_rate * delta))
		moved = true

	if active_visual_input or moved:
		host.request_render()
