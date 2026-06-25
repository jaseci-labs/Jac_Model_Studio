"""studio - prompt library. Serves studio/prompts.json (ported from server).

`jac start` runs with cwd = the project dir, so the file resolves relative to cwd.
"""

import json;
import os;

def:pub list_prompts() -> dict {
    here = os.path.dirname(os.path.abspath("prompts.json"));
    path = os.path.join(here, "prompts.json");
    try {
        with open(path) as f {
            return dict(json.load(f));
        }
    } except Exception {
        return {"categories": []};
    }
}
