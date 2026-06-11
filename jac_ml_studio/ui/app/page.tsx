"use client";
import { useState } from "react";
import dynamic from "next/dynamic";
import { NavRail, type Section } from "@/components/nav-rail";
import { ChatSection } from "@/components/chat-section";

const SECTIONS: Section[] = ["chat", "train", "data", "evals"];

function initialSection(): Section {
  if (typeof window === "undefined") return "chat";
  const h = window.location.hash.replace("#", "") as Section;
  return SECTIONS.includes(h) ? h : "chat";
}

function Placeholder({ name, phase }: { name: string; phase: number }) {
  return (
    <div className="flex h-full flex-1 items-center justify-center">
      <p className="micro-label">{name} — PHASE {phase}</p>
    </div>
  );
}

const TrainSection = dynamic(
  () => import("@/components/sections/train/train-section"),
  { ssr: false, loading: () => <Placeholder name="TRAIN" phase={2} /> }
);

export default function Home() {
  const [section, setSection] = useState<Section>(initialSection);
  const [visited, setVisited] = useState<Set<Section>>(() => new Set([initialSection()]));

  const go = (s: Section) => {
    setSection(s);
    setVisited((v) => new Set(v).add(s));
    history.replaceState(null, "", s === "chat" ? window.location.pathname : `#${s}`);
  };

  const slot = (s: Section) => (s === section ? "flex min-w-0 flex-1" : "hidden");

  return (
    <div className="flex h-screen overflow-hidden">
      <NavRail section={section} onSection={go} />
      <div className={slot("chat")}>
        <ChatSection />
      </div>
      {visited.has("train") && (
        <div className={slot("train")}>
          <TrainSection active={section === "train"} />
        </div>
      )}
      {visited.has("data") && (
        <div className={slot("data")}>
          <Placeholder name="DATA" phase={3} />
        </div>
      )}
      {visited.has("evals") && (
        <div className={slot("evals")}>
          <Placeholder name="EVALS" phase={4} />
        </div>
      )}
    </div>
  );
}
