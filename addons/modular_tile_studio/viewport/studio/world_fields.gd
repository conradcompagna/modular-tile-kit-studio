@tool
extends RefCounted

## World fields behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

# --- Board -> scene -------------------------------------------------------

## Return one world XZ rectangle derived from the board's canonical placement bounds.
##
## BoardDocument.compute_bounds() resolves terrain and every placement through one
## canonical result, so field coverage never depends on placement source type.
static func _required_world_surface_field_rect(host: MTSStudioViewport) -> Rect2:
	if host.board == null:
		return Rect2(MTSStudioViewport.WorldSurfaceFields.DEFAULT_ORIGIN, MTSStudioViewport.WorldSurfaceFields.DEFAULT_SIZE)
	return host._required_world_surface_field_rect_for(host.board)


## Calculate exact editable height coverage for one detached or live board document.
static func _required_world_surface_field_rect_for(host: MTSStudioViewport, source_board: BoardDocument) -> Rect2:
	if source_board == null or source_board.is_empty():
		return Rect2(MTSStudioViewport.WorldSurfaceFields.DEFAULT_ORIGIN, MTSStudioViewport.WorldSurfaceFields.DEFAULT_SIZE)
	var board_bounds := (
		host._board_bounds()
		if source_board == host.board
		else source_board.compute_bounds()
	)
	return host._world_surface_field_rect_for_bounds(board_bounds)


## Convert one authoritative board bound into the editable XZ field rectangle.
static func _world_surface_field_rect_for_bounds(host: MTSStudioViewport, board_bounds: AABB) -> Rect2:
	var board_end := board_bounds.end
	var minimum := Vector2(
		floorf(board_bounds.position.x - MTSStudioViewport.WORLD_HEIGHT_COVERAGE_MARGIN_M),
		floorf(board_bounds.position.z - MTSStudioViewport.WORLD_HEIGHT_COVERAGE_MARGIN_M)
	)
	var maximum := Vector2(
		ceilf(board_end.x + MTSStudioViewport.WORLD_HEIGHT_COVERAGE_MARGIN_M),
		ceilf(board_end.z + MTSStudioViewport.WORLD_HEIGHT_COVERAGE_MARGIN_M)
	)
	return Rect2(minimum, maximum - minimum)


## Initialize a newly bound board's terrain field directly from its canonical world bounds.
static func _reset_world_surface_field_coverage(host: MTSStudioViewport) -> void:
	if host.world_surface_fields == null or host.board == null or host.board.is_empty():
		return
	var required_rect := host._required_world_surface_field_rect()
	host.world_surface_fields.configure(
		required_rect.position,
		required_rect.size,
		host._world_surface_field_resolution(required_rect),
		false
	)


## Return the canonical texture resolution for one visible world-field rectangle.
static func _world_surface_field_resolution(host: MTSStudioViewport, required_rect: Rect2) -> Vector2i:
	return Vector2i(
		ceili(required_rect.size.x * MTSStudioViewport.WORLD_HEIGHT_TEXELS_PER_METER) + 1,
		ceili(required_rect.size.y * MTSStudioViewport.WORLD_HEIGHT_TEXELS_PER_METER) + 1
	)


## Initialize or expand terrain coverage for board mutations while preserving authored sculpt pixels.
static func _ensure_world_surface_field_coverage(host: MTSStudioViewport) -> bool:
	if host.world_surface_fields == null or host.board == null:
		return false
	var required_rect := host._required_world_surface_field_rect()
	if (
		host.world_surface_fields.height_source_image == null
		or host.world_surface_fields.height_source_image.is_empty()
	):
		# The first paint turns an intentionally empty startup board into authored
		# state. Configure that first canonical field directly; expansion requires
		# an existing image and therefore cannot represent this state transition.
		host.world_surface_fields.configure(
			required_rect.position,
			required_rect.size,
			host._world_surface_field_resolution(required_rect),
			false
		)
		return true
	return host.world_surface_fields.ensure_coverage(required_rect)
