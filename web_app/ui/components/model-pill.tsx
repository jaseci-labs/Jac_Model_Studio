"use client";
import { useState } from "react";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import type { ModelsResponse } from "@/lib/api";

export function ModelPill(props: {
  info: ModelsResponse | null;
  modelId: string;
  compareId: string | null;
  loading: { id: string; elapsed: number } | null;
  loadError: string | null;
  onPick: (id: string) => void;
  onPickCompare: (id: string | null) => void;
}) {
  const { info } = props;
  const [pickerOpen, setPickerOpen] = useState(false);
  const [cmpOpen, setCmpOpen] = useState(false);
  const label = (id: string | null) => info?.models.find((m) => m.id === id)?.label ?? id;
  return (
    <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
      <div className="flex items-center gap-2">
        <Popover open={pickerOpen} onOpenChange={setPickerOpen}>
          <PopoverTrigger className="rounded-full border border-neutral-700 bg-[#161616] px-4 py-1 text-xs text-neutral-200 hover:border-neutral-500">
            {props.loading ? `loading ${label(props.loading.id)}… ${props.loading.elapsed.toFixed(0)}s` : <>{label(props.modelId)} <span className="text-neutral-500">▾</span></>}
          </PopoverTrigger>
          <PopoverContent className="w-56 border-neutral-800 bg-[#121212] p-1">
            {info?.models.map((m) => (
              <button
                key={m.id}
                disabled={!m.available}
                onClick={() => { props.onPick(m.id); setPickerOpen(false); }}
                className="flex w-full items-center justify-between rounded px-2 py-1.5 text-left text-xs text-neutral-300 hover:bg-[#1a1a1a] disabled:opacity-40"
              >
                {m.label}
                <span className="font-mono text-[9px] text-neutral-500">
                  {m.id === info.loaded ? "● LOADED" : m.available ? `${m.size_gb}GB` : "MISSING"}
                </span>
              </button>
            ))}
          </PopoverContent>
        </Popover>
        {props.compareId && (
          <span className="font-mono text-[10px] text-neutral-500">vs {label(props.compareId)}</span>
        )}
        {props.loadError && (
          <span className="font-mono text-[10px] text-neutral-400 border border-dashed border-neutral-600 px-2 py-0.5">LOAD ERR: {props.loadError.slice(0, 60)}</span>
        )}
      </div>
      <Popover open={cmpOpen} onOpenChange={setCmpOpen}>
        <PopoverTrigger className="micro-label hover:text-neutral-300">
          ⇄ COMPARE{props.compareId ? " ·ON" : ""}
        </PopoverTrigger>
        <PopoverContent className="w-56 border-neutral-800 bg-[#121212] p-1" align="end">
          <button
            onClick={() => { props.onPickCompare(null); setCmpOpen(false); }}
            className="w-full rounded px-2 py-1.5 text-left text-xs text-neutral-400 hover:bg-[#1a1a1a]"
          >
            off
          </button>
          {info?.models.filter((m) => m.available && m.id !== props.modelId).map((m) => (
            <button
              key={m.id}
              onClick={() => { props.onPickCompare(m.id); setCmpOpen(false); }}
              className="w-full rounded px-2 py-1.5 text-left text-xs text-neutral-300 hover:bg-[#1a1a1a]"
            >
              {m.label}
            </button>
          ))}
        </PopoverContent>
      </Popover>
    </div>
  );
}
