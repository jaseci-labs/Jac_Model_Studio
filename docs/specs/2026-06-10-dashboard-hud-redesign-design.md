# DataGen Dashboard — HUD Redesign

**Date:** 2026-06-10
**Status:** Approved (brainstormed via visual companion, 6 rounds of mockups)
**Target:** `dashboard_app/` restyled in place. Server walkers (`.sv.jac`) untouched.

## Goal

The current glassmorphic monochrome UI is hard to read: 0.72–0.84rem text, low-contrast
grays, status conveyed by dot-shape only. Replace it with a **sci-fi HUD** design
language — mono dark with subtle semantic color accents — chosen by the user from 15
candidate styles, with larger type throughout.

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Style | Sci-fi HUD: corner brackets, scanline texture, telemetry labels |
| Palette | Black & white base, dark mode only |
| Color use | Subtle accents (option A): semantic signals only, not chrome |
| Code/log color | Normal syntax highlighting (One-Dark palette) |
| Monitor layout | L1 — classic stack: stats strip → chart grid → full-width log |
| Train layout | T2 — split console: config left, status + tall log right |
| Ingest layout | I2 — builder rail left, preview + add-form right |
| Typography | Monospace everything |
| Compare mode | Keep, completely redesigned in HUD style |
| Build target | Restyle `dashboard_app/` in place (no new app) |

## 1. Design system (`global.css` rewrite)

- **Canvas:** `#050507` background with a faint scanline overlay
  (`repeating-linear-gradient(0deg, rgba(255,255,255,.015) 0 1px, transparent 1px 3px)`).
- **Font:** `ui-monospace, "SF Mono", Menlo, monospace` for everything — labels, values,
  buttons, inputs, logs.
- **Panels:** square corners (no border-radius), `1px solid #333` borders. Two panel
  treatments:
  - *Bracket tile* (stats): plain border plus white 2px corner brackets at top-left and
    bottom-right (absolutely-positioned pseudo-elements or spans).
  - *Labeled panel* (logs, preview, config): floating label sitting on the top border
    (`LOG.TAIL`, `LAUNCH.CONFIG`), background-matched to punch out the border line.
- **Type scale (bigger than current):** stat values ~1.8rem white; body/controls 13px;
  labels 10–11px uppercase, letter-spaced 2px, `#777`, dot-notation naming
  (`PASS.RATE`, `LOSS.TRN`, `LOG.TAIL`).
- **Semantic accents only** — chrome stays mono:
  - green `#4ade80`: running, pass, nominal, converging
  - red `#f87171`: failed, error, at-ceiling
  - amber `#fbbf24`: caution (e.g. val above best)
- **Status glyphs:** `⦿` running (green, subtle pulse), `✓` done, `✗` fail (red),
  `○` pending/idle (gray).
- **Trend annotations** under stat values: `▲ NOMINAL`, `▼ CONVERGING`, `— HOLDING`
  in the matching accent color, 10px.
- **Controls:** bordered mono buttons (square), active segment = solid top+bottom white
  border or inverse video; primary action = green border + green text (`▶ START SFT`);
  destructive = red border on hover. Inputs: `#0a0a0c` fill, `#333` border, white text,
  white border on focus.
- **Syntax highlighting** for logs and JSONL preview, One-Dark palette: keywords
  `#c678dd`, functions `#61afef`, strings `#98c379`, types `#e5c07b`, punctuation
  `#abb2bf`, dim metadata `#555`. Pass/fail marks `✓`/`✗` in green/red. Implemented as a
  small client-side tokenizer over log/JSONL text (regex-based, no library).

## 2. Monitor page (layout L1 — classic stack)

Top to bottom:

1. **Controls row:** run selector, SFT/DPO segmented control, Refresh, Auto toggle
   (with `⦿`/`○` glyph), Compare toggle; right-aligned `ITER 480` readout.
2. **Stat tiles** (bracket tiles): `PASS.RATE`, `LOSS.TRN`, `LOSS.VAL`, `TOK/S`, plus
   idiom tiles (`IDIOM.SIM`, `IDIOMATIC`, `PY.SHAPED`, `RUNS/TOTAL`) when
   `metrics.has_idiom`. Each shows value + trend annotation where derivable from the
   metric series (compare last two points).
3. **Chart grid** (2-col, auto-fit): train loss, val loss, holdout pass curve, learning
   rate, tokens/sec, idiom similarity (conditional) — HUD-styled `MetricChart`.
4. **`LOG.TAIL` labeled panel,** full width: syntax-colored train.log tail.

**Compare mode (rebuilt):** toggling Compare replaces sections 2–4 with per-run headline
bracket tiles (run name colored from fixed palette `["#60a5fa","#f472b6","#34d399","#a78bfa","#22d3ee"]`)
and three `MultiLineChart`s (train loss, val loss, pass curve), HUD-styled with a legend
strip of colored `■ name` markers.

Empty state: `NO SIGNAL — select a run` centered, `#555`.

## 3. Train page (layout T2 — split console)

Two columns (config ~1fr, status ~1.6fr; stacks on narrow viewport):

- **Left — `LAUNCH.CONFIG` labeled panel:** base model input, short name input, SFT/DPO
  segment, then per-mode knobs (SFT: `EVAL_EVERY`, `SUBSET`, `DRY_ITERS`, skip-dry
  checkbox; DPO: `DPO_ITERS`, `DPO_LR`, `DPO_BETA`, `SUBSET`), heavy-run warning as one
  amber-accent line, and full-width `▶ START SFT|DPO` green-bordered button (disabled
  while running).
- **Right — `RUN.STATUS` labeled panel:** header strip with status glyph + word, pid,
  iter, started time, elapsed, and `■ STOP` (red-bordered, enabled only while running);
  below, tall (~60vh) syntax-colored run log, autoscrolled to bottom.

Polling behavior unchanged (2.5s self-rearming tick).

## 4. Ingest page (layout I2 — builder rail + work area)

- **Top:** dataset stat bracket tiles (SFT total, DPO pairs, MLX SFT, MLX DPO, holdout).
- **Left rail — `BUILDERS` labeled panel:** the 12 stages as a vertical list in pipeline
  order, each row: status glyph + label (+ `(slow)` note for scale). Click runs the
  stage; running stage shows `⦿`. Stage log tail in a dashed sub-panel under the list.
  Stage status derives from current-session runs (`builder_status`), `○` otherwise.
- **Right work area:** `PREVIEW` labeled panel (file selector with counts, `‹ ›` paging,
  row counter, syntax-colored JSONL rows) above `ADD.EXAMPLES` labeled panel (target
  selector, mono textarea, `APPEND` primary button, result message inline —
  green/red-accented).

## 5. Charts (`MetricChart`, `MultiLineChart`)

- Transparent background; gridlines `#222`; mono 10px tick labels `#666`.
- Square-cornered tooltip: `#0a0a0c` bg, `#333` border, mono text.
- `MetricChart`: white stroke by default; accepts semantic stroke override. Last point
  gets a small green circle marker while the run is live (prop-driven).
- `MultiLineChart`: strokes from the fixed compare palette; HUD legend strip.
- Chart titles become panel labels in dot-notation. Exact titles: `LOSS.TRAIN`,
  `LOSS.VAL`, `CURVE.PASS`, `LR`, `TOK.S`, `IDIOM.SIM`.

## 6. Out of scope

- No new server endpoints, no `.sv.jac` changes, no pipeline changes.
- No GPU memory tile (not present in train.log artifacts).
- No light mode, no theme switcher.
- testdashboardapp/ stays as the mockup archive only; it is not the build target.

## 7. Verification

- `jac build --client web` passes (production client bundle).
- Manual: `jac start --dev main.jac` from `dashboard_app/`, walk all three screens with
  existing `results/` artifacts; check Monitor compare toggle, Train start/stop controls
  render (no live run needed), Ingest preview paging and add-examples message styling.
- Hot-reload only touches `.cl.jac` + css, so no server restart needed during styling.

## Addendum A (2026-06-10, mid-implementation)

A parallel session restructured the app before Tasks 4+ ran (commits `5aa3daf`, `8c2778f`):
Monitor is now live-runs-only; new **History** page holds past runs + the compare overlay;
new **Dataset** page browses the corpus with server-side syntax highlighting (`tok-*` spans);
shared **RunCharts** renders stat cards + chart grid + log tail; nav has 5 tabs.

User decision: **extend the HUD redesign to all 5 pages.** Consequences:
- Compare mode lives on History (not Monitor); Monitor keeps layout L1 minus compare.
- RunCharts becomes the HUD home of stat tiles/charts/log for Monitor + History.
- Dataset keeps server-side highlighting; global.css gains HUD-styled `dg-table/thead/tr/td`,
  `dg-kind`, `dg-detail*`, `dg-code*` and the One-Dark `tok-*` palette (square corners, #333 borders).
- The plan's Task 5 is replaced; History and Dataset get new tasks (see plan Revision A).
