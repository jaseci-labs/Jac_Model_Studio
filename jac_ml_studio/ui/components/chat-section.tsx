"use client";
import React, { useState } from "react";
import { useStudio } from "@/lib/use-studio";
import { Sidebar } from "@/components/sidebar";
import { Offline } from "@/components/offline";
import { ModelPill } from "@/components/model-pill";
import { Thread } from "@/components/thread";
import { Composer } from "@/components/composer";
import { Rail } from "@/components/rail";

export const ChatSection = React.memo(function ChatSection() {
  const s = useStudio();
  const [railCollapsed, setRailCollapsed] = useState(false);
  if (s.online === false) return <Offline />;
  if (s.online === null) return null;
  return (
    <div className="flex h-full min-w-0 flex-1 overflow-hidden">
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
          onPick={(id) => {
            if (id === s.compareId) s.setCompareId(null);
            void s.loadModel(id);
          }}
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
      <Rail
        prompts={s.prompts}
        sampling={s.sampling}
        lastStats={[...s.messages].reverse().find((m) => m.stats)?.stats ?? null}
        collapsed={railCollapsed}
        onSampling={s.setSampling}
        onPick={s.setComposer}
        onToggle={() => setRailCollapsed(!railCollapsed)}
      />
    </div>
  );
});
