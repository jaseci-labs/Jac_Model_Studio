"use client";
import { useState, useEffect, useCallback, useRef } from "react";
import { api, type ModelsResponse } from "./api";
import { evalsApi, type EvalRecord, type EvalDetail } from "./api-evals";
import { usePoll } from "./use-poll";

export type EvalForm = {
  kind: "probe" | "idiom";
  modelId: string | null;
  modelPath: string;
  adapter: string;
  holdout: "function" | "graph";
  limit: string;
  simThreshold: string;
};

const DEFAULT_FORM: EvalForm = {
  kind: "probe",
  modelId: null,
  modelPath: "",
  adapter: "",
  holdout: "graph",
  limit: "",
  simThreshold: "0.7",
};

export function useEvals(active: boolean) {
  const [models, setModels] = useState<ModelsResponse | null>(null);
  const [form, setFormState] = useState<EvalForm>(DEFAULT_FORM);
  const [history, setHistory] = useState<EvalRecord[]>([]);
  const [activeEval, setActiveEval] = useState<EvalDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const initializedRef = useRef(false);

  const fetchList = useCallback(async () => {
    try {
      const res = await evalsApi.list();
      setHistory(res.evals);
    } catch (e) {
      console.error("evals list error", e);
    }
  }, []);

  // On activation: fetch models + list (once)
  useEffect(() => {
    if (!active) return;
    if (initializedRef.current) return;
    initializedRef.current = true;
    void api.models().then((m) => {
      setModels(m);
      setFormState((prev) => ({
        ...prev,
        modelId: prev.modelId ?? (m.models.find((x) => x.available)?.id ?? null),
      }));
    });
    void fetchList();
  }, [active, fetchList]);

  // Poll active eval while running
  const isRunning = activeEval?.status === "running";
  usePoll(
    async () => {
      if (!activeEval) return;
      try {
        const detail = await evalsApi.get(activeEval.id);
        setActiveEval(detail);
        if (detail.status !== "running") {
          void fetchList();
        }
      } catch (e) {
        console.error("eval poll error", e);
      }
    },
    2500,
    active && isRunning
  );

  const setForm = useCallback((patch: Partial<EvalForm>) => {
    setFormState((prev) => ({ ...prev, ...patch }));
  }, []);

  const start = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const { kind, modelId, modelPath, adapter, holdout, limit, simThreshold } = form;
      const record = await evalsApi.start({
        kind,
        model_id: modelPath ? null : (modelId ?? null),
        model_path: modelPath || null,
        adapter: adapter || null,
        holdout,
        limit: limit ? parseInt(limit, 10) : null,
        sim_threshold: kind === "idiom" && simThreshold ? parseFloat(simThreshold) : null,
      });
      const detail = await evalsApi.get(record.id);
      setActiveEval(detail);
      void fetchList();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [form, fetchList]);

  const stopActive = useCallback(async () => {
    if (!activeEval) return;
    try {
      await evalsApi.stop(activeEval.id);
      const detail = await evalsApi.get(activeEval.id);
      setActiveEval(detail);
      void fetchList();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [activeEval, fetchList]);

  const removeEval = useCallback(
    async (id: number) => {
      try {
        await evalsApi.remove(id);
        if (activeEval?.id === id) setActiveEval(null);
        void fetchList();
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [activeEval, fetchList]
  );

  const openEval = useCallback(async (id: number) => {
    try {
      const detail = await evalsApi.get(id);
      setActiveEval(detail);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  return {
    models,
    form,
    setForm,
    history,
    activeEval,
    error,
    busy,
    start,
    stopActive,
    removeEval,
    openEval,
  };
}
