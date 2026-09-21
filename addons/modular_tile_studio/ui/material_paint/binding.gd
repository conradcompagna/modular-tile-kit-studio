@tool
extends RefCounted

## Binding behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Bind the board's one profile, the PNG asset library, and the viewport's one sparse painter.
static func bind(host: MaterialPaintPanel,
	p_board: BoardDocument,
	p_library: AssetLibrary,
	p_viewport: MTSStudioViewport
) -> void:
	if host.viewport != null and host.viewport.material_profile_replayed.is_connected(host._on_material_profile_replayed):
		host.viewport.material_profile_replayed.disconnect(host._on_material_profile_replayed)
	# Detach from the outgoing library before rebinding, or a replaced library
	# would leave this panel still rebuilding from the previous one.
	if host.library != null and host.library.library_changed.is_connected(host._on_library_changed):
		host.library.library_changed.disconnect(host._on_library_changed)
	host.board = p_board
	host.library = p_library
	host.viewport = p_viewport
	if host.viewport != null and not host.viewport.material_profile_replayed.is_connected(host._on_material_profile_replayed):
		host.viewport.material_profile_replayed.connect(host._on_material_profile_replayed)
	if host.library != null and not host.library.library_changed.is_connected(host._on_library_changed):
		host.library.library_changed.connect(host._on_library_changed)
	host._draft = MaterialBlendProfile.new()
	if host.board != null and host.board.material_blend != null:
		host._draft.from_json(host.board.material_blend.to_json())
	host._selected_layers[MaterialPaintPanel.Workflow.PAINT] = host._find_first_layer(MaterialPaintPanel.Workflow.PAINT)
	host._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL] = host._find_first_layer(MaterialPaintPanel.Workflow.PROCEDURAL)
	host._pending_assets[MaterialPaintPanel.Workflow.PAINT] = ""
	host._pending_assets[MaterialPaintPanel.Workflow.PROCEDURAL] = ""
	if host._no_constraint_mode != null:
		host._no_constraint_mode.set_pressed_no_signal(false)
	host._populate_materials()
	host._refresh_main_controls()
	if host.viewport != null and host._brush_radius != null:
		host.viewport.set_material_brush_radius(host._brush_radius.value)
	if host.viewport != null and host._draft != null:
		host.viewport.set_material_pressure_controls(
			host._draft.pressure_controls_size,
			host._draft.pressure_controls_opacity
		)


## Rebuild the PNG gallery whenever the asset library's contents change.
##
## The gallery is a VIEW of AssetLibrary, never a snapshot of it. It was
## previously built only by bind(), so a PNG imported while the editor was open
## stayed invisible here until something happened to rebind the panel.
##
## The current choice is stored as an asset id in the draft profile rather than as
## a row index, so _refresh_main_controls() restores the highlight afterwards even
## though repopulating renumbers every row.
static func _on_library_changed(host: MaterialPaintPanel) -> void:
	host._populate_materials()
	host._refresh_main_controls()


## Resynchronize the compact controls after global undo or redo restores a stored material profile.
static func _on_material_profile_replayed(host: MaterialPaintPanel, profile_json: Dictionary) -> void:
	if host._draft == null:
		host._draft = MaterialBlendProfile.new()
	host._draft.from_json(profile_json)
	host._selected_layers[MaterialPaintPanel.Workflow.PAINT] = host._find_first_layer(MaterialPaintPanel.Workflow.PAINT)
	host._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL] = host._find_first_layer(MaterialPaintPanel.Workflow.PROCEDURAL)
	host._pending_assets[MaterialPaintPanel.Workflow.PAINT] = ""
	host._pending_assets[MaterialPaintPanel.Workflow.PROCEDURAL] = ""
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())
