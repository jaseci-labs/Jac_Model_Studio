# Glass Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Studio's dark terminal aesthetic (5 dormant themes + dead switcher, hard-locked dark) with ONE frosted "soft-futurism" design system — orange `#EC8242` accent, glass surfaces, light+dark, extreme font weights, orchestrated CSS motion — rendering identically on the JMS and Experiments surfaces, then consolidate folders (delete stale `jms/`, keep `jms-projects/`, rename `studio-desktop/`→`jms/`).

**Architecture:** Four CSS layers loaded in order (`theme.css` tokens → `global.css` Tailwind-glue + base + motion + unified glass components → `jms.css` JMS-only layout). Twin `.exp-*`/`.jms-*` component classes collapse to single grouped-selector rules (one definition, both names, zero call-site churn across 43 files). Component `.cl.jac` edits are surgical: Landing (unify+expand), AppShell/frontend (light-dark toggle replacing forced dark), delete `JmsThemeSwitcher`. Follows the Distinctive-Design four-vector (typography extremes, cohesive orange theme, page-load choreography, layered mesh+noise backgrounds) on a glass base.

**Tech Stack:** Jac client components (`.cl.jac` → React), Tailwind v4, hand-written CSS custom properties, Google Fonts (Geist/Geist Mono) + fontsource (Space Grotesk) + Inter, Playwright (project `.venv`) for visual verification.

**Reference docs:** Spec `docs/superpowers/specs/2026-07-22-glass-studio-design.md`. User's pasted `DESIGN.md` (Arc glass) + Distinctive-Design skill are the aesthetic authority. `.cl.jac` rules: see the `jac-cl-components` skill (has-fields reactive, `async can with entry` = mount effect, statement slots, no React/JS syntax).

## Global Constraints

- **Accent is orange `#EC8242`** (light) / `#f4914e` (dark) everywhere — never purple. Gradients are warm (peach/coral) + one cool counterpoint, never purple-blue.
- **Fonts:** display = `Geist` (heavy 700/900), body = `Inter` (light 200/300), mono = `Geist Mono`. Extreme weight contrast is mandatory (never 400/500/600 for display). Load via Google Fonts / fontsource — never assume system fonts.
- **Every surface uses `backdrop-filter: var(--blur)`** with an `@supports not` fallback to `--surface-strong` and a `@media (max-width:768px)` reduction to `blur(8px)`.
- **All motion is CSS-only** (keyframes + stagger classes); no framer-motion, no JS animation libs. Every animation respects `@media (prefers-reduced-motion: reduce)`.
- **JMS and Experiments must render identical component chrome** — driven by shared tokens + grouped selectors, never per-surface values.
- **CSS import order in `main.jac` is load-bearing:** `theme.css` → `global.css` → `jms.css`. Do not reorder.
- **New CSS files / new imports require a full `jac start` restart** — HMR does not copy new files into `.jac/client/compiled/`. Editing an existing watched file hot-reloads fine.
- **`jac check main.jac` must pass** after every code change (pass = string `main.jac PASSED`, not exit code).
- **Never delete `jms-projects/`** (807 MB real MLX adapters + live data) or anything under `models/`/`adapters/`. Checkpoint before the folder op.
- **Test-before-claiming:** no task is "done" without a real Playwright screenshot viewed + zero console/network errors. Verify in BOTH light and dark once the toggle exists (Phase 3+).
- Commit after every task. Stage specific files (never `git add -A`). Co-Authored-By + Claude-Session footer per session convention.

## Verification harness (used by every task)

The project venv has Playwright: `/Volumes/ExtremePro/JaseciLabs/jac_model_studio/.venv/bin/python3`. The dev server runs on `http://localhost:8000`. Reusable screenshot script lives at the scratchpad `spheron_test/` dir (already present from prior work). Standard per-task check:

1. `cd studio-desktop && jac check main.jac` → expect `main.jac PASSED`.
2. If a NEW file/import was added: kill + restart `jac start --dev` (see `scripts`/prior logs); else HMR suffices.
3. Run the screenshot driver (below) against the pages the task touched.
4. `Read` each PNG; confirm the intended change + zero regressions.
5. Confirm the driver printed `errs: []` (zero pageerror + zero 4xx/5xx).

**Reusable driver** (`scratchpad/spheron_test/shot.py` — create in Task 0, reuse after; parameterize pages as needed):

```python
import sys, time
from playwright.sync_api import sync_playwright
SHOT="/private/tmp/claude-502/-Volumes-ExtremePro-JaseciLabs-jac-model-studio/6ec42492-e2d4-43ab-8d61-eabb326f20fb/scratchpad/spheron_test/shots"
errs=[]
with sync_playwright() as p:
    b=p.chromium.launch(headless=True)
    pg=b.new_page(viewport={"width":1400,"height":1000})
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("response", lambda r: errs.append(f"{r.status} {r.url}") if r.status>=400 else None)
    pg.goto("http://localhost:8000/", wait_until="networkidle", timeout=30000); time.sleep(1.2)
    pg.screenshot(path=f"{SHOT}/{sys.argv[1] if len(sys.argv)>1 else 'shot'}.png")
    b.close()
print("errs:", errs)
```

Run: `/Volumes/ExtremePro/JaseciLabs/jac_model_studio/.venv/bin/python3 scratchpad/spheron_test/shot.py <name>`

---

## Phase 0 — Token foundation (light + dark palettes, fonts, motion, glass primitives)

### Task 0: Baseline snapshot + driver

**Files:**
- Create: `scratchpad/spheron_test/shot.py` (the driver above)

- [ ] **Step 1:** Confirm dev server up: `curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/` → `200`. If not, start it.
- [ ] **Step 2:** Write the driver script above.
- [ ] **Step 3:** Capture baseline: run driver for `baseline_landing`; navigate+shoot JMS Projects, Experiments Chat (extend script or reuse prior `verify_theme.py`). `Read` them — this is the "before" reference for every later diff.
- [ ] **Step 4:** `git status` clean check; no commit (scratchpad is outside repo).

### Task 1: `theme.css` — rewrite as light+dark glass token source

**Files:**
- Modify (full rewrite of token blocks): `studio-desktop/theme.css`

**Interfaces:**
- Produces: canonical tokens consumed by `global.css`/`jms.css` — `--bg --surface --surface-strong --text --text-muted --border --border-alt --accent --accent-hover --accent-soft --accent-tint --accent-ring --ok --danger --radius --blur --shadow-soft --shadow-nav --inner-hi --font-display --font-body --font-mono --weight-* --ease-out --dur-* --bg-gradient`. Also keeps alias names still referenced by existing classes: `--jms-* --exp-* --background --foreground --card --muted-foreground --font-mono --font-sans --chart-* --ws0N --ws-accent` (mapped to the new canonical values so no call site breaks).

- [ ] **Step 1: Replace the whole file** with the block below. This deletes the 5 `data-jms-theme` blocks, the `.jms-scope[data-jms-theme=…]` overrides, the phosphor `::before`, and the old terminal palette. It keeps `.jms-scope` (base rule) and every alias name that `global.css`/`jms.css` classes still reference, remapped to the new tokens.

```css
/* theme.css — the ONE canonical token source for the whole Studio.
   Light-glass :root + dark-glass .dark override. Orange accent #EC8242.
   Both product surfaces (Experiments .exp-*, JMS .jms-*) read these tokens;
   --jms-*/--exp-*/shadcn names below are thin aliases so existing component
   classes need no edits. Loads before global.css + jms.css (main.jac order). */

/* ---- fonts: display grotesque (heavy) + body (light) + mono ---- */
@import url('https://fonts.googleapis.com/css2?family=Geist:wght@100..900&family=Geist+Mono:wght@100..900&family=Inter:wght@100..900&display=swap');
@import "@fontsource-variable/space-grotesk";

:root {
  /* ===== glass palette — LIGHT (default) ===== */
  --bg: #faf9f7;
  --bg-gradient:
    radial-gradient(at 18% 0%,  rgba(255,196,150,0.55) 0%, transparent 50%),
    radial-gradient(at 82% 22%, rgba(180,210,255,0.45) 0%, transparent 50%),
    radial-gradient(at 50% 100%, rgba(255,170,120,0.40) 0%, transparent 55%);
  --surface: rgba(255,255,255,0.60);
  --surface-strong: rgba(255,255,255,0.85);
  --text: #16130f;
  --text-muted: #6b6459;
  --border: rgba(255,255,255,0.55);
  --border-alt: rgba(20,16,12,0.08);
  --accent: #EC8242;
  --accent-hover: #d96e2e;
  --accent-soft: #f4a574;
  --accent-tint: rgba(236,130,66,0.12);
  --accent-ring: 0 0 0 3px rgba(236,130,66,0.28);
  --ok: #3a9d6b;
  --danger: #d24b3e;
  --inner-hi: inset 0 1px 0 rgba(255,255,255,0.60);

  /* ===== shared (mode-independent) ===== */
  --radius: 16px;
  --blur: blur(20px) saturate(160%);
  --shadow-soft: 0 8px 32px rgba(20,16,12,0.10);
  --shadow-nav: 0 4px 16px rgba(20,16,12,0.08);
  --font-display: 'Geist', 'Space Grotesk Variable', ui-sans-serif, sans-serif;
  --font-body: 'Inter', ui-sans-serif, system-ui, -apple-system, sans-serif;
  --font-mono: 'Geist Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
  --weight-thin: 200; --weight-light: 300; --weight-reg: 400;
  --weight-bold: 700; --weight-black: 900;
  --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
  --dur-fast: 0.3s; --dur-base: 0.6s; --dur-slow: 0.9s;
  --space-1:4px; --space-2:8px; --space-3:12px; --space-4:16px; --space-5:20px; --space-6:24px;

  /* ===== aliases so existing classes keep working ===== */
  --background: var(--bg); --foreground: var(--text);
  --card: var(--surface); --card-foreground: var(--text);
  --popover: var(--surface-strong); --popover-foreground: var(--text);
  --primary: var(--accent); --primary-foreground: #ffffff;
  --secondary: var(--surface); --secondary-foreground: var(--text);
  --muted: var(--surface); --muted-foreground: var(--text-muted);
  --accent-foreground: #ffffff;
  --destructive: var(--text-muted); --destructive-strong: var(--danger);
  --input: var(--border-alt); --ring: var(--accent);
  --font-sans: var(--font-display);
  --glow: var(--shadow-soft);
  --chart-1: var(--accent); --chart-2: #6aa0e0; --chart-3: var(--text);
  --chart-4: var(--text-muted); --chart-5: var(--accent-soft);
  --sidebar: var(--surface); --sidebar-foreground: var(--text);
  --sidebar-primary: var(--accent); --sidebar-primary-foreground: #ffffff;
  --sidebar-accent: var(--accent); --sidebar-accent-foreground: #ffffff;
  --sidebar-border: var(--border-alt); --sidebar-ring: var(--accent);
  --ws01: var(--accent); --ws02: #6aa0e0; --ws03: #d8a657;
  --ws04: #b89ce8; --ws05: #6fc3b2; --ws06: #e08a8a; --ws-accent: var(--accent);
  /* --jms-* aliases (jms.css classes reference these unchanged) */
  --jms-bg: var(--bg); --jms-bg-raised: var(--surface); --jms-fg: var(--text);
  --jms-fg-dim: var(--text-muted); --jms-accent: var(--accent); --jms-accent-2: var(--chart-2);
  --jms-accent-fg: #ffffff; --jms-border: var(--border-alt); --jms-ok: var(--ok);
  --jms-danger: var(--danger); --jms-font-display: var(--font-display);
  --jms-font-body: var(--font-body); --jms-font-mono: var(--font-mono);
  --jms-radius: var(--radius); --jms-hover-shadow: var(--shadow-soft);
  --jms-border-w: 1px; --jms-rule-style: solid; --jms-display-weight: var(--weight-black);
  --jms-display-tracking: -0.03em; --jms-display-transform: none; --jms-display-glow: none;
  --jms-card-shadow: var(--inner-hi);
  /* --exp-* aliases */
  --exp-radius: var(--radius); --exp-glow: var(--shadow-soft);
  --exp-accent-tint: var(--accent-tint); --exp-accent-ring: var(--accent-ring);
}

.dark {
  /* ===== glass palette — DARK (derived) ===== */
  --bg: #0c0a08;
  --bg-gradient:
    radial-gradient(at 18% 0%,  rgba(236,130,66,0.20) 0%, transparent 55%),
    radial-gradient(at 82% 22%, rgba(90,120,180,0.18) 0%, transparent 55%),
    radial-gradient(at 50% 100%, rgba(236,130,66,0.14) 0%, transparent 60%);
  --surface: rgba(255,255,255,0.05);
  --surface-strong: rgba(255,255,255,0.09);
  --text: #f5f2ec;
  --text-muted: #9a9082;
  --border: rgba(255,255,255,0.08);
  --border-alt: rgba(255,255,255,0.06);
  --accent: #f4914e;
  --accent-hover: #ffa361;
  --accent-soft: #b86a38;
  --accent-tint: rgba(244,145,78,0.16);
  --accent-ring: 0 0 0 3px rgba(244,145,78,0.30);
  --ok: #4fb583;
  --danger: #e5675a;
  --inner-hi: inset 0 1px 0 rgba(255,255,255,0.08);
  --shadow-soft: 0 8px 32px rgba(0,0,0,0.45);
  --shadow-nav: 0 4px 16px rgba(0,0,0,0.40);
  --primary-foreground: #0c0a08;
  --jms-accent-fg: #0c0a08; --accent-foreground: #0c0a08;
}

/* mobile: cheaper blur (DESIGN.md §8) */
@media (max-width: 768px) { :root { --blur: blur(8px) saturate(150%); } }

/* JMS scope base — no per-theme overrides anymore; inherits :root/.dark */
.jms-scope {
  position: relative;
  color: var(--text);
  font-family: var(--font-body);
  -webkit-font-smoothing: antialiased;
  transition: background-color 220ms ease, color 220ms ease;
}
```

- [ ] **Step 2:** `grep -n '\-\*/' studio-desktop/theme.css` → must return nothing (guards the literal-`*/`-in-comment bug from prior work).
- [ ] **Step 3:** `cd studio-desktop && jac check main.jac` → `main.jac PASSED`.
- [ ] **Step 4:** Restart dev server (fonts import changed → safest to restart). Run driver `t1_landing`. Expect app renders (may look half-styled — components still dark-assuming until Phase 1). `errs: []`.
- [ ] **Step 5: Commit.**
```bash
git add studio-desktop/theme.css
git commit -m "feat(glass): rewrite theme.css as light+dark glass token source (orange #EC8242)"
```

### Task 2: `global.css` — Tailwind rebind + body mesh background + noise + motion layer

**Files:**
- Modify: `studio-desktop/global.css` (the `@theme inline` block, `@layer base`, the `body` rule; ADD motion keyframes/stagger + textured background)

**Interfaces:**
- Produces: utility bindings (`bg-background` etc. now resolve to glass tokens); `.reveal` + `.stagger-1..6` motion classes; `body` mesh gradient + noise texture consumed by every page.

- [ ] **Step 1:** Replace the `@theme inline { … }` block's radius section and confirm color binds still point at alias names (they do — `--color-background: var(--background)` etc. resolve through Task 1 aliases). Update the radius scale to the new 16px base (already `calc(var(--radius)*…)` — no change needed). No edit required to the color binds; verify only.
- [ ] **Step 2:** Replace the `body { … }` rule (currently radial-dot texture) with the mesh gradient + noise:

```css
body {
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-body);
  font-weight: var(--weight-light);
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
/* fixed mesh gradient behind all content (DESIGN.md §5) */
body::before {
  content: ""; position: fixed; inset: 0; z-index: -2;
  background: var(--bg-gradient); background-attachment: fixed;
}
/* subtle grain (Distinctive §4 backgrounds) */
body::after {
  content: ""; position: fixed; inset: 0; z-index: -1; pointer-events: none;
  opacity: 0.04; mix-blend-mode: overlay;
  background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 400 400' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
}
```

- [ ] **Step 3:** Append the motion layer (anywhere after `@layer base`):

```css
/* ---- page-load choreography (Distinctive §3) ---- */
.reveal { opacity: 0; animation: fadeInUp var(--dur-base) var(--ease-out) forwards; }
.stagger-1{animation-delay:.05s} .stagger-2{animation-delay:.10s} .stagger-3{animation-delay:.15s}
.stagger-4{animation-delay:.20s} .stagger-5{animation-delay:.25s} .stagger-6{animation-delay:.30s}
@keyframes fadeInUp { from{opacity:0;transform:translateY(24px)} to{opacity:1;transform:none} }
.reveal-scale { opacity:0; animation: scaleIn var(--dur-base) var(--ease-out) forwards; }
@keyframes scaleIn { from{opacity:0;transform:scale(.94)} to{opacity:1;transform:none} }
@media (prefers-reduced-motion: reduce) {
  .reveal,.reveal-scale{animation:none;opacity:1;transform:none}
}
```

- [ ] **Step 4:** Update `html { @apply font-sans; }` in `@layer base` — leave as-is (font-sans now = display; but body sets `--font-body` explicitly, so body text stays Inter). Verify no `@apply` references a removed token.
- [ ] **Step 5:** `jac check main.jac` → PASSED. HMR reload (existing file). Driver `t2_landing`. `Read`: expect warm mesh gradient visible behind content, grain subtle. `errs: []`.
- [ ] **Step 6: Commit.**
```bash
git add studio-desktop/global.css
git commit -m "feat(glass): body mesh gradient + grain + CSS motion layer"
```

---

## Phase 1 — Unified glass component vocabulary (both surfaces identical)

### Task 3: Unify buttons — `.exp-btn` + `.jms-btn` → one grouped glass rule

**Files:**
- Modify: `studio-desktop/global.css` (`.exp-btn*` block, lines ~133-168)
- Modify: `studio-desktop/jms.css` (`.jms-btn*` block, lines ~49-74, 321-322) — delete these (now defined once in global.css grouped with exp)

**Interfaces:**
- Produces: `.exp-btn, .jms-btn` (glass outline), `+ -accent` (orange fill), `+ -ghost`, `+ -danger`. Both class names resolve to identical rules. Consumed by all button call sites unchanged.

- [ ] **Step 1:** In `global.css`, replace the entire `.exp-btn` family with grouped selectors:

```css
/* unified glass button — .exp-btn and .jms-btn are the SAME rule */
.exp-btn, .jms-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  font-family: var(--font-mono); font-size: 11px; font-weight: var(--weight-reg);
  letter-spacing: 0.12em; text-transform: uppercase;
  color: var(--text-muted);
  background: var(--surface); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--border-alt);
  border-radius: calc(var(--radius) * 0.75);
  box-shadow: var(--inner-hi);
  padding: 7px 14px; cursor: pointer;
  transition: color 160ms, border-color 160ms, background-color 160ms, box-shadow 160ms, transform 160ms, filter 160ms;
}
.exp-btn:hover, .jms-btn:hover {
  color: var(--text); border-color: var(--accent);
  transform: translateY(-1px); box-shadow: var(--shadow-soft), var(--inner-hi);
}
.exp-btn:disabled, .jms-btn:disabled { opacity: 0.4; cursor: not-allowed; transform: none; }
.exp-btn-accent, .jms-btn-accent {
  background: var(--accent); border-color: var(--accent); color: #fff;
}
.exp-btn-accent:hover, .jms-btn-accent:hover { filter: brightness(1.08); color: #fff; border-color: var(--accent); }
.exp-btn-ghost, .jms-btn-ghost { background: transparent; backdrop-filter: none; border-color: transparent; box-shadow: none; }
.exp-btn-ghost:hover, .jms-btn-ghost:hover { color: var(--text); border-color: transparent; }
.exp-btn-danger, .jms-btn-danger { color: var(--danger); border-color: var(--border-alt); }
.exp-btn-danger:hover, .jms-btn-danger:hover { color: var(--danger); border-color: var(--danger); }
@supports not (backdrop-filter: blur(1px)) { .exp-btn, .jms-btn { background: var(--surface-strong); } }
```

- [ ] **Step 2:** In `jms.css`, DELETE the old `.jms-btn`/`.jms-btn:hover`/`.jms-btn-accent`/`.jms-btn-accent:hover` block (~49-74) and `.jms-btn-danger`/`:hover` (~321-322). Leave a one-line comment: `/* .jms-btn* unified with .exp-btn* in global.css */`.
- [ ] **Step 3:** `jac check main.jac` → PASSED. HMR. Driver: shoot JMS Projects (has DELETE `.jms-btn-danger`, HUB/KEYS `.jms-btn`) as `t3_jms`, Experiments Cloud (`.exp-btn`) as `t3_exp`. `Read` both. Expect identical frosted buttons with orange hover on both surfaces. `errs: []`.
- [ ] **Step 4: Commit.**
```bash
git add studio-desktop/global.css studio-desktop/jms.css
git commit -m "feat(glass): unify .exp-btn/.jms-btn into one glass button rule"
```

### Task 4: Unify chips, inputs, cards/panels, labels, stats, display

**Files:**
- Modify: `studio-desktop/global.css` (`.exp-chip*`, `.exp-input`, `.exp-panel`, `.exp-hoverable`, `.exp-display`, `.micro-label`, `.stat-line`)
- Modify: `studio-desktop/jms.css` (`.jms-chip`, `.jms-input`/`.jms-textarea`, `.jms-card`, `.jms-label`, `.jms-stat`, `.jms-display`, `.jms-mono`/`.jms-mono-dim`, `.jms-section`/`.jms-section-label`) — replace bodies with grouped-selector references or delete where fully covered by a global.css grouped rule

**Interfaces:**
- Produces grouped rules: `.exp-chip,.jms-chip`(+active), `.exp-input,.jms-input,.jms-textarea`, `.exp-panel,.jms-card,.jms-section`(glass surface), `.micro-label,.jms-label`, `.stat-line,.jms-stat`, `.exp-display,.jms-display`. All consumed unchanged by call sites.

- [ ] **Step 1:** In `global.css`, replace `.exp-chip`/`:hover`/`-active` with a grouped glass chip, adding `.jms-chip`:

```css
.exp-chip, .jms-chip {
  display: inline-flex; align-items: center; gap: 6px;
  font-family: var(--font-mono); font-size: 11px; letter-spacing: 0.04em;
  color: var(--text-muted);
  background: var(--surface); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--border-alt); border-radius: 999px;
  padding: 4px 12px; cursor: pointer;
  transition: color 160ms, border-color 160ms, background-color 160ms, box-shadow 160ms;
}
.exp-chip:hover, .jms-chip:hover { color: var(--text); border-color: var(--accent); }
.exp-chip-active, .jms-chip-active {
  color: var(--accent); border-color: var(--accent);
  background: var(--accent-tint); box-shadow: var(--accent-ring);
}
```
(Note: `.jms-chip` was previously a small orange badge; call sites use it as a badge AND for chat bubbles — the glass pill reads fine in both. Verify in Step 5.)

- [ ] **Step 2:** In `global.css`, replace `.exp-input` adding jms inputs:

```css
.exp-input, .jms-input, .jms-textarea {
  width: 100%; font-family: var(--font-mono); font-size: 12px; color: var(--text);
  background: var(--surface); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--border-alt); border-radius: calc(var(--radius) * 0.6);
  padding: 9px 12px; outline: none;
  transition: border-color 160ms, box-shadow 160ms;
}
.exp-input:focus, .jms-input:focus, .jms-textarea:focus { border-color: var(--accent); box-shadow: var(--accent-ring); }
.exp-input::placeholder, .jms-input::placeholder, .jms-textarea::placeholder { color: var(--text-muted); opacity: 0.7; }
.jms-textarea { resize: vertical; min-height: 68px; line-height: 1.45; }
```

- [ ] **Step 3:** In `global.css`, replace `.exp-panel` + `.exp-hoverable` and add `.jms-card`/`.jms-section` to the glass-surface group:

```css
.exp-panel, .jms-card, .jms-section {
  position: relative;
  background: var(--surface); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--border); border-radius: var(--radius);
  box-shadow: var(--shadow-soft), var(--inner-hi);
  transition: border-color 200ms, box-shadow 200ms, background-color 220ms, transform 200ms;
}
@supports not (backdrop-filter: blur(1px)) { .exp-panel,.jms-card,.jms-section { background: var(--surface-strong); } }
.exp-hoverable { transition: border-color 180ms, box-shadow 180ms, background-color 200ms, color 160ms, transform 180ms; }
.exp-hoverable:hover, .jms-card:hover { border-color: var(--accent); box-shadow: var(--shadow-soft), var(--inner-hi); transform: translateY(-2px); }
```

- [ ] **Step 4:** In `global.css`, update `.micro-label,.jms-label`, `.stat-line,.jms-stat`, `.exp-display,.jms-display` as grouped rules (fold in the previously-fixed values, now with the glass fonts):

```css
.micro-label, .jms-label {
  font-family: var(--font-mono); font-size: 10px; font-weight: 500;
  letter-spacing: 0.18em; text-transform: uppercase; color: var(--text-muted);
  transition: color 180ms ease;
}
.stat-line, .jms-stat {
  font-family: var(--font-mono); font-size: 11px; letter-spacing: 0.06em; color: var(--text-muted);
}
.exp-display, .jms-display {
  font-family: var(--font-display); font-weight: var(--weight-black);
  letter-spacing: -0.03em; line-height: 0.92; color: var(--text);
}
```

- [ ] **Step 5:** In `jms.css`, DELETE the now-duplicated bodies of `.jms-card`(+hover), `.jms-label`, `.jms-stat`, `.jms-display`, `.jms-chip`, `.jms-input`/`.jms-textarea`(+focus/placeholder), `.jms-section`/(keep `.jms-section-label` — it's JMS-only geometry), replacing each with a comment noting it moved to global.css. KEEP JMS-only classes: `.jms-hero-*`, `.jms-topbar`, `.jms-footer`, `.jms-rail`, `.jms-pill*`, `.jms-grid`, `.jms-pcard`, `.jms-pname`, `.jms-dots`/`.jms-dot*`, `.jms-newcard`, `.jms-srow`, `.jms-mono*`, `.jms-trunc-left`, `.jms-flash`, `.jms-section-label`, `.jms-switcher*`/`.jms-swatch*` (swatches deleted in Phase 3). For `.jms-pname` update its `font-weight`/`tracking` to `var(--weight-black)`/`-0.03em`; for `.jms-mono`/`.jms-mono-dim` keep (mono text, token-colored).
- [ ] **Step 6:** `jac check main.jac` → PASSED. HMR. Driver: JMS Projects (`t4_jms_projects`), JMS Sources (`t4_jms_sources`, has `.jms-section`/`.jms-input`/`.jms-chip`), Experiments Chat (`t4_exp_chat`), Experiments Data (`t4_exp_data`). `Read` all four. Expect frosted glass cards/panels/inputs, orange focus rings, identical chrome across surfaces. `errs: []`.
- [ ] **Step 7: Commit.**
```bash
git add studio-desktop/global.css studio-desktop/jms.css
git commit -m "feat(glass): unify chips/inputs/cards/panels/labels/display across surfaces"
```

### Task 5: Retire the shared `Button` wrapper's exp-only bias (verify parity)

**Files:**
- Modify (only if needed): `studio-desktop/components/shared/Button.cl.jac`

**Interfaces:**
- Consumes: `.exp-btn*` grouped rules from Task 3.
- Produces: `Button` component now renders identical glass on any surface (its classes are the unified ones).

- [ ] **Step 1:** Read `Button.cl.jac`. Its `VARIANTS` map uses `exp-btn`/`exp-btn exp-btn-accent`/`exp-btn exp-btn-ghost` — these are now the unified glass rules, so no code change is required; the component already produces the correct glass button everywhere. Confirm by reading only.
- [ ] **Step 2:** If any JMS surface hand-writes `className="jms-btn"` where a `<Button>` would be cleaner — DO NOT refactor now (ponytail; out of scope). Leave call sites.
- [ ] **Step 3:** No code change → no commit. (This task is a verification gate: confirm `Button` needs nothing. If it hardcodes a removed token, fix minimally and commit.)

---

## Phase 2 — JMS-only layout glassification

### Task 6: Glassify JMS hero panels + topbar/footer + stage rail + project cards

**Files:**
- Modify: `studio-desktop/jms.css` (`.jms-hero-panel`, `.jms-topbar`, `.jms-footer`, `.jms-rail`, `.jms-pill*`, `.jms-pcard`, `.jms-newcard`, `.jms-section-label`, `.jms-hero-accent-tick`)

**Interfaces:**
- Produces: JMS layout surfaces adopt glass (frosted bg, blur, soft shadow, inner-highlight) while keeping their unique geometry (hero grid sizing, rail width, pill shape).

- [ ] **Step 1:** `.jms-hero-panel` — it already has `.jms-card` (now glass from Task 4). Update its own rule: remove any opaque `background-color`; ensure `border-radius: var(--radius)`. Keep the flex/padding/hover-lift geometry. The accent tick gradient → orange:

```css
.jms-hero-accent-tick {
  width: 34px; height: 3px; border-radius: 2px;
  background: linear-gradient(90deg, var(--accent), var(--accent-soft));
  transition: width 200ms ease;
}
```

- [ ] **Step 2:** `.jms-topbar`/`.jms-footer` — make them frosted glass bars:

```css
.jms-topbar {
  display:flex; align-items:center; justify-content:space-between; gap:16px;
  padding:14px clamp(16px,2.5vw,32px);
  background: var(--surface-strong); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border-bottom:1px solid var(--border-alt); flex-shrink:0;
}
.jms-footer {
  display:flex; align-items:center; justify-content:center;
  padding:10px clamp(16px,2.5vw,32px);
  border-top:1px solid var(--border-alt); flex-shrink:0;
}
```

- [ ] **Step 3:** `.jms-section-label` — background must match the panel it floats over. Change `background-color: var(--jms-bg)` → `background: var(--surface-strong); backdrop-filter: var(--blur);` so the floating tab reads on glass.
- [ ] **Step 4:** `.jms-pill-active` and `.jms-pill-dot-done` → orange (`var(--accent)`); `.jms-pill-active` background → `var(--accent-tint)`. `.jms-dot-on` → `var(--accent)`.
- [ ] **Step 5:** `jac check main.jac` → PASSED. HMR. Driver: JMS Landing (`t6_landing`), JMS Sources (`t6_sources`), JMS Train (`t6_train`). `Read`. Expect frosted hero panels over the mesh gradient, glass topbar, orange ticks/pills. Confirm the section-label floating tab is legible on glass. `errs: []`.
- [ ] **Step 6: Commit.**
```bash
git add studio-desktop/jms.css
git commit -m "feat(glass): glassify JMS hero/topbar/rail/section layout, orange accents"
```

---

## Phase 3 — Light/dark toggle (replace forced-dark + dead switchers)

### Task 7: AppShell + frontend — theme init from preference, not forced dark

**Files:**
- Modify: `studio-desktop/components/AppShell.cl.jac:108-111` (`async can with entry` — remove forced `.dark`)
- Modify: `studio-desktop/frontend.cl.jac` (add a mount-time theme init so Landing/Login/loading frames get the right mode)

**Interfaces:**
- Produces: a single localStorage key `jacml.mode` ∈ `{"light","dark"}`; `.dark` class on `<html>` applied from it (or `prefers-color-scheme` on first visit). Consumed by Task 8's toggle.

- [ ] **Step 1:** In `AppShell.cl.jac`, replace lines 109-111 (`doc.documentElement.classList.add("dark")` + antialiased) with a preference read:

```jac
        doc: any = document;
        win: any = window;
        mode: str = "dark";
        try {
            saved: any = win.localStorage.getItem("jacml.mode");
            if saved { mode = str(saved); }
            elif win.matchMedia and win.matchMedia("(prefers-color-scheme: light)").matches { mode = "light"; }
        } except Exception { }
        if mode == "dark" { doc.documentElement.classList.add("dark"); }
        else { doc.documentElement.classList.remove("dark"); }
        doc.body.classList.add("antialiased");
```

- [ ] **Step 2:** In `frontend.cl.jac`'s `async can with entry` (after the jms.theme block ~line 48), add the same mode-apply so the Landing/loading frames (which mount before AppShell) get it. Also change the `checking` blank frame (line 85) from `bg-[#0a0a0a]` to `bg-background` so it respects the mode.

```jac
        # apply persisted light/dark mode before first paint
        try {
            dc: any = document;
            wm: any = window;
            md: str = "dark";
            sv2: any = wm.localStorage.getItem("jacml.mode");
            if sv2 { md = str(sv2); }
            elif wm.matchMedia and wm.matchMedia("(prefers-color-scheme: light)").matches { md = "light"; }
            if md == "dark" { dc.documentElement.classList.add("dark"); }
            else { dc.documentElement.classList.remove("dark"); }
        } except Exception { }
```

- [ ] **Step 3:** `jac check main.jac` → PASSED. Restart (component logic changed; safe). Driver `t7_landing`. Expect: with no `jacml.mode` set and a dark OS pref → dark glass; the loading frame no longer flashes hardcoded black. `errs: []`.
- [ ] **Step 4: Commit.**
```bash
git add studio-desktop/components/AppShell.cl.jac studio-desktop/frontend.cl.jac
git commit -m "feat(glass): init light/dark from preference instead of forcing dark"
```

### Task 8: Rewrite `ThemeSwitcher` as a light/dark toggle + mount it

**Files:**
- Modify (rewrite): `studio-desktop/components/ThemeSwitcher.cl.jac`
- Modify: `studio-desktop/components/jms/Landing.cl.jac` (mount the toggle in the topbar) AND `studio-desktop/components/jms/JmsShell.cl.jac` (mount in topbar) — so the toggle is reachable from both surfaces. Experiments' `WorkspaceBar` also gets it (Step 4).

**Interfaces:**
- Consumes: `jacml.mode` from Task 7.
- Produces: `ThemeSwitcher()` component — a single button toggling `.dark` on `<html>` + persisting `jacml.mode`. No props needed.

- [ ] **Step 1:** Replace `ThemeSwitcher.cl.jac` entirely:

```jac
"""ThemeSwitcher — one button toggling light/dark. Flips the `.dark` class on
<html> and persists to localStorage('jacml.mode'). All theming is CSS vars
(theme.css :root vs .dark), so no state reaches other components."""

def:pub ThemeSwitcher() -> JsxElement {
    has mode: str = "dark";

    can with entry {
        win: any = window;
        try {
            saved: any = win.localStorage.getItem("jacml.mode");
            if saved { mode = str(saved); }
        } except Exception { }
    }

    def toggle(e: MouseEvent) {
        nextMode: str = "light" if mode == "dark" else "dark";
        mode = nextMode;
        doc: any = document;
        win: any = window;
        if nextMode == "dark" { doc.documentElement.classList.add("dark"); }
        else { doc.documentElement.classList.remove("dark"); }
        try { win.localStorage.setItem("jacml.mode", nextMode); } except Exception { }
    }

    return <button
        onClick={toggle}
        className="jms-btn"
        title="toggle light / dark"
    >{"◐ DARK" if mode == "dark" else "◑ LIGHT"}</button>;
}
```

- [ ] **Step 2:** Mount in `Landing.cl.jac` topbar — change the topbar div (lines 14-16) to include the toggle on the right:

```jac
    import from ..ThemeSwitcher { ThemeSwitcher }
    ...
        <div className="jms-topbar">
            <span className="jms-label">JAC MODEL STUDIO</span>
            <ThemeSwitcher />
        </div>
```
(Add the import at top of Landing.cl.jac: `import from ..ThemeSwitcher { ThemeSwitcher }`.)

- [ ] **Step 3:** Mount in `JmsShell.cl.jac` topbar — add `import from ..ThemeSwitcher { ThemeSwitcher }` and place `<ThemeSwitcher />` in the right-hand action group (before `⚙ KEYS`).
- [ ] **Step 4:** Mount in Experiments — read `components/WorkspaceBar.cl.jac`, add `import from .ThemeSwitcher { ThemeSwitcher }` and render `<ThemeSwitcher />` in its right-hand region (next to settings/hub). If WorkspaceBar's structure makes this awkward, mount in `NavRail.cl.jac` bottom instead (it already has a footer area). Pick whichever is a ≤3-line insert.
- [ ] **Step 5:** `jac check main.jac` → PASSED. Restart (new import + new mounts). Driver: Landing (`t8_landing`), then a second script run that clicks the toggle and re-shoots (`t8_landing_light`), and one Experiments page toggled (`t8_exp_light`). `Read` all. Expect the whole Studio flips light↔dark, orange accent persists, glass reads correctly in both. `errs: []`.
- [ ] **Step 6: Commit.**
```bash
git add studio-desktop/components/ThemeSwitcher.cl.jac studio-desktop/components/jms/Landing.cl.jac studio-desktop/components/jms/JmsShell.cl.jac studio-desktop/components/WorkspaceBar.cl.jac studio-desktop/components/NavRail.cl.jac
git commit -m "feat(glass): light/dark toggle button, mounted on both surfaces"
```

### Task 9: Delete `JmsThemeSwitcher` + the dead 5-theme/`data-jms-theme` machinery

**Files:**
- Delete: `studio-desktop/components/jms/JmsThemeSwitcher.cl.jac`
- Modify: `studio-desktop/components/jms/Landing.cl.jac` (drop `data-jms-theme={t}` + `t` local), `studio-desktop/components/jms/JmsShell.cl.jac` (same), `studio-desktop/frontend.cl.jac` (drop `jmsTheme`/`applyJmsTheme`/`jms.theme` plumbing + the theme/onTheme props), `studio-desktop/jms.css` (delete `.jms-switcher*` + `.jms-swatch*`)

**Interfaces:**
- Produces: JMS surfaces render under `.jms-scope` inheriting `:root`/`.dark` (no per-jms-theme attribute).

- [ ] **Step 1:** Confirm `JmsThemeSwitcher` has no remaining importers: `grep -rn "JmsThemeSwitcher" studio-desktop/` → only its own file. Delete the file.
- [ ] **Step 2:** In `Landing.cl.jac`: remove line 9 `t: str = "electric-minimal";` and the `data-jms-theme={t}` attribute (keep `className="jms-scope …"`). Update the docstring line about the theme lock.
- [ ] **Step 3:** In `JmsShell.cl.jac`: remove `t: str = "electric-minimal";` (line 20) and `data-jms-theme={t}` (line 34); drop the unused `theme`/`onTheme` params from the signature (line 15) if nothing passes them after Step 4. Update docstring.
- [ ] **Step 4:** In `frontend.cl.jac`: remove `jmsTheme` has-field, the `jms.theme` localStorage restore block (lines 42-48 region), `applyJmsTheme`, and the `theme=`/`onTheme=` props on `<JmsShell>`/`<Landing>` (they no longer accept them). Keep the rest of the router intact.
- [ ] **Step 5:** In `jms.css`: delete `.jms-switcher`, `.jms-switcher-name`, `.jms-swatch`, `.jms-swatch:hover`, `.jms-swatch-active`, and the five `.jms-swatch-<theme>` rules.
- [ ] **Step 6:** `jac check main.jac` → PASSED. Restart. Driver: Landing + JMS Projects + JMS Train, both modes. `Read`. Expect no visual change vs Task 8 (the machinery was dormant) but no console errors from missing props. `errs: []`.
- [ ] **Step 7: Commit.**
```bash
git add -u studio-desktop/
git commit -m "chore(glass): delete dormant 5-theme JMS switcher + data-jms-theme plumbing"
```

---

## Phase 4 — Landing unification + expansion

### Task 10: Make the two Landing entries pixel-identical

**Files:**
- Modify: `studio-desktop/components/jms/Landing.cl.jac`
- Modify: `studio-desktop/jms.css` (`.jms-hero-grid` columns, `.jms-hero-word*`, remove `.jms-hero-quiet`)

**Interfaces:**
- Produces: two identical glass entry cards differing only in text.

- [ ] **Step 1:** In `jms.css`: set `.jms-hero-grid` `grid-template-columns: 1fr 1fr;` (was `1.12fr 1fr`). Merge `.jms-hero-word` and `.jms-hero-word-sm` into ONE size used by both — set both to `font-size: clamp(44px, min(7vw, 13vh), 104px);` (a middle ground so both "JMS" and "EXPERIMENTS" fit their equal columns without overflow). Delete `.jms-hero-quiet` + its `.jms-hero-quiet .jms-hero-sub` rule.
- [ ] **Step 2:** In `Landing.cl.jac`: on the Experiments panel remove the `jms-hero-quiet` class; change `jms-hero-word-sm` → `jms-hero-word` on the EXPERIMENTS word so both use the same class. Keep distinct kicker/sub/stat text.
- [ ] **Step 3:** `jac check main.jac` → PASSED. HMR (jms.css) + restart is safer (Landing changed). Driver: `t10_landing` at 1400px, and re-run at viewport 1024px (`t10_landing_sm`) to catch overflow of "EXPERIMENTS". `Read` both. Expect two identical cards, equal width, same word size, no clipping. `errs: []`.
- [ ] **Step 4: Commit.**
```bash
git add studio-desktop/components/jms/Landing.cl.jac studio-desktop/jms.css
git commit -m "feat(glass): make JMS and Experiments landing entries pixel-identical"
```

### Task 11: Expand the Landing — floating pill nav, staggered reveal, depth row

**Files:**
- Modify: `studio-desktop/components/jms/Landing.cl.jac`
- Modify: `studio-desktop/jms.css` (add `.jms-pillnav`, `.jms-feature-row`, `.jms-feature`)

**Interfaces:**
- Produces: a richer landing — floating pill nav at top (`--surface-strong` blur), hero entries with `.reveal`/`.stagger-N`, and a 3-card glass feature/stat row below.

- [ ] **Step 1:** Add CSS to `jms.css`:

```css
/* floating pill nav (DESIGN.md §4 navigation) */
.jms-pillnav {
  position: absolute; top: 18px; left: 50%; transform: translateX(-50%); z-index: 20;
  display: flex; align-items: center; gap: 18px;
  padding: 8px 18px; border-radius: 999px;
  background: var(--surface-strong); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--border); box-shadow: var(--shadow-nav), var(--inner-hi);
}
/* depth row beneath the two entries */
.jms-feature-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: clamp(12px,1.4vw,20px);
  padding: 0 clamp(16px,2.5vw,32px) clamp(14px,2vw,28px); }
.jms-feature {
  padding: 16px 18px; border-radius: var(--radius);
  background: var(--surface); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
  border: 1px solid var(--border); box-shadow: var(--shadow-soft), var(--inner-hi);
}
```

- [ ] **Step 2:** In `Landing.cl.jac`, restructure the return. Replace the plain `jms-topbar` with the floating pill nav (wordmark + a subtle tagline + `<ThemeSwitcher/>`), add `reveal stagger-N` classes to the two hero panels, and add a 3-card feature row under the hero grid. Full return body:

```jac
    return <div className="jms-scope relative flex h-screen w-screen flex-col overflow-hidden">
        <div className="jms-pillnav reveal stagger-1">
            <span className="jms-label" style={{"color": "var(--text)"}}>JAC · MODEL STUDIO</span>
            <ThemeSwitcher />
        </div>

        <div className="jms-hero-grid" style={{"paddingTop": "84px"}}>
            <div className="jms-card jms-hero-panel reveal stagger-2"
                onClick={lambda e: MouseEvent { if onPick is not None { onPick("jms"); } }}>
                <span className="jms-label jms-hero-kicker">NEW · PROJECT PIPELINE</span>
                <span className="jms-display jms-hero-word">JMS</span>
                <span className="jms-hero-accent-tick" />
                <span className="jms-hero-sub">Synthesize a dataset. Train a model for it.</span>
                <span className="jms-stat">dataset synthesis · cloud + local finetuning · eval</span>
            </div>
            <div className="jms-card jms-hero-panel reveal stagger-3"
                onClick={lambda e: MouseEvent { if onPick is not None { onPick("experiments"); } }}>
                <span className="jms-label jms-hero-kicker">EXISTING LAB</span>
                <span className="jms-display jms-hero-word">EXPERIMENTS</span>
                <span className="jms-hero-accent-tick" />
                <span className="jms-hero-sub">The existing lab: chat, data, train, RL, CPT.</span>
                <span className="jms-stat">sft/dpo · rl/grpo · cpt workspaces</span>
            </div>
        </div>

        <div className="jms-feature-row reveal stagger-4">
            <div className="jms-feature">
                <span className="jms-label">LOCAL · FIRST</span>
                <div className="jms-hero-sub" style={{"marginTop":"6px"}}>Your models, your data. Native desktop, MLX on-device.</div>
            </div>
            <div className="jms-feature">
                <span className="jms-label">CLOUD · WHEN YOU WANT</span>
                <div className="jms-hero-sub" style={{"marginTop":"6px"}}>Burst to Spheron GPUs for heavier finetunes.</div>
            </div>
            <div className="jms-feature">
                <span className="jms-label">END · TO · END</span>
                <div className="jms-hero-sub" style={{"marginTop":"6px"}}>Synthesize → curate → train → eval, one surface.</div>
            </div>
        </div>

        <div className="jms-footer reveal stagger-5">
            <span className="jms-stat">local-first · your models, your data</span>
        </div>
    </div>;
```

- [ ] **Step 3:** `jac check main.jac` → PASSED. Restart. Driver: `t11_landing` (dark) + toggle + `t11_landing_light`. Watch that the hero grid + feature row + footer all fit `h-screen` with no page scroll at 1400×1000 (reduce hero panel min-heights in `.jms-hero-panel` if it overflows — the feature row adds height). `Read`. Expect: floating pill nav, staggered entrance, identical entries, glass feature cards, both modes beautiful, no scroll. `errs: []`.
- [ ] **Step 4:** If content overflows `h-screen`: in `.jms-hero-grid` reduce vertical padding and/or in `.jms-hero-panel` lower the top padding; re-shoot until no scrollbar. Document the final values in the commit.
- [ ] **Step 5: Commit.**
```bash
git add studio-desktop/components/jms/Landing.cl.jac studio-desktop/jms.css
git commit -m "feat(glass): expand landing — pill nav, staggered reveal, glass feature row"
```

---

## Phase 5 — Motion choreography across surfaces

### Task 12: Add staggered entrance to JMS + Experiments mounts

**Files:**
- Modify: `studio-desktop/components/jms/JmsShell.cl.jac` (topbar + body reveal)
- Modify: `studio-desktop/components/jms/JmsProjects.cl.jac` (card grid stagger)
- Modify: `studio-desktop/components/SectionMount.cl.jac` OR each section's root — add a `reveal` on the active section container

**Interfaces:**
- Produces: each surface animates in on mount/switch (choreography over scatter — Distinctive §3).

- [ ] **Step 1:** In `JmsShell.cl.jac`, add `reveal stagger-1` to the topbar div and `reveal stagger-2` to the body wrapper.
- [ ] **Step 2:** In `JmsProjects.cl.jac`, add `reveal` + `stagger-N` (N from index, cap 6) to each project card in the `.jms-grid` loop — use `("reveal stagger-" + str(min(i+1, 6)))` appended to the card className, iterating with `enumerate`. (Follow the cl statement-slot + `key=` rules.)
- [ ] **Step 3:** For Experiments: in `AppShell.cl.jac`'s slot render (line 182), append `reveal` to the visible slot's className via the `slot()` helper — change `slot()` to return `"flex min-w-0 flex-1 reveal"` when visible. This animates each section as it becomes active.
- [ ] **Step 4:** `jac check main.jac` → PASSED. Restart. Driver: click JMS → shoot (`t12_jms`), click a project → shoot, switch Experiments sections → shoot. `Read`. Expect smooth staggered entrances; `prefers-reduced-motion` still yields instant (spot-check by emulating reduced motion in the driver: `p.chromium.launch()` + `new_page(..., reduced_motion="reduce")` → elements visible, no anim). `errs: []`.
- [ ] **Step 5: Commit.**
```bash
git add studio-desktop/components/jms/JmsShell.cl.jac studio-desktop/components/jms/JmsProjects.cl.jac studio-desktop/components/AppShell.cl.jac
git commit -m "feat(glass): staggered entrance choreography on JMS + Experiments mounts"
```

---

## Phase 6 — Full verification sweep (Playwright MCP) + AI-slop audit

### Task 13: Interactive Playwright MCP sweep, both modes, all surfaces

**Files:** none (verification only) — may produce follow-up fix commits.

- [ ] **Step 1:** Using the Playwright MCP tools (deferred — load via `ToolSearch("select:…")` for the playwright MCP server if present; otherwise drive via the `.venv` Playwright script), walk the full app in DARK: Landing → JMS → New Project → Sources → Generate → Curate → Train → Eval → back → Experiments → Chat → Data → Train → Evals → Cloud → Plan. Screenshot each. Toggle each interactive control (buttons hover, chips select, inputs focus) and confirm orange accent + glass.
- [ ] **Step 2:** Repeat the entire walk in LIGHT (toggle first).
- [ ] **Step 3:** `Read` every screenshot. Build a defect list: any surface still opaque/non-glass, any non-orange accent, any unreadable text (contrast), any overflow/clipping, any element that didn't get the font/weight treatment.
- [ ] **Step 4:** Run the **AI-slop checklist** against the result (Distinctive skill): ❌ no Inter-as-display (display must be Geist heavy), ❌ no 400/500/600 display weights, ❌ no flat gray backgrounds (mesh must show), ❌ no missing entrance motion. ✅ distinctive font pairing, ✅ extreme weight contrast, ✅ cohesive orange theme, ✅ orchestrated motion, ✅ layered background. Note violations.
- [ ] **Step 5:** Fix each defect with a minimal targeted edit (one commit per coherent fix group). Re-shoot the affected page after each. Do not batch blind.
- [ ] **Step 6:** Final confirm: zero console/network errors across the whole walk in both modes. Commit any fixes:
```bash
git add studio-desktop/...
git commit -m "fix(glass): <specific defect> from full-sweep verification"
```

### Task 14: Contrast + font-loading audit

**Files:** none unless fixes needed.

- [ ] **Step 1:** In the driver, evaluate `getComputedStyle` on `body` → confirm `font-family` resolves to Inter (not fallback) and a display element resolves to Geist. If a font failed to load (Network tab 4xx on the Google Fonts / fontsource request), fix the `@import`.
- [ ] **Step 2:** Spot-check WCAG contrast on muted text over glass in light mode (the riskiest): `--text-muted #6b6459` on `--surface` over the peach gradient. If it reads too faint, darken `--text-muted` to `#5a5348` and re-shoot. (Accessibility is a "don't simplify away" per ponytail.)
- [ ] **Step 3:** Commit any fixes.

---

## Phase 7 — Folder consolidation (delete stale `jms/`, keep `jms-projects/`, rename `studio-desktop/`→`jms/`)

### Task 15: Pre-rename checkpoint + delete stale `jms/`

**Files:** repo root.

- [ ] **Step 1: Safety checkpoint.** `git status` clean (all glass work committed). `git rev-parse HEAD` — record the SHA in the commit message of Step 4 as the rollback point. Confirm the real adapters exist: `ls -la jms-projects/train-real-mlx/runs/*/adapter/ jms-projects/p10-eval-real/runs/*/adapter/` → the ~538 MB / ~269 MB safetensors are present. **Do not proceed if `jms-projects/` is missing or empty.**
- [ ] **Step 2:** Confirm `jms/` is pure cache: `find jms -type f -name '*.jac' | head` → empty; `du -sh jms`. If the old SQLite matters to you, archive first: `cp -r jms/.jac/data /tmp/old-jms-db-archive` (optional; default skip). 
- [ ] **Step 3:** Delete: `rm -rf jms/`. Verify: `ls jms 2>&1` → "No such file".
- [ ] **Step 4:** This isn't a source change (jms/ was gitignored cache) so there may be nothing to commit. If `.gitignore` referenced `jms/` specifically, leave it (harmless). No commit unless `.gitignore` changes.

### Task 16: Rename `studio-desktop/` → `jms/` + update path references

**Files:**
- Rename: `studio-desktop/` → `jms/`
- Modify (string refs only): `PLAN.md`, `studio.workspace.toml`, `studio-desktop/README.md`, `studio-desktop/scripts/backup_graph.sh` (cron comment), `studio-desktop/scripts/dev/fake_spheron.py` (comment), `studio-desktop/paths.sv.jac` (docstring), `docs/superpowers/specs/2026-07-22-glass-studio-design.md` (leave — historical). NOTE: `paths.sv.jac` LOGIC uses `__file__`/`.parent` — no logic change needed; `workspace_root()` still resolves to repo root after rename.

**Interfaces:**
- Produces: the app dir is now `jms/`; `workspace_root()` = repo root (unchanged); `jms-projects/` still resolves.

- [ ] **Step 1:** `git mv studio-desktop jms`. (Git preserves history; moves all tracked files.)
- [ ] **Step 2:** Move untracked-but-needed runtime dirs too if `git mv` skipped them: `ls studio-desktop 2>/dev/null` should be empty; if `.jac/`, `.venv/`, DBs remain (untracked), `mv studio-desktop/.jac jms/.jac` etc., or just `rmdir`/`mv` leftovers. Confirm the app's own `.jac/data/*.db` moved so local projects/users persist.
- [ ] **Step 3:** Update the literal `studio-desktop` strings that are NOT remote-deploy paths:
  - `README.md`: `studio-desktop` → `jms` (all occurrences).
  - `PLAN.md`, `studio.workspace.toml` (the LOCAL entries; **leave `remote_studio_root = "/workspace/studio-desktop"`** and `spheron.sv.jac:721`'s remote default — those are the Spheron GPU worker's checkout path, independent of the local rename, unless you also rename the remote checkout).
  - `scripts/backup_graph.sh` cron comment, `scripts/dev/fake_spheron.py` comment, `paths.sv.jac` docstring line 5.
- [ ] **Step 4:** Update any launch/start scripts referencing the old dir: `grep -rn "studio-desktop" jms/*.sh jms/start*.sh 2>/dev/null` and fix.
- [ ] **Step 5:** `cd jms && jac check main.jac` → `main.jac PASSED`.
- [ ] **Step 6: Commit the rename.**
```bash
git add -A
git commit -m "refactor: rename studio-desktop -> jms (canonical app dir); rollback=<HEAD SHA from Task 15>"
```

### Task 17: Post-rename functional verification

**Files:** none.

- [ ] **Step 1:** Start the app from the new dir (`cd jms && ./start.sh` or the dev command with the env vars, per README). Confirm it boots — no import errors, no missing-path errors.
- [ ] **Step 2:** Driver against `http://localhost:8000/`: Landing loads (glass), click JMS → **existing projects appear** (proves `jms-projects/` still resolves via `workspace_root()`). Open `p10-eval-real` or `train-real-mlx` → its real adapter/eval data loads.
- [ ] **Step 3:** Full smoke: `cd jms && ./smoke.sh` (if present) or the driver walk from Task 13 (abbreviated). Confirm both surfaces render, light/dark toggles, `errs: []`.
- [ ] **Step 4:** Confirm `jms-projects/` untouched: `ls -la jms-projects/train-real-mlx/runs/*/adapter/` → adapters still present, same sizes.
- [ ] **Step 5:** Update memory (`project-jac-ml-studio.md`, `project-studio-overhaul.md`) noting: app dir renamed to `jms/`; glass design system live; light/dark; orange accent. Update `docs/README.md` status line if present.
- [ ] **Step 6: Commit** any doc/memory updates (memory lives outside repo — write those files directly; commit only in-repo docs).

---

## Self-review (spec coverage)

- Glass light+dark tokens → Tasks 1-2. ✅
- Orange accent everywhere → Tasks 1,3,4,6 + audit 13. ✅
- Extreme font weights + distinctive display (Geist) + Inter body → Task 1 fonts, Task 4 display, audit 14. ✅
- Unified twin classes (grouped selectors, zero call-site churn) → Tasks 3-4. ✅
- Glass with `@supports`/mobile fallback → Tasks 1,3,4. ✅
- Motion layer + choreography + reduced-motion → Tasks 2,11,12. ✅
- Mesh gradient + noise background → Task 2. ✅
- Landing entries identical → Task 10; expanded (pill nav, depth row, reveal) → Task 11. ✅
- Working light/dark toggle, kill dead switchers → Tasks 7,8,9. ✅
- Distinctive four-vector + AI-slop checklist → Task 13. ✅
- Delete stale `jms/`, KEEP `jms-projects/`, rename `studio-desktop`→`jms` → Tasks 15-17. ✅
- Playwright MCP + visual checks throughout → per-task verification + Task 13. ✅
- Never-delete `jms-projects/` adapters → Tasks 15,17 guards. ✅

## Notes / deliberate simplifications (ponytail)

- Grouped selectors instead of renaming `.jms-*`→`.g-*` across 43 files: identical result, ~zero churn. A cosmetic rename is a future option, not now.
- No framer-motion: CSS keyframes cover all needed choreography.
- Dark palette derived, not designed from a second DESIGN.md: matches "I derive it" decision.
- `jms-projects/` QA-dir pruning deferred (not asked); only stale `jms/` cache deleted.
- Remote Spheron `remote_studio_root` left as `/workspace/studio-desktop` unless the remote checkout is also renamed — local rename doesn't force it.
