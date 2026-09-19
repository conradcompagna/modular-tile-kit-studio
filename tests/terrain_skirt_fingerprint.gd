extends SceneTree

## Deterministic fingerprint of every canonical terrain face, plus enumeration timing.
##
## This exists to prove that a performance change to the skirt builder leaves the
## emitted face set bit-identical. Paint is addressed by face UID, and
## BoardDocument.prune_orphaned_terrain_paint() PERMANENTLY releases authored paint
## whose UID is absent from terrain_faces(). Any drift in this fingerprint is
## therefore silent loss of authored material, not a cosmetic difference.
##
## Run against two builds and compare FINGERPRINT; it must be identical.


## Defer the checks until global script classes are available to the SceneTree.
func _init() -> void:
	_run.call_deferred()


## Build one deliberately awkward terrain that exercises every skirt branch.
##
## A plain filled rectangle only ever hits the simple full-edge skirt case. The
## interior hole produces interior boundary edges, the explicit steps force real
## walls between neighbours, and the deep relief makes bands_in_span() emit many
## bands per boundary edge -- which is exactly the shape of an imported map.
func _fixture() -> TerrainMesh:
	var origin := Vector2i(-3, -2)
	var size := Vector2i(12, 10)
	var terrain := TerrainMesh.create(origin, size)
	for z: int in size.y:
		for x: int in size.x:
			terrain.set_cell_filled(origin + Vector2i(x, z), true)
	# An interior hole creates boundary edges that a rectangular fixture misses.
	for z: int in range(3, 6):
		for x: int in range(4, 7):
			terrain.set_cell_filled(origin + Vector2i(x, z), false)
	for z: int in size.y:
		for x: int in size.x:
			var cell := origin + Vector2i(x, z)
			if not terrain.is_cell_filled(cell):
				continue
			terrain.set_cell_top_level(
				cell,
				sin(float(x) * 0.7) * 3.0 + cos(float(z) * 0.5) * 2.5
			)
	# Two adjacent cells forced far apart so a tall real wall exists between them.
	terrain.set_cell_top_level(origin + Vector2i(5, 1), 7.25)
	terrain.set_cell_top_level(origin + Vector2i(6, 1), -4.5)
	# One saddle cell, whose diagonal is stored rather than re-derived.
	terrain.set_cell_top(
		origin + Vector2i(2, 7),
		PackedFloat32Array([0.0, 3.0, 3.0, 0.0])
	)
	terrain.skirt_depth_m = 2.5
	return terrain


## Build a larger irregular terrain used only to time full-board enumeration.
func _timing_fixture(side: int) -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i.ZERO, Vector2i(side, side))
	for z: int in side:
		for x: int in side:
			terrain.set_cell_filled(Vector2i(x, z), true)
	# A ragged boundary, because skirt cost scales with perimeter.
	for z: int in side:
		for x: int in side:
			if (x * x + z * z) % 37 == 0:
				terrain.set_cell_filled(Vector2i(x, z), false)
	for z: int in side:
		for x: int in side:
			var cell := Vector2i(x, z)
			if not terrain.is_cell_filled(cell):
				continue
			terrain.set_cell_top_level(
				cell,
				sin(float(x) * 0.3) * 8.0 + cos(float(z) * 0.4) * 6.0
			)
	terrain.skirt_depth_m = 3.0
	return terrain


## Serialize one face at a precision that exposes any float drift.
func _face_line(face: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append("kind=%d" % int(face["kind"]))
	parts.append("uid=%s" % String(face["paint_uid"]))
	parts.append("cell=%s" % str(face["cell"]))
	parts.append("edge=%d" % int(face["edge"]))
	parts.append("band=%d" % int(face["band"]))
	parts.append("grid=%s" % str(face["grid_cell"]))
	parts.append("face=%d" % int(face["face"]))
	if face.has("diagonal"):
		parts.append("diag=%d" % int(face["diagonal"]))
	for key: String in ["bottom_m", "top_m", "start_t", "end_t"]:
		if face.has(key):
			parts.append("%s=%.9f" % [key, float(face[key])])
	var geometry: PackedVector3Array = (
		face["quad"] if face.has("quad") else face["polygon"]
	)
	for point: Vector3 in geometry:
		parts.append("(%.9f,%.9f,%.9f)" % [point.x, point.y, point.z])
	return "|".join(parts)


## Print the sorted face fingerprint and the enumeration cost.
func _run() -> void:
	var terrain := _fixture()
	var faces := terrain.terrain_faces(8)
	var lines := PackedStringArray()
	var counts := {0: 0, 1: 0, 2: 0}
	for face: Dictionary in faces:
		lines.append(_face_line(face))
		var kind := int(face["kind"])
		counts[kind] = int(counts[kind]) + 1
	lines.sort()
	print("FACE_COUNT=%d" % faces.size())
	print("TOP=%d SIDE=%d SKIRT=%d" % [counts[0], counts[1], counts[2]])
	print("SKIRT_BASE=%.9f" % terrain.skirt_base_m)
	print("FINGERPRINT=%s" % "\n".join(lines).sha256_text())

	var side := 80
	var timing_terrain := _timing_fixture(side)
	var started := Time.get_ticks_usec()
	for _pass: int in 5:
		timing_terrain.terrain_faces(8)
	var elapsed := Time.get_ticks_usec() - started
	print("TIMING_SIDE=%d" % side)
	print("ENUMERATE_5X_USEC=%d" % elapsed)
	print("ENUMERATE_1X_MS=%.2f" % (float(elapsed) / 5000.0))
	quit()
