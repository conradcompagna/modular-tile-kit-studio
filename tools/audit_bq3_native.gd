@tool
extends RefCounted

## Measure every final source through its native pose for visible contact and light clearance auditing.
func run() -> Dictionary:
	var p: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge",true,false).plugin
	var board: BoardDocument = p.board
	var canonicalizer: Variant = GLBAssetImporter.new().canonicalizer
	var result: Array[Dictionary] = []
	for prop: PropPlacement in board.props:
		var asset: TileAsset = board.resolve_prop_asset(prop)
		var packed: PackedScene = ResourceLoader.load(asset.prop_model_path(),"PackedScene",ResourceLoader.CACHE_MODE_REPLACE)
		if packed == null:
			return {"ok":false,"missing":asset.prop_model_path()}
		var scene: Node3D = packed.instantiate()
		var source_bounds: AABB = canonicalizer.compute_bounds(scene)
		scene.free()
		var world_pose: Transform3D = Transform3D(Basis.IDENTITY,board.prop_world_origin(prop))*prop.orientation_transform(asset)*asset.prop_pose_transform
		var bounds: AABB = world_pose*source_bounds
		result.append({"id":prop.asset_id,"source":asset.prop_model_path(),"origin":str(prop.origin),"world_bounds":str(bounds),"pose":[_xyz(world_pose.basis.x),_xyz(world_pose.basis.y),_xyz(world_pose.basis.z),_xyz(world_pose.origin)],"voxels":asset.prop_voxels.size()})
	var report: Dictionary = {"ok":true,"props":result,"lighting":board.lighting.to_json()}
	var file := FileAccess.open("res://exports/blackridge_quarantine_revision03/native_contact_measurements.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	return {"ok":true,"measured_props":result.size()}

## Preserve native vector values as numeric arrays rather than lossy diagnostic strings.
func _xyz(value: Vector3) -> Array:
	return [value.x,value.y,value.z]
