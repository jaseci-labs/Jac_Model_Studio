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

# Purple ramp for the composition bar (light→dark, largest category first).
glob SHADES: list[str] = ["#e8dcf7", "#d3bdec", "#b89ce8", "#9a78d4", "#7d5cba", "#5f4499", "#48317a"];

def:pub CptSftData -> JsxElement {
    has stats: any = None,
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1;

    async def _fetch(p: str, off: int) -> None {
        r = await cptsft_rows(p, off, 25);
        rows = list(r["rows"]);
        total = int(r["total"]);
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

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="section-header flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">DATA · CPT-SFT RELEASE (read-only)</span>
            <span className="micro-label text-muted-foreground/80">04-cpt-sft/dataset/fresh</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            {_composition()}
            {_holdouts()}
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
