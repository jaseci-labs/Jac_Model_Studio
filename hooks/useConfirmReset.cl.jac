"""useConfirmReset — auto-disarms the app's two-click "SURE?" destructive confirms.

The two-click pattern (first click arms the button and flips its label to
"SURE?", second click actually deletes) lives in JmsProjects (project DELETE),
Evals (eval-history DEL) and WorkspaceSettings (workspace DELETE + section ✕).
Armed state used to be sticky: nothing but a second click cleared it, so a
button could sit armed indefinitely and a stray click on the same screen
position minutes later silently deleted a project / eval / workspace. Nothing in
this app is recoverable, so that was a data-loss bug, not a cosmetic one.

This hook is the single disarm mechanism for all of them. Call it once per
confirm state var, UNCONDITIONALLY (it wraps a `useEffect`, so it must sit above
any early `return` in the component), passing:

  * `armed` — the confirm state as a string. "" means nothing is armed. Passing
    the id (not a bool) means re-arming on a DIFFERENT row re-fires the effect
    and restarts that row's timer.
  * `reset` — a nullary callback that clears the confirm var.
  * `ms`    — timeout backstop, default 4s.

Three ways it disarms, all with the same `reset`:

  1. Escape — a document keydown, matching the Escape-closes-a-dialog wiring in
     Shortcuts.cl.jac / WorkspaceSettings.cl.jac. Deliberately does NOT
     stopPropagation: in a drawer, Escape disarming the button and closing the
     drawer are both correct.
  2. Pointer-down anywhere that is not inside the armed button. The armed button
     must carry `data-confirm-armed` (see CONFIRM_ARMED_SEL) for the hit test.
     `mousedown`, not `click`, on purpose: mousedown lands BEFORE React's click
     handler re-renders the row, so the attribute is still in the DOM when the
     second (confirming) click starts and the hit test correctly skips it.
  3. A 4s timeout, re-armed from scratch every time `armed` changes and cleared
     in the effect cleanup — same effect-local-timer-id shape as Toast's
     auto-dismiss, so nothing leaks across re-renders or unmount.
"""

import from react { useEffect }

"""The armed button must render `data-confirm-armed={"1" if armed else None}`
(React drops the attribute for a None value), which is what this selector finds."""
glob:pub CONFIRM_ARMED_SEL: str = "[data-confirm-armed]";

def:pub useConfirmReset(armed: str, reset: any, ms: float = 4000.0) {
    useEffect(lambda {
        if not armed or reset is None { return lambda { }; }
        doc: any = document;
        onKey = lambda(e: any) {
            if str(e.key) == "Escape" { reset(); }
        };
        onDown = lambda(e: any) {
            # Structural guard, not a try/except: a JS TypeError from a target
            # with no .closest is NOT a Jac Exception, so `except Exception`
            # would rethrow it and leave the button armed — the exact failure
            # this hook exists to prevent. No `closest` ⇒ treat as outside.
            t: any = e.target;
            inside: any = t.closest(CONFIRM_ARMED_SEL) if (t and t.closest) else None;
            if not inside { reset(); }
        };
        doc.addEventListener("keydown", onKey);
        doc.addEventListener("mousedown", onDown);
        tid: any = setTimeout(lambda { reset(); }, ms);
        return lambda {
            doc.removeEventListener("keydown", onKey);
            doc.removeEventListener("mousedown", onDown);
            clearTimeout(float(str(tid)));
        };
    }, [armed]);
}
