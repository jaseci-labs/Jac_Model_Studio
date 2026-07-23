"""Field / TextInput / Segmented form primitives. Ports ui/components/shared/field.tsx."""

def:pub Field(label: str, children: any = None) -> JsxElement {
    return <div className="flex flex-col gap-1">
        <span className="micro-label">{label}</span>
        {children}
    </div>;
}

def:pub TextInput(value: str, onSet: Callable[([str], None)], placeholder: str, mono: bool) -> JsxElement {
    return <input
        type="text"
        value={value}
        onChange={lambda e: ChangeEvent { onSet(e.target.value); }}
        placeholder={placeholder}
        className={"exp-input " + (
            "font-mono" if mono else ""
        )}
    />;
}

def:pub Segmented(options: list[str], value: str, onSet: Callable[([str], None)]) -> JsxElement {
    return <div className="flex gap-1">
        {for opt in options {
            <button
                key={opt}
                onClick={lambda e: MouseEvent { onSet(opt); }}
                className={"exp-chip " + (
                    "exp-chip-active" if value == opt else ""
                )}
            >
                {opt}
            </button>
        }}
    </div>;
}
