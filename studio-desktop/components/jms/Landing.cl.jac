"""Landing — the hub hero. Two full-height panels: JMS (the new product, loud)
and EXPERIMENTS (the existing lab, deliberately quieter). No page scroll at any
window size ≥ ~900×600: the hero grid flexes between a fixed top bar and footer
strip, display type is clamp()-sized against both vw and vh, and everything
overflow-hidden. Theme state lives in the frontend gate; this just renders the
current one and forwards switcher clicks."""

import from .JmsThemeSwitcher { JmsThemeSwitcher }

def:pub Landing(onPick: any = None, theme: str = "", onTheme: any = None) -> JsxElement {
    t: str = theme if theme else "electric-minimal";
    return <div
        className="jms-scope flex h-screen w-screen flex-col overflow-hidden"
        data-jms-theme={t}
    >
        <div className="jms-topbar">
            <span className="jms-label">JAC MODEL STUDIO</span>
            <JmsThemeSwitcher theme={t} onTheme={onTheme} />
        </div>

        <div className="jms-hero-grid">
            <div
                className="jms-card jms-hero-panel"
                onClick={lambda e: MouseEvent {
                    if onPick is not None { onPick("jms"); }
                }}
            >
                <span className="jms-label jms-hero-kicker">NEW · PROJECT PIPELINE</span>
                <span className="jms-display jms-hero-word">JMS</span>
                <span className="jms-hero-accent-tick" />
                <span className="jms-hero-sub">Synthesize a dataset. Train a model for it.</span>
                <span className="jms-stat">dataset synthesis · cloud + local finetuning · eval</span>
            </div>

            <div
                className="jms-card jms-hero-panel jms-hero-quiet"
                onClick={lambda e: MouseEvent {
                    if onPick is not None { onPick("experiments"); }
                }}
            >
                <span className="jms-label jms-hero-kicker">EXISTING LAB</span>
                <span className="jms-display jms-hero-word-sm">EXPERIMENTS</span>
                <span className="jms-hero-sub">The existing lab: chat, data, train, RL, CPT.</span>
                <span className="jms-stat">sft/dpo · rl/grpo · cpt workspaces</span>
            </div>
        </div>

        <div className="jms-footer">
            <span className="jms-stat">local-first · your models, your data</span>
        </div>
    </div>;
}
