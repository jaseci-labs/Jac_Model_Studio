from fastapi import FastAPI

import config


def create_app(loader=None, stream_fn=None) -> FastAPI:
    app = FastAPI(title="Jac Studio")
    app.state.loader = loader
    app.state.stream_fn = stream_fn

    @app.get("/api/models")
    def models():
        out = []
        for m in config.MODELS:
            avail = config.model_available(m)
            out.append({
                "id": m["id"],
                "label": m["label"],
                "available": avail,
                "size_gb": config.dir_size_gb(config.model_path(m)) if avail else None,
            })
        return {
            "models": out,
            "loaded": None,
            "ram_gb": config.total_ram_gb(),
            "resident_gb": None,
        }

    return app


app = create_app()
