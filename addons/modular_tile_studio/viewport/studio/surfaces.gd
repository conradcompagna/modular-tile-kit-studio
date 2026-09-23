@tool
extends RefCounted

## Surfaces behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Build one placement-owned node while canonical terrain supplies painted geometry.
##
## Terrain paint is material state on the heightfield and therefore contributes
## no mesh, decal, or collider of its own. This node exists purely so selection,
## slice visibility, and bounds have one record per placement to read.
static func _build_surface_node(host: MTSStudioViewport,
	surface: SurfacePlacement,
	asset: TileAsset
) -> Node3D:
	var root := Node3D.new()
	root.name = "Surface_%s" % surface.asset_id
	root.position = Vector3(surface.origin)

	# Only a native Decal owns a node of its own. A shader decal is an ordinary
	# placement-local layer on the receiving terrain material, so it contributes no
	# child here for the same reason ordinary terrain paint does not.
	if surface.is_decal():
		var local_transform := SurfacePlacement.transform_for_size(
			surface.origin,
			surface.face,
			surface.rotation_quarters,
			surface.canonical_footprint(asset),
			surface.grid_anchor
		)
		local_transform.origin -= root.position
		var decal := host._build_decal_node(surface, asset, local_transform)
		if decal != null:
			root.add_child(decal)

	root.set_meta("mts_placement", surface)
	root.set_meta("mts_spatial_signature", host._placement_spatial_signature(surface))
	root.set_meta("mts_layer_y", surface.origin.y)
	root.set_meta("mts_bounds", host._surface_bounds(surface, asset))
	return root


## Return the projection depth one native decal needs to reach its real receivers.
##
## A Decal affects only fragments INSIDE its box. A fixed thin slab therefore works
## on perfectly flat ground and nowhere else: the moment the surface slopes or
## steps, it leaves the slab and the stamp is clipped away, which reads as the
## decal refusing to follow the terrain.
##
## The depth is derived from how far the placement's OWN receiver faces actually
## depart from its plane, so it is exactly as deep as the relief under it and no
## deeper. The box stays centred on the plane, so it is sized to twice the larger
## departure plus a margin, covering both directions without being re-centred.
##
## Bleed-through stays bounded for the same reason: depth never exceeds the relief
## genuinely beneath the stamp, and normal_fade still rejects the far side of a
## wall, whose surface faces away from the projection axis.
static func _decal_projection_depth_m(host: MTSStudioViewport,
	surface: SurfacePlacement,
	local_surface_transform: Transform3D,
	outward_normal: Vector3
) -> float:
	# Enough to absorb float error and the shallow relief of an almost-flat cell.
	const MINIMUM_DEPTH_M := 0.25
	# Terrain relief can be arbitrarily tall; past this a projector stops being a
	# stamp and starts painting unrelated geometry, so it is reported and clamped.
	const MAXIMUM_DEPTH_M := 32.0
	const MARGIN_M := 0.1
	if host.terrain_renderer == null:
		return MINIMUM_DEPTH_M
	# The node's local frame is the world frame less the placement root offset, and
	# the surface root sits at the placement origin, so the world plane point is
	# recovered by adding it back.
	var world_plane_point := local_surface_transform.origin + Vector3(surface.origin)
	var extent := host.terrain_renderer.receiver_extent_along_axis(
		surface.terrain_face_uids,
		world_plane_point,
		outward_normal
	)
	if extent.is_empty():
		return MINIMUM_DEPTH_M
	var reach := maxf(
		absf(float(extent["minimum"])),
		absf(float(extent["maximum"]))
	)
	var depth := reach * 2.0 + MARGIN_M
	if depth > MAXIMUM_DEPTH_M:
		push_warning(
			"[Tile Studio] decal '%s' spans %.2f m of relief; clamping its projection to %.1f m."
			% [surface.asset_id, reach * 2.0, MAXIMUM_DEPTH_M]
		)
		return MAXIMUM_DEPTH_M
	return maxf(depth, MINIMUM_DEPTH_M)


## Build one Godot-native Decal from the saved surface transform and PBR map set.
##
## Surface placement uses local XY with +Z outward, while Decal uses local XZ
## and projects along -Y. Reordering those same basis axes preserves image-right
## and image-up without changing the placement root's exact authored origin.
static func _build_decal_node(host: MTSStudioViewport,
	surface: SurfacePlacement,
	asset: TileAsset,
	local_surface_transform: Transform3D
) -> Decal:
	if host.material_factory == null:
		push_error("[Tile Studio] Cannot build decal '%s' without a material factory." % surface.asset_id)
		return null
	if asset == null:
		push_error("[Tile Studio] Cannot build decal for a missing surface asset.")
		return null

	var surface_basis := local_surface_transform.basis.orthonormalized()
	var outward_normal := surface_basis.z
	var projector_basis := Basis(
		surface_basis.x,
		outward_normal,
		-surface_basis.y
	)
	var footprint := surface.canonical_footprint(asset)
	var decal := Decal.new()
	decal.name = "Projection"
	decal.size = Vector3(
		float(footprint.x),
		host._decal_projection_depth_m(surface, local_surface_transform, outward_normal),
		float(footprint.y)
	)
	decal.transform = Transform3D(projector_basis, local_surface_transform.origin)
	if not host._configure_native_decal(decal, surface, asset):
		decal.free()
		return null
	return decal


## Configure one native Decal from the original maps and its optional palette tint.
##
## Palette matching multiplies the node's existing authored tint after material
## configuration, so the albedo texture itself remains full-resolution and untouched.
static func _configure_native_decal(host: MTSStudioViewport,
	decal: Decal,
	surface: SurfacePlacement,
	asset: TileAsset
) -> bool:
	var palette_adjustment: Dictionary = {}
	if surface.match_underlying_palette:
		palette_adjustment = host._native_decal_palette_adjustment(surface)
		if palette_adjustment.is_empty():
			return false
	if not host.material_factory.configure_decal(decal, asset):
		return false
	if not palette_adjustment.is_empty():
		var palette_modulate := palette_adjustment["modulate"] as Color
		decal.modulate = Color(
			decal.modulate.r * palette_modulate.r,
			decal.modulate.g * palette_modulate.g,
			decal.modulate.b * palette_modulate.b,
			decal.modulate.a
		)
	return true


## Return the fixed-cost palette adjustment for one native decal placement.
static func _native_decal_palette_adjustment(host: MTSStudioViewport, surface: SurfacePlacement) -> Dictionary:
	if surface == null or not surface.match_underlying_palette:
		return {}
	if (
		host.board == null
		or host.library == null
		or host.material_factory == null
		or host._surface_palette_matcher_script == null
	):
		push_error("[Tile Studio] Native decal palette matching is missing required render data.")
		return {}
	return host._surface_palette_matcher_script.call(
		"native_adjustment",
		surface,
		host.board,
		host.library,
		host.material_factory,
		host.surface_material_paint
	) as Dictionary


## Return the affine palette adjustment for one direct shader-decal layer.
##
## Only small color statistics are analyzed; the GPU still samples every original
## source texture at its imported resolution without creating a processed copy.
static func _shader_decal_palette_adjustment(host: MTSStudioViewport, surface: SurfacePlacement) -> Dictionary:
	if surface == null or not surface.match_underlying_palette:
		return {}
	if (
		host.board == null
		or host.library == null
		or host.material_factory == null
		or host._surface_palette_matcher_script == null
	):
		push_error("[Tile Studio] Shader decal palette matching is missing required render data.")
		return {}
	return host._surface_palette_matcher_script.call(
		"shader_adjustment",
		surface,
		host.board,
		host.library,
		host.material_factory,
		host.surface_material_paint
	) as Dictionary
