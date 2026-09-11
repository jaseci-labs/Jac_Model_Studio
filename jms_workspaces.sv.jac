"""studio - JMS workspace grouping (OSP graph, per-user, LEAN).

JMS workspaces exist to GROUP projects at the top nav bar (WorkspaceBar /
NavRail are already generic renderers over a `{workspaces:[{id,label,accent}]}`
layout dict — see workspace.sv.jac's `ui_layout`). Unlike Experiments'
`Workspace` node, a `JmsWorkspace` carries NO `WorkspaceSection` children and
NO `default_model`/`files` — a project keeps its own internal stage rail
(SOURCES/GENERATE/CURATE/TRAIN/EVAL), so there is nothing here to mount.

Graph shape: `root ++> JmsWorkspace`, one layer, seeded once (backfill-safe —
new `_SEED_JMS_WORKSPACES` entries get added to an already-seeded graph without
duplicating what's there, mirroring `workspace.sv.jac:_ensure_workspaces_seeded`).
Every read/write walks the CALLER'S OWN root (`[root -->][?:JmsWorkspace]`), so
this is multi-tenant isolated for free — same guarantee jms_projects.sv.jac
relies on.

This task (B1) does NOT touch jms_projects.sv.jac: a project's `group_id`
field + the workspace-filtered `list_projects`/`create_project` land in a
later task. `delete_jms_workspace` here only removes the `JmsWorkspace` node.

Checker notes (jaclang 0.16.1, same as jms_projects.sv.jac): `root ++> X(...)`
returns a LIST — unwrap `[0]` before touching the new node; dict values
crossing the RPC boundary are `any`.
"""

# ------------------------------------------------------------------- views -----
"""One workspace as the top nav bar sees it: just enough to render a tile."""
obj JmsWorkspaceView {
    has id: str = "",
        label: str = "",
        accent: str = "";
}

# ------------------------------------------------------------------- nodes -----
node JmsWorkspace {
    has wid: str = "",
        label: str = "",
        accent: str = "",
        sort_order: int = 0;
}

# --------------------------------------------------------------- seed data -----
# Fixed single-workspace seed. Mirrors workspace.sv.jac's backfill-safe seeding
# shape so a future entry can be appended here without duplicating "main" on an
# already-seeded graph.
glob _SEED_JMS_WORKSPACES: list[dict] = [
    {"wid": "main", "label": "MAIN", "accent": "ws01", "sort_order": 0}
];

# ------------------------------------------------------------------ finders ----
def _all_jms_workspaces() -> list[JmsWorkspace] {
    wss = [w for w in [root -->][?:JmsWorkspace]];
    wss.sort(key=lambda w: JmsWorkspace -> str {
        return str(w.sort_order).zfill(6) + w.wid;
    });
    return wss;
}

def _find_jms_workspace(wid: str) -> JmsWorkspace | None {
    for w in [root -->][?:JmsWorkspace] {
        if w.wid == wid { return w; }
    }
    return None;
}

# ------------------------------------------------------------------ seeding ----
"""Create the fixed workspace set on the caller's root the first time
(idempotent). Backfill-safe: if the graph already holds JmsWorkspace nodes,
only specs whose wid is missing get added (so a future new seed entry isn't
skipped forever on an already-seeded graph) — mirrors
workspace.sv.jac:_ensure_workspaces_seeded."""
def _seed_jms_workspaces() -> None {
    existing = [w for w in [root -->][?:JmsWorkspace]];
    present: list[str] = [];
    for w in existing { present.append(w.wid); }
    for spec in _SEED_JMS_WORKSPACES {
        if str(spec["wid"]) not in present {
            root ++> JmsWorkspace(
                wid=str(spec["wid"]), label=str(spec["label"]),
                accent=str(spec["accent"]), sort_order=int(str(spec["sort_order"]))
            );
        }
    }
}

def _jms_workspace_view(w: JmsWorkspace) -> JmsWorkspaceView {
    return JmsWorkspaceView(id=w.wid, label=w.label, accent=w.accent);
}

def _next_jms_workspace_id() -> str {
    max_n = 0;
    for w in [root -->][?:JmsWorkspace] {
        try {
            n = int(w.wid);
            if n > max_n { max_n = n; }
        } except Exception { }
    }
    nxt = max_n + 1;
    return ("0" + str(nxt)) if nxt < 10 else str(nxt);
}

def _next_jms_accent() -> str {
    accents = ["ws01", "ws02", "ws03", "ws04", "ws05", "ws06"];
    n = len([root -->][?:JmsWorkspace]);
    return accents[n % len(accents)];
}

# ---------------------------------------------------------------- endpoints ----
"""JMS workspace registry for the top nav bar — workspaces + a default. Reads
from the graph (root --> JmsWorkspace), seeding on first call. Plain `def` →
caller's isolated root, so workspaces are per-user."""
def jms_ui_layout() -> dict {
    _seed_jms_workspaces();
    wss = [_jms_workspace_view(w) for w in _all_jms_workspaces()];
    ids: list[str] = [];
    for w in wss { ids.append(w.id); }
    default_ws = wss[0].id if len(wss) > 0 else "main";
    return {
        "default_workspace": default_ws,
        "workspace_ids": ids,
        "workspaces": wss
    };
}

"""Add a new JMS workspace, sorted after every existing one. Returns the
refreshed layout dict (same shape as `jms_ui_layout`)."""
def create_jms_workspace(label: str, accent: str) -> dict {
    _seed_jms_workspaces();
    wid = _next_jms_workspace_id();
    acc = accent if accent else _next_jms_accent();
    root ++> JmsWorkspace(
        wid=wid, label=label, accent=acc, sort_order=len(_all_jms_workspaces())
    );
    return jms_ui_layout();
}

"""Patch label/accent on an existing JMS workspace (unknown wid is a no-op).
Returns the refreshed layout dict."""
def update_jms_workspace(wid: str, label: str, accent: str) -> dict {
    _seed_jms_workspaces();
    w = _find_jms_workspace(wid);
    if w {
        w.label = label;
        w.accent = accent;
    }
    return jms_ui_layout();
}

"""Delete a JMS workspace node (refuses to drop the last one, mirroring
workspace.sv.jac's delete_workspace floor). Projects are NOT touched by this
task — reassigning their group_id to "" lands with jms_projects.sv.jac's
group_id field in a later task. Returns the refreshed layout dict."""
def delete_jms_workspace(wid: str) -> dict {
    _seed_jms_workspaces();
    if len(_all_jms_workspaces()) > 1 {
        w = _find_jms_workspace(wid);
        if w { del w; }
    }
    return jms_ui_layout();
}

"""Persist a new top-bar tile order. Unknown ids are ignored. Returns the
refreshed layout dict."""
def reorder_jms_workspaces(ids: list) -> dict {
    _seed_jms_workspaces();
    for (i, wid) in enumerate(ids) {
        w = _find_jms_workspace(str(wid));
        if w { w.sort_order = i; }
    }
    return jms_ui_layout();
}
