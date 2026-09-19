@tool
extends "res://addons/modular_tile_studio/importers/glb_runtime_optimizer.gd"

const UPRIGHT_SHA256 := "d05104e8d87704283093fb3970bed025519b7d5fd1de02d898c4ce37ce1ee232"

## Apply the director-approved millimetre bounds exception only to the measured upright source hash.
func build_from_source(source_path: String, output_path: String, target_ratio: float, texture_size_limit: int) -> Dictionary:
	if FileAccess.get_sha256(source_path) != UPRIGHT_SHA256:
		return {"ok":false,"error":"BQR upright exception rejected an unrecognized source hash."}
	return super.build_from_source(source_path, output_path, target_ratio, texture_size_limit)

## Permit at most 0.25 percent diagonal-relative drift while retaining every native surface, UV, material and triangle check.
func _bounds_match(source: AABB, output: AABB) -> bool:
	var tolerance: float = maxf(source.size.length(),0.001) * 0.0025
	return source.position.distance_to(output.position) <= tolerance and source.size.distance_to(output.size) <= tolerance
