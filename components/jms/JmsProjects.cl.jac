"""JmsProjects — the project list (card grid) + the whole project lifecycle.

A card shows the project name (display type), a 2-line use-case excerpt, a
`N sources · raw X · curated Y` stat line, five stage-progress dots (filled per
stage_state == "done"), the created date, a two-click DELETE (first click →
"SURE?", second confirms — no window.confirm) and a RENAME / CLONE / EXPORT
action row. A dashed NEW PROJECT card expands into an inline name + use-case form.

One card at a time can swap its body for an action panel (`actId` + `actMode`):

  RENAME  inline name edit. Display name ONLY — the panel says so, because the
          slug (and therefore the on-disk folder) never moves. See
          jms_projects.sv.jac `rename_project` for the full justification: stored
          adapter_paths and live worker processes hold that directory open.
  CLONE   duplicates the CONFIG (use case, sources, provider/model, plan). The
          "also copy curated rows" checkbox is opt-in and prints the real byte
          cost next to it (from `dataset_export_info`) before you commit; it is
          disabled outright when there is nothing materialized to copy.
  EXPORT  downloads train.jsonl / holdout.jsonl and a project summary
          (Markdown or JSON) fully client-side — Blob + object URL, revoked after
          the click. `export_dataset` is PAGINATED under a ~2 MB server-side
          response budget, so a large dataset is fetched page by page (progress is
          shown) and joined in the browser; no endpoint ever returns the file whole.

Above the grid: a search box (name + use case) and a recent/name sort, both
persisted to localStorage so a reload keeps the view. With no projects at all the
grid is replaced by a real onboarding panel (what a project is, the 5 stages, and
what you need) rather than a bare "+ NEW PROJECT" tile.

Cards are built from get_project() dicts (fetched per project after list_projects)
so the stat line + stage dots have row_stats + stage_state to read. `onOpen(pid,
name)` hands the selection up to JmsShell for the breadcrumb + detail switch.

`group` (from JmsShell's active workspace) filters the list to that workspace
and is stamped onto any project created from this grid. A plain mount effect
only runs once, so switching workspaces needs a real prop-change refetch —
`useEffect(..., [group])` reloads whenever `group` changes (it also fires once
on mount, replacing the old `async can with entry` load).

# ponytail: rename lives on the CARD only, not in the project-detail header. The
breadcrumb name is owned by JmsShell (it captures it from onOpen), so a rename
from inside the detail view would need a new callback threaded through a
component this file does not own. Ceiling: you rename from the list, then open."""

import from react { useEffect }
import from ...hooks.useConfirmReset { useConfirmReset }
sv import from ...jms_projects {
    create_project, list_projects, get_project, delete_project,
    rename_project, duplicate_project,
    dataset_export_info, export_dataset, export_summary
}

glob STAGE_IDS: list[str] = ["sources", "generate", "curate", "train", "eval"];

# First-run onboarding copy. Deliberately describes only what the app actually
# does today — no roadmap, no promises.
glob ONBOARD: list[dict] = [
    {"n": "1", "id": "SOURCES",
     "t": "Point at a folder of code or docs on this machine. It is scanned in place — file counts and a token estimate. Nothing is uploaded here."},
    {"n": "2", "id": "GENERATE",
     "t": "An LLM drafts a dataset plan you edit and approve, then synthesizes rows grounded in those sources."},
    {"n": "3", "id": "CURATE",
     "t": "Accept, reject or edit the generated rows, then split them into train.jsonl and holdout.jsonl."},
    {"n": "4", "id": "TRAIN",
     "t": "LoRA-finetune a base model on the curated set — locally with MLX, or on a rented cloud GPU."},
    {"n": "5", "id": "EVAL · CHAT",
     "t": "Score the adapter against the holdout (LLM judge or text similarity), then chat with it."}
];
glob NEEDS: list[str] = [
    "A local directory of code or docs to learn from.",
    "For GENERATE: an Anthropic or OpenAI API key, or a local MLX model you have already downloaded.",
    "For local TRAIN: Apple Silicon with MLX. Otherwise train on a rented GPU."
];

def _sstate(d: any, sid: str) -> str {
    ss: any = d["stage_state"];
    if ss and sid in ss { return str(ss[sid]); }
    return "empty";
}

"""Case-insensitive substring match over name + use case."""
def _matches(d: any, needle: str) -> bool {
    if not needle { return True; }
    return needle in (str(d["name"]) + " " + str(d["use_case"])).lower();
}

"""Recent-first IS the server's order, so `recent` is a pass-through; `name` does
an explicit insertion sort (case-insensitive) built from slices + concat rather
than `sorted(key=...)` / `list.insert`, neither of which is guaranteed to survive
the .cl.jac → JS compile."""
def _ordered(items: list, mode: str) -> list {
    if mode != "name" { return items; }
    out: list = [];
    for d in items {
        k = str(d["name"]).lower();
        pos = len(out);
        j = 0;
        while j < len(out) {
            if k < str(out[j]["name"]).lower() { pos = j; break; }
            j = j + 1;
        }
        out = out[:pos] + [d] + out[pos:];
    }
    return out;
}

"""Human byte size. Integer math on purpose: an f-string format spec (`:.1f`)
does not survive the .cl.jac → JS compile."""
def _hbytes(n: int) -> str {
    if n < 1024 { return str(n) + " B"; }
    if n < 1048576 { return str(n // 1024) + " KB"; }
    return str(n // 1048576) + "." + str((n % 1048576) * 10 // 1048576) + " MB";
}

"""One side of a dataset_export_info dict as "12 rows · 4 KB"."""
def _dsline(info: any, which: str) -> str {
    if not info { return "checking…"; }
    if which not in info { return "—"; }
    side: any = info[which];
    if not side["exists"] { return "not materialized yet"; }
    return str(side["lines"]) + " rows · " + _hbytes(int(str(side["bytes"])));
}

"""True once we know there is a curated train.jsonl worth copying/exporting."""
def _hasTrain(info: any) -> bool {
    if not info { return False; }
    if "train" not in info { return False; }
    side: any = info["train"];
    return bool(side["exists"]) and int(str(side["lines"])) > 0;
}

"""Hand *text* to the browser as a download, entirely client-side: Blob → object
URL → a throwaway <a download> → revoke. `window.Reflect.construct` because bare
`new X()` is rejected by the Jac client compiler. The revoke is deferred a tick:
revoking synchronously right after .click() cancels the download in Chromium."""
def _download(name: str, mime: str, text: str) -> None {
    doc: any = document;
    win: any = window;
    blob: any = win.Reflect.construct(win.Blob, [[text], {"type": mime}]);
    url: any = win.URL.createObjectURL(blob);
    a: any = doc.createElement("a");
    a.href = url;
    a.download = name;
    a.style.display = "none";
    doc.body.appendChild(a);
    a.click();
    doc.body.removeChild(a);
    setTimeout(lambda { win.URL.revokeObjectURL(url); }, 0);
}

def:pub JmsProjects(onOpen: any = None, group: str = "") -> JsxElement {
    has rows: list = [],
        loading: bool = True,
        loadErr: str = "",
        creating: bool = False,
        newName: str = "",
        newUse: str = "",
        createBusy: bool = False,
        confirmId: str = "",
        query: str = "",
        sortBy: str = "recent",
        actId: str = "",
        actMode: str = "",
        renameVal: str = "",
        cloneName: str = "",
        cloneRows: bool = False,
        expInfo: any = None,
        busy: bool = False,
        msg: str = "";

    async def load -> None {
        try {
            r = await list_projects(group);
            acc: list = [];
            for p in r {
                d = await get_project(p.pid);
                if d { acc.append(d); }
            }
            rows = acc;
            loadErr = "";
        } except Exception {
            # Without this the promise rejects unhandled, `loading` never clears and
            # the user stares at "LOADING…" forever with no clue why.
            loadErr = "could not load projects — is the server reachable?";
        }
        loading = False;
    }

    useEffect(lambda {
        loading = True;
        load();
        return lambda {};
    }, [group]);

    # An armed DELETE ("SURE?") disarms itself on Escape, on a pointer-down
    # outside the button, or after 4s — see hooks/useConfirmReset. Without it the
    # armed card stayed armed forever and a later stray click deleted a project.
    useConfirmReset(confirmId, lambda -> None { confirmId = ""; });

    # Restore the search + sort choice once, on mount only.
    useEffect(lambda {
        try {
            w: any = window;
            sq: any = w.localStorage.getItem("jms.projects.q");
            ss: any = w.localStorage.getItem("jms.projects.sort");
            if sq { query = str(sq); }
            if ss { sortBy = str(ss); }
        } except Exception { }
        return lambda {};
    }, []);

    # `apply*` and not `set*`: a `has x` already generates a `setX` binding, and
    # reusing that name is a "symbol already declared" compile error.
    def applyQuery(v: str) -> None {
        query = v;
        try {
            w: any = window;
            w.localStorage.setItem("jms.projects.q", v);
        } except Exception { }
    }

    def applySort(v: str) -> None {
        sortBy = v;
        try {
            w: any = window;
            w.localStorage.setItem("jms.projects.sort", v);
        } except Exception { }
    }

    async def createNew -> None {
        if not newName.strip() { return; }
        createBusy = True;
        try {
            await create_project(newName.strip(), newUse.strip(), group);
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
        actId = "";
        actMode = "";
    }

    def closeAct -> None {
        actId = "";
        actMode = "";
        msg = "";
    }

    async def loadInfo(pid: str) -> None {
        try {
            i = await dataset_export_info(pid);
            expInfo = ({} if ("error" in i) else i);
        } except Exception {
            expInfo = {};
        }
    }

    def openAct(pid: str, mode: str, d: any) -> None {
        actId = pid;
        actMode = mode;
        msg = "";
        confirmId = "";
        creating = False;
        if mode == "rename" { renameVal = str(d["name"]); }
        if mode == "clone" {
            cloneName = str(d["name"]) + " copy";
            cloneRows = False;
        }
        if mode == "clone" or mode == "export" {
            expInfo = None;
            loadInfo(pid);
        }
    }

    async def doRename(pid: str) -> None {
        nm = renameVal.strip();
        if not nm { msg = "name cannot be empty"; return; }
        busy = True;
        try {
            await rename_project(pid, nm);
            actId = "";
            actMode = "";
            msg = "";
            await load();
        } except Exception { msg = "rename failed"; }
        busy = False;
    }

    async def doClone(pid: str) -> None {
        busy = True;
        msg = "cloning…";
        try {
            r = await duplicate_project(pid, cloneName.strip(), cloneRows);
            if "error" in r {
                msg = str(r["error"]);
            } else {
                actId = "";
                actMode = "";
                cloneName = "";
                cloneRows = False;
                msg = "";
                await load();
            }
        } except Exception { msg = "clone failed"; }
        busy = False;
    }

    # Paged pull: the server caps each response (~2 MB / 2k rows) and hands back
    # `next_offset` + `eof`, so a large dataset arrives in bounded chunks that are
    # joined here. The 500-page stop is a runaway guard, and it SAYS it stopped
    # rather than handing over a silently short file.
    async def doExportDataset(pid: str, which: str) -> None {
        busy = True;
        msg = "preparing " + which + "…";
        chunks: list = [];
        off = 0;
        fname: str = which + ".jsonl";
        pages = 0;
        stopped = False;
        try {
            while True {
                r = await export_dataset(pid, which, off);
                if "error" in r {
                    msg = str(r["error"]);
                    busy = False;
                    return;
                }
                for ln in list(r["lines"]) { chunks.append(str(ln)); }
                fname = str(r["filename"]);
                if r["eof"] { break; }
                off = int(str(r["next_offset"]));
                pages = pages + 1;
                msg = "downloading… " + str(len(chunks)) + " rows";
                if pages > 500 {
                    stopped = True;
                    break;
                }
            }
            _download(fname, "application/x-ndjson", "\n".join(chunks) + "\n");
            if stopped {
                msg = "stopped at " + str(len(chunks)) + " rows (500-page guard) — file is INCOMPLETE";
            } else {
                msg = str(len(chunks)) + " rows exported";
            }
        } except Exception { msg = "export failed"; }
        busy = False;
    }

    async def doExportSummary(pid: str, fmt: str) -> None {
        busy = True;
        msg = "building summary…";
        try {
            r = await export_summary(pid, fmt);
            if "error" in r {
                msg = str(r["error"]);
            } else {
                _download(str(r["filename"]), str(r["mime"]), str(r["content"]));
                msg = ("summary exported — TRUNCATED, see its notes"
                       if r["truncated"] else "summary exported");
            }
        } except Exception { msg = "export failed"; }
        busy = False;
    }

    def _renamePanel(d: any) -> JsxElement {
        pid = str(d["pid"]);
        return <div key={pid} className="jms-card jms-pcard" style={{"cursor": "default"}}>
            <span className="jms-label">RENAME PROJECT</span>
            <input
                className="jms-input"
                aria-label="new project name"
                value={renameVal}
                placeholder="project name"
                onChange={lambda e: any { renameVal = str(e.target.value); }}
                onKeyDown={lambda e: KeyboardEvent {
                    if e.key == "Enter" { doRename(pid); }
                }}
            />
            <span className="jms-clamp2">
                Display name only. The folder stays {str(d["slug"])} — moving it would break
                saved adapter paths and any run holding it open.
            </span>
            <div className="mt-auto flex items-center gap-2">
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={busy}
                    onClick={lambda e: MouseEvent { doRename(pid); }}
                >{"SAVING…" if busy else "SAVE"}</button>
                <button className="jms-btn" onClick={lambda e: MouseEvent { closeAct(); }}>CANCEL</button>
            </div>
            {if msg {
                <span key="msg" className="jms-flash">{msg}</span>
                skip;
            }}
        </div>;
    }

    def _clonePanel(d: any) -> JsxElement {
        pid = str(d["pid"]);
        hasDs = _hasTrain(expInfo);
        cost = _dsline(expInfo, "train") if (expInfo is None or hasDs) else "no curated rows yet";
        return <div key={pid} className="jms-card jms-pcard" style={{"cursor": "default"}}>
            <span className="jms-label">DUPLICATE PROJECT</span>
            <input
                className="jms-input"
                aria-label="name for the duplicate"
                value={cloneName}
                placeholder="name for the copy"
                onChange={lambda e: any { cloneName = str(e.target.value); }}
            />
            <span className="jms-clamp2">
                Copies the use case, sources and the approved plan. Datasets, adapters
                and run history are NOT copied.
            </span>
            <label className="jms-stat flex items-center gap-2" style={{"cursor": "pointer"}}>
                <input
                    type="checkbox"
                    aria-label="also copy the curated dataset"
                    checked={cloneRows}
                    disabled={not hasDs}
                    onChange={lambda e: any { cloneRows = bool(e.target.checked); }}
                />
                <span>also copy curated rows · {cost}</span>
            </label>
            <div className="mt-auto flex items-center gap-2">
                <button
                    className="jms-btn jms-btn-accent"
                    disabled={busy}
                    onClick={lambda e: MouseEvent { doClone(pid); }}
                >{"CLONING…" if busy else "DUPLICATE"}</button>
                <button className="jms-btn" onClick={lambda e: MouseEvent { closeAct(); }}>CANCEL</button>
            </div>
            {if msg {
                <span key="msg" className="jms-flash">{msg}</span>
                skip;
            }}
        </div>;
    }

    def _exportPanel(d: any) -> JsxElement {
        pid = str(d["pid"]);
        hasDs = _hasTrain(expInfo);
        return <div key={pid} className="jms-card jms-pcard" style={{"cursor": "default"}}>
            <span className="jms-label">EXPORT</span>
            <span className="jms-stat">train · {_dsline(expInfo, "train")}</span>
            <span className="jms-stat">holdout · {_dsline(expInfo, "holdout")}</span>
            <div className="flex flex-wrap items-center gap-1.5">
                <button
                    className="jms-btn"
                    disabled={bool(busy or not hasDs)}
                    onClick={lambda e: MouseEvent { doExportDataset(pid, "train"); }}
                >TRAIN.JSONL</button>
                <button
                    className="jms-btn"
                    disabled={bool(busy or not hasDs)}
                    onClick={lambda e: MouseEvent { doExportDataset(pid, "holdout"); }}
                >HOLDOUT.JSONL</button>
            </div>
            <div className="flex flex-wrap items-center gap-1.5">
                <button
                    className="jms-btn"
                    disabled={busy}
                    onClick={lambda e: MouseEvent { doExportSummary(pid, "md"); }}
                >SUMMARY.MD</button>
                <button
                    className="jms-btn"
                    disabled={busy}
                    onClick={lambda e: MouseEvent { doExportSummary(pid, "json"); }}
                >SUMMARY.JSON</button>
            </div>
            <div className="mt-auto flex items-center gap-2">
                <button className="jms-btn" onClick={lambda e: MouseEvent { closeAct(); }}>CLOSE</button>
            </div>
            {if msg {
                <span key="msg" className="jms-flash">{msg}</span>
                skip;
            }}
        </div>;
    }

    def _card(d: any, i: int) -> JsxElement {
        pid = str(d["pid"]);
        if actId == pid and actMode == "rename" { return _renamePanel({"d": d}); }
        if actId == pid and actMode == "clone" { return _clonePanel({"d": d}); }
        if actId == pid and actMode == "export" { return _exportPanel({"d": d}); }
        rs: any = d["row_stats"];
        raw = str(rs["raw"]) if rs else "0";
        cur = str(rs["curated"]) if rs else "0";
        nsrc = len(list(d["sources"]));
        # ponytail: stays a <div role="button"> rather than a real <button> — it contains
        # nested action <button>s and button-in-button is invalid HTML. Ceiling: the card
        # is one focus stop with its buttons following; no roving-tabindex grid.
        return <div
            key={pid}
            className={"jms-card jms-pcard" + (" reveal stagger-" + str(min(i + 1, 6)))}
            role="button"
            tabIndex={0}
            aria-label={"open project " + str(d["name"])}
            onClick={lambda e: MouseEvent {
                if onOpen is not None { onOpen(pid, str(d["name"])); }
            }}
            onKeyDown={lambda e: KeyboardEvent {
                if e.key == "Enter" or e.key == " " {
                    e.preventDefault();
                    if onOpen is not None { onOpen(pid, str(d["name"])); }
                }
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
                        data-confirm-armed={"1" if confirmId == pid else None}
                        onClick={lambda e: MouseEvent {
                            e.stopPropagation();
                            removeProj(pid);
                        }}
                    >{"SURE?" if confirmId == pid else "DELETE"}</button>
                </div>
                <div className="flex flex-wrap items-center gap-1.5">
                    <button
                        className="jms-btn"
                        aria-label={"rename " + str(d["name"])}
                        onClick={lambda e: MouseEvent {
                            e.stopPropagation();
                            openAct(pid, "rename", d);
                        }}
                    >RENAME</button>
                    <button
                        className="jms-btn"
                        aria-label={"duplicate " + str(d["name"])}
                        onClick={lambda e: MouseEvent {
                            e.stopPropagation();
                            openAct(pid, "clone", d);
                        }}
                    >CLONE</button>
                    <button
                        className="jms-btn"
                        aria-label={"export " + str(d["name"])}
                        onClick={lambda e: MouseEvent {
                            e.stopPropagation();
                            openAct(pid, "export", d);
                        }}
                    >EXPORT</button>
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
                    aria-label="project name"
                    value={newName}
                    placeholder="project name"
                    onChange={lambda e: any { newName = str(e.target.value); }}
                />
                <textarea
                    className="jms-textarea flex-1"
                    aria-label="project use case"
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
            role="button"
            tabIndex={0}
            aria-label="new project"
            onClick={lambda e: MouseEvent { _openForm(); }}
            onKeyDown={lambda e: KeyboardEvent {
                if e.key == "Enter" or e.key == " " { e.preventDefault(); _openForm(); }
            }}
        >
            <span className="jms-display" style={{"fontSize": "28px"}}>+</span>
            <span className="jms-label">NEW PROJECT</span>
        </div>;
    }

    def _onboarding -> JsxElement {
        return <div className="min-h-0 flex-1 overflow-y-auto p-6">
            <div className="mx-auto flex flex-col gap-5" style={{"maxWidth": "760px"}}>
                <div className="flex flex-col gap-2">
                    <span className="jms-label">GETTING STARTED</span>
                    <span className="jms-display" style={{"fontSize": "38px", "lineHeight": "1.05"}}>
                        A PROJECT TURNS YOUR CODE INTO A FINETUNED MODEL
                    </span>
                    <span className="jms-hero-sub" style={{"maxWidth": "62ch"}}>
                        Point a project at a folder of code or docs. It synthesizes a training
                        dataset from them, you curate it, and it finetunes a LoRA adapter you can
                        score and chat with. Everything stays in one project folder on this machine.
                    </span>
                </div>

                <div className="jms-section flex flex-col gap-3">
                    <span className="jms-label">THE FIVE STAGES</span>
                    {for s in ONBOARD {
                        <div key={str(s["id"])} className="flex items-start gap-3">
                            <span className="jms-mono-dim" style={{"minWidth": "16px"}}>{str(s["n"])}</span>
                            <div className="flex min-w-0 flex-col gap-1">
                                <span className="jms-label">{str(s["id"])}</span>
                                <span className="jms-stat">{str(s["t"])}</span>
                            </div>
                        </div>
                    }}
                </div>

                <div className="jms-section flex flex-col gap-3">
                    <span className="jms-label">WHAT YOU'LL NEED</span>
                    {for n in NEEDS {
                        <div key={n} className="flex items-start gap-3">
                            <span className="jms-mono-dim" style={{"minWidth": "16px"}}>·</span>
                            <span className="jms-stat">{n}</span>
                        </div>
                    }}
                </div>

                <div className="flex items-center gap-3">
                    <button
                        className="jms-btn jms-btn-accent"
                        onClick={lambda e: MouseEvent { _openForm(); }}
                    >+ NEW PROJECT</button>
                    <span className="jms-mono-dim">a project is just a folder — deleting one never touches your sources</span>
                </div>
            </div>
        </div>;
    }

    if loading {
        return <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden p-6">
            <span className="jms-label">LOADING…</span>
        </div>;
    }

    if loadErr {
        return <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 overflow-hidden p-6">
            <span className="jms-label" style={{"color": "var(--jms-danger)"}}>{loadErr}</span>
            <button className="jms-btn" onClick={lambda e: MouseEvent { loading = True; load(); }}>RETRY</button>
        </div>;
    }

    if len(rows) == 0 and not creating {
        return _onboarding();
    }

    shown = _ordered([d for d in rows if _matches(d, query.strip().lower())], sortBy);

    return <div className="min-h-0 flex-1 overflow-y-auto p-6">
        <div className="mb-4 flex flex-wrap items-center gap-2">
            <input
                className="jms-input"
                type="search"
                aria-label="search projects by name or use case"
                placeholder="search name or use case…"
                value={query}
                style={{"maxWidth": "300px"}}
                onChange={lambda e: any { applyQuery(str(e.target.value)); }}
            />
            <select
                className="jms-input"
                aria-label="sort projects"
                value={sortBy}
                onChange={lambda e: any { applySort(str(e.target.value)); }}
            >
                <option value="recent">MOST RECENT</option>
                <option value="name">NAME A→Z</option>
            </select>
            <span className="jms-mono-dim">{str(len(shown))} of {str(len(rows))}</span>
            {if query {
                <button
                    key="clr"
                    className="jms-btn"
                    onClick={lambda e: MouseEvent { applyQuery(""); }}
                >CLEAR</button>
                skip;
            }}
        </div>
        {if len(shown) == 0 and not creating {
            <div key="nomatch" className="flex flex-col items-center gap-3 p-10">
                <span key="nm1" className="jms-label">NO PROJECT MATCHES THAT SEARCH</span>
                <button
                    key="nm2"
                    className="jms-btn"
                    onClick={lambda e: MouseEvent { applyQuery(""); }}
                >CLEAR SEARCH</button>
            </div>
            skip;
        }}
        <div className="jms-grid">
            {_newCard()}
            {# _card takes params → compiles to a props-component; call with a props dict, not positionally
             [_card({"d": d, "i": i}) for (i, d) in enumerate(shown)]}
        </div>
    </div>;
}
