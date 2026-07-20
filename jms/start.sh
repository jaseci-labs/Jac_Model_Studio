#!/bin/bash
# Jac ML Studio (pure Jac): one process serves the API (:8001) + Vite UI (:8000).
# Ctrl-C stops it. The old FastAPI+Next app (server/, ui/) was replaced by studio/.
set -e
cd "$(dirname "$0")"

export JAC_STUDIO_DATA_ROOT="${JAC_STUDIO_DATA_ROOT:-/Volumes/ExtremePro/JaseciLabs/jac_model_studio}"

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

exec jac start --dev main.jac
