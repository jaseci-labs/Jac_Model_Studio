"""Landing — the hub hero. Two identical-size full-height panels, JMS (the new
product) and EXPERIMENTS (the existing lab), differing only in copy. A floating
glass pill nav sits at top-center (wordmark + `<ThemeSwitcher/>`), and a 3-card
glass feature row sits below the entries. No page scroll at any window size
≥ ~900×600: the hero grid flexes between the pill nav and the footer strip,
display type is clamp()-sized against both vw and vh, and everything is
overflow-hidden. Entrance uses `reveal`/`stagger-N` (global.css). Light/dark
mode is inherited from `:root`/`.dark` via the `<ThemeSwitcher/>` — no
per-jms-theme lock."""

import from ..ThemeSwitcher { ThemeSwitcher }

def:pub Landing(onPick: any = None) -> JsxElement {
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
}
