"use client";
import React from "react";

export type Section = "chat" | "train" | "data" | "evals";

const GLYPHS: Record<Section, React.ReactNode> = {
  chat: (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <path d="M2 3h12v8H6l-3 3v-3H2z" strokeLinejoin="miter" />
    </svg>
  ),
  train: (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <path d="M2 13h12" stroke="#444" />
      <path d="M2 3c3 0 3 7 6 7 2 0 3-2 6-2" />
    </svg>
  ),
  data: (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="3" y="2" width="10" height="3.4" />
      <rect x="3" y="6.3" width="10" height="3.4" />
      <rect x="3" y="10.6" width="10" height="3.4" />
    </svg>
  ),
  evals: (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="2.5" y="2.5" width="5" height="5" />
      <rect x="8.5" y="2.5" width="5" height="5" />
      <rect x="2.5" y="8.5" width="5" height="5" />
      <path d="M9.5 11l1.5 1.5L13.5 9" />
    </svg>
  ),
};

const LABELS: Record<Section, string> = { chat: "CHAT", train: "TRAIN", data: "DATA", evals: "EVALS" };
const ORDER: Section[] = ["chat", "train", "data", "evals"];

export function NavRail({ section, onSection }: { section: Section; onSection: (s: Section) => void }) {
  return (
    <nav className="flex w-12 shrink-0 flex-col items-center border-r border-neutral-800 bg-[#0d0d0d] py-3">
      <span className="micro-label mb-6 [writing-mode:vertical-lr]">JAC·ML</span>
      <div className="flex flex-col gap-1">
        {ORDER.map((s) => (
          <button
            key={s}
            title={LABELS[s]}
            onClick={() => onSection(s)}
            className={`relative flex h-10 w-10 items-center justify-center rounded-md transition-colors ${
              s === section ? "text-neutral-100" : "text-neutral-600 hover:text-neutral-300"
            }`}
          >
            {s === section && <span className="absolute left-0 top-2 bottom-2 w-[2px] bg-neutral-100" />}
            {GLYPHS[s]}
            <span className="sr-only">{LABELS[s]}</span>
          </button>
        ))}
      </div>
      <div className="flex-1" />
      <span className="micro-label [writing-mode:vertical-lr]">v2</span>
    </nav>
  );
}
