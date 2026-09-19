"""Commission the three approved quarantine specimens through Meshy without exposing the existing credential."""
import base64
import json
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / 'assets/blackridge_quarantine_revision/meshy'
KEY_PATH = Path('C:/Users/conra/Desktop/blackledger/.secrets/meshy_api_key.txt')
NAMES = ('upright_specimen', 'occult_table', 'suspended_husk')


# Send the credential only in the authorization header to Meshy's documented API origin.
def request(path, payload=None):
    key = KEY_PATH.read_text().strip()
    headers = {'Authorization': 'Bearer ' + key}
    body = None
    if payload is not None:
        headers['Content-Type'] = 'application/json'
        body = json.dumps(payload).encode()
    try:
        with urlopen(Request('https://api.meshy.ai/openapi/v1/' + path, data=body, headers=headers), timeout=90) as response:
            return json.load(response)
    except HTTPError as error:
        message = error.read().decode().replace(key, '[REDACTED]')
        raise RuntimeError(f'Meshy HTTP {error.code}: {message[:500]}') from None


# Store a local submission record before creating a paid task so reruns cannot silently duplicate it.
def main():
    action, name = sys.argv[1:3]
    if name not in NAMES:
        raise ValueError('Unknown commissioned asset name.')
    state_path = ART / (name + '_meshy.json')
    if action == 'submit':
        source = ART / (name + '_reference.png')
        payload = {'image_url': 'data:image/png;base64,' + base64.b64encode(source.read_bytes()).decode(),
                   'ai_model': 'meshy-7', 'ultra_mode': False, 'should_texture': True,
                   'enable_pbr': True, 'texture_resolution': '4k', 'should_remesh': True,
                   'target_polycount': 150000, 'topology': 'triangle', 'image_enhancement': False,
                   'target_formats': ['glb']}
        state = {'name': name, 'status': 'SUBMITTING', 'input': source.name,
                 'parameters': {k: v for k, v in payload.items() if k != 'image_url'}}
        with state_path.open('x') as output:
            json.dump(state, output, indent=2)
        result = request('image-to-3d', payload)
        state.update(task_id=result['result'], status='PENDING')
    elif action == 'status':
        state = json.loads(state_path.read_text())
        result = request('image-to-3d/' + state['task_id'])
        state.update({key: result.get(key) for key in ('status', 'progress', 'consumed_credits', 'task_error')})
        if result['status'] == 'SUCCEEDED':
            for suffix, url in [('glb', result['model_urls']['glb']), ('preview.png', result['thumbnail_url'])]:
                output = ART / (name + '.' + suffix)
                if not output.exists():
                    with urlopen(url, timeout=120) as response:
                        temporary = output.with_suffix(output.suffix + '.part')
                        temporary.write_bytes(response.read())
                        temporary.replace(output)
                state[suffix] = str(output.relative_to(ROOT))
    else:
        raise ValueError('Use submit or status.')
    state_path.write_text(json.dumps(state, indent=2))
    print(json.dumps(state))


if __name__ == '__main__':
    main()

