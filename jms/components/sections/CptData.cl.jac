"""DATA section (workspace 03 CPT) — continual-pretrain corpus browser.

Reads the CPT dataset built by model-experiments/03-new/cpt_build/build_cpt.py via cpt.sv.jac:
manifest stat tiles + a token-composition bar (plain divs, grayscale ramp — one
stacked bar doesn't need recharts) + the code-gate table + a RowBrowser over the
5 raw per-source files and the 2 packed splits.
"""

sv import from ...cpt { cpt_manifest, cpt_files, cpt_rows }
import from ..shared.StatTile { StatTile }
import from ..shared.Field { Segmented }
import from ..shared.RowBrowser { RowBrowser }

# Grayscale ramp for the composition bar (light→dark, ordered like SRC_ORDER).
glob SHADES: list[str] = ["#ededed", "#b8b8b8", "#888888", "#5a5a5a", "#3a3a3a"];

def _k(n: int) -> str {
    # compact token count: 1970952 -> "1.97M", 64451 -> "64.5K"
    if n >= 1000000 {
        whole = n // 1000000;
        frac = (n % 1000000) // 10000;
        return str(whole) + "." + (("0" + str(frac))[-2:]) + "M";
    }
    if n >= 1000 {
        whole = n // 1000;
        frac = (n % 1000) // 100;
        return str(whole) + "." + str(frac) + "K";
    }
    return str(n);
}

def:pub CptData -> JsxElement {
    has man: any = None,
        cptSource: str = "all",
        sourceOpts: list = ["all"],
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1;

    async def _fetch(p: str, off: int) -> None {
        r = await cpt_rows(p, off, 25);
        rows = list(r["rows"]);
        total = int(r["total"]);
    }

    # `src` passed explicitly — reading cptSource right after setting it returns
    # the stale value (React writes are async), same as RlData._loadSource.
    async def _loadSource(src: str) -> None {
        fs = await cpt_files(src);
        files = fs;
        expanded = -1;
        offset = 0;
        if len(list(fs)) > 0 {
            path = str(fs[0].path);
            await _fetch(str(fs[0].path), 0);
        } else {
            path = ""; rows = []; total = 0;
        }
    }

    async def switchSource(s: str) -> None {
        cptSource = s;
        await _loadSource(s);
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
        m = await cpt_manifest();
        # tag each source with its ramp shade up front so the render loops never
        # need an index (enumerate/.index() are awkward in the JSX .map() compile).
        opts: list = ["all"];
        if m["ok"] {
            srcs = list(m["sources"]);
            idx = 0;
            for s in srcs {
                s["shade"] = SHADES[idx % len(SHADES)];
                opts.append(str(s["name"]));
                idx += 1;
            }
        }
        man = m;
        sourceOpts = opts;
        await _loadSource(cptSource);
    }

    def _tiles() -> JsxElement {
        if not man or not man["ok"] {
            return <span className="micro-label">loading…</span>;
        }
        srcs: list = list(man["sources"]);
        pk = man["packed"];
        return <div className="grid grid-cols-3 gap-3 lg:grid-cols-6">
            <StatTile label="TOTAL.TOKENS" value={_k(int(man["total_tokens"]))} sub="all sources" dim={False} />
            {for s in srcs {
                <StatTile key={str(s["name"])} label={str(s["name"]).upper()} value={_k(int(s["tokens"]))} sub={str(s["rows"]) + " rows · " + str(s["windows"]) + " win"} dim={False} />
            }}
        </div>;
    }

    def _composition() -> JsxElement {
        if not man or not man["ok"] {
            return <span></span>;
        }
        srcs: list = list(man["sources"]);
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">TOKEN.COMPOSITION</span>
            <div className="flex h-4 w-full overflow-hidden rounded-sm">
                {for s in srcs {
                    <div
                        key={str(s["name"])}
                        style={{"width": str(int(s["pct"]) / 10.0) + "%", "background": str(s["shade"])}}
                        title={str(s["name"]) + " " + str(int(s["pct"]) / 10.0) + "%"}
                    ></div>
                }}
            </div>
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1">
                {for s in srcs {
                    <span key={str(s["name"])} className="stat-line flex items-center gap-1.5 text-muted-foreground">
                        <span style={{"display": "inline-block", "width": 8, "height": 8, "background": str(s["shade"])}}></span>
                        {str(s["name"])} {str(int(s["pct"]) / 10.0)}%
                    </span>
                }}
            </div>
        </div>;
    }

    def _gate() -> JsxElement {
        if not man or not man["ok"] {
            return <span></span>;
        }
        gate: list = list(man["gate"]);
        decon: list = list(man["decontam"]);
        dropped = 0;
        for d in decon { dropped += int(d["dropped"]); }
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">CODE.GATE · jac check -p per repo</span>
            <div className="overflow-x-auto">
                <table className="w-full font-mono text-xs">
                    <thead>
                        <tr className="text-muted-foreground">
                            <th className="py-1 text-left">repo</th>
                            <th className="text-right">files</th>
                            <th className="text-right">passed</th>
                            <th className="text-right">%</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for g in gate {
                            <tr key={str(g["repo"])} className="border-t border-border text-foreground/80">
                                <td className="py-1">{g["repo"]}</td>
                                <td className="text-right text-muted-foreground">{str(g["files"])}</td>
                                <td className="text-right text-foreground">{str(g["passed"])}</td>
                                <td className="text-right text-muted-foreground">{str(g["pct"])}%</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div>
            <div className="stat-line mt-2 text-muted-foreground/80">
                decontam dropped {str(dropped)} (14-gram containment ≥0.5 vs RL holdouts) · packed {str(man["packed"]["train"])}/{str(man["packed"]["valid"])} · seq {str(man["seq_len"])} · split {str(man["split"])} · EOS {str(man["eos_token"])} · {str(man["n_repos"])} repos
            </div>
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="section-header flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">DATA · CPT CORPUS (read-only)</span>
            <span className="micro-label text-muted-foreground/80">03-new/dataset/cpt</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            {_composition()}
            {_gate()}
            <div className="flex flex-wrap items-center gap-2">
                <span className="micro-label text-muted-foreground/80">SOURCE</span>
                <Segmented options={sourceOpts} value={cptSource} onSet={lambda (v: str) { switchSource(v); }} />
            </div>
            <RowBrowser
                files={files} path={path} rows={rows} offset={offset}
                total={total} expanded={expanded}
                onOpen={openFile} onToggle={toggleRow}
                onPrev={prevPage} onNext={nextPage}
            />
            <div className="stat-line text-muted-foreground/70">source: model-experiments/03-cpt-only/dataset/cpt</div>
        </div>
    </div>;
}
