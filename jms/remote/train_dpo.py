#!/usr/bin/env python3
"""LoRA DPO trainer for remote GPU VMs (HuggingFace TRL) -- STUB.

Argparse skeleton mirrors train_sft.py, plus --beta for DPO. Dataset rows are
preference triples: {"prompt": ..., "chosen": ..., "rejected": ...}.

The body is not wired yet; it raises after parsing so the module stays
importable/parseable and the CLI contract is visible.
"""

import argparse
import sys


def parse_args():
    p = argparse.ArgumentParser(description="LoRA DPO trainer (TRL) -- stub.")
    p.add_argument("--model_name_or_path", required=True, help="HF id or local path.")
    p.add_argument("--dataset", required=True, help="Path to jsonl of {prompt,chosen,rejected}.")
    p.add_argument("--eval_dataset", default=None, help="Optional valid jsonl, same shape.")
    p.add_argument("--output_dir", default="output", help="Adapter saved to <output_dir>/adapter.")
    p.add_argument("--metrics_file", default="metrics.jsonl", help="JSONL metrics stream.")

    # LoRA
    p.add_argument("--lora_r", type=int, default=16)
    p.add_argument("--lora_alpha", type=int, default=32)
    p.add_argument("--lora_dropout", type=float, default=0.05)
    p.add_argument("--target_modules", default="q_proj,k_proj,v_proj,o_proj")

    # Training
    p.add_argument("--max_steps", type=int, default=0, help="0 = use epochs.")
    p.add_argument("--num_epochs", type=float, default=1.0)
    p.add_argument("--per_device_batch_size", type=int, default=1)
    p.add_argument("--grad_accum", type=int, default=4)
    p.add_argument("--lr", type=float, default=1e-4)
    p.add_argument("--max_seq_len", type=int, default=2048)
    p.add_argument("--eval_every", type=int, default=50)
    p.add_argument("--subset", type=int, default=0, help="0 = all rows.")
    p.add_argument("--seed", type=int, default=42)

    # Precision / memory
    p.add_argument("--bf16", action="store_true")
    p.add_argument("--load_in_4bit", action="store_true")

    # DPO
    p.add_argument("--beta", type=float, default=0.1, help="DPO KL regularization strength.")

    return p.parse_args()


def main():
    parse_args()
    raise SystemExit("DPO not wired yet -- Phase later")


if __name__ == "__main__":
    main()
