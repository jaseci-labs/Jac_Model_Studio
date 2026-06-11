import { j } from "./api";

export type Pt = { x: number; y: number };

export type RunSummary = {
  name: string;
  has_sft: boolean;
  has_dpo: boolean;
  stages: string[];
  running: boolean;
};

export type RunMetrics = {
  name: string;
  mode: string;
  found: boolean;
  running: boolean;
  last_iter: number;
  train: Pt[];
  val: Pt[];
  lr: Pt[];
  tps: Pt[];
  curve: Pt[];
  idiom_sim: Pt[];
  has_idiom: boolean;
  idiom_label: string;
  idiom_avg_sim: number;
  idiom_idiomatic: number;
  idiom_python: number;
  idiom_runs: number;
  idiom_total: number;
  log_tail: string;
};

export type JobStatus = {
  name: string;
  mode: string;
  status: "idle" | "running" | "done" | "failed" | "stopped" | "finished";
  pid: number;
  started: string;
  last_iter: number;
  log_tail: string;
  message: string;
};

export type Session = {
  name: string;
  mode: "sft" | "dpo";
  status: JobStatus["status"];
  last_iter: number;
  started: string;
  label: string;
};

export type CompareRow = Record<string, number> & { x: number };

export type CompareResult = {
  names: string[];
  train: CompareRow[];
  val: CompareRow[];
  curve: CompareRow[];
  headline: {
    name: string;
    final_pass: number;
    last_loss: number;
    idiom_sim: number;
    idiomatic: number;
    idiom_label: string;
    has_idiom: boolean;
  }[];
};

export const trainApi = {
  runs: () => j<{ runs: RunSummary[] }>("/api/runs"),
  metrics: (name: string, mode: string) => j<RunMetrics>(`/api/runs/${name}?mode=${mode}`),
  compare: (mode: string) => j<CompareResult>(`/api/runs/compare?mode=${mode}`),
  sessions: () => j<{ sessions: Session[] }>("/api/train/sessions"),
  status: (name: string, mode: string) => j<JobStatus>(`/api/train/status?name=${name}&mode=${mode}`),
  start: (body: { model_id: string | null; name: string; mode: string; opts: Record<string, string> }) =>
    j<JobStatus>("/api/train/start", { method: "POST", body: JSON.stringify(body) }),
  stop: (name: string, mode: string) =>
    j<JobStatus>("/api/train/stop", { method: "POST", body: JSON.stringify({ name, mode }) }),
  update: () =>
    j<{ ok: boolean; message: string }>("/api/system/update", { method: "POST" }),
};
