"use client";
import { useState } from "react";
import { highlight } from "@/lib/highlight";

export function CodeBlock({
  lang,
  code,
  label,
}: {
  lang: string;
  code: string;
  label?: string;
}) {
  const [copied, setCopied] = useState(false);
  const tab = label ?? `OUTPUT.${(lang || "TXT").toUpperCase()}`;

  return (
    <div className="relative mt-3 mb-1 rounded-lg border border-neutral-800 bg-[#121212]">
      <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">{tab}</span>
      <button
        onClick={() => {
          navigator.clipboard.writeText(code);
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        }}
        className="absolute right-2 top-2 font-mono text-[9px] text-neutral-500 hover:text-neutral-200"
      >
        {copied ? "COPIED" : "COPY"}
      </button>
      <pre className="overflow-x-auto p-3 pt-4 font-mono text-xs leading-relaxed text-neutral-200">
        {highlight(code)}
      </pre>
    </div>
  );
}
