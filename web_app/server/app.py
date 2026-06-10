from fastapi import FastAPI

import config
from model_manager import ModelManager


def create_app(loader=None, stream_fn=None) -> FastAPI:
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

    return app


app = create_app()
