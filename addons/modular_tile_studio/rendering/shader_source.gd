@tool
extends RefCounted

## Expand authored shader includes before deriving variants or hashing source.
## Godot loads the canonical .gdshader directly; the material factory needs the
## same complete source so alpha-token rewrites and editor cache invalidation
## also see changes inside .gdshaderinc files.


static func read_expanded(path: String, ancestors: PackedStringArray = PackedStringArray()) -> String:
	if ancestors.has(path):
		push_error("Surface shader include cycle: %s -> %s" % [ancestors, path])
		return ""
	if not FileAccess.file_exists(path):
		push_error("Surface shader source does not exist: %s" % path)
		return ""
	var source := FileAccess.get_file_as_string(path)
	var include_pattern := RegEx.new()
	include_pattern.compile('(?m)^#include[ \\t]+"([^"]+)"[ \\t]*(?:\\r?\\n|$)')
	var stack := ancestors.duplicate()
	stack.append(path)
	var expanded := ""
	var cursor := 0
	for include: RegExMatch in include_pattern.search_all(source):
		expanded += source.substr(cursor, include.get_start() - cursor)
		var include_path := include.get_string(1)
		if not include_path.begins_with("res://") and not include_path.begins_with("user://"):
			include_path = path.get_base_dir().path_join(include_path).simplify_path()
		var included_source := read_expanded(include_path, stack)
		if included_source.is_empty():
			return ""
		expanded += included_source
		cursor = include.get_end()
	return expanded + source.substr(cursor)
