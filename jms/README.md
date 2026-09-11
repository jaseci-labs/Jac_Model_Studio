# Jac ML Studio (JMS)

Local ML workbench written in pure Jac (server `.sv.jac` + React-in-Jac client
`.cl.jac`, one codebase). Two surfaces:

- **JMS** — projects: sources → synthesize dataset → curate → train (local MLX or
  a BYO remote GPU) → eval → chat with the result. Plus the in-app AI assistant.
- **Experiments** — workspaces with CHAT (registry models), DATA (dataset
  browser) and CLOUD (BYO GPU clusters + supervised remote runs).

This directory is self-contained: it runs from `jms/` and only reaches outside
through the paths in `studio.workspace.toml`.

## Run

    jac setup desktop        # one-time: native webview target
    ./start.sh               # native desktop window (dev mode, local single user)

Browser instead of a native window: `jac start --dev main.jac` (UI :8000, API
:8001). Production (multi-tenant, login gate): `JWT_SECRET=... ./start_prod.sh`,
see `deploy/`.

After editing a `.cl.jac` file restart the server — `--dev` compiles the client
once at boot.

## Config and data

| What | Where | Override |
|------|-------|----------|
| Model registry, dataset files, cloud-run defaults | `studio.workspace.toml` | `$JAC_STUDIO_WORKSPACE/studio.workspace.toml` |
| Base dir for relative paths in the toml | `jms/` | `JAC_STUDIO_WORKSPACE` |
| Runtime data JMS writes: `results/` (per-user runs, GPU lock), `audit/`, `projects/`, `examples/` | `jms/data/` (gitignored) | `JAC_STUDIO_DATA_ROOT` |
| Graph + users DB, JWT secret | `jms/.jac/` (gitignored) | — |

The shipped toml points at the sibling `../model-experiments/` checkout (base
Qwen3-Coder q4 + the 08 SFT adapter, 08 SFT/DPO datasets). Registry entries take
`path` (MLX model dir) and an optional `adapter` (LoRA dir). Any path may be
missing: the model shows as unavailable and dataset files count 0.

Worker/tool binaries (`jac`, `mlx_lm.lora`) are taken from next to the running
interpreter, then `PATH`; a `../.venv/bin` is used only as a last-resort
fallback if it exists.

## Desktop runtime dependencies (one-time, after clone or `jac clean`)

The desktop target runs the server in-process on a bundled Python that lacks the
`jac-scale` server stack. `start.sh` points `JAC_DESKTOP_DEPS` at
`.jac/desktop_deps/`; populate it with (versions pinned to what jac-scale needs):

    pip install --target .jac/desktop_deps \
      "rich>=13.0.0" "python-dotenv>=1.2.1,<2.0.0" \
      "fastapi>=0.121.3,<0.122.0" "uvicorn[standard]>=0.38.0,<0.39.0" \
      "pyjwt>=2.10.1,<2.11.0" "fastapi-sso>=0.21.0,<1.0.0" \
      "python-multipart>=0.0.21,<1.0.0" "bcrypt>=4.0.0,<5.0.0" \
      "aiohttp>=3.9.0,<4.0.0" "sqlalchemy>=2.0.0,<3.0.0" \
      "email-validator>=2.3.0,<3.0.0" \
      "pymongo>=4.15.4,<5.0.0" "redis>=7.1.0,<8.0.0"

## Layout

- `main.jac` — registers every endpoint + mounts the client.
- `paths.sv.jac` — the three roots (studio / workspace / data) + tool lookup.
- `workspace.sv.jac` — toml loader + Experiments workspace graph.
- `jms_*.sv.jac` — JMS product (projects, plan, gen, curate, train, eval, chat, llm).
- `models` / `inference` / `chat` / `persistence` / `data` — model registry,
  resident MLX + streaming, chat history graph, dataset browser.
- `jobs` (detached subprocess engine + heavy GPU lock), `cloudruns` / `clusters` /
  `backends` / `remote/` (BYO GPU runs), `auth`, `audit`, `crypto`, `assistant`.
- `components/`, `hooks/`, `lib/` — UI. `scripts/` — workers + backup tooling.
- `docs/{plans,specs,blog}` — design history.

## Test

    jac test <module>.test.jac     # one annex; run each *.test.jac (no server needed)
    ./smoke.sh                     # while the browser-target server is up
    JAC_API=http://localhost:8001 ./smoke_auth.sh

Tests redirect `JAC_STUDIO_WORKSPACE` / `JAC_STUDIO_DATA_ROOT` to temp dirs. Don't
`jac run` app modules from inside `jms/` while a server is up — it writes the
live `.jac/data` graph.
