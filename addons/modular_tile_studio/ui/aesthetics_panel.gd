@tool
class_name AestheticsPanel
extends LookPanelBase

## Board-wide controls for the unified GPU surface system.
##
## Asset-specific colour, Height response, and tiling controls live in the
## selected texture's inspector. Everything here is deliberately a
## board-global visual response: displacement master, editable world heightfield,
## seam correction strength, geometry-derived contact and stochastic
## sampling controls. BoardDocument placements remain the same constrained
## asset/grid/orientation language used by human painting and future LLM JSON.


func rebuild() -> void:
	_clear_body()
	if board == null:
		_update_status()
		return
	var profile := board.aesthetics

	_reset_all_row(_body, "Reset all rendering settings", func() -> void:
		board.reset_aesthetics()
		rebuild()
		_changed())

	_section(_body, "GPU surface effects", func() -> void:
		profile.reset_section(AestheticProfile.SECTION_SURFACE_GPU)
		rebuild()
		_changed())
	_profile_fields(_body, profile, AestheticProfile.SECTION_SURFACE_GPU,
		AestheticProfile.FIELDS, AestheticProfile.COLOR_FIELDS, AestheticProfile.TOGGLE_FIELDS)
	_note(_body,
		"These controls are board-global. Per-texture material choices and each GLB's terrain-flatten settings live in the selected asset's inspector.")

	_note(_body,
		"The unified surface shader handles PNG materials and live geometry deformation. Lighting, tonemapping, and colour grade live in the Lighting window.")

	_update_status()


## Summarize whether the current board still uses shipped rendering values or has an authored custom look.
func _update_status() -> void:
	if board == null:
		_status.text = "No board bound."
		return
	_status.text = "GPU surface settings: %s   Â·   saved with the board." % (
		"default" if board.aesthetics.is_default() else "customised"
	)
