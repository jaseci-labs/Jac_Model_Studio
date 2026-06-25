"""studio - streaming chat endpoint (SSE).

`chat_stream` takes the full message history + sampling params and streams real
MLX tokens. Returns a generator → the runtime serves it as `text/event-stream`,
consumed by a raw fetch reader on the client. Persistence (chat/message nodes)
is handled separately via the persistence.sv.jac walkers the client calls.

Frames: {kind:"load",load_s} once, {kind:"token",token,text} per token,
{kind:"done",text,tokens,tps,load_s,gen_s} last, {kind:"error",text} on failure.
"""

import time;
import inference;
import models;

def:pub chat_stream(
    messages: list[dict], model_id: str, temperature: float, top_p: float, max_tokens: int
) -> any {
    m = models.model_by_id(model_id);
    if not m {
        yield {"kind": "error", "text": f"unknown model_id: {model_id}"};
        return;
    }
    path = str(models.model_path(m));
    load_s = inference.load_sync(model_id, path);
    yield {"kind": "load", "load_s": load_s, "model_id": model_id};

    acc = "";
    last: any = None;
    t0 = time.monotonic();
    gen: any = inference.stream_tokens(messages, temperature, top_p, max_tokens);
    for frame in gen {
        chunk = str(frame["text"]);
        acc += chunk;
        last = frame;
        yield {"kind": "token", "token": chunk, "text": acc};
    }
    yield {
        "kind": "done",
        "text": acc,
        "tokens": last["tokens"] if last else 0,
        "tps": last["tps"] if last else 0.0,
        "load_s": load_s,
        "gen_s": time.monotonic() - t0
    };
}
