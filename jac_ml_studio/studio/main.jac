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
import from data { FileRefView, DataRowView, dataset_stats, dataset_files, dataset_rows, add_examples }
import from builders { BuilderView, list_builders, run_builder, get_builder }
import from prompts { list_prompts }
import from evals { EvalView, create_eval, list_evals, get_eval, stop_eval, delete_eval }
# Training control + read-only run metrics — consumed by the TRAIN section's
# `sv import` RPC stubs, so register them at the top level.
import from train { start_training, stop_training, get_status, list_sessions }
import from runs { list_runs, get_run, compare_runs }
# Streaming chat endpoint — consumed by a raw fetch reader on the client (not an
# `sv import` RPC stub), so register it explicitly at the top level.
import from chat { chat_stream }

# Client-side UI
cl {
    import "./global.css";
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
