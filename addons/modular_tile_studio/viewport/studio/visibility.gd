@tool
extends RefCounted

## Visibility behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Re-read the brush asset and redraw the painting overlay in place.
##
## The brush holds a live TileAsset reference, so an inspector edit (size, face,
## facing, anchor) changes the data the overlay is built from without the
## controller ever being told. Called by the plugin after any such edit, this is
## what makes a resize or an axis change show up under the cursor immediately
## instead of on the next brush reselect.
static func refresh_brush_preview(host: MTSStudioViewport) -> void:
	if host.placement == null:
		return
	host.placement.refresh_brush()
	# The overlay is only repositioned on mouse motion, so a change made while
	# the cursor is parked over the board would otherwise not move until the
	# user jiggles the mouse. Re-picking under the current cursor redraws it now.
	if host.camera != null and host.is_visible_in_tree():
		host.placement.update_hover(host.camera, host._last_mouse)
	host._emit_status()
	host.request_render()


## Editor-only Y visibility (spec 7). Hides nodes; never deletes data.
## Apply the editor's Y visibility rule to logical surfaces, batched art, and
## real GLB props without deleting any authored placements.
static func _apply_slice(host: MTSStudioViewport) -> void:
	for root: Node3D in [
		host.surfaces_root,
		host.surface_art_root,
		host.props_root,
		host.prop_art_root,
		host.gameplay_markers_root,
		host.particle_effects_root,
	]:
		if root == null:
			continue
		for child in root.get_children():
			var node := child as Node3D
			if node != null:
				host._apply_slice_to_node(node)
	host.request_render()


## Apply the current Y-slice rule to one newly created or existing visual node.
static func _apply_slice_to_node(host: MTSStudioViewport, node: Node3D) -> void:
	var layer: int = node.get_meta("mts_layer_y", 0)
	match host.slice_mode:
		MTSStudioViewport.K.SliceMode.ALL:
			node.visible = true
		MTSStudioViewport.K.SliceMode.CURRENT_AND_BELOW:
			node.visible = layer <= host.current_y
		MTSStudioViewport.K.SliceMode.CURRENT_ONLY:
			node.visible = layer == host.current_y


## Show the selected collision or movement diagnostic over live board artwork.
static func set_occupancy_mode(host: MTSStudioViewport, p_mode: int) -> void:
	if host.occupancy_overlay == null:
		return
	host.occupancy_overlay.set_mode(p_mode)

	if host.surfaces_root != null:
		host.surfaces_root.visible = true
	if host.surface_art_root != null:
		host.surface_art_root.visible = true
	if host.props_root != null:
		host.props_root.visible = true
	if host.prop_art_root != null:
		host.prop_art_root.visible = true
	host._emit_status()
	host.request_render()


static func occupancy_mode_name(host: MTSStudioViewport) -> String:
	return host.occupancy_overlay.mode_name() if host.occupancy_overlay != null else "OFF"


## Synchronize slice visibility with structural-floor picking before applying
## the new visibility state, so hidden floors cannot steal prop clicks.
static func set_slice_mode(host: MTSStudioViewport, mode: int) -> void:
	host.slice_mode = mode
	if host.placement != null:
		host.placement.slice_mode = mode
	host._apply_slice()
	host._emit_status()
	host.request_render()
