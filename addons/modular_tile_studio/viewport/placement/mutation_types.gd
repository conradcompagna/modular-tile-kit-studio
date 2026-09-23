@tool
extends RefCounted

## Mutation types behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Return the exact placement-category mask represented by canonical resources.
static func _mutation_mask_for_resources(host: MTSPlacementController, resources: Array[Resource]) -> int:
	var mutation_mask := 0
	for resource: Resource in resources:
		if resource is SurfacePlacement:
			mutation_mask |= MTSPlacementController.BoardMutation.SURFACES
		elif resource is PropPlacement:
			mutation_mask |= MTSPlacementController.BoardMutation.PROPS
		else:
			push_error("[Tile Studio] cannot classify an unsupported placement mutation.")
	return mutation_mask
