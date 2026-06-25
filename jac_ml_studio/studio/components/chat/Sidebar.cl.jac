"""Chat history sidebar — ports ui/components/sidebar.tsx.

Chat list (active highlight, hover-reveal DEL), new-chat button, RAM gauge.
"""

def _gauge(used: float, total: float) -> str {
    if total <= 0.0 {
        return "░░░░░░░░";
    }
    n = int(round(used / total * 8.0));
    bar = "";
    i = 0;
    while i < 8 {
        bar += "▮" if i < n else "░";
        i += 1;
    }
    return bar;
}

def:pub Sidebar(
    chats: list,
    activeId: str,
    ramGb: float,
    residentGb: float,
    onNew: Callable[([], None)],
    onOpen: Callable[([str], None)],
    onDelete: Callable[([str], None)]
) -> JsxElement {
    return <div className="flex w-48 shrink-0 flex-col border-r border-neutral-800 bg-[#0d0d0d]">
        <div className="flex items-center justify-between border-b border-neutral-800 px-3 py-2.5">
            <span className="micro-label">JAC.STUDIO · fig.1</span>
        </div>
        <button
            onClick={lambda e: MouseEvent { onNew(); }}
            className="m-2 rounded-md border border-dashed border-neutral-700 px-2 py-1.5 text-left font-mono text-xs text-neutral-400 hover:border-neutral-500 hover:text-neutral-200"
        >
            + new chat
        </button>
        <div className="flex-1 overflow-y-auto px-2">
            {if len(chats) == 0 {
                <span className="micro-label px-1">no chats yet</span>
                skip;
            }}
            {for c in chats {
                <div
                    key={str(c.id)}
                    onClick={lambda e: MouseEvent { onOpen(str(c.id)); }}
                    className={"group mb-0.5 flex cursor-pointer items-center justify-between rounded px-2 py-1.5 " + (
                        "bg-[#1a1a1a] text-neutral-100" if str(c.id) == activeId
                        else "text-neutral-400 hover:bg-[#141414]"
                    )}
                >
                    <span className="truncate font-mono text-xs" title={str(c.title)}>{c.title if c.title else "untitled"}</span>
                    <button
                        onClick={lambda e: MouseEvent { e.stopPropagation(); onDelete(str(c.id)); }}
                        className="micro-label ml-2 hidden shrink-0 text-neutral-600 hover:text-neutral-300 group-hover:block"
                    >
                        DEL
                    </button>
                </div>
            }}
        </div>
        <div className="dashed-rule mx-2" />
        <div className="px-3 py-2">
            <div className="micro-label">MEMORY</div>
            <div className="font-mono text-[11px] text-neutral-400">
                {_gauge(residentGb, ramGb)} {str(int(round(residentGb)))}/{str(int(round(ramGb)))} GB
            </div>
        </div>
    </div>;
}
