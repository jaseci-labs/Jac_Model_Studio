"""Ingest: dataset stats, JSONL preview, run the Jac builders, add raw examples.

Stats/preview read the dataset files; the builder buttons spawn `jac run
srccurrent/jacgen/<stage>.jac` via services/jobs.run_builder and poll its log;
add-examples appends validated rows to the conversion sources.
"""

sv import from ..services.dataset { DatasetStats, FileStat, FileRef, dataset_stats, list_dataset_files, sample_rows, add_examples }
sv import from ..services.jobs { JobStatus, run_builder, builder_status }
import from .RunCharts { StatCard }
import from .TrainPage { StatusBadge }

# pipeline order (subset that's useful to trigger from the UI).
glob STAGES: list[list[str]] = [
    ["seed_conversion", "seed"], ["idiomatic_batch", "idiom-1"], ["idiomatic_batch2", "idiom-2"],
    ["idiomatic_batch3", "idiom-3"], ["scale_conversion", "scale (slow)"], ["dpo_conversion", "dpo pairs"],
    ["build_manifest", "manifest"], ["build_splits", "sft splits"], ["build_dpo_splits", "dpo splits"],
    ["holdout", "holdout"], ["graph_holdout", "graph holdout"], ["dataset_stats", "stats"],
];

def:pub BuilderButton(stage: str, label: str, active: str, onRun: Callable[([str], None)]) -> JsxElement {
    def handle(e: MouseEvent) {
        onRun(stage);
    }
    return <button onClick={handle} className={"dg-btn dg-btn-primary" if stage == active else "dg-btn"}>{label}</button>;
}

def:pub IngestPage() -> JsxElement {
    has stats: DatasetStats | None = None,
        files: list[FileRef] = [],
        sel_file: str = "dataset/conversion/sft.jsonl",
        offset: int = 0,
        rows: list[str] = [],
        active_stage: str = "",
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
            bstatus = await builder_status(active_stage);
            if bstatus is not None and bstatus.status == "running" {
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
            <StatCard key="sft" label="SFT total" value={str(stats.sft_total)} sub="idiomatic + transpile" />
            <StatCard key="dpo" label="DPO pairs" value={str(stats.dpo_pairs)} sub="chosen / rejected" />
            <StatCard key="mlxsft" label="MLX SFT" value={str(stats.splits["mlx_train"]) + " / " + str(stats.splits["mlx_valid"])} sub="train / valid" />
            <StatCard key="mlxdpo" label="MLX DPO" value={str(stats.splits["dpo_train"]) + " / " + str(stats.splits["dpo_valid"])} sub="train / valid" />
            <StatCard key="hold" label="holdout" value={str(stats.splits["holdout"]) + " / " + str(stats.splits["graph_holdout"])} sub="function / graph" />
        </div>}

        <div key="sec-build" className="dg-mb-lg">
            <div className="dg-title">Build dataset · run in pipeline order (scale is slow)</div>
            <div className="dg-row dg-mb" style={{"gap": "0.4rem"}}>
                {for pair in STAGES {
                    <BuilderButton key={pair[0]} stage={pair[0]} label={pair[1]} active={active_stage} onRun={do_run} />
                }}
            </div>
            {bstatus is not None and <div className="dg-row" style={{"marginBottom": "0.4rem"}}>
                <StatusBadge status={bstatus.status} />
                <span className="dg-faint">{active_stage}</span>
            </div>}
            {bstatus is not None and bstatus.log_tail != "" and <pre className="dg-log" style={{"maxHeight": "180px"}}>{bstatus.log_tail}</pre>}
        </div>

        <div key="sec-preview" className="dg-mb-lg">
            <div className="dg-row" style={{"marginBottom": "0.55rem"}}>
                <span className="dg-title" style={{"marginBottom": "0"}}>Preview</span>
                <select value={sel_file} onChange={on_file} className="dg-select">
                    {for f in files {
                        <option key={f.path} value={f.path}>{f.label + "  (" + str(f.count) + ")"}</option>
                    }}
                </select>
                <button onClick={prev_page} className="dg-btn">‹ prev</button>
                <span className="dg-faint">{"rows " + str(offset) + "–" + str(offset + len(rows))}</span>
                <button onClick={next_page} className="dg-btn">next ›</button>
            </div>
            <div className="dg-stack">
                {if len(rows) == 0 {
                    <div key="empty" className="dg-faint">no rows</div>
                }}
                {for (i, r) in enumerate(rows) {
                    <pre key={str(i)} className="dg-log" style={{"maxHeight": "118px"}}>{r}</pre>
                }}
            </div>
        </div>

        <div key="sec-add">
            <div className="dg-title">Add raw examples · one JSON object per line</div>
            <div className="dg-row" style={{"marginBottom": "0.5rem"}}>
                <select value={add_target} onChange={lambda e: ChangeEvent { add_target = e.target.value; }} className="dg-select">
                    <option value="dataset/conversion/sft.jsonl">SFT (messages)</option>
                    <option value="dataset/conversion/dpo.jsonl">DPO (prompt/chosen/rejected)</option>
                </select>
                <button onClick={do_add} className="dg-btn dg-btn-primary">Append</button>
                {add_msg != "" and <span className="dg-faint">{add_msg}</span>}
            </div>
            <textarea value={add_text} onChange={lambda e: ChangeEvent { add_text = e.target.value; }}
                placeholder={"{\"messages\": [{\"role\": \"user\", ...}], \"meta\": {...}}"}
                className="dg-textarea" />
        </div>
    </div>;
}
