"""Chat right rail — prompt library + sampling controls + last-run stats.
Ports ui/components/rail.tsx."""

def _trunc(s: str) -> str {
    one = s.split(String.fromCharCode(10))[0];
    return (one[:54] + "…") if len(one) > 54 else one;
}

def _slider(
    label: str, val: float, lo: float, hi: float, step: float, fmt: str,
    onSet: Callable[([float], None)]
) -> JsxElement {
    return <div className="mb-3">
        <div className="mb-1 flex justify-between">
            <span className="micro-label">{label}</span>
            <span className="font-mono text-[11px] text-neutral-300">{fmt}</span>
        </div>
        <input
            type="range"
            min={str(lo)} max={str(hi)} step={str(step)} value={str(val)}
            onChange={lambda e: ChangeEvent { onSet(float(e.target.value)); }}
            className="w-full accent-neutral-400"
        />
    </div>;
}

def:pub Rail(
    prompts: list, temperature: float, topP: float, maxTokens: int, lastStats: any,
    collapsed: bool, onPick: Callable[([str], None)],
    onTemp: Callable[([float], None)], onTopP: Callable[([float], None)],
    onMaxTokens: Callable[([float], None)], onToggle: Callable[([], None)]
) -> JsxElement {
    has openCat: str = "py2jac";

    if collapsed {
        return <button
            onClick={lambda e: MouseEvent { onToggle(); }}
            className="flex w-8 shrink-0 items-center justify-center border-l border-neutral-800 bg-[#0d0d0d] text-neutral-500 hover:text-neutral-200"
        >⟨</button>;
    }
    return <div className="flex w-60 shrink-0 flex-col overflow-y-auto border-l border-neutral-800 bg-[#0d0d0d]">
        <div className="flex items-center justify-between border-b border-neutral-800 px-3 py-2.5">
            <span className="micro-label">PROMPT LIBRARY</span>
            <button onClick={lambda e: MouseEvent { onToggle(); }} className="micro-label text-neutral-600 hover:text-neutral-300">⟩</button>
        </div>
        <div className="p-2">
            {for cat in prompts {
                <div key={str(cat["id"])} className="mb-1">
                    <button
                        onClick={lambda e: MouseEvent { openCat = "" if openCat == str(cat["id"]) else str(cat["id"]); }}
                        className="flex w-full items-center justify-between rounded px-2 py-1 text-left font-mono text-[11px] text-neutral-300 hover:bg-[#161616]"
                    >
                        <span>{("▾ " if openCat == str(cat["id"]) else "▸ ") + str(cat["label"])}</span>
                        <span className="text-neutral-600">{str(len(list(cat["prompts"])))}</span>
                    </button>
                    {if openCat == str(cat["id"]) {
                        <div className="flex flex-col gap-0.5 pl-2">
                            {for (pi, pr) in enumerate(list(cat["prompts"])) {
                                <button
                                    key={str(pi)}
                                    onClick={lambda e: MouseEvent { onPick(str(pr)); }}
                                    className="truncate rounded px-2 py-1 text-left stat-line hover:bg-[#161616] hover:text-neutral-300"
                                    title={str(pr)}
                                >{_trunc(str(pr))}</button>
                            }}
                        </div>
                        skip;
                    }}
                </div>
            }}
        </div>

        <div className="dashed-rule mx-3" />
        <div className="border-b border-neutral-800 px-3 py-2.5"><span className="micro-label">SAMPLING</span></div>
        <div className="p-3">
            {_slider("TEMPERATURE", temperature, 0.0, 1.5, 0.05, f"{temperature:.2f}", onTemp)}
            {_slider("TOP_P", topP, 0.1, 1.0, 0.05, f"{topP:.2f}", onTopP)}
            {_slider("MAX_TOKENS", float(maxTokens), 128.0, 4096.0, 128.0, str(maxTokens), onMaxTokens)}
        </div>

        <div className="dashed-rule mx-3" />
        <div className="p-3">
            <div className="micro-label mb-2">LAST RUN</div>
            {if lastStats {
                <div className="font-mono text-[11px] leading-relaxed text-neutral-400">
                    <div>{str(lastStats["tps"])} tok/s</div>
                    <div>{str(lastStats["tokens"])} tokens</div>
                    <div>Δ {str(lastStats["gen_s"])}s · load {str(lastStats["load_s"])}s</div>
                </div>
                skip;
            }}
            {if not lastStats {
                <span className="stat-line">no run yet</span>
                skip;
            }}
        </div>
    </div>;
}
