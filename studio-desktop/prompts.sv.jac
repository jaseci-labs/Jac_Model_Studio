"""studio - prompt library. Serves studio/prompts.json (ported from server).

Resolved relative to studio_root() so it works regardless of cwd.
"""

import json;
import paths;

def list_prompts() -> dict {
    path = str(paths.studio_root() / "prompts.json");
    try {
        with open(path) as f {
            return dict(json.load(f));
        }
    } except Exception {
        return {"categories": []};
    }
}
