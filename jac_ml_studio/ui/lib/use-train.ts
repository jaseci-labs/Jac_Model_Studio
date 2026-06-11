"use client";
import { useState, useRef, useEffect, useCallback } from "react";
import { usePoll } from "./use-poll";
import { trainApi } from "./api-train";
import type { Session, JobStatus, RunMetrics, CompareResult } from "./api-train";

export type TrainTab = "launch" | "monitor" | "history";
type FeedState = "live" | "stalled" | "nofeed";

const SFT_OPT_KEYS = ["EVAL_EVERY", "SUBSET", "DRY_ITERS", "SKIP_DRY"] as const;
const DPO_OPT_KEYS = ["DPO_ITERS", "DPO_LR", "DPO_BETA", "SUBSET"] as const;

const DEFAULT_OPTS: Record<string, string> = {
  EVAL_EVERY: "60",
  SUBSET: "50",
  DRY_ITERS: "30",
  SKIP_DRY: "0",
  DPO_ITERS: "200",
  DPO_LR: "1e-6",
  DPO_BETA: "0.1",
};

interface LaunchForm {
  modelId: string;
  name: string;
  mode: "sft" | "dpo";
  opts: Record<string, string>;
}

export function useTrain(active: boolean) {
  const [tab, setTab] = useState<TrainTab>("launch");
  const [sessions, setSessions] = useState<Session[]>([]);
  const [form, setForm] = useState<LaunchForm>({
    modelId: "Qwen/Qwen3-Coder-30B-A3B-Instruct",
    name: "qwen",
    mode: "sft",
    opts: { ...DEFAULT_OPTS },
  });
  const [job, setJob] = useState<JobStatus | null>(null);
  const [selected, setSelected] = useState<{ name: string; mode: string } | null>(null);
  const [metrics, setMetrics] = useState<RunMetrics | null>(null);
  const [compare, setCompare] = useState<CompareResult | null>(null);
  const [compareMode, setCompareMode] = useState<"sft" | "dpo">("sft");
  const [feed, setFeed] = useState<FeedState>("nofeed");
  const [stalledFor, setStalledFor] = useState(0);
  const [error, setError] = useState<string | null>(null);

  // History-specific state
  const [historyView, setHistoryView] = useState<"runs" | "compare">("runs");
  const [historySel, setHistorySel] = useState<{ name: string; mode: string } | null>(null);
  const [historyMetrics, setHistoryMetrics] = useState<RunMetrics | null>(null);

  const lastIterRef = useRef<number>(-1);
  const samePollsRef = useRef<number>(0);
  // Keep a ref so the sessions poll callback can read current selected without closure staleness
  const selectedRef = useRef<{ name: string; mode: string } | null>(null);
  useEffect(() => { selectedRef.current = selected; });

  const historySelRef = useRef<{ name: string; mode: string } | null>(null);
  useEffect(() => { historySelRef.current = historySel; });

  // Sessions poll — always active when section is active.
  usePoll(
    async () => {
      try {
        const res = await trainApi.sessions();
        const all: Session[] = res.sessions;
        setSessions(all);

        // Monitor auto-select: only pick running sessions
        const running = all.filter((s) => s.status === "running");
        const cur = selectedRef.current;
        if (cur) {
          // If selected session is no longer running, clear it (it moved to history)
          const stillRunning = running.find((s) => s.name === cur.name && s.mode === cur.mode);
          if (!stillRunning) {
            setSelected(null);
            lastIterRef.current = -1;
            samePollsRef.current = 0;
          }
        }
        if (!selectedRef.current && running.length > 0) {
          setSelected({ name: running[0].name, mode: running[0].mode });
          lastIterRef.current = -1;
          samePollsRef.current = 0;
        }
      } catch {
        // silent
      }
    },
    5000,
    active
  );

  // Job status poll — only when tab === "launch"
  usePoll(
    async () => {
      if (!form.name) return;
      try {
        const j = await trainApi.status(form.name, form.mode);
        setJob(j);
        setError(null);
      } catch (e) {
        setError(e instanceof Error ? e.message : "fetch error");
      }
    },
    2500,
    active && tab === "launch"
  );

  // Metrics poll — only when tab === "monitor" && selected
  usePoll(
    async () => {
      if (!selected) return;
      try {
        const m = await trainApi.metrics(selected.name, selected.mode);
        setMetrics(m);

        if (!m.found || !m.running) {
          setFeed("nofeed");
          return;
        }

        if (m.last_iter > lastIterRef.current) {
          lastIterRef.current = m.last_iter;
          samePollsRef.current = 0;
          setFeed("live");
          setStalledFor(0);
        } else {
          samePollsRef.current += 1;
          if (samePollsRef.current >= 12) {
            setFeed("stalled");
            setStalledFor(samePollsRef.current * 2.5);
          }
        }
      } catch {
        // silent
      }
    },
    2500,
    active && tab === "monitor" && selected !== null
  );

  // Compare fetch — one-shot on tab entry + compareMode change
  const compareFetchActive = active && tab === "history";
  useEffect(() => {
    if (!compareFetchActive) return;
    let cancelled = false;
    trainApi
      .compare(compareMode)
      .then((res) => {
        if (!cancelled) setCompare(res);
      })
      .catch(() => { /* silent */ });
    return () => { cancelled = true; };
  }, [compareFetchActive, compareMode]);

  // History runs view: fetch metrics once when historySel changes
  useEffect(() => {
    if (!active || tab !== "history" || historyView !== "runs" || !historySel) return;
    let cancelled = false;
    trainApi
      .metrics(historySel.name, historySel.mode)
      .then((m) => {
        if (!cancelled) setHistoryMetrics(m);
      })
      .catch(() => { /* silent */ });
    return () => { cancelled = true; };
  }, [active, tab, historyView, historySel]);

  // Auto-select first non-running session when entering history runs view with nothing selected.
  // Deferred to avoid calling setState synchronously in the effect body.
  useEffect(() => {
    if (!active || tab !== "history" || historyView !== "runs") return;
    if (historySelRef.current) return;
    const candidate = sessions.find((s) => s.mode === compareMode && s.status !== "running");
    if (!candidate) return;
    const id = setTimeout(() => {
      if (!historySelRef.current) {
        setHistorySel({ name: candidate.name, mode: candidate.mode });
      }
    }, 0);
    return () => clearTimeout(id);
  }, [active, tab, historyView, sessions, compareMode]);

  // Actions
  const start = useCallback(async () => {
    const keys = form.mode === "sft" ? SFT_OPT_KEYS : DPO_OPT_KEYS;
    const filtered: Record<string, string> = {};
    for (const k of keys) {
      if (form.opts[k] !== undefined) filtered[k] = form.opts[k];
    }
    try {
      const j = await trainApi.start({
        model_id: form.mode === "sft" ? form.modelId : null,
        name: form.name,
        mode: form.mode,
        opts: filtered,
      });
      setJob(j);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "start failed");
    }
  }, [form]);

  const stop = useCallback(async () => {
    try {
      const j = await trainApi.stop(form.name, form.mode);
      setJob(j);
    } catch (e) {
      setError(e instanceof Error ? e.message : "stop failed");
    }
  }, [form.name, form.mode]);

  const updateForm = useCallback(<K extends keyof LaunchForm>(key: K, value: LaunchForm[K]) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  }, []);

  const updateOpt = useCallback((key: string, value: string) => {
    setForm((prev) => ({ ...prev, opts: { ...prev.opts, [key]: value } }));
  }, []);

  const pickSession = useCallback((name: string, mode: string) => {
    setSelected({ name, mode });
    lastIterRef.current = -1;
    samePollsRef.current = 0;
    setFeed("nofeed");
    setStalledFor(0);
  }, []);

  const pickHistorySession = useCallback((name: string, mode: string) => {
    setHistorySel({ name, mode });
    setHistoryMetrics(null);
  }, []);

  return {
    tab,
    setTab,
    sessions,
    form,
    updateForm,
    updateOpt,
    job,
    selected,
    pickSession,
    metrics,
    compare,
    compareMode,
    setCompareMode,
    feed,
    stalledFor,
    error,
    start,
    stop,
    historyView,
    setHistoryView,
    historySel,
    pickHistorySession,
    historyMetrics,
    SFT_OPT_KEYS,
    DPO_OPT_KEYS,
  };
}
