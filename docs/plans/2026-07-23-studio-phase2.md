# Studio Phase 2 — JMS workspaces + uniform nav, and grounded AI assistant

> Executed under FULL AUTONOMY (user: "implement all parts without further approval, work through your own choices"). Subagent-driven in the `glass-studio` worktree at `/Volumes/ExtremePro/JaseciLabs/jac_model_studio_glass` (app dir `jms/`). Dev server on :8000 from the worktree; verify with the nav.py/navdark.py drivers; `jac check main.jac` + screenshots + zero console errors gate every task. Commit per task (branch guard glass-studio). Integrate into main repo when the SFT session frees it.

## Feature B — JMS workspaces + uniform nav

**Goal:** JMS gets a top workspace bar + the same nav/layout system as Experiments; JMS "workspaces" group projects; each project keeps its internal stage rail. Also fix the pre-existing bug where Experiments' workspace-CRUD endpoints aren't registered in main.jac (management 404s).

**Design (from nav audit — trust these file:line):**
- `WorkspaceBar.cl.jac` + `NavRail.cl.jac` are already GENERIC renderers over a `{workspaces:[{id,label,accent,...}]}` layout dict; only Experiments-specific bit is the literal `‹ EXPERIMENTS` back label (`WorkspaceBar.cl.jac:24`). CSS (`.exp-topbar`/`.jms-topbar`, `--wsNN`/`--ws-accent`) already unified.
- Experiments workspace model: `Workspace` node (`workspace.sv.jac:265-282`: wid,label,accent,default_model,files,sort_order) + `WorkspaceSection` children; `ui_layout()` (line 474-485) returns `{default_workspace, workspace_ids, workspaces:[view]}`; CRUD `create/update/delete/reorder_workspace(s)` (487-531); seeded via `_ensure_workspaces_seeded` (379-401).
- JMS: `JmsProject` node (`jms_projects.sv.jac:66-74`) has NO group field; `list_projects()` (500-507) no filter; `JmsProjects.cl.jac` flat grid; `JmsProject.cl.jac:115-126` stage rail = the per-project "sections" (KEEP untouched). `JmsShell.cl.jac` routes on local `projectId`.
- main.jac registration gap: only `ui_layout` imported from workspace (`main.jac:22`); `create_workspace`/etc NOT registered though `WorkspaceSettings.cl.jac:3` sv-imports them → 404.

### Task B1: `jms_workspaces.sv.jac` — lean JMS workspace model (no sections)
- Create `jms/jms_workspaces.sv.jac`: `JmsWorkspace` node (`wid: str, label: str, accent: str, sort_order: int`), a `JmsWorkspaceView` obj DTO, a `_seed_jms_workspaces()` (root ++> JmsWorkspace, seed one: `{wid:"main", label:"MAIN", accent:"ws01", sort_order:0}`; backfill-safe like `workspace.sv.jac:379-401`), and endpoints: `jms_ui_layout() -> dict` (`{default_workspace, workspace_ids:list, workspaces:[JmsWorkspaceView]}`), `create_jms_workspace(label: str, accent: str) -> dict`, `update_jms_workspace(wid: str, label: str, accent: str) -> dict`, `delete_jms_workspace(wid: str) -> dict` (also clears/reassigns projects' group_id to "" — projects are NOT deleted), `reorder_jms_workspaces(ids: list) -> dict`. Per-user root scoping like jms_projects.sv.jac. Semicolons/typed globs.
- Register ALL these in `main.jac` (add `import from jms_workspaces { jms_ui_layout, create_jms_workspace, update_jms_workspace, delete_jms_workspace, reorder_jms_workspaces }` near the jms_projects import block line ~63).
- Self-check: a `check_jms_workspaces.jac` with-entry that seeds, lists (≥1), creates, updates, deletes, asserts counts. Run with `JAC_LOCAL_USER=1`. `jac check main.jac` PASSED.

### Task B2: `jms_projects.sv.jac` — add `group_id` to projects
- Add `group_id: str = ""` to the `JmsProject` node (near line 66-74) and to `JmsProjectView` (54-63) and `_project_view()` (379-385).
- `create_project(name: str, use_case: str, group_id: str = "")` (483-497) — store group_id.
- `list_projects(group_id: str = "")` (500-507) — if group_id != "", filter to matching projects; "" returns all (back-compat).
- `update_project` (562-570): allow patching `group_id` alongside use_case/provider/model.
- If `create_project`/`list_projects` signatures are registered in main.jac, keep them working (positional). Self-check + `jac check`.

### Task B3: `WorkspaceBar` reusable + fix Experiments workspace-CRUD registration
- `WorkspaceBar.cl.jac`: add prop `backLabel: str = "‹ EXPERIMENTS"`; replace the literal `‹ EXPERIMENTS` (line 24) with `{backLabel}`. No other change (Experiments callers keep the default).
- Fix main.jac: register the workspace CRUD endpoints WorkspaceSettings needs — add to the workspace import: `create_workspace, update_workspace, delete_workspace, reorder_workspaces, add_section, update_section, delete_section, reorder_sections, section_types` (verify exact names in workspace.sv.jac). Verify Experiments "⚙ WORKSPACES" add/edit now works (screenshot the drawer + create a workspace).
- `jac check`, screenshot Experiments workspace settings drawer working.

### Task B4: `JmsShell` — mount the JMS workspace bar
- `JmsShell.cl.jac`: `sv import` `jms_ui_layout`; `has jmsLayout: any = None, jmsWorkspace: str = ""`; on mount fetch `jms_ui_layout()`, set jmsLayout + default workspace. Replace the current plain `.jms-topbar` wordmark row with `<WorkspaceBar layout={jmsLayout} workspace={jmsWorkspace} onWorkspace={switchWs} onSettings={openWsSettings} onHub={onHub} backLabel="‹ JMS" />` — BUT keep the JMS-specific right-side actions (KEYS) and, when a project is open, the breadcrumb. Approach: when `projectId==""` show the WorkspaceBar (workspace tiles); when a project is open, show a slim breadcrumb bar (‹ PROJECTS / name) as today. Keep ThemeSwitcher + KEYS reachable in both (WorkspaceBar already renders ThemeSwitcher + a settings/right group — add KEYS there via an extra prop or a small right-slot). Pass `group={jmsWorkspace}` to `<JmsProjects>`.
- Guard None (jmsLayout None → render a blank/loading frame). `jac check`, screenshot JMS with workspace tiles both modes.

### Task B5: `JmsProjects` — filter + create by workspace
- `JmsProjects.cl.jac`: accept `group: str = ""` prop; call `list_projects(group)`; when creating (line 48-59) pass `group` into `create_project(name, use_case, group)`. Empty-state text unchanged. Screenshot: creating a project in workspace A shows only in A.

### Task B6: `JmsWorkspaceSettings` drawer
- Create `jms/components/jms/JmsWorkspaceSettings.cl.jac` — a slide-over drawer (mirror `WorkspaceSettings.cl.jac` structure but LEAN: no sections). Lists JMS workspaces, add (label + accent picker from ws01..ws06), rename, delete (with confirm; projects in it revert to no-group). Reload via `jms_ui_layout()`. Wire `onSettings` in JmsShell to open it; `onChanged` refreshes jmsLayout.
- `jac check`, screenshot the drawer add/rename/delete both modes.

### Task B7: uniform-nav verification
- Screenshot JMS + Experiments side-by-side conceptually (both have top workspace bar + content; JMS project→stage rail matches Experiments section rail), both light+dark. Confirm: JMS workspace switching filters projects; create-in-workspace works; JMS + Experiments workspace settings both work; zero console errors. Fix any regressions.

## Feature A — grounded AI assistant

**Goal:** an in-app assistant with a model picker (local MLX Qwen/Gemma + API Claude via ANTHROPIC_API_KEY / OpenAI via OPENAI_API_KEY), grounded in FULL app state (workspaces, projects, datasets, runs+configs+logs, evals, adapters, deployments), full functionality (streaming chat). Reachable as a global surface.

**Design (from assistant audit — trust these file:line):**
- Chat SSE: `chat.sv.jac:16 chat_stream(messages, model_id, temperature, top_p, max_tokens)` generator → `/function/chat_stream`; frames `{kind:load|token|done|error}`. MLX gen: `inference.sv.jac stream_chat(...)` (single resident model, lock, LoRA support). Client = raw `fetch("/function/chat_stream")` + manual SSE reader, watch `event: end`/`event: error` sentinel (`Chat.cl.jac:184-288`). Reuse this template.
- Providers/keys: `jms_llm.sv.jac:116 llm_status()` already returns `{providers:[{id:claude,models},{id:mlx,models}]}`; Anthropic key = `JmsSettings.anthropic_key` encrypted via `crypto.sv.jac`, `resolved_anthropic_key()` (stored else env). NO OpenAI yet. Local models: `models.sv.jac list_models()`.
- byllm 0.6.13 + litellm 1.82.6 + openai 2.41.0 installed in the serving (uv-tool) venv; NO mlx there (mlx lives in the main-tree project .venv). → litellm direct streaming (`model="anthropic/…"` / `"openai/…"`, `stream=True`, `api_key=…`) is the proven cloud path.
- Context sources (all cheap dict calls): `workspace.ui_layout`, `jms_projects.list_projects/get_project`, `jms_train.list_train_runs`, `jms_eval.list_jms_evals`, `runs.list_runs`, `evals.list_evals`, `cloudruns.list_cloud_runs`, `spheron.list_spheron_dispatches`, `persistence.list_chats`, `jms_llm.llm_status`. Grounding precedent: `jms_plan.sv.jac:_collect_grounding` (caps `_MAX_GROUND_CHARS=30000`, `_PER_FILE_CHARS=2000`); binary skip list `jms_projects.sv.jac:39-46`.
- ENV CAVEAT: worktree serving venv lacks mlx → the local-MLX path builds + integrates but is only runtime-verifiable at main-tree integration; the API path (Claude/OpenAI) is verifiable in the worktree if a key is set (else verify provider-listing + needs-key state).

### Task A1: OpenAI key support + unified provider listing
- Add OpenAI key infra mirroring `jms_llm.sv.jac`'s Anthropic pattern: `OpenAiSettings` node (`has openai_key: str = ""`), `set_openai_key`/`resolved_openai_key`(stored else env `OPENAI_API_KEY`)/`clear_openai_key`, encrypt via `crypto.sv.jac`. Put in a new `assistant.sv.jac` (or extend jms_llm — prefer new module to not disturb PLAN).
- `assistant_providers() -> dict`: `{providers:[{id:"mlx",label:"Local (MLX)",requires_key:False,models:[list_models available ids]},{id:"claude",label:"Claude (Anthropic)",requires_key:True,configured:bool,models:["claude-sonnet-5","claude-haiku-4-5"]},{id:"openai",label:"OpenAI",requires_key:True,configured:bool,models:["gpt-4o","gpt-4o-mini"]}]}`.
- Register in main.jac. Self-check + `jac check`.

### Task A2: `assistant_context` — full-app-state grounding bundle
- In `assistant.sv.jac`: `_collect_assistant_context() -> str` — fan out to the context sources above, serialize into a labeled text digest (WORKSPACES / JMS PROJECTS+stage_state / TRAIN RUNS / EVALS / CLOUD / CHAT HISTORY headers), truncate per the `_MAX_GROUND_CHARS`/`_PER_FILE_CHARS` caps, skip binaries. Read a bounded sample of key text files (project dataset/eval summaries, run logs tail) via `paths.resolve`. Tolerate missing/empty (best-effort). Expose `assistant_context() -> str` endpoint for debugging + self-check (asserts it contains the seeded workspace + any project names, non-empty, under cap).

### Task A3: `assistant_stream` — streaming chat over any provider, grounded
- `assistant.sv.jac`: `assistant_stream(messages: list[dict], provider: str, model_id: str, temperature=0.3, top_p=0.9, max_tokens=1536) -> any` generator, same frame protocol as chat_stream. Prepend a system message = grounding preamble + `_collect_assistant_context()`. Dispatch: `provider=="mlx"` → `inference.stream_chat(msgs, model_id, models.model_path(...), ...)`; `provider in (claude,openai)` → litellm streaming (`import litellm`; `litellm.completion(model=("anthropic/" if claude else "openai/")+model_id, messages=msgs, stream=True, api_key=resolved_*_key(), max_tokens=...)`, yield `{kind:"token",...}` per chunk delta, final `{kind:"done",...}`; on missing key yield `{kind:"error", text:"<provider> key not set"}`). Register in main.jac. Self-check the mlx/error branches structurally (can't load mlx in worktree — assert the claude branch with no key returns an error frame, and that a bogus provider errors cleanly).

### Task A4: `AssistantPanel.cl.jac` — grounded assistant chat UI
- New `jms/components/AssistantPanel.cl.jac`: a slide-over panel (glass, `fixed inset-y-0 right-0` drawer, wide) with a provider+model picker (from `assistant_providers()`, gate API providers on `configured`, show "set key" affordance if not), a message Thread (reuse `components/chat/Thread.cl.jac` if directly reusable, else a minimal bubble list), and a Composer (reuse `components/chat/Composer.cl.jac` or minimal textarea+send). Wire send → raw-fetch SSE to `/function/assistant_stream` exactly like `Chat.cl.jac:184-215` incl. the `event: end`/`event: error` sentinel handling. Grounding is server-side (no client context work).

### Task A5: OpenAI + Anthropic key UI
- Extend `components/jms/ApiKeyModal.cl.jac` (the ⚙ KEYS modal) to also set/clear the OpenAI key (add a second field + calls to `set_openai_key`/`clear_openai_key`, show masked status from `assistant_providers()`), alongside the existing Anthropic field. Both surfaces reach KEYS.

### Task A6: surface the assistant globally
- Add an `✦ ASSISTANT` (or `✦ ASK`) glass button in BOTH top bars (JMS WorkspaceBar right group + Experiments WorkspaceBar right group — one shared prop/slot since the bar is now shared) that toggles the `<AssistantPanel>` slide-over. Mount `<AssistantPanel open onClose>` at the shell level (JmsShell + AppShell, or once in frontend). Reachable from anywhere.

### Task A7: assistant verification
- `jac check`; screenshot the assistant panel open in both modes; open provider picker (shows MLX + Claude + OpenAI, API ones gated on key). If an Anthropic key is configured in the env/settings, ask "what projects and training runs exist?" and confirm a grounded answer streams referencing the real Glass Test project + any runs. If no key, verify the needs-key state + that MLX appears (runtime MLX deferred to integration). Zero console errors.

## Integration (final, autonomous)
When the SFT session frees the main tree (watcher `wait_sft.sh`): delete stale main-tree `jms/` cache, land `glass-studio` (glass + phase-2) onto the target branch, verify real projects/data load + both features work, remove the worktree. Playbook in the ledger.
