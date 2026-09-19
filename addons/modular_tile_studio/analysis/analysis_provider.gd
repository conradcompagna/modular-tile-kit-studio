@tool
class_name AnalysisProvider
extends RefCounted

## Abstract analysis backend (spec 18).
##
## The editor must never depend on a specific AI model. Concrete providers
## implement this contract; ComfyUIProvider is the first, but MoGe/Marigold/SAM
## are reached through user-supplied workflow recipes rather than being wired
## into the plugin. Analysis is always optional -- an asset with only albedo is
## fully usable (spec 11).

signal job_started(job_id: String, asset_id: String)
signal job_progress(job_id: String, message: String, fraction: float)
signal job_finished(job_id: String, asset_id: String, outputs: Dictionary)
signal job_failed(job_id: String, asset_id: String, reason: String)


## Kick off analysis of `asset` using `recipe`. Returns a job id, or "" if the
## job could not be started.
func analyze(_asset: TileAsset, _recipe: Dictionary) -> String:
	push_error("AnalysisProvider.analyze is abstract")
	return ""


func cancel(_job_id: String) -> void:
	pass


## One of: "idle", "queued", "running", "done", "failed", "unknown".
func query_status(_job_id: String) -> String:
	return "unknown"


## Whether the backend is currently reachable. The editor stays fully functional
## when this is false (spec 19).
func is_available() -> bool:
	return false


func provider_name() -> String:
	return "None"
