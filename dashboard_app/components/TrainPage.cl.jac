"""Train: start/stop an SFT or DPO run and watch its orchestrator log.

Shells out (server-side) to run_probe.sh / run_dpo.sh via services/jobs.sv.jac.
The trainer's loss curves live on the Monitor screen; this screen shows run
status + the run-<mode>.log (quantize/fuse/eval stage progress).
"""

sv import from ..services.jobs { JobStatus, start_training, stop_training, job_status }

def:pub Field(label: str, value: str, hint: str, onChange: Callable[([str], None)]) -> JsxElement {
    def handle(e: ChangeEvent) {
        onChange(e.target.value);
    }
    return <label className="dg-field">
        <span className="dg-label">{label}</span>
        <input value={value} onChange={handle} placeholder={hint} className="dg-input" style={{"minWidth": "118px"}} />
    </label>;
}

def:pub StatusBadge(status: str) -> JsxElement {
    dot: str = "dg-dot-idle";
    if status == "running" { dot = "dg-dot-run"; }
    if status == "done" { dot = "dg-dot-done"; }
    if status == "failed" { dot = "dg-dot-fail"; }
    return <span className="dg-badge"><span className={"dg-dot " + dot}></span>{status}</span>;
}

def:pub TrainPage() -> JsxElement {
    has model_id: str = "Qwen/Qwen3-Coder-30B-A3B-Instruct",
        name: str = "qwen",
        mode: str = "sft",
        eval_every: str = "60",
        subset: str = "50",
        dry_iters: str = "30",
        skip_dry: bool = False,
        dpo_iters: str = "200",
        dpo_lr: str = "1e-6",
        dpo_beta: str = "0.1",
        status: JobStatus | None = None,
        tick: int = 0;

    async can with [name, mode, tick] entry {
        if name != "" {
            status = await job_status(name, mode);
            schedule_next();
        }
    }

    def schedule_next -> None {
        setTimeout(lambda { tick = tick + 1; }, 2500);
    }

    async def do_start -> None {
        if mode == "sft" {
            opts: dict = {"EVAL_EVERY": eval_every, "SUBSET": subset, "DRY_ITERS": dry_iters, "SKIP_DRY": "1" if skip_dry else "0"};
        } else {
            opts: dict = {"DPO_ITERS": dpo_iters, "DPO_LR": dpo_lr, "DPO_BETA": dpo_beta, "SUBSET": subset};
        }
        status = await start_training(model_id, name, mode, opts);
        tick = tick + 1;
    }

    async def do_stop -> None {
        status = await stop_training(name, mode);
        tick = tick + 1;
    }

    def set_mode(m: str) -> None {
        mode = m;
    }

    is_running: bool = status is not None and status.status == "running";

    return <div className="dg-page">
        <div className="dg-banner dg-mb">
            <strong>⚠ Heavy.</strong> A 30B run is hours long and near the 48GB Metal ceiling — don't launch SFT and
            DPO for the same model at once. SFT iters come from <span className="dg-mono">configs/lora.yaml</span>;
            the knobs below are the env vars the scripts honour.
        </div>

        <div className="dg-row-end dg-mb">
            <Field label="base model (HF id)" value={model_id} hint="org/model" onChange={lambda v: str { model_id = v; }} />
            <Field label="short name" value={name} hint="qwen" onChange={lambda v: str { name = v; }} />
            <div className="dg-field">
                <span className="dg-label">mode</span>
                <div className="dg-seg">
                    <button onClick={lambda (e: MouseEvent) { set_mode("sft"); }} className={"dg-seg-btn dg-active" if mode == "sft" else "dg-seg-btn"}>SFT</button>
                    <button onClick={lambda (e: MouseEvent) { set_mode("dpo"); }} className={"dg-seg-btn dg-active" if mode == "dpo" else "dg-seg-btn"}>DPO</button>
                </div>
            </div>
        </div>

        <div className="dg-row-end dg-mb">
            {if mode == "sft" {
                <Field key="ee" label="EVAL_EVERY (s)" value={eval_every} hint="60" onChange={lambda v: str { eval_every = v; }} />
                <Field key="ss" label="SUBSET" value={subset} hint="50" onChange={lambda v: str { subset = v; }} />
                <Field key="di" label="DRY_ITERS" value={dry_iters} hint="30" onChange={lambda v: str { dry_iters = v; }} />
                <label key="sd" className="dg-row" style={{"gap": "0.4rem", "color": "#8b8b96", "fontSize": "0.78rem", "alignSelf": "flex-end", "paddingBottom": "0.5rem"}}>
                    <input type="checkbox" checked={skip_dry} onChange={lambda (e: ChangeEvent) { skip_dry = not skip_dry; }} />
                    <span>skip dry-run</span>
                </label>
            }}
            {if mode == "dpo" {
                <Field key="it" label="DPO_ITERS" value={dpo_iters} hint="200" onChange={lambda v: str { dpo_iters = v; }} />
                <Field key="lr" label="DPO_LR" value={dpo_lr} hint="1e-6" onChange={lambda v: str { dpo_lr = v; }} />
                <Field key="be" label="DPO_BETA" value={dpo_beta} hint="0.1" onChange={lambda v: str { dpo_beta = v; }} />
                <Field key="ds" label="SUBSET" value={subset} hint="50" onChange={lambda v: str { subset = v; }} />
            }}
        </div>

        <div className="dg-row dg-mb">
            <button onClick={do_start} disabled={is_running} className="dg-btn dg-btn-primary">Start {mode}</button>
            <button onClick={do_stop} disabled={not is_running} className="dg-btn dg-btn-danger">Stop</button>
            {status is not None and <StatusBadge status={status.status} />}
            {status is not None and status.message != "" and <span className="dg-faint">{status.message}</span>}
        </div>

        {status is not None and <div className="dg-row dg-mb" style={{"gap": "1.4rem"}}>
            <span className="dg-faint">pid {str(status.pid)}</span>
            <span className="dg-faint">iter {str(status.last_iter)}</span>
            <span className="dg-faint">started {status.started if status.started != "" else "—"}</span>
        </div>}

        {status is not None and <pre className="dg-log" style={{"maxHeight": "320px"}}>{status.log_tail if status.log_tail != "" else "(no output yet)"}</pre>}
    </div>;
}
