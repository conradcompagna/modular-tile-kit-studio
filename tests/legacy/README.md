# Archived blockout fixtures

These two scripts predate the canonical `TerrainMesh` heightfield and still
reference deleted `BlockoutSlot`, `SurfaceBoxPlacement`, and `floor_levels` APIs.
They are retained as historical design evidence and are not runnable regression
tests for the current editor.

Current coverage lives in `terrain_heightfield_check.gd`,
`prop_contact_regression_check.gd`, `material_tile_targeting_check.gd`,
`material_paint_viewport_check.gd`, and `placement_viewport_check.gd` in the parent
directory; board serialization and reload coverage is in `board_document_check.gd`.
