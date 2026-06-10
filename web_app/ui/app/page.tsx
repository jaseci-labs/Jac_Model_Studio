"use client";
import { useStudio } from "@/lib/use-studio";
import { Sidebar } from "@/components/sidebar";
import { Offline } from "@/components/offline";
import { ModelPill } from "@/components/model-pill";
import { Thread } from "@/components/thread";
import { Composer } from "@/components/composer";

export default function Home() {
  const s = useStudio();
  if (s.online === false) return <Offline />;
  if (s.online === null) return null;
  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar
        chats={s.chats}
        activeId={s.chatId}
        info={s.modelsInfo}
        busy={s.busy}
        onNew={s.newChat}
        onOpen={(id) => { void s.openChat(id); }}
        onDelete={(id) => { void s.removeChat(id); }}
      />
      <main className="flex min-w-0 flex-1 flex-col">
        <ModelPill
          info={s.modelsInfo}
          modelId={s.modelId}
          compareId={s.compareId}
          loading={s.loadingModel}
          loadError={s.loadError}
          onPick={(id) => { void s.loadModel(id); }}
          onPickCompare={s.setCompareId}
        />
        <Thread messages={s.messages} modelLabel={(id) => s.modelsInfo?.models.find((m) => m.id === id)?.label ?? id ?? ""} />
        <Composer
          value={s.composer}
          busy={s.busy}
          categories={s.prompts}
          onChange={s.setComposer}
          onSend={(t) => { void s.send(t); }}
          onChip={(cid) => {
            const cat = s.prompts.find((c) => c.id === cid);
            if (cat?.prompts[0]) s.setComposer(cat.prompts[0]);
          }}
        />
      </main>
      <div className="w-60 shrink-0">{/* Task 13 */}</div>
    </div>
  );
}
