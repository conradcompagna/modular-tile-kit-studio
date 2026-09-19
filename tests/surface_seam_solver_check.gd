extends SceneTree

## Regression check proving the terrain material uses parallax without a seam solver.

var _failures: int = 0


## Run the retired-solver contract and exit with a useful process status.
func _init() -> void:
	_check_profile_serialization()
	_check_shader_globals()
	if _failures > 0:
		push_error("surface_parallax_check: %d failure(s)" % _failures)
		quit(1)
		return
	print("surface_parallax_check: PASS")
	quit(0)


## Record one failed invariant without hiding later diagnostics.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("surface_parallax_check: %s" % message)


## Verify saved look data exposes only the material-parallax controls.
func _check_profile_serialization() -> void:
	var profile := AestheticProfile.new()
	profile.parallax_master = 0.75
	profile.height_metres_per_source_pixel = 0.002
	var data := profile.to_json()
	_check(
		is_equal_approx(float(data.get("parallax_master", -1.0)), 0.75)
		and is_equal_approx(float(data.get("height_metres_per_source_pixel", -1.0)), 0.002),
		"the saved profile must expose the material-parallax controls"
	)
	_check(
		not data.has("surface_seam_solver_enabled")
		and not data.has("gpu_displacement_master")
		and not data.has("displacement_samples_per_metre"),
		"the saved profile must not retain seam or vertex-displacement controls"
	)


## Verify the project publishes the two globals consumed by the terrain shader.
func _check_shader_globals() -> void:
	_check(
		ProjectSettings.has_setting("shader_globals/mts_parallax_master")
		and ProjectSettings.has_setting("shader_globals/mts_height_metres_per_source_pixel"),
		"the terrain shader globals must be registered by Project Settings"
	)
