"""Freeze concise artifact provenance for the canonical Quarantine revision without altering artwork."""
from pathlib import Path
import hashlib
import json

root=Path(__file__).resolve().parents[1]
out=root/'reports/blackridge_quarantine_revision'
board_path=root/'boards/blackridge_quarantine.json'
board=json.loads(board_path.read_text())
validation=json.loads((out/'runtime_validation_02.json').read_text())
imports=json.loads((root/'exports/blackridge_quarantine_revision/native_import_report.json').read_text())
captures=[{'path':str(p.relative_to(root)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted((root/'captures/blackridge_quarantine_revision').glob('*_02.png'))]
receipt_paths=sorted((root/'assets/blackridge_quarantine_revision/meshy').glob('*_meshy.json'))
record={'board':'res://boards/blackridge_quarantine.json','canonical_sha256':hashlib.sha256(board_path.read_bytes()).hexdigest(),
        'native_import_status':imports['status'],'props':len(board['props']),'filled_one_metre_cells':sum(board['terrain']['cell_mask']),
        'runtime_validation':'reports/blackridge_quarantine_revision/runtime_validation_02.json','runtime_failures':validation['failures'],
        'captures':captures,'paid_meshy_jobs':3,'mesh_generation_credits':90,'ultra_mode':False,
        'chord_materials':['exterior_brick','city_setts','lime_plaster'],'chord_channels':['albedo','normal','roughness','metallic'],
        'optimized_meshes':[{'id':x['id'],'triangles':x['metrics']['output']['triangles'],'texture_cap':x['metrics']['output']['texture_max_dimension'],'path':x['runtime_path']} for x in imports['results'] if x.get('metrics')],
        'bounds_exception':'reports/blackridge_quarantine_revision/UPRIGHT_OPTIMIZATION_EXCEPTION.json',
        'support_and_light_audit':'reports/blackridge_quarantine_revision/SPECIMEN_CONTACT_AUDIT.json',
        'prior_original_board':'exports/blackridge_quarantine_revision/board_before_revision.json',
        'final_frozen_board':'exports/blackridge_quarantine_revision/board_runtime02_frozen.json',
        'independent_review':'Final critic reassessment pending; runtime01 conditional score8.065/10 returned only sign occlusion.',
        'shared_bw_or_global_renderer_changes':False}
(out/'FINAL_HANDOFF.json').write_text(json.dumps(record,indent=2))
source=json.loads((out/'SOURCE_AUDIT.json').read_text())
source['native_install_pending']=False
source['native_final_handoff']='reports/blackridge_quarantine_revision/FINAL_HANDOFF.json'
(out/'SOURCE_AUDIT.json').write_text(json.dumps(source,indent=2))
print(json.dumps({'captures':len(captures),'canonical_sha256':record['canonical_sha256'],'failures':record['runtime_failures']}))
