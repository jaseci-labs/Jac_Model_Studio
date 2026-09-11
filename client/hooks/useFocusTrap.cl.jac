"""useFocusTrap — keeps Tab / Shift-Tab inside an open dialog or drawer.

Every overlay in this app (WorkspaceSettings, AssistantPanel, CommandPalette,
ShortcutSheet, ApiKeyModal) already ran the same `useEffect` on `open`: add a
document Escape listener, move focus onto the panel, and restore focus to the
previously-focused element in the cleanup. The one thing all five explicitly
gave up on — five separate `# ponytail: no focus trap` notes — was Tab: focus
walked straight out of the panel and into the page behind it, which is dead
scenery while `aria-modal="true"` is up. This hook is that missing piece, and
ONLY that piece:

  * initial focus (a) and focus restore (c) stay where they already work, in
    each component's existing Escape effect. Duplicating them here would be
    actively wrong for (c): effects run in declaration order, so a second
    `prev = document.activeElement` captured after the panel already focused
    itself would "restore" focus to the panel that is being unmounted.
  * this hook is therefore side-effect-only and returns nothing, matching the
    shape of hooks/useConfirmReset.

Call it UNCONDITIONALLY (it wraps a `useEffect`, so it must sit above any early
`return` in the component) and AFTER the component's own open-effect, so that
by the time the safety net below runs, the panel has already focused itself:

    panelRef: any = useRef(None);
    ...
    useFocusTrap(panelRef, open);      # after the Escape useEffect
    ...
    <aside ref={panelRef} role="dialog" aria-modal="true" tabIndex={-1}>

`panelRef` is a React ref to the dialog container, read at EVENT time (never
captured into the closure), so a re-render that swaps the node cannot leave the
trap pointing at a detached element.

Wrapping rules, given `items` = the panel's focusable descendants in DOM order:
  * Shift-Tab on the first item  -> last item.
  * Tab on the last item         -> first item.
  * either, while the container itself holds focus (it is `tabIndex={-1}`, so it
    IS the active element right after open) -> last / first. Without this case
    the very first Shift-Tab after opening a drawer escaped it, which is the
    exact bug being fixed.
  * no focusable descendants at all -> park focus on the container.

Stacked overlays: the ⌘K palette can open over the assistant drawer, so two
traps can be listening at once. A trap whose panel does not hold focus stands
down IF something else with `role="dialog"` does — otherwise the lower dialog
would yank focus out of the one on top. It only pulls focus back when focus is
loose in the page (e.g. a scrim click left it on <body>).
"""

import from react { useEffect }

"""Focusable descendants, in DOM order. `:not([disabled])` mirrors the guard
buttons across the app rely on, and `[tabindex='-1']` is excluded so the dialog
container itself never counts as one of its own stops."""
glob:pub FOCUSABLE_SEL: str =
    "a[href], area[href], button:not([disabled]), input:not([disabled]):not([type='hidden']), "
    + "select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1']), "
    + "[contenteditable='true'], audio[controls], video[controls], details > summary";

def:pub useFocusTrap(panelRef: any, open: bool) {
    useEffect(lambda {
        if not open or panelRef is None { return lambda { }; }
        doc: any = document;
        onKey = lambda(e: any) {
            if str(e.key) != "Tab" { return; }
            panel: any = panelRef.current;
            if not panel { return; }
            cur: any = doc.activeElement;
            inside: bool = bool(cur and panel.contains(cur));
            # Structural guard, not a try/except (a JS TypeError is not a Jac
            # Exception): a target with no `.closest` is treated as "not in a
            # dialog", i.e. loose focus we are allowed to reclaim.
            other: any = cur.closest('[role="dialog"]') if (cur and cur.closest) else None;
            if not inside and other { return; }

            items: list[any] = list(panel.querySelectorAll(FOCUSABLE_SEL));
            if len(items) == 0 {
                e.preventDefault();
                panel.focus();
                return;
            }
            first: any = items[0];
            last: any = items[len(items) - 1];
            back: bool = bool(e.shiftKey);

            # Focus loose in the page, or parked on the container itself: pull it
            # to the edge the user is tabbing toward.
            if not inside or cur == panel {
                e.preventDefault();
                if back { last.focus(); } else { first.focus(); }
                return;
            }
            if back and cur == first {
                e.preventDefault();
                last.focus();
            } elif (not back) and cur == last {
                e.preventDefault();
                first.focus();
            }
        };
        doc.addEventListener("keydown", onKey);
        return lambda {
            doc.removeEventListener("keydown", onKey);
        };
    }, [open]);
}
