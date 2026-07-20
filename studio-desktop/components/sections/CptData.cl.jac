"""DATA section (workspace 03 CPT) — continual-pretrain corpus browser.

Reads the CPT dataset built by model-experiments/03-new/cpt_build/build_cpt.py via cpt.sv.jac:
manifest stat tiles + a token-composition bar (plain divs, grayscale ramp — one
stacked bar doesn't need recharts) + the code-gate table + a RowBrowser over the
5 raw per-source files and the 2 packed splits.
"""

sv import from ...cpt { cpt_manifest, cpt_files, cpt_rows }
import from ..shared.StatTile { StatTile }
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
        if m["ok"] {
            srcs = list(m["sources"]);
            idx = 0;
            for s in srcs {
                s["shade"] = SHADES[idx % len(SHADES)];
                idx += 1;
            }
        }
        man = m;
        fs = await cpt_files();
        files = fs;
        if len(list(fs)) > 0 {
            await openFile(str(fs[0].path));
        }
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
        return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">TOKEN.COMPOSITION</span>
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
                    <span key={str(s["name"])} className="stat-line flex items-center gap-1.5 text-neutral-500">
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
        return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">CODE.GATE · jac check -p per repo</span>
            <div className="overflow-x-auto">
                <table className="w-full font-mono text-xs">
                    <thead>
                        <tr className="text-neutral-500">
                            <th className="py-1 text-left">repo</th>
                            <th className="text-right">files</th>
                            <th className="text-right">passed</th>
                            <th className="text-right">%</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for g in gate {
                            <tr key={str(g["repo"])} className="border-t border-neutral-900 text-neutral-300">
                                <td className="py-1">{g["repo"]}</td>
                                <td className="text-right text-neutral-500">{str(g["files"])}</td>
                                <td className="text-right text-neutral-100">{str(g["passed"])}</td>
                                <td className="text-right text-neutral-500">{str(g["pct"])}%</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div>
            <div className="stat-line mt-2 text-neutral-600">
                decontam dropped {str(dropped)} (14-gram containment ≥0.5 vs RL holdouts) · packed {str(man["packed"]["train"])}/{str(man["packed"]["valid"])} · seq {str(man["seq_len"])} · split {str(man["split"])} · EOS {str(man["eos_token"])} · {str(man["n_repos"])} repos
            </div>
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">DATA · CPT CORPUS (read-only)</span>
            <span className="micro-label text-neutral-600">03-new/dataset/cpt</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            {_composition()}
            {_gate()}
            <RowBrowser
                files={files} path={path} rows={rows} offset={offset}
                total={total} expanded={expanded}
                onOpen={openFile} onToggle={toggleRow}
                onPrev={prevPage} onNext={nextPage}
            />
        </div>
    </div>;
}
