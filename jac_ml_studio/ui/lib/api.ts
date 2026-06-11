const BASE = "http://127.0.0.1:8400";

export type ModelInfo = { id: string; label: string; available: boolean; size_gb: number | null };
export type ModelsResponse = { models: ModelInfo[]; loaded: string | null; ram_gb: number; resident_gb: number | null };
export type Stats = { model_id: string; gen_tokens: number; tps: number; seconds: number; load_seconds: number };
export type ChatMeta = { id: number; title: string; created_at: string; updated_at: string };
export type StoredMessage = { id: number; chat_id: number; role: "user" | "assistant"; content: string; model_id: string | null; stats: Stats | null; pair_group: string | null; created_at: string };
export type PromptCategory = { id: string; label: string; prompts: string[] };
export type Sampling = { temperature: number; top_p: number; max_tokens: number };

export type StreamEvent =
  | { type: "token"; text: string }
  | { type: "load"; status: "loading" | "ready"; model_id: string; elapsed?: number; seconds?: number }
  | ({ type: "stats" } & Stats)
  | { type: "error"; message: string }
  | { type: "done" };

async function j<T>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!r.ok) throw new Error(`${path}: ${r.status}`);
  return r.json();
}

export const api = {
  models: () => j<ModelsResponse>("/api/models"),
  prompts: () => j<{ categories: PromptCategory[] }>("/api/prompts"),
  chats: () => j<ChatMeta[]>("/api/chats"),
  createChat: (title: string) => j<ChatMeta>("/api/chats", { method: "POST", body: JSON.stringify({ title }) }),
  getChat: (id: number) => j<{ chat: ChatMeta; messages: StoredMessage[] }>(`/api/chats/${id}`),
  renameChat: (id: number, title: string) => j<{ ok: boolean }>(`/api/chats/${id}`, { method: "PATCH", body: JSON.stringify({ title }) }),
  deleteChat: (id: number) => j<{ ok: boolean }>(`/api/chats/${id}`, { method: "DELETE" }),
};

async function streamSSE(path: string, body: unknown, onEvent: (e: StreamEvent) => void) {
  const r = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok || !r.body) throw new Error(`${path}: ${r.status}`);
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const frame = buf.slice(0, i);
      buf = buf.slice(i + 2);
      if (frame.startsWith("data: ")) onEvent(JSON.parse(frame.slice(6)));
    }
  }
}

export type ChatBody = {
  model_id: string;
  messages: { role: string; content: string }[];
  chat_id?: number | null;
  pair_group?: string | null;
  persist_user?: boolean;
} & Sampling;

export const streamChat = (body: ChatBody, onEvent: (e: StreamEvent) => void) =>
  streamSSE("/api/chat", body, onEvent);

export const streamLoad = (model_id: string, onEvent: (e: StreamEvent) => void) =>
  streamSSE("/api/load", { model_id }, onEvent);
