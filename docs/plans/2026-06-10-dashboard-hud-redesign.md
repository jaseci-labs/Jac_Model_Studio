# Dashboard HUD Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle `dashboard_app/` in place from glassmorphic monochrome to a sci-fi HUD design (mono dark, subtle semantic accents, monospace type, syntax-colored logs) per `docs/superpowers/specs/2026-06-10-dashboard-hud-redesign-design.md`.

**Architecture:** Pure client-side restyle: rewrite `global.css` (new design system), add one shared HUD-primitives component, restyle the two chart wrappers, then rebuild the three page components on the locked layouts (Monitor=L1 stack, Train=T2 split console, Ingest=I2 rail+work area). Server walkers (`.sv.jac`) and `main.jac` are untouched.

**Tech Stack:** Jac (jac-client JSX components, `.cl.jac`), Recharts, plain CSS. No new dependencies.

**Testing note:** This project has no JS test framework; the verification loop for every task is `jac check <file>` (type-check/lint) plus `jac build --client web` at the end, and visual checks via `jac start --dev main.jac` (`.cl.jac` and CSS hot-reload; no server restart needed since no `.sv.jac` changes). If `jac check` errors, follow its `-> run 'jac guide ...'` hints (see `dashboard_app/AGENTS.md`).

**Working directory for all commands:** `/Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app`

**Service objects referenced by the pages (already exist, do not modify):**
- `RunSummary {name, has_sft, has_dpo, stages, running}`, `RunMetrics {name, mode, found, running, last_iter, train, val, lr, tps, curve, idiom_sim, has_idiom, idiom_label, idiom_avg_sim, idiom_idiomatic, idiom_python, idiom_runs, idiom_total, log_tail}`, `CompareResult {names, train, val, curve, headline}` (`services/runs.sv.jac`)
- `JobStatus {name, mode, status, pid, started, last_iter, log_tail, message}` (`services/jobs.sv.jac`)
- `DatasetStats {sft_files, sft_total, dpo_pairs, splits}`, `FileRef {path, label, count}` (`services/dataset.sv.jac`)

---

### Task 1: Design system — rewrite `global.css`

**Files:**
- Modify: `dashboard_app/global.css` (full replace)

- [ ] **Step 1: Replace the entire contents of `global.css` with:**

```css
/* DataGen dashboard — sci-fi HUD design system.
   Mono dark; color is semantic only (green=good, red=fail, amber=caution).
   Spec: docs/superpowers/specs/2026-06-10-dashboard-hud-redesign-design.md */

:global(*) { box-sizing: border-box; }
:global(html), :global(body) { margin: 0; padding: 0; }
:global(body) {
  background: #050507;
  color: #d8d8d8;
  font-family: ui-monospace, "SF Mono", Menlo, monospace;
  font-size: 13px;
  -webkit-font-smoothing: antialiased;
}
:global(::selection) { background: rgba(255, 255, 255, 0.18); }

/* thin monochrome scrollbars */
:global(::-webkit-scrollbar) { width: 10px; height: 10px; }
:global(::-webkit-scrollbar-thumb) { background: rgba(255, 255, 255, 0.12); }
:global(::-webkit-scrollbar-thumb:hover) { background: rgba(255, 255, 255, 0.2); }
:global(::-webkit-scrollbar-track) { background: transparent; }

/* app canvas: pure dark + faint scanlines */
.dg-app {
  min-height: 100vh;
  background:
    repeating-linear-gradient(0deg, rgba(255, 255, 255, 0.015) 0 1px, transparent 1px 3px),
    #050507;
}

/* ---- semantic accents ---- */
.dg-acc-green { color: #4ade80; }
.dg-acc-red   { color: #f87171; }
.dg-acc-amber { color: #fbbf24; }

/* ---- nav ---- */
.dg-nav {
  position: sticky; top: 0; z-index: 50;
  display: flex; align-items: center; gap: 0.6rem;
  padding: 0.8rem 1.4rem;
  background: rgba(5, 5, 7, 0.92);
  border-bottom: 1px solid #2a2a2e;
}
.dg-brand {
  font-size: 0.8rem; font-weight: 700; letter-spacing: 0.32em;
  color: #fff; margin-right: 1.2rem;
}
.dg-navlink {
  text-decoration: none; color: #555;
  font-size: 0.8rem; letter-spacing: 0.18em; text-transform: uppercase;
  padding: 0.3rem 0.85rem;
  border-top: 1px solid transparent; border-bottom: 1px solid transparent;
  transition: color .15s, border-color .15s;
}
.dg-navlink:hover { color: #ccc; }
.dg-navlink.dg-active { color: #fff; border-top-color: #fff; border-bottom-color: #fff; }
.dg-spacer { flex: 1; }

/* ---- page + layout helpers ---- */
.dg-page { padding: 1.5rem 1.6rem; max-width: 1180px; margin: 0 auto; }
.dg-row { display: flex; gap: 0.7rem; align-items: center; flex-wrap: wrap; }
.dg-row-end { display: flex; gap: 0.7rem; align-items: flex-end; flex-wrap: wrap; }
.dg-stack { display: flex; flex-direction: column; gap: 0.5rem; }
.dg-mb { margin-bottom: 1.1rem; }
.dg-mb-lg { margin-bottom: 1.6rem; }

/* ---- bracket stat tile ---- */
.dg-stats { display: flex; gap: 0.8rem; flex-wrap: wrap; }
.dg-tile {
  position: relative; min-width: 150px; padding: 0.85rem 1rem;
  border: 1px solid #333; background: rgba(255, 255, 255, 0.012);
}
.dg-br { position: absolute; width: 10px; height: 10px; }
.dg-br-tl { top: -1px; left: -1px; border-top: 2px solid #fff; border-left: 2px solid #fff; }
.dg-br-br { bottom: -1px; right: -1px; border-bottom: 2px solid #fff; border-right: 2px solid #fff; }
.dg-tile-label {
  color: #777; font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.18em;
  margin-bottom: 0.4rem;
}
.dg-tile-value { color: #fff; font-size: 1.8rem; line-height: 1; }
.dg-tile-sub { font-size: 0.7rem; letter-spacing: 0.08em; margin-top: 0.4rem; color: #666; }

/* ---- labeled panel (LOG.TAIL / LAUNCH.CONFIG / ...) ---- */
.dg-panel {
  position: relative; border: 1px solid #333; padding: 1rem;
  background: rgba(255, 255, 255, 0.008);
  margin-top: 0.6rem; /* room for the floating label */
}
.dg-panel-label {
  position: absolute; top: -0.55em; left: 10px;
  background: #050507; padding: 0 7px;
  color: #777; font-size: 0.7rem; letter-spacing: 0.22em; text-transform: uppercase;
}

/* ---- titles / text ---- */
.dg-h1 { font-size: 1.2rem; letter-spacing: 0.1em; margin: 0 0 0.2rem; color: #fff; }
.dg-title { color: #aaa; font-size: 0.8rem; letter-spacing: 0.16em; text-transform: uppercase; margin-bottom: 0.55rem; }
.dg-muted { color: #9a9aa5; font-size: 0.84rem; }
.dg-faint { color: #666; font-size: 0.78rem; }
.dg-mono { font-family: inherit; }

/* ---- buttons ---- */
.dg-btn {
  display: inline-flex; align-items: center; gap: 0.45rem;
  padding: 0.42rem 0.95rem; cursor: pointer;
  font-size: 0.78rem; font-family: inherit; letter-spacing: 0.08em;
  background: transparent; color: #bbb;
  border: 1px solid #444;
  transition: color .15s, border-color .15s, background .15s;
}
.dg-btn:hover { color: #fff; border-color: #888; background: rgba(255, 255, 255, 0.04); }
.dg-btn:active { transform: translateY(1px); }
.dg-btn:disabled { opacity: 0.35; cursor: not-allowed; }
.dg-btn-primary { color: #4ade80; border: 2px solid #4ade80; font-weight: 700; }
.dg-btn-primary:hover { background: rgba(74, 222, 128, 0.08); color: #4ade80; border-color: #4ade80; }
.dg-btn-danger { color: #999; }
.dg-btn-danger:hover:not(:disabled) { color: #f87171; border-color: #f87171; background: rgba(248, 113, 113, 0.06); }

/* segmented control */
.dg-seg { display: inline-flex; gap: 0; border: 1px solid #444; }
.dg-seg-btn {
  padding: 0.34rem 0.95rem; cursor: pointer; border: none;
  background: transparent; color: #666; font-size: 0.78rem; font-family: inherit;
  letter-spacing: 0.1em; text-transform: uppercase;
  transition: background .15s, color .15s;
}
.dg-seg-btn:hover { color: #ccc; }
.dg-seg-btn.dg-active { background: #fff; color: #000; font-weight: 700; }

/* ---- inputs ---- */
.dg-field { display: flex; flex-direction: column; gap: 0.3rem; }
.dg-label { color: #777; font-size: 0.7rem; letter-spacing: 0.16em; text-transform: uppercase; }
.dg-input, .dg-select, .dg-textarea {
  padding: 0.5rem 0.7rem;
  background: #0a0a0c; color: #eee;
  border: 1px solid #333;
  font-size: 0.8rem; font-family: inherit; outline: none;
  transition: border-color .15s;
}
.dg-input:focus, .dg-select:focus, .dg-textarea:focus { border-color: #999; }
.dg-input::placeholder, .dg-textarea::placeholder { color: #4a4a52; }
.dg-select { min-width: 150px; }
.dg-select option { background: #0a0a0c; color: #eee; }
.dg-textarea { width: 100%; min-height: 120px; resize: vertical; font-size: 0.76rem; }

/* ---- status glyphs ---- */
.dg-status { font-size: 0.78rem; letter-spacing: 0.14em; }
.dg-glyph-run  { color: #4ade80; animation: dg-pulse 1.4s infinite; }
.dg-glyph-done { color: #d8d8d8; }
.dg-glyph-fail { color: #f87171; }
.dg-glyph-idle { color: #666; }
@keyframes dg-pulse { 0% { opacity: 1; } 50% { opacity: 0.45; } 100% { opacity: 1; } }

/* ---- banner (warnings) ---- */
.dg-banner {
  border: 1px solid #333; border-left: 3px solid #fbbf24;
  padding: 0.6rem 0.9rem; font-size: 0.76rem; line-height: 1.55; color: #999;
}
.dg-banner strong { color: #fbbf24; font-weight: 700; }

/* ---- log / pre ---- */
.dg-log {
  background: rgba(0, 0, 0, 0.45); border: 1px solid #2a2a2e;
  padding: 0.7rem 0.9rem; margin: 0;
  font-size: 0.74rem; line-height: 1.6; color: #b7b7c0;
  font-family: inherit;
  overflow: auto; white-space: pre-wrap; word-break: break-word;
}
.dg-json { max-height: 118px; }

/* ---- builder rail (Ingest) ---- */
.dg-stage {
  display: flex; align-items: center; gap: 0.55rem; width: 100%;
  padding: 0.4rem 0.55rem; cursor: pointer; text-align: left;
  background: transparent; border: 1px solid transparent;
  color: #aaa; font-size: 0.78rem; font-family: inherit; letter-spacing: 0.06em;
  transition: border-color .15s, color .15s;
}
.dg-stage:hover { border-color: #444; color: #fff; }
.dg-stage.dg-active { border-color: #fff; color: #fff; }

/* ---- page grids ---- */
.dg-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 1rem; }
.dg-train-grid { display: grid; grid-template-columns: 1fr 1.6fr; gap: 1rem; align-items: start; }
.dg-ingest-grid { display: grid; grid-template-columns: 1fr 2fr; gap: 1rem; align-items: start; }
@media (max-width: 900px) {
  .dg-train-grid, .dg-ingest-grid { grid-template-columns: 1fr; }
}

/* ---- charts ---- */
.dg-chart { padding: 0.9rem 0.95rem 0.6rem; }
.dg-chart-empty { color: #555; font-size: 0.78rem; letter-spacing: 0.2em; text-align: center; padding: 2.6rem 0; }
```

- [ ] **Step 2: Verify the app still builds against the new CSS (class renames break nothing structurally — pages still reference old classes until later tasks; old class names that vanished simply render unstyled, which is fine mid-migration):**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check main.jac`
Expected: no errors (CSS is not type-checked; this confirms nothing else broke).

- [ ] **Step 3: Commit**

```bash
git add dashboard_app/global.css
git commit -m "style(dashboard): HUD design system in global.css"
```

---

### Task 2: Shared HUD primitives — `components/hud/Hud.cl.jac`

**Files:**
- Create: `dashboard_app/components/hud/Hud.cl.jac`

Provides `BracketTile` (stat tile with corner brackets), `StatusGlyph` (replaces the old `StatusBadge`), `LogView` (syntax-colored log pre), `JsonRow` (colored JSONL preview row).

- [ ] **Step 1: Create `dashboard_app/components/hud/Hud.cl.jac` with:**

```jac
"""Shared HUD primitives: bracket stat tiles, status glyphs, syntax-colored logs.

Color is semantic only (green good / red fail / amber caution); One-Dark palette
for code tokens in logs. Pure presentation — no server imports.
"""

glob KEYWORDS: list[str] = [
    "def", "walker", "can", "obj", "node", "edge", "return", "import", "from",
    "has", "with", "entry", "visit", "spawn", "report", "glob", "let",
    "if", "else", "for", "while", "in", "not", "and", "or", "class", "lambda"
];

def word_color(w: str) -> str {
    s: str = w.strip("():;,{}[]<>");
    if s in KEYWORDS { return "#c678dd"; }
    if w.startswith("\"") or w.startswith("'") or w.startswith("`") { return "#98c379"; }
    if "✓" in w or s == "PASS" or s == "saved" { return "#4ade80"; }
    if "✗" in w or "FAIL" in s or "rror" in w or "Traceback" in w { return "#f87171"; }
    t: str = s.replace(".", "").replace("-", "").replace("e", "").replace("%", "").replace("/", "");
    if t != "" and t.isdigit() { return "#61afef"; }
    return "";
}

def word_style(w: str) -> dict {
    c: str = word_color(w);
    if c == "" { return {}; }
    return {"color": c};
}

def:pub BracketTile(label: str, value: str, sub: str, subcls: str) -> JsxElement {
    return <div className="dg-tile">
        <span className="dg-br dg-br-tl"></span>
        <span className="dg-br dg-br-br"></span>
        <div className="dg-tile-label">{label}</div>
        <div className="dg-tile-value">{value}</div>
        {sub != "" and <div className={"dg-tile-sub " + subcls}>{sub}</div>}
    </div>;
}

def:pub StatusGlyph(status: str) -> JsxElement {
    g: str = "○";
    c: str = "dg-glyph-idle";
    if status == "running" { g = "⦿"; c = "dg-glyph-run"; }
    if status == "done" or status == "finished" { g = "✓"; c = "dg-glyph-done"; }
    if status == "failed" { g = "✗"; c = "dg-glyph-fail"; }
    return <span className={"dg-status " + c}>{g + " " + status.upper()}</span>;
}

def:pub LogView(text: str, maxh: str) -> JsxElement {
    lines: list[str] = text.split("\n");
    return <pre className="dg-log" style={{"maxHeight": maxh}}>
        {for (i, ln) in enumerate(lines) {
            <div key={str(i)}>
                {for (j, w) in enumerate(ln.split(" ")) {
                    <span key={str(j)} style={word_style(w)}>{w + " "}</span>
                }}
            </div>
        }}
    </pre>;
}

def seg_style(i: int) -> dict {
    if i % 2 == 1 { return {"color": "#98c379"}; }
    return {"color": "#8b8b96"};
}

def seg_text(i: int, p: str) -> str {
    if i % 2 == 1 { return "\"" + p + "\""; }
    return p;
}

def:pub JsonRow(text: str) -> JsxElement {
    parts: list[str] = text.split("\"");
    return <pre className="dg-log dg-json">
        {for (i, p) in enumerate(parts) {
            <span key={str(i)} style={seg_style(i)}>{seg_text(i, p)}</span>
        }}
    </pre>;
}
```

- [ ] **Step 2: Type-check**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check components/hud/Hud.cl.jac`
Expected: no errors. If JSX slot syntax errors appear, run `jac guide --search jsx` and adjust loop/conditional slot forms to match the guide (the patterns above mirror `MonitorPage.cl.jac`'s existing `{for ...}` / `{cond and ...}` usage).

- [ ] **Step 3: Commit**

```bash
git add dashboard_app/components/hud/Hud.cl.jac
git commit -m "feat(dashboard): shared HUD primitives (tiles, glyphs, colored logs)"
```

---

### Task 3: Nav — restyle `AppShell.cl.jac`

**Files:**
- Modify: `dashboard_app/components/AppShell.cl.jac`

- [ ] **Step 1: Replace the `NavBar` function body (keep `NavLink` and `AppShell` as-is) with:**

```jac
def:pub NavBar() -> JsxElement {
    path: str = str(useLocation()["pathname"]);
    return <nav className="dg-nav">
        <span className="dg-brand">⟨ DATAGEN ⟩</span>
        <NavLink dest="/monitor" label="Monitor" path={path} />
        <NavLink dest="/train" label="Train" path={path} />
        <NavLink dest="/ingest" label="Ingest" path={path} />
        <span className="dg-spacer"></span>
        <span className="dg-faint">LOCAL · MLX</span>
    </nav>;
}
```

Also update the module docstring (line 1) to `"""Top-level shell: HUD nav bar + client routes (Monitor / Train / Ingest)."""`.

- [ ] **Step 2: Type-check**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check components/AppShell.cl.jac`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add dashboard_app/components/AppShell.cl.jac
git commit -m "style(dashboard): HUD nav bar"
```

---

### Task 4: Charts — restyle `MetricChart` and `MultiLineChart`

**Files:**
- Modify: `dashboard_app/components/charts/MetricChart.cl.jac` (full replace)
- Modify: `dashboard_app/components/charts/MultiLineChart.cl.jac` (full replace)

`MetricChart` gains a `live: bool` param (green dot on last point while run is live). All callers are updated in Tasks 5–7; this task temporarily breaks callers' arity, which is why Tasks 4 and 5 should be committed before restarting any visual check — `jac check` per file still passes.

- [ ] **Step 1: Replace `MetricChart.cl.jac` with:**

```jac
"""A single labelled Recharts line chart over a [{x, y}, ...] series.
HUD panel; white stroke default, green ReferenceDot marks the live tip."""

import from "recharts" { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ReferenceDot }

def:pub MetricChart(title: str, data: list[dict], color: str, live: bool) -> JsxElement {
    n: int = len(data);
    return <div className="dg-panel dg-chart">
        <span className="dg-panel-label">{title}</span>
        {n == 0 and <div className="dg-chart-empty">NO SIGNAL</div>}
        {n > 0 and <ResponsiveContainer width="100%" height={180}>
            <LineChart data={data} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                <Tooltip
                    contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": "0px", "fontFamily": "ui-monospace, Menlo, monospace", "fontSize": "11px"}}
                    labelStyle={{"color": "#777"}}
                    itemStyle={{"color": "#fafafa"}}
                />
                <Line type="monotone" dataKey="y" stroke={color} strokeWidth={1.4} dot={False} isAnimationActive={False} />
                {live and <ReferenceDot x={data[n - 1]["x"]} y={data[n - 1]["y"]} r={3} fill="none" stroke="#4ade80" strokeWidth={1.5} />}
            </LineChart>
        </ResponsiveContainer>}
    </div>;
}
```

- [ ] **Step 2: Replace `MultiLineChart.cl.jac` with:**

```jac
"""Overlay line chart: one line per run, merged on x. Used by Monitor's compare view.
HUD panel; each run keeps a distinct color from the compare palette."""

import from "recharts" { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, Legend }

def:pub MultiLineChart(title: str, data: list[dict], names: list[str], colors: list[str]) -> JsxElement {
    return <div className="dg-panel dg-chart">
        <span className="dg-panel-label">{title}</span>
        {len(data) == 0 and <div className="dg-chart-empty">NO SIGNAL</div>}
        {len(data) > 0 and <ResponsiveContainer width="100%" height={210}>
            <LineChart data={data} margin={{"top": 10, "right": 14, "left": 0, "bottom": 0}}>
                <CartesianGrid stroke="#1c1c1f" vertical={False} />
                <XAxis dataKey="x" tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={{"stroke": "#333"}} />
                <YAxis tick={{"fill": "#666", "fontSize": 10, "fontFamily": "ui-monospace, Menlo, monospace"}} tickLine={False} axisLine={False} width={46} domain={["auto", "auto"]} />
                <Tooltip
                    contentStyle={{"background": "#0a0a0c", "border": "1px solid #333", "borderRadius": "0px", "fontFamily": "ui-monospace, Menlo, monospace", "fontSize": "11px"}}
                    labelStyle={{"color": "#777"}}
                    itemStyle={{"color": "#fafafa"}}
                />
                <Legend wrapperStyle={{"fontSize": "0.72rem", "color": "#9a9aa5", "fontFamily": "ui-monospace, Menlo, monospace"}} />
                {for (i, nm) in enumerate(names) {
                    <Line key={nm} type="monotone" dataKey={nm} stroke={colors[i % len(colors)]} strokeWidth={1.4} dot={False} isAnimationActive={False} connectNulls={True} />
                }}
            </LineChart>
        </ResponsiveContainer>}
    </div>;
}
```

- [ ] **Step 3: Type-check both**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check components/charts/MetricChart.cl.jac && jac check components/charts/MultiLineChart.cl.jac`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add dashboard_app/components/charts/
git commit -m "style(dashboard): HUD chart panels, live tip marker"
```

---

### Task 5: Monitor page — L1 stack + rebuilt compare

**Files:**
- Modify: `dashboard_app/components/MonitorPage.cl.jac` (full replace)

- [ ] **Step 1: Replace `MonitorPage.cl.jac` with:**

```jac
"""Monitor: live HUD for a selected training run (SFT or DPO).

Layout L1: controls row -> bracket stat tiles -> chart grid -> LOG.TAIL panel.
Polls get_run_metrics on a 2.5s self-rearming timer while auto-refresh is on.
"""

sv import from ..services.runs { RunSummary, RunMetrics, CompareResult, list_runs, get_run_metrics, compare_runs }
import from .charts.MetricChart { MetricChart }
import from .charts.MultiLineChart { MultiLineChart }
import from .hud.Hud { BracketTile, LogView }

glob CMP_COLORS: list[str] = ["#60a5fa", "#f472b6", "#34d399", "#a78bfa", "#22d3ee"];

def last_y(series: list[dict]) -> str {
    if len(series) == 0 { return "—"; }
    return str(series[len(series) - 1]["y"]);
}

def loss_trend(series: list[dict]) -> list[str] {
    # [label, accent-class] from the last two points of a loss series.
    if len(series) < 2 { return ["", ""]; }
    a: float = float(str(series[len(series) - 2]["y"]));
    b: float = float(str(series[len(series) - 1]["y"]));
    if b < a { return ["▼ CONVERGING", "dg-acc-green"]; }
    if b > a { return ["▲ RISING", "dg-acc-amber"]; }
    return ["— HOLDING", ""];
}

def pass_trend(series: list[dict]) -> list[str] {
    if len(series) < 2 { return ["", ""]; }
    a: float = float(str(series[len(series) - 2]["y"]));
    b: float = float(str(series[len(series) - 1]["y"]));
    if b >= a { return ["▲ NOMINAL", "dg-acc-green"]; }
    return ["▼ REGRESSING", "dg-acc-amber"];
}

def:pub MonitorPage() -> JsxElement {
    has runs: list[RunSummary] = [],
        metrics: RunMetrics | None = None,
        cmp: CompareResult | None = None,
        compare: bool = False,
        name: str = "",
        mode: str = "sft",
        auto: bool = True,
        tick: int = 0;

    async can with entry {
        # use a LOCAL for the fetched list: assigning `runs` (state) doesn't update
        # it synchronously, so reading `runs` here would see the stale [] and skip.
        found: list[RunSummary] = await list_runs();
        runs = found;
        if len(found) > 0 and name == "" {
            name = found[0].name;
            metrics = await get_run_metrics(found[0].name, mode);
        }
    }

    async can with [name, mode, tick] entry {
        if name != "" {
            metrics = await get_run_metrics(name, mode);
            if auto {
                schedule_next();
            }
        }
    }

    async can with [compare, mode, tick] entry {
        if compare {
            cmp = await compare_runs(mode);
        }
    }

    def schedule_next -> None {
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    def pick_mode(m: str) -> None {
        mode = m;
    }

    def on_select(e: ChangeEvent) {
        name = e.target.value;
    }

    def toggle_auto(e: MouseEvent) {
        auto = not auto;
        if auto {
            tick = tick + 1;
        }
    }

    def refresh(e: MouseEvent) {
        tick = tick + 1;
    }

    def toggle_compare(e: MouseEvent) {
        compare = not compare;
        tick = tick + 1;
    }

    # non-optional locals so compare JSX (incl. nested for-slots) needn't narrow
    # the optional `cmp` — the checker won't track that into slot scope.
    chead: list[dict] = cmp.headline if cmp is not None else [];
    cnames: list[str] = cmp.names if cmp is not None else [];
    ctrain: list[dict] = cmp.train if cmp is not None else [];
    cval: list[dict] = cmp.val if cmp is not None else [];
    ccurve: list[dict] = cmp.curve if cmp is not None else [];

    is_live: bool = metrics is not None and metrics.running and auto;
    trn_t: list[str] = loss_trend(metrics.train) if metrics is not None else ["", ""];
    val_t: list[str] = loss_trend(metrics.val) if metrics is not None else ["", ""];
    pas_t: list[str] = pass_trend(metrics.curve) if metrics is not None else ["", ""];

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <select value={name} onChange={on_select} className="dg-select">
                {if len(runs) == 0 {
                    <option key="none" value="">no runs found</option>
                }}
                {for r in runs {
                    <option key={r.name} value={r.name}>{r.name}</option>
                }}
            </select>
            <div className="dg-seg">
                <button onClick={lambda (e: MouseEvent) { pick_mode("sft"); }} className={"dg-seg-btn dg-active" if mode == "sft" else "dg-seg-btn"}>SFT</button>
                <button onClick={lambda (e: MouseEvent) { pick_mode("dpo"); }} className={"dg-seg-btn dg-active" if mode == "dpo" else "dg-seg-btn"}>DPO</button>
            </div>
            <button onClick={refresh} className="dg-btn">REFRESH</button>
            <button onClick={toggle_auto} className="dg-btn">
                <span className={"dg-acc-green" if auto else "dg-faint"}>{"⦿" if auto else "○"}</span>
                {"AUTO ON" if auto else "AUTO OFF"}
            </button>
            <button onClick={toggle_compare} className={"dg-btn dg-btn-primary" if compare else "dg-btn"}>
                {"COMPARING ALL RUNS" if compare else "COMPARE"}
            </button>
            <span className="dg-spacer"></span>
            {not compare and metrics and <span className="dg-faint">{"ITER " + str(metrics.last_iter)}</span>}
        </div>

        {compare and len(chead) > 0 and <div className="dg-stats dg-mb">
            {for (i, h) in enumerate(chead) {
                <div key={str(h["name"])} className="dg-tile">
                    <span className="dg-br dg-br-tl"></span>
                    <span className="dg-br dg-br-br"></span>
                    <div className="dg-tile-label" style={{"color": CMP_COLORS[i % len(CMP_COLORS)]}}>{"■ " + str(h["name"]) + " · " + mode}</div>
                    <div className="dg-tile-value">{str(h["final_pass"]) + "%"}</div>
                    <div className="dg-tile-sub">{"idiom " + str(h["idiom_sim"]) + " · loss " + str(h["last_loss"])}</div>
                </div>
            }}
        </div>}

        {compare and len(chead) > 0 and <div className="dg-grid">
            <MultiLineChart title="LOSS.TRAIN" data={ctrain} names={cnames} colors={CMP_COLORS} />
            <MultiLineChart title="LOSS.VAL" data={cval} names={cnames} colors={CMP_COLORS} />
            <MultiLineChart title="CURVE.PASS" data={ccurve} names={cnames} colors={CMP_COLORS} />
        </div>}

        {not compare and metrics is None and <div className="dg-chart-empty" style={{"padding": "4rem 0"}}>NO SIGNAL — SELECT A RUN</div>}

        {not compare and metrics and <div className="dg-stats dg-mb">
            <BracketTile label="PASS.RATE" value={last_y(metrics.curve) + "%"} sub={pas_t[0]} subcls={pas_t[1]} />
            <BracketTile label="LOSS.TRN" value={last_y(metrics.train)} sub={trn_t[0]} subcls={trn_t[1]} />
            <BracketTile label="LOSS.VAL" value={last_y(metrics.val)} sub={val_t[0]} subcls={val_t[1]} />
            <BracketTile label="TOK.S" value={last_y(metrics.tps)} sub={"ITER " + str(metrics.last_iter)} subcls="" />
        </div>}

        {not compare and metrics and metrics.has_idiom and <div className="dg-stats dg-mb">
            <BracketTile label="IDIOM.SIM" value={str(metrics.idiom_avg_sim)} sub={metrics.idiom_label} subcls="" />
            <BracketTile label="IDIOMATIC" value={str(metrics.idiom_idiomatic)} sub="DIVERGED FROM TRANSPILE" subcls="" />
            <BracketTile label="PY.SHAPED" value={str(metrics.idiom_python)} sub="REPRODUCED TRANSPILE" subcls="" />
            <BracketTile label="RUNS.TOTAL" value={str(metrics.idiom_runs) + "/" + str(metrics.idiom_total)} sub="BEHAVIORAL PASS" subcls="" />
        </div>}

        {not compare and metrics and <div className="dg-grid">
            <MetricChart title="LOSS.TRAIN" data={metrics.train} color="#fff" live={is_live} />
            <MetricChart title="LOSS.VAL" data={metrics.val} color="#fff" live={is_live} />
            <MetricChart title="CURVE.PASS" data={metrics.curve} color="#fff" live={is_live} />
            <MetricChart title="LR" data={metrics.lr} color="#fff" live={False} />
            <MetricChart title="TOK.S" data={metrics.tps} color="#fff" live={False} />
            {len(metrics.idiom_sim) > 0 and <MetricChart title="IDIOM.SIM" data={metrics.idiom_sim} color="#fff" live={False} />}
        </div>}

        {not compare and metrics and <div className="dg-panel dg-mb-lg" style={{"marginTop": "1.4rem"}}>
            <span className="dg-panel-label">LOG.TAIL</span>
            <LogView text={metrics.log_tail if metrics.log_tail != "" else "(no log yet)"} maxh="220px" />
        </div>}
    </div>;
}
```

Note: `StatCard` is removed from this file — `IngestPage` imports it today; Task 7 switches that import to `BracketTile`. Do Tasks 5–7 in order, then check the whole app.

- [ ] **Step 2: Type-check**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check components/MonitorPage.cl.jac`
Expected: no errors (IngestPage's stale `StatCard` import errors only when checking IngestPage; fixed in Task 7).

- [ ] **Step 3: Commit**

```bash
git add dashboard_app/components/MonitorPage.cl.jac
git commit -m "feat(dashboard): HUD Monitor page (L1 stack, trend tiles, colored log)"
```

---

### Task 6: Train page — T2 split console

**Files:**
- Modify: `dashboard_app/components/TrainPage.cl.jac` (full replace)

- [ ] **Step 1: Replace `TrainPage.cl.jac` with:**

```jac
"""Train: split console — LAUNCH.CONFIG left, RUN.STATUS + tall log right.

Shells out (server-side) to run_probe.sh / run_dpo.sh via services/jobs.sv.jac.
The trainer's loss curves live on the Monitor screen; this screen shows run
status + the run-<mode>.log (quantize/fuse/eval stage progress).
"""

sv import from ..services.jobs { JobStatus, start_training, stop_training, job_status }
import from .hud.Hud { StatusGlyph, LogView }

def:pub Field(label: str, value: str, hint: str, onChange: Callable[([str], None)]) -> JsxElement {
    def handle(e: ChangeEvent) {
        onChange(e.target.value);
    }
    return <label className="dg-field">
        <span className="dg-label">{label}</span>
        <input value={value} onChange={handle} placeholder={hint} className="dg-input" />
    </label>;
}

def:pub TrainPage() -> JsxElement {
    has model_id: str = "Qwen/Qwen3-Coder-30B-A3B-Instruct",
        name: str = "qwen",
        mode: str = "sft",
        eval_every: str = "60",
        subset: str = "50",
        dry_iters: str = "30",
        skip_dry: bool = False,
        dpo_iters: str = "200",
        dpo_lr: str = "1e-6",
        dpo_beta: str = "0.1",
        status: JobStatus | None = None,
        tick: int = 0;

    async can with [name, mode, tick] entry {
        if name != "" {
            status = await job_status(name, mode);
            schedule_next();
        }
    }

    def schedule_next -> None {
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    async def do_start -> None {
        if mode == "sft" {
            opts: dict = {"EVAL_EVERY": eval_every, "SUBSET": subset, "DRY_ITERS": dry_iters, "SKIP_DRY": "1" if skip_dry else "0"};
        } else {
            opts: dict = {"DPO_ITERS": dpo_iters, "DPO_LR": dpo_lr, "DPO_BETA": dpo_beta, "SUBSET": subset};
        }
        status = await start_training(model_id, name, mode, opts);
        tick = tick + 1;
    }

    async def do_stop -> None {
        status = await stop_training(name, mode);
        tick = tick + 1;
    }

    def set_mode(m: str) -> None {
        mode = m;
    }

    is_running: bool = status is not None and status.status == "running";

    return <div className="dg-page">
        <div className="dg-train-grid">
            <div className="dg-panel">
                <span className="dg-panel-label">LAUNCH.CONFIG</span>
                <div className="dg-stack">
                    <Field label="BASE MODEL (HF ID)" value={model_id} hint="org/model" onChange={lambda v: str { model_id = v; }} />
                    <Field label="SHORT NAME" value={name} hint="qwen" onChange={lambda v: str { name = v; }} />
                    <div className="dg-field">
                        <span className="dg-label">MODE</span>
                        <div className="dg-seg">
                            <button onClick={lambda (e: MouseEvent) { set_mode("sft"); }} className={"dg-seg-btn dg-active" if mode == "sft" else "dg-seg-btn"}>SFT</button>
                            <button onClick={lambda (e: MouseEvent) { set_mode("dpo"); }} className={"dg-seg-btn dg-active" if mode == "dpo" else "dg-seg-btn"}>DPO</button>
                        </div>
                    </div>
                    {if mode == "sft" {
                        <Field key="ee" label="EVAL_EVERY (S)" value={eval_every} hint="60" onChange={lambda v: str { eval_every = v; }} />
                        <Field key="ss" label="SUBSET" value={subset} hint="50" onChange={lambda v: str { subset = v; }} />
                        <Field key="di" label="DRY_ITERS" value={dry_iters} hint="30" onChange={lambda v: str { dry_iters = v; }} />
                        <label key="sd" className="dg-row" style={{"gap": "0.45rem", "color": "#777", "fontSize": "0.74rem"}}>
                            <input type="checkbox" checked={skip_dry} onChange={lambda (e: ChangeEvent) { skip_dry = not skip_dry; }} />
                            <span>SKIP DRY-RUN</span>
                        </label>
                    }}
                    {if mode == "dpo" {
                        <Field key="it" label="DPO_ITERS" value={dpo_iters} hint="200" onChange={lambda v: str { dpo_iters = v; }} />
                        <Field key="lr" label="DPO_LR" value={dpo_lr} hint="1e-6" onChange={lambda v: str { dpo_lr = v; }} />
                        <Field key="be" label="DPO_BETA" value={dpo_beta} hint="0.1" onChange={lambda v: str { dpo_beta = v; }} />
                        <Field key="ds" label="SUBSET" value={subset} hint="50" onChange={lambda v: str { subset = v; }} />
                    }}
                    <div className="dg-banner">
                        <strong>⚠ HEAVY.</strong> A 30B run is hours long and near the 48GB Metal ceiling — don't launch SFT and
                        DPO for the same model at once. SFT iters come from <span className="dg-mono">configs/lora.yaml</span>.
                    </div>
                    <button onClick={do_start} disabled={is_running} className="dg-btn dg-btn-primary" style={{"justifyContent": "center", "padding": "0.6rem"}}>{"▶ START " + mode.upper()}</button>
                </div>
            </div>

            <div className="dg-panel">
                <span className="dg-panel-label">RUN.STATUS</span>
                <div className="dg-row dg-mb">
                    {status is not None and <StatusGlyph status={status.status} />}
                    {status is not None and <span className="dg-faint">{"PID " + str(status.pid)}</span>}
                    {status is not None and <span className="dg-faint">{"ITER " + str(status.last_iter)}</span>}
                    {status is not None and <span className="dg-faint">{"STARTED " + (status.started if status.started != "" else "—")}</span>}
                    <span className="dg-spacer"></span>
                    <button onClick={do_stop} disabled={not is_running} className="dg-btn dg-btn-danger">■ STOP</button>
                </div>
                {status is not None and status.message != "" and <div className="dg-faint dg-mb">{status.message}</div>}
                <LogView text={status.log_tail if status is not None and status.log_tail != "" else "(no output yet)"} maxh="60vh" />
            </div>
        </div>
    </div>;
}
```

- [ ] **Step 2: Type-check**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check components/TrainPage.cl.jac`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add dashboard_app/components/TrainPage.cl.jac
git commit -m "feat(dashboard): HUD Train page (T2 split console)"
```

---

### Task 7: Ingest page — I2 builder rail + work area

**Files:**
- Modify: `dashboard_app/components/IngestPage.cl.jac` (full replace)

- [ ] **Step 1: Replace `IngestPage.cl.jac` with:**

```jac
"""Ingest: dataset stats, builder rail (pipeline order), JSONL preview, add raw examples.

Stats/preview read the dataset files; the builder rail spawns `jac run
srccurrent/jacgen/<stage>.jac` via services/jobs.run_builder and polls its log;
add-examples appends validated rows to the conversion sources.
"""

sv import from ..services.dataset { DatasetStats, FileStat, FileRef, dataset_stats, list_dataset_files, sample_rows, add_examples }
sv import from ..services.jobs { JobStatus, run_builder, builder_status }
import from .hud.Hud { BracketTile, StatusGlyph, JsonRow, LogView }

# pipeline order (subset that's useful to trigger from the UI).
glob STAGES: list[list[str]] = [
    ["seed_conversion", "seed"], ["idiomatic_batch", "idiom-1"], ["idiomatic_batch2", "idiom-2"],
    ["idiomatic_batch3", "idiom-3"], ["scale_conversion", "scale (slow)"], ["dpo_conversion", "dpo pairs"],
    ["build_manifest", "manifest"], ["build_splits", "sft splits"], ["build_dpo_splits", "dpo splits"],
    ["holdout", "holdout"], ["graph_holdout", "graph holdout"], ["dataset_stats", "stats"],
];

def:pub IngestPage() -> JsxElement {
    has stats: DatasetStats | None = None,
        files: list[FileRef] = [],
        sel_file: str = "dataset/conversion/sft.jsonl",
        offset: int = 0,
        rows: list[str] = [],
        active_stage: str = "",
        stage_status: dict = {},
        bstatus: JobStatus | None = None,
        btick: int = 0,
        add_target: str = "dataset/conversion/sft.jsonl",
        add_text: str = "",
        add_msg: str = "";

    async can with entry {
        stats = await dataset_stats();
        files = await list_dataset_files();
    }

    async can with [sel_file, offset] entry {
        rows = await sample_rows(sel_file, offset, 8);
    }

    async can with [active_stage, btick] entry {
        if active_stage != "" {
            fetched: JobStatus | None = await builder_status(active_stage);
            bstatus = fetched;
            if fetched is not None {
                marks: dict = dict(stage_status);
                marks[active_stage] = fetched.status;
                stage_status = marks;
            }
            if fetched is not None and fetched.status == "running" {
                setTimeout(lambda { btick = btick + 1; }, 2000);
            } else {
                stats = await dataset_stats();
                files = await list_dataset_files();
            }
        }
    }

    async def do_run(stage: str) -> None {
        active_stage = stage;
        bstatus = await run_builder(stage);
        btick = btick + 1;
    }

    def stage_glyph(stage: str) -> str {
        s: str = str(stage_status.get(stage, ""));
        if s == "running" { return "⦿"; }
        if s == "done" { return "✓"; }
        if s == "failed" { return "✗"; }
        return "○";
    }

    def stage_cls(stage: str) -> str {
        s: str = str(stage_status.get(stage, ""));
        base: str = "dg-stage dg-active" if stage == active_stage else "dg-stage";
        if s == "running" { return base + " dg-acc-green"; }
        if s == "failed" { return base + " dg-acc-red"; }
        return base;
    }

    def on_file(e: ChangeEvent) {
        sel_file = e.target.value;
        offset = 0;
    }

    def next_page(e: MouseEvent) {
        offset = offset + 8;
    }

    def prev_page(e: MouseEvent) {
        offset = offset - 8 if offset >= 8 else 0;
    }

    async def do_add -> None {
        res = await add_examples(add_target, add_text);
        added: int = int(res["added"]);
        total: int = int(res["total"]);
        errs: list = list(res["errors"]);
        if len(errs) > 0 {
            add_msg = "added " + str(added) + " · " + str(len(errs)) + " error(s): " + str(errs[0]);
        } else {
            add_msg = "added " + str(added) + " row(s) · file now " + str(total);
        }
        add_text = "";
        stats = await dataset_stats();
        files = await list_dataset_files();
    }

    return <div className="dg-page">
        {stats and <div key="sec-stats" className="dg-stats dg-mb-lg">
            <BracketTile key="sft" label="SFT.TOTAL" value={str(stats.sft_total)} sub="IDIOMATIC + TRANSPILE" subcls="" />
            <BracketTile key="dpo" label="DPO.PAIRS" value={str(stats.dpo_pairs)} sub="CHOSEN / REJECTED" subcls="" />
            <BracketTile key="mlxsft" label="MLX.SFT" value={str(stats.splits["mlx_train"]) + " / " + str(stats.splits["mlx_valid"])} sub="TRAIN / VALID" subcls="" />
            <BracketTile key="mlxdpo" label="MLX.DPO" value={str(stats.splits["dpo_train"]) + " / " + str(stats.splits["dpo_valid"])} sub="TRAIN / VALID" subcls="" />
            <BracketTile key="hold" label="HOLDOUT" value={str(stats.splits["holdout"]) + " / " + str(stats.splits["graph_holdout"])} sub="FUNCTION / GRAPH" subcls="" />
        </div>}

        <div className="dg-ingest-grid">
            <div className="dg-panel">
                <span className="dg-panel-label">BUILDERS</span>
                <div className="dg-faint" style={{"marginBottom": "0.5rem"}}>run in pipeline order ↓</div>
                <div className="dg-stack" style={{"gap": "0.15rem"}}>
                    {for pair in STAGES {
                        <button key={pair[0]} onClick={lambda (e: MouseEvent) { do_run(pair[0]); }} className={stage_cls(pair[0])}>
                            <span>{stage_glyph(pair[0])}</span>
                            <span>{pair[1]}</span>
                        </button>
                    }}
                </div>
                {bstatus is not None and <div className="dg-row" style={{"margin": "0.6rem 0 0.4rem"}}>
                    <StatusGlyph status={bstatus.status} />
                    <span className="dg-faint">{active_stage}</span>
                </div>}
                {bstatus is not None and bstatus.log_tail != "" and <LogView text={bstatus.log_tail} maxh="160px" />}
            </div>

            <div className="dg-stack" style={{"gap": "1.2rem"}}>
                <div className="dg-panel">
                    <span className="dg-panel-label">PREVIEW</span>
                    <div className="dg-row" style={{"marginBottom": "0.55rem"}}>
                        <select value={sel_file} onChange={on_file} className="dg-select">
                            {for f in files {
                                <option key={f.path} value={f.path}>{f.label + "  (" + str(f.count) + ")"}</option>
                            }}
                        </select>
                        <button onClick={prev_page} className="dg-btn">‹ PREV</button>
                        <span className="dg-faint">{"ROWS " + str(offset) + "–" + str(offset + len(rows))}</span>
                        <button onClick={next_page} className="dg-btn">NEXT ›</button>
                    </div>
                    <div className="dg-stack">
                        {if len(rows) == 0 {
                            <div key="empty" className="dg-faint">NO ROWS</div>
                        }}
                        {for (i, r) in enumerate(rows) {
                            <JsonRow key={str(i)} text={r} />
                        }}
                    </div>
                </div>

                <div className="dg-panel">
                    <span className="dg-panel-label">ADD.EXAMPLES</span>
                    <div className="dg-row" style={{"marginBottom": "0.5rem"}}>
                        <select value={add_target} onChange={lambda e: ChangeEvent { add_target = e.target.value; }} className="dg-select">
                            <option value="dataset/conversion/sft.jsonl">SFT (messages)</option>
                            <option value="dataset/conversion/dpo.jsonl">DPO (prompt/chosen/rejected)</option>
                        </select>
                        <button onClick={do_add} className="dg-btn dg-btn-primary">APPEND</button>
                        {add_msg != "" and <span className={"dg-acc-red" if "error" in add_msg else "dg-acc-green"} style={{"fontSize": "0.74rem"}}>{add_msg}</span>}
                    </div>
                    <textarea value={add_text} onChange={lambda e: ChangeEvent { add_text = e.target.value; }}
                        placeholder={"{\"messages\": [{\"role\": \"user\", ...}], \"meta\": {...}}"}
                        className="dg-textarea" />
                </div>
            </div>
        </div>
    </div>;
}
```

Notes for the implementer:
- The old file imported `StatCard` from MonitorPage and `StatusBadge` from TrainPage; both imports are gone — primitives now come from `.hud.Hud`. One JSON-object-per-line hint moved into the `ADD.EXAMPLES` panel label/placeholder.
- `stage_status` is rebuilt via `dict(stage_status)` + reassignment so the state change is detected (same reason as the LOCAL-variable comment in MonitorPage).
- If the checker rejects `lambda (e: MouseEvent) { do_run(pair[0]); }` capturing the loop var, fall back to the old `BuilderButton` child-component pattern (see git history of this file) with the new classes.

- [ ] **Step 2: Type-check the whole app**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac check components/IngestPage.cl.jac && jac check main.jac`
Expected: no errors anywhere now (all stale imports resolved).

- [ ] **Step 3: Commit**

```bash
git add dashboard_app/components/IngestPage.cl.jac
git commit -m "feat(dashboard): HUD Ingest page (I2 builder rail + work area)"
```

---

### Task 8: Build verification + docs touch-up

**Files:**
- Modify: `dashboard_app/README.md` (two lines)

- [ ] **Step 1: Production client build**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac build --client web`
Expected: build completes without errors.

- [ ] **Step 2: Manual smoke (visual)**

Run: `cd /Users/ayush/Downloads/JaseciLabs/DataGeneration/dashboard_app && jac start --dev main.jac`, open http://localhost:8000 and verify against the spec:
- Monitor: bracket stat tiles with trend annotations, HUD charts, syntax-colored LOG.TAIL; Compare toggle shows palette-colored tiles + 3 multi-line charts; run selector + SFT/DPO + auto toggle all work.
- Train: LAUNCH.CONFIG left / RUN.STATUS right; mode toggle swaps knob fields; START disabled while a run is live; log fills the tall right panel.
- Ingest: stat tiles, builder rail with `○` glyphs (click `stats` — the cheapest stage — and watch it go `⦿` then `✓`), preview paging with colored JSON rows, ADD.EXAMPLES message coloring.
Then stop the dev server.

- [ ] **Step 3: Update README design references**

In `dashboard_app/README.md`: change the `components/AppShell.cl.jac` bullet from "nav + routes" context if it mentions glass, and anywhere "glass" appears, reference the HUD design instead; add one line under the intro: `UI: sci-fi HUD design system (mono dark, semantic accents) — see docs/superpowers/specs/2026-06-10-dashboard-hud-redesign-design.md.`

- [ ] **Step 4: Commit**

```bash
git add dashboard_app/README.md
git commit -m "docs(dashboard): note HUD design system in README"
```

---

## Self-review (done at plan time)

- **Spec coverage:** design system → Task 1; HUD primitives incl. syntax tokenizer → Task 2; nav → Task 3; charts incl. live dot + dot-notation titles (`LOSS.TRAIN`, `LOSS.VAL`, `CURVE.PASS`, `LR`, `TOK.S`, `IDIOM.SIM`) → Task 4; Monitor L1 + rebuilt compare + `NO SIGNAL` empty state → Task 5; Train T2 → Task 6; Ingest I2 → Task 7; verification → Task 8. Out-of-scope items (no `.sv.jac` changes, no GPU tile, no light mode) hold across all tasks.
- **Type consistency:** `BracketTile(label, value, sub, subcls)`, `StatusGlyph(status)`, `LogView(text, maxh)`, `JsonRow(text)` are used with those exact signatures in Tasks 5–7; `MetricChart(title, data, color, live)` matches Task 4 and all Task 5 call sites.
- **Known risk:** Jac client syntax for lambdas-in-loops and dict-state updates; mitigations inline (Task 7 notes, `jac check` + `jac guide` loop each task).

---

# Revision A — 5-page scope (supersedes Tasks 5 and 8; Tasks 6 and 7 renumbered)

App was restructured mid-implementation (commits `5aa3daf`, `8c2778f`): Monitor = live-only,
new HistoryPage (past runs + compare), new DatasetPage (server-side `tok-*` highlighting),
shared RunCharts. User chose to extend HUD to all 5 pages. Tasks 1–4 stand as written.
Execution order: 4 → 5R → 6 (Train, unchanged from original Task 6) → 7R → 8R → 9 → 10.
Note: between 5R and 8R, `jac check components/IngestPage.cl.jac` fails on the removed
`StatCard` import — expected; whole-app check happens in Task 10.

### Task 5R: RunCharts + MonitorPage (replaces original Task 5)

**Files:**
- Modify: `dashboard_app/components/RunCharts.cl.jac` (full replace)
- Modify: `dashboard_app/components/MonitorPage.cl.jac` (full replace)

- [ ] **Step 1: Replace `RunCharts.cl.jac` with:**

```jac
"""Shared render of one run's metrics: HUD stat tiles + chart grid + LOG.TAIL.
Used by Monitor (live) and History (past snapshot)."""

sv import from ..services.runs { RunMetrics }
import from .charts.MetricChart { MetricChart }
import from .hud.Hud { BracketTile, LogView }

def last_y(series: list[dict]) -> str {
    if len(series) == 0 { return "—"; }
    return str(series[len(series) - 1]["y"]);
}

def loss_trend(series: list[dict]) -> list[str] {
    # [label, accent-class] from the last two points of a loss series.
    if len(series) < 2 { return ["", ""]; }
    a: float = float(str(series[len(series) - 2]["y"]));
    b: float = float(str(series[len(series) - 1]["y"]));
    if b < a { return ["▼ CONVERGING", "dg-acc-green"]; }
    if b > a { return ["▲ RISING", "dg-acc-amber"]; }
    return ["— HOLDING", ""];
}

def pass_trend(series: list[dict]) -> list[str] {
    if len(series) < 2 { return ["", ""]; }
    a: float = float(str(series[len(series) - 2]["y"]));
    b: float = float(str(series[len(series) - 1]["y"]));
    if b >= a { return ["▲ NOMINAL", "dg-acc-green"]; }
    return ["▼ REGRESSING", "dg-acc-amber"];
}

def:pub RunCharts(metrics: RunMetrics, live: bool) -> JsxElement {
    trn_t: list[str] = loss_trend(metrics.train);
    val_t: list[str] = loss_trend(metrics.val);
    pas_t: list[str] = pass_trend(metrics.curve);
    return <div>
        <div className="dg-stats dg-mb">
            <BracketTile label="PASS.RATE" value={last_y(metrics.curve) + "%"} sub={pas_t[0]} subcls={pas_t[1]} />
            <BracketTile label="LOSS.TRN" value={last_y(metrics.train)} sub={trn_t[0]} subcls={trn_t[1]} />
            <BracketTile label="LOSS.VAL" value={last_y(metrics.val)} sub={val_t[0]} subcls={val_t[1]} />
            <BracketTile label="TOK.S" value={last_y(metrics.tps)} sub={"ITER " + str(metrics.last_iter)} subcls="" />
        </div>

        {metrics.has_idiom and <div className="dg-stats dg-mb">
            <BracketTile key="a" label="IDIOM.SIM" value={str(metrics.idiom_avg_sim)} sub={metrics.idiom_label} subcls="" />
            <BracketTile key="b" label="IDIOMATIC" value={str(metrics.idiom_idiomatic)} sub="DIVERGED FROM TRANSPILE" subcls="" />
            <BracketTile key="c" label="PY.SHAPED" value={str(metrics.idiom_python)} sub="REPRODUCED TRANSPILE" subcls="" />
            <BracketTile key="d" label="RUNS.TOTAL" value={str(metrics.idiom_runs) + " / " + str(metrics.idiom_total)} sub="BEHAVIORAL PASS" subcls="" />
        </div>}

        <div className="dg-grid">
            <MetricChart title="LOSS.TRAIN" data={metrics.train} color="#fff" live={live} />
            <MetricChart title="LOSS.VAL" data={metrics.val} color="#fff" live={live} />
            <MetricChart title="CURVE.PASS" data={metrics.curve} color="#fff" live={live} />
            <MetricChart title="LR" data={metrics.lr} color="#fff" live={False} />
            <MetricChart title="TOK.S" data={metrics.tps} color="#fff" live={False} />
            {len(metrics.idiom_sim) > 0 and <MetricChart title="IDIOM.SIM" data={metrics.idiom_sim} color="#fff" live={False} />}
        </div>

        <div className="dg-panel dg-mb-lg" style={{"marginTop": "1.4rem"}}>
            <span className="dg-panel-label">LOG.TAIL</span>
            <LogView text={metrics.log_tail if metrics.log_tail != "" else "(no log yet)"} maxh="220px" />
        </div>
    </div>;
}
```

Note: the old `StatCard` export is intentionally gone; HistoryPage/IngestPage stop using it in Tasks 7R/8R.

- [ ] **Step 2: Replace `MonitorPage.cl.jac` with (logic identical to current file, HUD markup):**

```jac
"""Monitor — LIVE. Shows only currently-running training sessions and streams
their metrics in real time (2.5s poll). When a run finishes it drops off here and
appears under History.
"""

sv import from ..services.jobs { Session, list_sessions }
sv import from ..services.runs { RunMetrics, get_run_metrics }
import from .RunCharts { RunCharts }

def:pub MonitorPage() -> JsxElement {
    has sessions: list[Session] = [],
        sel_name: str = "",
        sel_mode: str = "sft",
        metrics: RunMetrics | None = None,
        tick: int = 0;

    async can with [tick] entry {
        s: list[Session] = await list_sessions();
        sessions = s;
        run: list[Session] = [x for x in s if x.status == "running"];
        found: bool = False;
        for x in run {
            if x.name == sel_name and x.mode == sel_mode { found = True; }
        }
        if not found {
            if len(run) > 0 {
                sel_name = run[0].name;
                sel_mode = run[0].mode;
            } else {
                sel_name = "";
                metrics = None;
            }
        }
        if sel_name != "" {
            metrics = await get_run_metrics(sel_name, sel_mode);
        }
        # always live — re-arm a single timer (only [tick] dep, so no extra chains)
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    def pick(nm: str, md: str) -> None {
        sel_name = nm;
        sel_mode = md;
    }

    running: list[Session] = [x for x in sessions if x.status == "running"];

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <span className="dg-status dg-glyph-run">⦿ LIVE</span>
            {for x in running {
                <button key={x.name + x.mode}
                    onClick={lambda (e: MouseEvent) { pick(x.name, x.mode); }}
                    className={"dg-btn dg-btn-primary" if (x.name == sel_name and x.mode == sel_mode) else "dg-btn"}>
                    {x.label}
                </button>
            }}
            <span className="dg-spacer"></span>
            {metrics and <span className="dg-faint">{"ITER " + str(metrics.last_iter)}</span>}
        </div>

        {len(running) == 0 and <div className="dg-panel" style={{"textAlign": "center", "padding": "2.6rem 1rem"}}>
            <span className="dg-panel-label">MONITOR</span>
            <div className="dg-chart-empty" style={{"padding": "0 0 0.5rem"}}>NO ACTIVE RUN</div>
            <div className="dg-faint">Start one on the TRAIN tab — it streams here live. Finished runs live under HISTORY.</div>
        </div>}

        {len(running) > 0 and metrics and <RunCharts metrics={metrics} live={True} />}
    </div>;
}
```

- [ ] **Step 3: `jac check components/RunCharts.cl.jac && jac check components/MonitorPage.cl.jac`** — no errors.
- [ ] **Step 4: Commit** `git add dashboard_app/components/RunCharts.cl.jac dashboard_app/components/MonitorPage.cl.jac && git commit -m "feat(dashboard): HUD RunCharts + live Monitor"`

### Task 6: Train page — unchanged from original plan Task 6 (T2 split console). Note HistoryPage and IngestPage still import `StatusBadge` from TrainPage until Tasks 7R/8R run; only check `components/TrainPage.cl.jac` in this task.

### Task 7R: HistoryPage — HUD restyle (new)

**Files:**
- Modify: `dashboard_app/components/HistoryPage.cl.jac` (full replace)

- [ ] **Step 1: Replace with (logic identical, HUD markup; StatusGlyph from Hud; RunCharts gains live arg):**

```jac
"""History — PAST training sessions. Browse any finished run's metrics (snapshot),
and compare runs (gemma vs qwen) overlaid. Live runs live on the Monitor tab."""

sv import from ..services.jobs { Session, list_sessions }
sv import from ..services.runs { RunMetrics, CompareResult, get_run_metrics, compare_runs }
import from .RunCharts { RunCharts }
import from .charts.MultiLineChart { MultiLineChart }
import from .hud.Hud { StatusGlyph }

glob CMP_COLORS: list[str] = ["#60a5fa", "#f472b6", "#34d399", "#a78bfa", "#22d3ee"];

def:pub HistoryPage() -> JsxElement {
    has sessions: list[Session] = [],
        sel: str = "",
        sel_name: str = "",
        sel_mode: str = "sft",
        metrics: RunMetrics | None = None,
        compare: bool = False,
        cmode: str = "sft",
        cmp: CompareResult | None = None,
        tick: int = 0;

    async can with entry {
        s: list[Session] = await list_sessions();
        past: list[Session] = [x for x in s if x.status != "running"];
        sessions = past;
        if len(past) > 0 and sel == "" {
            sel = past[0].name + "|" + past[0].mode;
            sel_name = past[0].name;
            sel_mode = past[0].mode;
            metrics = await get_run_metrics(past[0].name, past[0].mode);
        }
    }

    async can with [sel_name, sel_mode, tick] entry {
        if sel_name != "" {
            metrics = await get_run_metrics(sel_name, sel_mode);
        }
    }

    async can with [compare, cmode] entry {
        if compare {
            cmp = await compare_runs(cmode);
        }
    }

    def on_select(e: ChangeEvent) {
        v: str = e.target.value;
        sel = v;
        parts: list = v.split("|");
        sel_name = str(parts[0]);
        sel_mode = str(parts[1]) if len(parts) > 1 else "sft";
    }

    def set_cmode(m: str) -> None {
        cmode = m;
    }

    def toggle_compare(e: MouseEvent) {
        compare = not compare;
    }

    chead: list[dict] = cmp.headline if cmp is not None else [];
    cnames: list[str] = cmp.names if cmp is not None else [];
    ctrain: list[dict] = cmp.train if cmp is not None else [];
    cval: list[dict] = cmp.val if cmp is not None else [];
    ccurve: list[dict] = cmp.curve if cmp is not None else [];
    cur_status: str = "";
    for x in sessions {
        if x.name == sel_name and x.mode == sel_mode { cur_status = x.status; }
    }

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <select value={sel} onChange={on_select} className="dg-select" disabled={compare}>
                {if len(sessions) == 0 {
                    <option key="none" value="">no past runs</option>
                }}
                {for x in sessions {
                    <option key={x.name + x.mode} value={x.name + "|" + x.mode}>{x.label}</option>
                }}
            </select>
            {not compare and cur_status != "" and <StatusGlyph status={cur_status} />}
            <button onClick={toggle_compare} className={"dg-btn dg-btn-primary" if compare else "dg-btn"}>
                {"COMPARING ALL RUNS" if compare else "COMPARE"}
            </button>
            {compare and <div className="dg-seg">
                <button onClick={lambda (e: MouseEvent) { set_cmode("sft"); }} className={"dg-seg-btn dg-active" if cmode == "sft" else "dg-seg-btn"}>SFT</button>
                <button onClick={lambda (e: MouseEvent) { set_cmode("dpo"); }} className={"dg-seg-btn dg-active" if cmode == "dpo" else "dg-seg-btn"}>DPO</button>
            </div>}
        </div>

        {compare and len(chead) > 0 and <div className="dg-stats dg-mb">
            {for (i, h) in enumerate(chead) {
                <div key={str(h["name"])} className="dg-tile">
                    <span className="dg-br dg-br-tl"></span>
                    <span className="dg-br dg-br-br"></span>
                    <div className="dg-tile-label" style={{"color": CMP_COLORS[i % len(CMP_COLORS)]}}>{"■ " + str(h["name"]) + " · " + cmode}</div>
                    <div className="dg-tile-value">{str(h["final_pass"]) + "%"}</div>
                    <div className="dg-tile-sub">{"idiom " + str(h["idiom_sim"]) + " · loss " + str(h["last_loss"])}</div>
                </div>
            }}
        </div>}

        {compare and len(chead) > 0 and <div className="dg-grid">
            <MultiLineChart title="LOSS.TRAIN" data={ctrain} names={cnames} colors={CMP_COLORS} />
            <MultiLineChart title="LOSS.VAL" data={cval} names={cnames} colors={CMP_COLORS} />
            <MultiLineChart title="CURVE.PASS" data={ccurve} names={cnames} colors={CMP_COLORS} />
        </div>}

        {not compare and metrics is None and <div className="dg-chart-empty" style={{"padding": "4rem 0"}}>NO PAST RUNS</div>}
        {not compare and metrics and <RunCharts metrics={metrics} live={False} />}
    </div>;
}
```

- [ ] **Step 2: `jac check components/HistoryPage.cl.jac`** — no errors.
- [ ] **Step 3: Commit** `git add dashboard_app/components/HistoryPage.cl.jac && git commit -m "feat(dashboard): HUD History page"`

### Task 8R: IngestPage — I2 (use the ORIGINAL plan Task 7 code verbatim)

The original Task 7 file replacement remains correct for the current IngestPage (state/handler logic
is identical in the restructured app; only the old imports differ, and the replacement already imports
from `.hud.Hud`). Follow original Task 7 steps 1–3 exactly, except the whole-app check: run
`jac check components/IngestPage.cl.jac` only (DatasetPage/main check happens in Task 10).

### Task 9: DatasetPage CSS + markup touch (new)

**Files:**
- Modify: `dashboard_app/global.css` (append section)
- Modify: `dashboard_app/components/DatasetPage.cl.jac` (one class + two text tweaks)

- [ ] **Step 1: Append to `global.css`:**

```css
/* ---- dataset table (HUD) ---- */
.dg-table { border: 1px solid #333; }
.dg-thead, .dg-tr {
  display: grid;
  grid-template-columns: 56px minmax(120px, 200px) 110px minmax(120px, 180px) 1fr;
  gap: 0.6rem; align-items: center;
  padding: 0.5rem 0.9rem;
}
.dg-thead { border-bottom: 1px solid #333; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.18em; color: #777; }
.dg-tr { border-bottom: 1px solid #1c1c1f; cursor: pointer; transition: background .12s; font-size: 0.78rem; color: #bbb; }
.dg-tr:hover { background: rgba(255, 255, 255, 0.03); }
.dg-tr.dg-open { background: rgba(255, 255, 255, 0.05); }
.dg-td { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dg-kind { font-size: 0.66rem; padding: 0.08rem 0.4rem; border: 1px solid #444; color: #999; text-transform: uppercase; letter-spacing: 0.08em; }
.dg-detail { padding: 0.9rem 1rem 1.1rem; background: rgba(0, 0, 0, 0.35); border-bottom: 1px solid #1c1c1f; }
.dg-detail-prompt { color: #b7b7c0; font-size: 0.8rem; margin-bottom: 0.7rem; line-height: 1.5; white-space: pre-wrap; }
.dg-code-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 0.7rem; }

/* ---- code block + One-Dark tokens (server-side highlighted spans) ---- */
.dg-code { border: 1px solid #333; background: #0a0a0c; }
.dg-code-label { font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.18em; color: #777; padding: 0.35rem 0.7rem; border-bottom: 1px solid #2a2a2e; }
.dg-code-pre { margin: 0; padding: 0.7rem 0.85rem; overflow: auto; max-height: 360px; }
.dg-code-pre code { font-family: inherit; font-size: 0.76rem; line-height: 1.55; color: #d7d7e0; white-space: pre; }
.tok-kw   { color: #c678dd; }
.tok-type { color: #56b6c2; }
.tok-bi   { color: #e5c07b; }
.tok-str  { color: #98c379; }
.tok-num  { color: #d19a66; }
.tok-com  { color: #6b7079; font-style: italic; }
```

- [ ] **Step 2: In `DatasetPage.cl.jac`:** change `className="dg-glass dg-table"` to `className="dg-table"`; change the two hint strings `"click a row to expand"` → `"CLICK ROW TO EXPAND"` and `"rows " + ...` → `"ROWS " + ...`; change button labels `‹ prev`/`next ›` → `‹ PREV`/`NEXT ›`. No logic changes.
- [ ] **Step 3: `jac check components/DatasetPage.cl.jac`** — no errors.
- [ ] **Step 4: Commit** `git add dashboard_app/global.css dashboard_app/components/DatasetPage.cl.jac && git commit -m "style(dashboard): HUD dataset table + One-Dark token palette"`

### Task 10: Build verification + docs (replaces original Task 8)

Same as original Task 8, but the manual smoke covers FIVE screens (Monitor live/empty, History incl.
compare, Train, Ingest, Dataset expand-row with token colors) and step 1 starts with
`jac check main.jac` (whole app, all imports resolved) before `jac build --client web`.
