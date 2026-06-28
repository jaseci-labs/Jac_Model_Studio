"""RL ladder results backend — reads the live ladder output (results/rl_ladder.jsonl
in the repo root, written by rl/run_ladder.jac) and pivots it into chart-ready
structures for the RL section. This replaces the static weekend-only data with the
real, updating SFT/GRPO ladder curve.

Each ladder eval appends one row tagged r<N>/<model>/<cond>/<gen|mem>. We collapse
to one cell per (model, rung, cond) and emit: a flat cell list (the table), a
rung-indexed curve (one line per model·cond, gen pass@1), and the line keys.

# ponytail: reads external JSON (json.loads -> Any), so strict `jac check` can't
# type the dict pivot — same as rl/eval_rl.jac / rl/show_ladder.jac. Bar is
# `jac check -p` (parse) + it runs; verified against the real rl_ladder.jsonl.
"""

import os;
import json;
import from pathlib { Path }

# rl.sv.jac lives at studio/ root = <repo>/jac_ml_studio/studio ; results/ is at <repo>.
glob RL_REPO: str = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))));
glob RUNG_ORDER: list = ["1", "3", "5", "10", "20", "all"];

def _results_path() -> str {
    return os.environ.get("JAC_RL_RESULTS", os.path.join(RL_REPO, "results", "rl_ladder.jsonl"));
}

def:pub get_rl_ladder() -> dict {
    p = _results_path();
    if not os.path.exists(p) {
        return {"cells": [], "curve": [], "curve_keys": [], "families": [], "count": 0, "source": p};
    }
    # pivot — last write wins per (model,rung,cond,kind)
    cells: dict = {};
    for line in Path(p).read_text().split("\n") {
        s = str(line).strip();
        if not s { continue; }
        try {
            rec = json.loads(s);
        } except ValueError {
            continue;
        }
        parts = str(rec.get("tag", "")).split("/");
        if len(parts) != 4 { continue; }
        (rung, model, cond, kind) = (str(parts[0]).lstrip("r"), str(parts[1]), str(parts[2]), str(parts[3]));
        key = model + "|" + rung + "|" + cond;
        slot: dict = cells.get(key, {"model": model, "rung": rung, "cond": cond});
        slot[kind] = rec;
        cells[key] = slot;
    }

    out_cells: list = [];
    curve_map: dict = {};
    keys: set = set();
    fams: set = set();
    for k in cells.keys() {
        c: dict = cells[k];
        g: dict = c.get("gen", {});
        m: dict = c.get("mem", {});
        bf: dict = g.get("by_family", {});
        out_cells.append({
            "model": c["model"], "rung": c["rung"], "cond": c["cond"],
            "gen_pass1": g.get("pass1_pct", None), "gen_passk": g.get("passk_pct", None),
            "gen_near": g.get("near_pct", None), "osim": g.get("avg_osim", None),
            "mem_pass1": m.get("pass1_pct", None), "n": g.get("tasks", None),
            "by_family": bf
        });
        for f in bf.keys() { fams.add(str(f)); }
        if "pass1_pct" in g {
            line_key = c["model"] + "·" + c["cond"];
            keys.add(line_key);
            cp: dict = curve_map.get(c["rung"], {"x": c["rung"]});
            cp[line_key] = g["pass1_pct"];
            curve_map[c["rung"]] = cp;
        }
    }
    curve: list = [];
    for r in RUNG_ORDER {
        if r in curve_map { curve.append(curve_map[r]); }
    }
    # cells sorted by model, then ladder rung order, then cond
    def _rk(row: dict) -> int {
        return RUNG_ORDER.index(str(row["rung"])) if str(row["rung"]) in RUNG_ORDER else 99;
    }
    out_cells.sort(key=lambda r: r and (str(r["model"]), _rk(r), str(r["cond"])));
    return {
        "cells": out_cells, "curve": curve, "curve_keys": sorted(keys),
        "families": sorted(fams), "count": len(out_cells), "source": p
    };
}
