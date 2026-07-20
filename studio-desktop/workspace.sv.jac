"""studio - workspace configuration loader.

Single source of truth for studio's data-config (model registry, dataset file
maps, train/builder/eval key lists, CPT + RL layout). Everything that used to be
a hard-coded `glob` in models/data/train/builders/evals/cpt/rl now flows through
here, so the studio app adapts to a checkout by editing studio.workspace.toml,
not code.

Resolution:
  1. <workspace_root>/studio.workspace.toml   (JAC_STUDIO_WORKSPACE; travels
     with the data checkout)
  2. <studio_root>/studio.workspace.toml      (shipped fallback inside the app)
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

def holdouts() -> dict {
    return _dict_of(_sec("models").get("holdouts"));
}

def excluded_run_dirs() -> list[str] {
    return _str_list(_sec("models").get("excluded_run_dirs"));
}

# --- SFT/DPO dataset (data.sv.jac) ------------------------------------------

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

def append_targets() -> dict {
    return _dict_of(_sec("data").get("append_targets"));
}

def data_sft_stat_files() -> list[str] {
    return _str_list(_sec("data").get("sft_stat_files"));
}

def data_split_files() -> dict {
    return _dict_of(_sec("data").get("split_files"));
}

# --- RL (rl.sv.jac / data.sv.jac) -------------------------------------------

def rl_sources() -> list[str] {
    return _str_list(_sec("rl").get("sources"));
}

# Values are per-source [[rel, label], ...]; kept as a raw dict (untyped values).
def rl_preview_files() -> dict {
    return _dict_of(_sec("rl").get("preview_files"));
}

def rung_order() -> list {
    return _str_list(_sec("rl").get("rung_order"));
}

# --- CPT (cpt.sv.jac) -------------------------------------------------------

def cpt_files() -> list[list[str]] {
    raw = _sec("cpt").get("files");
    out: list[list[str]] = [];
    if not isinstance(raw, list) { return out; }
    for pair in (raw as list) {
        if isinstance(pair, list) {
            out.append([str(x) for x in (pair as list)]);
        }
    }
    return out;
}

def cpt_manifest_rel() -> str {
    raw = _sec("cpt").get("manifest_rel");
    return str(raw) if raw is not None else "";
}

def cpt_src_order() -> list[str] {
    return _str_list(_sec("cpt").get("src_order"));
}

def cpt_kind_map() -> dict {
    return _dict_of(_sec("cpt").get("kind_map"));
}

# --- train / builders / evals (train/builders/evals.sv.jac) -----------------

def sft_keys() -> list[str] {
    return _str_list(_sec("train").get("sft_keys"));
}

def dpo_keys() -> list[str] {
    return _str_list(_sec("train").get("dpo_keys"));
}

def builder_stages() -> list[str] {
    return _str_list(_sec("builders").get("stages"));
}

def eval_kinds() -> list[str] {
    return _str_list(_sec("evals").get("kinds"));
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

"""Spheron remote path overrides from [spheron] in studio.workspace.toml.
Used by spheron.sv.jac to build the cloudInit.runcmd working directory for a
dispatched training job (a fresh Spheron instance starts empty, so these are
where the dispatch cds into before launching)."""
def spheron_remote_config() -> dict {
    return _dict_of(_sec("spheron"));
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
        secs.sort(key=lambda s: WorkspaceSection -> int { return s.order; });
        return WorkspaceView(
            id=self.wid, label=self.label, accent=self.accent,
            default_model=self.default_model, files=list(self.files),
            sections=[s.to_view() for s in secs]
        );
    }
}

# Fixed workspace set used to seed the graph on first run. Mirrors the old
# filesystem-discovered layout (01 SFT/DPO, 02 RL/GRPO, 03 CPT) — each now carries
# an arbitrary `files` list the user can repoint to anything they want.
glob _SEED_WORKSPACES: list[dict] = [
    {
        "id": "01",
        "label": "SFT/DPO",
        "accent": "ws01",
        "default_model": "qwen-dpo",
        "files": ["01-sft-dpo"],
        "sections": [
            {"id": "chat", "label": "CHAT", "component": "Chat", "order": 0},
            {"id": "data", "label": "DATA", "component": "Data", "order": 1},
            {"id": "train", "label": "TRAIN", "component": "Train", "order": 2},
            {"id": "evals", "label": "EVALS", "component": "Evals", "order": 3},
            {"id": "cloud", "label": "CLOUD", "component": "Cloud", "order": 4}
        ]
    },
    {
        "id": "02",
        "label": "RL/GRPO",
        "accent": "ws02",
        "default_model": "qwen3coder-rl",
        "files": ["02-rl-grpo"],
        "sections": [
            {"id": "chat", "label": "CHAT", "component": "Chat", "order": 0},
            {"id": "data", "label": "DATA", "component": "RlData", "order": 1},
            {"id": "results", "label": "RESULTS", "component": "Results", "order": 2},
            {"id": "generate", "label": "GENERATE", "component": "Generate", "order": 3}
        ]
    },
    {
        "id": "03",
        "label": "CPT",
        "accent": "ws03",
        "default_model": "qwen-q4",
        "files": ["03-new"],
        "sections": [
            {"id": "chat", "label": "CHAT", "component": "Chat", "order": 0},
            {"id": "data", "label": "DATA", "component": "CptData", "order": 1},
            {"id": "train", "label": "TRAIN", "component": "CptTrain", "order": 2},
            {"id": "plan", "label": "PLAN", "component": "Plan", "order": 3}
        ]
    }
];

"""Create the fixed workspace set on the graph the first time (idempotent).
After seeding the graph is the source of truth — these nodes persist to SQLite
and survive restarts. A no-op once any Workspace node exists."""
def _ensure_cloud_section(ws: Workspace) -> None {
    if ws.wid != "01" { return; }
    for sec in [ws -->][?:WorkspaceSection] {
        if sec.sid == "cloud" { return; }
    }
    ws ++> WorkspaceSection(sid="cloud", label="CLOUD", component="Cloud", order=4);
}

def _ensure_workspaces_seeded() -> None {
    if len([root -->][?:Workspace]) > 0 {
        for ws in [root -->][?:Workspace] {
            _ensure_cloud_section(ws);
        }
        return;
    }
    for (i, spec) in enumerate(_SEED_WORKSPACES) {
        ws = root ++> Workspace(
            wid=str(spec["id"]),
            label=str(spec["label"]),
            accent=str(spec["accent"]),
            default_model=str(spec["default_model"]),
            files=[str(f) for f in (spec["files"] as list)],
            sort_order=i
        );
        for sec in (spec["sections"] as list) {
            sd = sec as dict;
            ws ++> WorkspaceSection(
                sid=str(sd["id"]),
                label=str(sd["label"]),
                component=str(sd["component"]),
                order=int(sd["order"])
            );
        }
    }
}

"""All workspaces on the caller's root, ordered by sort_order then wid."""
def _all_workspaces() -> list[Workspace] {
    wss = [w for w in [root -->][?:Workspace]];
    wss.sort(key=lambda w: Workspace -> str {
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
    {"component": "Data", "label": "SFT/DPO Data", "default_sid": "data"},
    {"component": "RlData", "label": "RL Data", "default_sid": "data"},
    {"component": "CptData", "label": "CPT Data", "default_sid": "data"},
    {"component": "Train", "label": "Train", "default_sid": "train"},
    {"component": "CptTrain", "label": "CPT Train", "default_sid": "train"},
    {"component": "Evals", "label": "Evals", "default_sid": "evals"},
    {"component": "Results", "label": "Results", "default_sid": "results"},
    {"component": "Generate", "label": "Generate", "default_sid": "generate"},
    {"component": "Plan", "label": "Plan", "default_sid": "plan"},
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
    dm = default_model if default_model else "qwen-dpo";
    ws = root ++> Workspace(
        wid=wid, label=label, accent=acc, default_model=dm,
        files=list(files), sort_order=len(_all_workspaces())
    );
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
    sec = ws ++> WorkspaceSection(
        sid=sid, label=label, component=component, order=max_ord + 1
    );
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
