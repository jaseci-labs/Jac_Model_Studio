"use client";
import { useEffect, useRef, useState } from "react";
import type { UiMessage } from "@/lib/use-studio";

function CodeBlock({ lang, code }: { lang: string; code: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="relative mt-3 mb-1 rounded-lg border border-neutral-800 bg-[#121212]">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
        OUTPUT.{(lang || "TXT").toUpperCase()}
      </span>
      <button
        onClick={() => { navigator.clipboard.writeText(code); setCopied(true); setTimeout(() => setCopied(false), 1200); }}
        className="absolute right-2 top-2 font-mono text-[9px] text-neutral-500 hover:text-neutral-200"
      >
        {copied ? "COPIED" : "COPY"}
      </button>
      <pre className="overflow-x-auto p-3 pt-4 font-mono text-xs leading-relaxed text-neutral-200">{code}</pre>
    </div>
  );
}

function parts(content: string) {
  const out: { type: "text" | "code"; lang?: string; body: string }[] = [];
  const re = /```(\w*)\n?([\s\S]*?)(```|$)/g;
  let last = 0, m: RegExpExecArray | null;
  while ((m = re.exec(content))) {
    if (m.index > last) out.push({ type: "text", body: content.slice(last, m.index) });
    out.push({ type: "code", lang: m[1], body: m[2].replace(/\n$/, "") });
    last = re.lastIndex;
  }
  if (last < content.length) out.push({ type: "text", body: content.slice(last) });
  return out;
}

function Bubble({ m, label }: { m: UiMessage; label: string }) {
  if (m.role === "user") {
    return (
      <div className="my-2 flex justify-end">
        <div className="max-w-[80%] whitespace-pre-wrap rounded-xl bg-neutral-200 px-4 py-2 text-sm text-neutral-900">{m.content}</div>
      </div>
    );
  }
  return (
    <div className="my-3 max-w-[92%]">
      {m.pairGroup && <div className="micro-label mb-1">{label}</div>}
      {m.loadState && (
        <div className="stat-line animate-pulse">swapping to {label}… {m.loadState.elapsed.toFixed(0)}s</div>
      )}
      {parts(m.content).map((p, i) =>
        p.type === "code" ? (
          <CodeBlock key={i} lang={p.lang ?? ""} code={p.body} />
        ) : (
          <p key={i} className="whitespace-pre-wrap text-sm leading-relaxed text-neutral-200">{p.body}</p>
        ),
      )}
      {m.streaming && !m.loadState && <span className="animate-pulse font-mono text-neutral-400">▍</span>}
      {m.error && <div className="stat-line mt-1 border border-dashed border-neutral-600 p-2">ERROR: {m.error}</div>}
      {m.stats && (
        <div className="stat-line mt-1.5">
          └─ {m.stats.tps.toFixed(0)} tok/s · {m.stats.gen_tokens} tok · Δ{m.stats.seconds}s
          {m.stats.load_seconds > 0 && ` · load ${m.stats.load_seconds}s`}
        </div>
      )}
    </div>
  );
}

export function Thread({ messages, modelLabel }: { messages: UiMessage[]; modelLabel: (id?: string) => string }) {
  const endRef = useRef<HTMLDivElement>(null);
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: "smooth" }); }, [messages]);

  const rows: (UiMessage | UiMessage[])[] = [];
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    const n = messages[i + 1];
    if (m.role === "assistant" && m.pairGroup && n?.pairGroup === m.pairGroup) {
      rows.push([m, n]);
      i++;
    } else rows.push(m);
  }

  return (
    <div className="flex-1 overflow-y-auto px-6 py-4">
      {messages.length === 0 && (
        <div className="flex h-full items-center justify-center">
          <p className="micro-label">SELECT A PROMPT OR TYPE BELOW</p>
        </div>
      )}
      {rows.map((r, i) =>
        Array.isArray(r) ? (
          <div key={i} className="grid grid-cols-2 gap-4">
            {r.map((m, k) => (
              <div key={k} className="rounded-lg border border-dashed border-neutral-800 p-3">
                <Bubble m={m} label={modelLabel(m.modelId)} />
              </div>
            ))}
          </div>
        ) : (
          <Bubble key={i} m={r as UiMessage} label={modelLabel((r as UiMessage).modelId)} />
        ),
      )}
      <div ref={endRef} />
    </div>
  );
}
