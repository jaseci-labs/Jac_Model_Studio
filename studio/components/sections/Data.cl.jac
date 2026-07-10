"""DATA section — pipeline rail + add-examples (left) | dataset browser (right).

Ports ui/components/sections/data/{data-section,pipeline-rail,add-examples,
dataset-browser,row-detail,stats-tiles}. The 13 build stages run as detached jobs
(builders.sv.jac); the browser is read-only over the preview-allowed files
(data.sv.jac); appends go through add_examples. Row detail renders code via CodeBlock.

# studio: the tsx polls builders only while a stage is running (usePoll). Reproducing
# that gate needs a fresh closure over state; instead we poll unconditionally every
# 3s while mounted — a touch more network, but correct and far simpler.
"""

sv import from ...data { dataset_stats, dataset_files, dataset_rows, add_examples, rl_dataset_files, rl_dataset_rows, FileRefView, DataRowView }
sv import from ...builders { list_builders, run_builder, BuilderView }
import from ..shared.StatTile { StatTile }
import from ..shared.StatusGlyph { StatusGlyph }
import from ..shared.LogView { LogView }
import from ..shared.Field { Segmented }
import from ..shared.CodeBlock { CodeBlock }

glob GROUPS: list[dict] = [
    {"label": "SEED", "stages": ["seed_conversion"]},
    {"label": "IDIOM BATCHES", "stages": ["idiomatic_batch", "idiomatic_batch2", "idiomatic_batch3"]},
    {"label": "SCALE", "stages": ["scale_conversion"]},
    {"label": "DPO", "stages": ["dpo_conversion"]},
    {"label": "MANIFEST+SPLITS", "stages": ["build_manifest", "build_splits", "build_dpo_splits"]},
    {"label": "HOLDOUTS", "stages": ["holdout", "graph_holdout"]},
    {"label": "AUDIT", "stages": ["dataset_stats", "verify_dataset"]}
];

glob KIND_LABEL: dict = {"sft": "SFT", "dpo": "DPO", "holdout": "HOLD", "raw": "RAW", "rltask": "RL"};
glob RL_SOURCES: list[str] = ["SFT", "GRPO", "conversion", "synthetic", "splits"];

def:pub Data -> JsxElement {
    has stats: any = None,
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1,
        builders: list = [],
        selectedStage: str = "",
        addTarget: str = "sft",
        addText: str = "",
        addResult: any = None,
        addBusy: bool = False,
        dataView: str = "core",
        rlSource: str = "SFT",
        doneCount: int = 0,
        runningStage: str = "",
        pollId: any = None;

    # `p`/`off`/`view`/`src` are passed explicitly — reading the state right after
    # setting it returns the stale value (React state writes are async).
    async def _fetch(p: str, off: int, view: str, src: str) -> None {
        limit = 25;
        r: dict = {};
        if view == "rl" {
            r = await rl_dataset_rows(src, p, off, limit);
        } else {
            r = await dataset_rows(p, off, limit);
        }
        rows = list(r["rows"]);
        total = int(r["total"]);
    }

    async def openFile(p: str) -> None {
        path = p;
        offset = 0;
        expanded = -1;
        await _fetch(p, 0, dataView, rlSource);
    }

    async def _loadView(view: str, src: str) -> None {
        fs: list = [];
        if view == "rl" {
            fs = await rl_dataset_files(src);
        } else {
            fs = await dataset_files();
        }
        files = fs;
        expanded = -1;
        offset = 0;
        if len(list(fs)) > 0 {
            path = str(fs[0].path);
            await _fetch(str(fs[0].path), 0, view, src);
        } else {
            path = ""; rows = []; total = 0;
        }
    }

    async def switchView(v: str) -> None {
        dataView = v;
        await _loadView(v, rlSource);
    }

    async def switchRlSource(s: str) -> None {
        rlSource = s;
        await _loadView("rl", s);
    }

    async def loadBuilders() -> None {
        bs = await list_builders();
        builders = bs;
        dc = 0;
        rs = "";
        for b in bs {
            st = str(b.status);
            if st == "done" or st == "finished" {
                dc += 1;
            }
            if st == "running" {
                rs = str(b.stage);
            }
        }
        doneCount = dc;
        runningStage = rs;
    }

    def selectStage(s: str) -> None {
        selectedStage = s;
    }

    async def runStage(s: str) -> None {
        selectedStage = s;
        await run_builder(stage=s);
        await loadBuilders();
    }

    async def submitExamples() -> None {
        addBusy = True;
        addResult = None;
        r = await add_examples(target=addTarget, jsonl=addText);
        addResult = r;
        addBusy = False;
        if int(r["added"]) > 0 {
            stats = await dataset_stats();
            fs = await dataset_files();
            files = fs;
        }
    }

    async can with entry {
        stats = await dataset_stats();
        fs = await dataset_files();
        files = fs;
        await loadBuilders();
        if len(fs) > 0 {
            await openFile(str(fs[0].path));
        }
        pollId = setInterval(lambda -> None { loadBuilders(); }, 3000);
    }

    can with exit {
        if pollId is not None {
            clearInterval(float(str(pollId)));
        }
    }

    async def prevPage -> None {
        if offset > 0 {
            noff = max(0, offset - 25);
            offset = noff;
            expanded = -1;
            await _fetch(path, noff, dataView, rlSource);
        }
    }

    async def nextPage -> None {
        if offset + len(rows) < total {
            noff = offset + 25;
            offset = noff;
            expanded = -1;
            await _fetch(path, noff, dataView, rlSource);
        }
    }

    def _statusOf(stage: str) -> str {
        for b in builders {
            if str(b.stage) == stage {
                return str(b.status);
            }
        }
        return "idle";
    }

    def _logOf(stage: str) -> str {
        for b in builders {
            if str(b.stage) == stage {
                return str(b.log_tail);
            }
        }
        return "";
    }

    def _tiles() -> JsxElement {
        if not stats {
            return <span className="micro-label">loading…</span>;
        }
        sp: any = stats["splits"];
        return <div className="grid grid-cols-3 gap-3 lg:grid-cols-6">
            <StatTile label="SFT.TOTAL" value={str(stats["sft_total"])} sub="examples" dim={False} />
            <StatTile label="DPO.PAIRS" value={str(stats["dpo_pairs"])} sub="pairs" dim={False} />
            <StatTile label="MLX.SFT" value={str(sp["mlx_train"]) + "/" + str(sp["mlx_valid"])} sub="train/valid" dim={False} />
            <StatTile label="MLX.DPO" value={str(sp["dpo_train"]) + "/" + str(sp["dpo_valid"])} sub="train/valid" dim={False} />
            <StatTile label="HOLDOUT" value={str(sp["holdout"])} sub="function" dim={False} />
            <StatTile label="HOLDOUT.GRAPH" value={str(sp["graph_holdout"])} sub="graph" dim={False} />
        </div>;
    }

    def _rail() -> JsxElement {
        nstages = len(builders) if len(builders) > 0 else 13;
        pct = (doneCount * 100.0) / nstages if nstages > 0 else 0.0;
        return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">PIPELINE</span>
            <div className="mb-3 flex flex-col gap-1.5">
                <div className="flex items-center justify-between">
                    <span className="stat-line text-neutral-500">{str(doneCount)}/{str(nstages)} DONE</span>
                    {runningStage and <span className="micro-label pulse text-neutral-300">⦿ {runningStage}</span>}
                </div>
                <div className="h-1 w-full rounded-full bg-neutral-800">
                    <div className="h-1 rounded-full bg-neutral-300 transition-all" style={{"width": str(pct) + "%"}}></div>
                </div>
            </div>
            <div className="relative flex flex-col gap-0.5 pl-3">
                <div className="absolute bottom-1 left-0 top-1 w-px bg-neutral-800"></div>
                {for group in GROUPS {
                    <div key={str(group["label"])} className="mt-2 first:mt-0">
                        <div className="mb-1 flex items-center gap-2">
                            <span className="micro-label shrink-0 text-neutral-600">{str(group["label"])}</span>
                            <div className="dashed-rule flex-1"></div>
                        </div>
                        {for stage in list(group["stages"]) {
                            <div key={str(stage)}>
                                <div
                                    onClick={lambda e: MouseEvent { selectStage(str(stage)); }}
                                    className={"flex cursor-pointer items-center gap-2 rounded px-2 py-1 " + (
                                        "bg-[#1a1a1a]" if selectedStage == str(stage) else "hover:bg-[#141414]"
                                    )}
                                >
                                    <StatusGlyph status={_statusOf(str(stage))} showLabel={False} />
                                    <span className="flex-1 truncate font-mono text-xs text-neutral-400">{str(stage)}</span>
                                    <button
                                        disabled={_statusOf(str(stage)) == "running"}
                                        onClick={lambda e: MouseEvent { e.stopPropagation(); runStage(str(stage)); }}
                                        className="micro-label rounded border border-neutral-700 px-1.5 py-0.5 text-neutral-500 transition-colors hover:border-neutral-500 hover:text-neutral-200 disabled:cursor-not-allowed disabled:opacity-30"
                                    >
                                        RUN
                                    </button>
                                </div>
                                {(str(stage) == "seed_conversion") and <div className="stat-line ml-8 mt-0.5 mb-1 border-l-2 border-neutral-600 pl-2">TRUNCATES sft.jsonl→32 · dpo.jsonl→2 · run idiomatic batches after, then downstream stages</div>}
                            </div>
                        }}
                    </div>
                }}
            </div>
        </div>;
    }

    def _detail(row: any) -> JsxElement {
        kind = str(row["kind"]);
        return <div className="rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 space-y-2">
            {row["prompt"] and <div>
                <div className="micro-label mb-1 text-neutral-600">PROMPT</div>
                <pre className="whitespace-pre-wrap font-mono text-xs text-neutral-400 leading-relaxed">{row["prompt"]}</pre>
            </div>}
            {row["python"] and <CodeBlock label="" code={str(row["python"])} lang="python" />}
            {(row["jac"] and kind != "dpo") and <CodeBlock label="" code={str(row["jac"])} lang="jac" />}
            {(kind == "dpo" and row["chosen"]) and <CodeBlock label="CHOSEN.JAC" code={str(row["chosen"])} lang="jac" />}
            {(kind == "dpo" and row["rejected"]) and <CodeBlock label="REJECTED.JAC" code={str(row["rejected"])} lang="jac" />}
            {(kind == "raw" and row["raw"]) and <pre className="overflow-x-auto font-mono text-xs text-neutral-400 leading-relaxed whitespace-pre">{row["raw"]}</pre>}
        </div>;
    }

    def _addExamples() -> JsxElement {
        ph = ('one JSON object per line · sft: {"messages":[...]}' if addTarget == "sft"
            else 'one JSON object per line · dpo: {"prompt","chosen","rejected"}');
        return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">ADD.EXAMPLES</span>
            <div className="flex flex-col gap-3">
                <Segmented options={["sft", "dpo"]} value={addTarget} onSet={lambda v: str { addTarget = v; }} />
                <textarea
                    rows={6}
                    value={addText}
                    onChange={lambda e: ChangeEvent { addText = e.target.value; }}
                    placeholder={ph}
                    className="w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1.5 font-mono text-xs text-neutral-100 outline-none placeholder:text-neutral-600 focus:border-neutral-500 resize-none"
                ></textarea>
                <button
                    disabled={addBusy or (not addText.strip())}
                    onClick={lambda e: MouseEvent { submitExamples(); }}
                    className="micro-label self-start rounded border border-neutral-600 px-3 py-1.5 text-neutral-300 transition-colors hover:border-neutral-400 hover:text-neutral-100 disabled:cursor-not-allowed disabled:opacity-30"
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

    def _browser() -> JsxElement {
        canPrev = offset > 0;
        canNext = offset + len(rows) < total;
        return <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">DATASET.BROWSER</span>
            <div className="mb-3 flex flex-wrap gap-1">
                {(len(files) == 0) and <span className="stat-line">no files</span>}
                {for f in files {
                    <button
                        key={str(f.path)}
                        onClick={lambda e: MouseEvent { openFile(str(f.path)); }}
                        className={"rounded border px-2 py-0.5 font-mono text-[10px] transition-colors " + (
                            "border-neutral-500 bg-[#1a1a1a] text-neutral-100" if str(f.path) == path
                            else "border-neutral-700 text-neutral-500 hover:text-neutral-300"
                        )}
                    >
                        {f.label} {str(f.count)}
                    </button>
                }}
            </div>
            {path and <div>
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
                    {for row in rows {
                        <div key={str(row["idx"])}>
                            <div
                                onClick={lambda e: MouseEvent { expanded = -1 if expanded == int(row["idx"]) else int(row["idx"]); }}
                                className="grid cursor-pointer grid-cols-[2rem_1fr_3rem_3rem_5rem_1fr] gap-2 rounded px-0.5 py-1 font-mono text-xs hover:bg-[#141414]"
                            >
                                <span className="text-neutral-600">{str(row["idx"])}</span>
                                <span className="truncate text-neutral-300">{row["name"]}</span>
                                <span className="text-neutral-500">{str(KIND_LABEL[str(row["kind"])]) if str(row["kind"]) in KIND_LABEL else str(row["kind"])}</span>
                                <span className="text-neutral-500">{row["difficulty"]}</span>
                                <span className="truncate text-neutral-500">{row["source"]}</span>
                                <span className="truncate text-neutral-600">{row["preview"]}</span>
                            </div>
                            {(expanded == int(row["idx"])) and <div className="mb-1">{_detail({"row": row})}</div>}
                        </div>
                    }}
                </div>
                {(total > 0) and <div className="mt-3 flex items-center justify-center gap-3 stat-line">
                    <button disabled={not canPrev} onClick={lambda e: MouseEvent { prevPage(); }} className="disabled:opacity-30 hover:text-neutral-200 transition-colors">← PREV</button>
                    <span>{str(offset + 1)} to {str(offset + len(rows))} of {str(total)}</span>
                    <button disabled={not canNext} onClick={lambda e: MouseEvent { nextPage(); }} className="disabled:opacity-30 hover:text-neutral-200 transition-colors">NEXT →</button>
                </div>}
            </div>}
            {(not path) and <div className="stat-line py-6 text-center">select a file above</div>}
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">DATA.PIPELINE</span>
            <span className="micro-label text-neutral-600">DATASET.CTL</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            <div className="grid gap-4" style={{"gridTemplateColumns": "280px 1fr"}}>
                <div className="flex flex-col gap-4">
                    {_rail()}
                    {selectedStage and <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                        <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{selectedStage}</span>
                        <LogView text={_logOf(selectedStage)} maxH="14rem" />
                    </div>}
                </div>
                <div className="flex flex-col gap-4">
                    <div className="flex flex-wrap items-center gap-2">
                        <span className="micro-label text-neutral-600">DATASET</span>
                        <Segmented options={["core", "rl"]} value={dataView} onSet={lambda v: str { switchView(v); }} />
                        {(dataView == "rl") and <Segmented options={RL_SOURCES} value={rlSource} onSet={lambda v: str { switchRlSource(v); }} />}
                    </div>
                    {(dataView == "rl") and <div className="stat-line text-neutral-600">RL training data (read-only) — SFT gold · GRPO reward tasks · python→jac · synthetic · splits. See RL_FINDINGS.md.</div>}
                    {_browser()}
                    {(dataView == "core") and _addExamples()}
                </div>
            </div>
        </div>
    </div>;
}
