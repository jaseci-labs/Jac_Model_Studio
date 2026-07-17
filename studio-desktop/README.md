# Jac ML Studio

One-stop local ML workbench for the Jac fine-tuning project: chat with the
trained models, launch + monitor training, run the data pipeline, and run
evals — all in one monochrome UI. Written in **pure Jac** (full-stack: server
+ React-in-Jac client from one codebase). Supersedes the old FastAPI + Next.js
app (deleted) and the earlier web_app/ + dashboard_app/.

## Run

    ./studio/start.sh             # one process: API :8001 + Vite UI :8000
    open http://localhost:8000

Models/dataset/results are read from `JAC_STUDIO_DATA_ROOT` (default: the
main DataGeneration checkout — those dirs are gitignored, worktrees lack them).

## Layout

Everything lives in this directory (`studio/` at the repo root):

- `*.sv.jac` — server endpoints. `models`/`inference` (resident MLX + token
  stream), `chat` (SSE), `persistence` (OSP graph: chats/messages, replaces
  SQLite), `data`/`builders` (dataset + pipeline), `evals` (OSP EvalRun graph),
  `train`/`runs` (job control + metrics), `jobs` (detached subprocess engine,
  port of procs.py), `metrics` (log/metric parsers, port of runlogs.py),
  `prompts`.
- `components/**/*.cl.jac` — the UI. Sections CHAT / TRAIN / DATA / EVALS / RL
  behind the left icon rail; shared chart/form/log primitives; monochrome
  Geist-Mono schematic theme (`global.css`).
- `main.jac` — registers every endpoint + mounts the client app.

## Test

    cd studio && jac check main.jac   # type-check the whole app
    ./studio/smoke.sh                 # while running
