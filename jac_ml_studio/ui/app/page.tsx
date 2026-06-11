"use client";
import dynamic from "next/dynamic";

// Client-only: the shell reads location.hash for its initial section, which
// can't match the server-rendered HTML — skip SSR for this purely-local app.
const AppShell = dynamic(() => import("@/components/app-shell"), { ssr: false });

export default function Home() {
  return <AppShell />;
}
