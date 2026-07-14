"""PLAN section (workspace 03 CPT) — the CPT→SFT/DPO→GRPO roadmap.

Static render of 03-new/docs/workflow.md: the 9 phases with a status glyph each
(P1 done — corpus built; everything downstream idle/gated) + the 12-item
checklist. Status is hardcoded to on-disk reality; workflow.md is the source of
truth. No sv imports.
"""

import from ..shared.StatusGlyph { StatusGlyph }

glob PHASES: list[dict] = [
    {"id": "P0", "status": "idle", "title": "Base eval (checkpoint 0)", "note": "unmodified Qwen3-Coder-30B-A3B through both eval tracks — the floor every checkpoint is read against."},
    {"id": "P1", "status": "done", "title": "CPT data build", "note": "DONE — 3.84M tokens, 939 windows (790/149). 5 sources: docs, code, rehearsal, blogs, osp_paper. Decontam clean, manifest emitted."},
    {"id": "P2", "status": "done", "title": "CPT training", "note": "DONE (2026-07-14) — 2586/2586 iters, 6.82h. Train loss -18.5%, val loss -24.4%, moving together (no overfit signal). Peak mem 30.4GB/48GB. Fused: models/qwen-cpt-v1-fused-q4. CF regression check PASS (16/16 both models, zero delta) — see analysis.md."},
    {"id": "C1", "status": "done", "title": "Checkpoint 1 · +CPT eval", "note": "DONE (2026-07-14) — NULL RESULT. 20-question semantic MCQ: qwen-q4 18/20 vs qwen-cpt-v1 18/20, identical answers on every question. CPT-v1 NOT accepted — see analysis.md."},
    {"id": "P4", "status": "idle", "title": "SFT/DPO (redesigned data)", "note": "GATED — spec not yet written. Also gated on Checkpoint 1's null: don't build on an unconfirmed CPT checkpoint. Reuse 01-sft-dpo recipe; redesign DPO pairs toward semantic-vs-subtly-wrong OSP idiom."},
    {"id": "C2", "status": "idle", "title": "Checkpoint 2 · +CPT+SFT/DPO eval", "note": "Full track: semantic MCQ + online-judge (compiler/pass@k) + human trust check."},
    {"id": "P6", "status": "idle", "title": "RL/GRPO (redesigned corpus+reward)", "note": "GATED — spec not yet written. Multi-project source diversity + Type-B AST/partial-credit grading + idiom balance."},
    {"id": "C3", "status": "idle", "title": "Checkpoint 3 · +CPT+SFT/DPO+GRPO eval", "note": "Same full track as checkpoint 2."},
    {"id": "P8", "status": "idle", "title": "Read the ablation", "note": "4-point delta table (base / +CPT / +CPT+SFT-DPO / +…+GRPO). Did CPT move the semantic ceiling SFT+RL both hit?"}
];

glob CHECKLIST: list[dict] = [
    {"done": True, "t": "Blog source located (jaseci-labs/jaseci-blogs)"},
    {"done": True, "t": "General-code rehearsal corpus picked (codeparrot-clean-valid)"},
    {"done": True, "t": "jaseci-labs org repo inventory enumerated (17 Jac repos)"},
    {"done": True, "t": "Phase 1 CPT dataset built, manifest emitted, decontam clean"},
    {"done": False, "t": "Phase 0 base eval recorded (both tracks)"},
    {"done": True, "t": "Phase 2 CPT training run complete (CF monitor still unbuilt, see analysis doc)"},
    {"done": True, "t": "Checkpoint 1 MCQ + trust check recorded — NULL, checkpoint NOT accepted"},
    {"done": False, "t": "SFT/DPO redesign spec written (gates Phase 4)"},
    {"done": False, "t": "Phase 4 SFT/DPO run, Checkpoint 2 full eval recorded"},
    {"done": False, "t": "RL/GRPO redesign spec written (gates Phase 6)"},
    {"done": False, "t": "Phase 6 GRPO run, Checkpoint 3 full eval recorded"},
    {"done": False, "t": "Phase 8 ablation table built, hypothesis confirmed/killed"}
];

def:pub Plan -> JsxElement {
    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">PLAN · CPT → SFT/DPO → GRPO</span>
            <span className="micro-label text-neutral-600">03-new/docs/workflow.md</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">PHASES</span>
                <div className="relative flex flex-col gap-0.5 pl-3">
                    <div className="absolute bottom-1 left-0 top-1 w-px bg-neutral-800"></div>
                    {for p in PHASES {
                        <div key={str(p["id"])} className="flex items-start gap-3 rounded px-2 py-1.5">
                            <span className="mt-0.5 shrink-0"><StatusGlyph status={str(p["status"])} showLabel={False} /></span>
                            <span className="shrink-0 font-mono text-xs text-neutral-600" style={{"width": 26}}>{str(p["id"])}</span>
                            <div className="flex flex-col gap-0.5">
                                <span className="font-mono text-xs text-neutral-200">{str(p["title"])}</span>
                                <span className="stat-line text-neutral-500">{str(p["note"])}</span>
                            </div>
                        </div>
                    }}
                </div>
            </div>

            <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">CHECKLIST</span>
                <div className="flex flex-col gap-1">
                    {for c in CHECKLIST {
                        <div key={str(c["t"])} className="flex items-center gap-2 font-mono text-xs">
                            <span className={"shrink-0 " + ("text-neutral-100" if c["done"] else "text-neutral-600")}>{"✓" if c["done"] else "○"}</span>
                            <span className={"text-neutral-300" if c["done"] else "text-neutral-500"}>{str(c["t"])}</span>
                        </div>
                    }}
                </div>
                <div className="stat-line mt-3 text-neutral-600">status hardcoded to on-disk reality · source of truth: 03-new/docs/workflow.md</div>
            </div>
        </div>
    </div>;
}
