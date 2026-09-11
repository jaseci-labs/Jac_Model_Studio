"""Field / TextInput / Segmented form primitives. Ports ui/components/shared/field.tsx.

Named event handlers (not `lambda (e: Type) { … }`) so client compile works across
Jac versions that reject the unparenthesized typed-lambda spelling.

a11y: `Field` renders a REAL <label> element (not a styled <span>) so the caption
is exposed as a label in the a11y tree, and threads its caption down to the
control through `htmlFor`/`ariaLabel` where a call site opts in. Controls that
Field cannot reach carry their own accessible name: `TextInput` always emits an
`aria-label` (explicit `ariaLabel`, else the caption-ish `placeholder`).
`Segmented` needs nothing — its options are <button>s with visible text.

# ponytail: Field does NOT wrap its children in the <label> (implicit
# association) and does NOT clone children to inject a generated id. Both were
# tried and rejected: a <label> forwards clicks to its first labelable
# descendant, and ~8 call sites put <button> groups inside a Field
# (Train BACKEND, Evals MODEL/KIND, Cloud OFFER/SSH KEY/AUTO-TERMINATE), so
# wrapping would make a click on the caption text press the first button.
# Ceiling: a raw <input> passed as a Field child (Login EMAIL/PASSWORD) is still
# only named by its placeholder unless the call site passes `htmlFor` + `id`.
"""

def:pub Field(label: str, htmlFor: str = "", children: any = None) -> JsxElement {
    return <div className="flex flex-col gap-1">
        <label className="micro-label" htmlFor={htmlFor if htmlFor else None}>{label}</label>
        {children}
    </div>;
}

def:pub TextInput(
    value: str, onSet: Callable[[str], None], placeholder: str, mono: bool,
    ariaLabel: str = "", id: str = ""
) -> JsxElement {
    # `any` so an unset id renders as no attribute at all (React drops null props);
    # the intrinsic `id` prop is typed str and rejects `str | None` directly.
    domId: any = id if id else None;
    def handle_change(e: ChangeEvent) {
        onSet(e.target.value);
    }
    return <input
        type="text"
        id={domId}
        aria-label={ariaLabel if ariaLabel else placeholder}
        value={value}
        onChange={handle_change}
        placeholder={placeholder}
        className={"exp-input " + (
            "font-mono" if mono else ""
        )}
    />;
}

def:pub Segmented(options: list[str], value: str, onSet: Callable[[str], None]) -> JsxElement {
    return <div className="flex gap-1">
        {for opt in options {
            <button
                key={opt}
                onClick={lambda { onSet(opt); }}
                className={"exp-chip " + (
                    "exp-chip-active" if value == opt else ""
                )}
            >
                {opt}
            </button>
        }}
    </div>;
}
