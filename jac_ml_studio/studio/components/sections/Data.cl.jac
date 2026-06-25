"""DATA section — dataset stats + JSONL browser with row detail.

Ports ui/components/sections/data/{data-section,stats-tiles,dataset-browser,row-detail}.
Read-only over the preview-allowed files (data.sv.jac). Builder pipeline (subprocess)
lands with the jobs module.
"""

sv import from ...data { dataset_stats, dataset_files, dataset_rows, FileRefView, DataRowView }
import from ..shared.StatTile { StatTile }

def:pub Data -> JsxElement {
    has stats: any = None,
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1;

    # `p`/`off` are passed explicitly — reading the `path`/`offset` state right
    # after setting it returns the stale value (React state writes are async).
    async def _fetch(p: str, off: int) -> None {
        limit = 25;
        r = await dataset_rows(p, off, limit);
        rows = list(r["rows"]);
        total = int(r["total"]);
    }

    async def openFile(p: str) -> None {
        path = p;
        offset = 0;
        expanded = -1;
        await _fetch(p, 0);
    }

    async can with entry {
        stats = await dataset_stats();
        fs = await dataset_files();
        files = fs;
        if len(fs) > 0 {
            await openFile(str(fs[0].path));
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
            return <span className="micro-label">loading…</span>;
        }
        sp: any = stats["splits"];
        return <div className="grid grid-cols-6 gap-3">
            <StatTile label="SFT.TOTAL" value={str(stats["sft_total"])} sub="idiomatic + auto" dim={False} />
            <StatTile label="DPO.PAIRS" value={str(stats["dpo_pairs"])} sub="preference" dim={False} />
            <StatTile label="MLX.SFT" value={str(sp["mlx_train"])} sub={"valid " + str(sp["mlx_valid"])} dim={False} />
            <StatTile label="MLX.DPO" value={str(sp["dpo_train"])} sub={"valid " + str(sp["dpo_valid"])} dim={False} />
            <StatTile label="HOLDOUT" value={str(sp["holdout"])} sub="function" dim={False} />
            <StatTile label="HOLDOUT.GRAPH" value={str(sp["graph_holdout"])} sub="graph" dim={False} />
        </div>;
    }

    def _detail(row: any) -> JsxElement {
        return <div className="mt-2 flex flex-col gap-2 rounded-md border border-neutral-800 bg-[#0d0d0d] p-3">
            {row["prompt"] and <div><div className="micro-label mb-1">PROMPT</div><pre className="whitespace-pre-wrap font-mono text-[11px] text-neutral-400">{row["prompt"]}</pre></div>}
            {row["python"] and <div><div className="micro-label mb-1">PYTHON</div><pre className="overflow-x-auto rounded border border-neutral-800 bg-[#121212] p-2 font-mono text-[11px] text-neutral-300">{row["python"]}</pre></div>}
            {row["jac"] and <div><div className="micro-label mb-1">JAC</div><pre className="overflow-x-auto rounded border border-neutral-800 bg-[#121212] p-2 font-mono text-[11px] text-neutral-300">{row["jac"]}</pre></div>}
            {row["chosen"] and <div><div className="micro-label mb-1">CHOSEN.JAC</div><pre className="overflow-x-auto rounded border border-neutral-800 bg-[#121212] p-2 font-mono text-[11px] text-neutral-300">{row["chosen"]}</pre></div>}
            {row["rejected"] and <div><div className="micro-label mb-1">REJECTED.JAC</div><pre className="overflow-x-auto rounded border border-neutral-800 bg-[#121212] p-2 font-mono text-[11px] text-neutral-500">{row["rejected"]}</pre></div>}
            {row["raw"] and <div><div className="micro-label mb-1">RAW</div><pre className="overflow-x-auto font-mono text-[11px] text-neutral-500">{row["raw"]}</pre></div>}
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">DATA</span>
            <span className="micro-label text-neutral-600">DATA.PIPE</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}

            {#* file picker pills *#}
            <div className="flex flex-wrap gap-2">
                {for f in files {
                    <button
                        key={str(f.path)}
                        onClick={lambda e: MouseEvent { openFile(str(f.path)); }}
                        className={"rounded-full border px-3 py-1 font-mono text-[11px] " + (
                            "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if str(f.path) == path
                            else "border-neutral-800 text-neutral-500 hover:text-neutral-300"
                        )}
                    >
                        {f.label} <span className="text-neutral-600">{str(f.count)}</span>
                    </button>
                }}
            </div>

            {#* rows table *#}
            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">ROWS · {str(offset)}–{str(offset + len(rows))} / {str(total)}</span>
                <div className="grid grid-cols-[40px_1.4fr_64px_64px_1fr_2fr] gap-2 border-b border-neutral-800 pb-1 micro-label">
                    <span>#</span><span>NAME</span><span>KIND</span><span>DIFF</span><span>SOURCE</span><span>PREVIEW</span>
                </div>
                {for row in rows {
                    <div key={str(row["idx"])}>
                        <div
                            onClick={lambda e: MouseEvent { expanded = -1 if expanded == int(row["idx"]) else int(row["idx"]); }}
                            className="grid cursor-pointer grid-cols-[40px_1.4fr_64px_64px_1fr_2fr] gap-2 border-b border-neutral-900 py-1.5 font-mono text-[11px] text-neutral-400 hover:bg-[#111]"
                        >
                            <span className="text-neutral-600">{str(row["idx"])}</span>
                            <span className="truncate text-neutral-200">{row["name"]}</span>
                            <span className="text-neutral-500">{row["kind"]}</span>
                            <span className="text-neutral-500">{row["difficulty"]}</span>
                            <span className="truncate text-neutral-500">{row["source"]}</span>
                            <span className="truncate text-neutral-500">{row["preview"]}</span>
                        </div>
                        {expanded == row["idx"] and _detail(row)}
                    </div>
                }}
                <div className="mt-2 flex items-center gap-2">
                    <button onClick={lambda e: MouseEvent { prevPage(); }} disabled={offset <= 0} className="micro-label rounded border border-neutral-800 px-2 py-1 disabled:opacity-30 hover:text-neutral-200">◂ PREV</button>
                    <button onClick={lambda e: MouseEvent { nextPage(); }} disabled={offset + len(rows) >= total} className="micro-label rounded border border-neutral-800 px-2 py-1 disabled:opacity-30 hover:text-neutral-200">NEXT ▸</button>
                </div>
            </div>
        </div>
    </div>;
}
