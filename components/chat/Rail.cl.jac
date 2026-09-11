"""Chat right rail — prompt library + sampling controls + last-run stats.
Ports ui/components/rail.tsx."""

# 40 chars ≈ two lines at 11px mono in the w-60 rail, which is what the row
# wraps to. Longer than that and the tail is invisible anyway; shorter and the
# prose prompts (which share long leading verbs) start colliding.
def _clip(s: str) -> str {
    return (s[:40] + "…") if len(s) > 40 else s;
}

# Row label for one library prompt.
#
# BUG THIS FIXES: labelling a row with its FIRST line rendered all 12 "Python →
# Jac" prompts as the identical string "Convert this Python to idiomatic Jac:" —
# every entry in the category shares that prefix, and the part that actually
# differs (the fenced code) was cut off. So: when a prompt carries a fenced code
# block, the label is the first line INSIDE the fence — trimmed of a leading
# `def ` and a trailing `:`/`{`, so `normalize_vector(vector)` / `walker Counter` —
# which is exactly the distinguishing part; otherwise it is the first non-empty
# line (the prose prompts are already distinct). The category header
# ("Python → Jac") already carries the shared intent, so dropping the shared
# prefix loses nothing. Full prompt stays available via `title=`.
#
# ponytail: derived client-side from the prompt text. prompts.json has no
# per-entry label/title field; adding one there is the real fix and is out of
# scope here. Ceiling: a prompt whose first code line is itself shared across
# entries would collide again — the row number is the only tiebreak.
def _label(s: str) -> str {
    lines = s.split(chr(10));
    lead = "";
    inCode = False;
    for ln in lines {
        t = str(ln).strip();
        if not t { continue; }
        if t[:3] == "```" {
            if inCode { break; }
            inCode = True;
            continue;
        }
        if inCode {
            code = t[4:].strip() if t[:4] == "def " else t;
            return _clip(code.rstrip(":").rstrip("{").strip());
        }
        if not lead { lead = t; }
    }
    return _clip(lead);
}

# NOTE: a `def -> JsxElement` with params compiles to a props-OBJECT component
# (`function Slider(props) { const {label,...} = props; }`) — it MUST be handed a
# single props object. The old positional call silently destructured every field
# to undefined (unlabeled sliders with min/max/value="undefined", and
# `onSet is not a function` the moment you dragged one). Rendering it as JSX
# (`<Slider label=… />`) is the props-object form that also type-checks.
def Slider(
    label: str, val: float, lo: float, hi: float, step: float, fmt: str,
    onSet: Callable[([float], None)]
) -> JsxElement {
    return <div className="mb-3">
        <div className="mb-1 flex justify-between">
            <span className="micro-label">{label}</span>
            <span className="font-mono text-[11px] text-foreground/80">{fmt}</span>
        </div>
        <input
            type="range"
            aria-label={label}
            min={str(lo)} max={str(hi)} step={str(step)} value={str(val)}
            onChange={lambda (e: ChangeEvent) { onSet(float(e.target.value)); }}
            className="w-full accent-[var(--accent)]"
        />
    </div>;
}

def:pub Rail(
    prompts: list, temperature: float, topP: float, maxTokens: int, lastStats: any,
    collapsed: bool, onPick: Callable[([str], None)],
    onTemp: Callable[([float], None)], onTopP: Callable[([float], None)],
    onMaxTokens: Callable[([float], None)], onToggle: Callable[([], None)]
) -> JsxElement {
    has openCat: str = "py2jac";

    if collapsed {
        return <button
            onClick={lambda (e: MouseEvent) { onToggle(); }}
            className="flex w-8 shrink-0 items-center justify-center border-l border-border bg-card text-muted-foreground hover:text-foreground"
        >⟨</button>;
    }
    return <div className="flex w-60 shrink-0 flex-col overflow-y-auto border-l border-border bg-card">
        <div className="flex items-center justify-between border-b border-border px-3 py-2.5">
            <span className="micro-label">PROMPT LIBRARY</span>
            <button onClick={lambda (e: MouseEvent) { onToggle(); }} className="micro-label text-muted-foreground/80 hover:text-foreground/80">⟩</button>
        </div>
        <div className="p-2">
            {for cat in prompts {
                <div key={str(cat["id"])} className="mb-1">
                    <button
                        onClick={lambda (e: MouseEvent) { openCat = "" if openCat == str(cat["id"]) else str(cat["id"]); }}
                        className="flex w-full items-center justify-between rounded-sm px-2 py-1 text-left font-mono text-[11px] text-foreground/80 hover:bg-secondary"
                    >
                        <span>{("▾ " if openCat == str(cat["id"]) else "▸ ") + str(cat["label"])}</span>
                        <span className="text-muted-foreground/80">{str(len(list(cat["prompts"])))}</span>
                    </button>
                    {if openCat == str(cat["id"]) {
                        <div key="if1" className="flex flex-col gap-0.5 pl-2">
                            {for (pi, pr) in enumerate(list(cat["prompts"])) {
                                <button
                                    key={str(pi)}
                                    onClick={lambda (e: MouseEvent) { onPick(str(pr)); }}
                                    className="group flex w-full items-start gap-2 rounded-sm px-2 py-1 text-left hover:bg-secondary"
                                    title={str(pr)}
                                >
                                    <span className="w-4 shrink-0 text-right font-mono text-[10px] text-muted-foreground/80">{str(pi + 1)}</span>
                                    <span className="min-w-0 flex-1 stat-line leading-snug break-words group-hover:text-foreground/80">{_label(str(pr))}</span>
                                </button>
                            }}
                        </div>
                        skip;
                    }}
                </div>
            }}
        </div>

        <div className="dashed-rule mx-3" />
        <div className="border-b border-border px-3 py-2.5"><span className="micro-label">SAMPLING</span></div>
        <div className="p-3">
            <Slider key="temp" label="TEMPERATURE" val={temperature} lo={0.0} hi={1.5}
                step={0.05} fmt={f"{temperature:.2f}"} onSet={onTemp} />
            <Slider key="topp" label="TOP_P" val={topP} lo={0.1} hi={1.0}
                step={0.05} fmt={f"{topP:.2f}"} onSet={onTopP} />
            <Slider key="maxtok" label="MAX_TOKENS" val={float(maxTokens)} lo={128.0} hi={4096.0}
                step={128.0} fmt={str(maxTokens)} onSet={onMaxTokens} />
        </div>

        <div className="dashed-rule mx-3" />
        <div className="p-3">
            <div className="micro-label mb-2">LAST RUN</div>
            {if lastStats {
                <div key="if2" className="font-mono text-[11px] leading-relaxed text-muted-foreground">
                    <div>{str(lastStats["tps"])} tok/s</div>
                    <div>{str(lastStats["tokens"])} tokens</div>
                    <div>Δ {str(lastStats["gen_s"])}s · load {str(lastStats["load_s"])}s</div>
                </div>
                skip;
            }}
            {if not lastStats {
                <span key="if3" className="stat-line">no run yet</span>
                skip;
            }}
        </div>
    </div>;
}
