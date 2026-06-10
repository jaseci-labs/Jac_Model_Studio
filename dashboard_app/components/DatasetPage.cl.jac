"""Dataset: browse the whole corpus as pretty, syntax-highlighted code.

Table + expand. Pick any dataset file; each row shows index/name/difficulty/source/
preview; click to expand the full Python + Jac (or DPO chosen/rejected) code, which
the server syntax-highlights into classed spans (rendered here via unsafe_html —
trusted local dataset, not user input)."""

sv import from ..services.dataset { FileRef, DataRow, list_dataset_files, dataset_rows }

def:pub CodeBlock(label: str, html: str) -> JsxElement {
    return <div className="dg-code">
        <div className="dg-code-label">{label}</div>
        <pre className="dg-code-pre"><code>{unsafe_html(html)}</code></pre>
    </div>;
}

def:pub DatasetRow(row: DataRow, isOpen: bool, onToggle: Callable[([int], None)]) -> JsxElement {
    def handle(e: MouseEvent) {
        onToggle(row.idx);
    }
    return <div>
        <div className={"dg-tr dg-open" if isOpen else "dg-tr"} onClick={handle}>
            <div className="dg-td dg-faint">{str(row.idx)}</div>
            <div className="dg-td dg-mono">{row.name}</div>
            <div className="dg-td"><span className="dg-kind">{row.difficulty}</span></div>
            <div className="dg-td dg-faint">{row.source}</div>
            <div className="dg-td dg-mono dg-faint">{row.preview}</div>
        </div>
        {isOpen and <div className="dg-detail">
            {row.prompt != "" and <div className="dg-detail-prompt">{row.prompt}</div>}
            <div className="dg-code-grid">
                {row.py_html != "" and <CodeBlock label="python" html={row.py_html} />}
                {row.jac_html != "" and <CodeBlock label="jac" html={row.jac_html} />}
                {row.chosen_html != "" and <CodeBlock label="chosen · jac" html={row.chosen_html} />}
                {row.rejected_html != "" and <CodeBlock label="rejected · jac" html={row.rejected_html} />}
                {row.raw_html != "" and <CodeBlock label="json" html={row.raw_html} />}
            </div>
        </div>}
    </div>;
}

def:pub DatasetPage() -> JsxElement {
    has files: list[FileRef] = [],
        rel: str = "dataset/conversion/sft.jsonl",
        offset: int = 0,
        rows: list[DataRow] = [],
        expanded: int = -1;

    async can with entry {
        files = await list_dataset_files();
        rows = await dataset_rows(rel, 0, 25);
    }

    async can with [rel, offset] entry {
        rows = await dataset_rows(rel, offset, 25);
        expanded = -1;
    }

    def on_file(e: ChangeEvent) {
        rel = e.target.value;
        offset = 0;
    }

    def next_page(e: MouseEvent) {
        offset = offset + 25;
    }

    def prev_page(e: MouseEvent) {
        offset = offset - 25 if offset >= 25 else 0;
    }

    def toggle(idx: int) -> None {
        expanded = -1 if expanded == idx else idx;
    }

    return <div className="dg-page">
        <div className="dg-row dg-mb">
            <select value={rel} onChange={on_file} className="dg-select">
                {for f in files {
                    <option key={f.path} value={f.path}>{f.label + "  (" + str(f.count) + ")"}</option>
                }}
            </select>
            <button onClick={prev_page} className="dg-btn">‹ prev</button>
            <span className="dg-faint">{"rows " + str(offset) + "–" + str(offset + len(rows))}</span>
            <button onClick={next_page} className="dg-btn">next ›</button>
            <span className="dg-spacer"></span>
            <span className="dg-faint">click a row to expand</span>
        </div>

        <div className="dg-glass dg-table">
            <div className="dg-thead">
                <div>#</div><div>name</div><div>difficulty</div><div>source</div><div>preview</div>
            </div>
            {if len(rows) == 0 {
                <div key="empty" className="dg-faint" style={{"padding": "1.2rem 0.9rem"}}>no rows</div>
            }}
            {for r in rows {
                <DatasetRow key={str(r.idx)} row={r} isOpen={expanded == r.idx} onToggle={toggle} />
            }}
        </div>
    </div>;
}
