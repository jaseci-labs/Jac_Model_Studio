# JMS / Experiments UI Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the JMS product surface (`components/jms/**` + `jms.css`) and the Experiments product surface (`components/sections/**` + `global.css`) look and feel like one coherent design system, instead of two apps that happen to share a color palette.

**Architecture:** Introduce one neutral token layer that both surfaces' root scopes populate identically; rebuild `components/shared/**` so every component reads *only* that neutral layer (never `--jms-*` or shadcn names directly); migrate both surfaces' ~90+ hand-rolled panel/button/chip/tab/status sites onto the rebuilt shared components; then clean up the token-layer and typography divergences that don't need a shared component (fonts, background texture, spacing scale, chart palette).

**Tech Stack:** Jac client components (`.cl.jac`, compiles to React), Tailwind CSS v4 (`@theme inline` token bridging), two hand-written CSS files (`global.css`, `jms.css`), no build-time CSS preprocessor beyond Tailwind/PostCSS already wired into `jac.toml`.

**Research base:** four parallel Opus-model audits (full JMS design-system inventory, full Experiments design-system inventory, direct pattern-by-pattern comparison, and a shared-component reuse audit) were run against the current codebase on 2026-07-22 before writing this plan. Every claim below cites real `file:line` locations found in those audits — this is not a guess, it's a synthesis of a from-scratch line-by-line reading of `jms.css` (567 lines), `global.css` (323 lines), all 11 `components/jms/**` files, all 14 `components/sections/**` files, and all 15 `components/shared/**` files.

## Global Constraints

- **Never break the existing look of either surface mid-migration.** Every task must leave the app in a visually-working state a human can screenshot and compare before/after. Use the `run` skill / Playwright pattern already established this session (launch `jac start --dev` on an isolated scratch data root + explicit non-default ports, screenshot, compare) — never test against a real running user instance (see "Global Constraints" postscript below on why this matters).
- **Real bug, not cosmetic, has already caused a live incident this session**: running a second `jac start --dev` instance against the real project's `JAC_STUDIO_DATA_ROOT` while another instance was already running corrupted the local-user session (a Root-ownership permission conflict) and required an `lldb`-based file-descriptor recovery to fix. **Every implementer in this plan MUST use `JAC_STUDIO_DATA_ROOT`/`JAC_STUDIO_WORKSPACE` pointed at a scratch directory (e.g. under the session's scratchpad), and explicit non-default `--port`/`--api_port` flags, never the real project root, when smoke-testing.** Check `ps aux | grep "jac start"` before launching anything to confirm no conflicting instance is already running on the ports you intend to use.
- **CSS custom properties are the unification mechanism, not a rewrite.** Both `jms.css` and `global.css` already express nearly the same *values* for core colors (bg/fg/accent/border/radius/glow are hex-identical or a couple of hex digits apart — confirmed by direct audit). The fix is architectural (one source of truth both scopes populate) not a redesign of what things look like today. Do not restyle components beyond what's needed to route them through shared tokens/components — this is a consolidation plan, not a redesign.
- **`components/shared/**` components must become scope-independent.** After this plan, every shared component must render identically regardless of whether its parent DOM tree has `.jms-scope[data-jms-theme="..."]` or the Experiments root wrapper above it. Verification: mount each shared component under `.jms-scope[data-jms-theme="warm-industrial"]` (an amber theme, currently unused but fully defined in jms.css) and under the plain Experiments root, screenshot both, confirm the *token values* differ (proving it re-themes) but the *layout/structure* is identical.
- **Do not touch**: `model-experiments/**` (unrelated ML pipeline work), `jms/` (old pre-restructure app, already deleted — don't resurrect), anything under `.jac/` (build artifacts), `models/`/`adapters/` (never-delete rule from project memory).
- **Commit after every task**, Co-Authored-By footer per session convention. Never `git add -A` — this session has an unrelated concurrent worktree touching other files; stage only the files each task actually changed.
- **`/ponytail:ponytail` governs every edit**: no speculative new abstractions beyond what's specified below, shortest working diff per task, delete dead code you find along the way rather than leaving it commented out.

---

## Research findings this plan is built on (read before starting any task)

### Finding 1 — Two token systems, hand-copied not shared (highest structural priority)
`jms.css` defines `--jms-*` tokens on `.jms-scope` (`jms.css:16-47`). `global.css` defines shadcn-style tokens (`--accent`, `--card`, `--border`, `--foreground`, …) on `:root`/`.dark` (`global.css:65-102`), plus a second `--exp-*` token block (`global.css:152-157`) whose comments literally say `== --jms-radius` / `== --jms-hover-shadow` — i.e. a human manually copied the JMS values into Experiments' own token names once. Core colors match exactly (bg `#050507`, fg `#f2f2f5`, accent `#3355ff`, border `#1a1a22`, radius `12px`, hover-glow `0 0 60px -18px rgba(51,85,255,.55)` — all identical on both sides). But: raised-surface shade drifts (`--jms-bg-raised:#0b0b10` vs `--card:#0a0a0d`), dim-fg drifts (`#85859a` vs `#8a8a95`), accent-fg drifts (`#ffffff` vs `#f2f2f5`), **there is no `--jms-ok`/success-equivalent token in Experiments at all**, and **danger philosophy is inverted**: Experiments deliberately declares `--destructive: #d4d4d4` (gray — `global.css:80` comment: "errors are gray + typography, not red") while JMS declares `--jms-danger: #ff4d5e` (real red). Chart colors are fully divergent — the actual `--chart-1..5` tokens are never used anywhere; every chart hardcodes its own hex palette in JS (`Train.cl.jac:28-29`, `Results.cl.jac:39-44`, `CptTrain.cl.jac:19`).

### Finding 2 — `components/shared/**` is not actually shared (root cause of the theme-leak bugs)
Every file in `components/shared/` is styled exclusively in the Experiments vocabulary (`.exp-*` classes, `micro-label`/`stat-line`/`pulse`, shadcn `var(--accent)` etc.) — **zero** shared components read `--jms-*` or live under `.jms-scope`-aware styling, and **zero** have their own `.style.css` annex. JMS only borrows 3 of the 15 shared components — `LogView`, `MonoChart`, `StatTile` (confirmed cross-surface import sites: `TrainStage.cl.jac:21-22`, `EvalStage.cl.jac:25`) — and all 3 **silently ignore the active JMS theme**, because they read global `:root` tokens that only happen to equal JMS's `electric-minimal` defaults by coincidence. Switch JMS to any of its other 4 already-defined themes (`warm-industrial`, `bright-lab`, `phosphor`, `print-shop`) and these three components stay locked to electric-blue-on-near-black regardless. **`Button.cl.jac` and `Panel.cl.jac` — the two components explicitly built to collapse the repeated hand-rolled button/panel markup — have zero imports anywhere in the codebase.** Meanwhile: the floating-label bordered-panel idiom is hand-copied **51 times** across 11 Experiments files (`grep "micro-label absolute -top-2"`) and independently reimplemented as `.jms-section`/`.jms-section-label` in JMS (`jms.css:521-539`); buttons are hand-rolled at ~55 JMS call sites (`.jms-btn`) and ~10+ Experiments call sites via a recurring `btn = "exp-btn "` string-concatenation anti-pattern (`Cloud.cl.jac:435,495,584,629`, `Train.cl.jac:449`, `CptTrain.cl.jac:100`) that bypasses the `.exp-btn-accent` class entirely — **`.exp-btn-accent` is used exactly once in the whole Experiments codebase**, meaning most "primary" buttons (including Cloud's own "▶ START REMOTE SFT") are not visually distinguished from secondary buttons at all.

### Finding 3 — Typography is two different identities (highest visual-impact priority per the comparison audit)
JMS: display font Space Grotesk Variable, body font Instrument Sans Variable, mono Geist Mono (`jms.css:27-29`). Experiments: sans font Geist, mono Geist Mono — **no Space Grotesk, no Instrument Sans anywhere** (`global.css:100-101`). The uppercase-mono micro-label aesthetic (labels/kickers/stats) genuinely is shared in spirit (both all-caps Geist Mono, similar size/tracking) — but every heading and every paragraph of body prose renders in a completely different typeface family between the two surfaces. The comparison audit ranks this the #1 highest-impact fix: "no amount of matching hex values overcomes two different typefaces sitting side by side."

### Finding 4 — Status indicators: three incompatible mechanisms (2nd highest-impact)
JMS: accent-blue geometric dots, two redundant systems even within JMS itself — `.jms-dot`/`.jms-dot-on` (8px, `jms.css:409-420`, one call site: `JmsProjects.cl.jac:92`) and `.jms-pill-dot`/`.jms-pill-dot-done` (7px, `jms.css:510-518`, used everywhere else). Experiments' shared `StatusGlyph.cl.jac` renders typographic glyph characters (○⦿✓✗◌) colored via Tailwind text-color utilities, honoring a deliberate monochrome-only contract. But `Cloud.cl.jac` — the single highest-traffic Experiments file for this pattern — bypasses `StatusGlyph` and hand-rolls a **third**, literal-color dot system (`bg-emerald-500`/`bg-red-500`/`bg-foreground`, `Cloud.cl.jac:559-563`) that directly contradicts the monochrome-danger token philosophy Experiments itself declared, and additionally invents a `"detached"` status state `StatusGlyph` doesn't know about (worked around inline, `Cloud.cl.jac:608`).

### Finding 5 — Background texture, tab mechanism, and spacing rhythm all differ (3rd highest-impact, bundled because they compound into "the two surfaces breathe differently")
Experiments' `<body>` has a radial dot-grid texture (`global.css:118`, `radial-gradient(#101014 1px …) 18px`); `.jms-scope` is flat. Tab/nav is built three separate ways: JMS's `.jms-pill`/`.jms-pill-active` (solid-fill active state, `jms.css:487-509`), Experiments' `SubTabs.cl.jac` (underline-only active state, no fill), and Experiments' `NavRail.cl.jac` (translucent-tint active state + a colored accent bar, `NavRail.cl.jac:83-90`) — three different visual languages for "this tab/item is selected." Spacing rhythm: JMS runs a 24px/20px scale (`p-6`, `gap-6`, `gap-5`, padding on the *scroll container*); Experiments runs a tighter 16px scale (`p-4`, `gap-4`, padding inside *each pane* instead of the container).

### Finding 6 — Lower-priority but real, cheap-to-fix issues found within each surface independently
- JMS has no `:disabled` CSS state on `.jms-btn` at all — disabled buttons look identical to enabled ones (`jms.css:194-219`).
- JMS copy-pastes the same inline error-styling span (`className="jms-mono-dim" style={{"color":"var(--jms-danger)"}}`) at ~15 call sites instead of having a `.jms-error` class (the success twin `.jms-flash` already exists, `jms.css:470-476`).
- JMS has one real token-system violation: `EvalStage.cl.jac:418` uses raw `border-neutral-800` instead of `var(--jms-border)`, so that one row won't re-theme with the other 4 JMS themes.
- JMS's `.jms-chip` class is overloaded across 4 unrelated semantics including, oddly, a chat-message bubble (`EvalStage.cl.jac:487`).
- Experiments' `.section-header` class is referenced at 4 call sites and in `SectionHeader.cl.jac:5` but **is not defined in either CSS file** — a dead no-op class; the other 6 section headers render identically without it.
- Experiments has radius drift even within itself: `.exp-panel` = 12px, nav/workspace tiles = 10px (`rounded-lg`), `RowBrowser` rows = 4px (`rounded`) — three radii for adjacent surface elements.
- Experiments' input fields (`.exp-input`, raised bg `#0f0f14` + focus glow ring) render visibly differently from JMS's input fields (`.jms-input`, flat page-bg `#050507`, no focus ring) despite matching type metrics — and JMS doesn't use the shared `Field.cl.jac` component at all, hand-rolling raw `<input className="jms-input">`.
- Empty states are ad hoc on both sides; the purpose-built shared `EmptyState.cl.jac` is imported by only 1-2 files total across the whole app.

---

## Phase 0 — Foundation: the neutral token layer

### Task 1: Add a neutral, scope-independent token layer to both CSS files

**Files:**
- Modify: `studio-desktop/global.css` (add a new block, do not touch existing `:root`/`.dark` shadcn tokens — those stay, other things still read them)
- Modify: `studio-desktop/jms.css` (add the equivalent block to `.jms-scope` and each `[data-jms-theme="…"]` override)

**Interfaces:**
- Produces: a new token namespace `--ui-*` (e.g. `--ui-bg`, `--ui-bg-raised`, `--ui-fg`, `--ui-fg-dim`, `--ui-accent`, `--ui-accent-2`, `--ui-accent-fg`, `--ui-border`, `--ui-ok`, `--ui-danger`, `--ui-radius`, `--ui-radius-sm`, `--ui-glow`, `--ui-font-display`, `--ui-font-body`, `--ui-font-mono`, plus a spacing scale `--ui-space-1` through `--ui-space-6`) that Task 2 onward will make every rebuilt shared component read **exclusively**. Both `:root` (Experiments' real root, un-scoped) and `.jms-scope` (every theme variant) must define the full set — this is the one place values can differ per-theme, everything downstream just reads `--ui-*`.
- Consumes: nothing new — this task only *adds* a mapping layer. Existing `--jms-*` and shadcn (`--accent` etc.) tokens are left in place untouched so nothing currently reading them breaks mid-migration.

- [ ] **Step 1: Decide the canonical values.** Since Finding 1 shows raised-surface/dim-fg/accent-fg have small drifts, and Experiments has no `ok` token while JMS's danger-red contradicts Experiments' declared gray-danger philosophy — these are real design decisions, not typos. Recommended resolution (confirm with a human before implementing if you have any doubt, this is the one place taste enters the plan): keep JMS's slightly warmer raised-surface (`#0b0b10`) and dim-fg (`#85859a`) as canonical (they're the more considered choice, chosen for a variable-font pairing), keep Experiments' pure `--ok`-less gray-danger philosophy as canonical for **shared components** (statuses/errors default to monochrome — `--ui-danger: #d4d4d4`), but ALSO define `--ui-danger-strong: #ff4d5e` for the rare cases (destructive confirmation buttons, billing alerts) that genuinely need real red — Cloud.cl.jac's billing-alert red (Finding 6) is a legitimate use of "strong" danger, not a bug, just needs to go through a named token instead of a hardcoded hex.
- [ ] **Step 2: Add the `--ui-*` block to `global.css`'s `:root`** (`global.css:65` area), each `--ui-*` token defined as `var(--the-existing-shadcn-token)` where a direct equivalent exists (e.g. `--ui-bg: var(--background);`), and as a literal value for the ones with no shadcn equivalent (`--ui-ok`, `--ui-danger-strong`, the spacing scale, `--ui-font-display`/`--ui-font-body` — Experiments needs to load Space Grotesk/Instrument Sans here too, see Task 3).
- [ ] **Step 3: Add the equivalent `--ui-*` block to `jms.css`'s `.jms-scope` base rule** (`jms.css:16` area) as `var(--jms-*)` aliases, and to **all 5** `[data-jms-theme="…"]` override blocks (`jms.css:50,56,77,97,132`) so every theme populates the full `--ui-*` set, not just electric-minimal. This is what makes shared components finally re-theme correctly per Task 4's verification method.
- [ ] **Step 4: Verification.** Write a throwaway `.cl.jac` test page (or reuse an existing one temporarily) with a single `<div>` reading `background: var(--ui-bg); color: var(--ui-fg); border: 1px solid var(--ui-border);` mounted once under `.jms-scope[data-jms-theme="warm-industrial"]` and once under Experiments' plain root. Screenshot both (isolated test instance per Global Constraints), confirm the colors genuinely differ (proving per-theme population works) and delete the test page.
- [ ] **Step 5: Commit.**

### Task 2: Load JMS's fonts globally and settle the one-typeface-system decision

**Files:**
- Modify: wherever fonts are currently loaded for JMS (search for `Space Grotesk`/`Instrument Sans` font-face declarations or `@fontsource` imports — likely in `jac.toml`'s npm deps per the `@fontsource`/`@fontsource-variable` packages seen in `.jac/client/node_modules` during the audit, or a `<link>`/`@import` in `main.jac`/`frontend.cl.jac`)
- Modify: `global.css` (point `--font-sans`/`--ui-font-display`/`--ui-font-body` at the JMS faces)

**Interfaces:**
- Consumes: Task 1's `--ui-font-display`/`--ui-font-body`/`--ui-font-mono` tokens.
- Produces: both surfaces render headings in the same display face and body copy in the same body face.

- [ ] **Step 1: Confirm this is the desired direction, not the reverse.** Finding 3 is presented as "two typefaces, pick one" — this plan recommends adopting **JMS's** faces (Space Grotesk display / Instrument Sans body) as canonical, since JMS is the newer, actively-designed surface per its own docstrings, and Experiments never deliberately chose Geist-for-everything — it's just what shadcn ships with by default. If a human reviewing this plan prefers the reverse (drop Space Grotesk/Instrument Sans, make JMS use Geist to match Experiments), swap step 2/3 accordingly — the mechanism is identical either way, only the direction changes.
- [ ] **Step 2: Ensure Space Grotesk Variable + Instrument Sans Variable are loaded app-wide** (not just when JMS mounts) — find how JMS currently loads them and make that load unconditional at the app root instead of JMS-only.
- [ ] **Step 3: Point Experiments' `.exp-display` class and general body text at `--ui-font-display`/`--ui-font-body`** instead of hardcoded `--font-sans`/Geist (`global.css:281` area for `.exp-display`; the general body font is likely set once near `global.css:100-101` and inherited).
- [ ] **Step 4: Visual verification** — screenshot one Experiments heading (e.g. Cloud's "SPHERON" topbar label or a section title) and one body paragraph before/after on an isolated test instance; confirm the font actually changed and nothing reflows badly (Space Grotesk/Instrument Sans have different metrics than Geist — check for text overflow in tight labels, especially anything using `white-space: nowrap` or fixed-width containers).
- [ ] **Step 5: Commit.**

---

## Phase 1 — Rebuild the shared component library to be scope-independent

### Task 3: Rebuild `Panel.cl.jac` as the single bordered-labeled-panel primitive and wire in its `.style.css`

**Files:**
- Modify: `studio-desktop/components/shared/Panel.cl.jac` (currently dead code, 0 imports — rewrite its styling to be token-driven; keep its existing prop API if reasonable, expand only if the 51+40 real call sites this plan will migrate onto it need something it doesn't have yet)
- Create: `studio-desktop/components/shared/Panel.style.css` (scoped annex, per `jac-cl-styling` convention) — OR add the rules directly to a new shared section of whichever CSS file is more idiomatic here (check whether any other `shared/` component already has a `.style.css` annex as precedent; audit found none exist yet, so this may be the first — if the project's Jac tooling doesn't auto-scope a annex for a `shared/` component the way it does for `sections/`/`jms/` components, put the rules in `global.css` under a new `--ui-*`-only block instead, clearly commented as "consumed by shared/Panel, token-driven, safe under any scope")

**Interfaces:**
- Consumes: Task 1's `--ui-bg-raised`, `--ui-border`, `--ui-radius`, `--ui-fg-dim`.
- Produces: `Panel(label: str, children, className: str = "")` (or whatever the current dead-code signature is — read it first) rendering the exact floating-label-on-border idiom both surfaces already use, but through one component. This becomes the target every Task-4-onward migration site converts to.

- [ ] **Step 1: Read the current `Panel.cl.jac`** in full — it already has the right shape per the shared-component audit ("the dead shared/Panel is the right shape but the wrong, Experiments-only styling"), so this is a restyle, not a rewrite from scratch.
- [ ] **Step 2: Replace every class/CSS-variable reference inside it with `--ui-*` equivalents.**
- [ ] **Step 3: Self-check** — mount `<Panel label="TEST">hello</Panel>` under both `.jms-scope[data-jms-theme="electric-minimal"]` and the Experiments root on an isolated test instance, screenshot both, confirm they look like today's `.jms-section`/`.exp-panel` (no visual regression) and are structurally identical to each other.
- [ ] **Step 4: Commit** (component only — do not migrate call sites yet, that's Tasks 6-7).

### Task 4: Rebuild `Button.cl.jac` as the single button primitive

**Files:**
- Modify: `studio-desktop/components/shared/Button.cl.jac` (dead code, 0 imports — restyle to `--ui-*` tokens)

**Interfaces:**
- Consumes: Task 1's `--ui-accent`, `--ui-accent-fg`, `--ui-border`, `--ui-fg-dim`, `--ui-radius`.
- Produces: `Button(variant: "outline"|"accent"|"ghost"|"danger" = "outline", disabled: bool = False, onClick, children)`. **Must include a real `:disabled` visual state** (Finding 6: JMS currently has none at all) — e.g. reduced opacity + `cursor: not-allowed`, matching Experiments' existing `.exp-btn:disabled{opacity:0.4}` which is the one implementation that already has this right.

- [ ] **Step 1: Read the current dead `Button.cl.jac`** — per the audit it already maps outline/solid/ghost variants to CSS classes; keep that variant API, just retarget the classes to `--ui-*`.
- [ ] **Step 2: Add the missing `disabled` visual state.**
- [ ] **Step 3: Self-check** across both scopes + all 4 variants + disabled state, screenshot grid, confirm no regression vs current `.jms-btn`/`.exp-btn` appearance.
- [ ] **Step 4: Commit.**

### Task 5: Rebuild `Chip.cl.jac` as the single chip/pill primitive, and promote `StatusGlyph.cl.jac` to canonical status renderer

**Files:**
- Modify: `studio-desktop/components/shared/Chip.cl.jac` (currently internal-only via Gallery — restyle to `--ui-*`)
- Modify: `studio-desktop/components/shared/StatusGlyph.cl.jac` (add the missing `"detached"` state so `Cloud.cl.jac` no longer needs its inline `"failed" if status=="detached" else status` workaround; keep the monochrome-only contract — do NOT add colored variants, that's the whole point of Finding 4)

**Interfaces:**
- Produces: `Chip(active: bool = False, children)` token-driven pill. `StatusGlyph` gains a `detached` entry in its glyph/color map (`StatusGlyph.cl.jac:3-9`ish), styled the same monochrome way as `failed` (dashed underline) since detached is functionally "went wrong, needs attention" like failed.
- Consumes: Task 1 tokens.

- [ ] **Step 1: Restyle Chip** to `--ui-*`, matching current `.exp-chip`/`.jms-pill` visual (both are close enough per Finding 2's comparison that one shape works for both — same mono-uppercase-pill idiom).
- [ ] **Step 2: Add `detached` to StatusGlyph's state map**, monochrome-styled.
- [ ] **Step 3: Self-check** both components across both scopes.
- [ ] **Step 4: Commit.**

### Task 6: De-hardcode `MonoChart.cl.jac`, `MultiLineChart.cl.jac`, and `StatTile.cl.jac` — the three components already used cross-surface

**Files:**
- Modify: `studio-desktop/components/shared/MonoChart.cl.jac` (replace hardcoded `#666`/`#333`/`#1c1c1f` axis/grid colors and the caller-passed literal `accent` prop default with `--ui-*` reads; keep `accent` as an override-able prop for legitimate per-chart color needs, but default it to `var(--ui-accent)` not a hardcoded hex)
- Modify: `studio-desktop/components/shared/MultiLineChart.cl.jac` (same treatment for its hardcoded `HUES` palette)
- Modify: `studio-desktop/components/shared/StatTile.cl.jac` (already close to scope-independent per the audit — just swap its remaining `border-input`/`text-foreground` direct-shadcn reads for `--ui-*`)

**Interfaces:**
- Consumes: Task 1 tokens, plus the (still-hardcoded, out of this plan's scope to redesign) per-file caller chart-color choices in `Train.cl.jac:28-29`/`Results.cl.jac:39-44`/`CptTrain.cl.jac:19` — those callers can keep passing custom hex if a chart genuinely needs a distinct multi-series palette (that's a legitimate use case, not a bug), the bug is only that the *components' own defaults/chrome* (axis lines, grid, tooltip bg) were hardcoded instead of theme-aware.
- Produces: these 3 components finally re-theme correctly when mounted inside a non-`electric-minimal` JMS theme — this is the concrete fix for the theme-leak bug the shared-component audit flagged as the clearest evidence of Finding 2.

- [ ] **Step 1: MonoChart** — swap hardcoded grid/axis/tooltip-bg colors for `--ui-border`/`--ui-fg-dim`/`--ui-bg-raised`. Real call sites to verify against: `TrainStage.cl.jac:395` (JMS, currently passes `accent="#4ade80"` hardcoded green — leave the caller's explicit override alone, just fix the component's own chrome), `Train.cl.jac:24`/`CptTrain.cl.jac:16`/`CptResults.cl.jac:9` (Experiments).
- [ ] **Step 2: MultiLineChart** — same treatment, Experiments-only today (`Train.cl.jac`) but should still be theme-aware for when/if JMS adopts it.
- [ ] **Step 3: StatTile** — swap remaining direct shadcn reads. Real call sites: `EvalStage.cl.jac:411` (JMS), `Evals.cl.jac:17`/`CptTrain.cl.jac:14`/`CptResults.cl.jac:7`/`CptSftPlan.cl.jac:12`/`Data.cl.jac:17`/`CptData.cl.jac:10`/`CptSftData.cl.jac:11`/`Train.cl.jac:23` (Experiments, 8 sites).
- [ ] **Step 4: The actual regression test for this task** — mount `EvalStage` (which uses `StatTile`) under JMS's `warm-industrial` theme (temporarily flip `JmsShell.cl.jac`'s hardcoded `t = "electric-minimal"` to `"warm-industrial"` on the isolated test instance only, revert after screenshotting) and confirm the StatTile now visibly picks up amber tones instead of staying electric-blue. This is the concrete, falsifiable proof that Finding 2's theme-leak is fixed.
- [ ] **Step 5: Commit.**

### Task 7: De-hardcode `LogView.cl.jac`

**Files:**
- Modify: `studio-desktop/components/shared/LogView.cl.jac` (swap its `.exp-panel`/`text-foreground`/`text-muted-foreground` reads for `--ui-*` equivalents — via using the rebuilt `Panel` from Task 3 as its wrapper, or direct token reads if wrapping in Panel changes its layout unacceptably)

**Interfaces:** Consumes Task 1 tokens + optionally Task 3's `Panel`. Produces the third and final cross-surface component fix for Finding 2.

- [ ] **Step 1: Read current LogView, decide wrap-in-Panel vs direct-token-swap** based on whether Panel's padding/label conventions fit LogView's log-tail use case (it may need a plainer frame without the floating label — check real call sites `TrainStage.cl.jac:396`, `Evals.cl.jac:16`, `CptTrain.cl.jac:15`, `Data.cl.jac:19`, `Cloud.cl.jac:29`, `Train.cl.jac:22` for how it's actually used before deciding).
- [ ] **Step 2: Implement, self-check both scopes.**
- [ ] **Step 3: Commit.**

### Task 8: Adopt `EmptyState.cl.jac` as the one empty-state component; add the missing error-text and loading conventions as shared primitives

**Files:**
- Modify: `studio-desktop/components/shared/EmptyState.cl.jac` — retarget to `--ui-*` (currently Experiments-only styled, only used by `CptResults.cl.jac`).
- Create (or add to Task 4's Button work if it makes sense as one file): a small new shared primitive for the error-text idiom — e.g. `ErrorText.cl.jac`, a one-line component wrapping `<span style={{color: 'var(--ui-danger)'}}>{children}</span>` at `--ui-fg-dim`-adjacent sizing, replacing the ~15 copy-pasted inline-style spans in JMS (Finding 6) and the equivalent scattered `stat-line text-muted-foreground`/`text-foreground` error spans in Experiments.

**Interfaces:**
- Consumes: Task 1 tokens.
- Produces: `EmptyState(message: str, pulse: bool = False, hint: str = "")` (verify exact current prop shape first — this component already exists and has a working API, just wrong tokens); `ErrorText(children)` as a brand-new minimal primitive.

- [ ] **Step 1: Restyle EmptyState to `--ui-*`.**
- [ ] **Step 2: Build `ErrorText`** — deliberately tiny (~10 lines), this is exactly the kind of "shortest working diff" ponytail calls for; do not build a generic `<Alert>`/toast system, this plan only needs the inline error-span replacement.
- [ ] **Step 3: Self-check both, both scopes.**
- [ ] **Step 4: Commit.**

---

## Phase 2 — Migrate both surfaces onto the rebuilt shared components

> **Ordering note:** Phase 2 is the bulk of the diff (dozens of call sites across both `components/jms/**` and `components/sections/**`). Split it into one task per *file*, not per pattern, so each task stays reviewable and independently revertable. The list below groups files by surface; do JMS first (fewer files, smaller surface area, lower risk) to validate the migration mechanics before touching the much larger Experiments call-site count.

### Task 9: Migrate JMS panels — replace `.jms-section`/`.jms-section-label` with `Panel` across all 5 stage files

**Files:** Modify `components/jms/stages/{SourcesStage,GenerateStage,CurateStage,TrainStage,EvalStage}.cl.jac` (real call sites, all confirmed by audit: `SourcesStage.cl.jac:113,137,176`; `GenerateStage.cl.jac:383,420,443,567,642,668`; `TrainStage.cl.jac:232,353,385`; `CurateStage.cl.jac:329,385,418`; `EvalStage.cl.jac:327,378,407,457`).

**Interfaces:** Consumes Task 3's `Panel`. Produces: zero remaining `.jms-section`/`.jms-section-label` usages in `components/jms/**` (verify with a final `grep`).

- [ ] **Step 1-5 (one per file):** For each of the 5 stage files, replace every `<div className="jms-section ...">+ <span className="jms-section-label">` pair with `<Panel label="...">`, preserving whatever Tailwind layout classes (`flex flex-col gap-3` etc.) were on the original div by passing them through `Panel`'s `className` prop.
- [ ] **Step 6: Screenshot every stage** (Sources/Generate/Curate/Train/Eval) before/after on an isolated instance, confirm no visual regression (this directly re-verifies the label-clipping fix from earlier this session still holds — Panel must preserve adequate top clearance).
- [ ] **Step 7: `grep -rn "jms-section" components/jms/` returns nothing** except possibly the now-unused CSS rule itself (leave the CSS rule in `jms.css` for one more task cycle in case of rollback, remove it in the final cleanup task).
- [ ] **Step 8: Commit** (can be one commit for all 5 files, or one per file if you want finer revert granularity — implementer's judgment call, note it in the PR/commit message either way).

### Task 10: Migrate JMS buttons — replace `.jms-btn`/`.jms-btn-accent`/`.jms-btn-danger` with `Button` across all JMS files

**Files:** Modify all files under `components/jms/**` that reference `jms-btn` (the audit found ~55 call sites across `Landing.cl.jac`, `JmsShell.cl.jac`, `JmsProjects.cl.jac`, `ApiKeyModal.cl.jac`, and all 5 stage files — run `grep -rn "jms-btn" components/jms/` at task start for the authoritative current list, since exact counts may have shifted since the audit).

**Interfaces:** Consumes Task 4's `Button`. Produces zero remaining `.jms-btn*` usages in `components/jms/**`.

- [ ] **Step 1: Enumerate every call site** via `grep -rn "jms-btn" components/jms/`.
- [ ] **Step 2: Migrate file by file**, mapping the existing `"jms-btn" + (" jms-btn-accent" if X else "")` string-concat toggle pattern (seen at e.g. `SourcesStage.cl.jac:188`, `GenerateStage.cl.jac:390,681,685`, `CurateStage.cl.jac:262`, `TrainStage.cl.jac:236`, `EvalStage.cl.jac:348,520`) onto `Button`'s `variant` prop (`variant={"accent" if X else "outline"}`).
- [ ] **Step 3: Preserve the busy-label-swap convention** (buttons showing "SAVING…"/"SCANNING…" etc. while `disabled={busy}`) — this is good UX, keep it, just route through the new `Button` component's `disabled` prop (which now has real visual disabled styling per Task 4, an actual improvement over today's no-op disabled state).
- [ ] **Step 4: Screenshot every JMS surface**, confirm no regression, confirm disabled buttons now visibly look disabled (a real, checkable improvement).
- [ ] **Step 5: `grep` confirms zero remaining `.jms-btn` usages.**
- [ ] **Step 6: Commit.**

### Task 11: Migrate JMS status dots — collapse `.jms-dot`/`.jms-dot-on` AND `.jms-pill-dot`/`.jms-pill-dot-done` onto `StatusGlyph`

**Files:** Modify `components/jms/JmsProjects.cl.jac:92` (the lone `.jms-dot`/`.jms-dot-on` site) and every `.jms-pill-dot`/`.jms-pill-dot-done` site (`JmsProject.cl.jac:122`, `TrainStage.cl.jac:361`, and the other pill-as-list-row sites the JMS audit found: version lists, GPU offers, SSH keys, training runs, evals — re-`grep` at task start for the current authoritative list).

**Interfaces:** Consumes Task 5's `StatusGlyph`. Produces: `.jms-dot`/`.jms-dot-on`/`.jms-pill-dot`/`.jms-pill-dot-done` CSS rules become unused (remove in final cleanup task), one status-rendering mechanism used everywhere in JMS.

- [ ] **Step 1: Map JMS's current status vocabulary onto StatusGlyph's** (idle/running/done/failed/stopped/finished + the new `detached` from Task 5) — JMS's "done" state already matches directly.
- [ ] **Step 2: Migrate each call site.**
- [ ] **Step 3: Screenshot, confirm dots still communicate status clearly** (StatusGlyph's typographic-glyph approach is a genuine style change from JMS's solid-circle dots — flag any place this reads worse and note it for a human design call, don't force it through if a specific spot looks clearly worse; this is the one migration in Phase 2 where taste judgment matters most).
- [ ] **Step 4: Commit.**

### Task 12: Migrate Experiments' hand-rolled `exp-panel`/`micro-label` sites onto `Panel` (highest-volume task in this plan — 40 sites)

**Files:** Modify every file under `components/sections/**` with a `exp-panel ... micro-label absolute -top-2` pair (audit found 51 total occurrences across 11 files including `RowBrowser.cl.jac`, `Generate.cl.jac`, `Cloud.cl.jac`, `Train.cl.jac`, and others — `grep -rn "micro-label absolute -top-2" components/` at task start for the authoritative, current list; split this into sub-tasks of ~3-4 files each if a single implementer pass would be too large to review well, following the "task right-sizing" principle — a reviewer should be able to hold one sub-task's diff in their head).

**Interfaces:** Consumes Task 3's `Panel`. Produces near-zero remaining hand-rolled `exp-panel` + floating-label pairs in `components/sections/**` (some `exp-panel` usages without a label may legitimately stay as bare `.exp-panel` divs if they're not the labeled-frame idiom — don't force those into `Panel` if they don't have a label).

- [ ] **Step 1: Enumerate** via `grep -rn "micro-label absolute -top-2" components/sections/` (and separately audit bare `exp-panel`-without-label usages to decide if those need a labelless `Panel` variant or should stay as-is).
- [ ] **Step 2 onward: migrate file-by-file** (recommend grouping: Cloud.cl.jac alone given its size/traffic; then Train.cl.jac + CptTrain.cl.jac; then the CPT-family files (CptData/CptResults/CptSftData/CptSftPlan) together; then the remainder), screenshotting each group before/after.
- [ ] **Final step: `grep` confirms the count dropped from 51 to near-zero** (report the exact before/after count honestly — some genuinely-different frame variants may remain, that's fine, document why if so).
- [ ] **Commit per group.**

### Task 13: Migrate Experiments' buttons — kill the `btn = "exp-btn "` anti-pattern, fix the primary-CTA-not-using-accent bug

**Files:** Modify `Cloud.cl.jac:435,495,584,629`, `Train.cl.jac:449`, `CptTrain.cl.jac:100` (the confirmed anti-pattern sites), plus every other bare `exp-btn`/`exp-btn-accent`/`exp-btn-ghost`/`exp-btn-danger` reference across `components/sections/**` (re-`grep` at task start).

**Interfaces:** Consumes Task 4's `Button`. Produces: Cloud's "▶ START REMOTE SFT" (and every other genuine primary action across Experiments) actually renders as a filled accent button, matching what a "primary CTA" should look like — this is a real, user-visible bug fix, not just a refactor (Finding 2: `.exp-btn-accent` is currently used exactly once in the whole surface).

- [ ] **Step 1: Enumerate every button site**, classify each as primary/secondary/ghost/danger by what it actually does (not by copying its current class, which the audit shows is often wrong).
- [ ] **Step 2: Migrate to `Button` with the correct variant** — this is the task where "START REMOTE SFT"/"START TRAINING"-equivalent buttons across Cloud/Train/CptTrain finally get their accent treatment.
- [ ] **Step 3: Screenshot every affected section**, specifically calling out the before/after on primary buttons since this is a visible behavior change (buttons that were flat outlines will now be filled blue) — flag this explicitly in the task's report so a human can confirm they want that (it's the correct fix per the design intent already encoded in the CSS, but it IS a visible change worth a sanity check).
- [ ] **Step 4: Commit.**

### Task 14: Migrate Experiments' status dots (Cloud.cl.jac's bespoke emerald/red system) onto `StatusGlyph`

**Files:** Modify `Cloud.cl.jac:559-563` (the hand-rolled `bg-emerald-500`/`bg-red-500`/`bg-foreground` dot) and `:608` (the inline `"detached"` workaround, now unnecessary per Task 5).

**Interfaces:** Consumes Task 5's `StatusGlyph` (with its new `detached` state). Produces: Cloud's deployment/run status rendering finally honors the monochrome-danger philosophy its own `global.css:80` comment declares, and its `detached` state renders through the real vocabulary instead of a workaround.

- [ ] **Step 1: Replace the hand-rolled dot** with `<StatusGlyph status={...} />`.
- [ ] **Step 2: Remove the now-unnecessary inline `"failed" if status=="detached" else status"` remap.**
- [ ] **Step 3: Screenshot Cloud's INSTANCES/RUNS views**, confirm status is still clearly legible without the emerald/red coloring (this is a real design tradeoff — monochrome status may read as less scannable at a glance; if it genuinely looks worse, that's worth flagging to a human as a possible reason to reconsider the monochrome-only contract, rather than silently forcing a worse UI through).
- [ ] **Step 4: Commit.**

### Task 15: Migrate Experiments' empty states and error spans onto `EmptyState`/`ErrorText`

**Files:** Every "no X yet" span across `components/sections/**` (Cloud, Train, Evals, RowBrowser, CptResults, etc. — re-`grep` for `stat-line`/`micro-label` text patterns matching empty-state phrasing) and every error-red/gray text span.

**Interfaces:** Consumes Task 8's `EmptyState`/`ErrorText`. Produces one consistent empty-state and error-text rendering across all of Experiments (and, since Task 8 already retargeted `EmptyState` to `--ui-*`, this also means JMS could adopt the same component going forward instead of its own bespoke empty-state markup — not required by this plan, but leave the door open, don't build anything that would block it).

- [ ] **Step 1: Enumerate.**
- [ ] **Step 2: Migrate file-by-file, screenshot each.**
- [ ] **Step 3: Commit.**

---

## Phase 3 — Tab/nav unification, spacing scale, background texture, cleanup

### Task 16: Decide and implement one tab/nav visual language

**Files:** Modify `components/shared/SubTabs.cl.jac` and/or `components/sections/NavRail.cl.jac` and `jms.css`'s `.jms-pill`/`.jms-pill-active` rules, depending on which direction is chosen.

**This task requires a human decision before implementation** — Finding 5 identifies three incompatible mechanisms (JMS solid-fill pills, Experiments underline sub-tabs, Experiments tinted-tile-with-bar nav) with no obviously-correct winner; unlike the button/panel/status consolidations (which had one component clearly better-built than its alternatives), all three tab mechanisms are reasonable design choices for slightly different contexts (a vertical stage rail vs a horizontal sub-tab strip vs a top-level section switcher). Recommend to the human: keep the tinted-tile+accent-bar treatment for top-level surface navigation (NavRail-style, since it's the most information-dense — shows selection AND workspace-color identity), keep the solid-fill pill for vertical stage rails (JMS-style, reads well in a narrow column), and use the underline treatment ONLY for true in-page sub-tabs where a lighter-weight indicator is appropriate (Experiments' `SubTabs.cl.jac` INSTANCES/RUNS/SETUP case) — i.e. these may not need to collapse to ONE mechanism, they may need to become three *intentional, documented* variants of one shared component instead of three *accidental* ones. Bring this framing to the human before implementing.

- [ ] **Step 1: Present the three-variant framing above to the user for a decision** (this is exactly the kind of design-taste call that shouldn't be made unilaterally by an implementer, per this project's own established pattern of surfacing judgment calls).
- [ ] **Step 2 onward: implement whatever is decided**, following the same migrate-per-file-then-screenshot discipline as Phase 2.

### Task 17: Unify the spacing scale

**Files:** Modify `jms.css`, `global.css` (add a shared `--ui-space-1` through `--ui-space-6` scale per Task 1, if not already added there), then migrate the highest-drift spacing sites — JMS's container-level `p-6`/`gap-6` vs Experiments' `p-4`/`gap-4` — to a single agreed rhythm.

**This also needs a human decision**: Finding 5 shows JMS is roomier (24px scale) and Experiments is denser (16px scale) — picking one changes the felt density of one entire surface. Recommend: since Experiments has many more, denser data-table-style views (RowBrowser, chat, evals lists) where density is genuinely useful, and JMS is currently mostly simple forms/panels where extra room doesn't cost much, consider keeping Experiments' tighter rhythm as canonical and simply tightening JMS's container padding/gaps by one step (24px→20px, 20px→16px) rather than loosening Experiments — but present both directions to the human, this is a felt-density call.

- [ ] **Step 1: Present the direction choice to the user.**
- [ ] **Step 2 onward: implement, screenshot-compare density before/after on real content-heavy views (not just empty forms) to judge the felt effect honestly.**

### Task 18: Decide and implement one background-texture treatment

**Files:** `global.css:118` (the radial dot-grid `<body>` background) vs `jms.css`'s flat `.jms-scope` background.

**Human decision needed**: pick flat-everywhere or dot-grid-everywhere. Recommend flat (JMS's choice) as canonical, since the dot-grid is a fairly loud whole-screen texture that competes with data-dense Experiments views (charts, logs, tables) — but this is genuinely a one-line aesthetic call for a human, not an implementer.

- [ ] **Step 1: Present the choice.**
- [ ] **Step 2: Implement whichever direction, verify no content-legibility regression (especially over charts/code blocks) if dot-grid is kept anywhere.**

### Task 19: Final cleanup — remove now-dead CSS, fix the remaining Finding-6 one-offs

**Files:** `jms.css`, `global.css`, `EvalStage.cl.jac:418` (the `border-neutral-800` token violation), `EvalStage.cl.jac:487` (the `.jms-chip`-as-chat-bubble misuse — give the chat bubble its own small class instead), `SectionHeader.cl.jac`/wherever `.section-header` is referenced (either actually define the class with real styling, or remove the dead references — don't leave a no-op class referenced in some files and not others).

**Interfaces:** Produces a genuinely clean final state — every CSS rule in both files is either actively used or deliberately documented as "kept for a future theme" (matching the existing precedent for the 4 unused JMS theme variants, which the codebase already treats as intentionally-kept-cheap-to-revive per `JmsShell.cl.jac`'s own docstring).

- [ ] **Step 1: `grep` for zero remaining usages of every class this plan removed** (`.jms-section`, `.jms-section-label`, `.jms-dot`, `.jms-dot-on`, the old `.jms-pill-dot`/`.jms-pill-dot-done` if fully migrated, the old bare `exp-panel`+`micro-label` pattern where fully migrated) and delete those CSS rules.
- [ ] **Step 2: Fix `EvalStage.cl.jac:418`'s `border-neutral-800`** → `var(--ui-border)`.
- [ ] **Step 3: Give the EvalStage chat bubble its own class** instead of misusing `.jms-chip`.
- [ ] **Step 4: Resolve `.section-header`** — check what real styling (if any) was originally intended, either implement it for real (border-bottom + spacing, matching what the 6 non-tagged headers already look like without it) and add it to the 6 missing sites for consistency, or strip the dead references. Either is fine; leaving it half-wired is not.
- [ ] **Step 5: Full-app final screenshot pass** — every JMS stage, every Experiments section, on an isolated test instance, compared against the very first screenshots taken at the start of this plan's execution, confirming the net visual effect is "more consistent," not "broken."
- [ ] **Step 6: Commit.**

---

## Verification (end-to-end)

1. `grep -rn "jms-section\|jms-btn\|jms-dot\b\|jms-pill-dot" components/jms/` and the Experiments-side equivalents return only whatever was deliberately kept (document any remainder with a one-line reason).
2. Every shared component in `components/shared/**` compiles and renders under both `.jms-scope[data-jms-theme="electric-minimal"]` and `.jms-scope[data-jms-theme="warm-industrial"]` (or any other non-default theme) with genuinely different colors — this is the falsifiable proof Finding 2's theme-leak bug is fixed, not just "probably fine."
3. Zero hardcoded hex colors remain in `MonoChart.cl.jac`/`MultiLineChart.cl.jac`'s own chrome (axis/grid/tooltip) — caller-passed data-series colors are fine and expected to stay hardcoded per-caller.
4. A full-app screenshot diff (every stage, every section) shows no accidental regressions — text still fits, nothing overflows, nothing clips (a direct callback to the two label-clipping bugs already found and fixed earlier this session — this plan must not reintroduce that class of bug).
5. Both `jac check` (compile) and the app's own test files (`*.test.jac` — several exist per this project's conventions, e.g. `cloudruns.test.jac`, `auth.test.jac`) still pass after the full migration.

## Parked (explicitly NOT this plan)

- A full visual redesign of either surface — this plan only consolidates existing, already-similar patterns onto one implementation. If the human wants JMS or Experiments to look meaningfully *different* from how they look today (new layouts, new color palette, new information architecture), that's a separate brainstorming/design pass, not this consolidation plan.
- Runtime theme-switching UI for Experiments (JMS already has an unused `JmsThemeSwitcher.cl.jac` wired to 5 themes but not mounted anywhere live — wiring it up, and/or building an Experiments-side equivalent, is a nice follow-on but is out of scope here; this plan's job is making the *infrastructure* theme-correct, not necessarily exposing theme-switching to end users yet).
- Migrating `Gallery.cl.jac`/`RowBrowser.cl.jac`/`CodeBlock.cl.jac`/`Field.cl.jac`/`SectionHeader.cl.jac` to be cross-surface-adopted by JMS — the shared-component audit judged these as "genuinely Experiments-domain" (dataset browsing, forms) rather than needing JMS uptake; only retarget their tokens to `--ui-*` opportunistically if touched for other reasons, don't force a migration task for them.
