"""App self-update: restart server+ui from the current checkout's code."""
from pathlib import Path
from fastapi import APIRouter, HTTPException
import procs

APP_DIR = Path(__file__).resolve().parents[2]  # jac_ml_studio/

router = APIRouter(prefix="/api/system")


@router.post("/update")
def update():
    script = APP_DIR / "update.sh"
    if not script.is_file():
        raise HTTPException(500, "update.sh missing")
    import subprocess
    p = subprocess.Popen(["/bin/bash", str(script)], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True, "pid": p.pid, "message": "restarting · back in about 20s"}
