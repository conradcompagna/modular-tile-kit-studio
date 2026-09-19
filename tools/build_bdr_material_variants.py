"""Retexture the untouched restored geology without changing a single geometry byte."""
from pathlib import Path
import hashlib
import io
import json
import struct
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/blackridge_depths_revision'
OUT=ROOT/'exports/blackridge_depths_revision'
poses=json.loads((ROOT/'reports/blackridge_depths/restored_native_prop_transforms.json').read_text())


# Read the canonical glTF document and its binary payload without importing or normalizing the mesh.
def read_glb(path):
    source=path.read_bytes()
    assert source[:4]==b'glTF'
    length,kind=struct.unpack_from('<II',source,12)
    assert kind==0x4e4f534a
    document=json.loads(source[20:20+length])
    offset=20+length
    binary_length,kind=struct.unpack_from('<II',source,offset)
    assert kind==0x004e4942
    return document,bytearray(source[offset+8:offset+8+binary_length])


# Append explicit PBR image data while retaining all source mesh/accessor buffer views verbatim.
def add_texture(document,binary,png,name):
    binary.extend(b'\x00'*((-len(binary))%4))
    view=len(document['bufferViews'])
    document['bufferViews'].append({'buffer':0,'byteOffset':len(binary),'byteLength':len(png)})
    binary.extend(png)
    image=len(document['images'])
    document['images'].append({'bufferView':view,'mimeType':'image/png','name':name})
    texture=len(document['textures'])
    document['textures'].append({'source':image,'sampler':0})
    return texture


# Store a valid glTF container after appending material data; original geometry bytes remain a prefix.
def write_glb(path,document,binary):
    document['buffers'][0]['byteLength']=len(binary)
    metadata=json.dumps(document,separators=(',',':')).encode()
    metadata+=b' '*((-len(metadata))%4)
    binary.extend(b'\x00'*((-len(binary))%4))
    path.write_bytes(struct.pack('<III',0x46546c67,2,12+8+len(metadata)+8+len(binary))+
                    struct.pack('<II',len(metadata),0x4e4f534a)+metadata+
                    struct.pack('<II',len(binary),0x004e4942)+binary)


channels=ART/'bdr_wall_source_chord'
albedo=(channels/'albedo.png').read_bytes()
normal=(channels/'normal.png').read_bytes()
rough=np.asarray(Image.open(channels/'roughness.png').convert('L'))
metal=np.asarray(Image.open(channels/'metallic.png').convert('L'))
packed=Image.fromarray(np.stack([np.full_like(rough,255),rough,metal],axis=-1))
stream=io.BytesIO();packed.save(stream,format='PNG')
kit={};evidence=[]
for index in [0,1,6,15,28]:
    record=next(r for r in poses if r['index']==index)
    old_id=record['asset']; new_id=old_id.replace('BD_','BDR_',1)
    source=ROOT/record['path'].replace('res://','')
    document,binary=read_glb(source)
    original_binary=bytes(binary)
    geometry_views={a['bufferView'] for a in document['accessors'] if 'bufferView' in a}
    geometry_hash=hashlib.sha256(b''.join(bytes(binary[v.get('byteOffset',0):v.get('byteOffset',0)+v['byteLength']]) for i,v in enumerate(document['bufferViews']) if i in geometry_views)).hexdigest()
    base_index=add_texture(document,binary,albedo,'BDR mineral limestone albedo')
    normal_index=add_texture(document,binary,normal,'BDR mineral limestone normal')
    orm_index=add_texture(document,binary,stream.getvalue(),'BDR mineral limestone roughness metal')
    for material in document['materials']:
        material['name']='BDR damp mineral cleavage'
        material['normalTexture']={'index':normal_index,'scale':1.0}
        material['pbrMetallicRoughness']={'baseColorTexture':{'index':base_index},'baseColorFactor':[1,1,1,1],
                                        'metallicRoughnessTexture':{'index':orm_index},'metallicFactor':0,'roughnessFactor':1}
    name=new_id.lower();destination=ART/(name+'.glb')
    write_glb(destination,document,binary)
    assert bytes(binary[:len(original_binary)])==original_binary
    kit[name]={'asset_id':new_id,'path':str(destination),'grid':record['grid_bounds'],'original_asset':old_id,'axis':0}
    evidence.append({'asset':new_id,'canonical_source':record['path'],'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
                     'variant_sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),'geometry_sha256':geometry_hash,
                     'all_geometry_buffer_views_unchanged':True,'original_binary_prefix_unchanged':True})
(OUT/'kit.json').write_text(json.dumps(kit,indent=2)+'\n')
(OUT/'material_variant_provenance.json').write_text(json.dumps(evidence,indent=2)+'\n')
print(json.dumps({'variants':len(kit),'all_original_geometry_bytes_preserved':True}))
