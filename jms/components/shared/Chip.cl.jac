"""Chip — selectable pill (segmented options, session pickers, file chips,
history model/stage buttons). Selected = accent surface + the workspace accent
color on the border (second state channel beyond tone)."""

import from ...lib.utils { cn }

def:pub Chip(
    onClick: Callable[([MouseEvent], None)],
    selected: bool = False,
    children: any = None,
    className: str = ""
) -> JsxElement {
    return <button
        onClick={onClick}
        style={{"borderColor": "var(--ws-accent)"} if selected else {}}
        className={cn(
            "exp-chip",
            "exp-chip-active" if selected else "",
            className
        )}
    >
        {children}
    </button>;
}
