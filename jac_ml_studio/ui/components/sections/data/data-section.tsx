"use client";
import { useData } from "@/lib/use-data";
import { StatsTiles } from "./stats-tiles";
import { PipelineRail } from "./pipeline-rail";
import { DatasetBrowser } from "./dataset-browser";
import { AddExamples } from "./add-examples";
import { LogView } from "@/components/shared/log-view";

export default function DataSection({ active }: { active: boolean }) {
  const data = useData(active);

  const selectedBuilder = data.selectedStage
    ? data.builders.find((b) => b.stage === data.selectedStage)
    : null;

  return (
    <div className="flex h-full min-w-0 flex-1 flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
        <span className="micro-label">DATA.PIPELINE</span>
        <span className="micro-label text-neutral-600">DATASET.CTL</span>
      </div>

      {/* Body */}
      <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
        {/* Stats row */}
        <StatsTiles stats={data.stats} />

        {/* Main grid */}
        <div className="grid gap-4" style={{ gridTemplateColumns: "280px 1fr" }}>
          {/* Left: pipeline + stage log */}
          <div className="flex flex-col gap-4">
            <PipelineRail
              builders={data.builders}
              selectedStage={data.selectedStage}
              onRun={data.runStage}
              onSelect={data.selectStage}
            />

            {/* Stage log panel */}
            {data.selectedStage && (
              <div className="relative rounded-md border border-neutral-800 bg-[#0d0d0d] p-3 pt-4">
                <span className="micro-label absolute -top-2 left-3 bg-[#0a0a0a] px-2">
                  {data.selectedStage}
                </span>
                <LogView
                  text={selectedBuilder?.log_tail ?? ""}
                  maxH="14rem"
                />
              </div>
            )}
          </div>

          {/* Right: browser + add examples */}
          <div className="flex flex-col gap-4">
            <DatasetBrowser
              files={data.files}
              browser={data.browser}
              expanded={data.expanded}
              onOpenFile={data.openFile}
              onPage={data.page}
              onToggleRow={data.toggleRow}
            />
            <AddExamples
              addForm={data.addForm}
              onSetAddForm={data.setAddForm}
              onSubmit={data.submitExamples}
            />
          </div>
        </div>
      </div>
    </div>
  );
}
