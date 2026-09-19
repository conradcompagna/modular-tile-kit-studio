@tool
extends RefCounted

## Complete all explicit BQR source and material reimports before a fresh process is allowed to load this level.
func run(reimport: bool = true) -> Dictionary:
	var paths: PackedStringArray = PackedStringArray(JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_quarantine_revision03/reimport_paths.json")))
	if reimport:
		EditorInterface.get_resource_filesystem().reimport_files(paths)
	var results: Array[Dictionary] = []
	for path: String in paths:
		if path.ends_with(".glb"):
			var scene: PackedScene = ResourceLoader.load(path,"PackedScene",ResourceLoader.CACHE_MODE_REPLACE)
			results.append({"path":path,"ok":scene != null})
	var report: Dictionary = {"reimported":paths.size(),"load_checks":results}
	var file := FileAccess.open("res://exports/blackridge_quarantine_revision03/load_checks.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	return report
