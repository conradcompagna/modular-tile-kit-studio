"""Generate the Angel Gate's commissioned Meshy props without logging credentials."""
import base64
import json
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "assets" / "angel_gate"
KEY_PATH = Path(r"C:\Users\conra\Desktop\blackledger\.secrets\meshy_api_key.txt")


# Read the existing credential only into memory and send it only to Meshy's API.
def request(path, payload=None):
    headers = {"Authorization": "Bearer " + KEY_PATH.read_text().strip()}
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    req = Request("https://api.meshy.ai/openapi/v1/" + path, data=body, headers=headers)
    try:
        with urlopen(req, timeout=60) as response:
            return json.load(response)
    except HTTPError as error:
        raise RuntimeError(f"Meshy HTTP {error.code}: {error.read().decode()[:600]}") from None


# Keep task IDs on disk so repeated status checks cannot commission duplicate jobs.
def main():
    action, name = sys.argv[1:3]
    ART.mkdir(parents=True, exist_ok=True)
    state_path = ART / (name + "_meshy.json")
    if action == "submit":
        if state_path.exists():
            raise RuntimeError("Task already exists; inspect its status instead of resubmitting.")
        image = ART / (name + "_reference.png")
        payload = {
            "image_url": "data:image/png;base64," + base64.b64encode(image.read_bytes()).decode(),
            "ai_model": "meshy-7", "should_texture": True, "enable_pbr": True,
            "texture_resolution": "2k", "should_remesh": True,
            "target_polycount": 120000, "topology": "triangle",
            "image_enhancement": False, "target_formats": ["glb"],
        }
        result = request("image-to-3d", payload)
        state = {"task_id": result["result"], "input": image.name,
                 "parameters": {k: v for k, v in payload.items() if k != "image_url"}}
        state_path.write_text(json.dumps(state, indent=2))
        print(json.dumps(state))
    elif action == "status":
        state = json.loads(state_path.read_text())
        result = request("image-to-3d/" + state["task_id"])
        state.update({k: result.get(k) for k in ["status", "progress", "consumed_credits", "task_error"]})
        if result["status"] == "SUCCEEDED":
            for key, url in [("glb", result["model_urls"]["glb"]), ("preview.png", result["thumbnail_url"])]:
                output = ART / (name + "." + key)
                if not output.exists():
                    with urlopen(url, timeout=120) as response:
                        output.write_bytes(response.read())
                state[key] = str(output.relative_to(ROOT))
        state_path.write_text(json.dumps(state, indent=2))
        print(json.dumps(state))
    else:
        raise ValueError("Use submit or status.")


if __name__ == "__main__":
    main()
