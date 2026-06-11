import { j } from "./api";

export type FileRef = { path: string; label: string; count: number };

export type DataRow = {
  idx: number;
  name: string;
  difficulty: string;
  source: string;
  kind: "sft" | "dpo" | "holdout" | "raw";
  preview: string;
  prompt: string;
  python: string;
  jac: string;
  chosen: string;
  rejected: string;
  raw: string;
};

// Matches datasets.stats() return exactly:
// { sft_files: [{path,total,by_difficulty,by_generator,by_source},...], sft_total, dpo_pairs,
//   splits: {mlx_train,mlx_valid,dpo_train,dpo_valid,holdout,graph_holdout} }
export type SftFileStats = {
  path: string;
  total: number;
  by_difficulty: Record<string, number>;
  by_generator: Record<string, number>;
  by_source: Record<string, number>;
};

export type DatasetStats = {
  sft_files: SftFileStats[];
  sft_total: number;
  dpo_pairs: number;
  splits: {
    mlx_train: number;
    mlx_valid: number;
    dpo_train: number;
    dpo_valid: number;
    holdout: number;
    graph_holdout: number;
  };
};

export type BuilderStatus = {
  stage: string;
  status: string;
  pid?: number;
  started?: string;
  log_tail?: string;
  message?: string;
};

export const dataApi = {
  stats: () => j<DatasetStats>("/api/dataset/stats"),
  files: () => j<{ files: FileRef[] }>("/api/dataset/files"),
  rows: (path: string, offset: number, limit = 25) =>
    j<{ rows: DataRow[]; total: number }>(
      `/api/dataset/rows?path=${encodeURIComponent(path)}&offset=${offset}&limit=${limit}`
    ),
  addExamples: (target: "sft" | "dpo", text: string) =>
    j<{ added: number; errors: string[]; total: number }>("/api/dataset/examples", {
      method: "POST",
      body: JSON.stringify({ target, text }),
    }),
  builders: () => j<{ builders: BuilderStatus[] }>("/api/builders"),
  runBuilder: (stage: string) =>
    j<BuilderStatus>("/api/builders/run", {
      method: "POST",
      body: JSON.stringify({ stage }),
    }),
};
