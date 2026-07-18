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
# Vast.ai GPU cloud (vastai SDK) — full instance lifecycle: search/create/list/
# ssh/logs/exec + start/stop/reboot/destroy.
import from vast {
    vast_status, search_gpus, create_gpu_instance,
    vast_instances, vast_instance, vast_ssh, vast_logs, vast_exec,
    stop_gpu_instance, start_gpu_instance, reboot_gpu_instance, destroy_gpu_instance,
    set_vast_key, clear_vast_key, vast_credential_status,
    dispatch_training_job, list_vast_dispatches, get_vast_dispatch, stop_vast_dispatch
}
# Local single-user mode flag — consumed by the client's auth gate to
# auto-provision a session (desktop) or show the login screen (prod).
import from auth { local_mode }

# Client-side UI
cl {
    import "./global.css";
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
