@tool
extends EditorPlugin

## Enabled only by the disposable test project, never by the normal editor.


func _enter_tree() -> void:
	_start.call_deferred()


func _start() -> void:
	var allowed := ["material_paint_ui_check", "placement_viewport_check"]
	var selected := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture="):
			selected = argument.trim_prefix("--fixture=")
	if selected not in allowed:
		push_error("Select an editor fixture with -- --fixture=<name>.")
		get_tree().quit(1)
		return
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	var script := load("res://tests/%s.gd" % selected) as Script
	var fixture := script.new() as Node
	get_tree().root.add_child(fixture)
