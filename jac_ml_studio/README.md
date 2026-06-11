# Jac ML Studio

One-stop local ML workbench for the Jac fine-tuning project: chat with the
trained models, launch + monitor training, run the data pipeline, and run
evals — all in one monochrome UI. Supersedes web_app/ (chat only) and
dashboard_app/ (jac-client training dashboard), both now deprecated.

## Run

    ./jac_ml_studio/start.sh      # API :8400 + UI :3000
    open http://localhost:3000

Models/dataset/results are read from `JAC_STUDIO_DATA_ROOT` (default: the
main DataGeneration checkout — those dirs are gitignored, worktrees lack them).

## Layout

- `server/` — FastAPI + mlx_lm + job orchestration. SQLite in `server/data/`.
- `ui/` — Next.js + shadcn, Soft Mono × Schematic theme. Sections: CHAT /
  TRAIN / DATA / EVALS behind the left icon rail.

## Test

    cd jac_ml_studio/server && .venv/bin/pytest
    ./jac_ml_studio/smoke.sh      # while running
