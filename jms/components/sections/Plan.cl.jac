"""PLAN section — renders the hand-maintained plan doc for the workspace it
belongs to, and an honest empty state everywhere else.

WORKSPACE-SCOPED. This component is mounted by every workspace whose layout has
a PLAN section, but the only plan document transcribed here is workspace
PLAN_WS's (03 · CPT). PHASES/CHECKLIST describe THAT experiment and nothing
else, so on any other workspace this renders "no plan doc" rather than showing
CPT content under an unrelated experiment. Do not add content for another
workspace unless you are transcribing that workspace's real doc.

STATIC DOCUMENT, NOT LIVE STATE. There is no `sv import` in this file: PHASES and
CHECKLIST below are hand-transcribed from 03-new/docs/workflow.md and are only as
current as AS_OF. They are rendered with a STATIC · HAND-MAINTAINED tag and the
AS_OF date in the header so nobody mistakes them for something the system read.

To make this live later, follow `cptsft.sv.jac:cptsft_plan_status` — it derives
plan status from the real results tree, and CptSftPlan.cl.jac renders it. Doing
that here needs a new sv endpoint plus a main.jac registration.
"""

import from ..shared.StatusGlyph { StatusGlyph }
import from ..shared.EmptyState { EmptyState }

# The ONE workspace whose plan doc is transcribed below (wid from workspace.sv.jac
# `_SEED_WORKSPACES`: 01 SFT/DPO, 02 RL/GRPO, 03 CPT, 04 CPT-SFT — 04 has its own
# live component, CptSftPlan.cl.jac).
glob PLAN_WS: str = "03";
glob PLAN_SOURCE: str = "03-new/docs/workflow.md";

# Date the hardcoded PHASES/CHECKLIST content below reflects. BUMP THIS whenever
# you edit either list — it is what the header shows the user.
glob AS_OF: str = "2026-07-14";

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

def:pub Plan(workspace: str = "") -> JsxElement {
    # ponytail: one transcribed doc, one workspace. Everything else gets the
    # empty state rather than a fabricated roadmap. A real multi-workspace PLAN
    # needs the docs read server-side (see module docstring) — out of scope here.
    if workspace != PLAN_WS {
        return <div className="flex h-full min-w-0 flex-1 flex-col">
            <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
                <span className="micro-label">PLAN</span>
                <span className="micro-label text-muted-foreground/80">
                    {("WORKSPACE " + workspace) if workspace else "NO WORKSPACE"}
                </span>
            </div>
            <div className="flex flex-1 items-center justify-center p-4">
                <div className="w-full max-w-md text-center">
                    <EmptyState
                        label="NO PLAN DOC FOR THIS WORKSPACE"
                        hint={"PLAN renders a hand-transcribed plan document. None has been written for this workspace — the only one that exists lives on workspace " + PLAN_WS + " (" + PLAN_SOURCE + ")."}
                    />
                </div>
            </div>
        </div>;
    }
    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">PLAN · CPT → SFT/DPO → GRPO</span>
            <div className="flex items-center gap-2">
                <span className="micro-label rounded border border-input px-1.5 py-0.5 text-muted-foreground">STATIC · HAND-MAINTAINED</span>
                <span className="micro-label text-muted-foreground/80">{PLAN_SOURCE}</span>
            </div>
        </div>
        <div className="border-b border-border px-4 py-1.5">
            <span className="stat-line text-muted-foreground">Not live status. This page is a hand-transcribed copy of {PLAN_SOURCE} (workspace {PLAN_WS} · CPT) as of {AS_OF} — it does not read the system and will not update as experiments move on.</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="relative exp-panel p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">PHASES</span>
                <div className="relative flex flex-col gap-0.5 pl-3">
                    <div className="absolute bottom-1 left-0 top-1 w-px bg-secondary"></div>
                    {for p in PHASES {
                        <div key={str(p["id"])} className="flex items-start gap-3 rounded px-2 py-1.5">
                            <span className="mt-0.5 shrink-0"><StatusGlyph status={str(p["status"])} showLabel={False} /></span>
                            <span className="shrink-0 font-mono text-xs text-muted-foreground/80" style={{"width": 26}}>{str(p["id"])}</span>
                            <div className="flex flex-col gap-0.5">
                                <span className="font-mono text-xs text-foreground">{str(p["title"])}</span>
                                <span className="stat-line text-muted-foreground">{str(p["note"])}</span>
                            </div>
                        </div>
                    }}
                </div>
            </div>

            <div className="relative exp-panel p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">CHECKLIST</span>
                <div className="flex flex-col gap-1">
                    {for c in CHECKLIST {
                        <div key={str(c["t"])} className="flex items-center gap-2 font-mono text-xs">
                            <span className={"shrink-0 " + ("text-foreground" if c["done"] else "text-muted-foreground/80")}>{"✓" if c["done"] else "○"}</span>
                            <span className={"text-foreground/80" if c["done"] else "text-muted-foreground"}>{str(c["t"])}</span>
                        </div>
                    }}
                </div>
                <div className="stat-line mt-3 text-muted-foreground/80">hand-transcribed as of {AS_OF} · not read from the system · source of truth: {PLAN_SOURCE}</div>
            </div>
        </div>
    </div>;
}
