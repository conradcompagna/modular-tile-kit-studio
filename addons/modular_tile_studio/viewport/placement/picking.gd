@tool
extends RefCounted

## Picking behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

# --- Picking --------------------------------------------------------------

## Grid cell under the mouse, found by intersecting the active camera ray with
## the current Y layer. This works for both fixed and rotatable orthographic
## isometric views without a second placement representation.
## Pick the current editing plane for surfaces, Fill, and empty-space prop clicks.
## Prop brushes first try structural +Y floors so an elevated platform becomes
## the placement origin without sampling any visual height or relief data.
static func pick_cell(host: MTSPlacementController, camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null:
		return {"hit": false, "cell": Vector3i.ZERO}

	# Terrain is the ground everything is placed on, so it is picked first and
	# unconditionally. There is no competing layer grid: a prop lands where the
	# sculpted surface actually is, and so do sculpt and paint strokes.
	var terrain_hit := host._pick_terrain(camera, mouse_pos)
	if terrain_hit.get("hit", false):
		return terrain_hit

	# Direct PNG brushes have no plane of their own. A miss is a miss, so the
	# cursor cannot invent a paintable quad in empty space.
	if host.brush_is_surface() and host.brush_asset != null:
		return {"hit": false, "cell": Vector3i.ZERO}
	# Prop tools retain their explicit current-layer authoring plane.
	return host._pick_current_layer(camera, mouse_pos)


## Intersect the camera ray with the authored terrain surface.
##
## The march walks the ray forward in world XZ and detects the step where it
## crosses from above the terrain to below it, then refines that step by
## bisection. Sampling the grid's own bilinear surface means picking agrees
## exactly with the rendered mesh and with the gameplay heights, instead of
## introducing a third opinion about where the ground is.
static func _pick_terrain(host: MTSPlacementController, camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null:
		return {"hit": false}
	return host.pick_terrain_from_ray(
		camera.project_ray_origin(mouse_pos),
		camera.project_ray_normal(mouse_pos)
	)


## Intersect one explicit world-space ray with the authored terrain surface.
##
## Delegates to MTSTerrainRenderer.pick_face(), which tests the real displayed
## faces. This replaced a ray-march over sample_world_height(): that function
## reads only the TOP surface, so it could not see a vertical wall at all and a
## prop could never be placed on a wall band. It also gave painting and placement
## two different opinions about where the ground was. There is now exactly one.
##
## Exposed so material painting resolves its brush against the same faces a
## placement lands on.
static func pick_terrain_from_ray(host: MTSPlacementController, origin: Vector3, direction: Vector3) -> Dictionary:
	if host.board == null or host.board.terrain == null or host.board.terrain.is_empty():
		return {"hit": false}
	if direction.length_squared() <= 0.0 or host.terrain_renderer == null:
		return {"hit": false}

	var pick: Dictionary = host.terrain_renderer.pick_face(origin, direction.normalized())
	if pick.is_empty():
		return {"hit": false}
	var face: Dictionary = pick["face"]
	var point: Vector3 = pick["point"]
	if not face.has("grid_cell"):
		push_error("[Tile Studio] picked terrain face has no canonical grid cell.")
		return {"hit": false}
	var grid_cell: Vector3i = face["grid_cell"]
	return {
		"hit": true,
		# A whole terrain face has one stable lattice address. Using the face's
		# canonical minimum corner prevents two clicks on one slope from rounding
		# to different placement layers.
		"cell": grid_cell,
		"point": point,
		"normal": pick["normal"],
		"terrain_face": face,
		"support": null,
		"terrain": true,
	}


## Pick the horizontal plane represented by the current structural editing layer.
static func _pick_current_layer(host: MTSPlacementController, camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(mouse_pos)
	var direction := camera.project_ray_normal(mouse_pos)
	var plane_y := float(host.current_y)

	if absf(direction.y) < 0.0001:
		return {"hit": false, "cell": Vector3i.ZERO}

	var t := (plane_y - origin.y) / direction.y
	if t < 0.0:
		return {"hit": false, "cell": Vector3i.ZERO}

	var point := origin + direction * t
	return {
		"hit": true,
		"cell": Vector3i(
			floori(point.x),
			host.current_y,
			floori(point.z)
		),
		"point": point,
		"support": null,
	}


## Return whether the active brush requires the dedicated edge target primitive.
static func _uses_surface_edge_targeter(host: MTSPlacementController) -> bool:
	return (
		host.brush_surface_edge_mode
		and host.brush_is_surface()
		and host.brush_surface_presentation != SurfacePlacement.Presentation.TERRAIN_PAINT
	)


## Ray-pick a canonical terrain edge without passing through pick_cell().
static func _pick_grid_edge(host: MTSPlacementController, camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	if camera == null or host.terrain_renderer == null:
		return {"hit": false}
	var target := host.terrain_renderer.pick_grid_edge(
		camera.project_ray_origin(mouse_pos),
		camera.project_ray_normal(mouse_pos)
	)
	return target if not target.is_empty() else {"hit": false}
