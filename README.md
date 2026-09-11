# Jac ML Studio (JMS)

Local ML workbench written in pure Jac (server `.sv.jac` + React-in-Jac client
`.cl.jac`, one codebase). Two surfaces:

- **JMS** — projects: sources → synthesize dataset → curate → train (local MLX or
  a BYO remote GPU) → eval → chat with the result. Plus the in-app AI assistant.
- **Experiments** — workspaces with CHAT (registry models), DATA (dataset
  browser) and CLOUD (BYO GPU clusters + supervised remote runs).

Self-contained: runs from the repo root and only reaches outside through the
paths in `studio.workspace.toml`. The fine-tuning experiments (datasets,
adapters, SFT playbook) live in their own repo,
[jaseci-labs/Jac_Model_Experiments](https://github.com/jaseci-labs/Jac_Model_Experiments);
the shipped toml expects it checked out next to this repo:

    git clone https://github.com/jaseci-labs/Jac_Model_Experiments.git ../Jac_Model_Experiments

## Run

    ./start.sh               # dev mode, local single user: API :8001, UI :8000 (auto-opens; JMS_NO_OPEN=1 to skip)

Needs the `jac` on PATH to carry jac-scale + jac-client + mlx-lm (the uv-installed
`jaclang` tool does). Production (multi-tenant, login gate):
`JWT_SECRET=... ./start_prod.sh`, see `deploy/`.

Native desktop window (`--client desktop`) is off: the installed jac-desktop
0.2.0 host serves static files only and never starts the API, so the window
loads but every call 404s.

After editing a `.cl.jac` file restart the server — `--dev` compiles the client
once at boot.

## Config and data

| What | Where | Override |
|------|-------|----------|
| Model registry, dataset files, cloud-run defaults | `studio.workspace.toml` | `$JAC_STUDIO_WORKSPACE/studio.workspace.toml` |
| Base dir for relative paths in the toml | repo root | `JAC_STUDIO_WORKSPACE` |
| Runtime data JMS writes: `results/` (per-user runs, GPU lock), `audit/`, `projects/`, `examples/` | `data/` (gitignored) | `JAC_STUDIO_DATA_ROOT` |
| Graph + users DB, JWT secret | `.jac/` (gitignored) | — |

The shipped toml points at a `Jac_Model_Experiments` checkout next to this repo (base
Qwen3-Coder q4 + the 08 SFT adapter, 08 SFT/DPO datasets). Registry entries take
`path` (MLX model dir) and an optional `adapter` (LoRA dir). Any path may be
missing: the model shows as unavailable and dataset files count 0.

Worker/tool binaries (`jac`, `mlx_lm.lora`) are taken from next to the running
interpreter, then `PATH`; a `.venv/bin` in the repo root is used only as a last-resort
fallback if it exists.

## Layout

    main.jac            registers every endpoint (server imports) + mounts the client
    server/             one package per concern; each dir has an empty __init__.jac
      core/             paths (3 roots + tool lookup), auth, audit, crypto, jobs
                        (detached engine + heavy GPU lock), persistence (chat graph),
                        workspace (toml loader + Experiments graph), metrics, data
      models/           models (registry), inference (resident MLX), chat, assistant,
                        prompts (+ prompts.json)
      jms/              jms_* — JMS product (projects, plan, gen, curate, train, eval, chat, llm)
      cloud/            cloudruns, clusters, backends (BYO GPU runs; uploads remote/)
    client/             frontend.cl.jac, auth_session.cl.jac, components/, hooks/, lib/,
                        styles/ (theme.css, global.css, jms.css)
    assets/             favicon — must stay at the root (jac-scale serve_root_asset)
    remote/             uploaded to GPU boxes
    scripts/            workers (jms_gen_worker, jms_eval_worker), smoke tests, backup/restore, pysite/
    deploy/  docs/      systemd/Caddy units; design specs + JMS write-up

Server modules import each other by package path from the repo root
(`import from server.core { paths }`, `import from server.jms.jms_projects { ... }`).
`.cl.jac` files `sv import` with dots up to the repo root
(`sv import from ...server.core.jobs { ... }` from `client/components/`).
Persisted `node` types carry `@archetype_alias("<old_module>.<Node>")` so graph rows
written before the move still load.

## Test

    jac test server/core/jobs.test.jac   # one annex, FROM THE REPO ROOT (no server needed)
    scripts/smoke.sh                     # while the browser-target server is up
    JAC_API=http://localhost:8001 scripts/smoke_auth.sh

`jac test` must run from the repo root so `server.*` imports resolve.

Tests redirect `JAC_STUDIO_WORKSPACE` / `JAC_STUDIO_DATA_ROOT` to temp dirs. Don't
`jac run` app modules from the repo root while a server is up — it writes the
live `.jac/data` graph.
