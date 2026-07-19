"""GENERATE section (workspace 02 RL/GRPO) — deployable best-of-k Jac codegen.

Samples k completions from the SFT model and returns the first that compiles+runs
(rl_generate → 02-rl-grpo/rl/generate.py). The jac compiler is the verifier; on the
holdout this reaches ~78% vs ~55% greedy. Loads a 30B model per call (~1–2 min).
"""

sv import from ...rl { rl_generate }
import from ..shared.Button { Button }

def:pub Generate -> JsxElement {
    has genPrompt: str = "Write a Jac function `add(a: int, b: int) -> int` that returns their sum.",
        genJac: str = "",
        genNote: str = "",
        genBusy: bool = False;

    async def doGen() -> None {
        genBusy = True; genJac = ""; genNote = "sampling 8 completions + compiler-verifying (~1-2 min, loads the model)…";
        r = await rl_generate(genPrompt, 8);
        genBusy = False;
        genJac = str(r["jac"]);
        genNote = ("✓ " + str(r["note"])) if r["verified"] else ("⚠ " + str(r["note"]));
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">GENERATE · best-of-k + compiler verifier (~78%)</span>
            <span className="micro-label text-muted-foreground/70">{"sampling…" if genBusy else "SFT · deploy"}</span>
        </div>

        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="relative rounded-md border border-border bg-card p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-background px-2">GENERATE JAC · best-of-k + compiler verifier (~78%)</span>
                <textarea
                    className="w-full resize-y rounded-sm border border-input bg-background p-2 font-mono text-xs text-foreground outline-none placeholder:text-muted-foreground/70 focus:border-ring"
                    rows={4} value={genPrompt} onChange={lambda e: ChangeEvent { genPrompt = str(e.target.value); }}
                    placeholder="Describe the Jac function to generate…" />
                <div className="mt-2 flex items-center gap-3">
                    <Button variant="solid" disabled={genBusy} onClick={lambda e: MouseEvent { doGen(); }}>
                        {"generating…" if genBusy else "▷ generate (sample 8, keep the one that compiles+runs)"}
                    </Button>
                    {(<span className="stat-line text-muted-foreground">{genNote}</span>) if genNote else <span></span>}
                </div>
                {(<pre className="mt-3 overflow-x-auto rounded-sm border border-border bg-background p-3 font-mono text-xs text-foreground">{genJac}</pre>) if genJac else <span></span>}
                <div className="stat-line mt-2 text-muted-foreground/70">the jac compiler is the verifier — returns the first of 8 samples that compiles+runs. On the holdout this reaches ~78% vs ~55% greedy. Loads the SFT model per call (~1–2 min).</div>
            </div>
        </div>
    </div>;
}
