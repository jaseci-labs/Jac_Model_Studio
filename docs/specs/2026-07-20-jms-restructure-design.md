# Repo restructure: model-experiments/ + jms/, this_is_jac into RL dataset

## Goal

Split the repo into two top-level sections — model-finetuning experiments vs. the
app that visualizes/drives them — and fold `this_is_jac/` (the real hand-written
Jac codebase attempt 2 mines RL tasks from) into `02-rl-grpo/dataset/` where it
belongs conceptually. Rename `studio/` to `jms/` ("Jac Model Studio", JMS).

## Final layout

```
model-experiments/
  01-sft-dpo/              (unchanged internals)
  02-rl-grpo/
    dataset/
      this_is_jac/         <- moved from repo root
      rl/, rl_conv/        (unchanged)
  03-new/
jms/                        <- renamed from studio/
models/                     (unchanged, stays at root — gitignored weights)
docs/                        (unchanged, stays at root — cross-cutting strategy)
context.md, README.md, setup_env.sh   (stay at root)
```

`models/`, `docs/`, `context.md` stay at root rather than moving under
`model-experiments/` — they're read directly by `jms/` and are cross-cutting,
not owned by any one attempt.

## Why this_is_jac's move is safe

`02-rl-grpo/rl/build_tasks.jac` regex-scans **already-generated** driver files
(`02-rl-grpo/rl/drivers/*.jac`) for a frozen `Origin: this_is_jac/...` provenance
comment baked in when they were originally mined. It never reads `this_is_jac/`
from disk at build time. Confirmed via read: no script does a live filesystem
lookup into `this_is_jac/` by path. So the move needs zero edits to the ~150
dataset/driver/template files under `02-rl-grpo/` that mention it in comments or
JSONL — those are historical labels, frozen data, not live pointers. Per prior
guidance, generated dataset artifacts are treated as precious/single-copy and
are not touched.

## Live path-string edits required

Only `jms/` (formerly `studio/`) does live filesystem reads/writes into the
moved directories, via relative path strings computed off `__file__` (two
dirs up = repo root) or literal relative strings passed to `jac run` / `Path()`.
Renaming `studio/` → `jms/` does not change this resolution (same depth under
repo root), so only the `01-sft-dpo/…`, `02-rl-grpo/…`, `03-new/…` literals
need a `model-experiments/` prefix inserted. Files confirmed by grep to contain
such literals:

- `jms/builders.sv.jac` — `jac run` target path for jacgen stages
- `jms/data.sv.jac` — dataset file listing + line-count paths (~20 literals)
- `jms/cpt.sv.jac` — CPT_ROOT-relative paths, manifest, results/adapters dirs
- `jms/evals.sv.jac` — jacgen script invocation path
- `jms/gallery.sv.jac` — `GALLERY_ROOTS` allowlist
- `jms/models.sv.jac` — eval holdout paths, results dir
- `jms/rl.sv.jac` — `RL_REPO`-relative results/generate.py paths
- `jms/train.sv.jac` — probe/dpo run-script paths
- `jms/main.jac` — comment only (update for accuracy)
- `jms/components/sections/{Results,CptResults,Evals}.cl.jac` — `Gallery
  prefix="..."` props must match the (now prefixed) `GALLERY_ROOTS` entries
- `jms/components/sections/{CptData,Plan,Generate,RlData}.cl.jac` — cosmetic
  label text only, update for accuracy, no functional effect

Also:
- `jms/jac.toml` — `name = "studio"` → `name = "jms"`
- `jms/start.sh`, `jms/README.md`, `jms/AGENTS.md` — self-references to
  `studio/`/"studio" → `jms/`/"JMS"
- `setup_env.sh` — fix `01-sft-dpo` refs (needs `model-experiments/` prefix)
  and fix the already-broken `./jac_ml_studio/start.sh` line → `./jms/start.sh`
- root `README.md` — rewrite structure section, attempt-table links, the
  `this_is_jac/` reference/path, studio→JMS naming throughout

## Git flow

1. Do all of the above on `studio-overhaul` (current branch).
2. Verify `jms/` boots (`jac start --dev main.jac`) and the moved paths
   resolve (spot-check a data/gallery/cpt endpoint).
3. Remove the stale, already-prunable `cpt-v2-impl` worktree
   (`.claude/worktrees/cpt-v2-impl`) and its branch `worktree-cpt-v2-impl`.
4. Merge `studio-overhaul` into `main` (fast-forward or merge commit — whole
   branch, including the 16 prior commits + this restructure).
5. Going forward: no more worktrees for feature work on this repo.

## Out of scope

- No edits to any file under `01-sft-dpo/`, `02-rl-grpo/dataset/rl*`,
  `02-rl-grpo/rl/drivers/`, `02-rl-grpo/rl/templates/`, or `03-new/dataset/` —
  these are frozen training/eval artifacts.
- No change to `models/` contents or layout.
- `this_is_jac/`'s own internals are untouched — it's portable by design
  (confirmed: no absolute-path or parent-relative assumptions in its source).
