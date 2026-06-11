"use client";
import { useTrain } from "@/lib/use-train";
import { SubTabs } from "@/components/shared/sub-tabs";
import { LaunchTab } from "./launch-tab";
import { MonitorTab } from "./monitor-tab";
import { HistoryTab } from "./history-tab";

const TABS = ["LAUNCH", "MONITOR", "HISTORY"] as const;

export default function TrainSection({ active }: { active: boolean }) {
  const train = useTrain(active);

  // SubTabs uses uppercase labels; internal state is lowercase
  const activeTabLabel = train.tab.toUpperCase();

  function handleTabChange(t: string) {
    train.setTab(t.toLowerCase() as "launch" | "monitor" | "history");
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
        <span className="micro-label text-neutral-600">TRAIN.CTL</span>
      </div>

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
          />
        )}
      </div>
    </div>
  );
}
