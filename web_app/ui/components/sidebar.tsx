"use client";
import type { ChatMeta, ModelsResponse } from "@/lib/api";

function MemGauge({ info }: { info: ModelsResponse | null }) {
  if (!info) return null;
  const used = info.resident_gb ?? 0;
  const filled = Math.min(8, Math.round((used / info.ram_gb) * 8));
  return (
    <div className="dashed-rule pt-3 font-mono text-[10px] text-neutral-500">
      MEM {used.toFixed(1)} / {info.ram_gb} GB{" "}
      <span className="text-neutral-300">{"▮".repeat(filled)}</span>
      {"░".repeat(8 - filled)}
    </div>
  );
}

export function Sidebar(props: {
  chats: ChatMeta[];
  activeId: number | null;
  info: ModelsResponse | null;
  busy: boolean;
  onNew: () => void;
  onOpen: (id: number) => void;
  onDelete: (id: number) => void;
}) {
  const gate = (fn: () => void) => () => {
    if (!props.busy) fn();
  };
  return (
    <aside className="flex w-56 shrink-0 flex-col border-r border-neutral-800 bg-[#0d0d0d] p-3">
      <div className="micro-label mb-3">JAC.STUDIO — fig.1</div>
      <button
        onClick={gate(props.onNew)}
        className="mb-3 rounded-md border border-dashed border-neutral-600 py-1.5 text-xs text-neutral-300 hover:border-neutral-400 disabled:opacity-40"
        disabled={props.busy}
      >
        + new chat
      </button>
      <div className="flex-1 overflow-y-auto">
        {props.chats.length === 0 && (
          <p className="px-2 font-mono text-[10px] text-neutral-600">no chats yet</p>
        )}
        {(() => {
          const today = new Date().toISOString().slice(0, 10);
          const groups: { day: string; chats: ChatMeta[] }[] = [];
          for (const c of props.chats) {
            const day = c.updated_at?.slice(0, 10) ?? "";
            const last = groups[groups.length - 1];
            if (last && last.day === day) {
              last.chats.push(c);
            } else {
              groups.push({ day, chats: [c] });
            }
          }
          return groups.map(({ day, chats }) => (
            <div key={day}>
              <div className="micro-label mb-1 mt-2">{day === today ? "TODAY" : day}</div>
              <div className="space-y-0.5">
                {chats.map((c) => (
                  <div
                    key={c.id}
                    onClick={gate(() => props.onOpen(c.id))}
                    className={`group flex cursor-pointer items-center justify-between rounded-md px-2 py-1.5 text-xs ${
                      c.id === props.activeId ? "bg-[#1a1a1a] text-neutral-100" : "text-neutral-400 hover:bg-[#141414]"
                    } ${props.busy ? "opacity-50" : ""}`}
                  >
                    <span className="truncate">{c.title}</span>
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        if (!props.busy) props.onDelete(c.id);
                      }}
                      className="hidden font-mono text-[9px] text-neutral-600 hover:text-neutral-300 group-hover:block"
                    >
                      DEL
                    </button>
                  </div>
                ))}
              </div>
            </div>
          ));
        })()}
      </div>
      <MemGauge info={props.info} />
    </aside>
  );
}
