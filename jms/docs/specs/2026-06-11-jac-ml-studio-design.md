# Jac ML Studio — Unified Web App Plan

## Context

The repo has three separate tool surfaces: the **Jac Studio chatbot** (`web_app/` — Next 16 + shadcn UI :3000, FastAPI/mlx server :8400, merged to main, the design benchmark), the **training dashboard** (`dashboard_app/` — jac-client React on :8000: Monitor/History/Train/Ingest/Dataset screens over 3 jac services), and the **data-generation pipeline** (15 `srccurrent/jacgen/*.jac` operations + `run_probe.sh`/`run_dpo.sh`, CLI-only). The user wants **one app — "Jac ML Studio"** — with the chatbot's Soft Mono × Schematic monochrome UI/UX carrying across everything.

**User decisions (locked):**
- Port dashboard_app functionality natively; dashboard_app retired (folder stays, deprecated).
- App lives in a NEW top-level folder **`jac_ml_studio/`** — the chatbot's `web_app/ui` + `web_app/server` code is **transported (copied) there as the starting point**; `web_app/` stays on disk untouched but is deprecated alongside dashboard_app once jac_ml_studio works. Same ports (:3000/:8400 — only one app runs at a time). New `jac_ml_studio/start.sh`/`smoke.sh`. Fresh venv + node_modules inside the new folder (both are gitignored and machine-local anyway).
- Data section gets ALL of: pipeline runner, dataset browser, example authoring, eval-suite runner.
- RAM contention chat-vs-training: **leave as-is, no new guards** (mem gauge already shows resident model).
- Nav: ~48px far-left icon rail, 4 sections — CHAT / TRAIN / DATA / EVALS. Chat's 3-column layout untouched.
- Train section: sub-tabs LAUNCH · MONITOR · HISTORY. Charts: Recharts, monochrome-styled.
- Eval runs history in SQLite (existing chats.db).
- Phased build on one branch (worktree), 4 phases, merge at end.

## Architecture

One FastAPI app (:8400) + one Next.js app (:3000), both already exist. Backend gains 4 routers + 4 logic modules; frontend gains a nav-rail shell + 3 lazy-mounted sections. Long-lived jobs (training, builders, evals) = detached processes (`start_new_session`) writing `run-*.log` with `__EXIT__ $?` markers + `.job-*.json` state files — exactly the proven dashboard_app semantics, ported from `dashboard_app/services/jobs.sv.jac`. Job state stays in files (survives server restart); only eval history goes to SQLite.

### Frontend routing decision
Single route `/`, client-side section state synced to `location.hash` (`#train`), **all visited sections stay mounted** (inactive = `hidden` class, NOT the `hidden` attribute — display:flex would override). Reason: chat streaming state lives in `use-studio.ts` owned by the chat component; Next route switching would unmount it mid-generation and lose the stream. Sections lazy-mount via `next/dynamic` on first visit so Recharts (~100KB) never enters the chat bundle. Every section poll hook takes `active: boolean` and pauses when hidden.

## Canonical API contract (backend ⇄ frontend)

```
/api/runs                GET    → {runs:[{name,has_sft,has_dpo,stages[],running}]}
/api/runs/compare?mode   GET    → {names[],train[],val[],curve[],headline[]}   (declare BEFORE /{name})
/api/runs/{name}?mode    GET    → RunMetrics {name,mode,found,running,last_iter,train[{x,y}],val,lr,tps,
                                  curve,idiom_sim,has_idiom,idiom_label,idiom_avg_sim,idiom_idiomatic,
                                  idiom_python,idiom_runs,idiom_total,log_tail}
/api/train/start         POST   {model_id,name,mode:"sft"|"dpo",opts{}} → JobStatus
                                 opts whitelist: SFT EVAL_EVERY/SUBSET/DRY_ITERS/SKIP_DRY/LIVE_EVAL;
                                 DPO DPO_ITERS/DPO_LR/DPO_BETA/DPO_LAYERS/SUBSET
/api/train/stop          POST   {name,mode} → JobStatus     (killpg SIGTERM)
/api/train/status        GET    ?name&mode → JobStatus {name,mode,status,pid,started,last_iter,log_tail,message}
                                 status ∈ idle|running|done|failed|stopped|finished
/api/train/sessions      GET    → {sessions:[{name,mode,status,last_iter,started,label}]}
/api/builders            GET    → {builders:[{stage,status:JobStatus}]}        (all 13 in one poll)
/api/builders/run        POST   {stage} → JobStatus          (whitelist 13 jacgen stages)
/api/dataset/stats       GET    → counts {sft_files[],sft_total,dpo_pairs,splits{...}}
/api/dataset/files       GET    → {files:[{path,label,count}]}                 (9-file allowlist)
/api/dataset/rows        GET    ?path&offset&limit → {rows:[DataRow],total}
                                 DataRow = {idx,name,difficulty,source,kind,preview,prompt,python,jac,
                                 chosen,rejected,raw} — RAW strings; client highlights (NO server HTML)
/api/dataset/examples    POST   {target:"sft"|"dpo",text} → {added,errors[],total}
/api/evals               POST   {kind:"probe"|"idiom",model_id|model_path,adapter?,holdout:"function"|"graph",
                                 limit?,sim_threshold?} → 201 record
/api/evals               GET    → {evals:[record]} newest-first (refreshes running rows first)
/api/evals/{id}          GET    → record + log_tail
/api/evals/{id}/stop     POST   → record
/api/evals/{id}          DELETE → {ok}  (killpg if running, rm results/_evals/<id>/, delete row)
```

Eval record: `{id,kind,model,adapter,holdout,params{limit,sim_threshold},scores{}|null,status,started,finished}`.

**Eval scores need NO stdout parsing**: `eval_probe.jac:166-173` writes a summary row to `JAC_EVAL_METRICS_OUT`; `idiom_eval.jac:190-198` to `JAC_IDIOM_OUT`. Point both at `results/_evals/<id>/metrics.jsonl`, harvest the last row on `__EXIT__ 0`.

## File structure

### Backend (`jac_ml_studio/server/` — transported copy of web_app/server, then extended)
```
app.py            unchanged chat/load/models/prompts/chats + 4 include_router calls
config.py         + results_dir(), jac_bin() (= data_root()/.venv/bin/jac), HOLDOUTS map,
                  EXCLUDED_RUN_DIRS = {comparison, _builder, _evals}
db.py             + eval_runs table (id,kind,model,adapter,holdout,params_json,pid,scores_json,
                  status,started,finished) + CRUD mirroring chats helpers
runlogs.py        NEW pure parsers (port runs.sv.jac): parse_train_log (SFT+DPO regex variants,
                  runs.sv.jac:101-123), read_series, last_row, tail, pick_idiom (fallback
                  graph-idiom.jsonl), stages (.done markers), merge_by_x, last_iter
procs.py          NEW process lifecycle (port jobs.sv.jac): _safe allowlist, _alive, _reap
                  (waitpid WNOHANG), job-json io, live_status (__EXIT__ marker authoritative,
                  jobs.sv.jac:150-172 ordering), stop (killpg), spawn_detached(cmd,runlog,env,cwd)
                  — close parent log fd post-Popen (jac original leaks); reject ".." segments,
                  resolve paths under data_root()
datasets.py       NEW (port dataset.sv.jac minus _hl HTML highlighting): stats, files, rows
                  (_fence/_funcname extraction → raw strings), append (open "a", not read+rewrite)
evalruns.py       NEW: build cmd/env for eval jobs, refresh(row) reconcile-on-read
routers/{runs,train,data,evals}.py   thin: validation + shaping only; sync def (threadpool)
tests/            extend conftest: results_root (real-format log fixtures), dataset_root,
                  fake_scripts (instant-exit/failing/sleeping run_probe.sh, run_dpo.sh),
                  fake_jac (.venv/bin/jac stub writing canned metrics row — works because
                  everything resolves via config.jac_bin() under monkeypatched root)
                  + test_runlogs, test_runs_api, test_train_api, test_dataset_api, test_evals_api
```

### Frontend (`jac_ml_studio/ui/` — transported copy of web_app/ui, then extended)
```
app/page.tsx                  shell: NavRail + 4 section slots (hash sync, visited-memo, lazy)
components/chat-section.tsx   current page.tsx body moved VERBATIM (owns useStudio; React.memo)
components/nav-rail.tsx       48px rail, 4 hand-drawn inline-SVG schematic glyphs (16×16,
                              currentColor, strokeWidth 1.25, square caps — NOT lucide),
                              active = bright + 2px left tick, tooltips, rotated JAC ML wordmark
components/shared/            stat-tile (BracketTile port: corner brackets), status-glyph
                              (○⦿✓✗◌ — monochrome brightness encodes state, shape carries
                              semantics, pulse on running), log-view (column-reverse <pre>
                              tail-follow trick + grayscale tokenizer), mono-chart +
                              multi-line-chart (Recharts ^2.12 wrappers), code-block
                              (copy of thread.tsx CodeBlock + highlight — NOT an extraction,
                              chat untouched), sub-tabs, field (mono inputs/segmented toggles)
components/sections/train/    train-section, launch-tab, monitor-tab, history-tab
components/sections/data/     data-section, pipeline-rail, stats-tiles, dataset-browser,
                              row-detail, add-examples
components/sections/evals/    evals-section, eval-launch, eval-history, eval-compare
lib/api.ts                    only change: export j() and streamSSE()
lib/{api-train,api-data,api-evals}.ts   typed domain clients
lib/use-poll.ts               usePoll(fn, ms, active) — pause on hidden/visibilitychange
lib/{use-train,use-data,use-evals}.ts   section state hooks
lib/highlight.ts              client regex tokenizer (port dataset.sv.jac _hl alternation +
                              HL_KW/TYPE/BI sets covering Python+Jac) → React spans, tok-* classes
                              mapped to grayscale tiers in globals.css
globals.css                   additive only: rail tick, pulse keyframe, tok-* grays, chart panel
```

### Recharts mono recipe (centralized in mono-chart.tsx)
Line: `#ededed`, 1.4px, no dots, no animation. Grid: `#1c1c1f` horizontal only. Axes: mono 10px `#666`, no tick lines. Tooltip: `#0a0a0c` bg, `1px solid #333`, radius 0, mono. Live tip: ReferenceDot pulse (was green in dashboard → mono pulse). Multi-run overlays: gray ramp `#ededed/#8a8a8a/#525252` + strokeDasharray patterns ("", "5 3", "1 3", "7 2 1 2"). Charts behind `next/dynamic`.

## Phases (one worktree, branch `jac-ml-studio`, off main)

**Phase 0 — docs**: write spec + this plan into `docs/superpowers/{specs,plans}/` and commit (mirrors repo convention from Jac Studio build).

**Phase 1 — Transport + shell + rail (chat regression-free)**
Transport first: `git mv`-free copy of `web_app/ui` + `web_app/server` (committed files only) into `jac_ml_studio/`, new `jac_ml_studio/{start.sh,smoke.sh,README.md}`, fresh `.venv` + `npm install`, gitignore entries for `jac_ml_studio/{ui/node_modules,ui/.next,server/.venv,server/data}`; verify transported app boots + chat works + 37 tests pass before changing anything. Then: chat-section.tsx verbatim move → nav-rail.tsx → page.tsx shell (hash sync, lazy placeholders "TRAIN — PHASE 2" etc.) → globals.css additions. **Phase gate:** build/lint clean; chat functional checklist (offline retry, model swap, compare, sidebar CRUD, sliders); **keep-mounted proof**: start long generation → switch to Train → back → tokens kept accumulating, busy still true; first-load JS of `/` unchanged ±1KB.

**Phase 2 — Train section (vertical slice)**
Backend: config additions → runlogs.py (TDD against real-format log fixtures) → procs.py (TDD w/ fake scripts) → routers/runs.py + routers/train.py → wire create_app.
Frontend: use-poll → api-train.ts → shared primitives (status-glyph, stat-tile, log-view, sub-tabs, field) → recharts + mono-chart → use-train → launch-tab (form, SFT|DPO knob switch, START/STOP, log tail) → monitor-tab (session picker, LIVE/STALLED-30s/NO-FEED chip via last_iter tracking, chart grid, idiom tiles) → history-tab (multi-line overlay + headline tiles).
Gate: real `run_probe.sh` smoke (SKIP_DRY dry-run iters) driven from UI; stop button kills process group.

**Phase 3 — Data section**
Backend: datasets.py + routers/data.py + /api/builders (procs reuse).
Frontend: api-data → highlight.ts + code-block → use-data → stats-tiles → pipeline-rail (13 stages vertical, ordered group headers SEED/IDIOM BATCHES/SCALE/DPO/MANIFEST+SPLITS/HOLDOUTS/VERIFY; permanent warning under seed_conversion: "TRUNCATES sft.jsonl→32 · dpo.jsonl→2 — run idiomatic batches after"; out-of-order dim hint, no hard block; one shared log panel) → dataset-browser + row-detail (25-row pages, expand → CodeBlocks by kind) → add-examples (target picker, per-line errors, stats refresh).
Gate: run dataset_stats + verify_dataset from UI; browse all 9 files; append a valid + an invalid example.

**Phase 4 — Evals section**
Backend: db eval_runs + CRUD → evalruns.py → routers/evals.py.
Frontend: api-evals → use-evals → eval-launch (kind toggle, model picker reusing api.models() registry + free-text path, adapter, holdout toggle, limit, sim-threshold for idiom only) → running log view → eval-history table → eval-compare (client pivot: models × holdouts, pass% + avg_sim, best-per-column brightened).
Gate: real idiom_eval on graph holdout (13 tasks, ~2min) from UI → scores land in history; second eval different model → compare grid populates.

**Finish**: final whole-branch review → merge to main → restart app.

## Execution method
Same as Jac Studio build: worktree via EnterWorktree, subagent-driven development (implementer + spec review + quality review per task), full plan doc with per-task code written before implementation (writing-plans skill), TDD on server, build/tsc/lint gates on UI.

## Key reuse (all arrives via the transport copy)
- server: create_app factory, sse.py, db.py connection-per-call + JAC_STUDIO_DB, config.data_root(), CORS, pydantic `protected_namespaces` pattern, test idioms (fake_root, tmp_db_global).
- ui: theme utilities, api.ts j()/streamSSE, CodeBlock styling, tooltip/popover/slider components (base-nova gotchas known: controlled popovers, scalar slider callback).
- `dashboard_app` as reference source (not runtime): jobs.sv.jac process semantics, runs.sv.jac parsers, dataset.sv.jac extraction, Hud.cl.jac/MetricChart.cl.jac visual concepts.
- `srccurrent/jacgen`: eval_probe/idiom_eval env contracts (JAC_EVAL_*/JAC_IDIOM_*).

## Risks
1. `results/_evals` must join every run-dir exclusion set or evals appear as training runs.
2. `__EXIT__` marker stays authoritative over pid liveness (restart reparents children; waitpid fails silently).
3. `/api/runs/compare` registered before `/api/runs/{name}`.
4. Path validation: `_safe` + ".."-rejection + resolve-under-data_root on every user-supplied path (dashboard originals had gaps).
5. Keep-mounted shell: use class-based hiding, React.memo chat, verify bundle size — the Phase 1 gate exists to catch all of this before anything else lands.
6. Training/eval/chat all unguarded on 48GB by user decision — document in router docstrings so reviews don't "fix" it.
7. jaclang type-checker quirks don't apply (no jac code written — jac only invoked as subprocess).

## Verification (end-to-end)
- Server: `.venv/bin/pytest` (existing 37 + ~40 new across 5 suites, all fake-seamed; no mlx imports in new modules).
- UI: `npm run build && npx tsc --noEmit && npm run lint` per phase.
- Live gates per phase (above) + final: `./jac_ml_studio/start.sh`, headless-Chrome drive of each section (puppeteer-core pattern from /tmp/slidertest), real dry-run training launch, real graph-holdout eval, chat regression checklist.
