"""Blender sidebar controls for conversion and touch-up."""
from .conversion import OBJECT_OT_convert_grid_heightfield
from .height_brush import OBJECT_OT_heightfield_height_brush
from .slope_brush import OBJECT_OT_heightfield_slope_brush
from bpy.types import Panel
from .edit_model import hf_has_edit_attributes

class VIEW3D_PT_grid_heightfield(Panel):
    bl_label = "Grid Heightfield"
    bl_idname = "VIEW3D_PT_grid_heightfield"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Heightfield"

    def draw(self, context):
        layout = self.layout
        settings = context.scene.hf_settings
        obj = context.active_object

        if obj is None or obj.type != 'MESH':
            box = layout.box()
            box.label(text="Select a mesh object.", icon='INFO')
        else:
            box = layout.box()
            box.label(text=f"Source: {obj.name}", icon='MESH_DATA')
            box.label(text="Sampling axis: World -Z")

        layout.prop(settings, "output_mode")
        layout.prop(settings, "grid_size_m")

        snap_box = layout.box()
        snap_box.prop(settings, "snap_height")
        if settings.snap_height:
            snap_box.prop(settings, "height_step_m")
            snap_box.prop(settings, "height_snap_mode")

        if settings.output_mode == 'STEPPED':
            wall_box = layout.box()
            wall_box.label(text="Stepped Geometry")
            wall_box.prop(settings, "create_step_walls")
            if settings.create_step_walls and settings.snap_height:
                wall_box.prop(settings, "band_step_walls")

            smooth_box = layout.box()
            smooth_box.label(text="Connected Second Pass")
            smooth_box.prop(settings, "smooth_low_transitions")
            if settings.smooth_low_transitions:
                smooth_box.prop(settings, "smooth_threshold_m")
                smooth_box.prop(settings, "smooth_threshold_basis")
                if settings.snap_height and settings.smooth_threshold_basis == 'SOURCE':
                    smooth_box.label(
                        text="Original Samples can smooth below the snap step.",
                        icon='INFO',
                    )

            wall_box.prop(settings, "boundary_skirt")
            if settings.boundary_skirt:
                wall_box.prop(settings, "boundary_base_mode")
                if settings.boundary_base_mode == 'CUSTOM':
                    wall_box.prop(settings, "boundary_base_m")

        align_box = layout.box()
        align_box.label(text="Grid Alignment")
        align_box.prop(settings, "grid_origin_x_m")
        align_box.prop(settings, "grid_origin_y_m")
        if settings.snap_height:
            align_box.prop(settings, "height_origin_m")

        options = layout.box()
        options.label(text="Options")
        options.prop(settings, "include_modifiers")
        options.prop(settings, "respect_scene_units")
        options.prop(settings, "hide_source")
        options.prop(settings, "max_cells")

        scale = context.scene.unit_settings.scale_length
        options.label(text=f"Scene Unit Scale: {scale:g}")

        layout.separator()
        layout.operator(
            OBJECT_OT_convert_grid_heightfield.bl_idname,
            icon='MOD_REMESH',
        )

        manual = layout.box()
        manual.label(text="Manual Touch-up")
        manual.prop(settings, "manual_brush_show_outline")

        slope = manual.box()
        slope.label(text="Slope Brush")
        slope.prop(settings, "slope_brush_radius_m")
        slope_col = slope.column()
        slope_col.enabled = hf_has_edit_attributes(obj)
        slope_col.operator(
            OBJECT_OT_heightfield_slope_brush.bl_idname,
            icon='BRUSH_DATA',
        )
        slope.label(text="Paint stair edges into connected slopes.")

        height = manual.box()
        height.label(text="Raise / Lower Brush")
        height.prop(settings, "height_brush_action", expand=True)
        height.prop(settings, "height_brush_increment_m")
        height.prop(settings, "height_brush_radius_cells")
        height_col = height.column()
        height_col.enabled = hf_has_edit_attributes(obj)
        height_col.operator(
            OBJECT_OT_heightfield_height_brush.bl_idname,
            icon='SCULPTMODE_HLT',
        )
        height.label(text="LMB uses action; Ctrl+LMB inverts it.")

        if not hf_has_edit_attributes(obj):
            manual.label(
                text="Select a generated heightfield to enable brushes.",
                icon='INFO',
            )
