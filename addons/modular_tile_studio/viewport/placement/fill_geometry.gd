@tool
extends RefCounted

## Fill geometry behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Pick on the plane locked by the first Fill point.
##
## Surface brushes use their actual face plane, floor props use XZ, and wall-slot
## props use the plane implied by their explicit forward face and support setting.
static func _pick_fill_cell(host: MTSPlacementController, camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null:
		return {"hit": false, "cell": Vector3i.ZERO}
	if host.fill_vertices.is_empty():
		return host.pick_cell(camera, mouse_pos)

	var anchor := host.fill_vertices[0]
	var normal := Vector3(MTSPlacementController.K.face_normal(host._fill_face()))
	var plane_point := host._fill_plane_point(anchor)
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_direction := camera.project_ray_normal(mouse_pos)
	var denominator := normal.dot(ray_direction)
	if absf(denominator) < 0.0001:
		return {"hit": false, "cell": Vector3i.ZERO}

	var distance := normal.dot(plane_point - ray_origin) / denominator
	if distance < 0.0:
		return {"hit": false, "cell": Vector3i.ZERO}

	var point := ray_origin + ray_direction * distance
	var cell := anchor
	for axis: Vector3i in host._fill_plane_axes():
		if axis.x != 0:
			cell.x = floori(point.x)
		elif axis.y != 0:
			cell.y = floori(point.y)
		elif axis.z != 0:
			cell.z = floori(point.z)
	return {
		"hit": true,
		"cell": cell,
		"point": point,
		"support": null,
	}


## Return the face whose plane owns Fill coordinates for the active brush.
static func _fill_face(host: MTSPlacementController) -> int:
	if host.terrain_splat_paint_enabled:
		# Directional splat Fill uses the same explicit plane shown by the dropdown.
		return host._terrain_splat_face
	if host.terrain_fill_enabled:
		# Sculpt and footprint Fill remain ground-plane terrain tools.
		return MTSPlacementController.K.Face.POS_Y
	if host.brush_is_surface():
		return host.brush_face
	if host.brush_is_prop() and host._prop_is_wall_supported():
		return host._active_prop_support_face
	if host.brush_is_prop() and host.brush_prop_support == PropPlacement.SUPPORT_WALL:
		return host.brush_prop_forward_face
	return MTSPlacementController.K.Face.POS_Y


## Return one point on the exact placement plane locked by the first Fill point.
##
## Positive surface faces and negative wall-prop facings use different box-side
## conventions; the offsets below mirror their canonical placement transforms.
static func _fill_plane_point(host: MTSPlacementController, anchor: Vector3i) -> Vector3:
	var point := Vector3(anchor)
	if host.brush_is_surface() or host.terrain_splat_paint_enabled:
		var active_face := host._fill_face()
		match active_face:
			MTSPlacementController.K.Face.NEG_Y:
				point.y += 1.0
			MTSPlacementController.K.Face.POS_X:
				point.x += 1.0
			MTSPlacementController.K.Face.POS_Z:
				point.z += 1.0
	elif (
		host.brush_is_prop() and host._prop_is_wall_supported()
	) or (
		host.brush_is_prop() and host.brush_prop_support == PropPlacement.SUPPORT_WALL
	):
		var normal := MTSPlacementController.K.face_normal(host._fill_face())
		var bounds := host._brush_box()
		if normal.x < 0:
			point.x += float(bounds.x)
		elif normal.z < 0:
			point.z += float(bounds.z)
	return point


## Return the two positive lattice axes spanning the active Fill plane.
static func _fill_plane_axes(host: MTSPlacementController) -> Array[Vector3i]:
	var raw_axes := SurfacePlacement.footprint_axes(host._fill_face())
	var axes: Array[Vector3i] = []
	for axis: Vector3i in raw_axes:
		axes.append(axis)
	return axes


## Return the explicit grid step along the active Fill plane axes.
##
## Direct textures use the toolbar metre width, while props use their oriented
## occupancy box.
static func _fill_stamp_size(host: MTSPlacementController) -> Vector2i:
	if host._fill_targets_terrain():
		# The toolbar Brush width IS the terrain brush width, so a filled line is
		# exactly as thick as a dragged stroke of the same width would have been.
		return Vector2i.ONE * host.surface_grid_stroke_size_m
	if host.brush_is_surface() and host.brush_asset != null:
		# Direct textures advance on the toolbar's metre grid; the PNG footprint
		# remains solely responsible for UV repeat scale.
		return Vector2i.ONE * host.surface_grid_stroke_size_m
	if host.brush_is_surface():
		return host._brush_rotated_surface_footprint()

	var axes := host._fill_plane_axes()
	var bounds := host._brush_box()
	return Vector2i(
		maxi(1, host._axis_extent(bounds, axes[0])),
		maxi(1, host._axis_extent(bounds, axes[1]))
	)


## Return a box extent measured along one positive cardinal lattice axis.
static func _axis_extent(host: MTSPlacementController, bounds: Vector3i, axis: Vector3i) -> int:
	return (
		absi(axis.x) * bounds.x
		+ absi(axis.y) * bounds.y
		+ absi(axis.z) * bounds.z
	)


## Project a cell delta onto one cardinal lattice axis.
static func _axis_distance(host: MTSPlacementController, delta: Vector3i, axis: Vector3i) -> int:
	return delta.x * axis.x + delta.y * axis.y + delta.z * axis.z


## Project one world cell onto integer coordinates in the active Fill plane.
static func _cell_to_fill_point(host: MTSPlacementController, cell: Vector3i) -> Vector2i:
	var axes := host._fill_plane_axes()
	return Vector2i(
		host._axis_distance(cell, axes[0]),
		host._axis_distance(cell, axes[1])
	)


## Convert one Fill-plane point back to a world origin on the locked plane.
static func _fill_point_to_cell(host: MTSPlacementController, point: Vector2i, anchor: Vector3i) -> Vector3i:
	var anchor_point := host._cell_to_fill_point(anchor)
	var axes := host._fill_plane_axes()
	return (
		anchor
		+ axes[0] * (point.x - anchor_point.x)
		+ axes[1] * (point.y - anchor_point.y)
	)


## Generate size-aligned origins for a point, line, or closed polygon.
static func _generate_fill_origins(host: MTSPlacementController, vertices: Array[Vector3i]) -> Array[Vector3i]:
	if vertices.is_empty() or not host._fill_is_armed():
		return []
	if vertices.size() == 1:
		return [vertices[0]]
	if host.fill_shape == MTSPlacementController.FillShape.PATH or vertices.size() == 2:
		return host._generate_polyline_origins(vertices)

	var points := host._project_fill_vertices(vertices)
	if host._polygon_twice_area(points) == 0:
		return host._generate_polyline_origins(vertices)
	return host._generate_polygon_origins(points, vertices[0])


## Project every clicked world vertex into the locked two-dimensional Fill plane.
static func _project_fill_vertices(host: MTSPlacementController, vertices: Array[Vector3i]) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	for vertex: Vector3i in vertices:
		points.append(host._cell_to_fill_point(vertex))
	return points


## Generate a Bresenham polyline on the active tool's explicit grid lattice.
##
## Direct textures advance by Grid stroke metres; props advance
## by their complete footprint or oriented occupancy box.
static func _generate_polyline_origins(host: MTSPlacementController, vertices: Array[Vector3i]) -> Array[Vector3i]:
	var points := host._project_fill_vertices(vertices)
	var anchor_point := points[0]
	var stamp_size := host._fill_stamp_size()
	var lattice_points: Array[Vector2i] = []
	for point: Vector2i in points:
		lattice_points.append(Vector2i(
			roundi(float(point.x - anchor_point.x) / float(stamp_size.x)),
			roundi(float(point.y - anchor_point.y) / float(stamp_size.y))
		))

	var origins: Array[Vector3i] = []
	var seen: Dictionary = {}
	for segment_index in lattice_points.size() - 1:
		for lattice_point: Vector2i in host._bresenham_points(
			lattice_points[segment_index],
			lattice_points[segment_index + 1]
		):
			var plane_point := Vector2i(
				anchor_point.x + lattice_point.x * stamp_size.x,
				anchor_point.y + lattice_point.y * stamp_size.y
			)
			var origin := host._fill_point_to_cell(plane_point, vertices[0])
			var key := MTSPlacementController.K.voxel_key(origin)
			if seen.has(key):
				continue
			seen[key] = true
			origins.append(origin)
	return origins


## Return every integer point on one inclusive Bresenham line.
static func _bresenham_points(host: MTSPlacementController, start: Vector2i, finish: Vector2i) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	var current := start
	var delta_x := absi(finish.x - start.x)
	var step_x := 1 if start.x < finish.x else -1
	var delta_y := absi(finish.y - start.y)
	var step_y := 1 if start.y < finish.y else -1
	var error := delta_x - delta_y

	while true:
		points.append(current)
		if current == finish:
			break
		var doubled_error := error * 2
		if doubled_error > -delta_y:
			error -= delta_y
			current.x += step_x
		if doubled_error < delta_x:
			error += delta_x
			current.y += step_y
	return points


## Return twice the signed polygon area without introducing fractional math.
static func _polygon_twice_area(host: MTSPlacementController, points: Array[Vector2i]) -> int:
	var area := 0
	for index in points.size():
		var current := points[index]
		var following := points[(index + 1) % points.size()]
		area += current.x * following.y - following.x * current.y
	return area


## Generate every complete, size-aligned stamp contained by a closed polygon.
static func _generate_polygon_origins(host: MTSPlacementController,
	points: Array[Vector2i],
	anchor: Vector3i
) -> Array[Vector3i]:
	var min_point := points[0]
	var max_point := points[0]
	for point: Vector2i in points:
		min_point.x = mini(min_point.x, point.x)
		min_point.y = mini(min_point.y, point.y)
		max_point.x = maxi(max_point.x, point.x)
		max_point.y = maxi(max_point.y, point.y)

	var anchor_point := points[0]
	var stamp_size := host._fill_stamp_size()
	var min_lattice_x := floori(
		float(min_point.x - anchor_point.x) / float(stamp_size.x)
	)
	var max_lattice_x := ceili(
		float(max_point.x - anchor_point.x) / float(stamp_size.x)
	)
	var min_lattice_y := floori(
		float(min_point.y - anchor_point.y) / float(stamp_size.y)
	)
	var max_lattice_y := ceili(
		float(max_point.y - anchor_point.y) / float(stamp_size.y)
	)
	var origins: Array[Vector3i] = []

	for lattice_y in range(min_lattice_y, max_lattice_y + 1):
		for lattice_x in range(min_lattice_x, max_lattice_x + 1):
			var plane_origin := Vector2i(
				anchor_point.x + lattice_x * stamp_size.x,
				anchor_point.y + lattice_y * stamp_size.y
			)
			if not host._stamp_centre_is_inside_polygon(plane_origin, points):
				continue
			origins.append(host._fill_point_to_cell(plane_origin, anchor))
	return origins


## Return whether one stamp's visible centre lies inside or on the polygon.
##
## Both the yellow control path and every stamp centre receive the same half-stamp
## translation from their stored origins. Testing their origin coordinates is
## therefore the exact same containment test without fractional coordinate drift.
## Centre sampling avoids the unwanted one-footprint erosion that occurs when every
## covered unit cell is required to fit inside the boundary.
static func _stamp_centre_is_inside_polygon(host: MTSPlacementController,
	origin: Vector2i,
	polygon: Array[Vector2i]
) -> bool:
	return host._point_is_in_polygon(Vector2(origin), polygon)


## Test one point against a polygon with an edge-inclusive even-odd rule.
static func _point_is_in_polygon(host: MTSPlacementController, point: Vector2, polygon: Array[Vector2i]) -> bool:
	var inside := false
	var previous_index := polygon.size() - 1
	for index in polygon.size():
		var current := Vector2(polygon[index])
		var previous := Vector2(polygon[previous_index])
		if host._point_is_on_segment(point, previous, current):
			return true
		if (current.y > point.y) != (previous.y > point.y):
			var crossing_x := (
				(previous.x - current.x)
				* (point.y - current.y)
				/ (previous.y - current.y)
				+ current.x
			)
			if point.x < crossing_x:
				inside = not inside
		previous_index = index
	return inside


## Return whether a point lies on one finite line segment within grid precision.
static func _point_is_on_segment(host: MTSPlacementController, point: Vector2, start: Vector2, finish: Vector2) -> bool:
	var segment := finish - start
	var relative := point - start
	if absf(segment.cross(relative)) > 0.0001:
		return false
	var projection := relative.dot(segment)
	return projection >= 0.0 and projection <= segment.length_squared()
