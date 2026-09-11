# Jac Studio — local chatbot for trained Gemma/Qwen models

**Date:** 2026-06-10
**Status:** Approved
**Workspace:** new git worktree off `probe-harness-and-graph-tier`; app lives in `web_app/`

## Purpose

A local web app to demo the fine-tuned Jac models in a chatbot interface. Lets the user
pick between trained Gemma and Qwen variants, chat multi-turn, fire curated preloaded
prompts or write their own, and compare two models side by side. Everything runs on this
Mac — no external services, no telemetry, no cloud calls.

## Models

Four entries in the model picker, all fused Q8 MLX models already on disk:

| Picker label | Path |
|---|---|
| Qwen · DPO | `models/qwen-jac-dpo-fused-q8` |
| Gemma · DPO | `models/gemma-jac-dpo-fused-q8` |
| Qwen · SFT | `models/qwen-jac-fused-q8` |
| Gemma · SFT | `models/gemma-jac-fused-q8` |

Constraint: 48GB unified memory; each model is ~17–30GB. **Exactly one model resident at
a time.** Switching models = unload current (drop references, `mx.clear_cache()`) → load
new one. Load takes ~20–40s; the UI shows an explicit loading state with elapsed time,
never a frozen screen.

## Architecture

Two processes under `web_app/`, started together by `web_app/start.sh`:

```
web_app/
  ui/        Next.js (App Router) + Tailwind + shadcn/ui     → http://localhost:3000
  server/    FastAPI + mlx_lm, Python venv                   → http://localhost:8400
  test/      brainstorm mockups (already exists, kept)
  start.sh   boots server then ui, Ctrl-C kills both
```

The UI talks only to the FastAPI server. The server is the single owner of model state.

### FastAPI endpoints

| Endpoint | Method | Behavior |
|---|---|---|
| `/api/models` | GET | Static list of 4 models + which one is loaded + memory info |
| `/api/load` | POST | `{model_id}` — swap resident model. Streams progress events (unloading / loading / ready) via SSE so the UI can show load progress |
| `/api/chat` | POST | `{model_id, messages[], temperature, top_p, max_tokens}` — SSE stream of tokens, terminated by a stats event (tok/s, generation tokens, wall time). If `model_id` isn't resident, server auto-loads first (emitting load events on the same stream) |
| `/api/chats` | GET/POST | List chats / create chat |
| `/api/chats/{id}` | GET/PATCH/DELETE | Fetch messages / rename / delete |
| `/api/prompts` | GET | Serve `prompts.json` |

### Inference

Mirrors the probe harness (`srccurrent/jacgen/eval_probe.jac`):

- `mlx_lm.load(path)` once per swap; held in a module-level singleton with an asyncio lock
  (one generation at a time — concurrent requests queue).
- Prompt built with `tokenizer.apply_chat_template(messages, add_generation_prompt=True)`
  over the **full multi-turn message history**. No system prompt — training data had none.
- `mlx_lm.stream_generate(...)` yields text chunks plus `generation_tokens` and
  `generation_tps`; chunks are forwarded as SSE events, final stats event carries
  tok/s, token count, duration, and model load time when a load happened.
- Generation runs in a thread executor so the event loop stays responsive.
- Default sampling: temperature 0.2, top_p 0.9, max_tokens 1024 — all overridable per
  request from the UI sliders.

### Compare mode

Sequential by necessity (48GB): UI sends the same prompt to model A via `/api/chat`,
waits for completion, then to model B. The server's auto-load handles the swap; the
load events render as a "swapping to Gemma · DPO… 12s" state in B's pane. Both panes
show their own stats. Compare turns are stored in the chat history as paired responses.

### Persistence

SQLite at `web_app/server/data/chats.db` (Python stdlib `sqlite3`). Tables:

- `chats(id, title, created_at, updated_at)`
- `messages(id, chat_id, role, content, model_id, stats_json, pair_group, created_at)`
  — `pair_group` non-null for compare-mode response pairs.

Title auto-derived from first user message (first ~40 chars). No accounts, no auth —
localhost only (server binds 127.0.0.1).

## Preloaded prompts

`web_app/server/prompts.json`, ~30 prompts in 4 categories:

| Category | Source |
|---|---|
| Python → Jac | ~12 picked from `dataset/eval_holdout/conversion.jsonl` `prompt` field (varied: dataclass, recursion, string ops, dict handling) |
| Jac idioms | ~8 handwritten: "write a walker that…", node/edge/ability/impl-block prompts |
| Explain Jac | ~6 handwritten: short Jac snippets + "what does this do?" |
| General coding | ~5 plain Python/algorithm prompts (shows models still general-purpose) |

Clicking a prompt fills the input box (editable), never auto-sends.

## UI

**Identity:** "Jac Studio". Strictly monochrome — no color anywhere, including syntax
highlighting (grayscale shades only) and states (loading/error rendered in grays +
typography, not red/green).

**Style — Soft Mono × Schematic:** charcoal base (`#0a0a0a`), layered gray panels
(`#0d0d0d`/`#121212`/`#1a1a1a`), hairline `#222`–`#333` borders, subtle rounding, clean
sans for prose. Schematic layer on top: faint dotted-grid page background, monospace
micro-labels with letter-spacing (`PROMPT LIBRARY`, `OUTPUT.JAC`, `MEM 28.1/48GB`),
dashed hairlines as section dividers, annotation-style stats (`└─ 42 tok/s · 312 tok ·
Δ7.4s`), code blocks with floating schematic tab labels. shadcn/ui components themed to
this via CSS variables.

**Layout (three columns):**

- **Left sidebar** — chat history grouped by day, new-chat button, footer memory gauge
  (resident model size / 48GB as a monospace bar).
- **Center** — model pill (popover picker, 4 models, shows loaded state), compare
  toggle, message thread, input box with category quick-chips above it. Assistant code
  blocks get the `OUTPUT.JAC` schematic tab + copy button. Streaming text renders live;
  stats line appears under each completed response.
- **Right rail** — prompt library (collapsible categories, click-to-fill), sampling
  sliders (temperature / top-p / max tokens), last-run stats block. Collapsible.

**Key states:** model loading (progress + elapsed), generation streaming (live tok/s in
stats line), compare swap ("swapping to X…"), server down (full-screen schematic-style
"backend offline" panel with the start command).

## Error handling

- Server unreachable → UI banner with `web_app/start.sh` hint, auto-retry ping.
- Model load failure (bad path, OOM) → SSE error event, toast + chat-level message;
  resident model state reported honestly by `/api/models`.
- Generation exception → error event on stream, partial text kept and marked.
- SQLite errors are fatal-logged but never crash generation (history write is
  best-effort after stream completes).

## Testing

- **Server:** pytest — chat-template prompt construction, SQLite CRUD, SSE event
  framing, model registry. Inference covered by a fake-model unit seam (mlx load/generate
  stubbed); one optional integration test marked `slow` that loads a real model.
- **UI:** component tests not the priority for a local demo tool; rely on typed API
  client + manual smoke. `start.sh` checked by a script that curls `/api/models` and
  `localhost:3000` after boot.

## Out of scope (YAGNI)

- Stitch MCP (not connected; shadcn direct).
- Auth, multi-user, network exposure, deployment.
- Base Q4/Q8 models in the picker (only the 4 fused trained variants).
- Parallel dual-model residency, GPU memory tuning beyond unload+clear-cache.
- Markdown rendering beyond code blocks + paragraphs.
