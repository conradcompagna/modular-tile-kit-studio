@tool
extends RefCounted

## Mutations behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Add one surface placement and index it according to its render role.
##
## Indexing is delegated so terrain paint, native decals, and shader decals are
## each recorded exactly once, in one place. These paths previously inlined the
## paint index themselves, which is how a second placement kind would silently
## have gone unindexed.
static func add_surface(host: BoardDocument, placement: SurfacePlacement) -> void:
	host.surfaces.append(placement)
	host._index_spatial_placement(placement)
	host.board_changed.emit()


## Remove one surface placement and release whatever index it held.
static func remove_surface(host: BoardDocument, placement: SurfacePlacement) -> void:
	var index := host.surfaces.find(placement)
	if index < 0:
		return
	host.surfaces.remove_at(index)
	host._unindex_spatial_placement(placement)
	host.board_changed.emit()


## Add multiple surfaces while updating indexes and emitting once.
static func add_surfaces_bulk(host: BoardDocument, placements: Array[SurfacePlacement]) -> void:
	if placements.is_empty():
		return
	for placement: SurfacePlacement in placements:
		host.surfaces.append(placement)
		host._index_spatial_placement(placement)
	host.board_changed.emit()


## Remove multiple surfaces while updating indexes and emitting once.
static func remove_surfaces_bulk(host: BoardDocument, placements: Array[SurfacePlacement]) -> void:
	if placements.is_empty():
		return
	var changed := false
	for placement: SurfacePlacement in placements:
		var index := host.surfaces.find(placement)
		if index < 0:
			continue
		changed = true
		host.surfaces.remove_at(index)
		host._unindex_spatial_placement(placement)
	if changed:
		host.board_changed.emit()


## Atomically replace selected structural surfaces with new surface placements.
##
## The next surface list is assembled and indexed before observers are notified,
## so the viewport never rebuilds from the temporary state with its conflicts
## removed but no replacement surfaces added.
static func replace_surfaces_bulk(host: BoardDocument,
	displaced: Array[SurfacePlacement],
	replacements: Array[SurfacePlacement]
) -> void:
	if displaced.is_empty() and replacements.is_empty():
		return
	for placement: SurfacePlacement in displaced:
		if not host.surfaces.has(placement):
			push_error(
				"[Tile Studio] cannot replace a surface that is no longer on the board."
			)
			return
	var next_surfaces: Array[SurfacePlacement] = []
	next_surfaces.append_array(host.surfaces)
	for placement: SurfacePlacement in displaced:
		next_surfaces.erase(placement)
	next_surfaces.append_array(replacements)
	host.surfaces = next_surfaces
	host.rebuild_indexes()
	host.board_changed.emit()


## Add one prop and update its canonical solid occupancy.
static func add_prop(host: BoardDocument, placement: PropPlacement) -> void:
	host.props.append(placement)
	host._index_spatial_placement(placement)
	host.board_changed.emit()


## Remove one prop and release its canonical solid occupancy.
static func remove_prop(host: BoardDocument, placement: PropPlacement) -> void:
	var index := host.props.find(placement)
	if index < 0:
		return
	host._unindex_spatial_placement(placement)
	host.props.remove_at(index)
	host.board_changed.emit()


## Add multiple props while updating canonical occupancy and emitting once.
##
## Fill commits use this path so placing hundreds of GLBs produces one document
## notification and one viewport synchronization rather than one rebuild per prop.
static func add_props_bulk(host: BoardDocument, placements: Array[PropPlacement]) -> void:
	if placements.is_empty():
		return
	for placement: PropPlacement in placements:
		host.props.append(placement)
		host._index_spatial_placement(placement)
	host.board_changed.emit()


## Remove multiple props while releasing canonical occupancy and emitting once.
##
## Undo uses the identical placement resources added by add_props_bulk, which
## keeps resource identity and occupancy provenance explicit.
static func remove_props_bulk(host: BoardDocument, placements: Array[PropPlacement]) -> void:
	if placements.is_empty():
		return
	var changed := false
	for placement: PropPlacement in placements:
		var index := host.props.find(placement)
		if index < 0:
			continue
		changed = true
		host._unindex_spatial_placement(placement)
		host.props.remove_at(index)
	if changed:
		host.board_changed.emit()


## Atomically replace selected props with new prop placements.
##
## Rebuilding indexes from the completed next list prevents observers from ever
## seeing a half-replaced prop volume or a stale occupancy entry.
static func replace_props_bulk(host: BoardDocument,
	displaced: Array[PropPlacement],
	replacements: Array[PropPlacement]
) -> void:
	if displaced.is_empty() and replacements.is_empty():
		return
	for placement: PropPlacement in displaced:
		if not host.props.has(placement):
			push_error(
				"[Tile Studio] cannot replace a prop that is no longer on the board."
			)
			return
	for placement: PropPlacement in displaced:
		host._unindex_spatial_placement(placement)
		host.props.erase(placement)
	for placement: PropPlacement in replacements:
		host.props.append(placement)
		host._index_spatial_placement(placement)
	host.board_changed.emit()
