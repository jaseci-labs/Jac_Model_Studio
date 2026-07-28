"""Landing — the hub hero. Two identical-size full-height panels, JMS (the new
product) and EXPERIMENTS (the existing lab), differing only in copy. A floating
glass pill nav sits at top-center (wordmark + `<ThemeSwitcher/>`), a 3-card
glass feature row sits below the entries, and a 3-slot footer carries a keyboard
hint, the tagline and a live "at a glance" readout. No page scroll at any window
size ≥ ~900×600: the hero grid flexes between the pill nav and the footer strip,
display type is clamp()-sized against both vw and vh, and everything is
overflow-hidden. Light/dark mode is inherited from `:root`/`.dark` via the
`<ThemeSwitcher/>` — no per-jms-theme lock.

The two hero entries are real `<button>` elements, not clickable divs: they are
the ONLY way into either surface, so they must be tab-reachable and fire on
Enter/Space natively. Tailwind preflight neutralises the UA button chrome and
`.jms-card`/`.jms-hero-panel` (class specificity > element specificity) supply
the glass, layout and `text-align: left` — the look is byte-identical.

The hero panels are FROZEN — their resting paint and their box must not change.
Everything this file adds to them is either out of flow (the absolutely
positioned `.jms-hero-enter` badge) or opacity-0 until hover/focus, so a
screenshot of the settled page is identical with and without it.

Load choreography (delays live in jms.css, derived from --dur-fast):
  pill nav .05s → hero panels .10/.15s → accent ticks .30s →
  feature cards .35/.40/.45s → footer .50s.

The footer's "at a glance" readout is real data or nothing: three independent
best-effort calls to endpoints that are already registered in main.jac
(`list_projects`, `list_runs`, `list_evals`). Each writes its own state string
only on success, so a failed/slow call simply omits its segment — this page
never renders a placeholder number that could be mistaken for a real one. The
readout's `<span>` is rendered unconditionally (empty until the calls land) so
the footer grid keeps exactly three tracks and `.jms-footer-3 > :last-child`
keeps pointing at it."""

# ponytail: the ~400px of empty panel interior is NOT filled, and cannot be from
# this file. Every block on this page lives in one h-screen flex column whose
# only flexible track is .jms-hero-grid, so ANY new row — an at-a-glance strip, a
# second line in a feature card, a "what's new" band — comes straight out of the
# panels' height, and the hero is frozen (its clamp()-ed wordmark is vh-sensitive
# at narrow widths, so a height change is a type-size change). Ceiling: the new
# detail is therefore height-neutral by construction — it goes into the footer's
# existing single line, onto the feature cards' existing label line, or into
# out-of-flow hover-only affordances. Filling the panel interiors needs the hero
# unfrozen, which is a separate decision.

import from react { useEffect }
import from ..ThemeSwitcher { ThemeSwitcher }
import from ..AssistantPanel { AssistantPanel }
sv import from ...jms_projects { list_projects }
sv import from ...runs { list_runs }
sv import from ...evals { list_evals }

def:pub Landing(onPick: any = None) -> JsxElement {
    has glance: str = "",
        running: int = 0;

    """Best-effort hub stats. Three independent try blocks on purpose: one dead
    endpoint must not blank the other two, and nothing is rendered for a segment
    that did not resolve."""
    async def loadGlance -> None {
        parts: list[str] = [];
        try {
            ps = await list_projects("");
            n = len(list(ps));
            parts.append(str(n) + (" PROJECT" if n == 1 else " PROJECTS"));
        } except Exception { }
        try {
            rr = await list_runs();
            rl = list(rr["runs"]);
            live = 0;
            for r in rl {
                if r["running"] { live = live + 1; }
            }
            running = live;
            seg = str(len(rl)) + (" RUN" if len(rl) == 1 else " RUNS");
            if live > 0 { seg = seg + " · " + str(live) + " LIVE"; }
            parts.append(seg);
        } except Exception { }
        try {
            er = await list_evals();
            el = list(er["evals"]);
            if len(el) > 0 {
                e0 = el[0];
                parts.append("LAST EVAL " + str(e0.status).upper() + " " + str(e0.started)[:10]);
            }
        } except Exception { }
        glance = " · ".join(parts);
    }

    useEffect(lambda {
        loadGlance();
        return lambda {};
    }, []);

    return <div className="jms-scope relative flex h-screen w-screen flex-col overflow-hidden">
        <div className="jms-pillnav reveal stagger-1">
            <span className="jms-label">JAC · MODEL STUDIO</span>
            <ThemeSwitcher />
        </div>

        <div className="jms-hero-grid" style={{"paddingTop": "84px"}}>
            <button type="button" className="jms-card jms-hero-panel reveal stagger-2"
                onClick={lambda e: MouseEvent { if onPick is not None { onPick("jms"); } }}>
                <span className="jms-hero-enter" aria-hidden="true">
                    <span className="jms-kbd">↵</span>ENTER
                </span>
                <span className="jms-label jms-hero-kicker">NEW · PROJECT PIPELINE</span>
                <span className="jms-display jms-hero-word">JMS</span>
                <span className="jms-hero-accent-tick jms-tick-draw jms-seq-6" />
                <span className="jms-hero-sub">Synthesize a dataset. Train a model for it.</span>
                <span className="jms-stat">dataset synthesis · cloud + local finetuning · eval</span>
            </button>
            <button type="button" className="jms-card jms-hero-panel reveal stagger-3"
                onClick={lambda e: MouseEvent { if onPick is not None { onPick("experiments"); } }}>
                <span className="jms-hero-enter" aria-hidden="true">
                    <span className="jms-kbd">↵</span>ENTER
                </span>
                <span className="jms-label jms-hero-kicker">EXISTING LAB</span>
                <span className="jms-display jms-hero-word">EXPERIMENTS</span>
                <span className="jms-hero-accent-tick jms-tick-draw jms-seq-6" />
                <span className="jms-hero-sub">The existing lab: chat, data, train, RL, CPT.</span>
                <span className="jms-stat">sft/dpo · rl/grpo · cpt workspaces</span>
            </button>
        </div>

        <div className="jms-feature-row">
            <div className="jms-feature reveal jms-seq-7">
                <div className="jms-feat-head">
                    <span className="jms-label">LOCAL · FIRST</span>
                    <span className="jms-feat-tag">MLX</span>
                </div>
                <div className="jms-hero-sub" style={{"marginTop":"6px"}}>Your models, your data. Native desktop, MLX on-device.</div>
                <span className="jms-feat-rule" />
            </div>
            <div className="jms-feature reveal jms-seq-8">
                <div className="jms-feat-head">
                    <span className="jms-label">CLOUD · WHEN YOU WANT</span>
                    <span className="jms-feat-tag">SPHERON</span>
                </div>
                <div className="jms-hero-sub" style={{"marginTop":"6px"}}>Burst to Spheron GPUs for heavier finetunes.</div>
                <span className="jms-feat-rule" />
            </div>
            <div className="jms-feature reveal jms-seq-9">
                <div className="jms-feat-head">
                    <span className="jms-label">END · TO · END</span>
                    <span className="jms-feat-tag">5 STAGES</span>
                </div>
                <div className="jms-hero-sub" style={{"marginTop":"6px"}}>Synthesize → curate → train → eval, one surface.</div>
                <span className="jms-feat-rule" />
            </div>
        </div>

        <div className="jms-footer jms-footer-3 reveal jms-seq-10">
            <span className="jms-stat">tab to move · ↵ to enter</span>
            <span className="jms-stat">local-first · your models, your data</span>
            <span className="jms-glance jms-stat reveal-fade">
                {if running > 0 { <span key="livedot" className="jms-live-dot pulse" /> }}
                {glance}
            </span>
        </div>

        <AssistantPanel pageContext="Hub landing page — the user can go to the Experiments lab or the JMS product." />
    </div>;
}
