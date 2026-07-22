"""jms_eval_worker — standalone holdout-scoring worker (JMS EVAL engine, P10).

Spawned DETACHED by jms_eval.sv.jac `start_eval` as `jac run
scripts/jms_eval_worker.jac` (cwd = studio root). A plain program: NO auth or
graph context, touches ONLY the filesystem + (judge) the Anthropic REST API.
Everything arrives via the env contract:

  JMS_EVAL_DIR      abs evals/<eid> dir (outputs.jsonl/scores.jsonl/summary.json)
  JMS_MODEL_PATH    abs base-model dir (mlx)
  JMS_ADAPTER_PATH  abs LoRA adapter dir (mlx_lm.load adapter_path=)
  JMS_HOLDOUT       abs dataset/holdout.jsonl (rows: {"messages":[...]})
  JMS_METRIC        judge | similarity
  JMS_LIMIT         0 = all rows, else first N
  JMS_JUDGE_MODEL   Anthropic model id (judge)
  JMS_PASS_SCORE    score >= this counts toward pass_rate (default 4)
  ANTHROPIC_API_KEY (judge only)

Flow: load base+adapter (own mlx copy — the server holds the heavy lock) → for
each holdout row split messages into prompt-context (all but last) + reference
(last message content), generate a completion, APPEND to outputs.jsonl → score
(judge: 10 rows/Anthropic call, {"score":1-5,"rationale"} per row, parse-retry
once then default 0; similarity: difflib ratio → round(ratio*4)+1) → write
scores.jsonl + summary.json {n, mean_score, pass_rate, metric}. Progress → stdout
(job runlog). Exit 0 done, 1 eval failure, 2 config error, 143 stopped.

The Anthropic REST call is a minimal copy of scripts/jms_gen_worker.jac's
_claude_generate (workers cannot import server modules) — keep in sync.
"""

import json;
import os;
import sys;
import time;
import difflib;
import importlib;
import from pathlib { Path }
import from signal { signal, SIGTERM }
import from http.client { HTTPSConnection }

glob _STATE: dict[str, any] = {"stop": False, "writing": False};
glob _MLX: dict[str, any] = {"model": None, "tokenizer": None};
glob _MAX_GEN: int = 512;          # generation cap per holdout row
glob _JUDGE_BATCH: int = 10;       # rows per Anthropic judge call

def _log(msg: str) -> None { print(msg, flush=True); }

def _env_int(name: str, fallback: int) -> int {
    try { return int(str(os.environ.get(name, str(fallback)))); }
    except Exception { return fallback; }
}

"""SIGTERM → stop; exit 143 now unless a file write is mid-flight."""
def _on_term(signum: any, frame: any) -> None {
    _STATE["stop"] = True;
    if not bool(_STATE["writing"]) {
        _log("[stop] SIGTERM — exiting");
        sys.exit(143);
    }
}

# ------------------------------------------------------------------ mlx -------
"""Load the worker's OWN base+adapter mlx copy once. importlib indirection: the
`import from mlx_lm { load }` form crashes the 0.16.1 checker's overloads."""
def _mlx_load(path: str, adapter_path: str) -> None {
    mod: any = importlib.import_module("mlx_lm");
    t0 = time.time();
    loaded: any = mod.load(path, adapter_path=adapter_path) if adapter_path else mod.load(path);
    _MLX["model"] = loaded[0];
    _MLX["tokenizer"] = loaded[1];
    _log(f"[mlx] base+adapter loaded in {int(time.time() - t0)}s: {path} + {adapter_path}");
}

"""Greedy decode of *prompt_messages* (deterministic — the fairest completion to
score). Returns the generated text."""
def _mlx_generate(prompt_messages: list, max_out: int) -> str {
    mod: any = importlib.import_module("mlx_lm");
    ptoks: any = _MLX["tokenizer"].apply_chat_template(prompt_messages, add_generation_prompt=True);
    out: any = mod.generate(
        _MLX["model"], _MLX["tokenizer"], ptoks, max_tokens=max_out, verbose=False
    );
    return str(out);
}

# --------------------------------------------------------------- anthropic ----
"""One blocking Anthropic /v1/messages call via http.client. Raises RuntimeError
with the HTTP status + body snippet on an API error (the fake-key probe surfaces
here). Minimal copy of jms_gen_worker._claude_generate."""
def _claude_generate(model: str, key: str, system: str, user: str, max_out: int) -> str {
    body = json.dumps({
        "model": model,
        "max_tokens": max_out,
        "system": system,
        "messages": [{"role": "user", "content": user}]
    }).encode("utf-8");
    conn: any = HTTPSConnection("api.anthropic.com", timeout=600);
    txt = "";
    code = 0;
    try {
        conn.request("POST", "/v1/messages", body, {
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        });
        resp: any = conn.getresponse();
        code = int(str(resp.status));
        txt = str(resp.read().decode("utf-8"));
    } finally {
        conn.close();
    }
    if code != 200 {
        raise RuntimeError(f"anthropic http {code}: {txt[:300]}");
    }
    data = dict(json.loads(txt));
    parts: list[str] = [];
    blks: any = data.get("content", []);
    for blk in blks {
        if isinstance(blk, dict) and str(blk.get("type", "")) == "text" {
            parts.append(str(blk.get("text", "")));
        }
    }
    return "".join(parts);
}

"""First [...] JSON array in *txt* (tolerates fences/prose). None on a miss."""
def _extract_arr(txt: str) -> list | None {
    t = txt.strip();
    a = t.find("[");
    b = t.rfind("]");
    if a < 0 or b <= a { return None; }
    try {
        val: any = json.loads(t[a:b + 1]);
        if isinstance(val, list) { return list(val); }
        return None;
    } except Exception {
        return None;
    }
}

# ------------------------------------------------------------------ helpers ---
"""Last user-turn content in a prompt-message list (the judge's question), else
the last message's content."""
def _last_user(pm: list) -> str {
    last = "";
    for m in pm {
        if isinstance(m, dict) {
            md = dict(m);
            if str(md.get("role", "")) == "user" { last = str(md.get("content", "")); }
        }
    }
    if last { return last; }
    if len(pm) > 0 and isinstance(pm[len(pm) - 1], dict) {
        return str(dict(pm[len(pm) - 1]).get("content", ""));
    }
    return "";
}

"""difflib ratio (0..1) → a 1-5 integer score: round(ratio*4)+1. Minimal
DUPLICATE of jms_eval.sv.jac `similarity_score` (workers can't import server
modules); the summary block below mirrors jms_eval.summarize — keep both in sync."""
def _sim_score(generated: str, reference: str) -> int {
    ratio = float(difflib.SequenceMatcher(None, generated, reference).ratio());
    s = int(round(ratio * 4.0)) + 1;
    if s < 1 { s = 1; }
    if s > 5 { s = 5; }
    return s;
}

def _append_line(pth: Path, rec: dict) -> None {
    _STATE["writing"] = True;
    pth.parent.mkdir(parents=True, exist_ok=True);
    f: any = open(str(pth), "a", encoding="utf-8");
    f.write(json.dumps(rec) + "\n");
    f.close();
    _STATE["writing"] = False;
}

def _write_json(pth: Path, rec: dict) -> None {
    _STATE["writing"] = True;
    pth.parent.mkdir(parents=True, exist_ok=True);
    pth.write_text(json.dumps(rec));
    _STATE["writing"] = False;
}

"""Build the judge user prompt for a batch of {q, reference, generated} items."""
def _judge_user(items: list) -> str {
    parts: list[str] = [];
    i = 0;
    for it in items {
        d = dict(it);
        parts.append(
            f"### Example {i}\nPROMPT:\n{str(d.get('q', ''))}\n\n"
            + f"REFERENCE ANSWER:\n{str(d.get('reference', ''))}\n\n"
            + f"MODEL ANSWER:\n{str(d.get('generated', ''))}"
        );
        i = i + 1;
    }
    joined = "\n\n".join(parts);
    return (
        f"You are grading {len(items)} model answers against reference answers.\n\n"
        + joined + "\n\n"
        + "For EACH example (in order), rate how well the MODEL ANSWER matches the "
        + "intent and correctness of the REFERENCE ANSWER for the given PROMPT, on a "
        + "1-5 integer scale (1=wrong/irrelevant, 3=partially correct, 5=fully "
        + "correct & equivalent). Output a STRICT JSON array of exactly "
        + f"{len(items)} objects, each {{\"score\": <1-5 int>, \"rationale\": \"<one "
        + "sentence>\"}}, in the same order. Output ONLY the JSON array — no prose, "
        + "no code fences."
    );
}

"""Score one batch via the judge. Returns a list of {score, rationale} the same
length as *items* (parse-retry once, then default score 0)."""
def _judge_batch(model: str, key: str, items: list) -> list {
    sys_p = "You are a strict, fair grader of code-assistant answers. You output only JSON.";
    user = _judge_user(items);
    max_out = len(items) * 120 + 200;
    parsed: list | None = None;
    try {
        raw = _claude_generate(model, key, sys_p, user, max_out);
        parsed = _extract_arr(raw);
    } except Exception as e {
        _log(f"[judge] api error: {str(e)[:220]}");
        # one retry
        try {
            time.sleep(2);
            raw2 = _claude_generate(model, key, sys_p, user, max_out);
            parsed = _extract_arr(raw2);
        } except Exception as e2 {
            _log("FATAL: judge api error: " + str(e2)[:260]);
            raise;
        }
    }
    if parsed is None {
        _log("[judge] parse miss — retrying once");
        try {
            raw3 = _claude_generate(model, key, sys_p, user + "\n\nYour previous reply was not a valid JSON array. Output ONLY the JSON array.", max_out);
            parsed = _extract_arr(raw3);
        } except Exception as e3 {
            _log(f"[judge] retry api error: {str(e3)[:220]}");
        }
    }
    out: list = [];
    n = len(items);
    if parsed is None {
        for _k in range(n) { out.append({"score": 0, "rationale": "judge parse failed"}); }
        return out;
    }
    i = 0;
    for it in parsed {
        if i >= n { break; }
        sc = 0;
        rat = "";
        if isinstance(it, dict) {
            d = dict(it);
            try { sc = int(str(d.get("score", 0))); } except Exception { sc = 0; }
            if sc < 0 { sc = 0; }
            if sc > 5 { sc = 5; }
            rat = str(d.get("rationale", ""));
        }
        out.append({"score": sc, "rationale": rat});
        i = i + 1;
    }
    while len(out) < n { out.append({"score": 0, "rationale": "judge parse failed"}); }
    return out;
}

# -------------------------------------------------------------------- main ----
def main() -> int {
    ed_s = str(os.environ.get("JMS_EVAL_DIR", ""));
    if not ed_s { _log("FATAL: JMS_EVAL_DIR not set"); return 2; }
    ed = Path(ed_s);
    ed.mkdir(parents=True, exist_ok=True);
    model_path = str(os.environ.get("JMS_MODEL_PATH", ""));
    adapter_path = str(os.environ.get("JMS_ADAPTER_PATH", ""));
    holdout = str(os.environ.get("JMS_HOLDOUT", ""));
    metric = str(os.environ.get("JMS_METRIC", "similarity"));
    limit = _env_int("JMS_LIMIT", 0);
    judge_model = str(os.environ.get("JMS_JUDGE_MODEL", "claude-sonnet-5"));
    pass_score = _env_int("JMS_PASS_SCORE", 4);
    key = str(os.environ.get("ANTHROPIC_API_KEY", ""));

    signal(int(SIGTERM), _on_term);

    if not model_path or not os.path.isdir(model_path) {
        _log("FATAL: JMS_MODEL_PATH missing or not a dir"); return 2;
    }
    if metric == "judge" and not key {
        _log("FATAL: judge metric without ANTHROPIC_API_KEY"); return 2;
    }
    if not holdout or not os.path.isfile(holdout) {
        _log("FATAL: JMS_HOLDOUT missing"); return 2;
    }

    # ---- read holdout ---------------------------------------------------------
    rows: list = [];
    try {
        f: any = open(holdout, "r", encoding="utf-8");
        txt = str(f.read());
        f.close();
        for ln in txt.splitlines() {
            if not ln.strip() { continue; }
            try {
                r = dict(json.loads(ln));
                msgs: any = r.get("messages", []);
                if not isinstance(msgs, list) or len(msgs) < 2 { continue; }
                ml = list(msgs);
                ref = str(dict(ml[len(ml) - 1]).get("content", "")) if isinstance(ml[len(ml) - 1], dict) else "";
                pm: list = [dict(m) for m in ml[:len(ml) - 1] if isinstance(m, dict)];
                rows.append({"prompt_messages": pm, "reference": ref});
            } except Exception { continue; }
        }
    } except Exception as e {
        _log("FATAL: cannot read holdout: " + str(e)[:200]); return 2;
    }
    if len(rows) == 0 { _log("FATAL: holdout has no valid rows"); return 2; }
    if limit > 0 and limit < len(rows) { rows = rows[:limit]; }
    _log(f"[eval] metric={metric} rows={len(rows)} judge_model={judge_model} pass>={pass_score}");

    # ---- load model -----------------------------------------------------------
    _log("[mlx] loading base+adapter (can take minutes)...");
    try {
        _mlx_load(model_path, adapter_path);
    } except Exception as e {
        _log("FATAL: mlx load failed: " + str(e)[:240]); return 2;
    }

    # ---- generation pass (append outputs.jsonl per row) -----------------------
    outputs_f = ed / "outputs.jsonl";
    outputs_f.write_text("");   # fresh
    generated: list[str] = [];
    idx = 0;
    for row in rows {
        if bool(_STATE["stop"]) { _log("[stop] before row " + str(idx)); return 143; }
        d = dict(row);
        pm: list = list(d["prompt_messages"]);
        ref = str(d["reference"]);
        gen_txt = "";
        try {
            gen_txt = _mlx_generate(pm, _MAX_GEN);
        } except Exception as e {
            _log(f"[gen] row {idx} generate error: {str(e)[:200]}");
            gen_txt = "";
        }
        generated.append(gen_txt);
        _append_line(outputs_f, {
            "idx": idx, "prompt_messages": pm, "reference": ref, "generated": gen_txt
        });
        _log(f"[gen] row {idx + 1}/{len(rows)} · {len(gen_txt)} chars");
        idx = idx + 1;
    }

    # ---- scoring pass ---------------------------------------------------------
    scores_f = ed / "scores.jsonl";
    scores_f.write_text("");
    all_scores: list[int] = [];
    if metric == "similarity" {
        i = 0;
        for row in rows {
            ref = str(dict(row)["reference"]);
            sc = _sim_score(generated[i], ref);
            all_scores.append(sc);
            _append_line(scores_f, {"idx": i, "score": sc});
            i = i + 1;
        }
    } else {
        i = 0;
        while i < len(rows) {
            if bool(_STATE["stop"]) { _log("[stop] during scoring"); return 143; }
            batch: list = [];
            j = i;
            while j < len(rows) and j < i + _JUDGE_BATCH {
                rd = dict(rows[j]);
                batch.append({
                    "q": _last_user(list(rd["prompt_messages"])),
                    "reference": str(rd["reference"]),
                    "generated": generated[j]
                });
                j = j + 1;
            }
            graded: list = [];
            try {
                graded = _judge_batch(judge_model, key, batch);
            } except Exception as e {
                _log("FATAL: judge failed: " + str(e)[:260]); return 1;
            }
            k = 0;
            for g in graded {
                gd = dict(g);
                sc = int(str(gd.get("score", 0)));
                all_scores.append(sc);
                _append_line(scores_f, {"idx": i + k, "score": sc, "rationale": str(gd.get("rationale", ""))});
                k = k + 1;
            }
            _log(f"[judge] scored {i + len(graded)}/{len(rows)}");
            i = i + _JUDGE_BATCH;
        }
    }

    # ---- summary --------------------------------------------------------------
    n = len(all_scores);
    total = 0;
    passed = 0;
    for s in all_scores {
        total = total + s;
        if s >= pass_score { passed = passed + 1; }
    }
    mean = (float(total) / float(n)) if n > 0 else 0.0;
    prate = (float(passed) / float(n)) if n > 0 else 0.0;
    _write_json(ed / "summary.json", {
        "n": n, "mean_score": mean, "pass_rate": prate, "metric": metric
    });
    _log(f"[eval] done: n={n} mean_score={mean} pass_rate={prate} metric={metric}");
    return 0;
}

with entry {
    sys.exit(main());
}
