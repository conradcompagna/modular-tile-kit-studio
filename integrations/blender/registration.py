"""Register and unregister the add-on components."""
from .settings import HF_Settings
from .conversion import OBJECT_OT_convert_grid_heightfield
from .height_brush import OBJECT_OT_heightfield_height_brush
from .slope_brush import OBJECT_OT_heightfield_slope_brush
from bpy.props import PointerProperty
from .panels import VIEW3D_PT_grid_heightfield
import bpy

classes = (
    HF_Settings,
    OBJECT_OT_convert_grid_heightfield,
    OBJECT_OT_heightfield_slope_brush,
    OBJECT_OT_heightfield_height_brush,
    VIEW3D_PT_grid_heightfield,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.hf_settings = PointerProperty(type=HF_Settings)


def unregister():
    if hasattr(bpy.types.Scene, "hf_settings"):
        del bpy.types.Scene.hf_settings
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
