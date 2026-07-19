"""App shell — workspace switcher + the active workspace's active section.

Three per-attempt workspaces (01 SFT/DPO, 02 RL/GRPO, 03 CPT). The rail switches
workspace (top) and section (below). All 11 section instances stay mounted and are
shown/hidden (CSS) so per-section state survives switches — critically, an in-flight
chat SSE stream keeps writing when you peek at another workspace. The last workspace
is remembered in localStorage; first-ever visit lands on 03 (current active work).
Each workspace's Chat gets its own history (persistence scopes by workspace) + a
default model.
"""

sv import from ..models { system_ram, loaded_model }
import from .NavRail { NavRail }
import from .Offline { Offline }
import from .shared.EmptyState { EmptyState }
import from .sections.Chat { Chat }
import from .sections.Train { Train }
import from .sections.Data { Data }
import from .sections.Evals { Evals }
import from .sections.RlData { RlData }
import from .sections.Results { Results }
import from .sections.Generate { Generate }
import from .sections.CptData { CptData }
import from .sections.CptTrain { CptTrain }
import from .sections.CptResults { CptResults }
import from .sections.Plan { Plan }

glob WS_DEFAULT_MODEL: dict = {"01": "qwen-dpo", "02": "qwen3coder-rl", "03": "qwen-q4"};

def:pub AppShell -> JsxElement {
    has workspace: str = "03",
        sections: dict = {"01": "chat", "02": "chat", "03": "chat"},
        online: int = -1,  # -1 unknown, 0 offline, 1 online
        layout: str = "split",
        ramGb: float = 0.0,
        loadedInfo: any = None,
        probeId: any = None;

    async def probe -> None {
        try {
            r = await system_ram();
            ramGb = float(str(r));
            online = 1;
        } except Exception {
            online = 0;
            return;
        }
        # cockpit layout shows resident model + memory; piggyback on the probe
        if layout == "cockpit" {
            try {
                loadedInfo = await loaded_model();
            } except Exception { }
        }
    }

    # Enable font antialiasing (the old app set this on <body> in layout.tsx; we
    # have no static HTML shell to edit). Restore the last workspace from
    # localStorage (first-ever visit stays on 03). Then probe the backend on
    # mount and re-probe every 3s.
    async can with entry {
        doc: any = document;
        doc.body.classList.add("antialiased");
        win: any = window;
        try {
            saved: any = win.localStorage.getItem("jacml.workspace");
            if saved == "01" or saved == "02" or saved == "03" {
                workspace = str(saved);
            }
        } except Exception { }
        # Re-apply the stored theme before the first real paint — the
        # loading/offline screens render before NavRail (and its ThemeSwitcher)
        # mounts. One-frame FOUC on the default theme is accepted.
        try {
            th: any = win.localStorage.getItem("jacml.theme");
            if th and th != "terminal" {
                doc.documentElement.setAttribute("data-theme", str(th));
            }
        } except Exception { }
        try {
            lo: any = win.localStorage.getItem("jacml.layout");
            if lo == "split" or lo == "rail" or lo == "icons" or lo == "cockpit" or lo == "topbar" or lo == "deck" or lo == "dock" {
                layout = str(lo);
            }
        } except Exception { }
        await probe();
        probeId = setInterval(lambda -> None { probe(); }, 3000);
    }

    can with exit {
        if probeId { clearInterval(float(str(probeId))); }
    }

    def goWorkspace(w: str) -> None {
        workspace = w;
        win: any = window;
        try {
            win.localStorage.setItem("jacml.workspace", w);
        } except Exception { }
    }

    def applyLayout(l: str) -> None {
        layout = l;
        win: any = window;
        try {
            win.localStorage.setItem("jacml.layout", l);
        } except Exception { }
    }

    # `sections` is per-workspace; rebuild a fresh dict from the fixed keys (never
    # mutate state in place; never `for k in sections` — iterating a `has dict`
    # compiles to for-of on a plain JS object → "sections is not iterable"; never
    # name the local `sections` — a same-name local compiles to setSections during
    # render → infinite re-render).
    def go(s: str) -> None {
        nd: dict = {
            "01": str(sections["01"]),
            "02": str(sections["02"]),
            "03": str(sections["03"])
        };
        nd[workspace] = s;
        sections = nd;
    }

    def slot(ws: str, s: str) -> str {
        vis = ws == workspace and s == str(sections[ws]);
        return "flex min-w-0 flex-1" if vis else "hidden";
    }

    if online == 0 {
        return <Offline onRetry={lambda -> None { probe(); }} />;
    }
    if online == -1 {
        return <div className="flex h-screen items-center justify-center bg-background"><EmptyState label="CONNECTING" pulse={True} /></div>;
    }
    return <div className={"flex h-screen overflow-hidden " + ("flex-col" if layout == "topbar" or layout == "deck" or layout == "split" else "")} data-ws={workspace} data-layout={layout}>
        {layout == "split" and <NavRail
            workspace={workspace} section={sections[workspace]}
            onWorkspace={goWorkspace} onSection={go}
            layout={layout} onLayout={applyLayout}
            loadedInfo={loadedInfo} ramGb={ramGb} part="top"
        />}
        {layout != "split" and <NavRail
            workspace={workspace} section={sections[workspace]}
            onWorkspace={goWorkspace} onSection={go}
            layout={layout} onLayout={applyLayout}
            loadedInfo={loadedInfo} ramGb={ramGb}
        />}
        <div className={"flex min-h-0 min-w-0 flex-1 " + ("pb-16" if layout == "dock" else "")}>
            {layout == "split" and <NavRail
                workspace={workspace} section={sections[workspace]}
                onWorkspace={goWorkspace} onSection={go}
                layout={layout} onLayout={applyLayout}
                loadedInfo={loadedInfo} ramGb={ramGb} part="side"
            />}
            <div className={slot("01", "chat")}><Chat workspace="01" defaultModel={str(WS_DEFAULT_MODEL["01"])} /></div>
            <div className={slot("01", "data")}><Data active={workspace == "01" and str(sections["01"]) == "data"} /></div>
            <div className={slot("01", "train")}><Train active={workspace == "01" and str(sections["01"]) == "train"} /></div>
            <div className={slot("01", "results")}><Evals active={workspace == "01" and str(sections["01"]) == "results"} /></div>
            <div className={slot("01", "plan")}><Plan workspace="01" /></div>

            <div className={slot("02", "chat")}><Chat workspace="02" defaultModel={str(WS_DEFAULT_MODEL["02"])} /></div>
            <div className={slot("02", "data")}><RlData /></div>
            <div className={slot("02", "train")}><Generate /></div>
            <div className={slot("02", "results")}><Results /></div>
            <div className={slot("02", "plan")}><Plan workspace="02" /></div>

            <div className={slot("03", "chat")}><Chat workspace="03" defaultModel={str(WS_DEFAULT_MODEL["03"])} /></div>
            <div className={slot("03", "data")}><CptData /></div>
            <div className={slot("03", "train")}><CptTrain active={workspace == "03" and str(sections["03"]) == "train"} /></div>
            <div className={slot("03", "results")}><CptResults active={workspace == "03" and str(sections["03"]) == "results"} /></div>
            <div className={slot("03", "plan")}><Plan workspace="03" /></div>
        </div>
    </div>;
}
