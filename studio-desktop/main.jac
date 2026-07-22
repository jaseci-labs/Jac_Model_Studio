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
import from gallery { list_galleries, gallery_images }
import from evals { EvalView, create_eval, list_evals, get_eval, stop_eval, delete_eval }
# Training control + read-only run metrics — consumed by the TRAIN section's
# `sv import` RPC stubs, so register them at the top level.
import from train { start_training, stop_training, get_status, list_sessions }
import from backends { list_backends }
import from workspace { ui_layout }
import from runs { list_runs, get_run, compare_runs }
# Live RL ladder results — consumed by the RL section's `sv import` RPC stub.
import from rl { get_rl_ladder, get_rl_corrected, rl_generate }
# CPT corpus browser + training control (model-experiments/03-new attempt) — consumed by the CPT
# workspace's DATA + TRAIN sections.
import from cpt {
    cpt_manifest, cpt_files, cpt_rows,
    start_cpt_training, stop_cpt_training, get_cpt_status, get_all_cpt_status
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
    search_gpus, create_gpu_instance,
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
import from jms_projects {
    JmsProjectView,
    create_project, list_projects, get_project, update_project, delete_project,
    add_source, remove_source, scan_source, write_project_snapshot
}
# JMS LLM provider config: per-user Anthropic key storage (encrypted) + the
# provider/model catalog + price table. Consumed by the ApiKeyModal + PLAN picker.
import from jms_llm {
    set_anthropic_key, clear_anthropic_key, llm_status, price_for
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
# Local single-user mode: `local_mode()` is the flag the client's auth gate
# reads; `local_session()` mints an in-process JWT so the desktop client (which
# can't reach /user/* over HTTP in webview mode) can still establish a session.
import from auth { local_mode, local_session }

# Client-side UI
cl {
    import "./global.css";
    import "./jms.css";
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
