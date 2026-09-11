"""DATA section — dataset browser + add-examples.

Read-only browser over the dataset files listed in studio.workspace.toml [data]
(data.sv.jac); add_examples appends to JMS-owned files under
<data_root>/examples/. Rows render via the shared RowBrowser. Stat tiles are
driven by whatever named splits the toml declares — no hard-coded file keys.
"""

sv import from ....server.core.data { dataset_stats, dataset_files, dataset_rows, add_examples, FileRefView, DataRowView }
import from ..shared.StatTile { StatTile }
import from ..shared.LogView { LogView }
import from ..shared.Field { Segmented }
import from ..shared.RowBrowser { RowBrowser }

def:pub Data -> JsxElement {
    has stats: any = None,
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1,
        addTarget: str = "sft",
        addText: str = "",
        addResult: any = None,
        addBusy: bool = False,
        loadErr: str = "";

    # `p`/`off` are passed explicitly — reading the state right after setting it
    # returns the stale value (React state writes are async).
    async def _fetch(p: str, off: int) -> None {
        try {
            r = await dataset_rows(p, off, 25);
            rows = list(r["rows"]);
            total = int(r["total"]);
        } except Exception as e {
            rows = [];
            total = 0;
            loadErr = "rows failed · " + str(e);
        }
    }

    async def openFile(p: str) -> None {
        path = p;
        offset = 0;
        expanded = -1;
        await _fetch(p, 0);
    }

    def toggleRow(idx: int) -> None {
        expanded = -1 if expanded == idx else idx;
    }

    async def submitExamples() -> None {
        addBusy = True;
        addResult = None;
        try {
            r = await add_examples(target=addTarget, jsonl=addText);
            addResult = r;
            if int(r["added"]) > 0 {
                stats = await dataset_stats();
                fs = await dataset_files();
                files = fs;
            }
        } except Exception as e {
            loadErr = "append failed · " + str(e);
        }
        # Always released: a throw above used to strand addBusy=True, which
        # disables APPEND forever with no message.
        addBusy = False;
    }

    async can with entry {
        try {
            stats = await dataset_stats();
            fs = await dataset_files();
            files = fs;
            if len(fs) > 0 {
                await openFile(str(fs[0].path));
            }
        } except Exception as e {
            # Without this the async IIFE this block compiles to rejects
            # unhandled and `stats` stays None — rendering "loading…" forever,
            # indistinguishable from a slow load.
            loadErr = "dataset load failed · " + str(e);
        }
    }

    async def prevPage -> None {
        if offset > 0 {
            noff = max(0, offset - 25);
            offset = noff;
            expanded = -1;
            await _fetch(path, noff);
        }
    }

    async def nextPage -> None {
        if offset + len(rows) < total {
            noff = offset + 25;
            offset = noff;
            expanded = -1;
            await _fetch(path, noff);
        }
    }

    def _tiles() -> JsxElement {
        if not stats {
            if loadErr {
                return <span className="micro-label" style={{"color": "var(--danger)"}}>{loadErr}</span>;
            }
            return <span className="micro-label">loading…</span>;
        }
        sp: list = list(stats["splits"]);
        return <div className="grid grid-cols-3 gap-3 lg:grid-cols-6">
            <StatTile label="SFT.TOTAL" value={str(stats["sft_total"])} sub="examples" dim={False} />
            {for sx in sp {
                <StatTile key={str(sx["name"])} label={str(sx["name"]).upper()} value={str(sx["count"])} sub="rows" dim={False} />
            }}
        </div>;
    }

    def _addExamples() -> JsxElement {
        ph = ('one JSON object per line · sft: {"messages":[...]}' if addTarget == "sft"
            else 'one JSON object per line · dpo: {"prompt","chosen","rejected"}');
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">ADD.EXAMPLES</span>
            <div className="flex flex-col gap-3">
                <Segmented options={["sft", "dpo"]} value={addTarget} onSet={lambda (v: str) { addTarget = v; }} />
                <textarea
                    rows={6}
                    aria-label={"new " + addTarget + " examples (JSONL)"}
                    value={addText}
                    onChange={lambda (e: ChangeEvent) { addText = e.target.value; }}
                    placeholder={ph}
                    className="exp-input resize-none"
                ></textarea>
                <button
                    disabled={addBusy or (not addText.strip())}
                    onClick={lambda (e: MouseEvent) { submitExamples(); }}
                    className="micro-label self-start rounded border border-input px-3 py-1.5 text-foreground/80 transition-colors hover:border-ring hover:text-foreground disabled:cursor-not-allowed disabled:opacity-30"
                >
                    {"APPENDING…" if addBusy else "APPEND"}
                </button>
                {addResult and <div className="flex flex-col gap-2">
                    <div className="stat-line">added {str(addResult["added"])} · total {str(addResult["total"])}</div>
                    {(len(list(addResult["errors"])) > 0) and <LogView text={"\n".join([str(x) for x in list(addResult["errors"])])} maxH="8rem" />}
                </div>}
            </div>
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="section-header flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">DATA · DATASETS</span>
        </div>
        {loadErr and <div key="dataerr" className="border-b border-border px-4 py-1.5">
            <span className="stat-line" style={{"color": "var(--danger)"}}>{loadErr}</span>
        </div>}
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            <div className="flex flex-col gap-4">
                <RowBrowser
                    files={files} path={path} rows={rows} offset={offset}
                    total={total} expanded={expanded}
                    onOpen={openFile} onToggle={toggleRow}
                    onPrev={prevPage} onNext={nextPage}
                />
                {_addExamples()}
            </div>
        </div>
    </div>;
}
