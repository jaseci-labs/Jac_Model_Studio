"""Chat history sidebar — ports ui/components/sidebar.tsx.

Chats are grouped by day (most-recent first) under TODAY / ISO-date micro-labels;
each row reveals a DEL action on hover. The footer MEM gauge shows resident vs
total RAM as `{used} / {ram} GB` plus an 8-cell ▮/░ bar."""

def _repeat(ch: str, n: int) -> str {
    s = "";
    i = 0;
    while i < n {
        s = s + ch;
        i = i + 1;
    }
    return s;
}

# Group consecutive chats (already sorted newest-first) by their updated_at day.
def _groups(chats: list) -> list[dict] {
    out: list[dict] = [];
    for c in chats {
        day = str(c.updated_at)[:10];
        if len(out) > 0 and out[len(out) - 1]["day"] == day {
            out[len(out) - 1]["chats"].append(c);
        } else {
            out.append({"day": day, "chats": [c]});
        }
    }
    return out;
}

def _mem_gauge(used: float, total: float) -> JsxElement {
    filled = 0;
    if total > 0.0 {
        filled = int(round(used / total * 8.0));
    }
    if filled > 8 { filled = 8; }
    if filled < 0 { filled = 0; }
    return <div className="dashed-rule pt-3 font-mono text-[10px] text-neutral-500">
        MEM {f"{used:.1f}"} / {str(int(total))} GB{" "}
        <span className="text-neutral-300">{_repeat("▮", filled)}</span>{_repeat("░", 8 - filled)}
    </div>;
}

def:pub Sidebar(
    chats: list,
    activeId: str,
    ramGb: float,
    residentGb: float,
    todayIso: str,
    busy: bool,
    onNew: Callable[([], None)],
    onOpen: Callable[([str], None)],
    onDelete: Callable[([str], None)]
) -> JsxElement {
    return <aside className="flex w-56 shrink-0 flex-col border-r border-neutral-800 bg-[#0d0d0d] p-3">
        <div className="micro-label mb-3">JAC.STUDIO · fig.1</div>
        <button
            onClick={lambda e: MouseEvent { if not busy { onNew(); } }}
            disabled={busy}
            className="mb-3 rounded-md border border-dashed border-neutral-600 py-1.5 text-xs text-neutral-300 hover:border-neutral-400 disabled:opacity-40"
        >
            + new chat
        </button>
        <div className="flex-1 overflow-y-auto">
            {if len(chats) == 0 {
                <p className="px-2 font-mono text-[10px] text-neutral-600">no chats yet</p>
                skip;
            }}
            {for grp in _groups(chats) {
                <div key={str(grp["day"])}>
                    <div className="micro-label mb-1 mt-2">{"TODAY" if grp["day"] == todayIso else str(grp["day"])}</div>
                    <div className="space-y-0.5">
                        {for c in list(grp["chats"]) {
                            <div
                                key={str(c.id)}
                                onClick={lambda e: MouseEvent { if not busy { onOpen(str(c.id)); } }}
                                className={"group flex cursor-pointer items-center justify-between rounded-md px-2 py-1.5 text-xs " + (
                                    "bg-[#1a1a1a] text-neutral-100" if str(c.id) == activeId
                                    else "text-neutral-400 hover:bg-[#141414]"
                                ) + (" opacity-50" if busy else "")}
                            >
                                <span className="truncate" title={str(c.title)}>{c.title if c.title else "untitled"}</span>
                                <button
                                    onClick={lambda e: MouseEvent { e.stopPropagation(); if not busy { onDelete(str(c.id)); } }}
                                    className="hidden font-mono text-[9px] text-neutral-600 hover:text-neutral-300 group-hover:block"
                                >DEL</button>
                            </div>
                        }}
                    </div>
                </div>
            }}
        </div>
        {_mem_gauge(residentGb, ramGb)}
    </aside>;
}
