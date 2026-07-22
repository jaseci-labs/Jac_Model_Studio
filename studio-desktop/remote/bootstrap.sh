#!/usr/bin/env bash
# Bootstrap a fresh Spheron Ubuntu VM for a studio training run.
# Run by supervisor.py as:  cd <remote_dir> && bash bootstrap.sh > provision.log 2>&1 && touch .provisioned
# Exit codes: 0 ok, 3 no GPU (unless ALLOW_NO_GPU=1).
set -euo pipefail

echo "== bootstrap.sh starting: $(date -u +%FT%TZ) =="

# --- OS packages (best-effort; tolerate missing sudo) -----------------------
install_pkgs() {
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n apt-get update -y && sudo -n apt-get install -y rsync python3-venv python3-pip
    else
        apt-get update -y && apt-get install -y rsync python3-venv python3-pip
    fi
}
install_pkgs || echo "WARNING: apt-get install failed (no sudo / no apt?); continuing with what's available"

# --- GPU check ---------------------------------------------------------------
HAS_GPU=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    HAS_GPU=1
    nvidia-smi || true
else
    if [ "${ALLOW_NO_GPU:-0}" = "1" ]; then
        echo "WARNING: nvidia-smi not found/working; continuing (ALLOW_NO_GPU=1)"
    else
        echo "ERROR: nvidia-smi not found/working and ALLOW_NO_GPU is not set" >&2
        exit 3
    fi
fi

# --- Python venv + requirements ---------------------------------------------
python3 -m venv .venv
.venv/bin/pip install -U pip
if [ -f requirements.txt ]; then
    .venv/bin/pip install -r requirements.txt
else
    echo "WARNING: no requirements.txt uploaded; skipping pip install -r"
fi
if [ "$HAS_GPU" = "1" ]; then
    # bitsandbytes only makes sense with CUDA present
    .venv/bin/pip install bitsandbytes || echo "WARNING: bitsandbytes install failed; continuing"
fi

# --- Torch sanity ------------------------------------------------------------
.venv/bin/python - <<PYEOF
import sys
try:
    import torch
except Exception as e:
    print("ERROR: torch import failed: %s" % e, file=sys.stderr)
    sys.exit(4)
print("torch", torch.__version__)
if ${HAS_GPU}:
    assert torch.cuda.is_available(), "GPU present but torch.cuda.is_available() is False"
    print("cuda ok:", torch.cuda.get_device_name(0))
PYEOF

echo "== bootstrap.sh done: $(date -u +%FT%TZ) =="
