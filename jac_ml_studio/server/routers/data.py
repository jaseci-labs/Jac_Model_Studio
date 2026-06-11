"""APIRouters for /api/dataset and /api/builders endpoints."""

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

import builders
import datasets

# ---------------------------------------------------------------------------
# Dataset router  (/api/dataset)
# ---------------------------------------------------------------------------

dataset_router = APIRouter(prefix="/api/dataset")


class ExamplesRequest(BaseModel):
    target: str
    text: str


@dataset_router.get("/stats")
def get_stats():
    return datasets.stats()


@dataset_router.get("/files")
def get_files():
    return {"files": datasets.list_files()}


@dataset_router.get("/rows")
def get_rows(path: str, offset: int = Query(default=0, ge=0), limit: int = Query(default=25, ge=1)):
    try:
        return datasets.rows(path, offset, limit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@dataset_router.post("/examples")
def post_examples(body: ExamplesRequest):
    try:
        return datasets.add_examples(body.target, body.text)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


# ---------------------------------------------------------------------------
# Builder router  (/api/builders)
# ---------------------------------------------------------------------------

builder_router = APIRouter(prefix="/api/builders")


class RunRequest(BaseModel):
    stage: str


@builder_router.get("")
def get_all_builders():
    return {"builders": builders.all_status()}


@builder_router.post("/run")
def post_run(body: RunRequest):
    try:
        return builders.run(body.stage)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@builder_router.get("/{stage}")
def get_builder_status(stage: str):
    try:
        return builders.status(stage)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
