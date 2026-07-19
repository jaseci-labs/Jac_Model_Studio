"""TRAIN section (workspace 03 CPT) — launch/monitor the single CPT LoRA run.

Simpler than 01's Train section: one named run ("cpt-v1", the config in
03-new/cpt_train/config.yaml), no per-mode form, no HISTORY/compare (there's
only ever one CPT run in flight). START/STOP + live status + loss/lr/tok-s
charts, polled every 2.5s while this section is active — same feed
live/stalled/nofeed tracker as 01's Train section, same MonoChart components.
Backed by cpt.sv.jac's start_cpt_training/stop_cpt_training/get_cpt_status.
"""

import from react { useEffect }
sv import from ...cpt { start_cpt_training, stop_cpt_training, get_cpt_status }
import from ..shared.StatusGlyph { StatusGlyph }
import from ..shared.StatTile { StatTile }
import from ..shared.LogView { LogView }
import from ..shared.MonoChart { MonoChart }
import from ..shared.Button { Button }

glob RUN_NAME: str = "cpt-v1";
glob CC: dict = {"loss": "var(--chart-2)", "lr": "var(--chart-1)", "tps": "var(--chart-5)"};

def _fix(v: any, n: int) -> str {
    return str(v.toFixed(n));
}

def:pub CptTrain(active: bool) -> JsxElement {
    has status: any = None,
        error: str = "",
        feed: str = "nofeed",
        stalledFor: int = 0;

    async def _poll(tracker: dict) -> None {
        try {
            s = await get_cpt_status(name=RUN_NAME);
            status = s;
            error = "";
            running = str(s["status"]) == "running";
            if not running {
                feed = "nofeed";
                return;
            }
            li = int(str(s["last_iter"]));
            if li > int(str(tracker["iter"])) {
                tracker["iter"] = li;
                tracker["same"] = 0;
                feed = "live";
                stalledFor = 0;
            } else {
                sm = int(str(tracker["same"])) + 1;
                tracker["same"] = sm;
                if sm >= 12 {
                    feed = "stalled";
                    stalledFor = int(sm * 5 / 2);
                }
            }
        } except Exception {
            error = "fetch error";
        }
    }

    useEffect(lambda {
        iv: any = None;
        if active {
            tracker: dict = {"iter": -1, "same": 0};
            cb = lambda { _poll(tracker); };
            cb();
            iv = setInterval(cb, 2500);
        }
        return lambda { if iv is not None { clearInterval(float(str(iv))); } };
    }, [active]);

    async def doStart() -> None {
        try {
            s = await start_cpt_training(name=RUN_NAME);
            status = s;
            error = "";
        } except Exception {
            error = "start failed";
        }
    }
    async def doStop() -> None {
        try {
            s = await stop_cpt_training(name=RUN_NAME);
            status = s;
        } except Exception {
            error = "stop failed";
        }
    }

    def _feedChip() -> JsxElement {
        if feed == "live" {
            return <span className="font-mono text-[10px] tracking-widest text-foreground">⦿ LIVE</span>;
        }
        if feed == "stalled" {
            return <span className="font-mono text-[10px] tracking-widest text-muted-foreground">⦿ STALLED {str(stalledFor)}s</span>;
        }
        return <span className="font-mono text-[10px] tracking-widest text-muted-foreground/70">○ NO FEED</span>;
    }

    isRunning = status is not None and str(status["status"]) == "running";

    lastIter = int(str(status["last_iter"])) if status is not None else 0;
    totalIters = int(str(status["total_iters"])) if status is not None else 2586;
    pct = (lastIter * 100.0) / totalIters if totalIters > 0 else 0.0;
    # leg/leg_ceiling are only nonzero for the CPT-v2 multi-leg flow
    # (start_cpt_leg in cpt.sv.jac); 0 for the plain cpt-v1 single run.
    leg = int(str(status["leg"])) if status is not None else 0;
    legCeiling = int(str(status["leg_ceiling"])) if status is not None else 0;

    train: list = list(status["train"]) if status is not None else [];
    val: list = list(status["val"]) if status is not None else [];
    lr: list = list(status["lr"]) if status is not None else [];
    tps: list = list(status["tps"]) if status is not None else [];
    lastTrain: any = train[len(train) - 1] if len(train) > 0 else None;
    lastVal: any = val[len(val) - 1] if len(val) > 0 else None;
    lastTps: any = tps[len(tps) - 1] if len(tps) > 0 else None;

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">TRAIN · CPT LoRA (cpt-v1)</span>
            <div className="flex items-center gap-3">
                {_feedChip()}
                <span className="micro-label text-muted-foreground/70">TRAIN.CTL</span>
            </div>
        </div>

        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="grid grid-cols-4 gap-3">
                <StatTile label="STATUS" value={(str(status["status"]).upper() if status is not None else "IDLE")} sub="" dim={False} />
                <StatTile label="ITER" value={f"{lastIter}/{totalIters}"} sub={_fix(pct, 1) + "%"} dim={False} />
                <StatTile label="TRAIN.LOSS" value={_fix(lastTrain["y"], 3) if lastTrain is not None else "·"} sub={("val " + _fix(lastVal["y"], 3)) if lastVal is not None else ""} dim={False} />
                <StatTile label="TOK/S" value={_fix(lastTps["y"], 0) if lastTps is not None else "·"} sub="" dim={False} />
            </div>

            <div className="relative rounded-md border border-border bg-card p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">RUN.CTL</span>
                <div className="flex items-center gap-3">
                    <StatusGlyph status={str(status["status"]) if status is not None else "idle"} showLabel={True} />
                    <div className="h-1 flex-1 rounded-full bg-accent">
                        <div className="h-1 rounded-full bg-primary transition-all" style={{"width": _fix(pct, 1) + "%"}}></div>
                    </div>
                </div>
                {status is not None and status["message"] and <p className="stat-line mt-2 text-muted-foreground">{str(status["message"])}</p>}
                {leg > 0 and <p className="stat-line mt-1 text-muted-foreground">LEG {str(leg)}/{str(legCeiling)}</p>}
                {status is not None and str(status["started"]) and <p className="stat-line mt-1 text-muted-foreground/70">STARTED {str(status["started"])}{(" · PID " + str(status["pid"])) if int(str(status["pid"])) > 0 else ""}</p>}
                <div className="mt-3 flex gap-2">
                    <Button variant="solid" onClick={lambda e: MouseEvent { doStart(); }} disabled={isRunning}>▶ START / RESUME</Button>
                    <Button variant="outline" onClick={lambda e: MouseEvent { doStop(); }} disabled={not isRunning}>■ STOP</Button>
                </div>
                {error and <p className="stat-line mt-1 text-muted-foreground">{error}</p>}
                <p className="stat-line mt-2 text-muted-foreground/70">3 epochs over 862 windows (2586 iters) · resumes from the last checkpoint if stopped and restarted</p>
            </div>

            <div className="grid grid-cols-2 gap-4">
                <MonoChart title="LOSS · train + val" data={train} secondary={val} live={feed == "live"} accent={str(CC["loss"])} expY={False} />
                <MonoChart title="LEARNING.RATE" data={lr} secondary={[]} live={False} accent={str(CC["lr"])} expY={True} />
                <MonoChart title="TOKENS/SEC" data={tps} secondary={[]} live={feed == "live"} accent={str(CC["tps"])} expY={False} />
            </div>

            <LogView text={str(status["log_tail"]) if status is not None and status["log_tail"] else ""} maxH="16rem" />
        </div>
    </div>;
}
