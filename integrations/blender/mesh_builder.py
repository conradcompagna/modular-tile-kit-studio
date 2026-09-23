"""Construct output meshes and their authoring attributes."""
import bpy

def create_mesh_object(context, source_obj, name, vertices, faces, metadata):
    mesh = bpy.data.meshes.new(name + "_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()

    new_obj = bpy.data.objects.new(name, mesh)
    collection = source_obj.users_collection[0] if source_obj.users_collection else context.collection
    collection.objects.link(new_obj)

    # New Blender objects start with an identity transform, and the generated
    # vertex coordinates are already in world space.

    # Face attributes are intentionally simple and game-pipeline-friendly.
    if len(mesh.polygons) == len(metadata):
        attr_x = mesh.attributes.new("hf_grid_x", type='INT', domain='FACE')
        attr_y = mesh.attributes.new("hf_grid_y", type='INT', domain='FACE')
        attr_height = mesh.attributes.new("hf_height_m", type='FLOAT', domain='FACE')
        attr_kind = mesh.attributes.new("hf_face_kind", type='INT', domain='FACE')
        attr_band = mesh.attributes.new("hf_band_index", type='INT', domain='FACE')
        attr_smooth_e = mesh.attributes.new("hf_smooth_east", type='BOOLEAN', domain='FACE')
        attr_smooth_n = mesh.attributes.new("hf_smooth_north", type='BOOLEAN', domain='FACE')

        for i, meta in enumerate(metadata):
            attr_x.data[i].value = meta["grid_x"]
            attr_y.data[i].value = meta["grid_y"]
            attr_height.data[i].value = meta["height_m"]
            attr_kind.data[i].value = meta["kind"]
            attr_band.data[i].value = meta["band_index"]
            attr_smooth_e.data[i].value = bool(meta.get("smooth_east", False))
            attr_smooth_n.data[i].value = bool(meta.get("smooth_north", False))

    return new_obj
