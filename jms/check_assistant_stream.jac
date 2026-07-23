"""studio - self-check for assistant.sv.jac (Task A3: grounded streaming chat
over MLX/Claude/OpenAI).

Run with `JAC_LOCAL_USER=1 jac run check_assistant_stream.jac` from jms/.

Only exercises paths that don't need mlx or a live API key (neither is
available in this worktree's serving venv / environment):
  - provider="claude" with NO anthropic key configured → must yield a single
    {kind:"error"} frame whose text mentions the key, never raise.
  - provider="bogus" → must yield a single {kind:"error"} frame, never raise.
The mlx branch is intentionally NOT exercised here — mlx isn't installed in
this worktree, so calling it would crash on `import from mlx_lm { ... }`
inside inference.stream_chat, not test assistant_stream's own logic. Its
correctness is by construction: it mirrors chat.sv.jac:chat_stream's model
resolution + delegation verbatim, which IS exercised at integration.
"""

import from assistant { assistant_stream }

with entry {
    # --- no-key path (claude) ---------------------------------------------
    frames_claude: list[dict] = [];
    gen_claude: any = assistant_stream(
        [{"role": "user", "content": "hi"}], "claude", "claude-sonnet-5"
    );
    for frame in gen_claude {
        frames_claude.append(frame);
    }
    assert len(frames_claude) == 1, f"expected exactly 1 frame, got {len(frames_claude)}";
    assert frames_claude[0]["kind"] == "error", "expected an error frame with no key configured";
    assert "key" in frames_claude[0]["text"], "error text should mention the missing key";
    print("claude no-key frame:", frames_claude[0]);

    # --- unknown provider ---------------------------------------------------
    frames_bogus: list[dict] = [];
    gen_bogus: any = assistant_stream(
        [{"role": "user", "content": "hi"}], "bogus", "whatever"
    );
    for frame in gen_bogus {
        frames_bogus.append(frame);
    }
    assert len(frames_bogus) == 1, f"expected exactly 1 frame, got {len(frames_bogus)}";
    assert frames_bogus[0]["kind"] == "error", "expected an error frame for an unknown provider";
    print("bogus provider frame:", frames_bogus[0]);

    print("OK");
}
