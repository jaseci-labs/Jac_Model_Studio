"""studio - Entry Point.

Combines server-side endpoints with the client-side UI.
"""

import from models { ModelView, list_models, system_ram }
import from persistence {
    ChatView, MsgView,
    create_chat, list_chats, rename_chat, delete_chat, get_messages, add_message
}
import from data { FileRefView, DataRowView, dataset_stats, dataset_files, dataset_rows }
import from prompts { list_prompts }
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
