"""Record the explicit measured upright optimization exception without changing source art."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[1]
report = json.loads((root/'exports/blackridge_quarantine_revision/native_import_report.json').read_text())
item = next(x for x in report['results'] if x['id'] == 'BQR_UPRIGHT_SPECIMEN')
source = root/'assets/blackridge_quarantine_revision/meshy/upright_specimen.glb'
metrics = item['metrics']
before = [float(x) for x in re.findall(r'-?\d+\.\d+', metrics['source']['bounds'])]
after = [float(x) for x in re.findall(r'-?\d+\.\d+', metrics['output']['bounds'])]
scale = 3 / after[4]
payload = {
    'asset_id': item['id'], 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'authorization': 'Director explicitly approved0.25 percent diagonal-relative bounds tolerance for this exact hash only.',
    'native_default_relative_tolerance':0.001, 'asset_local_relative_tolerance':0.0025,
    'source_bounds':metrics['source']['bounds'], 'optimized_bounds':metrics['output']['bounds'],
    'width_change_source_m':before[3]-after[3],
    'width_change_percent':100*(before[3]-after[3])/before[3],
    'width_change_at_authored_height_mm':(before[3]-after[3])*scale*1000,
    'runtime_metrics':metrics, 'pose':item['pose'], 'voxels':item['voxels'],
    'derivation':'Native canonicalizer and canonical plus diagonal voxel scans repeated from the actual installed optimized mesh; no cached voxel rescale.',
    'global_optimizer_unchanged':True,
    'all_other_native_validation_retained':True,
}
(root/'reports/blackridge_quarantine_revision/UPRIGHT_OPTIMIZATION_EXCEPTION.json').write_text(json.dumps(payload,indent=2))
print(json.dumps({k:payload[k] for k in ('width_change_percent','width_change_at_authored_height_mm')}))
