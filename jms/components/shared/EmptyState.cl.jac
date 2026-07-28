"""EmptyState — the one empty/loading vocabulary. pulse=True doubles as the
loading state (the app's aesthetic is text, not spinners).

`actionLabel` + `onAction` are TRAILING optionals so an empty panel can offer the
obvious next step instead of being a dead end; every pre-existing call site
(Gallery, Plan, CptResults) passes neither and renders exactly as before. The
button only mounts when BOTH are supplied — a label with no handler would be a
dead control."""

def:pub EmptyState(
    label: str, hint: str = "", pulse: bool = False, height: int = 0,
    actionLabel: str = "", onAction: any = None
) -> JsxElement {
    return <div
        className="flex flex-col items-center justify-center gap-1 py-6"
        style={{"height": height} if height > 0 else {}}
    >
        <span className={"micro-label " + ("pulse" if pulse else "")}>{label}</span>
        {hint and <span className="stat-line">{hint}</span>}
        {(actionLabel and onAction is not None) and <button
            className="exp-btn mt-3"
            onClick={lambda e: MouseEvent { onAction(); }}
        >{actionLabel}</button>}
    </div>;
}
