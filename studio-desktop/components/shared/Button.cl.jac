"""Button — the one action button. Three variants cover every current use:
outline (default chrome action), solid (the section's primary action), ghost
(inline micro-actions like COPY/DEL). One size; pass className for width tweaks."""

import from ...lib.utils { cn }

glob VARIANTS: dict = {
    "outline": "exp-btn",
    "solid": "exp-btn exp-btn-accent",
    "ghost": "exp-btn exp-btn-ghost"
};

def:pub Button(
    onClick: Callable[([MouseEvent], None)],
    children: any = None,
    variant: str = "outline",
    disabled: bool = False,
    className: str = ""
) -> JsxElement {
    v = str(VARIANTS[variant]) if variant in VARIANTS else str(VARIANTS["outline"]);
    return <button
        onClick={onClick}
        disabled={disabled}
        className={cn(v, className)}
    >
        {children}
    </button>;
}
