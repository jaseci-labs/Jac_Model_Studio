"""Single resident MLX model. 48GB box: exactly one model in memory.

Swap = drop references + gc + mx.clear_cache(), then mlx_lm.load() the new one.
The loader is injectable so tests never touch mlx.
"""
import asyncio
import gc
import time


def _mlx_loader(path: str):
    import mlx_lm  # lazy: keep test imports mlx-free
    return mlx_lm.load(path)


class ModelManager:
    def __init__(self, loader=None):
        self._loader = loader or _mlx_loader
        self.current_id: str | None = None
        self.model = None
        self.tokenizer = None
        self.load_seconds: float = 0.0
        self.lock = asyncio.Lock()  # one load/generation at a time

    def unload(self) -> None:
        self.model = None
        self.tokenizer = None
        self.current_id = None
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except ImportError:
            pass

    def load_sync(self, model_id: str, path: str) -> float:
        """Blocking. Returns seconds spent loading (0.0 if already resident)."""
        if self.current_id == model_id:
            return 0.0
        if self.current_id is not None:
            self.unload()
        t0 = time.monotonic()
        self.model, self.tokenizer = self._loader(path)
        self.load_seconds = round(time.monotonic() - t0, 1)
        self.current_id = model_id
        return self.load_seconds
