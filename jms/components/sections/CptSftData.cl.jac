"""DATA section (workspace 04 CPT-SFT) — frozen SFT/DPO release browser.

Reads the 04-cpt-sft dataset-generation output via cptsft.sv.jac: stat tiles
(SFT total / DPO pairs / holdouts) + a per-category composition bar (plain divs,
purple ramp — one stacked bar doesn't need recharts) + a RowBrowser over the
frozen releases and carved holdouts. Browse-only: the pool is frozen, no builder.
Follows Data.cl.jac's message/pair-shaped shape (the closer match), .exp-* classes.
"""

sv import from ...cptsft { cptsft_stats, cptsft_files, cptsft_rows }
import from ..shared.StatTile { StatTile }
import from ..shared.RowBrowser { RowBrowser }
import from ..shared.Field { Segmented }

# Purple ramp for the composition bar (light→dark, largest category first).
glob SHADES: list[str] = ["#e8dcf7", "#d3bdec", "#b89ce8", "#9a78d4", "#7d5cba", "#5f4499", "#48317a"];

def:pub CptSftData -> JsxElement {
    has stats: any = None,
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1,
        category: str = "all",
        axis: str = "all";

    # `p`/`off`/`cat`/`ax` passed explicitly — reading state right after setting
    # it returns the stale value (React writes are async). Only the filter that
    # matches the open file is applied server-side ("" = no filter); the SFT
    # category never leaks onto the DPO file and vice-versa.
    async def _fetch(p: str, off: int, cat: str, ax: str) -> None {
        catArg = cat if (("sft_train.jsonl" in p) and cat != "all") else "";
        axArg = ax if (("dpo_train.jsonl" in p) and ax != "all") else "";
        r = await cptsft_rows(p, off, 25, catArg, axArg);
        rows = list(r["rows"]);
        total = int(r["total"]);
    }

    async def openFile(p: str) -> None {
        path = p;
        offset = 0;
        expanded = -1;
        await _fetch(p, 0, category, axis);
    }

    async def pickCategory(c: str) -> None {
        category = c;
        offset = 0;
        expanded = -1;
        await _fetch(path, 0, c, axis);
    }

    async def pickAxis(a: str) -> None {
        axis = a;
        offset = 0;
        expanded = -1;
        await _fetch(path, 0, category, a);
    }

    def toggleRow(idx: int) -> None {
        expanded = -1 if expanded == idx else idx;
    }

    async def prevPage -> None {
        if offset > 0 {
            noff = max(0, offset - 25);
            offset = noff;
            expanded = -1;
            await _fetch(path, noff, category, axis);
        }
    }

    async def nextPage -> None {
        if offset + len(rows) < total {
            noff = offset + 25;
            offset = noff;
            expanded = -1;
            await _fetch(path, noff, category, axis);
        }
    }

    async can with entry {
        s = await cptsft_stats();
        # tag each category with its ramp shade up front (avoids index math in JSX .map)
        cats = list(s["categories"]);
        idx = 0;
        for c in cats {
            c["shade"] = SHADES[idx % len(SHADES)];
            idx += 1;
        }
        stats = s;
        fs = await cptsft_files();
        files = fs;
        if len(list(fs)) > 0 {
            await openFile(str(fs[0].path));
        }
    }

    def _tiles() -> JsxElement {
        if not stats {
            return <span className="micro-label">loading…</span>;
        }
        return <div className="grid grid-cols-3 gap-3 lg:grid-cols-6">
            <StatTile label="SFT.TOTAL" value={str(stats["sft_total"])} sub="examples" dim={False} />
            <StatTile label="DPO.PAIRS" value={str(stats["dpo_pairs"])} sub="pairs" dim={False} />
            <StatTile label="HOLDOUTS" value={str(stats["holdout_total"])} sub="eval rows" dim={False} />
            <StatTile label="CATEGORIES" value={str(len(list(stats["categories"])))} sub="task types" dim={False} />
            <StatTile label="RELEASE" value="fresh" sub="frozen pool" dim={False} />
            <StatTile label="FORMAT" value="SFT+DPO" sub="messages / pairs" dim={False} />
        </div>;
    }

    def _composition() -> JsxElement {
        if not stats {
            return <span></span>;
        }
        cats: list = list(stats["categories"]);
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">SFT.CATEGORY.COMPOSITION</span>
            <div className="flex h-4 w-full overflow-hidden rounded-sm">
                {for c in cats {
                    <div
                        key={str(c["name"])}
                        style={{"width": str(int(c["pct"]) / 10.0) + "%", "background": str(c["shade"])}}
                        title={str(c["name"]) + " " + str(c["count"]) + " (" + str(int(c["pct"]) / 10.0) + "%)"}
                    ></div>
                }}
            </div>
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1">
                {for c in cats {
                    <span key={str(c["name"])} className="stat-line flex items-center gap-1.5 text-muted-foreground">
                        <span style={{"display": "inline-block", "width": 8, "height": 8, "background": str(c["shade"])}}></span>
                        {str(c["name"])} {str(c["count"])} · {str(int(c["pct"]) / 10.0)}%
                    </span>
                }}
            </div>
        </div>;
    }

    def _holdouts() -> JsxElement {
        if not stats {
            return <span></span>;
        }
        hs: list = list(stats["holdouts"]);
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">EVAL.HOLDOUTS · shared/holdouts</span>
            <div className="flex flex-wrap gap-x-4 gap-y-1">
                {for h in hs {
                    <span key={str(h["name"])} className="stat-line text-muted-foreground">
                        {str(h["name"])} <span className="text-foreground">{str(h["count"])}</span>
                    </span>
                }}
            </div>
        </div>;
    }

    # Row-level filter picker — a CATEGORY Segmented over the SFT release, an AXIS
    # Segmented over the DPO release (options = ["all"] + stat breakdown names).
    # Only the picker matching the open file shows; other files (holdouts) get none.
    def _filters() -> JsxElement {
        if not stats {
            return <span></span>;
        }
        if "sft_train.jsonl" in path {
            opts: list = ["all"];
            for c in list(stats["categories"]) {
                opts.append(str(c["name"]));
            }
            return <div className="flex flex-wrap items-center gap-2">
                <span className="micro-label text-muted-foreground/80">CATEGORY</span>
                <Segmented options={opts} value={category} onSet={lambda v: str { pickCategory(v); }} />
            </div>;
        }
        if "dpo_train.jsonl" in path {
            aopts: list = ["all"];
            for a in list(stats["axes"]) {
                aopts.append(str(a["name"]));
            }
            return <div className="flex flex-wrap items-center gap-2">
                <span className="micro-label text-muted-foreground/80">AXIS</span>
                <Segmented options={aopts} value={axis} onSet={lambda v: str { pickAxis(v); }} />
            </div>;
        }
        return <span></span>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="section-header flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">DATA · CPT-SFT RELEASE (read-only)</span>
            <span className="micro-label text-muted-foreground/80">04-cpt-sft/dataset/fresh</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            {_composition()}
            {_holdouts()}
            {_filters()}
            <RowBrowser
                files={files} path={path} rows={rows} offset={offset}
                total={total} expanded={expanded}
                onOpen={openFile} onToggle={toggleRow}
                onPrev={prevPage} onNext={nextPage}
            />
            <div className="stat-line text-muted-foreground/70">source: model-experiments/04-cpt-sft/dataset</div>
        </div>
    </div>;
}
