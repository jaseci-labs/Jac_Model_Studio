"""App shell — ports ui/components/app-shell.tsx.

Left nav rail + the active section. All sections stay mounted and are shown/
hidden (CSS) so per-section state (chat history, loaded evals) survives tab
switches, matching the original's `visited` behavior.
"""

import from .NavRail { NavRail }
import from .sections.Chat { Chat }
import from .sections.Train { Train }
import from .sections.Data { Data }
import from .sections.Evals { Evals }
import from .sections.Rl { Rl }

def:pub AppShell -> JsxElement {
    has section: str = "chat";

    def go(s: str) -> None {
        section = s;
    }

    def slot(s: str) -> str {
        return "flex min-w-0 flex-1" if s == section else "hidden";
    }

    return <div className="flex h-screen overflow-hidden">
        <NavRail section={section} onSection={go} />
        <div className={slot("chat")}><Chat /></div>
        <div className={slot("train")}><Train /></div>
        <div className={slot("data")}><Data /></div>
        <div className={slot("evals")}><Evals /></div>
        <div className={slot("rl")}><Rl /></div>
    </div>;
}
