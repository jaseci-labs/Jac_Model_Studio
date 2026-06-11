"use client";
import { useState, useRef, useEffect, useCallback } from "react";
import { usePoll } from "./use-poll";
import { dataApi } from "./api-data";
import type { DatasetStats, FileRef, BuilderStatus, DataRow } from "./api-data";

interface BrowserState {
  path: string | null;
  offset: number;
  rows: DataRow[];
  total: number;
}

interface AddFormState {
  target: "sft" | "dpo";
  text: string;
  result: { added: number; errors: string[]; total: number } | null;
  busy: boolean;
}

export function useData(active: boolean) {
  const [stats, setStats] = useState<DatasetStats | null>(null);
  const [files, setFiles] = useState<FileRef[]>([]);
  const [builders, setBuilders] = useState<BuilderStatus[]>([]);
  const [selectedStage, setSelectedStage] = useState<string | null>(null);
  const [browser, setBrowser] = useState<BrowserState>({
    path: null,
    offset: 0,
    rows: [],
    total: 0,
  });
  const [expanded, setExpanded] = useState<number | null>(null);
  const [addForm, setAddFormState] = useState<AddFormState>({
    target: "sft",
    text: "",
    result: null,
    busy: false,
  });

  const initializedRef = useRef(false);
  const prevBuildersRef = useRef<BuilderStatus[]>([]);

  // Fetch stats + files
  const fetchStatsAndFiles = useCallback(async () => {
    try {
      const [statsRes, filesRes] = await Promise.all([
        dataApi.stats(),
        dataApi.files(),
      ]);
      setStats(statsRes);
      setFiles(filesRes.files);
    } catch {
      // silent
    }
  }, []);

  // Fetch builders
  const fetchBuilders = useCallback(async () => {
    try {
      const res = await dataApi.builders();
      const prev = prevBuildersRef.current;
      const next = res.builders;

      // Check if any previously-running stage is now done/failed
      if (prev.length > 0) {
        const anyBecameDone = prev.some((p) => {
          if (p.status !== "running") return false;
          const n = next.find((nb) => nb.stage === p.stage);
          return n && n.status !== "running";
        });
        if (anyBecameDone) {
          void fetchStatsAndFiles();
        }
      }

      prevBuildersRef.current = next;
      setBuilders(next);
    } catch {
      // silent
    }
  }, [fetchStatsAndFiles]);

  // On activation: initial fetch
  useEffect(() => {
    if (!active) return;
    if (initializedRef.current) return;
    initializedRef.current = true;
    void fetchStatsAndFiles();
    void fetchBuilders();
  }, [active, fetchStatsAndFiles, fetchBuilders]);

  // Poll builders only while any running
  const anyRunning = builders.some((b) => b.status === "running");
  usePoll(fetchBuilders, 2000, active && anyRunning);

  // Fetch rows for browser
  const fetchRows = useCallback(async (path: string, offset: number) => {
    try {
      const res = await dataApi.rows(path, offset, 25);
      setBrowser({ path, offset, rows: res.rows, total: res.total });
      setExpanded(null);
    } catch {
      // silent
    }
  }, []);

  // Actions
  const selectStage = useCallback((stage: string) => {
    setSelectedStage(stage);
  }, []);

  const runStage = useCallback(async (stage: string) => {
    setSelectedStage(stage);
    try {
      await dataApi.runBuilder(stage);
      // Optimistic refresh
      void fetchBuilders();
    } catch {
      // silent
    }
  }, [fetchBuilders]);

  const openFile = useCallback((path: string) => {
    void fetchRows(path, 0);
  }, [fetchRows]);

  const page = useCallback((dir: 1 | -1) => {
    setBrowser((prev) => {
      if (!prev.path) return prev;
      const newOffset = Math.max(0, Math.min(prev.total - 1, prev.offset + dir * 25));
      void fetchRows(prev.path, newOffset);
      return prev;
    });
  }, [fetchRows]);

  const toggleRow = useCallback((idx: number) => {
    setExpanded((prev) => (prev === idx ? null : idx));
  }, []);

  const setAddForm = useCallback(
    (updates: Partial<Omit<AddFormState, "busy" | "result">>) => {
      setAddFormState((prev) => ({ ...prev, ...updates }));
    },
    []
  );

  const submitExamples = useCallback(async () => {
    setAddFormState((prev) => ({ ...prev, busy: true, result: null }));
    try {
      const res = await dataApi.addExamples(addForm.target, addForm.text);
      setAddFormState((prev) => ({ ...prev, busy: false, result: res }));
      if (res.added > 0) {
        void fetchStatsAndFiles();
      }
    } catch {
      setAddFormState((prev) => ({ ...prev, busy: false }));
    }
  }, [addForm.target, addForm.text, fetchStatsAndFiles]);

  return {
    stats,
    files,
    builders,
    selectedStage,
    browser,
    expanded,
    addForm,
    selectStage,
    runStage,
    openFile,
    page,
    toggleRow,
    setAddForm,
    submitExamples,
  };
}
