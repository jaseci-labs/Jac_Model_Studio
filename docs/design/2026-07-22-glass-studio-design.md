# Glass Studio — unified frosted design system (light + dark)

**Date:** 2026-07-22
**Status:** approved design, pre-plan
**Surfaces:** JMS (project pipeline) + Experiments (chat/data/train/RL/CPT) — one identity, "cut from the same cloth."

## Goal

Replace the Studio's current dark terminal/mono aesthetic (5 dormant JMS themes + a dead 7-theme Experiments switcher, hard-locked to dark) with **one** frosted "soft-futurism" design system that:

1. Follows `DESIGN.md` (Arc glass: translucent surfaces, backdrop blur, pastel radial mesh gradients, soft geometry, generous radii) — **with the primary accent changed from purple to orange `#EC8242`.**
2. Applies the Distinctive-Design four-vector rigor where it doesn't fight DESIGN.md: **extreme font-weight contrast** (heavy display 800/900 vs light body 200/300), a distinctive grotesque display face (not Inter), **orchestrated staggered page-load motion**, and layered/textured backgrounds.
3. Renders **identically** on JMS and Experiments — same tokens, same component classes, so the two surfaces are visually one product.
4. Ships a working **light AND dark** mode (both greenfield today).
5. Expands the Landing page and makes the JMS and Experiments entry elements pixel-identical.
6. Ends with folder consolidation: delete stale `jms/`, keep live `jms-projects/`, rename `studio-desktop/`→`jms/`.

Efficiency governed by `ponytail`: shortest working diff, no framer-motion, CSS-only motion, grouped selectors instead of a 43-file class rename.

## Decisions locked (from brainstorming)

| Question | Decision |
|---|---|
| DESIGN.md vs Distinctive skill | **Blend** — DESIGN.md governs glass surfaces/gradients/radii; Distinctive skill governs weight extremes + distinctive display font + motion + bg depth. |
| Primary accent | **Orange `#EC8242`** (RGB 236,130,66), replacing DESIGN.md's purple `#8b5cf6`. Gradients warmed to harmonize. |
| Old themes | **Replace all** — delete the 5 JMS themes + terminal look. One glass identity, light/dark only. |
| Dark palette | **Derived** dark-glass (below), presented for approval. |
| Fonts | Free stand-in for PP Neue Montreal (**Geist** / Space Grotesk, already loaded) at heavy weight for display; **Inter** body at light weight; one mono for code. |
| Folder op | Delete `jms/` (stale cache, 0 source files) only; **keep `jms-projects/`** (807 MB real adapters + live data); rename `studio-desktop/`→`jms/`. |

## Current-state facts (from audit — trust these)

- **`jms/`** = 186 MB stale compile cache, **zero source files** (source deleted in git `95005881`), no live references → safe to delete. Only non-regenerable bit: old `jms/.jac/data/*.db` (obsolete; studio-desktop has its own DBs).
- **`jms-projects/`** = live data store, referenced by `studio-desktop/jms_projects.sv.jac:179` and `jms_chat.sv.jac:53` via `paths.workspace_root() / "jms-projects"`; `workspace_root()` = repo root. Holds ~807 MB real MLX adapters (`train-real-mlx`, `p10-eval-real`) + real evals. **Must not be deleted; must stay at repo root** so the renamed app still resolves it.
- **Landing** (`components/jms/Landing.cl.jac`): both entries already `jms-card jms-hero-panel`; differ only by `jms-hero-quiet`, `jms-hero-word` (200px) vs `jms-hero-word-sm` (82px), grid `1.12fr 1fr`.
- **Buttons**: 3 twin systems — `.exp-btn*` (`global.css:136-171`), `.jms-btn*` (`jms.css:49-74,321-322`), shared `Button.cl.jac` wrapping only exp. Token-for-token identical.
- **Class call-sites**: `.exp-*` = 140 sites / 32 files; `.jms-*` = 420 sites / 11 files (dense in `jms/stages/*`). Restyling class *definitions* touches only 3 CSS files.
- **Motion**: none but hover + one `mono-pulse` keyframe; `tw-animate-css` imported, unused; no framer-motion.
- **Glass/blur**: zero usages today — greenfield.
- **Themes**: Experiments `data-theme` switcher (`ThemeSwitcher.cl.jac`) is dead (no CSS backs it); JMS `data-jms-theme` locked to `electric-minimal` (`JmsShell.cl.jac:20`, `Landing.cl.jac:9`); `AppShell.cl.jac:110` forces `.dark` at boot. No working light mode.
- **CSS import order** (`main.jac:111-120`, load-bearing): `theme.css` → `global.css` → `jms.css`.
- **Fonts loaded**: Geist, Geist Mono, Space Grotesk, Instrument Sans, Archivo, Instrument Serif (7 across themes). After theme removal, trim to 3.

## Palette

### Light (default `:root`) — glass, orange
```
--bg:              #faf9f7        /* warm off-white */
--bg-gradient:     radial-gradient(at 18% 0%,  rgba(255,196,150,0.55) 0%, transparent 50%),
                   radial-gradient(at 82% 22%, rgba(180,210,255,0.45) 0%, transparent 50%),
                   radial-gradient(at 50% 100%,rgba(255,170,120,0.40) 0%, transparent 55%);
--surface:         rgba(255,255,255,0.60)      /* frosted */
--surface-strong:  rgba(255,255,255,0.85)
--text:            #16130f
--text-muted:      #6b6459
--border:          rgba(255,255,255,0.55)
--border-alt:      rgba(20,16,12,0.08)
--accent:          #EC8242
--accent-hover:    #d96e2e
--accent-soft:     #f4a574
--accent-tint:     rgba(236,130,66,0.12)
--accent-ring:     0 0 0 3px rgba(236,130,66,0.28)
--ok:              #3a9d6b
--danger:          #d24b3e
```

### Dark (`.dark`) — derived glass, orange
```
--bg:              #0c0a08        /* warm near-black */
--bg-gradient:     radial-gradient(at 18% 0%,  rgba(236,130,66,0.20) 0%, transparent 55%),
                   radial-gradient(at 82% 22%, rgba(90,120,180,0.18) 0%, transparent 55%),
                   radial-gradient(at 50% 100%,rgba(236,130,66,0.14) 0%, transparent 60%);
--surface:         rgba(255,255,255,0.05)
--surface-strong:  rgba(255,255,255,0.09)
--text:            #f5f2ec
--text-muted:      #9a9082
--border:          rgba(255,255,255,0.08)
--border-alt:      rgba(255,255,255,0.06)
--accent:          #f4914e        /* brightened for dark contrast */
--accent-hover:    #ffa361
--accent-soft:     #b86a38
--accent-tint:     rgba(244,145,78,0.16)
--accent-ring:     0 0 0 3px rgba(244,145,78,0.30)
--ok:              #4fb583
--danger:          #e5675a
```

### Shared (both modes)
```
--radius:          16px           /* cards; buttons/inputs = calc(--radius*0.75)=12px */
--blur:            blur(20px) saturate(160%)     /* mobile/reduced → blur(8px) */
--shadow-soft:     0 8px 32px rgba(20,16,12,0.10)
--shadow-nav:      0 4px 16px rgba(20,16,12,0.08)
--inner-hi:        inset 0 1px 0 rgba(255,255,255,0.6)   /* dark: rgba(255,255,255,0.08) */
--font-display:    'Geist', 'Space Grotesk', sans-serif   /* heavy weights 700/900 */
--font-body:       'Inter', ui-sans-serif, system-ui       /* light weights 200/300/400 */
--font-mono:       'Geist Mono', ui-monospace, monospace
--weight-thin: 200; --weight-light: 300; --weight-bold: 700; --weight-black: 900;
```

Type scale (DESIGN.md): 13 / 15 / 17 / 20 / 26 / 36 / 52 / 72.

## Architecture

Four layers, each with one job, loaded in `main.jac` order:

1. **`theme.css` — token layer.** Fonts (3), `:root` = light-glass palette + shared tokens, `.dark { }` = dark-glass overrides. Delete the 5 `data-jms-theme` blocks, the `.jms-scope[data-jms-theme=…]` overrides, and the terminal palette. Keep `--jms-*` / `--exp-*` as thin aliases of canonical names **only where component classes still reference them** (avoids touching call sites). `body` gets the fixed mesh gradient + noise; content scrolls over it.

2. **`global.css` — Tailwind glue + base + unified glass components.** Keeps `@import "tailwindcss"`, `@theme inline` (rebind `--color-*`/`--radius-*` to new tokens), `@layer base`, scrollbars, `.tok-*` syntax colors, `mono-pulse`. **Adds the motion layer** (keyframes + stagger classes). **Adds the unified glass component vocabulary**: each twin class defined once as a grouped selector — `.exp-btn, .jms-btn { …glass… }`, likewise chip/input/card/panel/label/stat/display. One definition, both names, zero call-site churn.

3. **`jms.css` — JMS-only layout.** Shrinks to the classes with no Experiments twin: hero grid/panel, stage rail/pills, section frames, project cards, source rows, truncation helpers. These adopt glass surfaces (frosted `--surface`, blur, radius, inner-highlight) but keep their unique geometry. Remove the theme/`.jms-scope`-override machinery.

4. **Components (`*.cl.jac`)** — mostly untouched (they reference class names). Targeted edits only: Landing (unify entries + expand), AppShell (light/dark instead of forced `.dark`), ThemeSwitcher (one working light/dark toggle), delete `JmsThemeSwitcher`, mount points get the stagger classes.

### Why grouped selectors over a class rename
Renaming `.jms-btn`→`.g-btn` across 420 sites in 11 files (+ 140 exp sites) is a large, error-prone diff for zero visual benefit — the classes already collapse to identical rules. Grouped selectors (`.exp-btn, .jms-btn { … }`) give guaranteed-identical rendering, one edit point, and leave every component file untouched. Ponytail: shortest working diff. A later cosmetic rename is possible but out of scope.

### Motion layer (CSS-only)
```
.reveal { opacity:0; animation: fadeInUp .7s cubic-bezier(.16,1,.3,1) forwards; }
.stagger-1{animation-delay:.05s} … .stagger-6{animation-delay:.30s}
@keyframes fadeInUp { from{opacity:0;transform:translateY(24px)} to{opacity:1;transform:none} }
@media (prefers-reduced-motion:reduce){ .reveal{animation:none;opacity:1} }
```
Applied on Landing hero children + each surface's top-level mount. No JS, no framer-motion, no per-widget micro-animations (choreography over scatter).

### Glass with fallback (DESIGN.md "don't forget fallbacks")
```
.g-surface { background: var(--surface); backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
             border:1px solid var(--border); border-radius:var(--radius); box-shadow: var(--shadow-soft), var(--inner-hi); }
@supports not (backdrop-filter: blur(1px)) { .g-surface { background: var(--surface-strong); } }
@media (max-width:768px){ :root{ --blur: blur(8px) saturate(150%); } }
```

## Landing expansion

- **Unify entries:** drop `jms-hero-quiet`; both use one display-size class; grid `1fr 1fr`; identical kicker/tick/sub/stat structure. The two entries become pixel-identical glass cards differing only in text.
- **Add (DESIGN.md):** floating pill nav at top (`--surface-strong`, blur, `--shadow-nav`); mesh-gradient body bg; staggered hero reveal; a supporting depth row beneath the two entries (glass feature/stat cards) so the page reads richer, not just two panels.
- All new elements are glass + orange accent + reveal motion.

## Light/dark toggle

- `AppShell.cl.jac:110`: stop forcing `.dark`; read persisted preference (localStorage) or `prefers-color-scheme`, apply `.dark` accordingly.
- Replace the dead `ThemeSwitcher` (7 no-op themes) with a single light/dark switch that toggles `.dark` and persists.
- Delete `JmsThemeSwitcher.cl.jac` and its swatch UI; remove the `data-jms-theme` lock lines. JMS surface inherits the same tokens as Experiments.

## Folder consolidation (final, gated)

1. **Checkpoint** current tree; confirm `jms-projects/` real adapters present.
2. Delete `jms/` (stale cache; optionally archive `jms/.jac/data/*.db` first if old users/anchors wanted — default discard).
3. **Keep `jms-projects/` at repo root, untouched.** (Optionally prune only throwaway QA project dirs — `test`, `diag-test`, `fix-verify`, `final-verify`, `panel-fix-check`, `demo-project`, `train-spheron-fake` — never `train-real-mlx`/`p10-eval-real`. Defer unless asked.)
4. `git mv studio-desktop jms`; update any repo-internal path references (build scripts, docs, `.gitignore`, launch commands) from `studio-desktop/`→`jms/`.
5. **Verify**: `jac check main.jac` passes; app boots; `workspace_root()` still resolves and existing projects load; Playwright pass across Landing + both surfaces.

## Testing / verification

- After each phase: `jac check main.jac` + a full dev-server restart (new CSS/files need restart, not just HMR) + Playwright screenshots of Landing, JMS Projects/Sources/Train, Experiments Chat/Data/Cloud in **both** light and dark.
- Playwright MCP for interactive checks (toggle theme, click entries, hover states).
- Zero console/network errors gate. Test-before-claiming: no "done" without a real screenshot + clean console.
- Visual acceptance: JMS and Experiments render identical component chrome; glass blur visible; orange accent everywhere; staggered reveal on load; light and dark both correct.

## Out of scope

- Renaming class vocabularies (`.jms-*`→`.g-*`) at call sites.
- Pruning `jms-projects/` real data.
- New product features; server (`.sv.jac`) logic changes beyond path updates from the rename.
- Sourcing the licensed PP Neue Montreal font.
