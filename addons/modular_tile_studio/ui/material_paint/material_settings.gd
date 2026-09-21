@tool
extends RefCounted

## Material settings behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Open the selected material's two-result appearance editor with live stored values.
static func _open_material_settings(host: MaterialPaintPanel) -> void:
	var layer_index := host._current_layer_index()
	if layer_index < 0 or host._draft == null:
		return
	var layer := host._draft.layer(layer_index)
	host._updating = true
	host._material_scale.value = float(layer.get("texture_scale_percent", 100.0))
	host._material_height_blend.value = float(layer.get("height_blend_percent", 0.0))
	host._update_slider_label(host._material_scale)
	host._update_slider_label(host._material_height_blend)
	host._updating = false
	host._material_dialog.popup_centered(Vector2i(470, 190))


## Commit material scale and height blending immediately while layer opacity remains deliberately absent.
static func _on_material_settings_changed(host: MaterialPaintPanel, _value: float) -> void:
	host._update_slider_label(host._material_scale)
	host._update_slider_label(host._material_height_blend)
	if host._updating or host._draft == null:
		return
	var layer_index := host._current_layer_index()
	if layer_index < 0:
		return
	var layer := host._draft.layer(layer_index)
	layer["texture_scale_percent"] = host._material_scale.value
	layer["height_blend_percent"] = host._material_height_blend.value
	layer["opacity_percent"] = 100.0
	host._draft.set_layer(layer_index, layer)
	host._commit_profile("Adjust material appearance", UndoRedo.MERGE_ENDS)
