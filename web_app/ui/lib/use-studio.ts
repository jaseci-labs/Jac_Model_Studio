"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { api, streamChat, streamLoad, type ChatMeta, type ModelsResponse, type PromptCategory, type Sampling, type Stats } from "./api";

export type UiMessage = {
  role: "user" | "assistant";
  content: string;
  modelId?: string;
  stats?: Stats;
  pairGroup?: string | null;
  streaming?: boolean;
  loadState?: { status: "loading"; elapsed: number } | null;
  error?: string | null;
};

export function useStudio() {
  const [online, setOnline] = useState<boolean | null>(null);
  const [modelsInfo, setModelsInfo] = useState<ModelsResponse | null>(null);
  const [modelId, setModelId] = useState("qwen-dpo");
  const [compareId, setCompareId] = useState<string | null>(null);
  const [loadingModel, setLoadingModel] = useState<{ id: string; elapsed: number } | null>(null);
  const [chats, setChats] = useState<ChatMeta[]>([]);
  const [chatId, setChatId] = useState<number | null>(null);
  const [messages, setMessages] = useState<UiMessage[]>([]);
  const [prompts, setPrompts] = useState<PromptCategory[]>([]);
  const [sampling, setSampling] = useState<Sampling>({ temperature: 0.2, top_p: 0.9, max_tokens: 1024 });
  const [composer, setComposer] = useState("");
  const [busy, setBusy] = useState(false);
  const messagesRef = useRef(messages);
  messagesRef.current = messages;

  const refreshModels = useCallback(async () => {
    try {
      const m = await api.models();
      setModelsInfo(m);
      setOnline(true);
    } catch {
      setOnline(false);
    }
  }, []);

  useEffect(() => {
    refreshModels();
    api.prompts().then((p) => setPrompts(p.categories)).catch(() => {});
    api.chats().then(setChats).catch(() => {});
  }, [refreshModels]);

  // offline retry ping
  useEffect(() => {
    if (online === false) {
      const t = setInterval(refreshModels, 3000);
      return () => clearInterval(t);
    }
  }, [online, refreshModels]);

  const newChat = useCallback(() => {
    setChatId(null);
    setMessages([]);
  }, []);

  const openChat = useCallback(async (id: number) => {
    const { messages: stored } = await api.getChat(id);
    setChatId(id);
    setMessages(stored.map((m) => ({
      role: m.role, content: m.content, modelId: m.model_id ?? undefined,
      stats: m.stats ?? undefined, pairGroup: m.pair_group,
    })));
  }, []);

  const removeChat = useCallback(async (id: number) => {
    await api.deleteChat(id);
    setChats(await api.chats());
    if (chatId === id) newChat();
  }, [chatId, newChat]);

  const loadModel = useCallback(async (id: string) => {
    setModelId(id);
    setLoadingModel({ id, elapsed: 0 });
    try {
      await streamLoad(id, (e) => {
        if (e.type === "load" && e.status === "loading") setLoadingModel({ id, elapsed: e.elapsed ?? 0 });
      });
    } finally {
      setLoadingModel(null);
      refreshModels();
    }
  }, [refreshModels]);

  const patchLast = (fn: (m: UiMessage) => UiMessage) =>
    setMessages((ms) => ms.map((m, i) => (i === ms.length - 1 ? fn(m) : m)));

  const runLeg = useCallback(async (legModel: string, history: { role: string; content: string }[], cid: number, persistUser: boolean, pairGroup: string | null) => {
    setMessages((ms) => [...ms, { role: "assistant", content: "", modelId: legModel, streaming: true, pairGroup }]);
    await streamChat(
      { model_id: legModel, messages: history, chat_id: cid, pair_group: pairGroup, persist_user: persistUser, ...sampling },
      (e) => {
        if (e.type === "token") patchLast((m) => ({ ...m, content: m.content + e.text, loadState: null }));
        else if (e.type === "load" && e.status === "loading") patchLast((m) => ({ ...m, loadState: { status: "loading", elapsed: e.elapsed ?? 0 } }));
        else if (e.type === "load" && e.status === "ready") patchLast((m) => ({ ...m, loadState: null }));
        else if (e.type === "stats") patchLast((m) => ({ ...m, stats: e as Stats, streaming: false }));
        else if (e.type === "error") patchLast((m) => ({ ...m, error: e.message, streaming: false, loadState: null }));
      },
    );
  }, [sampling]);

  const send = useCallback(async (text: string) => {
    if (!text.trim() || busy) return;
    setBusy(true);
    setComposer("");
    try {
      let cid = chatId;
      if (cid === null) {
        const title = text.trim().slice(0, 40) || "untitled";
        const c = await api.createChat(title);
        cid = c.id;
        setChatId(cid);
        api.chats().then(setChats).catch(() => {});
      }
      const history = [
        ...messagesRef.current
          .filter((m) => !m.error && (!m.pairGroup || m.modelId === modelId))
          .map((m) => ({ role: m.role, content: m.content })),
        { role: "user", content: text },
      ];
      setMessages((ms) => [...ms, { role: "user", content: text }]);
      if (compareId) {
        const pg = crypto.randomUUID();
        await runLeg(modelId, history, cid, true, pg);
        await runLeg(compareId, history, cid, false, pg);
      } else {
        await runLeg(modelId, history, cid, true, null);
      }
      api.chats().then(setChats).catch(() => {});
      refreshModels();
    } finally {
      setBusy(false);
    }
  }, [busy, chatId, compareId, modelId, runLeg, refreshModels]);

  return {
    online, modelsInfo, modelId, compareId, loadingModel, chats, chatId, messages,
    prompts, sampling, composer, busy,
    setCompareId, setSampling, setComposer,
    newChat, openChat, removeChat, loadModel, send, refreshModels,
  };
}
