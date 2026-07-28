"""studio - Entry Point.

Combines server-side endpoints with the client-side UI. Every `.sv.jac` endpoint
+ type consumed by the client (whether via an `sv import` RPC stub or a raw fetch
reader) must be registered here, or it 404s at runtime.
"""

import from models { ModelView, list_models, system_ram, loaded_model, warm_model }
import from persistence {
    ChatView, MsgView,
    create_chat, list_chats, rename_chat, delete_chat, get_messages, add_message, today_utc
}
import from data { FileRefView, DataRowView, dataset_stats, dataset_files, dataset_rows, add_examples, rl_sources, rl_dataset_files, rl_dataset_rows }
import from builders { BuilderView, list_builders, run_builder, get_builder }
import from prompts { list_prompts }
# Cross-app activity snapshot for the top-bar indicator (read-only).
import from jobs { active_jobs }
import from gallery { list_galleries, gallery_images }
import from evals { EvalView, create_eval, list_evals, get_eval, stop_eval, delete_eval }
# Training control + read-only run metrics — consumed by the TRAIN section's
# `sv import` RPC stubs, so register them at the top level.
import from train { start_training, stop_training, get_status, list_sessions }
import from backends { list_backends }
import from workspace {
    ui_layout, section_types,
    create_workspace, update_workspace, delete_workspace, reorder_workspaces,
    add_section, update_section, delete_section, reorder_sections
}
import from runs { list_runs, get_run, compare_runs }
# Live RL ladder results — consumed by the RL section's `sv import` RPC stub.
import from rl { get_rl_ladder, get_rl_corrected, rl_generate }
# CPT corpus browser + training control (model-experiments/03-new attempt) — consumed by the CPT
# workspace's DATA + TRAIN sections.
import from cpt {
    cpt_manifest, cpt_files, cpt_rows,
    start_cpt_training, stop_cpt_training, get_cpt_status, get_all_cpt_status
}
# 04-cpt-sft dataset browser + three-arm plan status (model-experiments/04-cpt-sft)
# — consumed by the CPT-SFT workspace's DATA + PLAN sections via `sv import` stubs.
import from cptsft {
    cptsft_stats, cptsft_files, cptsft_rows, cptsft_plan_status
}
# Streaming chat endpoint — consumed by a raw fetch reader on the client (not an
# `sv import` RPC stub), so register it explicitly at the top level.
import from chat { chat_stream }
# Spheron GPU cloud (REST API) — full deployment lifecycle: search offers/
# providers, deploy instances, list/get/ssh, terminate (+ rename + can-terminate),
# SSH-key management, and a cloud-init dispatch bridge that deploys a fresh
# instance with a training command baked into runcmd.
import from spheron {
    spheron_status, spheron_credential_status, spheron_providers,
    search_gpus,
    # create_gpu_instance is deliberately NOT registered: no client calls it, but as an
    # HTTP endpoint it lets a caller deploy a billing GPU VM with no supervisor and no
    # CloudRun node tracking it. Still used server-side (cloudruns.sv.jac:398,
    # spheron.sv.jac:920) — the function is untouched, only its HTTP exposure is gone.
    spheron_instances, spheron_instance, spheron_ssh,
    destroy_gpu_instance, can_terminate_gpu_instance, rename_gpu_instance,
    spheron_ssh_keys, add_spheron_ssh_key,
    set_spheron_key, clear_spheron_key,
    dispatch_training_job, list_spheron_dispatches, get_spheron_dispatch, stop_spheron_dispatch
}
# Supervised remote GPU runs (cloudruns.sv.jac + remote/supervisor.py): start a
# Spheron VM run under a detached local supervisor, poll status.json, stop /
# reattach / re-pull / panic-terminate. Consumed by the Cloud section's RUNS tab.
import from cloudruns {
    start_remote_run, run_status, list_cloud_runs,
    stop_run, reattach_run, pull_artifacts, terminate_run_vm
}
# JMS product surface: per-user project management + source scanning (graph-backed,
# root ++> JmsProject ++> JmsSource). Consumed by the JmsProjects / JmsProject /
# SourcesStage client components via `sv import` RPC stubs.
#
# Project lifecycle (rename / duplicate / export) is the same module: `rename_project`
# changes the DISPLAY name only (the slug stays the on-disk identity, so no directory
# ever moves), `duplicate_project` clones config + sources + one plan with an opt-in
# streamed curated-dataset copy, and the three export endpoints
# (`dataset_export_info` / `export_dataset` / `export_summary`) all carry a hard
# per-response byte budget and report in-band when they hit it.
import from jms_projects {
    JmsProjectView,
    create_project, list_projects, get_project, update_project, delete_project,
    rename_project, duplicate_project,
    dataset_export_info, export_dataset, export_summary,
    add_source, remove_source, scan_source, write_project_snapshot
}
# JMS top nav: a lean per-user workspace registry that GROUPS projects (no
# sections — a project keeps its own internal stage rail). Consumed by
# JmsShell's WorkspaceBar + the future JmsWorkspaceSettings drawer.
import from jms_workspaces {
    jms_ui_layout, create_jms_workspace, update_jms_workspace,
    delete_jms_workspace, reorder_jms_workspaces
}
# JMS LLM provider config: per-user Anthropic key storage (encrypted) + the
# provider/model catalog + price table. Consumed by the ApiKeyModal + PLAN picker.
import from jms_llm {
    set_anthropic_key, clear_anthropic_key, llm_status, price_for
}
# In-app AI assistant (phase 2, task A1): OpenAI key storage (encrypted,
# mirrors jms_llm's Anthropic pattern) + a unified provider listing
# (mlx/claude/openai) for the assistant's model picker. Task A3's
# `assistant_stream` (grounded streaming chat over MLX/Claude/OpenAI) is
# consumed by a raw fetch reader on the client, same as `chat_stream` below —
# registered here too so it doesn't 404.
import from assistant {
    assistant_providers, set_openai_key, clear_openai_key, assistant_context,
    assistant_stream
}
# JMS GENERATE stage, PLAN step: LLM-authored dataset plans (claude via byllm /
# mlx via the resident model), edit + approve. Consumed by GenerateStage.
import from jms_plan {
    draft_plan, get_plans, update_plan, approve_plan, latest_approved
}
# JMS GENERATE stage, SYNTHESIZE step: detached dataset-generation worker jobs
# (cost estimate, fire/stop, live status + log tail). Consumed by GenerateStage's
# SYNTHESIZE tab.
import from jms_gen {
    estimate_gen, start_gen, gen_status, stop_gen, list_gen_jobs
}
# JMS CURATE stage: file-based accept/reject/edit overlay over raw.jsonl +
# deterministic train/holdout split (materialize). Consumed by CurateStage.
import from jms_curate {
    curate_stats, curate_rows, decide_row, decide_page, rejected_ids, materialize
}
# JMS TRAIN stage: LoRA finetuning on a project's curated dataset. Two backends —
# local-mlx (mlx_lm.lora under the heavy GPU lock) + spheron (remote VM run
# delegated to cloudruns). Consumed by TrainStage via `sv import` RPC stubs.
import from jms_train {
    start_train, train_status, stop_train, list_train_runs
}
# JMS EVAL stage: score a completed local-mlx run's adapter on the project's
# holdout (judge = Claude LLM-as-judge / similarity = offline difflib), via a
# detached worker. Consumed by EvalStage's EVAL tab via `sv import` RPC stubs.
import from jms_eval {
    start_eval, eval_status, eval_rows, list_jms_evals, stop_eval_run
}
# JMS CHAT: stream a completion from a run's base model + LoRA adapter — same SSE
# frame protocol as chat_stream, consumed by EvalStage's CHAT tab via a raw fetch
# reader (not an `sv import` stub), so register it explicitly at the top level.
import from jms_chat { jms_chat_stream }
# Local single-user mode: `local_mode()` is the flag the client's auth gate
# reads; `local_session()` mints an in-process JWT so the desktop client (which
# can't reach /user/* over HTTP in webview mode) can still establish a session.
import from auth { local_mode, local_session, session_alive }

# Client-side UI
cl {
    import "./theme.css";
    import "./global.css";
    import "./jms.css";
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
