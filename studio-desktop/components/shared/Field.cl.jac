"""Field / TextInput / Segmented form primitives. Ports ui/components/shared/field.tsx.

Named event handlers (not `lambda (e: Type) { … }`) so client compile works across
Jac versions that reject the unparenthesized typed-lambda spelling.
"""

def:pub Field(label: str, children: any = None) -> JsxElement {
    return <div className="flex flex-col gap-1">
        <span className="micro-label">{label}</span>
        {children}
    </div>;
}

def:pub TextInput(
    value: str, onSet: Callable[[str], None], placeholder: str, mono: bool
) -> JsxElement {
    def handle_change(e: ChangeEvent) {
        onSet(e.target.value);
    }
    return <input
        type="text"
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
