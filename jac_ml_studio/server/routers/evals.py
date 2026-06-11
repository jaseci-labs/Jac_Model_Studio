"""APIRouter for /api/evals — eval-run lifecycle endpoints."""

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import config
import db
import evalruns
import procs

router = APIRouter(prefix="/api/evals")

VALID_KINDS = {"probe", "idiom"}
VALID_HOLDOUTS = set(config.HOLDOUTS.keys())


class EvalRequest(BaseModel):
    model_config = {"protected_namespaces": ()}
    kind: str
    model_id: str | None = None
    model_path: str | None = None
    adapter: str | None = None
    holdout: str = "function"
    limit: int | None = None
    sim_threshold: float | None = None


def _resolve_model_rel(body: EvalRequest) -> str:
    """Return model path relative to data_root, or raise HTTPException."""
    if body.model_id is not None:
        m = config.model_by_id(body.model_id)
        if m is None:
            raise HTTPException(400, f"unknown model_id: {body.model_id}")
        # Must be available on disk
        if not config.model_available(m):
            raise HTTPException(400, f"model not on disk: {m['path']}")
        return m["path"]

    if body.model_path is not None:
        p = body.model_path
        if not procs.safe(p, allow_slash=True):
            raise HTTPException(400, "invalid model_path")
        resolved = (config.data_root() / p).resolve()
        if not resolved.is_relative_to(config.data_root().resolve()):
            raise HTTPException(400, "model_path escapes data root")
        return p

    raise HTTPException(400, "model_id or model_path required")


def _resolve_adapter_rel(adapter: str | None) -> str | None:
    if adapter is None:
        return None
    if not procs.safe(adapter, allow_slash=True):
        raise HTTPException(400, "invalid adapter path")
    resolved = (config.data_root() / adapter).resolve()
    if not resolved.is_relative_to(config.data_root().resolve()):
        raise HTTPException(400, "adapter escapes data root")
    return adapter


@router.post("", status_code=201)
def create_eval(body: EvalRequest):
    if body.kind not in VALID_KINDS:
        raise HTTPException(400, f"kind must be one of {sorted(VALID_KINDS)}")
    if body.holdout not in VALID_HOLDOUTS:
        raise HTTPException(400, f"holdout must be one of {sorted(VALID_HOLDOUTS)}")

    model_rel = _resolve_model_rel(body)
    adapter_rel = _resolve_adapter_rel(body.adapter)

    params: dict = {}
    if body.limit is not None:
        params["limit"] = body.limit
    if body.sim_threshold is not None:
        params["sim_threshold"] = body.sim_threshold

    row = db.create_eval_run(
        kind=body.kind,
        model=model_rel,
        adapter=adapter_rel,
        holdout=body.holdout,
        params=params,
    )
    pid = evalruns.start(
        kind=body.kind,
        model_path_rel=model_rel,
        adapter_rel=adapter_rel,
        holdout_key=body.holdout,
        limit=body.limit,
        sim_threshold=body.sim_threshold,
        eval_id=row["id"],
    )
    db.set_eval_pid(row["id"], pid)
    return db.get_eval_run(row["id"])


@router.get("")
def list_evals():
    rows = db.list_eval_runs()
    return {"evals": [evalruns.refresh(r) for r in rows]}


@router.get("/{eval_id}")
def get_eval(eval_id: int):
    row = db.get_eval_run(eval_id)
    if row is None:
        raise HTTPException(404)
    row = evalruns.refresh(row)
    ed = evalruns.eval_dir(eval_id)
    row["log_tail"] = evalruns.runlogs.tail(ed / "run.log", 60)
    return row


@router.post("/{eval_id}/stop")
def stop_eval(eval_id: int):
    row = db.get_eval_run(eval_id)
    if row is None:
        raise HTTPException(404)
    return evalruns.stop_eval(row)


@router.delete("/{eval_id}")
def delete_eval(eval_id: int):
    row = db.get_eval_run(eval_id)
    if row is None:
        raise HTTPException(404)
    evalruns.remove(row)
    return {"ok": True}
