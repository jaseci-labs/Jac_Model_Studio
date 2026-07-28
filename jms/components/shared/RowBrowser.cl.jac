"""Shared dataset row browser: file chips + row table + expand-detail + pager.

Props-component extracted from Data.cl.jac so the 01 (core), 02 (RL) and 03 (CPT)
DATA sections all render identical browsers over `DataRowView` rows. The parent
owns the fetch state (files/path/rows/offset/total/expanded) and the handlers;
this component renders and calls back.

The ONE piece of local state is the search box (`has q`). It is deliberately not
a prop: the parent's pager is SERVER-paged (useRowPager fetches
`fetch_rows(path, offset)`, one page at a time), so a query here can only ever
match the rows already fetched. The UI says exactly that — "this page only",
with the loaded/total counts — instead of implying a dataset-wide search. The
server-side fix (a `q` argument on data.sv.jac's row endpoints) is in the report.

`setQ` is the only useState setter in the file; no handler here may be named that.
"""

import from .CodeBlock { CodeBlock }

glob KIND_LABEL: dict = {
    "sft": "SFT", "dpo": "DPO", "holdout": "HOLD", "raw": "RAW", "rltask": "RL",
    "doc": "DOC", "code": "CODE", "blog": "BLOG", "paper": "PAPER", "rehearsal": "REHRS"
};

"""One expanded row's detail: structured code panes (sft/dpo/holdout/rltask) OR a
raw text block (cpt corpus rows + plain-json rows). Called with a props dict."""
def:pub RowDetail(row: any) -> JsxElement {
    kind = str(row["kind"]);
    structured = row["prompt"] or row["python"] or row["jac"] or row["chosen"];
    return <div className="exp-panel p-3 space-y-2">
        {row["prompt"] and <div>
            <div className="micro-label mb-1 text-muted-foreground/80">PROMPT</div>
            <pre className="whitespace-pre-wrap font-mono text-xs text-muted-foreground leading-relaxed">{row["prompt"]}</pre>
        </div>}
        {row["python"] and <CodeBlock label="" code={str(row["python"])} lang="python" />}
        {(row["jac"] and kind != "dpo") and <CodeBlock label="" code={str(row["jac"])} lang="jac" />}
        {(kind == "dpo" and row["chosen"]) and <CodeBlock label="CHOSEN.JAC" code={str(row["chosen"])} lang="jac" />}
        {(kind == "dpo" and row["rejected"]) and <CodeBlock label="REJECTED.JAC" code={str(row["rejected"])} lang="jac" />}
        {(row["raw"] and not structured) and <pre className="max-h-[32rem] overflow-y-auto whitespace-pre-wrap break-words font-mono text-xs text-muted-foreground leading-relaxed">{row["raw"]}</pre>}
    </div>;
}

"""Every text a row shows anywhere (table columns + the expanded detail panes),
lower-cased into one haystack. `or ""` before `str()` because a missing JSON key
stringifies to the literal "undefined" and would then match a search for "und".
1-arg `.find` only — the 2/3-arg forms transpile but throw at runtime."""
glob SEARCH_KEYS: list = [
    "name", "kind", "difficulty", "source", "preview",
    "prompt", "python", "jac", "chosen", "rejected", "raw"
];

def _haystack(row: any) -> str {
    s = str(row["idx"]) + " ";
    for k in SEARCH_KEYS { s = s + str(row[k] or "") + " "; }
    return s.lower();
}

"""Rows of *rows* whose haystack contains the already-lower-cased *needle*.

# ponytail: substring match, recomputed every render, no memo and no index.
# Ceiling — one page is <=25 rows, and an empty needle short-circuits before any
# string work, so the scan only runs while someone is actually typing. Fuzzy
# ranking, regex, or field-scoped queries (kind:dpo) are NOT supported; the moment
# search needs to cover the whole file it has to move server-side anyway."""
def _searched(rows: list, needle: str) -> list {
    if not needle { return rows; }
    out: list = [];
    for r in rows {
        if _haystack(r).find(needle) >= 0 { out.append(r); }
    }
    return out;
}

"""File chips + search + row table + pager. Parent supplies state + callbacks:
onOpen(path), onToggle(idx), onPrev(), onNext()."""
def:pub RowBrowser(
    files: list, path: str, rows: list, offset: int, total: int, expanded: int,
    onOpen: any, onToggle: any, onPrev: any, onNext: any, label: str = "DATASET.BROWSER"
) -> JsxElement {
    has q: str = "";

    # Pager math stays on the FULL page (`rows`), never on `shown` — searching must
    # not make PREV/NEXT or the "x to y of n" counter lie.
    canPrev = offset > 0;
    canNext = offset + len(rows) < total;
    needle = q.strip().lower();
    shown = _searched(rows, needle);
    partial = total > len(rows);
    return <div className="exp-panel p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-background px-2">{label}</span>
        <div className="mb-3 flex flex-wrap gap-1">
            {(len(files) == 0) and <span className="stat-line">no files</span>}
            {for f in files {
                <button
                    key={str(f.path)}
                    onClick={lambda (e: MouseEvent) { onOpen(str(f.path)); }}
                    className={"exp-chip !px-2.5 !py-0.5 !text-[10px] " + (
                        "exp-chip-active" if str(f.path) == path else ""
                    )}
                >
                    {f.label} {str(f.count)}
                </button>
            }}
        </div>
        {path and <div>
            <div className="mb-2 flex flex-wrap items-center gap-2">
                <input
                    className="exp-input !h-7 !py-0 font-mono !text-[11px]"
                    style={{"width": "240px"}}
                    type="search"
                    aria-label="search the loaded rows"
                    placeholder="search this page…"
                    value={q}
                    onChange={lambda (e: any) { q = str(e.target.value); }}
                />
                {needle and <span className="stat-line">{str(len(shown))} / {str(len(rows))} match</span>}
                {needle and <button
                    className="exp-chip !px-2.5 !py-0.5 !text-[10px]"
                    onClick={lambda (e: MouseEvent) { q = ""; }}
                >CLEAR</button>}
                {(needle and partial) and <span className="stat-line text-muted-foreground/70">
                    searching this page only — {str(len(rows))} of {str(total)} rows loaded
                </span>}
            </div>
            <div className="overflow-x-auto">
                <div className="mb-1 grid grid-cols-[2rem_1fr_3rem_3rem_5rem_1fr] gap-2">
                    <span className="micro-label">#</span>
                    <span className="micro-label">NAME</span>
                    <span className="micro-label">KIND</span>
                    <span className="micro-label">DIFF</span>
                    <span className="micro-label">SOURCE</span>
                    <span className="micro-label">PREVIEW</span>
                </div>
                {(len(rows) == 0) and <div className="stat-line py-4 text-center">empty</div>}
                {(len(rows) > 0 and len(shown) == 0) and <div className="stat-line py-4 text-center">
                    no row on this page matches "{q.strip()}" — try another page
                </div>}
                {for row in shown {
                    <div key={str(row["idx"])}>
                        <div
                            role="button"
                            tabIndex={0}
                            aria-expanded={expanded == int(row["idx"])}
                            onClick={lambda (e: MouseEvent) { onToggle(int(row["idx"])); }}
                            onKeyDown={lambda (e: KeyboardEvent) {
                                if e.key == "Enter" or e.key == " " {
                                    e.preventDefault();
                                    onToggle(int(row["idx"]));
                                }
                            }}
                            className="grid cursor-pointer grid-cols-[2rem_1fr_3rem_3rem_5rem_1fr] gap-2 rounded-sm px-0.5 py-1 font-mono text-xs hover:bg-secondary"
                        >
                            <span className="text-muted-foreground/80">{str(row["idx"])}</span>
                            <span className="truncate text-foreground/80">{row["name"]}</span>
                            <span className="text-muted-foreground">{str(KIND_LABEL[str(row["kind"])]) if str(row["kind"]) in KIND_LABEL else str(row["kind"])}</span>
                            <span className="text-muted-foreground">{row["difficulty"]}</span>
                            <span className="truncate text-muted-foreground">{row["source"]}</span>
                            <span className="truncate text-muted-foreground/80">{row["preview"]}</span>
                        </div>
                        {(expanded == int(row["idx"])) and <div className="mb-1">{RowDetail({"row": row})}</div>}
                    </div>
                }}
            </div>
            {(total > 0) and <div className="mt-3 flex items-center justify-center gap-3 stat-line">
                <button disabled={not canPrev} onClick={lambda (e: MouseEvent) { onPrev(); }} className="disabled:opacity-30 hover:text-foreground transition-colors">← PREV</button>
                <span>{str(offset + 1)} to {str(offset + len(rows))} of {str(total)}</span>
                <button disabled={not canNext} onClick={lambda (e: MouseEvent) { onNext(); }} className="disabled:opacity-30 hover:text-foreground transition-colors">NEXT →</button>
            </div>}
        </div>}
        {(not path) and <div className="stat-line py-6 text-center">select a file above</div>}
    </div>;
}
