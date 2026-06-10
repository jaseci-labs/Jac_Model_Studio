import asyncio
import json
import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

import config
import db
import generate
from model_manager import ModelManager
from sse import sse


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatCreate(BaseModel):
    title: str


class ChatRename(BaseModel):
    title: str


class ChatRequest(BaseModel):
    model_config = {"protected_namespaces": ()}  # allow model_id field
    model_id: str
    messages: list[ChatMessage]
    temperature: float = 0.2
    top_p: float = 0.9
    max_tokens: int = 1024
    chat_id: int | None = None
    pair_group: str | None = None
    persist_user: bool = True


class LoadRequest(BaseModel):
    model_config = {"protected_namespaces": ()}
    model_id: str


def create_app(loader=None, stream_fn=None) -> FastAPI:
    db.init_db()
    app = FastAPI(title="Jac Studio")
    app.state.manager = ModelManager(loader=loader)
    app.state.stream_fn = stream_fn

    @app.get("/api/models")
    def models():
        mgr = app.state.manager
        out = []
        resident_gb = None
        for m in config.MODELS:
            avail = config.model_available(m)
            size = config.dir_size_gb(config.model_path(m)) if avail else None
            if m["id"] == mgr.current_id:
                resident_gb = size
            out.append({"id": m["id"], "label": m["label"], "available": avail, "size_gb": size})
        return {
            "models": out,
            "loaded": mgr.current_id,
            "ram_gb": config.total_ram_gb(),
            "resident_gb": resident_gb,
        }

    @app.get("/api/chats")
    def chats_list():
        return db.list_chats()

    @app.post("/api/chats")
    def chats_create(body: ChatCreate):
        return db.create_chat(body.title)

    @app.get("/api/chats/{chat_id}")
    def chats_get(chat_id: int):
        chat = db.get_chat(chat_id)
        if chat is None:
            raise HTTPException(404)
        return {"chat": chat, "messages": db.get_messages(chat_id)}

    @app.patch("/api/chats/{chat_id}")
    def chats_rename(chat_id: int, body: ChatRename):
        if db.get_chat(chat_id) is None:
            raise HTTPException(404)
        db.rename_chat(chat_id, body.title)
        return {"ok": True}

    @app.delete("/api/chats/{chat_id}")
    def chats_delete(chat_id: int):
        db.delete_chat(chat_id)
        return {"ok": True}

    async def load_events(mgr, model_id: str, path: str):
        """Load model in executor; heartbeat 'loading' events each second."""
        loop = asyncio.get_running_loop()
        fut = loop.run_in_executor(None, mgr.load_sync, model_id, str(path))
        fut.add_done_callback(lambda f: f.cancelled() or f.exception())
        t0 = time.monotonic()
        while not fut.done():
            yield sse({"type": "load", "status": "loading", "model_id": model_id,
                       "elapsed": round(time.monotonic() - t0, 1)})
            try:
                await asyncio.wait_for(asyncio.shield(fut), timeout=1.0)
            except asyncio.TimeoutError:
                pass
        secs = await fut  # re-raises load errors
        yield sse({"type": "load", "status": "ready", "model_id": model_id, "seconds": secs})

    @app.post("/api/chat")
    async def chat(req: ChatRequest):
        mgr = app.state.manager
        stream_fn = app.state.stream_fn or generate.stream_tokens

        async def gen():
            m = config.model_by_id(req.model_id)
            if m is None:
                yield sse({"type": "error", "message": f"unknown model: {req.model_id}"})
                return
            if not config.model_available(m):
                yield sse({"type": "error",
                           "message": f"model not found on disk: {config.model_path(m)}"})
                return

            if req.chat_id is not None and req.persist_user and req.messages:
                try:
                    db.add_message(req.chat_id, "user", req.messages[-1].content)
                except Exception as e:
                    print(f"history write failed: {e}")

            async with mgr.lock:
                load_secs = 0.0
                try:
                    if mgr.current_id != req.model_id:
                        async for ev in load_events(mgr, req.model_id, config.model_path(m)):
                            yield ev
                        load_secs = mgr.load_seconds
                except Exception as e:
                    mgr.unload()
                    yield sse({"type": "error", "message": f"load failed: {e}"})
                    return

                loop = asyncio.get_running_loop()
                q: asyncio.Queue = asyncio.Queue()
                msgs = [mm.model_dump() for mm in req.messages]
                stop = threading.Event()

                def worker():
                    try:
                        for text, ntok, tps in stream_fn(mgr.model, mgr.tokenizer, msgs,
                                                         req.temperature, req.top_p,
                                                         req.max_tokens):
                            if stop.is_set():
                                break
                            loop.call_soon_threadsafe(q.put_nowait, ("token", text, ntok, tps))
                        loop.call_soon_threadsafe(q.put_nowait, ("end", None, None, None))
                    except Exception as e:  # surfaced as SSE error event
                        loop.call_soon_threadsafe(q.put_nowait, ("error", str(e), None, None))

                loop.run_in_executor(None, worker)
                t0 = time.monotonic()
                full, gen_tokens, tps = "", 0, 0.0
                try:
                    while True:
                        kind, text, ntok, ntps = await q.get()
                        if kind == "token":
                            full += text
                            gen_tokens, tps = ntok, ntps
                            yield sse({"type": "token", "text": text})
                        elif kind == "error":
                            yield sse({"type": "error", "message": text})
                            return
                        else:
                            break
                    stats = {"type": "stats", "model_id": req.model_id,
                             "gen_tokens": gen_tokens, "tps": tps,
                             "seconds": round(time.monotonic() - t0, 1),
                             "load_seconds": load_secs}
                    yield sse(stats)
                    if req.chat_id is not None:
                        try:
                            db.add_message(req.chat_id, "assistant", full,
                                           model_id=req.model_id, stats=stats,
                                           pair_group=req.pair_group)
                        except Exception as e:
                            print(f"history write failed: {e}")
                    yield sse({"type": "done"})
                finally:
                    stop.set()

        return StreamingResponse(gen(), media_type="text/event-stream")

    @app.post("/api/load")
    async def load(req: LoadRequest):
        mgr = app.state.manager

        async def gen():
            m = config.model_by_id(req.model_id)
            if m is None:
                yield sse({"type": "error", "message": f"unknown model: {req.model_id}"})
                return
            if not config.model_available(m):
                yield sse({"type": "error",
                           "message": f"model not found on disk: {config.model_path(m)}"})
                return
            async with mgr.lock:
                try:
                    async for ev in load_events(mgr, req.model_id, config.model_path(m)):
                        yield ev
                except Exception as e:
                    mgr.unload()
                    yield sse({"type": "error", "message": f"load failed: {e}"})

        return StreamingResponse(gen(), media_type="text/event-stream")

    @app.get("/api/prompts")
    def prompts():
        p = Path(__file__).parent / "prompts.json"
        return json.loads(p.read_text())

    return app


app = create_app()
