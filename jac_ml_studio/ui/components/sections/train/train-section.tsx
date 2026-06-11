"use client";
import { useState } from "react";
import { useTrain } from "@/lib/use-train";
import { trainApi } from "@/lib/api-train";
import { SubTabs } from "@/components/shared/sub-tabs";
import { LaunchTab } from "./launch-tab";
import { MonitorTab } from "./monitor-tab";
import { HistoryTab } from "./history-tab";

const TABS = ["LAUNCH", "MONITOR", "HISTORY"] as const;

type UpdateState = "idle" | "confirm" | "updating";

export default function TrainSection({ active }: { active: boolean }) {
  const train = useTrain(active);
  const [updateState, setUpdateState] = useState<UpdateState>("idle");

  // SubTabs uses uppercase labels; internal state is lowercase
  const activeTabLabel = train.tab.toUpperCase();

  function handleTabChange(t: string) {
    train.setTab(t.toLowerCase() as "launch" | "monitor" | "history");
  }

  function handleUpdateClick() {
    if (updateState === "idle") {
      setUpdateState("confirm");
      setTimeout(() => setUpdateState((s) => (s === "confirm" ? "idle" : s)), 4000);
    } else if (updateState === "confirm") {
      setUpdateState("updating");
      trainApi.update().catch(() => {});
      setTimeout(() => location.reload(), 20000);
    }
  }

  return (
    <div className="flex flex-col h-full min-w-0 flex-1">
      {/* Header row */}
      <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
        <SubTabs
          tabs={[...TABS]}
          active={activeTabLabel}
          onTab={handleTabChange}
        />
        <div className="flex items-center gap-2">
          <button
            onClick={handleUpdateClick}
            disabled={updateState === "updating"}
            className={`border border-neutral-600 rounded-lg px-3 py-1 font-mono text-[10px] hover:border-neutral-400 disabled:opacity-30 transition-colors ${
              updateState === "confirm" ? "text-neutral-100" : "text-neutral-400"
            }`}
          >
            {updateState === "idle" && "⟳ UPDATE APP"}
            {updateState === "confirm" && "CONFIRM RESTART?"}
            {updateState === "updating" && "UPDATING…"}
          </button>
          <span className="micro-label text-neutral-600">TRAIN.CTL</span>
        </div>
      </div>

      {updateState === "updating" && (
        <div className="px-4 py-1 border-b border-neutral-800">
          <span className="stat-line text-neutral-500">restarting · page reloads in ~20s</span>
        </div>
      )}

      {/* Body */}
      <div className="overflow-y-auto flex-1 min-h-0">
        {train.tab === "launch" && (
          <LaunchTab
            form={train.form}
            updateForm={train.updateForm}
            updateOpt={train.updateOpt}
            job={train.job}
            error={train.error}
            onStart={train.start}
            onStop={train.stop}
            sftKeys={train.SFT_OPT_KEYS}
            dpoKeys={train.DPO_OPT_KEYS}
          />
        )}
        {train.tab === "monitor" && (
          <MonitorTab
            sessions={train.sessions}
            selected={train.selected}
            onPickSession={train.pickSession}
            metrics={train.metrics}
            feed={train.feed}
            stalledFor={train.stalledFor}
          />
        )}
        {train.tab === "history" && (
          <HistoryTab
            compare={train.compare}
            compareMode={train.compareMode}
            onSetCompareMode={train.setCompareMode}
            historyView={train.historyView}
            onSetHistoryView={train.setHistoryView}
            historySel={train.historySel}
            onPickHistorySession={train.pickHistorySession}
            historyMetrics={train.historyMetrics}
            sessions={train.sessions}
          />
        )}
      </div>
    </div>
  );
}
