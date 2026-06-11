import { StatTile } from "@/components/shared/stat-tile";
import type { DatasetStats } from "@/lib/api-data";

export function StatsTiles({ stats }: { stats: DatasetStats | null }) {
  const dim = !stats;
  const s = stats;

  return (
    <div className="grid grid-cols-3 gap-3 lg:grid-cols-6">
      <StatTile
        label="SFT.TOTAL"
        value={s ? String(s.sft_total) : "·"}
        sub="examples"
        dim={dim}
      />
      <StatTile
        label="DPO.PAIRS"
        value={s ? String(s.dpo_pairs) : "·"}
        sub="pairs"
        dim={dim}
      />
      <StatTile
        label="MLX.SFT"
        value={s ? `${s.splits.mlx_train}/${s.splits.mlx_valid}` : "·"}
        sub="train/valid"
        dim={dim}
      />
      <StatTile
        label="MLX.DPO"
        value={s ? `${s.splits.dpo_train}/${s.splits.dpo_valid}` : "·"}
        sub="train/valid"
        dim={dim}
      />
      <StatTile
        label="HOLDOUT"
        value={s ? String(s.splits.holdout) : "·"}
        sub="function"
        dim={dim}
      />
      <StatTile
        label="HOLDOUT.GRAPH"
        value={s ? String(s.splits.graph_holdout) : "·"}
        sub="graph"
        dim={dim}
      />
    </div>
  );
}
