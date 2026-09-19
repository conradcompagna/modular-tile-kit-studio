@tool
extends SceneTree
## Execute the real import + render path so runtime errors surface, not just parse errors.
func _init() -> void:
	var imp := TerrainGLBImporter.new()
	var r := imp.read("C:/Users/conra/Downloads/mesh_node_heightfield.glb")
	if not bool(r.get("ok", false)):
		print("FAIL import: ", r.get("error","")); quit(1); return
	var terrain := r["terrain"] as TerrainMesh
	print("cells=", terrain.size_cells, " filled=", int(r.get("filled_cells",0)),
		" walls=", int(r.get("wall_count",0)))
	# Exercise exactly what the plugin does after a successful read.
	var board := BoardDocument.new()
	board.terrain = terrain
	var rend := MTSTerrainRenderer.new()
	# Terrain renders as one mesh per paint chunk, so the whole surface is walked
	# rather than a single instance.
	if not rend.rebuild(board.terrain, 8, null):
		print("FAIL rebuild"); rend.free(); quit(1); return
	var vert := 0
	var tris := 0
	var lo := INF; var hi := -INF
	for inst: MeshInstance3D in rend.chunk_instances():
		var m := inst.mesh as ArrayMesh
		if m == null:
			continue
		for s in m.get_surface_count():
			var v := m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array
			for t in v.size()/3:
				tris += 1
				var A := v[t*3]; var B := v[t*3+1]; var C := v[t*3+2]
				for P in [A,B,C]:
					lo = minf(lo,P.y); hi = maxf(hi,P.y)
				var nr := (B-A).cross(C-A)
				if nr.length_squared() > 0.0 and absf(nr.normalized().y) < 0.1:
					vert += 1
	print("RENDERED chunks=", rend.chunks().size(), " tris=", tris,
		" VERTICAL=", vert, " Y=", lo, "..", hi)
	# Save/load round trip, the other runtime path.
	var back := BoardDocument.new()
	var err := back.from_json(board.to_json())
	print("roundtrip err=", err, " walls=", back.terrain.side_face_records().size())
	rend.free()
	print("IMPORT PATH OK")
	quit(0)
