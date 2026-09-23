@tool
class_name ParticleEffectLibrary
extends Resource

## Stores reusable custom particle presets separately from any one board.
##
## Boards reference stable preset IDs while this resource owns the PNG-backed
## simulation settings. Imported PNGs are copied under res://tile_library so
## saved projects never depend on an external absolute file path.

const LIBRARY_PATH := "res://tile_library/particle_effect_library.tres"
const EFFECTS_DIR := "res://tile_library/particle_effects"

@export var presets: Array[ParticleEffectPreset] = []

var _by_id: Dictionary = {}


## Load the saved library into this instance, creating the resource only when it does not exist yet.
func load_or_create() -> bool:
	if ResourceLoader.exists(LIBRARY_PATH):
		var stored := ResourceLoader.load(LIBRARY_PATH) as ParticleEffectLibrary
		if stored == null:
			push_error("[Tile Studio] Particle effect library exists but is not a ParticleEffectLibrary: %s" % LIBRARY_PATH)
			return false
		presets = stored.presets
	_rebuild_index()
	if not ResourceLoader.exists(LIBRARY_PATH):
		return save_library()
	return true


## Rebuild the derived ID lookup and report duplicate or empty IDs rather than silently replacing them.
func _rebuild_index() -> bool:
	_by_id.clear()
	var valid := true
	for preset: ParticleEffectPreset in presets:
		if preset == null or preset.preset_id.is_empty():
			push_error("[Tile Studio] Particle effect library contains a preset without an ID.")
			valid = false
			continue
		if _by_id.has(preset.preset_id):
			push_error("[Tile Studio] Duplicate particle preset ID: %s" % preset.preset_id)
			valid = false
			continue
		_by_id[preset.preset_id] = preset
	return valid


## Return the exact reusable preset referenced by a board placement.
func preset_by_id(preset_id: String) -> ParticleEffectPreset:
	if _by_id.size() != presets.size():
		_rebuild_index()
	return _by_id.get(preset_id, null) as ParticleEffectPreset


## Import one PNG into the project and create a neutral, fully editable particle preset around it.
func import_png(source_path: String) -> ParticleEffectPreset:
	if source_path.get_extension().to_lower() != "png":
		push_error("[Tile Studio] Particle presets require a PNG image: %s" % source_path)
		return null
	var source_absolute := ProjectSettings.globalize_path(source_path) if source_path.begins_with("res://") else source_path
	var image := Image.load_from_file(source_absolute)
	if image == null or image.is_empty():
		push_error("[Tile Studio] Particle PNG could not be decoded: %s" % source_path)
		return null

	var base_name := source_path.get_file().get_basename()
	var preset_id := _unique_id(_id_from_name(base_name))
	var destination_dir := "%s/%s" % [EFFECTS_DIR, preset_id.to_lower()]
	var destination_path := "%s/particle.png" % destination_dir
	var destination_absolute := ProjectSettings.globalize_path(destination_path)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination_dir))
	if mkdir_error != OK:
		push_error("[Tile Studio] Could not create particle preset directory '%s' (error %d)." % [destination_dir, mkdir_error])
		return null
	var copy_error := DirAccess.copy_absolute(source_absolute, destination_absolute)
	if copy_error != OK:
		push_error("[Tile Studio] Could not copy particle PNG to '%s' (error %d)." % [destination_path, copy_error])
		return null

	var preset := ParticleEffectPreset.new()
	preset.preset_id = preset_id
	preset.display_name = base_name.capitalize()
	preset.texture_path = destination_path
	presets.append(preset)
	_by_id[preset_id] = preset
	if not save_library():
		presets.erase(preset)
		_by_id.erase(preset_id)
		return null
	emit_changed()
	return preset


## Remove one unreferenced preset and its library entry; callers own reference checks.
func remove_preset(preset_id: String) -> bool:
	var preset := preset_by_id(preset_id)
	if preset == null:
		push_error("[Tile Studio] Cannot remove missing particle preset '%s'." % preset_id)
		return false
	presets.erase(preset)
	_by_id.erase(preset_id)
	if not save_library():
		presets.append(preset)
		_by_id[preset_id] = preset
		return false
	emit_changed()
	return true


## Persist the complete preset library atomically through Godot's ResourceSaver.
func save_library() -> bool:
	var parent_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LIBRARY_PATH.get_base_dir()))
	if parent_error != OK:
		push_error("[Tile Studio] Could not create particle library directory (error %d)." % parent_error)
		return false
	var error := ResourceSaver.save(self, LIBRARY_PATH)
	if error != OK:
		push_error("[Tile Studio] Could not save particle effect library (error %d)." % error)
		return false
	return true


## Turn a display filename into a stable uppercase machine identifier.
func _id_from_name(value: String) -> String:
	var source := value.strip_edges().to_upper()
	var output := ""
	var previous_was_separator := false
	for index in source.length():
		var code := source.unicode_at(index)
		var is_alphanumeric := (code >= 48 and code <= 57) or (code >= 65 and code <= 90)
		if is_alphanumeric:
			output += String.chr(code)
			previous_was_separator = false
		elif not previous_was_separator and not output.is_empty():
			output += "_"
			previous_was_separator = true
	output = output.trim_suffix("_")
	return output if not output.is_empty() else "PARTICLE_EFFECT"


## Append a visible numeric suffix until the machine identifier is unique.
func _unique_id(base_id: String) -> String:
	var candidate := base_id
	var suffix := 2
	while _by_id.has(candidate):
		candidate = "%s_%d" % [base_id, suffix]
		suffix += 1
	return candidate
