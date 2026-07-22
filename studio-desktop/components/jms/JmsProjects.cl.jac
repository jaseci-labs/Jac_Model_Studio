"""JmsProjects — the project list (card grid) + inline new-project form.

Each card shows the project name (display type), a 2-line use-case excerpt, a
`N sources · raw X · curated Y` stat line, five stage-progress dots (filled per
stage_state == "done"), the created date, and a two-click DELETE (first click →
"SURE?", second confirms — no window.confirm). A dashed NEW PROJECT card expands
into an inline name + use-case form. With no projects at all, a centered
"NO PROJECTS YET" hero carries the empty state.

Cards are built from get_project() dicts (fetched per project after list_projects)
so the stat line + stage dots have row_stats + stage_state to read. `onOpen(pid,
name)` hands the selection up to JmsShell for the breadcrumb + detail switch."""

sv import from ...jms_projects { create_project, list_projects, get_project, delete_project }

glob STAGE_IDS: list[str] = ["sources", "generate", "curate", "train", "eval"];

def _sstate(d: any, sid: str) -> str {
    ss: any = d["stage_state"];
    if ss and sid in ss { return str(ss[sid]); }
    return "empty";
}

def:pub JmsProjects(onOpen: any = None) -> JsxElement {
    has rows: list = [],
        loading: bool = True,
        creating: bool = False,
        newName: str = "",
        newUse: str = "",
        createBusy: bool = False,
        confirmId: str = "";

    async def load -> None {
        r = await list_projects();
        acc: list = [];
        for p in r {
            d = await get_project(p.pid);
            if d { acc.append(d); }
        }
        rows = acc;
        loading = False;
    }

    async can with entry {
        await load();
    }

    async def createNew -> None {
        if not newName.strip() { return; }
        createBusy = True;
        try {
            await create_project(newName.strip(), newUse.strip());
        } except Exception { }
        newName = "";
        newUse = "";
        creating = False;
        createBusy = False;
        await load();
    }

    async def removeProj(pid: str) -> None {
        if confirmId != pid { confirmId = pid; return; }
        confirmId = "";
        try { await delete_project(pid); } except Exception { }
        await load();
    }

    def _openForm -> None {
        creating = True;
        confirmId = "";
    }

    def _card(d: any) -> JsxElement {
        pid = str(d["pid"]);
        rs: any = d["row_stats"];
        raw = str(rs["raw"]) if rs else "0";
        cur = str(rs["curated"]) if rs else "0";
        nsrc = len(list(d["sources"]));
        return <div
            key={pid}
            className="jms-card jms-pcard"
            onClick={lambda e: MouseEvent {
                if onOpen is not None { onOpen(pid, str(d["name"])); }
            }}
        >
            <span className="jms-pname">{str(d["name"])}</span>
            <span className="jms-clamp2">{str(d["use_case"]) if d["use_case"] else "no use case yet"}</span>
            <div className="mt-auto flex flex-col gap-2.5">
                <span className="jms-stat">{str(nsrc)} sources · raw {raw} · curated {cur}</span>
                <div className="jms-dots">
                    {for sid in STAGE_IDS {
                        <span key={sid} className={"jms-dot" + (" jms-dot-on" if _sstate(d, sid) == "done" else "")} />
                    }}
                </div>
                <div className="flex items-center justify-between">
                    <span className="jms-mono-dim">{str(d["created"])[:10]}</span>
                    <button
                        className={"jms-btn" + (" jms-btn-danger" if confirmId == pid else "")}
                        onClick={lambda e: MouseEvent {
                            e.stopPropagation();
                            removeProj(pid);
                        }}
                    >{"SURE?" if confirmId == pid else "DELETE"}</button>
                </div>
            </div>
        </div>;
    }

    def _newCard -> JsxElement {
        if creating {
            return <div className="jms-card jms-pcard" style={{"cursor": "default"}}>
                <span className="jms-label">NEW PROJECT</span>
                <input
                    className="jms-input"
                    value={newName}
                    placeholder="project name"
                    onChange={lambda e: any { newName = str(e.target.value); }}
                />
                <textarea
                    className="jms-textarea flex-1"
                    value={newUse}
                    placeholder="use case — what should the model be good at?"
                    onChange={lambda e: any { newUse = str(e.target.value); }}
                />
                <div className="flex items-center gap-2">
                    <button
                        className="jms-btn jms-btn-accent"
                        disabled={createBusy}
                        onClick={lambda e: MouseEvent { createNew(); }}
                    >{"CREATING…" if createBusy else "CREATE"}</button>
                    <button
                        className="jms-btn"
                        onClick={lambda e: MouseEvent { creating = False; newName = ""; newUse = ""; }}
                    >CANCEL</button>
                </div>
            </div>;
        }
        return <div
            className="jms-card jms-pcard jms-newcard"
            onClick={lambda e: MouseEvent { _openForm(); }}
        >
            <span className="jms-display" style={{"fontSize": "28px"}}>+</span>
            <span className="jms-label">NEW PROJECT</span>
        </div>;
    }

    if loading {
        return <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden p-6">
            <span className="jms-label">LOADING…</span>
        </div>;
    }

    if len(rows) == 0 and not creating {
        return <div className="jms-shell-empty">
            <span className="jms-display jms-shell-word">NO PROJECTS YET</span>
            <span className="jms-hero-sub" style={{"maxWidth": "48ch"}}>
                Spin up a project, point it at your code + docs, and synthesize a dataset to finetune on.
            </span>
            <button className="jms-btn jms-btn-accent" onClick={lambda e: MouseEvent { _openForm(); }}>
                + NEW PROJECT
            </button>
        </div>;
    }

    return <div className="min-h-0 flex-1 overflow-y-auto p-6">
        <div className="jms-grid">
            {_newCard()}
            {# _card takes a param → compiles to a props-component; call with a props dict, not positionally
             [_card({"d": d}) for d in rows]}
        </div>
    </div>;
}
