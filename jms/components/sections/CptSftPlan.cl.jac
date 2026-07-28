"""PLAN section (workspace 04 CPT-SFT) — three-arm protocol status.

Live status view (mirrors Plan.cl.jac's read-only shape, but reads real on-disk
state via cptsft.sv.jac instead of hardcoding it): dataset-build status (fresh:
done with real counts; post_cptv2: pending/done per real check) + the three-arm
Incumbent/A/B/C table (base model · dataset · train · eval), honestly showing
"not started" where true. A REPORTING page — no launch buttons (Train tab covers
launching generically).
"""

sv import from ...cptsft { cptsft_plan_status }
import from ..shared.StatTile { StatTile }

def:pub CptSftPlan -> JsxElement {
    has status: any = None,
        loadErr: str = "";

    async can with entry {
        try {
            status = await cptsft_plan_status();
        } except Exception as e {
            # Unguarded this was an un-.catch()ed async IIFE: the rejection went
            # nowhere and `status` stayed None, so the page said "loading…" forever.
            loadErr = "plan status failed · " + str(e);
        }
    }

    def _glyph(ok: bool) -> str {
        return "✓" if ok else "○";
    }

    def _tiles() -> JsxElement {
        if not status {
            if loadErr {
                return <span className="micro-label" style={{"color": "var(--danger)"}}>{loadErr}</span>;
            }
            return <span className="micro-label">loading…</span>;
        }
        s: any = status;
        return <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <StatTile label="FRESH.BUILD" value={"DONE" if s["fresh_done"] else "PENDING"} sub={str(s["sft_total"]) + " SFT · " + str(s["dpo_pairs"]) + " DPO"} dim={not s["fresh_done"]} />
            <StatTile label="POST_CPTV2" value={"BUILT" if s["post_cptv2_exists"] else "PENDING"} sub="Arm B/C dataset" dim={not s["post_cptv2_exists"]} />
            <StatTile label="CPT-V2.BASE" value={"READY" if s["cptv2_base_exists"] else "MISSING"} sub="Arm B base adapter" dim={not s["cptv2_base_exists"]} />
            <StatTile label="HOLDOUTS" value={str(s["holdout_total"])} sub="carved eval rows" dim={False} />
        </div>;
    }

    def _build_status() -> JsxElement {
        if not status {
            return <span></span>;
        }
        s: any = status;
        pool: any = s["pool"];
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">DATASET.BUILD</span>
            <div className="flex flex-col gap-1 font-mono text-xs">
                <div className="flex items-center gap-2">
                    <span className={"shrink-0 " + ("text-foreground" if s["fresh_done"] else "text-muted-foreground/80")}>{_glyph(bool(s["fresh_done"]))}</span>
                    <span className="text-foreground/80">fresh — {str(s["sft_total"])} SFT / {str(s["dpo_pairs"])} DPO · frozen {str(pool["frozen_at"]) if pool["frozen_at"] else "—"} · {str(pool["n_hashes"])} pool hashes</span>
                </div>
                <div className="flex items-center gap-2">
                    <span className={"shrink-0 " + ("text-foreground" if s["post_cptv2_exists"] else "text-muted-foreground/80")}>{_glyph(bool(s["post_cptv2_exists"]))}</span>
                    <span className={"text-foreground/80" if s["post_cptv2_exists"] else "text-muted-foreground"}>post_cptv2 — {"built" if s["post_cptv2_exists"] else "not started (only fresh exists on disk)"}</span>
                </div>
            </div>
        </div>;
    }

    def _arms() -> JsxElement {
        if not status {
            return <span></span>;
        }
        arms: list = list(status["arms"]);
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">THREE-ARM.PROTOCOL</span>
            <div className="overflow-x-auto">
                <table className="w-full font-mono text-xs">
                    <thead>
                        <tr className="text-muted-foreground">
                            <th className="py-1 text-left">arm</th>
                            <th className="text-left">base model</th>
                            <th className="text-left">dataset</th>
                            <th className="text-left">train</th>
                            <th className="text-left">eval</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for a in arms {
                            <tr key={str(a["arm"])} className="border-t border-border text-foreground/80">
                                <td className="py-1 pr-3 text-foreground">{str(a["arm"])}</td>
                                <td className="pr-3 text-muted-foreground">{str(a["base"])}</td>
                                <td className="pr-3 text-muted-foreground">{str(a["dataset"])}</td>
                                <td className="pr-3 text-muted-foreground">{str(a["train"])}</td>
                                <td className="text-muted-foreground">{str(a["eval"])}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div>
            <div className="stat-line mt-3 text-muted-foreground/80">status read live from disk + the caller's results tree · pending shown honestly</div>
        </div>;
    }

    def _runs() -> JsxElement {
        if not status {
            return <span></span>;
        }
        runs: list = list(status["arm_runs"]);
        if len(runs) == 0 {
            return <div className="relative exp-panel p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">ARM.RUNS (live)</span>
                <div className="stat-line py-2 text-muted-foreground">no Arm A/B/C training runs found in the results tree yet</div>
            </div>;
        }
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">ARM.RUNS (live)</span>
            <div className="flex flex-col gap-1 font-mono text-xs">
                {for r in runs {
                    <div key={str(r["name"]) + str(r["mode"])} className="flex items-center gap-2 text-foreground/80">
                        <span className="text-foreground">{str(r["name"])}</span>
                        <span className="text-muted-foreground">· {str(r["mode"])} · {str(r["status"])}</span>
                    </div>
                }}
            </div>
        </div>;
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">PLAN · CPT-SFT THREE-ARM PROTOCOL</span>
            <span className="micro-label text-muted-foreground/80">04-cpt-sft/docs</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            {_tiles()}
            {_build_status()}
            {_arms()}
            {_runs()}
        </div>
    </div>;
}
