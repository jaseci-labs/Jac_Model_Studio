# Jac ML Studio

One-stop local ML workbench for the Jac fine-tuning project: chat with the
trained models, launch + monitor training, run the data pipeline, and run
evals — all in one monochrome UI. Written in **pure Jac** (full-stack: server
+ React-in-Jac client from one codebase). Supersedes the old FastAPI + Next.js
app (deleted) and the earlier web_app/ + dashboard_app/.

## Run

    jac setup desktop               # one-time: init the native webview target
    ./studio-desktop/start.sh       # launches a native desktop window (API in-process, no browser)

Models/dataset/results are read from `JAC_STUDIO_DATA_ROOT` (defaults to the
parent of `studio-desktop/` — the `jac_ml_studio` workspace checkout). Override
with `JAC_STUDIO_WORKSPACE` / `JAC_STUDIO_DATA_ROOT` when models live elsewhere.

Workspace data-config (model registry, dataset file maps, train defaults) lives
in `studio.workspace.toml` at the workspace root — see `workspace.sv.jac`.

## Desktop runtime dependencies (one-time, after clone or cache wipe)

The desktop target runs the server **in-process on an isolated, bundled Python**
(`~/.cache/jac/rt/<hash>/site`). `jaclang`'s wheel declares **no** dependencies,
so that bundle is missing the whole `jac-scale` server stack (`bcrypt`,
`sqlalchemy`, `fastapi`, `pymongo`, `pyjwt`, `redis`, …) and the in-process boot
dies on `import bcrypt`. `start.sh` points the native host's `JAC_DESKTOP_DEPS`
env var at `.jac/desktop_deps/` (appended to `sys.path` at boot). That dir is
.gitignored, so repopulate it after a fresh clone or a `jac clean`:

    pip install --target studio-desktop/.jac/desktop_deps \
      "rich>=13.0.0" "python-dotenv>=1.2.1,<2.0.0" \
      "fastapi>=0.121.3,<0.122.0" "uvicorn[standard]>=0.38.0,<0.39.0" \
      "pyjwt>=2.10.1,<2.11.0" "fastapi-sso>=0.21.0,<1.0.0" \
      "python-multipart>=0.0.21,<1.0.0" "bcrypt>=4.0.0,<5.0.0" \
      "aiohttp>=3.9.0,<4.0.0" "sqlalchemy>=2.0.0,<3.0.0" \
      "email-validator>=2.3.0,<3.0.0" \
      "pymongo>=4.15.4,<5.0.0" "redis>=7.1.0,<8.0.0"

Versions are pinned to what `jac-scale` requires; don't let pip float them or
the boot crashes on incompatible majors.

Dev-mode (`./start.sh`) also needs `watchdog` importable by the `jac` CLI
(HMR file watcher). It is listed under `[dependencies]` in `jac.toml`; `start.sh`
force-installs it into `.jac/venv` if missing (plain `pip install` can no-op when
watchdog is only present in the ephemeral `~/.cache/jac/rt/<hash>/site`).

## Layout

Everything lives in this directory (`studio-desktop/`):

- `paths.sv.jac` — canonical `studio_root` / `workspace_root` / `data_root` +
  jacgen script paths (single source of truth for path resolution).
- `workspace.sv.jac` — loads `studio.workspace.toml` (workspace root > studio
  root). Single source of truth for data-config the app used to hard-code: model
  registry, eval holdouts, dataset/RL/CPT file maps, train option keys, builder
  stages, eval kinds, RL rung order. Edit the TOML to adapt the app to a checkout
  — no code changes. (TOML, not YAML, because `jac` ships as a frozen binary
  whose bundled Python has stdlib `tomllib` but no PyYAML.)
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

    cd studio-desktop && jac check main.jac   # type-check the whole app
    ./studio-desktop/smoke.sh                 # while running
