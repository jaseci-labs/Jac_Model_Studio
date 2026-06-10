# Jac Studio

Local chatbot for the fine-tuned Jac models (Gemma/Qwen, SFT + DPO fused, MLX).
Everything runs on this machine — no external calls.

## Run

    ./web_app/start.sh        # API :8400 + UI :3000
    open http://localhost:3000

Models are read from `JAC_STUDIO_DATA_ROOT` (default: the main DataGeneration
checkout — `models/` is gitignored so worktrees don't have it).

## Layout

- `server/` — FastAPI + mlx_lm. One resident model; swap = unload → load (~20-40s).
  SSE streaming, SQLite history in `server/data/`.
- `ui/` — Next.js + shadcn, monochrome "Soft Mono × Schematic" theme.

## Test

    cd web_app/server && .venv/bin/pytest          # fast, fake-model seam
    ./web_app/smoke.sh                              # while running

Compare mode is sequential on 48GB: model A answers, then the server swaps to
model B (load progress shown in B's pane).
