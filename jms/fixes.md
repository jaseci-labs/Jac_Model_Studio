# JMS — Live Verification Sweep (full rewrite)

**Verified:** 2026-08-04 · Playwright 1.62.1 / Chromium headless, driving the **running** dev server (`jac start --client web --dev main.jac`, pid 3406, started 11:26), UI `:8000` / API `:8001`, `JAC_LOCAL_USER=1`.
**Method:** ~20 scripted browser sessions against the live app. Cold contexts with empty `localStorage`, full console + `pageerror` + HTTP-status capture on every session, computed-style probes, `elementFromPoint` hit-testing, `document.getAnimations()` sampling on `requestAnimationFrame`, CDP screencast pixel capture, and real `page.mouse` clicks (not `element.click()`) wherever actionability was the thing under test.
**Scope driven:** landing + 4 experiment workspaces × 6 tabs × 2 themes (48 screens), JMS landing + a project's 5 pipeline stages × 2 themes, all 6 overlays opened/closed/escaped/scrim-dismissed, 4 destructive-confirm sites armed and disarmed 3 ways each, 8 cold starts, and a 234-action endurance run per theme.

> Every claim below was re-tested from scratch this session. Nothing is carried over from the previous version of this file.

---

## 1. Summary

**The app is in good shape.** Across every screen driven this session I recorded **zero console errors, zero uncaught page errors, and zero HTTP 4xx/5xx** — the only non-2xx responses in the entire sweep were two I caused deliberately (a malformed probe request and an intentionally thrown `Error`). Cold start is a consistent **~340 ms to interactive** over 8 consecutive fresh contexts, with no 401 race and no failed requests.

**11 of the 13 tracked fixes are fully verified live. 2 are partial** — item 10 (disabled-button reasons) landed on 4 of its 6 buttons, and item 2 (FD exhaustion) is verified as far as it can be without loading a real model.

The headline result: **the black-flash fix holds up under hard testing.** 224 tab/workspace switches across both themes produced a minimum content-pane opacity of exactly `1.0` and **zero** keyframe animations on any wide element. The `.reveal` class is gone from the compiled `AppShell.js` that the browser actually receives, and the *intentional* entrance animation on genuine surface navigation still fires. The previously least-tested fix — the `⚙ WORKSPACES` drawer toggle — also **passes a real mouse click-through** on both surfaces, which is the check it had never been given.

Two prior issues are confirmed **resolved and can be closed**: the `key`-prop warning in `JmsWorkspaceSettings` (gone) and `components/LayoutSwitcher.cl.jac` (file no longer exists). Remaining findings are small: two accessibility gaps on disabled buttons, two destructive confirms that were never wired to the shared disarm hook, and one modal whose trigger still sits under its own scrim.

---

## 2. Verified working

### ✅ 1 — Tailwind utilities (`[plugins.client.vite]`) — **FULLY VERIFIED**
- Injected probe elements, read computed styles: `flex`→`display:flex`, `hidden`→`display:none`, `grid`→`display:grid`, `fixed`→`position:fixed`, `rounded-lg`→`border-radius:16px`, `z-50`→`z-index:50`. All resolve.
- `document.body.scrollHeight` = **1000** = viewport height (not a 30,000 px unstyled column).
- Across all **48** experiment screens (4 workspaces × 6 tabs × 2 themes): exactly **1** visible section slot every time (`distinct slot counts: [1]`), and `documentElement.scrollWidth <= innerWidth` on every one — zero horizontal overflow.
- Tab isolation is real, measured by *visible* button count varying per tab (ws01, dark): CHAT 39 · DATA 41 · TRAIN 23 · EVALS 34 · CLOUD 17 · PLAN 14.
- `jac.toml` carries `[plugins.client.vite]`; no bare `[client.vite]` table exists.

### ⚠️ 2 — FD exhaustion / model-load stability — **VERIFIED as far as reachable**
- **The raise is real and now observable through the API.** `POST /function/loaded_model` → `200` with `{"fd_boot_limit":65536,"fd_soft":65536,"fd_hard":-1,"fd_target":65536,...}`. The soft limit on the live process is genuinely 65536, and the boot-time value matches the target.
- The running server holds **17,503 open fds** (`lsof`) — impossible under the machine's default soft limit of 256, independently confirming `glob _FD_BOOT_LIMIT: int = _raise_fd_limit();` (`inference.sv.jac:128`) succeeded at import.
- Dict is built in `inference.sv.jac:246-251` and merged by `loaded_info()` (`:263-275`) on **both** the loaded and unloaded paths; `models.sv.jac:129-131` delegates. Endpoint is a plain `def` (i.e. `def:priv`) — it needs a JWT, so it is not exposed unauthenticated.
- `ulimit -S -n 65536` is present in `start.sh:38-41` (with a `ulimit -Hn` fallback) and `start_prod.sh:29-33`.
- ⚠️ **Caveat:** the live server was started with bare `jac start`, **not** through `start.sh`, so the launcher `ulimit` line is still unexercised in practice — the import-time raise is doing all the work. That is the more robust half, but the launcher path remains unproven.
- ℹ️ No real model load was performed, so the fd-exhaustion **recovery** path and lock-release behaviour are still unverified end-to-end.

### ✅ 3 — Assistant provider validation — **FULLY VERIFIED (both layers)**
- **Client refuses cleanly.** Opening the assistant and clicking `Claude (Anthropic)` with no key replaces the composer with `Connect Claude (Anthropic) / Enter your API key to continue. / SAVE & CONTINUE`. Measured before → after: `hasTextarea: true → false`, `hasSend: true → false`. The send path is **removed from the DOM**, so falling through to local MLX is structurally impossible.
- **Server refuses too.** `POST /function/assistant_stream` with the correct schema (`messages`, `provider`, `model_id`) → `200` SSE frame:
  - claude → `{"kind": "error", "text": "Set an Anthropic key (⚙ KEYS, top bar) to chat with Claude."}`
  - openai → `{"kind": "error", "text": "Set an OpenAI key (⚙ KEYS, top bar) to chat with OpenAI."}`
- Neither response contains `Errno`, `Traceback`, `OSError`, or any mention of MLX. Dispatch branches are mutually exclusive with an early `return` (`assistant.sv.jac:764-785`).

### ✅ 4 — `_LadderTip` → `LadderTip` — **FULLY VERIFIED**
- Workspace 02 → RESULTS renders **45** `.recharts-surface` elements.
- Hovering the ladder chart at three x-positions produced real tooltip content: `eval fixed · base greedy holdout accuracy % : 38.9`, `+ SFT · greedy holdout accuracy % : 61.1`, `+ best-of-k holdout accuracy % : 77.8`.
- `document.querySelectorAll('laddertip,_laddertip').length === 0` — React treats it as a component, not a literal DOM tag.
- Zero `incorrect casing` / `unrecognized tag` warnings anywhere in the sweep.

### ✅ 5 — Dead buttons, drawer toggle, dismiss, theme picker — **FULLY VERIFIED (this was the weakest fix; it now passes)**
- **`⚙ WORKSPACES` second-click toggle WORKS, via a real mouse click.** Tested with `page.mouse` through Playwright's actionability checker (which is what failed before), on **both** surfaces:

  | Surface | click 1 | `elementFromPoint` at gear centre while open | click 2 |
  |---|---|---|---|
  | `#experiments` | drawer opens (`aria-label="Workspaces and sections"`) | `BUTTON.exp-btn exp-btn-ghost shrink-0` — **the gear itself** | **drawer closes** |
  | `#jms` | drawer opens (`aria-label="JMS workspaces"`) | `BUTTON.exp-btn exp-btn-ghost shrink-0` — **the gear itself** | **drawer closes** |

  The `fixed inset-x-0 bottom-0 top-[var(--topbar-h)] z-50` reposition (`WorkspaceSettings.cl.jac:430`, `JmsWorkspaceSettings.cl.jac:164`) genuinely lifts the trigger out from under the panel. Gear rect is `x 1443→1568, y 14→47`; the drawer now starts below `--topbar-h` (62 px, `global.css:215`).
- **`+ new chat` works.** Typed `DRAFT THAT SHOULD BE CLEARED` into the composer → clicked `+ new chat` → composer value is `""`.
- **Escape dismisses** all 6 overlays (Experiments WorkspaceSettings, AssistantPanel, CommandPalette, ShortcutSheet, ApiKeyModal, JmsWorkspaceSettings) — verified individually, each returning 0 visible `[role="dialog"]` afterwards.
- **Scrim/outside click dismisses** both `⚙ WORKSPACES` drawers and the `⚙ KEYS` modal.
- **Only light/dark exists** — no 7-theme picker, as stated. Toggle flips `class="dark"` on `<html>`, `body` background `rgb(255,255,255)` ↔ `rgb(0,0,0)`, label `◑ LIGHT` ↔ `◐ DARK`.
- **Command palette (⌘K) works end to end:** opens (`aria-label="Command palette"`, 29 lines), filters on typing `cloud` → `SECTION CLOUD … 1 result`, `Enter` navigates to the CLOUD section.
- ⚠️ One residual: the `⚙ KEYS` gear is still covered by its own modal scrim — see §3.1.

### ✅ 6 — `/cl/__error__`, cold-start 401 race, favicon — **FULLY VERIFIED**
- **`/cl/__error__` reaches the API:** `POST` → **200 `{"ok":true}`**.
- **End-to-end, not just plumbing:** threw a real uncaught `Error` in the page; the framework's `__jacReportError()` handler fired and its `POST /cl/__error__` returned **200**.
- **Favicon exists and is served correctly** (this is a change from the previous report, which recorded a 404):
  - `/favicon.ico` → **200**, `content-type: image/x-icon`, **4969 bytes**
  - `/favicon.svg` → **200**, `content-type: image/svg+xml`, **1593 bytes**
- **No cold-start 401.** 8 consecutive cold contexts: time-to-interactive `[347, 336, 339, 336, 343, 343, 342, 346] ms`, 10 API calls each, **zero** 4xx/5xx, zero failed requests, zero page errors. `list_evals` returns `200 {"evals":[]}`.

### ✅ 7 — Destructive-action guards — **FULLY VERIFIED (4/4 confirm sites, live)**
All four sites arm to `SURE?`, render `data-confirm-armed`, and **disarm all three ways**. Nothing was actually deleted — the project, workspace and sections all survived the sweep.

| Site | arms | 4 s timeout | Escape | outside click |
|---|---|---|---|---|
| JMS project `DELETE` (`JmsProjects.cl.jac:536`) | ✅ `SURE?` | ✅ disarms | ✅ | ✅ |
| WorkspaceSettings workspace `DELETE` (`:532`) | ✅ `SURE?` | ✅ | ✅ | ✅ |
| WorkspaceSettings section `✕` (`:584`) | ✅ `aria-label="Confirm delete section chat"` | ✅ | ✅ | ✅ |
| JmsWorkspaceSettings `DELETE` (`:242`) | ✅ `SURE?` | ✅ | ✅ | ✅ |

- After the section-✕ cycle, all six sections were still present: `['CHAT','DATA','TRAIN','EVALS','CLOUD','PLAN']`.
- **`BUILD TRAINING SPLIT` refuses at 0 curated rows** — `disabled=true`, title *"Nothing to split — generate some rows in the GENERATE tab first."*, with a resolving `aria-describedby="jms-curate-split-hint"`.
- **EVALS deselect + LAUNCH disable — VERIFIED, and the guard is now genuinely reachable.** Scoped to the *visible* EVALS section (all 4 workspaces mount one, which is what made this look unreachable before):

  | step | LAUNCH `disabled` | LAUNCH `title` |
  |---|---|---|
  | initial | `false` | `"run this eval"` |
  | click active model chip (`Qwen · DPO`, title *"click again to deselect"*) → deselects | **`true`** | `"No model selected — pick one above, or type a model path."` |
  | click active holdout segment (`graph`) → deselects | `true` | (same) |
  | re-select `graph` | `true` (model still empty — correct) | (same) |

  Both pickers are genuinely click-to-deselect, and the disabled branch fires.
- EVALS history `DEL` was **not reachable** — `EVAL.HISTORY` is empty (`list_evals` → `{"evals":[]}`), so there is no row to arm. Its implementation shares the verified hook (`Evals.cl.jac:144`, `:420`).

### ✅ 8 — JWT secret (`[plugins.scale.jwt]`) — **VERIFIED via working sessions**
- `jac.toml:122` is `[plugins.scale.jwt]` (no bare `[scale.jwt]`), value `"${JWT_SECRET:-…}"`.
- Live evidence that signing works: `localStorage` holds a **221-char `jac_token`**, and every authenticated endpoint called with it returned 200 (`loaded_model`, `list_evals`, `assistant_stream`). 8 cold starts all minted a session with zero 401s.
- `start.sh:57-67` generates a random secret with `openssl rand -hex 32` when unset and caches it at `.jac/jwt_secret` (mode 600), so it is stable across restarts. `start_prod.sh:14-15` hard-requires an external value.

### ✅ 9 — Dead `components/LayoutSwitcher.cl.jac` deleted — **VERIFIED**
File does not exist; a repo-wide search returns no importers and no matches outside stale prose. **This item is done and should be dropped from the task list.**

### ⚠️ 10 — Disabled-button reasons (`title` + `aria-describedby`) — **PARTIAL (4 of 6)**
Read live off the DOM in both themes, resolving each `aria-describedby` against the actual element id:

| Button | `title` | `aria-describedby` | id resolves | verdict |
|---|---|---|---|---|
| DRAFT PLAN | ✅ *"Set an Anthropic key (⚙ KEYS, top bar) to draft with Claude."* | ✅ `jms-gen-draft-hint` | ✅ | **pass** |
| START TRAINING | ✅ *"Materialize a training split first (CURATE stage)."* | ✅ `jms-train-split-hint` | ✅ | **pass** |
| SCORE ON HOLDOUT | ✅ *"No completed local-mlx run with an adapter yet — train one in the TRAIN stage."* | ✅ `jms-eval-run-hint` | ✅ | **pass** |
| BUILD TRAINING SPLIT | ✅ *"Nothing to split — generate some rows…"* | ✅ `jms-curate-split-hint` | ✅ | **pass** |
| **ACCEPT ALL ON PAGE** | ✅ *"No pending rows on this page — nothing left to accept here."* | ❌ **absent** | — | **fail** — see §4.2 |
| **REGENERATE REJECTED (0)** | ✅ *"No rejected rows — reject a row first to regenerate it."* | ❌ absent in this state | — | **partial** — see §4.2 |

No dangling `aria-describedby` was found anywhere — every id that is emitted resolves.

### ✅ 11 — Focus trap on 5 drawers/modals — **FULLY VERIFIED**
Tabbed and Shift-Tabbed `max(focusables+3, 12)` times in each direction, checking after every press whether `document.activeElement` was still inside the dialog:

| Overlay | `aria-modal` | `tabindex` | focusables | escapes | Escape closes |
|---|---|---|---|---|---|
| WorkspaceSettings | true | `-1` | 46 | **0 / 98 presses** | ✅ |
| AssistantPanel | true | `-1` | 7 | **0 / 24** | ✅ |
| CommandPalette | true | `null` ⚠️ | 1 | **0 / 24** | ✅ |
| ShortcutSheet | true | `-1` | 1 | **0 / 24** | ✅ |
| ApiKeyModal | true | `-1` | 5 | **0 / 24** | ✅ |

- **The documented gap reproduces exactly as described:** `JmsWorkspaceSettings` (10 focusables) leaked focus on `Tab#10` → `BUTTON.assistant-launcher`, then `INPUT.jms-input`, `SELECT.jms-input`, and on the very first `Shift-Tab`. Known and expected — **not** a new issue.
- ⚠️ CommandPalette is missing `tabIndex={-1}` on its container — minor contract deviation, see §4.3.

### ✅ 12 — Theme persistence (`localStorage["jacml.mode"]`) — **FULLY VERIFIED**
| step | `<html>` class | `localStorage` | `body` background | label |
|---|---|---|---|---|
| fresh, no key | `""` | `null` | `rgb(255,255,255)` | `◑ LIGHT` |
| click toggle ×1 | `dark` | `dark` | `rgb(0,0,0)` | `◐ DARK` |
| click toggle ×2 | `""` | `light` | `rgb(255,255,255)` | `◑ LIGHT` |
| click toggle ×3 | `dark` | `dark` | `rgb(0,0,0)` | `◐ DARK` |
| **hard reload** | `dark` | `dark` | `rgb(0,0,0)` | persisted ✅ |
| navigate home / `#jms` / `#experiments` | `dark` throughout | `dark` | — | persisted ✅ |

Forcing `light` then `dark` in storage and hard-reloading each time applied correctly both ways. No code change was needed and none has regressed.

### ✅ 13 — Black-flash on tab / workspace switch — **FULLY VERIFIED, THE FIX HOLDS**
This got the hardest testing of the sweep, on four independent lines of evidence.

1. **The fix is live in the bundle the browser receives.** `.jac/client/compiled/components/AppShell.js` (mtime 11:43, newer than the source's 11:42:54) contains **zero** occurrences of `reveal`. The served module at `/components/AppShell.js` returns 200 and likewise contains none. The visible-slot className is now bare `flex min-w-0 flex-1` (`AppShell.cl.jac:264`).
2. **rAF animation sampling, nav-only, both themes.** A `requestAnimationFrame` loop recorded every `document.getAnimations()` entry in `playState === 'running'` and the minimum computed opacity of any element wider than 600 px inside `[data-ws]`:

   | run | clicks | min opacity | keyframe animations on wide elements |
   |---|---|---|---|
   | dark · tabs ×4 passes | 24 | **1** | **NONE** |
   | dark · workspaces ×4 passes | 16 | **1** | **NONE** |
   | dark · tab+workspace interleaved, no settle | 84 | **1** | **NONE** |
   | dark · nav-only endurance | 112 | **1** | **NONE** |
   | light · nav-only endurance | 112 | **1** | **NONE** |

   **224 navigation clicks with no settle time, and opacity never left 1.0.** No `fadeInUp` fired once.
3. **Pixel ground truth.** CDP screencast captured 322 real frames during dark-mode tab and workspace switching. The 29 frames that tripped a naive "%lit pixels" threshold were inspected as images and are **fully-rendered sparse dark-theme screens** (topbar, nav rail and panels all painted) — not blank panes. There is no black frame in the capture.
4. **The intentional entrance animation was NOT collaterally removed.** Navigating `HOME → EXPERIMENTS` and `HOME → JMS` both still play `["fadeInUp", "fadeIn"]`. Overlay entrances are also intact — opening a drawer still runs `fadeIn @ DIV.flex-1 g-scrim reveal-fade` (the deliberate scrim fade, and the only source of any opacity dip anywhere in the sweep).

---

## 3. Still broken / regressed

Nothing from the 13 tracked items regressed. Two small residuals:

### 🟡 3.1 — `⚙ KEYS` gear is still under its own modal scrim · **LOW**
**File:** `components/jms/ApiKeyModal.cl.jac:165`
The modal is `fixed inset-0 z-50` — unlike the two `⚙ WORKSPACES` drawers, it did **not** get the `top-[var(--topbar-h)]` treatment. While open, `elementFromPoint` at the gear's centre (`x 1357→1435, y 14→47`) returns `DIV.absolute inset-0 g-scrim reveal-fade`, and a real mouse click is refused by Playwright's actionability check (element intercepts pointer events), leaving the modal open.
**Repro:** `#jms` → `⚙ KEYS` → click `⚙ KEYS` again → modal stays open.
**Impact:** genuinely low — Escape and scrim-click both close it, and for a *centered* modal a scrim covering the whole viewport is a defensible design. Worth a decision, not necessarily a fix: either mirror the drawer offset, or accept it and stop treating "click the trigger again" as a supported dismiss for this modal.

### 🟡 3.2 — `BUILD TRAINING SPLIT` is briefly disabled with no stated reason · **LOW**
**File:** `components/jms/stages/CurateStage.cl.jac:617-620`
`disabled={bool(matBusy or loading or nCur == 0)}` includes `loading`, but `matHint` is only computed once loading finishes (`:589-598`). During the initial fetch the button is disabled while `title` falls back to the generic *"carve the accepted + edited rows into train.jsonl / holdout.jsonl"* and `aria-describedby` is dropped. Observed live: one stage visit caught exactly this state, the next showed the proper hint. Cosmetic and transient — a `"Loading…"` hint would close it.

---

## 4. New issues found

### 🟠 4.1 — Two destructive confirms are NOT wired to `useConfirmReset` · **MEDIUM**
The shared auto-disarm hook covers the four sites listed in §2.7, but two more two-click confirms exist and were missed. Both are the exact sticky-armed shape the hook was written to eliminate.

- **`components/sections/Cloud.cl.jac`** — `confirmTerm` / *"⚠ CONFIRM TERMINATE VM?"*: state `:108`, arm `:413`, button `:622-623`. No `useConfirmReset` import, no `data-confirm-armed`. **This is an irreversible cloud VM terminate** — the highest-consequence action in the app and the only one still able to sit armed indefinitely.
- **`components/jms/stages/CurateStage.cl.jac`** — `confirmMat` / *"CLICK AGAIN TO OVERWRITE"*: state `:81`, arm `:280-281`, label `:601`. No hook, no `data-confirm-armed`. Partially mitigated: `:613` disarms on a holdout-% change, and it overwrites `train.jsonl`/`holdout.jsonl` rather than deleting.

**Neither was reachable live** (no VMs provisioned; the split button is disabled at 0 curated rows), so this is a code-level finding — but the Cloud one carries real risk.

### 🟠 4.2 — `ACCEPT ALL ON PAGE` has no screen-reader disable reason · **LOW-MEDIUM**
**File:** `components/jms/stages/CurateStage.cl.jac:462-467`
It has a `title` but **no `aria-describedby`**, and no hint span is rendered for `acceptHint` (`:449`) — so the reason is hover-only and invisible to assistive tech. Confirmed live in both themes. Its sibling `REGENERATE REJECTED` does have `aria-describedby="jms-curate-regen-hint"`, but the span only renders while `running` (`:457-459, :475`), so in the state a user actually meets it (0 rejected rows) it is likewise title-only. The in-file comment at `:445-448` justifies this on the grounds that "a visible span already states it", which is not true for `ACCEPT ALL ON PAGE`.

### 🟡 4.3 — `CommandPalette` container lacks `tabIndex={-1}` · **LOW**
**File:** `components/shared/CommandPalette.cl.jac:156-164`
`hooks/useFocusTrap.cl.jac:26-28` documents that the dialog container must be `tabIndex={-1}`; the other four trapped overlays comply, this one does not. **The trap still holds in practice** (0 escapes in 24 presses) because the open-effect focuses `#jms-cmdk-input` (`:104-105`), so the `not inside` branch does the work. Only the `len(items) == 0` fallback degrades — `panel.focus()` on a non-focusable container is a silent no-op. One-attribute fix.

### 🟡 4.4 — `JUDGE` button is disabled with no reason at all · **LOW**
**File:** `components/jms/stages/EvalStage.cl.jac`
Observed live on the EVAL · CHAT stage in both themes: `disabled=true`, `title=null`, `aria-describedby=null`. Every other disabled control in the JMS pipeline states why it is disabled; this one is silently dead. Give it the same `title` (+ hint span) treatment as its neighbour `SCORE ON HOLDOUT`.

### 🟡 4.5 — `start_web_tmp.sh` is a near-duplicate of `start.sh` · **LOW / housekeeping**
8173 vs 8181 bytes, same blocks at the same line numbers, modified more recently than `start.sh`. Two launchers that must be kept in sync is how the `ulimit` / `JWT_SECRET` logic silently drifts. Delete it or clearly mark it disposable.

### ℹ️ 4.6 — Previously-reported issues that are now RESOLVED (close these)
- **`key`-prop warning in `JmsWorkspaceSettings` — GONE.** Opened the JMS `⚙ WORKSPACES` drawer many times across several sessions (including the focus-trap run that tabbed through all 10 of its focusables): **0 console warnings, 0 errors** every time.
- **`components/LayoutSwitcher.cl.jac` — GONE.** The file no longer exists.
- **`/favicon.ico` 404 — FIXED.** Now 200, `image/x-icon`, 4969 bytes.
- **Sticky destructive confirms — FIXED.** All four hooked sites disarm on timeout, Escape and outside click (§2.7).
- **Stale `[scale.*]` / `[client.*]` comment in `jac.toml` — FIXED.** The file now carries a long, accurate note explaining that `[plugins.*]` is load-bearing and that bare tables are silently dropped, with line-level references into jaclang. This is now the best documentation in the repo, not a trap.

### ℹ️ 4.7 — Checked and clean
- **Console/network:** zero console errors, zero `pageerror`, zero 4xx/5xx across 48 experiment screens, 10 JMS stage views, the landing page, and every overlay. The only non-2xx in the whole sweep were self-inflicted (a deliberately malformed `assistant_stream` body → 422, and an intentionally thrown `Error`).
- **Endurance:** 234 actions per theme (rapid workspace/tab churn with no settle time, plus overlay open/close cycles and `[ ] 1 2 3 4` keyboard nav) — ended in a consistent state, 1 visible slot, no overflow, clean console.
- **One transient blank page** was seen mid-sweep and chased down: it was caused by a crashed harness process leaking a competing browser, **not** by the app. Re-measured over 8 clean cold starts, time-to-interactive is a tight 336–347 ms. Not an app defect.
- No z-index/stacking problems; exactly one overlay layer at a time.
- Keyboard shortcuts (`⌘K`, `?`, `[`, `]`, `1`–`4`, `t`) all behave.

---

## 5. Task list

**Must fix**
- [ ] **Wire `useConfirmReset` into `Cloud.cl.jac`'s `confirmTerm`** (§4.1) — add the import, call the hook unconditionally, and render `data-confirm-armed` on the armed button (`:622-623`). This is an irreversible VM terminate and the last destructive action that can sit armed forever.

**Should fix**
- [ ] **Wire `useConfirmReset` into `CurateStage.cl.jac`'s `confirmMat`** (§4.1) — same three edits around `:81`, `:280-281`, `:601`.
- [ ] **Give `ACCEPT ALL ON PAGE` an `aria-describedby` + hint span** (§4.2), and make `REGENERATE REJECTED`'s hint render in the disabled-at-zero-rejected state, not only while running.
- [ ] **Give the `JUDGE` button a disable reason** (§4.4) — `title` + hint span, matching `SCORE ON HOLDOUT`.
- [ ] **Add `tabIndex={-1}` to the CommandPalette dialog container** (§4.3) — one attribute, restores the documented hook contract.

**Housekeeping**
- [ ] **Delete or clearly mark `start_web_tmp.sh`** (§4.5) — two drifting launchers is a latent `ulimit`/`JWT_SECRET` bug.
- [ ] **Boot the dev server through `start.sh`** rather than bare `jac start`, so the launcher `ulimit -S -n 65536` path is actually exercised (§2.2). Only the import-time raise is load-bearing today.
- [ ] **Decide on the `⚙ KEYS` scrim** (§3.1) — mirror the drawer's `top-[var(--topbar-h)]` offset, or accept it as a centered modal and stop expecting trigger-toggle dismiss.
- [ ] **Add a `"Loading…"` hint for `BUILD TRAINING SPLIT` while `loading`** (§3.2).
- [ ] ~~Delete `LayoutSwitcher.cl.jac`~~ — **done, file is gone.**
- [ ] ~~Add a favicon~~ — **done, 200 / 4969 bytes.**
- [ ] ~~Fix the stale `[client.*]` comment in `jac.toml`~~ — **done, now accurate and thorough.**
- [ ] ~~Fix the `key`-prop warning in `JmsWorkspaceSettings`~~ — **done, no warning reproduces.**

**Genuinely untested — schedule deliberately**
- [ ] **Exercise a real local model load** to prove the FD-recovery and lock-release paths end to end (§2.2). A failed load must release its lock and not cascade 500s onto unrelated endpoints. Deliberately skipped as too risky for a verification session; needs its own slot.
- [ ] **Test with an Anthropic key configured.** Every Claude-dependent path (assistant chat, JMS `DRAFT PLAN`, eval `JUDGE`) is verified only in its *refusal* state. The success paths are entirely unverified.
- [ ] **Get one EVALS history row into a dev fixture** so the `DEL` → `SURE?` path and the `MODEL × HOLDOUT` matrix ("NEED ≥2 COMPLETED EVALS") become testable without launching a real eval.
- [ ] **Provision (or mock) one cloud VM** so the `⚠ CONFIRM TERMINATE VM?` flow can be verified live after §4.1 is fixed.

**Opportunities**
- [ ] **Add a focus trap to `JmsWorkspaceSettings`** — it advertises `aria-modal="true"` while letting Tab walk into the page behind it (§2.11). Reproduced precisely; the other five overlays show the fix is a 3-line change.
- [ ] **Consider a `def:pub` health/diagnostics endpoint** surfacing `fd_*` alongside uptime. `loaded_model` already carries the fd keys but requires a JWT, so external monitoring cannot read them.
