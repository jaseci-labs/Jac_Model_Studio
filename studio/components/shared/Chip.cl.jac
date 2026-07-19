"""Chip — selectable pill (segmented options, session pickers, file chips,
history model/stage buttons). Selected = accent surface + ring border."""

import from ...lib.utils { cn }

def:pub Chip(
    onClick: Callable[([MouseEvent], None)],
    selected: bool = False,
    children: any = None,
    className: str = ""
) -> JsxElement {
    return <button
        onClick={onClick}
        className={cn(
            "rounded-md border px-3 py-1 text-xs transition-colors",
            "border-ring bg-accent text-foreground" if selected
                else "border-input text-muted-foreground hover:text-foreground/80",
            className
        )}
    >
        {children}
    </button>;
}
