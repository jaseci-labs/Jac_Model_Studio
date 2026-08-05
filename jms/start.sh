#!/bin/bash
# Jac ML Studio (pure Jac): runs as a native DESKTOP app. One process embeds the
# in-process API + serves the cl UI via Vite on loopback, rendered in the
# OS-native webview (WebKitGTK on Linux). `jac setup desktop` initializes the
# target; this builds (if needed) then launches the native window. Ctrl-C stops it.
# (For the browser/web target instead of a native window, drop `--client desktop`.)
set -e
cd "$(dirname "$0")"

_STUDIO_DIR="$(pwd)"
_WORKSPACE_DEFAULT="$(dirname "$_STUDIO_DIR")"
export JAC_STUDIO_WORKSPACE="${JAC_STUDIO_WORKSPACE:-$_WORKSPACE_DEFAULT}"
export JAC_STUDIO_DATA_ROOT="${JAC_STUDIO_DATA_ROOT:-$JAC_STUDIO_WORKSPACE}"

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
# fallback in inference.sv.jac (_raise_fd_limit) cannot retroactively fix opens
# that already failed during boot. macOS caps any request at kern.maxfilesperproc
# (184320 here); 65536 is ample and leaves ~48k headroom over the watcher.
# `-S` matters: bare `ulimit -n N` in bash sets the HARD limit too, permanently
# capping this process at N. `-S` raises only the soft limit and leaves hard
# alone, so the fallback below can still reach for the hard ceiling.
if ! ulimit -S -n 65536 2>/dev/null; then
  ulimit -S -n "$(ulimit -Hn)" 2>/dev/null || true
fi
echo "[start.sh] open-file limit: soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

# Local single-user desktop: the client auto-provisions one implicit local user
# and skips the login screen (see frontend.cl.jac / auth.local_mode). Production
# (start_prod.sh) deliberately leaves this unset so the real login gate shows.
export JAC_LOCAL_USER="${JAC_LOCAL_USER:-1}"

# JWT signing secret for dev. jac.toml's [plugins.scale.jwt] interpolates
# ${JWT_SECRET:-...} at config load, and jac-scale's own default is the public,
# git-committed 'supersecretkey_for_testing_only!'. Generate a random per-machine
# value once and CACHE it under .jac/ (gitignored) so it is stable across
# restarts: JWT_SECRET is also the secret-at-rest master key when JAC_SECRET_KEY
# is unset (crypto.sv.jac), so a fresh value each boot would log the user out
# every restart AND make already-encrypted Spheron credentials undecryptable.
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

# Desktop target runs the sv codespace in-process on an isolated, bundled Python
# (under ~/.cache/jac/rt/<hash>/site). jaclang's wheel declares no deps, so that
# bundle is missing the jac-scale server stack (bcrypt, sqlalchemy, fastapi,
# pymongo, pyjwt, ...). The native host appends every dir in JAC_DESKTOP_DEPS to
# sys.path at boot, so we point it at a project-local deps dir pinned to jac-scale.
# Re-populate with: pip install --target .jac/desktop_deps <see README>.
export JAC_DESKTOP_DEPS="${JAC_DESKTOP_DEPS:-$_STUDIO_DIR/.jac/desktop_deps}"

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

# UPSTREAM BUG (jaclang): the desktop runtime invokes the libwebview build
# helper by path (subprocess.run(["build_libwebview.sh"])), but the wheel
# extracts it without the execute bit (mode 644), so the first dev launch dies
# with PermissionError. The runtime chmod's its own launcher elsewhere but
# missed these two helpers. Each jac version keeps its own dir under
# ~/.cache/jac/rt/<hash>/... and a fresh extraction resets perms, so sweep every
# hash dir and set +x before launch. (On a machine with an empty cache, the
# very first start extracts then fails before this runs; every later start is
# self-healing.)
while IFS= read -r -d '' _wv_sh; do
  chmod +x "$_wv_sh"
done < <(find "$HOME/.cache/jac/rt" -path '*/desktop/native/webview/*.sh' -not -path '*/.tmp.*' -print0 2>/dev/null)
unset _wv_sh

# UPSTREAM BUG (jaclang 0.30.x): desktop --dev calls ensure_watchdog_common(),
# which on ImportError does `console.warning(..., style="muted")`. JacConsole
# .warning() only accepts (message, emoji=True) — the unexpected `style` kwarg
# turns a soft "HMR won't refresh" warning into a hard crash, so the native
# window never opens / never paints. Two mitigations:
#   1) Keep watchdog importable from the project venv (jac's sitecustomize puts
#      .jac/venv on sys.path). Force --target into the venv site-packages:
#      plain `pip install` no-ops when watchdog already lives in the ephemeral
#      ~/.cache/jac/rt/<hash>/site (wiped on re-extract / concurrent jac fights).
#   2) Strip the bad `style="muted"` from any extracted client_dev_common.jac
#      so a missing watchdog degrades to a warning instead of aborting launch.
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

while IFS= read -r -d '' _wd_jac; do
  # Idempotent: only rewrites copies that still have the bad kwarg.
  if grep -q 'style="muted"' "$_wd_jac" 2>/dev/null; then
    perl -i -0pe 's/(watchdog not installed[^\n]*\n\s*"[^"]*",)\s*\n\s*style="muted"\s*\n/$1\n/s' "$_wd_jac"
  fi
done < <(find "$HOME/.cache/jac/rt" -name 'client_dev_common.jac' -not -path '*/.tmp.*' -print0 2>/dev/null)
unset _wd_jac

exec jac start --client desktop --dev main.jac
