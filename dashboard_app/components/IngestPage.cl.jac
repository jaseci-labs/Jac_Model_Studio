"""Ingest: dataset stats, builder rail (pipeline order), JSONL preview, add raw examples.

Stats/preview read the dataset files; the builder rail spawns `jac run
srccurrent/jacgen/<stage>.jac` via services/jobs.run_builder and polls its log;
add-examples appends validated rows to the conversion sources.
"""

sv import from ..services.dataset { DatasetStats, FileStat, FileRef, dataset_stats, list_dataset_files, sample_rows, add_examples }
sv import from ..services.jobs { JobStatus, run_builder, builder_status }
import from .hud.Hud { BracketTile, StatusGlyph, JsonRow, LogView }

# pipeline order (subset that's useful to trigger from the UI).
glob STAGES: list[list[str]] = [
    ["seed_conversion", "seed"], ["idiomatic_batch", "idiom 1"], ["idiomatic_batch2", "idiom 2"],
    ["idiomatic_batch3", "idiom 3"], ["scale_conversion", "scale (slow)"], ["dpo_conversion", "dpo pairs"],
    ["build_manifest", "manifest"], ["build_splits", "sft splits"], ["build_dpo_splits", "dpo splits"],
    ["holdout", "holdout"], ["graph_holdout", "graph holdout"], ["dataset_stats", "stats"],
];

def:pub BuilderButton(stage: str, label: str, active: str, st: dict, onRun: Callable[([str], None)]) -> JsxElement {
    def handle(e: MouseEvent) {
        onRun(stage);
    }
    s: str = str(st.get(stage, ""));
    glyph: str = "○";
    if s == "running" { glyph = "⦿"; }
    if s == "done" { glyph = "✓"; }
    if s == "failed" { glyph = "✗"; }
    base: str = "dg-stage dg-active" if stage == active else "dg-stage";
    if s == "running" { base = base + " dg-acc-green"; }
    if s == "failed" { base = base + " dg-acc-red"; }
    return <button onClick={handle} className={base}>
        <span>{glyph}</span>
        <span>{label}</span>
    </button>;
}

def:pub IngestPage() -> JsxElement {
    has stats: DatasetStats | None = None,
        files: list[FileRef] = [],
        sel_file: str = "dataset/conversion/sft.jsonl",
        offset: int = 0,
        rows: list[str] = [],
        active_stage: str = "",
        stage_status: dict = {},
        bstatus: JobStatus | None = None,
        btick: int = 0,
        add_target: str = "dataset/conversion/sft.jsonl",
        add_text: str = "",
        add_msg: str = "";

    async can with entry {
        stats = await dataset_stats();
        files = await list_dataset_files();
    }

    async can with [sel_file, offset] entry {
        rows = await sample_rows(sel_file, offset, 8);
    }

    async can with [active_stage, btick] entry {
        if active_stage != "" {
            fetched: JobStatus | None = await builder_status(active_stage);
            bstatus = fetched;
            if fetched is not None {
                marks: dict = dict(stage_status);
                marks[active_stage] = fetched.status;
                stage_status = marks;
            }
            if fetched is not None and fetched.status == "running" {
                setTimeout(lambda { btick = btick + 1; }, 2000);
            } else {
                stats = await dataset_stats();
                files = await list_dataset_files();
            }
        }
    }

    async def do_run(stage: str) -> None {
        active_stage = stage;
        bstatus = await run_builder(stage);
        btick = btick + 1;
    }

    def on_file(e: ChangeEvent) {
        sel_file = e.target.value;
        offset = 0;
    }

    def next_page(e: MouseEvent) {
        offset = offset + 8;
    }

    def prev_page(e: MouseEvent) {
        offset = offset - 8 if offset >= 8 else 0;
    }

    async def do_add -> None {
        res = await add_examples(add_target, add_text);
        added: int = int(res["added"]);
        total: int = int(res["total"]);
        errs: list = list(res["errors"]);
        if len(errs) > 0 {
            add_msg = "added " + str(added) + " · " + str(len(errs)) + " error(s): " + str(errs[0]);
        } else {
            add_msg = "added " + str(added) + " row(s) · file now " + str(total);
        }
        add_text = "";
        stats = await dataset_stats();
        files = await list_dataset_files();
    }

    return <div className="dg-page">
        {stats and <div key="sec-stats" className="dg-stats dg-mb-lg">
            <BracketTile key="sft" label="SFT.TOTAL" value={str(stats.sft_total)} sub="IDIOMATIC + TRANSPILE" subcls="" />
            <BracketTile key="dpo" label="DPO.PAIRS" value={str(stats.dpo_pairs)} sub="CHOSEN / REJECTED" subcls="" />
            <BracketTile key="mlxsft" label="MLX.SFT" value={str(stats.splits["mlx_train"]) + " / " + str(stats.splits["mlx_valid"])} sub="TRAIN / VALID" subcls="" />
            <BracketTile key="mlxdpo" label="MLX.DPO" value={str(stats.splits["dpo_train"]) + " / " + str(stats.splits["dpo_valid"])} sub="TRAIN / VALID" subcls="" />
            <BracketTile key="hold" label="HOLDOUT" value={str(stats.splits["holdout"]) + " / " + str(stats.splits["graph_holdout"])} sub="FUNCTION / GRAPH" subcls="" />
        </div>}

        <div className="dg-ingest-grid">
            <div className="dg-panel">
                <span className="dg-panel-label">BUILDERS</span>
                <div className="dg-faint" style={{"marginBottom": "0.5rem"}}>run in pipeline order ↓</div>
                <div className="dg-stack" style={{"gap": "0.15rem"}}>
                    {for pair in STAGES {
                        <BuilderButton key={pair[0]} stage={pair[0]} label={pair[1]} active={active_stage} st={stage_status} onRun={do_run} />
                    }}
                </div>
                {bstatus is not None and <div className="dg-row" style={{"margin": "0.6rem 0 0.4rem"}}>
                    <StatusGlyph status={bstatus.status} />
                    <span className="dg-faint">{active_stage}</span>
                </div>}
                {bstatus is not None and bstatus.log_tail != "" and <LogView text={bstatus.log_tail} maxh="160px" />}
            </div>

            <div className="dg-stack" style={{"gap": "1.2rem"}}>
                <div className="dg-panel">
                    <span className="dg-panel-label">PREVIEW</span>
                    <div className="dg-row" style={{"marginBottom": "0.55rem"}}>
                        <select value={sel_file} onChange={on_file} className="dg-select">
                            {for f in files {
                                <option key={f.path} value={f.path}>{f.label + "  (" + str(f.count) + ")"}</option>
                            }}
                        </select>
                        <button onClick={prev_page} className="dg-btn">‹ PREV</button>
                        <span className="dg-faint">{"ROWS " + str(offset) + ".." + str(offset + len(rows))}</span>
                        <button onClick={next_page} className="dg-btn">NEXT ›</button>
                    </div>
                    <div className="dg-stack">
                        {if len(rows) == 0 {
                            <div key="empty" className="dg-faint">NO ROWS</div>
                        }}
                        {for (i, r) in enumerate(rows) {
                            <JsonRow key={str(i)} text={r} />
                        }}
                    </div>
                </div>

                <div className="dg-panel">
                    <span className="dg-panel-label">ADD.EXAMPLES</span>
                    <div className="dg-row" style={{"marginBottom": "0.5rem"}}>
                        <select value={add_target} onChange={lambda e: ChangeEvent { add_target = e.target.value; }} className="dg-select">
                            <option value="dataset/conversion/sft.jsonl">SFT (messages)</option>
                            <option value="dataset/conversion/dpo.jsonl">DPO (prompt/chosen/rejected)</option>
                        </select>
                        <button onClick={do_add} className="dg-btn dg-btn-primary">APPEND</button>
                        {add_msg != "" and <span className={"dg-acc-red" if "error" in add_msg else "dg-acc-green"} style={{"fontSize": "0.74rem"}}>{add_msg}</span>}
                    </div>
                    <textarea value={add_text} onChange={lambda e: ChangeEvent { add_text = e.target.value; }}
                        placeholder={"{\"messages\": [{\"role\": \"user\", ...}], \"meta\": {...}}"}
                        className="dg-textarea" />
                </div>
            </div>
        </div>
    </div>;
}
