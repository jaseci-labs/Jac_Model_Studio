"use client";
import { useStudio } from "@/lib/use-studio";
import { Sidebar } from "@/components/sidebar";
import { Offline } from "@/components/offline";

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
      <main className="flex min-w-0 flex-1 flex-col">{/* Task 12 */}</main>
      <div className="w-60 shrink-0">{/* Task 13 */}</div>
    </div>
  );
}
