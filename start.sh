#!/bin/bash
# Jac ML Studio (pure Jac), dev mode: API on :8001, UI on :8000 (opens in your
# browser), local single user. Ctrl-C stops it.
#
# Web target, not `--client desktop`: the installed jac-desktop 0.2.0 is an MVP
# whose host only serves static files and never starts the API (every
# /function/* call 404s), and the uv-installed copy only builds on Linux
# (WebKitGTK). Revisit when jac-desktop runs the sv codespace in-process.
set -e
cd "$(dirname "$0")"

_STUDIO_DIR="$(pwd)"
# Paths: JAC_STUDIO_WORKSPACE (base for studio.workspace.toml paths, default
# this dir) and JAC_STUDIO_DATA_ROOT (runtime writes, default ./data) are read
# by server/core/paths.sv.jac; only pass them through when set. See README.md.

# SQLite concurrency hardening — see scripts/pysite/sitecustomize.py for the
# full root-cause writeup. Short version: jac-scale opens a NEW sqlite
# connection to .jac/data/anchor_store.db per HTTP request and re-runs a schema
# write on it, both jaclang connect sites keep the stdlib 5s busy timeout, and
# users.db is left in DELETE journal mode by SQLAlchemy — so two concurrent
# browser sessions made unrelated read endpoints 500 with
# "sqlite3.OperationalError: database is locked". None of that is reachable
# from jac.toml, so the wrapper is installed via PYTHONPATH/sitecustomize,
# which CPython imports before any jac code runs. Must stay exported:
# detached worker subprocesses hit the same databases.
export PYTHONPATH="$_STUDIO_DIR/scripts/pysite${PYTHONPATH:+:$PYTHONPATH}"

# --- Open-file ceiling (must be raised BEFORE the process exists) -------------
# UPSTREAM BUG (jaclang): `--dev` makes jaclang watch the WHOLE project via
# `JacFileWatcher(watch_paths=[base])` — recursive, no ignore list
# (jaclang/cli/commands/impl/execution.impl.jac). On macOS watchdog uses its
# kqueue backend, which needs ONE OPEN FD PER WATCHED FILE AND DIRECTORY.
# Measured with lsof on a live dev server: 17,481 fds held at idle, 11,113 of
# them inside .jac/client/node_modules (es-toolkit alone 3,976). That is the fd
# floor before the app serves a single request.
#
# NOTE the `[client.vite.server.watch].ignored` list in jac.toml is unrelated to
# this: it governs the Vite *node child*, which holds only ~50 fds. The leak is
# entirely on the Python side and cannot be configured away from this repo.
#
# launchd gives GUI-launched processes a soft limit of 256 (`launchctl limit
# maxfiles`), so the watcher alone exhausts it and the first local model load
# dies with `[Errno 24] Too many open files` — after which EVERY endpoint 500s
# until a restart. Raising it here covers the watcher itself; the in-process
# fallback in server/models/inference.sv.jac (_raise_fd_limit) cannot retroactively fix opens
# that already failed during boot. macOS caps any request at kern.maxfilesperproc
# (184320 here); 65536 is ample and leaves ~48k headroom over the watcher.
# `-S` matters: bare `ulimit -n N` in bash sets the HARD limit too, permanently
# capping this process at N. `-S` raises only the soft limit and leaves hard
# alone, so the fallback below can still reach for the hard ceiling.
if ! ulimit -S -n 65536 2>/dev/null; then
  ulimit -S -n "$(ulimit -Hn)" 2>/dev/null || true
fi
echo "[start.sh] open-file limit: soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

# Local single-user mode: the client auto-provisions one implicit local user
# and skips the login screen (see client/frontend.cl.jac / auth.local_mode). Production
# (start_prod.sh) deliberately leaves this unset so the real login gate shows.
export JAC_LOCAL_USER="${JAC_LOCAL_USER:-1}"

# JWT signing secret for dev. jac.toml's [plugins.scale.jwt] interpolates
# ${JWT_SECRET:-...} at config load, and jac-scale's own default is the public,
# git-committed 'supersecretkey_for_testing_only!'. Generate a random per-machine
# value once and CACHE it under .jac/ (gitignored) so it is stable across
# restarts: JWT_SECRET is also the secret-at-rest master key when JAC_SECRET_KEY
# is unset (server/core/crypto.sv.jac), so a fresh value each boot would log the user out
# every restart AND make already-encrypted provider API keys undecryptable.
# Prod does the opposite on purpose: start_prod.sh REQUIRES an externally
# provided JWT_SECRET and never generates one.
_JWT_FILE="$_STUDIO_DIR/.jac/jwt_secret"
if [[ -z "${JWT_SECRET:-}" && ! -s "$_JWT_FILE" ]]; then
  mkdir -p "$(dirname "$_JWT_FILE")"
  # `head -c 32 /dev/urandom | xxd` fallback keeps this working without openssl.
  { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p | tr -d '\n'; } > "$_JWT_FILE"
  chmod 600 "$_JWT_FILE"
fi
if [[ -s "$_JWT_FILE" ]]; then
  export JWT_SECRET="${JWT_SECRET:-$(cat "$_JWT_FILE")}"
fi
unset _JWT_FILE

# jac 0.30+ places client_runtime_core.js in compiled/, but older .jac/client
# artifacts import ./jaclang/runtimelib/client_runtime_core.js. Symlink the legacy
# path so Vite can resolve it on dev startup; drop stale runtime so jac re-emits it.
RUNTIME_DIR=".jac/client/compiled"
RUNTIME_JS="$RUNTIME_DIR/client_runtime.js"
CORE_JS="$RUNTIME_DIR/client_runtime_core.js"
LEGACY_CORE="$RUNTIME_DIR/jaclang/runtimelib/client_runtime_core.js"

if [[ -f "$CORE_JS" ]]; then
  mkdir -p "$(dirname "$LEGACY_CORE")"
  ln -sfn "../../client_runtime_core.js" "$LEGACY_CORE"
fi

if [[ -f "$RUNTIME_JS" ]] && grep -q 'jaclang/runtimelib/client_runtime_core' "$RUNTIME_JS"; then
  rm -f "$RUNTIME_JS"
fi

# The dev-mode full-reload loop (desktop SQLite anchor store inside the Vite
# watch root triggering a polling-watcher reload on every WAL write) is now
# fixed durably in jac.toml via [plugins.client.vite.server.watch].ignored --
# that injects a `watch` override into the generated vite.dev.config.js (in a
# JS object literal the last duplicate key wins), so it survives `jac start`'s
# config regeneration AND runtime reinstalls. The previous in-place perl patch
# lived here but ran BEFORE `exec jac start`, which regenerates the config ~13s
# into startup and wiped it. Do not re-add an in-place config patch here.

# `--dev` file watching needs watchdog importable from the project venv (jac's
# sitecustomize puts .jac/venv on sys.path). Force --target into the venv
# site-packages: plain `pip install` no-ops when watchdog lives elsewhere.
_VENV_PY="$_STUDIO_DIR/.jac/venv/bin/python"
_VENV_SP="$_STUDIO_DIR/.jac/venv/lib/python3.14/site-packages"
if [[ -x "$_VENV_PY" ]]; then
  if [[ ! -d "$_VENV_SP/watchdog" ]]; then
    mkdir -p "$_VENV_SP"
    "$_VENV_PY" -m pip install --upgrade --force-reinstall --no-deps \
      --target "$_VENV_SP" 'watchdog>=3.0.0' >/dev/null
  fi
fi
unset _VENV_PY _VENV_SP

# Open the UI once Vite answers (background; JMS_NO_OPEN=1 to skip).
if [[ -z "${JMS_NO_OPEN:-}" ]] && command -v open >/dev/null; then
  ( for _ in $(seq 1 180); do
      curl -sf -o /dev/null -m 2 http://localhost:8000/ && { open http://localhost:8000/; break; }
      sleep 1
    done ) &
fi

exec jac start --dev main.jac
