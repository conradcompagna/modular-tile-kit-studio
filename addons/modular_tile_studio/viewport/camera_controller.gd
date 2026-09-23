@tool
class_name MTSCameraController
extends Camera3D

## Four-direction fixed isometric, rotatable isometric, and top-down editor cameras.
##
## All modes use the same orthographic projection, target, and zoom. The two
## isometric modes orbit a fixed-height offset, while top-down points directly
## at the target and keeps the same camera path for predictable editing.

const K := preload("../utils/mts_constants.gd")

signal view_changed()

## The active camera behavior. The toolbar exposes all values directly.
enum Mode { ISOMETRIC, ROTATABLE_ISOMETRIC, TOP_DOWN }

## Rotation speed matches the level-builder reference's deliberate keyboard orbit.
const ROTATABLE_ISO_YAW_RADIANS_PER_SECOND: float = K.ISO_ROTATABLE_YAW_RADIANS_PER_SECOND

## Fixed isometric exposes the four quarter-turn views around the same authored target.
const FIXED_ISOMETRIC_DIRECTION_COUNT: int = 4

## Each fixed-isometric direction changes only yaw and preserves the canonical pitch.
const FIXED_ISOMETRIC_DIRECTION_STEP_RADIANS: float = TAU / float(FIXED_ISOMETRIC_DIRECTION_COUNT)

## Point every camera angle looks at. Panning moves this shared target.
var target: Vector3 = Vector3.ZERO:
	set(value):
		target = value
		if is_inside_tree():
			_apply_view()

## The shared orthographic view height used by every camera mode.
var ortho_size: float = K.ISO_DEFAULT_ORTHO_SIZE:
	set(value):
		ortho_size = clampf(value, K.ISO_MIN_ORTHO_SIZE, K.ISO_MAX_ORTHO_SIZE)
		if is_inside_tree():
			_apply_view()

## The selected camera behavior is transient editor state and never enters a BoardDocument.
var mode: int = Mode.ISOMETRIC

var pan_speed: float = 12.0

## The orbit is measured from the canonical game-camera offset around world up.
var _orbit_yaw_radians: float = 0.0

## Direction zero is the original +X/+Z fixed view; the other values are exact quarter-turns.
var _fixed_isometric_direction_index: int = 0
var _panning: bool = false


## Initialize the clip planes and apply the canonical game-view transform.
func _ready() -> void:
	near = K.CAMERA_NEAR
	far = K.CAMERA_FAR
	_apply_view()


## Select a visible camera mode without changing the authored board.
func set_camera_mode(next_mode: int) -> void:
	var requested_mode: int = clampi(next_mode, Mode.ISOMETRIC, Mode.TOP_DOWN)
	if mode == requested_mode:
		return
	mode = requested_mode
	# Entering the alternate view always starts at the canonical game angle, so
	# the user can predict exactly where the first Q/E rotation begins.
	if is_rotatable_isometric():
		_orbit_yaw_radians = 0.0
	if is_inside_tree():
		_apply_view()


## Return whether this camera is currently presenting a snapped fixed-isometric direction.
func is_isometric() -> bool:
	return mode == Mode.ISOMETRIC


## Return whether this camera is currently in the rotatable isometric editor view.
func is_rotatable_isometric() -> bool:
	return mode == Mode.ROTATABLE_ISOMETRIC


## Return whether this camera is currently in the direct top-down editor view.
func is_top_down() -> bool:
	return mode == Mode.TOP_DOWN


## Apply the shared orthographic projection and the selected camera angle.
func _apply_view() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = ortho_size
	if is_top_down():
		# World -Z is the stable screen-up direction for the plan view; using it
		# avoids the singular look-at orientation caused by world up being parallel
		# to a camera that points directly downward.
		global_position = target + Vector3.UP * K.ISO_CAMERA_DISTANCE
		look_at(target, Vector3.FORWARD)
	else:
		var orbit_angle: float = _orbit_yaw_radians
		if is_isometric():
			orbit_angle = float(_fixed_isometric_direction_index) * FIXED_ISOMETRIC_DIRECTION_STEP_RADIANS
		var offset_direction: Vector3 = K.ISO_CAMERA_DIRECTION.normalized().rotated(Vector3.UP, orbit_angle)
		global_position = target + offset_direction * K.ISO_CAMERA_DISTANCE
		# The target is the one canonical placement reference; only the camera's
		# offset rotates, so the board never receives a hidden coordinate correction.
		look_at(target, Vector3.UP)
	view_changed.emit()


## Step fixed isometric by one exact quarter-turn without changing its pitch or framing.
func step_fixed_isometric_direction(left: bool) -> void:
	if not is_isometric():
		return
	var direction: int = -1 if left else 1
	_fixed_isometric_direction_index = wrapi(
		_fixed_isometric_direction_index + direction,
		0,
		FIXED_ISOMETRIC_DIRECTION_COUNT
	)
	_apply_view()


## Return the zero-based fixed direction for visible UI state and deterministic tests.
func get_fixed_isometric_direction_index() -> int:
	return _fixed_isometric_direction_index


## Describe the camera's exact world-space corner without imposing a compass convention.
func get_fixed_isometric_direction_label() -> String:
	match _fixed_isometric_direction_index:
		1:
			return "+X -Z"
		2:
			return "-X -Z"
		3:
			return "-X +Z"
		_:
			return "+X +Z"


## Rotate the orthographic camera around the shared target while holding its RPG tilt constant.
func rotate_isometric(left: bool, delta: float) -> void:
	if not is_rotatable_isometric():
		return
	var direction: float = -1.0 if left else 1.0
	_orbit_yaw_radians += direction * ROTATABLE_ISO_YAW_RADIANS_PER_SECOND * delta
	_apply_view()


## Pan in the visible screen plane so dragging slides the map beneath any camera view.
func pan_screen(delta_px: Vector2) -> void:
	var world_per_px: float = (ortho_size * 2.0) / maxf(1.0, float(get_viewport().size.y))
	var right: Vector3 = global_transform.basis.x
	var up: Vector3 = global_transform.basis.y
	target -= right * delta_px.x * world_per_px
	target += up * delta_px.y * world_per_px


## Pan along the ground plane for keyboard movement in the current camera orientation.
func pan_ground(direction: Vector2, delta: float) -> void:
	if direction == Vector2.ZERO:
		return
	var right: Vector3 = global_transform.basis.x
	var forward: Vector3 = global_transform.basis.y if is_top_down() else -global_transform.basis.z
	# Flatten onto the ground plane so panning never changes height.
	right.y = 0.0
	forward.y = 0.0
	right = right.normalized()
	forward = forward.normalized()
	# direction.y is +1 for W, so it must ADD forward motion: W moves the view
	# toward the top of the current map view.
	var speed: float = pan_speed * (ortho_size / K.ISO_DEFAULT_ORTHO_SIZE)
	target += (right * direction.x + forward * direction.y) * speed * delta


## Decrease the shared orthographic view height to zoom the active camera view in.
func zoom_in() -> void:
	zoom_by_factor(K.ISO_ZOOM_IN_FACTOR)


## Increase the shared orthographic view height to zoom the active camera view out.
func zoom_out() -> void:
	zoom_by_factor(K.ISO_ZOOM_OUT_FACTOR)


## Apply one multiplicative zoom step so held-key zoom remains smooth and frame-rate independent.
func zoom_by_factor(factor: float) -> void:
	ortho_size *= factor


## Frame an authored bound by updating the one shared target and orthographic zoom.
func frame_aabb(bounds: AABB, margin: float = 1.4) -> void:
	target = bounds.get_center()
	# Fit the box's diagonal so nothing clips regardless of the board's shape.
	var extent: float = maxf(bounds.size.length() * 0.5, 1.0)
	ortho_size = clampf(extent * margin, K.ISO_MIN_ORTHO_SIZE, K.ISO_MAX_ORTHO_SIZE)


## Frame an authored point using the one shared target and orthographic zoom.
func frame_point(point: Vector3, size_hint: float = 6.0) -> void:
	target = point
	ortho_size = clampf(size_hint, K.ISO_MIN_ORTHO_SIZE, K.ISO_MAX_ORTHO_SIZE)


## Start middle-button map panning in any camera view.
func begin_pan() -> void:
	_panning = true


## End middle-button map panning even if the mouse release arrived outside the viewport.
func end_pan() -> void:
	_panning = false


## Return whether the map is currently being panned.
func is_panning() -> bool:
	return _panning
