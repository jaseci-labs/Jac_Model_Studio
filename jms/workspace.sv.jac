"""studio - workspace configuration loader.

Single source of truth for studio's data-config (model registry, dataset file
maps, training-backend templates, cloud-run defaults). The app adapts to a
checkout by editing studio.workspace.toml, not code — it is the ONLY place that
names external artifacts (model dirs, datasets), and every such path may be
missing without crashing anything.

Resolution:
  1. <workspace_root>/studio.workspace.toml   (JAC_STUDIO_WORKSPACE override)
  2. <studio_root>/studio.workspace.toml      (shipped default, jms/)
  3. empty defaults                            (neither file present)

TOML (not YAML) because `jac` ships as a frozen binary whose bundled Python has
stdlib `tomllib` but no PyYAML — so the desktop app can rely on tomllib alone.

The parsed file is memoized for the process lifetime (config does not change at
runtime). Missing sections degrade to empty containers so the app still boots:
endpoints return empty lists, never crashes. All list accessors coerce items to
str (or dict) so TOML typing quirks (e.g. rung "1" vs int 1) can't leak through.
"""

import tomllib;
import paths;
import from pathlib { Path }

glob _FILE_NAME: str = "studio.workspace.toml";

# Parsed config + loaded flag, held in a mutable container so `_load` can flip the
# flag via __setitem__ (rebinding a `glob` name inside a function would shadow it
# as a local). The flag matters: an empty-but-valid file parses to {}, which is
# falsy, so guarding on _state["data"] alone would re-read every call.
glob _state: dict = {"loaded": False, "data": {}};

def _candidate_paths() -> list[Path] {
    return [paths.workspace_root() / _FILE_NAME, paths.studio_root() / _FILE_NAME];
}

"""Load + memoize the workspace toml (workspace_root wins, studio_root is the
shipped fallback). On a corrupt file or missing file, returns {} so accessors
degrade to empty defaults rather than raising. tomllib.loads on read_text() keeps
the checker happy (it can't infer the binary stream from open(...,'rb'))."""
def _load() -> dict {
    if _state["loaded"] { return dict(_state["data"]); }
    _state["loaded"] = True;
    for p in _candidate_paths() {
        if p.is_file() {
            try {
                _state["data"] = dict(tomllib.loads(p.read_text()));
            } except Exception {
                _state["data"] = {};
            }
            return dict(_state["data"]);
        }
    }
    return dict(_state["data"]);
}

"""A top-level section as a dict (never None)."""
def _sec(name: str) -> dict {
    raw = _load().get(name);
    return dict(raw) if isinstance(raw, dict) else {};
}

"""Coerce a yaml node to a dict (or {} if absent/wrong shape)."""
def _dict_of(raw: any) -> dict {
    return dict(raw) if isinstance(raw, dict) else {};
}

"""Coerce a yaml node to list[str] (or [] if absent/wrong shape). Items str'd."""
def _str_list(raw: any) -> list[str] {
    if not isinstance(raw, list) { return []; }
    return [str(x) for x in (raw as list)];
}

"""Which file the loader resolved (workspace > studio > ""). Handy for a future
/function/workspace_info debug endpoint."""
def resolved_path() -> str {
    for p in _candidate_paths() {
        if p.is_file() { return str(p); }
    }
    return "";
}

# --- model registry (models.sv.jac) -----------------------------------------

def model_registry() -> list[dict] {
    raw = _sec("models").get("registry");
    out: list[dict] = [];
    if not isinstance(raw, list) { return out; }
    for m in (raw as list) {
        if isinstance(m, dict) { out.append(dict(m)); }
    }
    return out;
}

def excluded_run_dirs() -> list[str] {
    return _str_list(_sec("models").get("excluded_run_dirs"));
}

# --- dataset browser (data.sv.jac) ------------------------------------------

def preview_files() -> list[list[str]] {
    raw = _sec("data").get("preview_files");
    out: list[list[str]] = [];
    if not isinstance(raw, list) { return out; }
    for pair in (raw as list) {
        if isinstance(pair, list) {
            out.append([str(x) for x in (pair as list)]);
        }
    }
    return out;
}

def data_sft_stat_files() -> list[str] {
    return _str_list(_sec("data").get("sft_stat_files"));
}

def data_split_files() -> dict {
    return _dict_of(_sec("data").get("split_files"));
}

# --- backend env-key whitelists (backends.sv.jac) --------------------------

def sft_keys() -> list[str] {
    return _str_list(_sec("train").get("sft_keys"));
}

def dpo_keys() -> list[str] {
    return _str_list(_sec("train").get("dpo_keys"));
}

# --- training backends (backends.sv.jac) ------------------------------------

def training_backend_default() -> str {
    raw = _sec("backends").get("default");
    return str(raw) if raw is not None else "mlx_local";
}

"""Top-level [backends] section minus the `default` scalar."""
def training_backends() -> dict {
    sec = _sec("backends");
    out: dict = {};
    for k in sec {
        if k == "default" { continue; }
        if isinstance(sec[k], dict) { out[str(k)] = dict(sec[k]); }
    }
    return out;
}

def training_backend(name: str) -> dict {
    raw = _sec("backends").get(name);
    return dict(raw) if isinstance(raw, dict) else {};
}

"""[cloudrun] section: supervised-run dataset defaults + supervisor policy
defaults (cloudruns.sv.jac)."""
def cloudrun_config() -> dict {
    return _dict_of(_sec("cloudrun"));
}

# --- UI layout (NavRail + AppShell) -----------------------------------------
# Workspaces live on the graph (root --> Workspace --> WorkspaceSection) and
# persist to SQLite (.jac/data/). Each Workspace owns its label, accent, default
# chat model, and an arbitrary list of file paths the user chose — no more rigid
# NN-* attempt-dir convention or sft_dpo/rl/cpt_train marker inference. The fixed
# set below seeds the graph once (when it holds no Workspace nodes); after that
# the graph is the single source of truth and survives restarts.

obj WorkspaceSectionView {
    has id: str = "",
        label: str = "",
        component: str = "";
}

obj WorkspaceView {
    has id: str = "",
        label: str = "",
        accent: str = "",
        default_model: str = "",
        files: list[str] = [],
        sections: list[WorkspaceSectionView] = [];
}

node WorkspaceSection {
    has sid: str = "",
        label: str = "",
        component: str = "",
        order: int = 0;

    def to_view -> WorkspaceSectionView {
        return WorkspaceSectionView(
            id=self.sid, label=self.label, component=self.component
        );
    }
}

node Workspace {
    has wid: str = "",
        label: str = "",
        accent: str = "",
        default_model: str = "",
        files: list[str] = [],
        sort_order: int = 0;

    def to_view -> WorkspaceView {
        secs = [s for s in [self -->][?:WorkspaceSection]];
        secs.sort(key=lambda (s: WorkspaceSection) -> int { return s.order; });
        return WorkspaceView(
            id=self.wid, label=self.label, accent=self.accent,
            default_model=self.default_model, files=list(self.files),
            sections=[s.to_view() for s in secs]
        );
    }
}

# --- the core rail ----------------------------------------------------------
# Every Experiments workspace shows the same generic sections, in this order:
#   CHAT · DATA · CLOUD
# (The per-experiment TRAIN/EVALS/RL/CPT/PLAN sections were removed with the
# 01-04 experiments they drove; training + eval now live in the JMS surface.)
#
# This is the single source of truth for BOTH first-run seeding (_seed_one_workspace)
# and the backfill migration (_migrate_core_rail), so the two can never drift.
glob _CORE_RAIL: list[dict] = [
    {"id": "chat", "label": "CHAT", "component": "Chat"},
    {"id": "data", "label": "DATA", "component": "Data"},
    {"id": "cloud", "label": "CLOUD", "component": "Cloud"}
];

# Canonical render position of every known section id. Used by the migration to
# slot new sections in at the right place relative to what is already there.
glob _CORE_RANK: dict[str, int] = {"chat": 0, "data": 1, "cloud": 2};

"""The full section spec (id/label/component, in render order) for one workspace."""
def _rail_spec_for(_wid: str) -> list[dict] {
    return [dict(item) for item in _CORE_RAIL];
}

"""The default chat model for new/repaired workspaces: the first registry entry."""
def _default_model_id() -> str {
    reg = model_registry();
    return str(reg[0]["id"]) if len(reg) > 0 else "";
}

# Fixed workspace set used to seed the graph on first run. Sections are NOT
# listed here: they come from _rail_spec_for(id) so seed and migration stay in
# lockstep. default_model "" = first model in the registry.
glob _SEED_WORKSPACES: list[dict] = [
    {
        "id": "01",
        "label": "MAIN",
        "accent": "ws01",
        "default_model": "",
        "files": []
    }
];

# --- one-shot graph migrations ----------------------------------------------
# `_ensure_workspaces_seeded` is a no-op once ANY Workspace exists, so changing
# _CORE_RAIL alone does nothing for a user whose graph is already in SQLite.
# Migrations below patch those live graphs. Each is guarded by a marker NODE
# (root --> GraphMigration) rather than a new `has` field on Workspace: adding a
# field to a persisted archetype has to survive unpickling of nodes written by
# the older schema, whereas a brand-new node type is always safe. The marker also
# gives requirement "run exactly once" for free — if the user deliberately
# deletes CLOUD afterwards, the migration is already marked and never resurrects it.

node GraphMigration {
    has name: str = "";
}

def _migration_applied(name: str) -> bool {
    for m in [root -->][?:GraphMigration] {
        if m.name == name { return True; }
    }
    return False;
}

def _mark_migration(name: str) -> None {
    if _migration_applied(name) { return; }
    root ++> GraphMigration(name=name);
    return;
}

glob _CORE_RAIL_MIGRATION: str = "core_rail_v1";

"""Add the core-rail sections this workspace is missing. Purely additive: never
deletes, relabels, or re-components a section that is already there.

Ordering: if the workspace still looks untouched (every section id is a known
rail id AND their current `order` already agrees with _CORE_RANK), the whole rail
is renumbered to the canonical ranks so the result renders in the intended
sequence. If the user has reordered the rail or added a section of their own, we
do NOT renumber — new sections are appended after the highest existing order, so
their layout survives intact."""
def _apply_core_rail(ws: Workspace) -> None {
    existing = [s for s in [ws -->][?:WorkspaceSection]];
    have: list[str] = [];
    for s in existing { have.append(s.sid); }

    missing: list[dict] = [];
    for item in _rail_spec_for(ws.wid) {
        if str(item["id"]) not in have { missing.append(item); }
    }
    if len(missing) == 0 { return; }

    existing.sort(key=lambda s: WorkspaceSection -> int { return s.order; });
    untouched = True;
    prev = -1;
    for s in existing {
        if s.sid not in _CORE_RANK { untouched = False; break; }
        rank = int(_CORE_RANK[s.sid]);
        if rank <= prev { untouched = False; break; }
        prev = rank;
    }

    if untouched {
        for item in missing {
            ws ++> WorkspaceSection(
                sid=str(item["id"]), label=str(item["label"]),
                component=str(item["component"]),
                order=int(_CORE_RANK[str(item["id"])])
            );
        }
        for s in existing { s.order = int(_CORE_RANK[s.sid]); }
        return;
    }

    nxt = 0;
    for s in existing {
        if s.order >= nxt { nxt = s.order + 1; }
    }
    for item in missing {
        ws ++> WorkspaceSection(
            sid=str(item["id"]), label=str(item["label"]),
            component=str(item["component"]), order=nxt
        );
        nxt = nxt + 1;
    }
    return;
}

"""Give every already-seeded workspace the uniform six-item rail. Runs at most
once per root; a fresh graph is seeded with the rail already correct and is
marked done immediately, so this body never executes for new users."""
def _migrate_core_rail() -> None {
    if _migration_applied(_CORE_RAIL_MIGRATION) { return; }
    for ws in [root -->][?:Workspace] {
        _apply_core_rail(ws);
    }
    _mark_migration(_CORE_RAIL_MIGRATION);
    return;
}

glob _LEGACY_PRUNE_MIGRATION: str = "legacy_prune_v1";

# The seeded workspaces of the deleted 02-04 experiments, identified by their
# EXACT seed `files` value so a workspace the user repointed is never touched.
glob _LEGACY_SEED_FILES: dict[str, list[str]] = {
    "02": ["02-rl-grpo"],
    "03": ["03-cpt-only"],
    "04": ["04-cpt-sft"]
};

"""One-shot cleanup after the 01-04 experiments were deleted:
- drop sections whose component no longer exists (Train/Evals/RlData/Cpt*/Plan/
  Results/Generate) — otherwise they render "UNKNOWN SECTION";
- drop the untouched seeded 02/03/04 workspaces (exact seed `files` match);
- workspace 01 still pointing at "01-sft-dpo" becomes the generic MAIN one;
- repoint any default_model that is no longer in the registry;
- never leave a workspace with zero sections (adds CHAT back)."""
def _migrate_legacy_prune() -> None {
    if _migration_applied(_LEGACY_PRUNE_MIGRATION) { return; }
    live: list[str] = [str(t["component"]) for t in SECTION_TYPES];
    reg_ids: list[str] = [str(m["id"]) for m in model_registry()];
    for ws in [root -->][?:Workspace] {
        legacy = _LEGACY_SEED_FILES.get(ws.wid);
        if legacy is not None and list(ws.files) == list(legacy) {
            _delete_workspace_node(ws);
            continue;
        }
        if ws.wid == "01" and list(ws.files) == ["01-sft-dpo"] {
            ws.files = [];
            if ws.label == "SFT/DPO" { ws.label = "MAIN"; }
        }
        for sec in [ws -->][?:WorkspaceSection] {
            if sec.component not in live { del sec; }
        }
        if len([ws -->][?:WorkspaceSection]) == 0 {
            ws ++> WorkspaceSection(sid="chat", label="CHAT", component="Chat", order=0);
        }
        if ws.default_model not in reg_ids { ws.default_model = _default_model_id(); }
    }
    _mark_migration(_LEGACY_PRUNE_MIGRATION);
    return;
}

# Construct one Workspace (+ its rail) from a _SEED_WORKSPACES spec at the given
# sort index. `root ++> Workspace(...)` returns a LIST — unwrap [0] before any
# attribute/edge access (a real bug class this file has hit before).
def _seed_one_workspace(spec: dict, sort_index: int) -> None {
    wid = str(spec["id"]);
    ws = (root ++> Workspace(
        wid=wid,
        label=str(spec["label"]),
        accent=str(spec["accent"]),
        default_model=str(spec["default_model"]) or _default_model_id(),
        files=[str(f) for f in (spec["files"] as list)],
        sort_order=sort_index
    ))[0];
    for item in _rail_spec_for(wid) {
        ws ++> WorkspaceSection(
            sid=str(item["id"]),
            label=str(item["label"]),
            component=str(item["component"]),
            order=int(_CORE_RANK[str(item["id"])])
        );
    }
    return;
}

"""Create the fixed workspace set on the graph the first time, then keep an
already-seeded graph current. After seeding the graph is the source of truth —
these nodes persist to SQLite and survive restarts."""
def _ensure_workspaces_seeded() -> None {
    existing = [root -->][?:Workspace];
    if len(existing) > 0 {
        # Already-seeded graph (persisted to SQLite): the initial-seed loop below
        # never re-runs, so a NEW _SEED_WORKSPACES entry (e.g. workspace 04) would
        # be skipped forever. Backfill any spec whose wid isn't on the graph yet,
        # then backfill the core rail onto the workspaces seeded by older builds.
        present: list[str] = [];
        for ws in existing { present.append(ws.wid); }
        for (i, spec) in enumerate(_SEED_WORKSPACES) {
            if str(spec["id"]) not in present {
                _seed_one_workspace(spec, i);
            }
        }
        _migrate_core_rail();
        _migrate_legacy_prune();
        if len([root -->][?:Workspace]) == 0 {
            for (i, spec) in enumerate(_SEED_WORKSPACES) { _seed_one_workspace(spec, i); }
        }
        return;
    }
    for (i, spec) in enumerate(_SEED_WORKSPACES) {
        _seed_one_workspace(spec, i);
    }
    # Freshly seeded graphs are already correct — mark the migrations spent so
    # they can never re-add or prune a section the user later changed.
    _mark_migration(_CORE_RAIL_MIGRATION);
    _mark_migration(_LEGACY_PRUNE_MIGRATION);
    return;
}

"""All workspaces on the caller's root, ordered by sort_order then wid."""
def _all_workspaces() -> list[Workspace] {
    wss = [w for w in [root -->][?:Workspace]];
    wss.sort(key=lambda (w: Workspace) -> str {
        return str(w.sort_order).zfill(6) + w.wid;
    });
    return wss;
}

def _find_workspace(wid: str) -> Workspace | None {
    for ws in [root -->][?:Workspace] {
        if ws.wid == wid { return ws; }
    }
    return None;
}

def _find_section(ws: Workspace, sid: str) -> WorkspaceSection | None {
    for sec in [ws -->][?:WorkspaceSection] {
        if sec.sid == sid { return sec; }
    }
    return None;
}

def _next_workspace_id() -> str {
    max_n = 0;
    for ws in [root -->][?:Workspace] {
        try {
            n = int(ws.wid);
            if n > max_n { max_n = n; }
        } except Exception { }
    }
    nxt = max_n + 1;
    return ("0" + str(nxt)) if nxt < 10 else str(nxt);
}

def _next_accent() -> str {
    accents = ["ws01", "ws02", "ws03", "ws04", "ws05", "ws06"];
    n = len([root -->][?:Workspace]);
    return accents[n % len(accents)];
}

def _delete_workspace_node(ws: Workspace) -> None {
    for sec in [ws -->][?:WorkspaceSection] { del sec; }
    del ws;
}

# Registry of mountable section components — single source for CRUD UI + SectionMount.
glob SECTION_TYPES: list[dict] = [
    {"component": "Chat", "label": "Chat", "default_sid": "chat"},
    {"component": "Data", "label": "Dataset", "default_sid": "data"},
    {"component": "Cloud", "label": "Cloud GPU", "default_sid": "cloud"}
];

"""Available section component types for the workspace editor."""
def section_types() -> list[dict] {
    return [dict(x) for x in SECTION_TYPES];
}

"""Workspace registry for the client shell — workspaces, sections, defaults.
Reads from the graph (root --> Workspace --> WorkspaceSection), seeding on first
call. Plain `def` → caller's isolated root, so workspaces are per-user."""
def ui_layout() -> dict {
    _ensure_workspaces_seeded();
    wss = [w.to_view() for w in _all_workspaces()];
    ids: list[str] = [];
    for w in wss { ids.append(w.id); }
    default_ws = wss[len(wss) - 1].id if len(wss) > 0 else "01";
    return {
        "default_workspace": default_ws,
        "workspace_ids": ids,
        "workspaces": wss
    };
}

def create_workspace(
    label: str, accent: str = "", default_model: str = "", files: list[str] = []
) -> WorkspaceView {
    _ensure_workspaces_seeded();
    wid = _next_workspace_id();
    acc = accent if accent else _next_accent();
    dm = default_model if default_model else _default_model_id();
    ws = (root ++> Workspace(
        wid=wid, label=label, accent=acc, default_model=dm,
        files=list(files), sort_order=len(_all_workspaces())
    ))[0];
    ws ++> WorkspaceSection(sid="chat", label="CHAT", component="Chat", order=0);
    return ws.to_view();
}

def update_workspace(
    wid: str, label: str, accent: str, default_model: str, files: list[str]
) -> WorkspaceView | None {
    _ensure_workspaces_seeded();
    ws = _find_workspace(wid);
    if not ws { return None; }
    ws.label = label;
    ws.accent = accent;
    ws.default_model = default_model;
    ws.files = list(files);
    return ws.to_view();
}

def delete_workspace(wid: str) -> bool {
    _ensure_workspaces_seeded();
    if len(_all_workspaces()) <= 1 { return False; }
    ws = _find_workspace(wid);
    if not ws { return False; }
    _delete_workspace_node(ws);
    return True;
}

def reorder_workspaces(ordered_ids: list[str]) -> bool {
    _ensure_workspaces_seeded();
    for (i, wid) in enumerate(ordered_ids) {
        ws = _find_workspace(str(wid));
        if ws { ws.sort_order = i; }
    }
    return True;
}

def add_section(wid: str, sid: str, label: str, component: str) -> WorkspaceSectionView | None {
    _ensure_workspaces_seeded();
    ws = _find_workspace(wid);
    if not ws { return None; }
    if _find_section(ws, sid) { return None; }
    max_ord = -1;
    for sec in [ws -->][?:WorkspaceSection] {
        if sec.order > max_ord { max_ord = sec.order; }
    }
    sec = (ws ++> WorkspaceSection(
        sid=sid, label=label, component=component, order=max_ord + 1
    ))[0];
    return sec.to_view();
}

def update_section(
    wid: str, sid: str, label: str, component: str
) -> WorkspaceSectionView | None {
    _ensure_workspaces_seeded();
    ws = _find_workspace(wid);
    if not ws { return None; }
    sec = _find_section(ws, sid);
    if not sec { return None; }
    sec.label = label;
    sec.component = component;
    return sec.to_view();
}

def delete_section(wid: str, sid: str) -> bool {
    _ensure_workspaces_seeded();
    ws = _find_workspace(wid);
    if not ws { return False; }
    if len([ws -->][?:WorkspaceSection]) <= 1 { return False; }
    sec = _find_section(ws, sid);
    if not sec { return False; }
    del sec;
    return True;
}

def reorder_sections(wid: str, ordered_ids: list[str]) -> bool {
    _ensure_workspaces_seeded();
    ws = _find_workspace(wid);
    if not ws { return False; }
    for (i, sid) in enumerate(ordered_ids) {
        sec = _find_section(ws, str(sid));
        if sec { sec.order = i; }
    }
    return True;
}
