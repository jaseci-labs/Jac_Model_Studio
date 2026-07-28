"""JobWatch.cl.jac — headless. Turns "a detached GPU job finished" into a toast.

Mount ONCE per shell. Renders nothing; it only polls `active_jobs()` (the same
read-only snapshot WorkspaceBar's count badge uses — this deliberately does NOT
render a second badge) and raises a toast when the RUNNING COUNT DROPS.

Why a separate poll from WorkspaceBar's: WorkspaceBar is owned by someone else
and holds the count in its own `has`, unreachable from here.
# ponytail: two 6s polls of one local file/proc read. Sharing them needs a
module-level store both components import, i.e. an edit to WorkspaceBar.

=== Not firing a spurious "job finished" ===
All watcher state lives in `useRef`s, NOT in `has` fields: the interval callback
is created once inside a `[]`-deps effect, so a `has` read inside it would see
its first-render value forever (the leak/stale class this repo has shipped six
times). The interval id is effect-LOCAL and cleared in the cleanup.

Four guards, each blocking a different false positive:
  1. `prevRef` starts at the sentinel -1 = "no baseline yet". The FIRST successful
     poll only records the baseline; -1 can never satisfy the drop test, so a page
     load while 0 jobs run (or while 3 do) never toasts.
  2. Only a STRICT decrease (`running < prev`) toasts. Equal or rising never does.
  3. A failed fetch does NOT touch the baseline and does NOT compare — otherwise
     one dropped request would read as `3 -> (error) -> 3` on reconnect, or worse,
     a transient `0` would look like completion.
  4. After 3 CONSECUTIVE failures the baseline is reset to the -1 sentinel, so
     coming back from a long server outage re-baselines silently instead of
     reporting a phantom drop that happened while we were blind.

Ceiling: the shell unmounts when you switch surfaces (JMS <-> Experiments <->
hub), which resets the baseline — a job finishing during that gap is missed
rather than mis-reported. Under-reporting is the correct failure direction here.
"""

import from react { useEffect, useRef }
sv import from ...jobs { active_jobs }
import from .Toast { pushToast }

def:pub JobWatch() -> JsxElement {
    prevRef: any = useRef(-1);
    failRef: any = useRef(0);

    useEffect(lambda {
        async def poll -> None {
            running: int = 0;
            heavy: str = "";
            ok: bool = True;
            try {
                s = await active_jobs();
                running = int(str(s["running"]));
                heavy = str(s["heavy"]);
            } except Exception {
                ok = False;
            }
            if not ok {
                fails: int = int(str(failRef.current)) + 1;
                failRef.current = fails;
                if fails >= 3 { prevRef.current = -1; }
                return;
            }
            failRef.current = 0;
            prev: int = int(str(prevRef.current));
            prevRef.current = running;
            if prev < 0 or running >= prev { return; }
            done: int = prev - running;
            title: str = "Background job finished" if done == 1 else (str(done) + " background jobs finished");
            body: str = "";
            if running > 0 {
                body = str(running) + " still running";
            } elif heavy {
                body = "GPU slot held by " + heavy;
            } else {
                body = "GPU slot is free";
            }
            pushToast("success", title, body);
        }
        poll();
        iv: any = setInterval(lambda { poll(); }, 6000);
        return lambda { clearInterval(float(str(iv))); };
    }, []);

    return <></>;
}
