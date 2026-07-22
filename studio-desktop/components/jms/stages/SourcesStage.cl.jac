"""SourcesStage — the SOURCES stage panel of a JMS project.

Three sections: (a) USE CASE — a textarea persisted via update_project with a
saved-flash; (b) SOURCES — one row per attached source (kind chip, left-truncated
path, files·tokens + extension histogram, RESCAN / REMOVE); (c) ADD SOURCE — an
absolute-path input + CODE/DOCS toggle + optional include/exclude comma-glob
inputs, with a busy state + inline error line.

`project` is the get_project() dict from the parent; `onRefresh` re-fetches it
after any mutation. Scanning happens server-side (add_source / scan_source run
the os.walk inline) so these handlers just fire-and-refresh. All colored surfaces
use jms.css token classes → correct in every theme. Handlers are named apply.../
add.../rescan/remove — NEVER set<HasVar> (that shadows the auto useState setter)."""

sv import from ....jms_projects { update_project, add_source, remove_source, scan_source }

def _fmtTokens(n: int) -> str {
    if n >= 1000000 { return f"{n / 1000000:.1f}M"; }
    if n >= 1000 { return f"{n / 1000:.1f}k"; }
    return str(n);
}

def _splitGlobs(s: str) -> list[str] {
    out: list[str] = [];
    for part in s.split(",") {
        t = part.strip();
        if t { out.append(t); }
    }
    return out;
}

def:pub SourcesStage(project: any = None, onRefresh: any = None) -> JsxElement {
    has useCase: str = "",
        ucInit: bool = False,
        savedFlash: bool = False,
        savingUc: bool = False,
        addPath: str = "",
        addKind: str = "code",
        addInc: str = "",
        addExc: str = "",
        addBusy: bool = False,
        addErr: str = "",
        busySid: str = "";

    # Seed the textarea from the loaded project once (prop → local editable state).
    can with entry {
        if not ucInit and project {
            useCase = str(project["use_case"]);
            ucInit = True;
        }
    }

    def _pid -> str {
        if project { return str(project["pid"]); }
        return "";
    }

    async def applyUseCase -> None {
        savingUc = True;
        savedFlash = False;
        try {
            await update_project(_pid(), {"use_case": useCase});
        } except Exception { }
        savingUc = False;
        savedFlash = True;
        if onRefresh is not None { await onRefresh(); }
    }

    async def addSrc -> None {
        if not addPath.strip() { addErr = "path required"; return; }
        addBusy = True;
        addErr = "";
        res: any = None;
        try {
            res = await add_source(
                _pid(), addKind, addPath.strip(),
                _splitGlobs(addInc), _splitGlobs(addExc)
            );
        } except Exception {
            addErr = "add failed";
            addBusy = False;
            return;
        }
        if res and "error" in res {
            addErr = str(res["error"]);
        } else {
            addPath = "";
            addInc = "";
            addExc = "";
            if onRefresh is not None { await onRefresh(); }
        }
        addBusy = False;
    }

    async def rescanSrc(sid: str) -> None {
        busySid = sid;
        try { await scan_source(_pid(), sid); } except Exception { }
        busySid = "";
        if onRefresh is not None { await onRefresh(); }
    }

    async def removeSrc(sid: str) -> None {
        busySid = sid;
        try { await remove_source(_pid(), sid); } except Exception { }
        busySid = "";
        if onRefresh is not None { await onRefresh(); }
    }

    sources: list = [];
    if project { sources = list(project["sources"]); }

    return <div className="flex flex-col gap-5">
        <div className="jms-section">
            <span className="jms-section-label">USE CASE</span>
            <div className="flex flex-col gap-3">
                <span className="jms-mono-dim">What should the finetuned model be good at?</span>
                <textarea
                    className="jms-textarea"
                    value={useCase}
                    placeholder="e.g. translate idiomatic Python into idiomatic Jac (OSP graph code)…"
                    onChange={lambda e: any {
                        useCase = str(e.target.value);
                        savedFlash = False;
                    }}
                />
                <div className="flex items-center gap-3">
                    <button
                        className="jms-btn jms-btn-accent"
                        disabled={savingUc}
                        onClick={lambda e: MouseEvent { applyUseCase(); }}
                    >{"SAVING…" if savingUc else "SAVE"}</button>
                    {savedFlash and <span className="jms-flash">saved ✓</span>}
                </div>
            </div>
        </div>

        <div className="jms-section">
            <span className="jms-section-label">SOURCES</span>
            {if len(sources) == 0 {
                <span className="jms-mono-dim">No sources yet — add a code or docs directory below.</span>
                skip;
            }}
            {if len(sources) > 0 {
                <div className="flex flex-col">
                    {for s in sources {
                        <div key={str(s["sid"])} className="jms-srow">
                            <span className="jms-chip">{str(s["kind"])}</span>
                            <div className="jms-trunc-left min-w-0 flex-1" title={str(s["path"])}>
                                <span className="jms-mono">{str(s["path"])}</span>
                            </div>
                            <div className="flex shrink-0 flex-col items-end gap-0.5">
                                <span className="jms-mono-dim">
                                    {str(s["files"])} files · ~{_fmtTokens(int(str(s["est_tokens"])))} tok
                                </span>
                                {s["ext_line"] and <span className="jms-mono-dim">{str(s["ext_line"])}</span>}
                            </div>
                            <div className="flex shrink-0 items-center gap-2">
                                <button
                                    className="jms-btn"
                                    disabled={busySid == str(s["sid"])}
                                    onClick={lambda e: MouseEvent { rescanSrc(str(s["sid"])); }}
                                >{"…" if busySid == str(s["sid"]) else "RESCAN"}</button>
                                <button
                                    className="jms-btn jms-btn-danger"
                                    disabled={busySid == str(s["sid"])}
                                    onClick={lambda e: MouseEvent { removeSrc(str(s["sid"])); }}
                                >REMOVE</button>
                            </div>
                        </div>
                    }}
                </div>
                skip;
            }}
        </div>

        <div className="jms-section">
            <span className="jms-section-label">ADD SOURCE</span>
            <div className="flex flex-col gap-3">
                <input
                    className="jms-input"
                    value={addPath}
                    placeholder="/absolute/path/to/repo-or-docs"
                    onChange={lambda e: any { addPath = str(e.target.value); addErr = ""; }}
                />
                <div className="flex flex-wrap items-center gap-3">
                    <div className="flex items-center gap-1">
                        <button
                            className={"jms-btn" + (" jms-btn-accent" if addKind == "code" else "")}
                            onClick={lambda e: MouseEvent { addKind = "code"; }}
                        >CODE</button>
                        <button
                            className={"jms-btn" + (" jms-btn-accent" if addKind == "docs" else "")}
                            onClick={lambda e: MouseEvent { addKind = "docs"; }}
                        >DOCS</button>
                    </div>
                    <input
                        className="jms-input flex-1"
                        style={{"minWidth": "140px"}}
                        value={addInc}
                        placeholder="include globs (optional, comma-sep)"
                        onChange={lambda e: any { addInc = str(e.target.value); }}
                    />
                    <input
                        className="jms-input flex-1"
                        style={{"minWidth": "140px"}}
                        value={addExc}
                        placeholder="exclude globs (optional, comma-sep)"
                        onChange={lambda e: any { addExc = str(e.target.value); }}
                    />
                </div>
                <div className="flex items-center gap-3">
                    <button
                        className="jms-btn jms-btn-accent"
                        disabled={addBusy}
                        onClick={lambda e: MouseEvent { addSrc(); }}
                    >{"SCANNING…" if addBusy else "ADD SOURCE"}</button>
                    {addErr and <span className="jms-mono-dim" style={{"color": "var(--jms-danger)"}}>{addErr}</span>}
                </div>
            </div>
        </div>
    </div>;
}
