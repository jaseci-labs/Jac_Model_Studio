import { j } from "./api";

export type EvalScores = Record<string, number | string>;

export type EvalRecord = {
  id: number;
  kind: "probe" | "idiom";
  model: string;
  adapter: string | null;
  holdout: string;
  params: { limit?: number | null; sim_threshold?: number | null } | null;
  pid: number | null;
  scores: EvalScores | null;
  status: "running" | "done" | "failed" | "stopped";
  started: string;
  finished: string | null;
};

export type EvalDetail = EvalRecord & { log_tail: string };

export const evalsApi = {
  list: () => j<{ evals: EvalRecord[] }>("/api/evals"),
  get: (id: number) => j<EvalDetail>(`/api/evals/${id}`),
  start: (body: {
    kind: string;
    model_id?: string | null;
    model_path?: string | null;
    adapter?: string | null;
    holdout: string;
    limit?: number | null;
    sim_threshold?: number | null;
  }) => j<EvalRecord>("/api/evals", { method: "POST", body: JSON.stringify(body) }),
  stop: (id: number) => j<EvalRecord>(`/api/evals/${id}/stop`, { method: "POST" }),
  remove: (id: number) => j<{ ok: boolean }>(`/api/evals/${id}`, { method: "DELETE" }),
};
