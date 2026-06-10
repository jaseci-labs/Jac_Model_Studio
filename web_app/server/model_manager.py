"""Single resident MLX model. 48GB box: exactly one model in memory.

Swap = drop references + gc + mx.clear_cache(), then mlx_lm.load() the new one.
The loader is injectable so tests never touch mlx.
"""
import asyncio
import gc
import threading
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
        self._thread_lock = threading.Lock()

    def _unload_locked(self) -> None:
        """Unload without acquiring _thread_lock (caller must hold it)."""
        self.model = None
        self.tokenizer = None
        self.current_id = None
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except (ImportError, AttributeError):
            pass

    def unload(self) -> None:
        with self._thread_lock:
            self._unload_locked()

    def load_sync(self, model_id: str, path: str) -> float:
        """Blocking. Returns seconds spent loading (0.0 if already resident)."""
        with self._thread_lock:
            if self.current_id == model_id:
                self.load_seconds = 0.0
                return 0.0
            if self.current_id is not None:
                self._unload_locked()
            t0 = time.monotonic()
            self.model, self.tokenizer = self._loader(path)
            self.load_seconds = round(time.monotonic() - t0, 1)
            self.current_id = model_id
            return self.load_seconds
