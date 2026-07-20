 Layer 1 — Finish wiring the config (cheap, mostly delete-and-replace) **DONE**

 All consumers below now call `workspace.*()` accessors. The migration table is kept for reference:

 ┌─────────────────┬──────────────────────────────────┬────────────────────────────────────────────────┐
 │ File            │ Still hardcoded                  │ Should call                                    │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ models.sv.jac   │ glob MODELS, HOLDOUTS,           │ workspace.model_registry() / .holdouts() /     │
 │                 │ EXCLUDED_RUN_DIRS                │ .excluded_run_dirs()                           │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ builders.sv.jac │ glob BUILDERS                    │ workspace.builder_stages()                     │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ train.sv.jac    │ glob SFT_KEYS, DPO_KEYS          │ workspace.sft_keys() / .dpo_keys()             │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ cpt.sv.jac      │ CPT_FILES, MANIFEST_REL,         │ workspace.cpt_*()                              │
 │                 │ SRC_ORDER, KIND_MAP              │                                                │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ evals.sv.jac    │ glob VALID_KINDS                 │ workspace.eval_kinds()                         │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ data.sv.jac     │ PREVIEW_FILES, APPEND_TARGETS,   │ workspace.preview_files() / .append_targets()  │
 │                 │ split maps                       │ / .data_sft_stat_files() / .data_split_files() │
 ├─────────────────┼──────────────────────────────────┼────────────────────────────────────────────────┤
 │ rl.sv.jac       │ RUNG_ORDER, RL_PREVIEW_FILES     │ workspace.rung_order() / .rl_preview_files()   │
 └─────────────────┴──────────────────────────────────┴────────────────────────────────────────────────┘

 Shipped fallback: `studio-desktop/studio.workspace.toml` (copied from repo root; workspace_root
 wins at runtime). TOML is the single source for **checkout config** (models, datasets, backends) —
 not for user workspaces (those live on the graph; see Layer 2 #2).

 ────────────────────────────────────────────────────────────────────────────────

 Layer 2 — Structural things config alone can't fix

 This is where "generalizable fine-tuning workspace" actually lives. Right now the app is a
 Jac-fine-tuning studio; making it a fine-tuning studio means abstracting five axes that are currently
 baked into code:

 1. Training backend is hardcoded to MLX-on-Mac shell scripts. **MOSTLY DONE (backends.sv.jac)**
 train.sv.jac / cpt.sv.jac build a declarative job spec and call `backends.render()`; per-method
 templates, env_keys, and log_parser live in `[backends.*]` in studio.workspace.toml. Train UI picks
 backend + method and reads opt keys from config; job files record backend; metrics dispatch by parser.
 `mlx_local` is wired; `hf_trl` / `axolotl` are stub entries. Still TODO: cloud dispatch, real parsers
 for non-MLX backends.

 2. The workspace concept (01/02/03) should be user data, not code or TOML. **IN PROGRESS (graph/SQLite)**
 Workspaces live on the Jac graph (`root --> Workspace --> WorkspaceSection`) and persist to SQLite
 (`.jac/data/`) — **not** in `studio.workspace.toml` or any `jac.toml`. TOML holds static checkout
 config (models, datasets, backends); workspaces are per-user layout state owned by the graph.

 Done: `Workspace` / `WorkspaceSection` nodes, `ui_layout()` endpoint, NavRail + AppShell read from the
 graph, idempotent seed from `_SEED_WORKSPACES` on first run.

 Still TODO:
 - CRUD endpoints (create / rename / reorder / delete workspace + sections) so users can add a 4th
   workspace without editing code
 - Dynamic section registry — `_sectionBody()` in AppShell.cl.jac still maps component names to imports
   by hand; new section types should register once, not require a shell edit
 - Per-user workspace isolation (today nodes hang off `root`; should scope under the caller's graph root
   like chats/evals)
 - UI for workspace management (settings drawer or admin section)

 3. Sections are bespoke, not composable.
 You have 10 hand-written section components (Data, Train, Evals, CptData, CptTrain, RlData, Plan…) each
 tightly coupled to one paradigm. The generalizable move is a small set of generic section primitives —
 DatasetBrowser, TrainingLauncher, EvalsRunner, CheckpointBrowser — parameterized by config, so a new
 workspace composes them instead of forking them.

 4. Dataset format is hardcoded to specific JSONL shapes.
 data.sv.jac / cpt.sv.jac parse SFT-message / DPO-pair / CPT-meta.text schemas inline. Needs a
 dataset-format abstraction (chat / instruction / preference / raw-text / completion) with a reader per
 format.

 5. Eval methodology is Jac-specific.
 evals.sv.jac runs jac eval with probe/idiom kinds. Needs pluggable eval runners: lm-eval-harness,
 held-out loss, LLM-judge, regex — each a small adapter with the same EvalView contract.

 (Bonus: inference is MLX-only — inference.sv.jac assumes local MLX dirs. A general studio wants
 hosted-API and vLLM/sglang backends behind the same warm_model / chat_stream interface.)

 ────────────────────────────────────────────────────────────────────────────────

 Layer 3 — Missing entirely

 Things that don't exist yet but a real fine-tuning workbench needs:

 - Checkpoint/adapter management as first-class: list, fuse, quantize, export, download, push-to-Hub.
   Right now run_probe.sh does quantize+fuse invisibly.
 - Dataset source connectors: HuggingFace Hub pull, local-dir scan, upload — not just browsing pre-built
   files.
 - Cloud training wired end-to-end: vast.sv.jac lets you rent a GPU box but you can't say "run training
   job X on instance Y". The bridge between jobs and instances is missing.
 - Metric extractors per backend: `parse_train_log_by()` dispatches by name but only `mlx` is wired.
   hf_trl / axolotl need real parsers when those backends land.
 - Experiment tracking: W&B / TensorBoard / Hub logging integration.
 - Base-model registry: the models you fine-tune from are implicit in the shell scripts; they should be
   first-class entries.
 - Presets/recipes: "SFT Qwen3 on my JSONL" as a one-click template instead of env-var archaeology.
 - CPT_TOTAL_ITERS magic dict → derive from the training config or declare per-run.

 ────────────────────────────────────────────────────────────────────────────────

 Suggested order of attack

 1. ~~Layer 1~~ — **DONE**. All consumers use `workspace.*()` accessors; TOML is the single source for
    checkout config (models, data paths, backends).
 2. ~~Job-spec + backend abstraction (Layer 2 #1)~~ — **mostly done**. Remaining: cloud dispatch + non-MLX
    parsers.
 3. Workspace graph CRUD + dynamic section registry (Layer 2 #2) — finish the SQLite-backed workspace
    model: user-editable workspaces on the graph, not in TOML. Then composable section primitives
    (Layer 2 #3).
 4. Layer 3 items opportunistically.

 ────────────────────────────────────────────────────────────────────────────────

 Config split (do not conflate)

 ┌──────────────────────┬─────────────────────────────┬──────────────────────────────────────────────┐
 │ Concern              │ Store                       │ Examples                                     │
 ├──────────────────────┼─────────────────────────────┼──────────────────────────────────────────────┤
 │ Checkout / ML config │ studio.workspace.toml       │ model registry, dataset paths, backends,     │
 │                      │ (file, versioned w/ repo)   │ eval kinds, CPT layout                       │
 ├──────────────────────┼─────────────────────────────┼──────────────────────────────────────────────┤
 │ User workspaces      │ SQLite graph (.jac/data/)   │ workspace label, sections, default model,    │
 │                      │ Workspace + WorkspaceSection│ file roots — per-user, editable at runtime   │
 │                      │ nodes via workspace.sv.jac  │                                              │
 ├──────────────────────┼─────────────────────────────┼──────────────────────────────────────────────┤
 │ Session prefs        │ localStorage (client)       │ last active workspace id                     │
 └──────────────────────┴─────────────────────────────┴──────────────────────────────────────────────┘

