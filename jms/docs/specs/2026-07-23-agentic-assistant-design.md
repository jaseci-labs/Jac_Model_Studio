# Agentic Assistant — Design

**Date:** 2026-07-23
**Status:** approved (scope: full execution, confirm-gated; build all four actions at once)

## Problem

The in-app assistant (`AssistantPanel`) only *describes* actions ("open the SFT/DPO
workspace", "Start a new training run"). The user wants it to actually **do** the
thing — navigate the app, start runs, launch evals, change settings.

## Approach

**Text-embedded action block, parsed client-side.** The model appends a fenced
directive to its natural-language reply:

```
Taking you to training.
⟦DO⟧{"action":"navigate","surface":"experiments","workspace":"04","stage":"train"}⟦/DO⟧
```

Chosen over native tool-calling (local MLX has no tools API — the user runs local
gemma; would split behavior) and over a second classifier LLM call (latency/cost,
fragility). One protocol, all four providers, zero provider-specific code.

## Action protocol

Preamble instructs: reply with a one-line natural confirmation, then **exactly one**
`⟦DO⟧{…}⟦/DO⟧` block when the user wants an action (never more than one — matches the
"one step" persona and keeps weak local models reliable). Whitelisted actions:

| action | payload | gate |
|---|---|---|
| `navigate` | `{surface, workspace?, stage?}` | auto (reversible) |
| `start_training` | `{name, mode:"sft"\|"dpo", model_id?}` | **confirm** |
| `create_eval` | `{kind, model_id?, holdout?, limit?}` | **confirm** |
| `set_setting` | `{wid, default_model?, accent?, label?}` | **confirm** |

`surface` ∈ {hub, experiments, jms}. `workspace`/`stage` accept the label OR id as
shown in the live app state; the dispatcher resolves label→id from the layout.

## Client dispatcher (`AssistantPanel`)

1. On each completed assistant message, regex out the trailing `⟦DO⟧…⟦/DO⟧`.
2. Strip it from the displayed bubble (user never sees raw JSON).
3. Parse JSON; ignore unknown/malformed action types (leave message as plain text).
4. Render an **action chip** under the message:
   - `navigate` → auto-execute immediately; chip shows "↪ Experiments · SFT/DPO · Train".
   - `start_training`/`create_eval`/`set_setting` → chip with **Confirm** + **Cancel**;
     endpoint fires only on Confirm. Blast radius = compute + heavy-job lock.

## Nav primitives (no prop-drilling)

- **Cross-surface:** widget sets `window.location.hash = surface` + dispatches a
  `popstate` event. `frontend.cl.jac` already listens to `popstate` → switches surface.
- **Workspace/stage (experiments):** `AppShell` registers
  `window.__jmsNav = {goWorkspace, go}` on mount (its existing internal defs);
  widget calls them. Cleared on unmount.

## Execution

Confirmed actions call existing endpoints via `sv import`:
`start_training(name, mode, model_id, opts, backend)`,
`create_eval(kind, model_id, holdout, limit, ...)`,
`update_workspace(wid, label, accent, default_model, files)`.
No new server write-logic; only the preamble changes server-side.

## Markdown rendering (folded-in ask)

Assistant chat bubbles currently render plain text. Add a compact hand-rolled
`md → JSX` renderer (headings, bold, inline code, fenced code, bullet lists, links,
paragraphs) applied to assistant bubbles. No new dependency (none installed; avoids
jac-build risk). Built as JSX elements (not `dangerouslySetInnerHTML`) → no XSS.
**Ceiling (ponytail):** no tables / nested lists / images; upgrade to a real parser
(react-markdown) only if richer docs need it. A standalone `.md` file viewer in the
workspace is out of scope unless the user confirms they meant that.

## Guards

- Only whitelisted action types dispatch; unknown blocks stay as visible text.
- Expensive/destructive actions (`start_training`, `create_eval`, `set_setting`) are
  always confirm-gated — never auto-fire.
- `navigate` auto-fires (reversible, no compute).

## Testing

- SSE probe per action type: model emits a well-formed `⟦DO⟧` block.
- Client parse unit: block extracted + stripped from bubble; malformed → plain text.
- Live click-through: one `navigate` (auto) + one `start_training` (Confirm → status).
- Markdown: bubble with `# h1`, `**bold**`, `` `code` ``, ```` ``` ```` fence, `- list`
  renders formatted.
