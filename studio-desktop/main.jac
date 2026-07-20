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
import from evals { EvalView, create_eval, list_evals, get_eval, stop_eval, delete_eval }
# Training control + read-only run metrics — consumed by the TRAIN section's
# `sv import` RPC stubs, so register them at the top level.
import from train { start_training, stop_training, get_status, list_sessions }
import from backends { list_backends }
import from workspace { ui_layout }
import from runs { list_runs, get_run, compare_runs }
# Live RL ladder results — consumed by the RL section's `sv import` RPC stub.
import from rl { get_rl_ladder, get_rl_corrected, rl_generate }
# CPT corpus browser + training control (03-new attempt) — consumed by the CPT
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
# Local single-user mode: `local_mode()` is the flag the client's auth gate
# reads; `local_session()` mints an in-process JWT so the desktop client (which
# can't reach /user/* over HTTP in webview mode) can still establish a session.
import from auth { local_mode, local_session }

# Client-side UI
cl {
    import "./global.css";
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
