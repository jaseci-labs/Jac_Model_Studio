"""studio - streaming chat endpoint (SSE).

`chat_stream` validates the model then delegates to `inference.stream_chat`, which
holds a single lock across load+generate so a concurrent request can't swap the
resident model mid-stream. The runtime serves the generator as `text/event-stream`,
consumed by a raw fetch reader on the client. Persistence (chat/message nodes) is
handled separately via the persistence.sv.jac walkers the client calls.

Frames: {kind:"load",load_s,model_id} once, {kind:"token",token,text} per token,
{kind:"done",text,tokens,tps,load_s,gen_s} last, {kind:"error",text} on failure.
"""

import from server.core { jobs }
import from server.models { inference }
import server.models.models as models;  # not `import from server.models { models }`: jac check resolves that to the package

def chat_stream(
    messages: list[dict], model_id: str,
    temperature: float = 0.2, top_p: float = 0.9, max_tokens: int = 1024
) -> any {
    # Loading/running a model in this server while a train/eval/gen job owns the
    # GPU slot can OOM the box (48 GB). Check, don't acquire — see jobs.heavy_busy.
    busy = jobs.heavy_busy();
    if busy {
        yield {"kind": "error", "text": f"GPU busy: {busy} is running — chat is paused until it finishes"};
        return;
    }
    m = models.model_by_id(model_id);
    if not m {
        yield {"kind": "error", "text": f"unknown model_id: {model_id}"};
        return;
    }
    if not models.model_available(m) {
        yield {"kind": "error", "text": f"model not found on disk: {model_id}"};
        return;
    }
    path = str(models.model_path(m));
    # stream_chat guards load+generate in try/except and emits its own error frame.
    gen: any = inference.stream_chat(
        messages, model_id, path, temperature, top_p, max_tokens, models.model_adapter_path(m)
    );
    for frame in gen {
        yield frame;
    }
}
