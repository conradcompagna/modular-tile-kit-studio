"""Run the project's existing CHORD recipe against one authored Depths material."""
from pathlib import Path
import json
import sys
import time
import urllib.parse
import requests

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'assets/blackridge_depths'/sys.argv[1]
SERVER='http://127.0.0.1:8188'
OUT=SOURCE.parent/(SOURCE.stem+'_chord')
OUT.mkdir(exist_ok=True)
with SOURCE.open('rb') as image:
    response=requests.post(SERVER+'/upload/image',files={'image':(SOURCE.name,image,'image/png')},data={'overwrite':'true'},timeout=60)
response.raise_for_status()
upload=response.json()
workflow=json.loads((ROOT/'addons/modular_tile_studio/analysis/recipes/chord_material_api.json').read_text())
workflow['1']['inputs']['image']=upload['name']
for key in ('10','11','12','13'):
    workflow[key]['inputs']['filename_prefix']='mts/blackridge_depths_'+SOURCE.stem+'_'+key
response=requests.post(SERVER+'/prompt',json={'prompt':workflow,'client_id':'blackridge_depths_chord'},timeout=60)
response.raise_for_status()
job=response.json()['prompt_id']
(OUT/'job.json').write_text(json.dumps({'prompt_id':job,'source':str(SOURCE),'workflow':workflow},indent=2))
print('CHORD_SUBMITTED '+job,flush=True)
while True:
    history=requests.get(SERVER+'/history/'+job,timeout=30).json()
    if job in history:
        result=history[job]
        (OUT/'result.json').write_text(json.dumps(result,indent=2))
        if result.get('status',{}).get('status_str')=='error':
            raise RuntimeError(result['status'])
        for node,channel in [('10','albedo'),('11','normal'),('12','roughness'),('13','metallic')]:
            item=result['outputs'][node]['images'][0]
            response=requests.get(SERVER+'/view?'+urllib.parse.urlencode(item),timeout=60)
            response.raise_for_status()
            (OUT/(channel+'.png')).write_bytes(response.content)
        print('CHORD_COMPLETE '+str(OUT),flush=True)
        break
    time.sleep(5)

