"""Refine only BQ-owned focal materials and add grounded papers to its checkpoint."""
from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
recipe_path = ROOT / 'tools/build_blackridge_quarantine_kit.py'
exec(compile(recipe_path.read_text().split('# The prison gate is a load-bearing arch')[0], str(recipe_path), 'exec'))
backup = OUT / 'pass03_source_checkpoint'
backup.mkdir(exist_ok=True)
cloth = material('BQ aged institutional cloth', (.20,.025,.03), ROOT/'assets/blackridge_intake/authority_banner_chord/albedo.png')
notice = material('BQ worn painted warning oak', (.06,.035,.025), ROOT/'assets/angel_gate_blender/wood.png')
paper = material('BQ damp registration forms', (.40,.34,.23), rough=.95)
ink = material('BQ faded registration ink', (.04,.035,.025))


# Preserve the exact existing source pose and geometry while replacing only owned surface materials.
def finish_existing(name):
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    path=BQART/(name+'.glb')
    if not (backup/path.name).exists():
        shutil.copy2(path,backup/path.name)
    bpy.ops.import_scene.gltf(filepath=str(backup/path.name))
    for ob in list(bpy.context.scene.objects):
        if ob.type != 'MESH':
            continue
        for slot in ob.material_slots:
            if slot.material and slot.material.name.startswith('BQ muted oxblood canvas'):
                slot.material=cloth
            if name=='quarantine_notice' and slot.material and slot.material.name.startswith('Deep iron and mortar shadow'):
                slot.material=notice
        # Sample an unlettered worn-cloth region; the BQ physical seal supplies the emblem.
        loops=[li for face in ob.data.polygons if ob.data.materials[face.material_index]==cloth for li in face.loop_indices]
        if loops:
            uv=ob.data.uv_layers.active.data
            u0=min(uv[i].uv.x for i in loops); u1=max(uv[i].uv.x for i in loops)
            v0=min(uv[i].uv.y for i in loops); v1=max(uv[i].uv.y for i in loops)
            for i in loops:
                u,v=uv[i].uv
                uv[i].uv=(.07+.25*(u-u0)/max(.001,u1-u0), .81+.14*(v-v0)/max(.001,v1-v0))
    if name=='registry_kiosk':
        # The original counter top is at 1.38 m after its measured 3.5 m export fit.
        box('Bound intake ledger',(1.30,2.43,1.382),(1.90,2.91,1.45),BLOOD,.006)
        box('Open ledger pages',(1.32,2.45,1.45),(1.88,2.89,1.46),paper,.002)
        for j in range(7):
            box('Ledger ink rows',(1.36,2.49+j*.049,1.461),(1.82,2.495+j*.049,1.465),ink,0,False)
        for j in range(3):
            box('Stacked damp forms',(2.02+j*.025,2.43+j*.028,1.382+j*.012),(2.56+j*.025,2.84+j*.028,1.394+j*.012),paper,.002)
        lathe('Counter ink pot',[(.085,0),(.085,.12),(.06,.15)],(2.62,2.50,1.42),DARK,12)
        beam('Ledger quill',(2.63,2.5,1.52),(2.74,2.47,1.77),.016,BONE)
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)
    PARTS.clear()
    print('BQ_FINISH_SOURCE '+name,flush=True)


for name in ['glass_quarantine_pen','glass_quarantine_pen_breached','quarantine_standard','quarantine_notice','registry_kiosk']:
    finish_existing(name)
