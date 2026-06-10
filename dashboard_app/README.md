# Training Dashboard (jac-client / jac-desktop)

Live GUI for the DataGeneration SFT→DPO pipeline. Five screens:

- **Monitor** — live-only: streams the currently-running run's charts
  (train/val loss, lr, tokens/sec, holdout test-pass curve, idiom stats).
  Auto-refreshes every 2.5 s; finished runs move to History.
- **History** — browse any past run's metrics snapshot, plus the
  compare-all-runs overlay (qwen vs gemma).
- **Train** — split console: pick base model + name + mode + hyperparameters,
  start/stop runs (detached subprocess of `run_probe.sh` / `run_dpo.sh`),
  watch the run log.
- **Ingest** — dataset stats, builder rail (pipeline order), paged JSONL
  preview, append raw examples to the conversion sources.
- **Dataset** — corpus browser: table + expandable rows with server-side
  syntax-highlighted Python/Jac code.

UI: sci-fi HUD design system (mono dark, semantic accents) — see
`docs/superpowers/specs/2026-06-10-dashboard-hud-redesign-design.md`.

It does **not** rewrite the training pipeline: the server walkers read the same
artifacts `run_probe.sh` / `run_dpo.sh` already produce
(`results/<name>/train.log`, `metrics.jsonl`, `idiom-metrics.jsonl`,
`dpo/...`), parsing them the same way as `srccurrent/jacgen/dashboard.jac`.

## Run

From this directory (`dashboard_app/`):

```bash
jac install                          # one-time: npm deps (recharts, react, ...)
jac start --dev main.jac             # browser  -> http://localhost:8000
jac start --client desktop main.jac  # native window (PyTauri, no Rust)
jac build --client web               # production client bundle (CI/smoke)
```

The server auto-detects the repo root: it looks for `results/` then `../results/`
(override with `DG_ROOT=/path`). Running from `dashboard_app/` resolves to the
parent repo, so the existing relative artifact paths work unchanged.

## Layout

- `main.jac` — entry + server endpoint registry (`import from services.runs`).
- `services/runs.sv.jac` — `list_runs`, `get_run_metrics` (read-only parsers).
- `components/AppShell.cl.jac` — nav + routes.
- `components/MonitorPage.cl.jac` — the live dashboard.
- `components/charts/MetricChart.cl.jac` — Recharts line-chart wrapper.
- `services/jobs.sv.jac` — `start_training`/`stop_training`/`job_status` +
  `run_builder`/`builder_status`. Spawns detached (new session), kills by process
  group, persists `results/<name>/.job-<mode>.json`, reaps zombies, and treats the
  appended `__EXIT__ <code>` marker as the authoritative done/failed signal.
- `services/dataset.sv.jac` — `dataset_stats`, `list_dataset_files`,
  `sample_rows` (allowlisted paths), `add_examples` (validated append).
- `components/{TrainPage,IngestPage}.cl.jac` — the Train and Ingest screens.

Paths are resolved absolutely (`_root()`), so the server's `open()` and the
spawned child's `cwd`/redirects agree. Inputs that reach a shell are strict-
allowlisted (`_safe`) and `shlex.quote`d.

Adding a server endpoint is a 2-file change: the `.sv.jac` + its import in
`main.jac`. Editing a `.sv.jac` needs a server restart (`pkill -f "jac start"`);
`.cl.jac` edits hot-reload.
