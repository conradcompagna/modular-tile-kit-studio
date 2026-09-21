@tool
extends RefCounted

## System settings behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Open global paint-system algorithms in one focused dialog instead of padding both workflows.
static func _open_system_settings(host: MaterialPaintPanel) -> void:
	if host._draft == null:
		return
	host._updating = true
	host._blend_mode.select(host._blend_mode.get_item_index(int(host._draft.blend_mode)))
	host._debug_view.select(host._debug_view.get_item_index(int(host._draft.debug_view)))
	host._paint_detail.value = host._draft.paint_texels_per_metre
	host._maximum_edge.value = host._draft.maximum_surface_edge_px
	host._pressure_size.button_pressed = host._draft.pressure_controls_size
	host._pressure_opacity.button_pressed = host._draft.pressure_controls_opacity
	host._auto_texture_thin_side_slivers.button_pressed = host._draft.auto_texture_thin_side_slivers
	host._updating = false
	host._refresh_resolution_summary()
	host._settings_dialog.popup_centered(Vector2i(490, 485))


## Commit cheap global algorithms immediately while resolution remains an explicit rebuild.
static func _on_system_settings_changed(host: MaterialPaintPanel, _value: Variant) -> void:
	if host._updating or host._draft == null:
		return
	host._draft.blend_mode = host._blend_mode.get_selected_id() as MaterialBlendProfile.BlendMode
	host._draft.debug_view = host._debug_view.get_selected_id() as MaterialBlendProfile.DebugView
	host._draft.pressure_controls_size = host._pressure_size.button_pressed
	host._draft.pressure_controls_opacity = host._pressure_opacity.button_pressed
	host._commit_profile("Change paint system", UndoRedo.MERGE_ENDS)


## Persist the visible side-strip option; the scoped profile refresh updates its affected batches.
static func _on_auto_texture_thin_side_slivers_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating or host._draft == null:
		return
	host._draft.auto_texture_thin_side_slivers = enabled
	host._commit_profile("Change thin side-strip texturing", UndoRedo.MERGE_ENDS)


## Update the requested memory consequence without mutating canonical paint or board state.
static func _on_resolution_settings_changed(host: MaterialPaintPanel, _value: float) -> void:
	if host._updating or host._draft == null:
		return
	host._refresh_resolution_summary()


## Build a complete candidate profile from the visible pending resolution controls.
static func _resolution_candidate_profile(host: MaterialPaintPanel) -> MaterialBlendProfile:
	var candidate := MaterialBlendProfile.new()
	candidate.from_json(host._draft.to_json())
	candidate.paint_texels_per_metre = roundi(host._paint_detail.value)
	candidate.maximum_surface_edge_px = roundi(host._maximum_edge.value)
	return candidate


## Show current and requested controllable RGBA8 memory before the explicit rebuild.
static func _refresh_resolution_summary(host: MaterialPaintPanel) -> void:
	if host._paint_memory_summary == null or host._apply_resolution_button == null or host._draft == null:
		return
	var candidate := host._resolution_candidate_profile()
	var changed := (
		candidate.paint_texels_per_metre != host._draft.paint_texels_per_metre
		or candidate.maximum_surface_edge_px != host._draft.maximum_surface_edge_px
	)
	host._apply_resolution_button.disabled = not changed
	if host.viewport == null or host.viewport.surface_material_paint == null:
		host._paint_memory_summary.text = "Paint-mask memory is unavailable without an active board."
		return
	var current := host.viewport.surface_material_paint.paint_memory_bytes()
	var requested := host.viewport.surface_material_paint.paint_memory_bytes(candidate)
	if (
		int(current.get("error", FAILED)) != OK
		or int(requested.get("error", FAILED)) != OK
	):
		host._paint_memory_summary.text = "Paint-mask memory could not be calculated from the active board."
		host._apply_resolution_button.disabled = true
		return
	var painted_surfaces := int(current.get("painted_surfaces", 0))
	if painted_surfaces == 0:
		host._paint_memory_summary.text = (
			"No brush masks are allocated. New masks will use %d texels/m with a %d px edge cap."
			% [candidate.paint_texels_per_metre, candidate.maximum_surface_edge_px]
		)
		return
	host._paint_memory_summary.text = (
		"Controllable mask memory: %s now → %s requested across %d painted surfaces "
		+ "(canonical CPU + derived GPU RGBA8 texels; driver overhead excluded)."
	) % [
		MaterialPaintPanel._format_memory_bytes(int(current.get("total_bytes", 0))),
		MaterialPaintPanel._format_memory_bytes(int(requested.get("total_bytes", 0))),
		painted_surfaces,
	]


## Format one byte count compactly for the visible paint-memory summary.
static func _format_memory_bytes(byte_count: int) -> String:
	if byte_count >= 1024 * 1024:
		return "%.1f MiB" % (float(byte_count) / float(1024 * 1024))
	if byte_count >= 1024:
		return "%.1f KiB" % (float(byte_count) / 1024.0)
	return "%d B" % byte_count


## Confirm a potentially lossy resample only when canonical paint already exists.
static func _request_resolution_rebuild(host: MaterialPaintPanel) -> void:
	host._refresh_resolution_summary()
	if host._apply_resolution_button.disabled:
		return
	if (
		host.viewport != null
		and host.viewport.surface_material_paint != null
		and host.viewport.surface_material_paint.has_any_paint()
	):
		host._resolution_dialog.dialog_text = (
			host._paint_memory_summary.text
			+ "\n\nExisting masks will be bilinearly resampled. Lower resolution can remove fine "
			+ "mask detail. The current exact masks are retained as compressed undo data."
		)
		host._resolution_dialog.popup_centered(Vector2i(520, 260))
		return
	host._apply_resolution_rebuild()


## Apply the pending resolution atomically through the viewport's canonical paint owner.
static func _apply_resolution_rebuild(host: MaterialPaintPanel) -> void:
	if host._draft == null or host.viewport == null or host.board == null:
		return
	var requested_detail := roundi(host._paint_detail.value)
	var requested_edge := roundi(host._maximum_edge.value)
	if not host.viewport.apply_material_paint_resolution(requested_detail, requested_edge):
		host._status.text = "Paint-mask resolution rebuild failed; the previous paint is unchanged."
		return
	host._draft.from_json(host.board.material_blend.to_json())
	host._refresh_resolution_summary()
	host._status.text = (
		"Paint masks rebuilt at %d texels/m with a %d px edge cap."
		% [host._draft.paint_texels_per_metre, host._draft.maximum_surface_edge_px]
	)
