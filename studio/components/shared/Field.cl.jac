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
        className={"w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1 text-sm text-neutral-100 outline-none placeholder:text-neutral-600 focus:border-neutral-500 " + (
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
                className={"rounded-md border px-3 py-1 text-xs transition-colors " + (
                    "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if value == opt
                    else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                )}
            >
                {opt}
            </button>
        }}
    </div>;
}
