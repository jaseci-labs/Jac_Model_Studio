"""RL ladder results backend — reads the live ladder output and pivots it into
chart-ready structures for the RL section. Replaces the static weekend-only data.

Two runs are surfaced:
  - primary: results/rl_ladder.jsonl  (gb+lib file-disjoint holdout)
  - sg:      results/rl_ladder_sg.jsonl (step 7, sg idiom held out file-disjoint)

Each ladder eval appends one row tagged r<N>/<model>/<cond>/<gen|mem>. We collapse
to one cell per (model, rung, cond) and emit, per run: a flat cell list (the table),
a rung-indexed curve (one line per model·cond, gen pass@1), and the line keys.

# ponytail: reads external JSON (json.loads -> Any), so strict `jac check` can't
# type the dict pivot — same as model-experiments/02-rl-grpo/rl/eval_rl.jac / model-experiments/02-rl-grpo/rl/show_ladder.jac. Bar is
# `jac check -p` (parse) + it runs; verified against the real rl_ladder.jsonl.
"""

import os;
import json;
import subprocess;
import paths;
import workspace;
import from pathlib { Path }

# Ladder rung axis lives in studio.workspace.toml (workspace.sv.jac).

def _ws() -> Path { return paths.workspace_root(); }

def _gen_py() -> str {
    p = _ws() / ".venv" / "bin" / "python3";
    return str(p) if p.exists() else "python3";
}

def _gen_model() -> str {
    return str(_ws() / "models" / "jac-qwen3coder-r20-rft-q4");
}

def _pivot(p: str) -> dict {
    if not os.path.exists(p) {
        return {"cells": [], "curve": [], "curve_keys": [], "families": [], "count": 0};
    }
    cells: dict = {};   # last write wins per (model,rung,cond,kind)
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
    # Densify: every rung row carries every series key (None where that
    # model·cond had no eval at this rung) so the client can render an explicit
    # N/A marker instead of silently dropping the series from the tooltip.
    all_keys: list = sorted(keys);
    curve: list = [];
    for r in workspace.rung_order() {
        if r in curve_map {
            cp: dict = curve_map[r];
            for lk in all_keys {
                if lk not in cp { cp[lk] = None; }
            }
            curve.append(cp);
        }
    }
    def _rk(row: dict) -> int {
        return workspace.rung_order().index(str(row["rung"])) if str(row["rung"]) in workspace.rung_order() else 99;
    }
    out_cells.sort(key=lambda r: r and (str(r["model"]), _rk(r), str(r["cond"])));
    return {"cells": out_cells, "curve": curve, "curve_keys": sorted(keys), "families": sorted(fams), "count": len(out_cells)};
}

<<<<<<<< HEAD:jms/rl.sv.jac
def:pub get_rl_ladder() -> dict {
    primary = _pivot(os.environ.get("JAC_RL_RESULTS", os.path.join(RL_REPO, "model-experiments/02-rl-grpo", "results", "rl_ladder.jsonl")));
    sg = _pivot(os.path.join(RL_REPO, "model-experiments/02-rl-grpo", "results", "rl_ladder_sg.jsonl"));
    v84 = _pivot(os.path.join(RL_REPO, "model-experiments/02-rl-grpo", "results", "rl_ladder_v84.jsonl"));
========
def get_rl_ladder() -> dict {
    ws = str(_ws());
    primary = _pivot(os.environ.get("JAC_RL_RESULTS", os.path.join(ws, "02-rl-grpo", "results", "rl_ladder.jsonl")));
    sg = _pivot(os.path.join(ws, "02-rl-grpo", "results", "rl_ladder_sg.jsonl"));
    v84 = _pivot(os.path.join(ws, "02-rl-grpo", "results", "rl_ladder_v84.jsonl"));
>>>>>>>> origin/main:studio-desktop/rl.sv.jac
    return {
        "cells": primary["cells"], "curve": primary["curve"], "curve_keys": primary["curve_keys"],
        "families": primary["families"], "count": primary["count"],
        "sg": sg, "v84": v84
    };
}

<<<<<<<< HEAD:jms/rl.sv.jac
def:pub get_rl_corrected() -> dict {
    # The corrected results (fixed eval+reward) — assembled by model-experiments/02-rl-grpo/rl/make_summary.py.
    p = os.path.join(RL_REPO, "model-experiments/02-rl-grpo", "resultspub", "rl", "corrected_summary.json");
    # Fallback/error shapes must carry every key the client dereferences
    # (Results.cl.jac lists journey/kscale unguarded).
    empty: dict = {"ladder": [], "holdouts": [], "journey": [], "kscale": [], "headline": {}, "note": ""};
========
def get_rl_corrected() -> dict {
    # The corrected results (fixed eval+reward) — assembled by 02-rl-grpo/rl/make_summary.py.
    p = str(_ws() / "02-rl-grpo" / "resultspub" / "rl" / "corrected_summary.json");
>>>>>>>> origin/main:studio-desktop/rl.sv.jac
    if not os.path.exists(p) {
        return {"ladder": [], "holdouts": [], "headline": {}, "note": ""};
    }
    return json.loads(Path(p).read_text());
}

def rl_generate(prompt: str, k: int = 8) -> dict {
    # Best-of-k Jac generation: sample k from the SFT model, return the first the jac
    # compiler accepts (model-experiments/02-rl-grpo/rl/generate.py). Loads a 30B model per call (~1-2 min) — this
    # is the deployable artifact from RL_FINDINGS.md (~78% vs 55% greedy).
    gen_model = _gen_model();
    if not os.path.exists(gen_model) {
        return {"ok": False, "verified": False, "jac": "", "note": "SFT model missing: " + gen_model};
    }
    ws = str(_ws());
    env = dict(os.environ);
    env["JAC_GEN_MODEL"] = gen_model;
    env["K"] = str(k);
    try {
        p = subprocess.run(
<<<<<<<< HEAD:jms/rl.sv.jac
            [GEN_PY, os.path.join(RL_REPO, "model-experiments/02-rl-grpo", "rl", "generate.py"), "--prompt", prompt],
            capture_output=True, text=True, timeout=900, cwd=RL_REPO, env=env
========
            [_gen_py(), os.path.join(ws, "02-rl-grpo", "rl", "generate.py"), "--prompt", prompt],
            capture_output=True, text=True, timeout=900, cwd=ws, env=env
>>>>>>>> origin/main:studio-desktop/rl.sv.jac
        );
        raw = str(p.stdout);
        verified = "verified by jac" in raw;
        parts = raw.split("\n\n", 1);
        note = str(parts[0]).strip().lstrip("# ") if parts else "";
        jac = str(parts[1]).strip() if len(parts) > 1 else raw.strip();
        return {"ok": True, "verified": verified, "jac": jac, "note": note, "k": k};
    } except Exception as e {
        return {"ok": False, "verified": False, "jac": "", "note": str(e)};
    }
}
