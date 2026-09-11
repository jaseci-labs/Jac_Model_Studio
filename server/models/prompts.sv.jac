"""studio - prompt library. Serves server/models/prompts.json (ported from server).

Resolved relative to studio_root() so it works regardless of cwd.
"""

import json;
import from server.core { paths }

def list_prompts() -> dict {
    path = str(paths.studio_root() / "server" / "models" / "prompts.json");
    try {
        with open(path) as f {
            return dict(json.load(f));
        }
    } except Exception {
        return {"categories": []};
    }
}
