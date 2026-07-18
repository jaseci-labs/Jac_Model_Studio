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

# Local single-user desktop: the client auto-provisions one implicit local user
# and skips the login screen (see frontend.cl.jac / auth.local_mode). Production
# (start_prod.sh) deliberately leaves this unset so the real login gate shows.
export JAC_LOCAL_USER="${JAC_LOCAL_USER:-1}"

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

exec jac start --client desktop --dev main.jac
