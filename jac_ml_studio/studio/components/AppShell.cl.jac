"""App shell — ports ui/components/app-shell.tsx.

Left nav rail + the active section. All sections stay mounted and are shown/
hidden (CSS) so per-section state (chat history, loaded evals) survives tab
switches, matching the original's `visited` behavior.
"""

sv import from ..models { system_ram }
import from .NavRail { NavRail }
import from .Offline { Offline }
import from .sections.Chat { Chat }
import from .sections.Train { Train }
import from .sections.Data { Data }
import from .sections.Evals { Evals }
import from .sections.Rl { Rl }

def:pub AppShell -> JsxElement {
    has section: str = "chat",
        online: int = -1;  # -1 unknown, 0 offline, 1 online

    async def probe -> None {
        try {
            await system_ram();
            online = 1;
        } except Exception {
            online = 0;
        }
    }

    # Enable the `dark` variant + font antialiasing (the old app set these on
    # <html>/<body> in layout.tsx; we have no static HTML shell to edit). Then
    # probe the backend on mount and re-probe every 3s so a dropped server flips
    # the whole shell to the Offline card and reconnects automatically.
    async can with entry {
        doc: any = document;
        doc.documentElement.classList.add("dark");
        doc.body.classList.add("antialiased");
        await probe();
        setInterval(lambda -> None { probe(); }, 3000);
    }

    def go(s: str) -> None {
        section = s;
    }

    def slot(s: str) -> str {
        return "flex min-w-0 flex-1" if s == section else "hidden";
    }

    if online == 0 {
        return <Offline />;
    }
    if online == -1 {
        return <div className="h-screen bg-[#0a0a0a]" />;
    }
    return <div className="flex h-screen overflow-hidden">
        <NavRail section={section} onSection={go} />
        <div className={slot("chat")}><Chat /></div>
        <div className={slot("train")}><Train active={section == "train"} /></div>
        <div className={slot("data")}><Data /></div>
        <div className={slot("evals")}><Evals /></div>
        <div className={slot("rl")}><Rl /></div>
    </div>;
}
