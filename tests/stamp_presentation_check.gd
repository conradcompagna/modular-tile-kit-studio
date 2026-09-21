extends SceneTree

## Exercise the real stamp presentation and palette state from brush to JSON.
##
## Every render role is checked so the visible brush choice, committed placement,
## and saved data cannot silently disagree.

const PlacementController := preload(
	"res://addons/modular_tile_studio/viewport/placement_controller.gd"
)
const K := preload("res://addons/modular_tile_studio/utils/mts_constants.gd")

var failures: int = 0


## Defer until global script classes are registered for the SceneTree.
func _init() -> void:
	_run.call_deferred()


## Record one failed invariant with a precise diagnostic.
func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok    %s" % message)
		return
	failures += 1
	printerr("  FAIL  %s" % message)


## Return the stable name of one render role for readable output.
func _role_name(role: int) -> String:
	var placement := SurfacePlacement.new()
	placement.presentation = role
	return placement.presentation_name()


## Verify every render role survives arming, committing, and a JSON round trip.
func _run() -> void:
	var controller := PlacementController.new()
	root.add_child(controller)

	for role: int in [
		SurfacePlacement.Presentation.TERRAIN_PAINT,
		SurfacePlacement.Presentation.DECAL,
		SurfacePlacement.Presentation.SHADER_DECAL,
	]:
		var name := _role_name(role)
		print("role: %s" % name)

		# 1. Arming must actually take. This is the step that silently failed.
		controller.set_surface_presentation(role)
		_check(
			controller.brush_surface_presentation == role,
			"%s arms the brush" % name
		)

		# 2. The explicit palette toggle must reach the controller.
		controller.set_surface_palette_matching(true)
		_check(
			controller.brush_match_underlying_palette,
			"%s keeps the palette-match choice" % name
		)

		# 3. A committed placement must carry its role and palette choice.
		var placement := SurfacePlacement.create("test_asset", Vector3i(1, 0, 2), K.Face.POS_Y, 0)
		placement.presentation = controller.brush_surface_presentation
		placement.match_underlying_palette = controller.brush_match_underlying_palette
		_check(placement.reference_error().is_empty(), "%s validates as a placement" % name)
		_check(
			placement.is_overlay() == (role != SurfacePlacement.Presentation.TERRAIN_PAINT),
			"%s reports the right occupancy role" % name
		)

		# 4. Saving and reloading must not change what was authored.
		var restored := SurfacePlacement.from_json(placement.to_json())
		_check(restored.presentation == role, "%s survives a JSON round trip" % name)
		_check(
			restored.match_underlying_palette
			== (role != SurfacePlacement.Presentation.TERRAIN_PAINT),
			"%s stores palette matching only for decal presentations" % name
		)
		_check(
			not restored.to_json().has("relief_depth_m"),
			"%s stores no redundant per-stamp relief depth" % name
		)

	controller.queue_free()
	print("")
	if failures == 0:
		print("STAMP PRESENTATION CHECK PASSED")
	else:
		printerr("STAMP PRESENTATION CHECK FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
