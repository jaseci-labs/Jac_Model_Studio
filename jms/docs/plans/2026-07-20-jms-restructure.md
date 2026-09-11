# JMS Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the repo into `model-experiments/` (01-sft-dpo, 02-rl-grpo, 03-new) and `jms/` (renamed from `studio/`), fold `this_is_jac/` into `02-rl-grpo/dataset/`, fix every live path reference, then merge the whole `studio-overhaul` branch into `main`.

**Architecture:** Pure filesystem restructuring (`git mv`) plus mechanical string-literal fixes in the ~16 files that do live path resolution into the moved directories. No new code, no unit tests in the pytest sense — "tests" here are: (a) `grep` checks proving no stale unprefixed path literal survives, (b) `jac check` / `jac validate` proving the app still compiles, (c) a live boot + curl smoke test proving the moved data actually resolves at runtime.

**Tech Stack:** git, Jac (`jac check`, `jac start --dev`), perl (portable in-place regex replace across macOS/GNU), the `mcp__jac-mcp__validate_jac` tool as a secondary compile check.

## Global Constraints

- Do not touch any file under `01-sft-dpo/`, `02-rl-grpo/dataset/rl*`, `02-rl-grpo/rl/drivers/`, `02-rl-grpo/rl/templates/`, or `03-new/dataset/` (post-move: `model-experiments/...`) — these are frozen training/eval artifacts, precious and single-copy.
- Do not modify `models/` contents or layout.
- Every `git mv` must be a real `git mv` (preserves history), never delete+recreate.
- Final directory layout is exactly:
  ```
  model-experiments/{01-sft-dpo, 02-rl-grpo/dataset/this_is_jac, 03-new}
  jms/                (renamed from studio/)
  models/ docs/ context.md README.md setup_env.sh   (unchanged, stay at root)
  ```
- Spec: `docs/superpowers/specs/2026-07-20-jms-restructure-design.md`

---

### Task 1: Move attempt dirs into model-experiments/, fold this_is_jac in

**Files:**
- Move: `01-sft-dpo/` → `model-experiments/01-sft-dpo/`
- Move: `02-rl-grpo/` → `model-experiments/02-rl-grpo/`
- Move: `03-new/` → `model-experiments/03-new/`
- Move: `this_is_jac/` → `model-experiments/02-rl-grpo/dataset/this_is_jac/`

**Interfaces:**
- Produces: the four directories at their new paths, on disk and in git's index, for every later task to reference.

- [ ] **Step 1: Create the parent dir and move the three attempt dirs**

```bash
mkdir -p model-experiments
git mv 01-sft-dpo model-experiments/01-sft-dpo
git mv 02-rl-grpo model-experiments/02-rl-grpo
git mv 03-new model-experiments/03-new
```

- [ ] **Step 2: Fold this_is_jac into 02-rl-grpo's dataset**

```bash
git mv this_is_jac model-experiments/02-rl-grpo/dataset/this_is_jac
```

- [ ] **Step 3: Verify the moves**

```bash
git status --short | head -5   # expect: R  01-sft-dpo/... -> model-experiments/01-sft-dpo/...  (x many, truncated)
ls model-experiments/
# expect: 01-sft-dpo  02-rl-grpo  03-new
ls model-experiments/02-rl-grpo/dataset/
# expect: rl  rl_conv  this_is_jac
test -d 01-sft-dpo -o -d 02-rl-grpo -o -d 03-new -o -d this_is_jac && echo "FAIL: old paths still exist" || echo "OK: old paths gone"
```

Expected: last line prints `OK: old paths gone`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: move attempts under model-experiments/, fold this_is_jac into 02-rl-grpo dataset

Groups 01-sft-dpo/02-rl-grpo/03-new under one parent so the repo root
splits cleanly into model-experiments/ vs the studio app. this_is_jac/
is the real Jac codebase attempt 2 mines RL tasks from, so it belongs
under 02-rl-grpo/dataset/ rather than floating at repo root.

Confirmed safe: build_tasks.jac only regex-reads already-generated
driver files for frozen Origin: comments, never this_is_jac/ from disk
at build time — no dataset/driver files need edits.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Rename studio/ to jms/

**Files:**
- Move: `studio/` → `jms/` (whole directory, all contents)

**Interfaces:**
- Consumes: nothing from Task 1 (independent rename, same repo root depth).
- Produces: `jms/` directory for Tasks 3-6 to edit.

- [ ] **Step 1: Rename**

```bash
git mv studio jms
```

- [ ] **Step 2: Verify**

```bash
ls jms/main.jac jms/jac.toml jms/start.sh   # all three must exist
test -d studio && echo "FAIL: studio/ still exists" || echo "OK: studio/ gone"
```

Expected: `OK: studio/ gone`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: rename studio/ to jms/

Studio is now branded JMS (Jac Model Studio). Same depth under repo
root, so __file__-relative path resolution inside the app (CPT_ROOT,
RL_REPO, data_root()) is unaffected by this rename alone — only the
literal 01-sft-dpo/02-rl-grpo/03-new path strings need fixing, done
in the next commit.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Fix live path literals inside jms/

**Files:**
- Modify: `jms/builders.sv.jac`, `jms/data.sv.jac`, `jms/cpt.sv.jac`, `jms/evals.sv.jac`, `jms/gallery.sv.jac`, `jms/models.sv.jac`, `jms/rl.sv.jac`, `jms/train.sv.jac`, `jms/main.jac`
- Modify: `jms/components/sections/CptData.cl.jac`, `jms/components/sections/Results.cl.jac`, `jms/components/sections/CptResults.cl.jac`, `jms/components/sections/Plan.cl.jac`, `jms/components/sections/Generate.cl.jac`, `jms/components/sections/Evals.cl.jac`, `jms/components/sections/RlData.cl.jac`

**Interfaces:**
- Consumes: `model-experiments/{01-sft-dpo,02-rl-grpo,03-new}` existing on disk (Task 1), `jms/` existing (Task 2).
- Produces: every literal `01-sft-dpo/…`, `02-rl-grpo/…`, `03-new/…` string inside `jms/` — whether a live filesystem path (`GALLERY_ROOTS`, `CPT_ROOT`-relative joins, `RL_REPO`-relative joins, `jac run` targets, `Gallery prefix=` props) or a cosmetic label/comment — now reads `model-experiments/01-sft-dpo/…` etc. Later tasks (boot/smoke test) rely on this being complete and consistent.

All three tokens appear only as path-like references in these files (confirmed by prior grep — no other meaning), so a blanket in-place replace across all 16 files is safe and simpler than hand-editing ~60 individual lines.

- [ ] **Step 1: Apply the global replace**

```bash
FILES="jms/builders.sv.jac jms/data.sv.jac jms/cpt.sv.jac jms/evals.sv.jac \
jms/gallery.sv.jac jms/models.sv.jac jms/rl.sv.jac jms/train.sv.jac jms/main.jac \
jms/components/sections/CptData.cl.jac jms/components/sections/Results.cl.jac \
jms/components/sections/CptResults.cl.jac jms/components/sections/Plan.cl.jac \
jms/components/sections/Generate.cl.jac jms/components/sections/Evals.cl.jac \
jms/components/sections/RlData.cl.jac"

perl -pi -e 's/01-sft-dpo/model-experiments\/01-sft-dpo/g' $FILES
perl -pi -e 's/02-rl-grpo/model-experiments\/02-rl-grpo/g' $FILES
perl -pi -e 's/03-new/model-experiments\/03-new/g' $FILES
```

- [ ] **Step 2: Verify no bare (unprefixed) references remain**

```bash
grep -rn '01-sft-dpo\|02-rl-grpo\|03-new' $FILES | grep -v 'model-experiments/'
```

Expected: empty output (every occurrence is now prefixed).

- [ ] **Step 3: Verify no double-prefixing happened**

```bash
grep -rn 'model-experiments/model-experiments' $FILES
```

Expected: empty output.

- [ ] **Step 4: Compile-check the app**

```bash
cd jms && ../.venv/bin/jac check main.jac; cd ..
```

Expected: no errors (warnings about `Any` from Python-interop are pre-existing and fine — only new hard errors indicate a broken edit).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
fix: prefix jms/ path literals with model-experiments/

01-sft-dpo/02-rl-grpo/03-new moved under model-experiments/ in a prior
commit; jms/ (formerly studio/) resolves several paths as literal
strings relative to repo root (GALLERY_ROOTS, CPT_ROOT-relative joins,
RL_REPO-relative joins, jac run targets, Gallery prefix props) that all
needed the same prefix inserted.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: JMS branding — jac.toml, start.sh, README.md, AGENTS.md

**Files:**
- Modify: `jms/jac.toml`
- Modify: `jms/start.sh`
- Modify: `jms/README.md`
- Modify: `jms/AGENTS.md`

**Interfaces:**
- Consumes: `jms/` existing (Task 2).
- Produces: no functional change — `name` field and doc text only. Nothing downstream depends on this.

- [ ] **Step 1: Update jac.toml project name**

Current (`jms/jac.toml` line 2-3):
```toml
[project]
name = "studio"
```

New:
```toml
[project]
name = "jms"
```

- [ ] **Step 2: Update start.sh's header comment**

Current (`jms/start.sh` line 2):
```bash
# Jac ML Studio (pure Jac): one process serves the API (:8001) + Vite UI (:8000).
```

New:
```bash
# JMS — Jac Model Studio (pure Jac): one process serves the API (:8001) + Vite UI (:8000).
```

And current line 3:
```bash
# Ctrl-C stops it. The old FastAPI+Next app (server/, ui/) was replaced by studio/.
```

New:
```bash
# Ctrl-C stops it. The old FastAPI+Next app (server/, ui/) was replaced by jms/.
```

- [ ] **Step 3: Sweep README.md and AGENTS.md for self-references**

```bash
grep -n '\bstudio\b\|Studio' jms/README.md jms/AGENTS.md
```

For each hit that means *this app* (not incidental prose), replace `studio/` → `jms/` and bare `studio` → `JMS` (keep "Jac Model Studio" phrases as "Jac Model Studio (JMS)" on first mention, "JMS" after). Use targeted Edit calls per hit — do not blanket-sed these two files since they're free-form prose, unlike Task 3's path literals.

- [ ] **Step 4: Verify no stale self-reference remains**

```bash
grep -n '\./studio\|studio/start\|studio/smoke\|cd studio' jms/README.md jms/AGENTS.md
```

Expected: empty output.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs: rebrand studio -> JMS in jac.toml, start.sh, README, AGENTS

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Fix setup_env.sh

**Files:**
- Modify: `setup_env.sh`

**Interfaces:**
- Consumes: `model-experiments/01-sft-dpo/` existing (Task 1), `jms/` existing (Task 2).
- Produces: no downstream dependents — this is a standalone operator script.

- [ ] **Step 1: Fix the 01-sft-dpo references**

Current (`setup_env.sh` lines 12, 17-18):
```bash
.venv/bin/jac check -p 01-sft-dpo/sft_dpo/jacgen/*.jac >/dev/null 2>&1 \
...
echo "  ./01-sft-dpo/sft_dpo/check.sh                     # syntax sweep + behavioral note"
echo "  ./01-sft-dpo/sft_dpo/run_probe.sh <hf-model> <name>"
```

New:
```bash
.venv/bin/jac check -p model-experiments/01-sft-dpo/sft_dpo/jacgen/*.jac >/dev/null 2>&1 \
...
echo "  ./model-experiments/01-sft-dpo/sft_dpo/check.sh                     # syntax sweep + behavioral note"
echo "  ./model-experiments/01-sft-dpo/sft_dpo/run_probe.sh <hf-model> <name>"
```

- [ ] **Step 2: Fix the already-broken studio start line**

Current (`setup_env.sh` lines 20-21):
```bash
echo "ML studio (chat + train + data + evals):"
echo "  ./jac_ml_studio/start.sh                   # API :8400 + UI :3000"
```

New:
```bash
echo "JMS (chat + train + data + evals):"
echo "  ./jms/start.sh                              # API :8001 + UI :8000"
```

(Port numbers corrected to match `jms/start.sh`'s actual `:8001`/`:8000` — the old comment's `:8400`/`:3000` was already stale before this restructure.)

- [ ] **Step 3: Verify**

```bash
grep -n '01-sft-dpo\|jac_ml_studio\|jms' setup_env.sh
```

Expected: `01-sft-dpo` lines all show `model-experiments/01-sft-dpo`, no `jac_ml_studio` remains, `./jms/start.sh` line present.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
fix: setup_env.sh paths for model-experiments/ + jms/ restructure

Also fixes a pre-existing stale reference to a nonexistent
jac_ml_studio/start.sh (wrong dir name, wrong ports) while touching
this file.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Rewrite root README.md

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: final layout from Tasks 1-2.
- Produces: no downstream dependents.

Every occurrence of `01-sft-dpo`, `02-rl-grpo`, `03-new` in this file is a path reference (verified by full read) — safe to blanket-replace, same as Task 3.

- [ ] **Step 1: Global path-token replace**

```bash
perl -pi -e 's/01-sft-dpo/model-experiments\/01-sft-dpo/g' README.md
perl -pi -e 's/02-rl-grpo/model-experiments\/02-rl-grpo/g' README.md
perl -pi -e 's/03-new/model-experiments\/03-new/g' README.md
```

- [ ] **Step 2: Fix the shared-root description block (originally lines 18-21)**

Current (now has stale path prefixes from Step 1 baked into `studio/`/`this_is_jac/` mentions — fix by hand):
```markdown
Shared across all attempts, at repo root: `models/` (base + merged checkpoints,
gitignored), `docs/` (repo-wide strategy + the adapter-hyperparameter registry),
`studio/` (the Jac Model Studio app, which reads results from every attempt),
`this_is_jac/` (the real Jac codebase RL mines tasks from), `papers/` (reference papers).
```

New:
```markdown
Shared across all attempts, at repo root: `models/` (base + merged checkpoints,
gitignored), `docs/` (repo-wide strategy + the adapter-hyperparameter registry),
`jms/` (Jac Model Studio, JMS — the app that reads results from every attempt),
`papers/` (reference papers). The attempts themselves live under
`model-experiments/`; `model-experiments/02-rl-grpo/dataset/this_is_jac/` is the
real Jac codebase RL mines tasks from.
```

- [ ] **Step 3: Fix the repository-layout table (originally lines 262-263)**

Current (after Step 1's global replace, the table rows read):
```markdown
| `model-experiments/model-experiments/02-rl-grpo/`... 
```
Note: Step 1's replace does NOT double-prefix here since the original text was `studio/` and `this_is_jac/`, not `01-sft-dpo` etc — but the table's `01-sft-dpo/`, `02-rl-grpo/`, `03-new/` row keys already got prefixed correctly by Step 1. Only the `studio/` and `this_is_jac/` rows need hand fixes.

Current:
```markdown
| `studio/` | **Jac Model Studio** — the app that visualizes/drives all of this (dataset browser, GENERATE panel, RL section, builder jobs) |
| `this_is_jac/` | the real open-source Jac codebase attempt 2 mines RL tasks from |
```

New:
```markdown
| `jms/` | **Jac Model Studio (JMS)** — the app that visualizes/drives all of this (dataset browser, GENERATE panel, RL section, builder jobs) |
| `model-experiments/02-rl-grpo/dataset/this_is_jac/` | the real open-source Jac codebase attempt 2 mines RL tasks from |
```

Also add a `model-experiments/` row right before the `model-experiments/01-sft-dpo/` row:
```markdown
| `model-experiments/` | parent dir for all three attempts (see rows below) |
```

- [ ] **Step 4: Verify**

```bash
grep -n 'model-experiments/model-experiments\|`studio/`\|studio/start\|studio/smoke' README.md
```

Expected: empty output.

```bash
grep -c 'model-experiments/' README.md
```

Expected: a large positive number (dozens — every attempt-dir link in the file).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs: update root README for model-experiments/ + jms/ restructure

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Boot + smoke verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: confidence gate before merge — if this fails, do not proceed to Task 9 (merge).

- [ ] **Step 1: Start JMS in the background**

```bash
cd jms && ./start.sh > /tmp/jms-boot.log 2>&1 &
echo $! > /tmp/jms.pid
cd ..
sleep 8
```

- [ ] **Step 2: Check it booted clean**

```bash
grep -i 'error\|traceback\|exception' /tmp/jms-boot.log | grep -v 'react-error-boundary'
```

Expected: empty output. If not empty, read `/tmp/jms-boot.log` in full before proceeding.

- [ ] **Step 3: Smoke-test endpoints that read the moved paths**

```bash
curl -sf http://localhost:8001/api/data/sft_summary || echo "FAIL: data endpoint"
curl -sf http://localhost:8001/api/cpt/manifest || echo "FAIL: cpt endpoint"
curl -sf http://localhost:8001/api/rl/ladder || echo "FAIL: rl endpoint"
```

(Exact endpoint paths: confirm against `jms/main.jac`'s route registrations before running — adjust the paths above to match if they differ; the point is to hit one endpoint each from `data.sv.jac`, `cpt.sv.jac`, and `rl.sv.jac` and confirm a 2xx with non-error JSON body, proving the `model-experiments/` prefix resolves correctly at runtime.)

- [ ] **Step 4: Stop the server**

```bash
kill "$(cat /tmp/jms.pid)"
```

- [ ] **Step 5: No commit for this task** (verification only — if everything passed, proceed; if anything failed, fix the relevant Task 3-6 file and re-run this task before continuing).

---

### Task 8: Remove the stale cpt-v2-impl worktree

**Files:** none (git administrative operation)

**Interfaces:**
- Consumes: nothing from prior tasks (independent cleanup).
- Produces: clean `git worktree list` for Task 9's merge.

- [ ] **Step 1: Confirm current state**

```bash
git worktree list
```

- [ ] **Step 2: Remove the worktree**

```bash
git worktree remove .claude/worktrees/cpt-v2-impl || git worktree remove --force .claude/worktrees/cpt-v2-impl
git worktree prune -v
```

- [ ] **Step 3: Delete the branch**

```bash
git branch -D worktree-cpt-v2-impl
```

- [ ] **Step 4: Verify**

```bash
git worktree list        # only the main worktree should remain
git branch -a | grep worktree-cpt-v2-impl   # expect no output
```

- [ ] **Step 5: No commit needed** (git worktree/branch state isn't a tracked file change).

---

### Task 9: Merge studio-overhaul into main

**Files:** none (git operation)

**Interfaces:**
- Consumes: all commits from Tasks 1-6, verified by Task 7, cleaned up by Task 8.

- [ ] **Step 1: Confirm branch state**

```bash
git status
git log --oneline main..studio-overhaul | wc -l   # should be 16 (prior) + this plan's commits
```

- [ ] **Step 2: Switch to main and merge**

```bash
git checkout main
git merge studio-overhaul --no-ff -m "$(cat <<'EOF'
merge: studio-overhaul — job engine, heavy lock, tokens+7 themes, model-experiments/+jms restructure

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Verify**

```bash
git log --oneline -5
ls model-experiments/ jms/    # both must exist on main now
```

- [ ] **Step 4: Do NOT push** — local merge only. Confirm with the user before pushing `main` to the remote (separate, explicit action).

---

## Self-Review Notes

- **Spec coverage:** every spec section (final layout, this_is_jac safety, live path-literal edits, git flow) maps to a task above. ✓
- **Placeholder scan:** no TBD/TODO; every step has literal commands or literal before/after text. ✓
- **Consistency:** `model-experiments/` spelled identically everywhere; `jms` used consistently as the new dir/project name. ✓
- **Known soft spot:** Task 7 Step 3's exact endpoint URLs are a best-guess pending a look at `jms/main.jac`'s route table at execution time — flagged inline rather than guessed as fact, since guessing wrong here would silently skip real verification.
