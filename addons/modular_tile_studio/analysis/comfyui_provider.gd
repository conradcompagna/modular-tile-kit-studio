@tool
class_name ComfyUIProvider
extends AnalysisProvider

## ComfyUI analysis backend (spec 19).
##
## Talks to a local ComfyUI over its HTTP API: upload image -> load an
## API-format workflow recipe -> substitute inputs -> queue -> poll history ->
## download outputs -> assign to G-buffer slots -> trigger derived maps.
##
## Deliberately generic. MoGe, Marigold and SAM are reached through recipe JSON
## files on disk, not hardcoded graphs, so swapping or adding models needs no
## GDScript change (spec 18/20).
##
## If ComfyUI is unavailable the editor must still work normally: every failure
## path here degrades to a status message and leaves the asset untouched
## (spec 19). A failed job never corrupts an asset.

const K := preload("../utils/mts_constants.gd")

signal availability_changed(available: bool)
## Emitted every time a probe resolves, whether or not availability changed.
## The UI needs this to clear a transient "reconnecting..." label: a server that
## was offline and is still offline produces no CHANGE, so availability_changed
## alone left the status stuck.
signal probe_finished(available: bool)

## Milliseconds between history polls while a job runs.
const POLL_INTERVAL_MS: int = 900
## How long to wait for an autostarted server to answer before giving up.
const AUTOSTART_TIMEOUT_SEC: float = 180.0
## Liveness probe budget. Short on purpose: /system_stats either answers at once
## or the server is not there, and a slow probe is indistinguishable from a
## frozen editor.
const PROBE_TIMEOUT_SEC: float = 3.0

var server_url: String = "http://127.0.0.1:8188"
var recipe_dir: String = "res://addons/modular_tile_studio/analysis/recipes"
var timeout_seconds: float = 600.0

var _available: bool = false
var _client_id: String = ""
var _jobs: Dictionary = {}
var _host: Node = null
var _probe_active: bool = false
var _autostart_pid: int = -1
var _autostart_deadline_ms: int = 0


func _init() -> void:
	_client_id = "mts-%d" % (randi() % 1000000)


## The provider needs a Node in the tree to own HTTPRequest children and timers.
func set_host(host: Node) -> void:
	_host = host


func provider_name() -> String:
	return "ComfyUI"


func is_available() -> bool:
	return _available


func base_url() -> String:
	return server_url.strip_edges().trim_suffix("/")


# --- HTTP plumbing --------------------------------------------------------

## Every request in this file goes through here.
##
## `use_threads` is the whole reason the editor used to lock up. It defaults to
## FALSE, which makes HTTPRequest poll its socket inside _process() -- on the
## main thread. Uploading a multi-megabyte source image and then holding the
## connection open for the entire MoGe/Marigold inference therefore froze the
## editor from the moment the button was pressed until the model finished, even
## though the code reads as callback-driven. Signal-based is not the same as
## off-thread; this flag is what actually moves the work.
##
## Consequence: request_completed fires on HTTPRequest's OWN thread, so any
## handler that touches the scene tree, UI, ResourceSaver or EditorInterface
## must hop back via _main_thread(). Callers here only mutate plain data and
## emit signals, and those signals are re-emitted on the main thread by
## _emit_main().
##
## body_size_limit stays -1 because analysis outputs are legitimately large
## multi-megapixel PNGs; a limit would silently truncate maps.
func _new_request(timeout_override: float = -1.0) -> HTTPRequest:
	# Callers must already be on the main thread: add_child touches the live
	# scene tree. _poll/_queue_prompt/_collect_outputs each defer for this.
	var request := HTTPRequest.new()
	request.use_threads = true
	request.body_size_limit = -1
	request.download_chunk_size = 262144
	# Timeout is per REQUEST KIND, not one global number.
	#
	# timeout_seconds is the INFERENCE budget (default 600 s) and is right for a
	# MoGe/Marigold run. Applying it to the liveness probe is what wedged the UI
	# at "reconnecting...": with ComfyUI down, a connect to a dead port does not
	# fail fast, so the probe sat for the full ten minutes while the 5 s poll
	# timer stacked another hung request on top of it every tick.
	var seconds := timeout_override if timeout_override > 0.0 else timeout_seconds
	request.timeout = int(maxf(seconds, 1.0))
	_host.add_child(request)
	return request


## Run `callable` on the main thread.
##
## HTTPRequest callbacks arrive on a worker thread once use_threads is on.
## Godot's scene tree, resource system and editor APIs are main-thread-only, so
## anything reaching them is deferred rather than called directly.
func _main_thread(callable: Callable) -> void:
	callable.call_deferred()


## Emit a signal on the main thread regardless of which thread produced it.
##
## Listeners are UI code (status text, inspector refresh, board rebuild), so
## emitting straight from the HTTP thread would touch Controls off-thread.
func _emit_main(signal_name: String, a: Variant = null, b: Variant = null, c: Variant = null) -> void:
	_do_emit.call_deferred(signal_name, a, b, c)


func _do_emit(signal_name: String, a: Variant, b: Variant, c: Variant) -> void:
	match signal_name:
		"job_started":
			job_started.emit(a, b)
		"job_progress":
			job_progress.emit(a, b, c)
		"job_finished":
			job_finished.emit(a, b, c)
		"job_failed":
			job_failed.emit(a, b, c)
		"availability_changed":
			availability_changed.emit(a)
		"probe_finished":
			probe_finished.emit(a)




# --- Connection -----------------------------------------------------------

## Probe /system_stats. Called on plugin load and on demand; never blocks the
## editor and never errors loudly when the server is simply not running.
func check_connection() -> void:
	if _host == null or not _host.is_inside_tree():
		return
	# Only ever one probe in flight. Without this the 5 s poll timer stacked a
	# new hung request every tick while the server was down.
	if _probe_active:
		return
	_probe_active = true
	var request := _new_request(PROBE_TIMEOUT_SEC)
	request.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			var ok := result == HTTPRequest.RESULT_SUCCESS and code == 200
			var changed := ok != _available
			_available = ok
			if ok:
				var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
				if parsed is Dictionary:
					_log_server_info(parsed)
			_probe_active = false
			if changed:
				_emit_main("availability_changed", _available)
			_emit_main("probe_finished", _available)
			request.queue_free.call_deferred()
	)
	var err := request.request(base_url() + "/system_stats")
	if err != OK:
		_probe_active = false
		var was := _available
		_available = false
		if was:
			_emit_main("availability_changed", false)
		_emit_main("probe_finished", false)
		request.queue_free.call_deferred()


func _log_server_info(stats: Dictionary) -> void:
	var system: Dictionary = stats.get("system", {})
	var devices: Array = stats.get("devices", [])
	var device_name := "unknown device"
	if devices.size() > 0 and devices[0] is Dictionary:
		device_name = String((devices[0] as Dictionary).get("name", device_name))
	print("[Tile Studio] ComfyUI connected: %s | ComfyUI %s | %s" % [
		base_url(), String(system.get("comfyui_version", "?")), device_name
	])


## Launch a local ComfyUI if one is configured and not already answering.
##
## Started detached so it outlives a single editor action; the user keeps
## ownership of the process. Returns true if a launch was attempted.
func try_autostart(python_exe: String, main_script: String, extra_args: PackedStringArray) -> bool:
	if _available or _autostart_pid > 0:
		return false
	if python_exe.is_empty() or main_script.is_empty():
		return false
	if not FileAccess.file_exists(python_exe):
		push_warning("[Tile Studio] ComfyUI autostart: python not found at '%s'" % python_exe)
		return false
	if not FileAccess.file_exists(main_script):
		push_warning("[Tile Studio] ComfyUI autostart: main.py not found at '%s'" % main_script)
		return false

	var args := PackedStringArray([main_script])
	args.append_array(extra_args)
	var pid := OS.create_process(python_exe, args, false)
	if pid <= 0:
		push_warning("[Tile Studio] ComfyUI autostart failed to spawn a process")
		return false

	_autostart_pid = pid
	_autostart_deadline_ms = Time.get_ticks_msec() + int(AUTOSTART_TIMEOUT_SEC * 1000.0)
	print("[Tile Studio] Starting ComfyUI (pid %d); it will connect when the server finishes loading." % pid)
	return true


## True while an autostarted server is still expected to come up. The UI uses
## this to show "starting..." rather than "offline".
func is_autostarting() -> bool:
	if _autostart_pid <= 0 or _available:
		return false
	if Time.get_ticks_msec() > _autostart_deadline_ms:
		_autostart_pid = -1
		return false
	return true


# --- Recipes (spec 20) ----------------------------------------------------

## Load recipe descriptors from the recipe directory. Each recipe names an
## API-format workflow file and declares which outputs map to which G-buffer
## channels, so the plugin never has to understand the graph itself.
func list_recipes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(recipe_dir)
	if dir == null:
		return out
	for file in dir.get_files():
		if not file.ends_with(".recipe.json"):
			continue
		var path := recipe_dir.path_join(file)
		var recipe := _load_json(path)
		if recipe.is_empty():
			continue
		recipe["recipe_path"] = path
		out.append(recipe)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", "")))
	return out


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[Tile Studio] recipe not found: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("[Tile Studio] recipe '%s' is not a JSON object" % path)
		return {}
	return parsed


# --- Job submission -------------------------------------------------------

## Run `recipe` over `asset`'s source image, or over one of its already-analyzed
## G-buffer channels when the recipe names one via "input_channel".
##
## Most recipes (MoGe, Marigold normals/depth/appearance, SAM) analyze the
## untouched source photo. A recipe that instead post-processes an existing map
## -- CHORD's normal-to-height Poisson solve, for instance, which needs a
## normal map as input, not a photo -- declares
## `"input_channel": "normal"` so the SAME upload/queue/poll/download path runs
## unchanged, just pointed at a different file. This is the one place that
## decides which image gets uploaded; no recipe-specific branching exists
## anywhere else in this provider.
##
## The asset is not modified until outputs actually arrive, so a failure at any
## stage leaves it exactly as it was.
func analyze(asset: TileAsset, recipe: Dictionary) -> String:
	if _host == null:
		push_error("[Tile Studio] ComfyUIProvider has no host node")
		return ""
	if asset == null:
		return ""
	if not _available:
		_emit_main("job_failed", "", asset.asset_id, "ComfyUI is not running at %s" % base_url())
		return ""

	var input_channel := String(recipe.get("input_channel", ""))
	var source := asset.source_path
	if not input_channel.is_empty():
		if asset.gbuffer == null:
			_emit_main("job_failed", "", asset.asset_id, "Asset has no G-buffer to read channel '%s' from" % input_channel)
			return ""
		source = asset.gbuffer.get_channel(input_channel)
		if source.is_empty():
			_emit_main("job_failed", "", asset.asset_id, "Asset has no '%s' map yet; run an analysis that produces it first" % input_channel)
			return ""
		source = ProjectSettings.globalize_path(source)

	if source.is_empty() or not FileAccess.file_exists(source):
		_emit_main("job_failed", "", asset.asset_id, "Asset has no readable source image")
		return ""

	var workflow_name := String(recipe.get("workflow", ""))
	if workflow_name.is_empty():
		_emit_main("job_failed", "", asset.asset_id, "Recipe names no workflow file")
		return ""
	var workflow_path: String = String(recipe.get("recipe_path", "")).get_base_dir().path_join(workflow_name)
	var workflow := _load_json(workflow_path)
	if workflow.is_empty():
		_emit_main("job_failed", "", asset.asset_id, "Workflow '%s' missing or invalid" % workflow_name)
		return ""

	var job_id := "job-%d-%s" % [Time.get_ticks_msec(), asset.asset_id]
	_jobs[job_id] = {
		"asset": asset,
		"recipe": recipe,
		"workflow": workflow,
		"status": "uploading",
		"prompt_id": "",
		"started_ms": Time.get_ticks_msec(),
	}
	_emit_main("job_started", job_id, asset.asset_id)
	_emit_main("job_progress", job_id, "Uploading source image", 0.05)
	_upload_image(job_id, source)
	return job_id


## POST the source image to /upload/image as multipart form data.
func _build_upload_payload(job_id: String, source_path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(source_path)
	if bytes.is_empty():
		return {
			"ok": false,
			"error": "Could not read source image",
		}

	var filename := "mts_%s_%s" % [
		job_id.replace(":", "_"),
		source_path.get_file()
	]

	var boundary := "----MTSBoundary%d" % Time.get_ticks_msec()

	var body := PackedByteArray()
	body.append_array(("--%s\r\n" % boundary).to_utf8_buffer())
	body.append_array(
		('Content-Disposition: form-data; name="image"; filename="%s"\r\n' % filename)
			.to_utf8_buffer()
	)
	body.append_array("Content-Type: image/png\r\n\r\n".to_utf8_buffer())
	body.append_array(bytes)
	body.append_array("\r\n".to_utf8_buffer())

	body.append_array(("--%s\r\n" % boundary).to_utf8_buffer())
	body.append_array(
		'Content-Disposition: form-data; name="overwrite"\r\n\r\n'.to_utf8_buffer()
	)
	body.append_array("true\r\n".to_utf8_buffer())
	body.append_array(("--%s--\r\n" % boundary).to_utf8_buffer())

	return {
		"ok": true,
		"filename": filename,
		"body": body,
		"headers": PackedStringArray([
			"Content-Type: multipart/form-data; boundary=%s" % boundary
		]),
	}


func _upload_image(job_id: String, source_path: String) -> void:
	if not _jobs.has(job_id) or _host == null:
		return

	var worker := Thread.new()
	var start_error := worker.start(
		_build_upload_payload.bind(job_id, source_path)
	)

	if start_error != OK:
		_fail(job_id, "Could not start upload preparation thread")
		return

	# Yield the editor while disk read + multipart construction happen.
	while worker.is_alive():
		await _host.get_tree().process_frame

	var payload_variant := worker.wait_to_finish()
	if not (payload_variant is Dictionary):
		_fail(job_id, "Upload preparation failed")
		return

	var payload: Dictionary = payload_variant

	if not bool(payload.get("ok", false)):
		_fail(job_id, String(payload.get("error", "Upload preparation failed")))
		return

	# Job may have been cancelled while the worker was running.
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return

	job["upload_name"] = String(payload["filename"])

	var request := _new_request()

	request.request_completed.connect(
		func(
			result: int,
			code: int,
			_h: PackedStringArray,
			response: PackedByteArray
		) -> void:
			request.queue_free.call_deferred()

			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				_fail(job_id, "Image upload failed (HTTP %d)" % code)
				return

			var parsed: Variant = JSON.parse_string(
				response.get_string_from_utf8()
			)

			if parsed is Dictionary:
				var reported := String(
					(parsed as Dictionary).get("name", "")
				)
				if not reported.is_empty():
					job["upload_name"] = reported

				job["upload_subfolder"] = String(
					(parsed as Dictionary).get("subfolder", "")
				)

			_emit_main("job_progress", job_id, "Queuing workflow", 0.15)

			_queue_prompt(job_id)
	)

	var err := request.request_raw(
		base_url() + "/upload/image",
		payload["headers"],
		HTTPClient.METHOD_POST,
		payload["body"]
	)
	if err != OK:
		request.queue_free.call_deferred()
		_fail(job_id, "Upload request could not be sent")


## Substitute inputs into the workflow and POST it to /prompt.
## Schedule the workflow POST.
##
## Entered from the upload's request_completed, i.e. HTTPRequest's worker thread
## now that use_threads is on. _new_request() parents a node into the live tree,
## and add_child is main-thread-only, so the real work is deferred exactly like
## _poll does.
func _queue_prompt(job_id: String) -> void:
	_queue_prompt_main.call_deferred(job_id)


func _queue_prompt_main(job_id: String) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty() or _host == null or not _host.is_inside_tree():
		return

	var workflow: Dictionary = (job["workflow"] as Dictionary).duplicate(true)
	var recipe: Dictionary = job["recipe"]
	var asset: TileAsset = job["asset"]

	var upload_name := String(job.get("upload_name", ""))
	var subfolder := String(job.get("upload_subfolder", ""))
	var image_ref := upload_name if subfolder.is_empty() else "%s/%s" % [subfolder, upload_name]

	_apply_substitutions(workflow, recipe, image_ref, asset)

	# Godot's JSON parser turns EVERY number into a float, so a node link that was
	# authored as ["3", 0] comes back as ["3", 0.0] and re-serialises that way.
	# ComfyUI indexes its outputs with that value in Python and raises
	# "list indices must be integers or slices, not float", rejecting the whole
	# prompt. Restore whole-valued floats to ints before sending.
	_restore_integers(workflow)

	var payload := {
		"prompt": workflow,
		"client_id": _client_id,
	}

	var request := _new_request()
	request.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, response: PackedByteArray) -> void:
			request.queue_free.call_deferred()
			var text := response.get_string_from_utf8()
			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				# ComfyUI returns detailed validation errors here; surface them
				# instead of a bare status code.
				_fail(job_id, "Queue rejected (HTTP %d): %s" % [code, text.substr(0, 400)])
				return
			var parsed: Variant = JSON.parse_string(text)
			if not (parsed is Dictionary):
				_fail(job_id, "Queue returned an unreadable response")
				return
			var prompt_id := String((parsed as Dictionary).get("prompt_id", ""))
			if prompt_id.is_empty():
				_fail(job_id, "Queue returned no prompt_id")
				return
			job["prompt_id"] = prompt_id
			job["status"] = "running"
			_emit_main("job_progress", job_id, "Running on ComfyUI", 0.3)
			_poll(job_id)
	)
	var err := request.request(
		base_url() + "/prompt",
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)
	if err != OK:
		request.queue_free.call_deferred()
		_fail(job_id, "Queue request could not be sent")


## Walk a parsed workflow and convert whole-valued floats back to ints, in place.
##
## Only exact integers are converted, so a genuine 0.5 threshold or 7.5 strength
## keeps its type. Node links (["3", 0]) and integer widgets (steps, resolution,
## batch size, seed) are what actually break without this.
func _restore_integers(value: Variant) -> void:
	if value is Dictionary:
		var dict: Dictionary = value
		for key: Variant in dict.keys():
			var entry: Variant = dict[key]
			if entry is float and _is_whole(entry):
				dict[key] = int(entry)
			else:
				_restore_integers(entry)
	elif value is Array:
		var array: Array = value
		for i in array.size():
			var entry: Variant = array[i]
			if entry is float and _is_whole(entry):
				array[i] = int(entry)
			else:
				_restore_integers(entry)


func _is_whole(number: float) -> bool:
	return is_finite(number) and absf(number - roundf(number)) < 0.0000001


## Inject the uploaded image and recipe parameters into the API-format graph.
##
## Recipes address nodes by id and widget name, which keeps this generic across
## MoGe/Marigold/SAM graphs without the plugin parsing node semantics.
func _apply_substitutions(workflow: Dictionary, recipe: Dictionary, image_ref: String, asset: TileAsset) -> void:
	# 1. Explicit image input nodes named by the recipe.
	var image_nodes: Array = recipe.get("image_input_nodes", [])
	for node_id: Variant in image_nodes:
		var node: Dictionary = workflow.get(String(node_id), {})
		if node.is_empty():
			continue
		var inputs: Dictionary = node.get("inputs", {})
		inputs["image"] = image_ref
		node["inputs"] = inputs

	# 2. Fallback: any LoadImage node, so a hand-exported workflow works without
	#    the author having to list node ids.
	if image_nodes.is_empty():
		for node_id: String in workflow:
			var node: Dictionary = workflow[node_id]
			if String(node.get("class_type", "")) == "LoadImage":
				var inputs: Dictionary = node.get("inputs", {})
				inputs["image"] = image_ref
				node["inputs"] = inputs

	# 3. Recipe-declared parameter overrides: { node_id: { widget: value } }.
	var params: Dictionary = recipe.get("parameters", {})
	for node_id: String in params:
		var node: Dictionary = workflow.get(node_id, {})
		if node.is_empty():
			continue
		var inputs: Dictionary = node.get("inputs", {})
		var overrides: Dictionary = params[node_id]
		for widget: String in overrides:
			inputs[widget] = overrides[widget]
		node["inputs"] = inputs

	# 4. Asset-derived context, so a recipe can reference real tile dimensions
	#    rather than assuming a size.
	var context: Dictionary = recipe.get("asset_parameters", {})
	for node_id: String in context:
		var node: Dictionary = workflow.get(node_id, {})
		if node.is_empty():
			continue
		var inputs: Dictionary = node.get("inputs", {})
		var mapping: Dictionary = context[node_id]
		for widget: String in mapping:
			var token := String(mapping[widget])
			inputs[widget] = _resolve_token(token, asset)
		node["inputs"] = inputs


func _resolve_token(token: String, asset: TileAsset) -> Variant:
	match token:
		"$asset_id":
			return asset.asset_id
		"$width_m":
			return asset.visual_size_m.x
		"$height_m":
			return asset.visual_size_m.y
		"$seed":
			return randi() % 1000000
		_:
			return token


# --- Polling --------------------------------------------------------------

## Schedule the next history poll.
##
## Re-entered from HTTPRequest's worker thread now that use_threads is on, and
## SceneTree/create_timer are main-thread-only -- so the actual scheduling is
## always deferred onto the main thread rather than called where we happen to be.
func _poll(job_id: String) -> void:
	_poll_main.call_deferred(job_id)


func _poll_main(job_id: String) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty() or _host == null or not _host.is_inside_tree():
		return

	if Time.get_ticks_msec() - int(job["started_ms"]) > int(timeout_seconds * 1000.0):
		_fail(job_id, "Timed out after %.0f s" % timeout_seconds)
		return

	var timer := _host.get_tree().create_timer(POLL_INTERVAL_MS / 1000.0)
	timer.timeout.connect(func() -> void:
		if not _jobs.has(job_id):
			return
		var request := _new_request()
		request.request_completed.connect(
			func(result: int, code: int, _h: PackedStringArray, response: PackedByteArray) -> void:
				request.queue_free.call_deferred()
				if result != HTTPRequest.RESULT_SUCCESS or code != 200:
					# A transient poll failure is not fatal; keep waiting.
					_poll(job_id)
					return
				var parsed: Variant = JSON.parse_string(response.get_string_from_utf8())
				if not (parsed is Dictionary):
					_poll(job_id)
					return
				var history: Dictionary = parsed
				var prompt_id := String(job["prompt_id"])
				if not history.has(prompt_id):
					_poll(job_id)
					return
				var entry: Dictionary = history[prompt_id]
				var status: Dictionary = entry.get("status", {})
				if status.get("status_str", "") == "error":
					# ComfyUI records the failing node and exception under
					# status.messages; without it the user only ever saw
					# "an execution error" and had nothing to act on.
					_fail(job_id, "ComfyUI execution error: %s" % _describe_status_error(status))
					return
				if not bool(status.get("completed", false)):
					_poll(job_id)
					return
				_emit_main("job_progress", job_id, "Retrieving outputs", 0.75)
				_collect_outputs(job_id, entry.get("outputs", {}))
		)
		var err := request.request(base_url() + "/history/" + String(job["prompt_id"]))
		if err != OK:
			request.queue_free.call_deferred()
			_poll(job_id)
	)


# --- Output retrieval -----------------------------------------------------

## Walk the history outputs, download each image, and file it under the channel
## the recipe assigned to that node.
## Entered from the poll's request_completed on HTTPRequest's worker thread; it
## fans out into _download_output, which parents new request nodes into the
## tree. Deferred for the same reason as _queue_prompt.
func _collect_outputs(job_id: String, outputs: Dictionary) -> void:
	_collect_outputs_main.call_deferred(job_id, outputs)


func _collect_outputs_main(job_id: String, outputs: Dictionary) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty() or _host == null or not _host.is_inside_tree():
		return
	var recipe: Dictionary = job["recipe"]
	var asset: TileAsset = job["asset"]
	# { node_id: channel } or { node_id: [channel, channel, ...] } when one node
	# emits several maps as a batch (Marigold IID does exactly this).
	var mapping: Dictionary = recipe.get("outputs", {})

	# A recipe may declare one node as carrying scalar UI metadata rather than
	# an image -- MoGe Geometry's MTSMoGeHeight node reports the point cloud's
	# metric X/Y/Z extent this way, since ComfyUI's history has no numeric
	# output type and "ui" is the one channel a custom node can use to return
	# plain data alongside its image. Stashed on the job (not in "written",
	# which _finish treats as one-path-per-channel) and merged into the result
	# right before the job is reported finished.
	var metrics_node := String(recipe.get("metrics_node", ""))
	if not metrics_node.is_empty() and outputs.has(metrics_node):
		var metric_output: Dictionary = outputs[metrics_node]
		var metric_list: Array = metric_output.get("mts_moge_metrics", [])
		if not metric_list.is_empty() and metric_list[0] is Dictionary:
			job["moge_metrics"] = metric_list[0]

	var downloads: Array = []
	for node_id: String in outputs:
		var node_output: Dictionary = outputs[node_id]
		var images: Array = node_output.get("images", [])
		if images.is_empty():
			continue
		var channel_spec: Variant = mapping.get(node_id, null)
		if channel_spec == null:
			continue
		var channels: Array = channel_spec if channel_spec is Array else [channel_spec]
		for i in images.size():
			if i >= channels.size():
				break
			var image_info: Dictionary = images[i]
			downloads.append({
				"channel": String(channels[i]),
				"filename": String(image_info.get("filename", "")),
				"subfolder": String(image_info.get("subfolder", "")),
				"type": String(image_info.get("type", "output")),
				# Optional { "r": "roughness", "g": "metallic" } layout for an
				# image that packs several maps into its colour channels.
				"unpack": _unpack_spec(recipe, node_id, i),
			})

	if downloads.is_empty():
		# The single most common analysis failure: the graph ran fine but the
		# recipe's output map names node ids that did not emit images (renamed
		# nodes, a PreviewImage instead of SaveImage, or a muted branch). Name
		# both sides so the mismatch is obvious rather than guessed at.
		var produced := PackedStringArray()
		for node_id: String in outputs:
			var imgs: Array = (outputs[node_id] as Dictionary).get("images", [])
			produced.append("%s(%d images)" % [node_id, imgs.size()])
		_fail(job_id, "No outputs matched the recipe map. Workflow emitted: [%s]; recipe expects nodes: [%s]" % [
			", ".join(produced) if produced.size() > 0 else "nothing",
			", ".join(PackedStringArray(mapping.keys()))
		])
		return

	job["pending"] = downloads.size()
	job["written"] = {}
	var derived_dir := asset.derived_dir
	if derived_dir.is_empty():
		derived_dir = K.ASSETS_DIR.path_join(asset.asset_id).path_join("derived")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(derived_dir))

	for download: Dictionary in downloads:
		_download_output(job_id, download, derived_dir)


func _download_output(job_id: String, download: Dictionary, derived_dir: String) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return

	var query := "filename=%s&subfolder=%s&type=%s" % [
		String(download["filename"]).uri_encode(),
		String(download["subfolder"]).uri_encode(),
		String(download["type"]).uri_encode(),
	]

	var request := _new_request()
	request.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			request.queue_free.call_deferred()
			var channel := String(download["channel"])
			if result == HTTPRequest.RESULT_SUCCESS and code == 200 and body.size() > 0:
				var ext := String(download["filename"]).get_extension()
				if ext.is_empty():
					ext = "png"
				var out_path := derived_dir.path_join("%s.%s" % [channel, ext])
				var file := FileAccess.open(out_path, FileAccess.WRITE)
				if file != null:
					file.store_buffer(body)
					file.close()

					# Some models pack several maps into one image's colour
					# channels. Marigold IID appearance returns a "material"
					# image carrying R=roughness and G=metallicity; saving it
					# under one channel name would keep the R and silently throw
					# the G away. The recipe declares the layout and it is
					# unpacked here into real single-channel maps.
					var unpacked := _unpack_channels(
						out_path,
						download.get("unpack", {}),
						derived_dir
					)
					if not unpacked.is_empty():
						for unpacked_channel: String in unpacked:
							(job["written"] as Dictionary)[unpacked_channel] = unpacked[unpacked_channel]
					elif download.get("unpack", {}).is_empty():
						(job["written"] as Dictionary)[channel] = out_path
					else:
						# An image the recipe said was packed, that could not be
						# split. Registering it under its holding name would put
						# an interleaved image into a single-channel slot, so it
						# is reported instead.
						push_warning(
							"[Tile Studio] '%s' is declared as a packed image but could not be unpacked; no channel was assigned from it"
							% channel
						)
				else:
					push_warning("[Tile Studio] could not write %s" % out_path)
			else:
				push_warning("[Tile Studio] download failed for channel '%s' (result %d, HTTP %d, %d bytes) from %s" % [
					channel, result, code, body.size(), base_url() + "/view?" + query
				])

			job["pending"] = int(job["pending"]) - 1
			if int(job["pending"]) <= 0:
				_finish(job_id)
	)
	var err := request.request(base_url() + "/view?" + query)
	if err != OK:
		request.queue_free.call_deferred()
		job["pending"] = int(job["pending"]) - 1
		if int(job["pending"]) <= 0:
			_finish(job_id)



## The packed-channel layout a recipe declares for one emitted image, if any.
##
## Recipes name it under "unpack", keyed by node id, and either as a single
## layout or as a list parallel to that node's "outputs" entry when the node
## emits a batch:
##
##   "unpack": { "11": { "r": "roughness", "g": "metallic" } }
##
## Returning an empty dictionary means "save this image as it is", which is the
## normal case.
func _unpack_spec(recipe: Dictionary, node_id: String, image_index: int) -> Dictionary:
	var all_specs: Variant = recipe.get("unpack", {})
	if not (all_specs is Dictionary):
		return {}

	var spec: Variant = (all_specs as Dictionary).get(node_id, null)
	if spec is Array:
		var list: Array = spec
		if image_index >= list.size():
			return {}
		spec = list[image_index]
	if spec is Dictionary:
		return spec
	return {}


## Split one packed image into single-channel maps on disk.
##
## Returns { channel_name: path } for what it wrote, or an empty dictionary if
## there was nothing to unpack.
##
## The packed source is DELETED afterwards: leaving it would put a file on disk
## that looks like a channel map but is really three of them interleaved, and
## anything that loaded it would get roughness with metallicity smeared through
## its green channel.
func _unpack_channels(
	packed_path: String,
	spec: Dictionary,
	derived_dir: String
) -> Dictionary:

	if spec.is_empty():
		return {}

	var packed := Image.new()
	if packed.load(ProjectSettings.globalize_path(packed_path)) != OK or packed.is_empty():
		push_warning("[Tile Studio] could not read packed map %s; leaving it as-is" % packed_path)
		return {}
	packed.convert(Image.FORMAT_RGBA8)

	var written := {}
	for component: String in spec:
		var channel := String(spec[component])
		if channel.is_empty() or not GBufferMapSet.CHANNELS.has(channel):
			push_warning("[Tile Studio] unpack names unknown channel '%s'" % channel)
			continue

		var index := _component_index(component)
		if index < 0:
			push_warning("[Tile Studio] unpack names unknown component '%s'" % component)
			continue

		var extracted := Image.create(
			packed.get_width(),
			packed.get_height(),
			false,
			Image.FORMAT_RGBA8
		)
		for y in packed.get_height():
			for x in packed.get_width():
				var value: float = packed.get_pixel(x, y)[index]
				extracted.set_pixel(x, y, Color(value, value, value, 1.0))

		var path := derived_dir.path_join("%s.png" % channel)
		if extracted.save_png(ProjectSettings.globalize_path(path)) == OK:
			written[channel] = path
		else:
			push_warning("[Tile Studio] could not write unpacked channel %s" % path)

	if not written.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(packed_path))

	return written


## Colour component name to its index in a Color.
func _component_index(component: String) -> int:
	match component.to_lower():
		"r", "red":
			return 0
		"g", "green":
			return 1
		"b", "blue":
			return 2
		"a", "alpha":
			return 3
		_:
			return -1


func _finish(job_id: String) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return
	var asset: TileAsset = job["asset"]
	var written: Dictionary = job.get("written", {})

	if written.is_empty():
		_fail(job_id, "Every output download or file write failed; see the warnings above for the per-channel reason")
		return

	# Metadata is merged under keys no real channel can collide with
	# (GBufferMapSet.CHANNELS has no "__" prefixed entries), so plugin.gd can
	# pull it back out before iterating "written" as channel-path pairs.
	if job.has("moge_metrics"):
		written["__moge_metrics"] = job["moge_metrics"]

	var relief_source := String(job["recipe"].get("relief_source", ""))
	if not relief_source.is_empty():
		written["__relief_source"] = relief_source

	job["status"] = "done"
	_emit_main("job_progress", job_id, "Assigning maps", 0.95)
	_jobs.erase(job_id)
	# Assignment happens in the caller (the plugin), which owns the asset,
	# the derived-map pipeline and resource saving.
	_emit_main("job_finished", job_id, asset.asset_id, written)


## Pull the failing node and exception out of a history status block.
func _describe_status_error(status: Dictionary) -> String:
	var parts := PackedStringArray()
	for message: Variant in status.get("messages", []):
		# Each entry is ["execution_error", { ... }] or similar.
		if not (message is Array) or (message as Array).size() < 2:
			continue
		var kind := String((message as Array)[0])
		var data: Variant = (message as Array)[1]
		if not (data is Dictionary):
			continue
		var info: Dictionary = data
		if kind == "execution_error":
			parts.append("node %s (%s): %s: %s" % [
				String(info.get("node_id", "?")),
				String(info.get("node_type", "?")),
				String(info.get("exception_type", "?")),
				String(info.get("exception_message", "")),
			])
		elif kind == "execution_interrupted":
			parts.append("interrupted at node %s" % String(info.get("node_id", "?")))
	if parts.size() == 0:
		return String(status.get("status_str", "unknown"))
	return " | ".join(parts)


func _fail(job_id: String, reason: String) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	var asset_id := ""
	if not job.is_empty():
		asset_id = (job["asset"] as TileAsset).asset_id
	_jobs.erase(job_id)
	push_warning("[Tile Studio] analysis job failed: %s" % reason)
	_emit_main("job_failed", job_id, asset_id, reason)


func cancel(job_id: String) -> void:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return
	var prompt_id := String(job.get("prompt_id", ""))
	_jobs.erase(job_id)
	if prompt_id.is_empty() or _host == null:
		return
	var request := _new_request()
	request.request_completed.connect(func(_r: int, _c: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		request.queue_free.call_deferred())
	request.request(
		base_url() + "/interrupt",
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		JSON.stringify({"client_id": _client_id})
	)


func query_status(job_id: String) -> String:
	var job: Dictionary = _jobs.get(job_id, {})
	if job.is_empty():
		return "idle"
	return String(job.get("status", "unknown"))


func active_job_count() -> int:
	return _jobs.size()
