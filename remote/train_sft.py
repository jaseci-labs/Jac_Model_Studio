#!/usr/bin/env python3
"""LoRA SFT trainer for remote GPU VMs (HuggingFace TRL).

Runs on a CUDA Linux VM for real training, but is written to also run CPU-only
so it can be smoke-tested on a laptop. 4-bit (bitsandbytes) is imported lazily
and only touched when --load_in_4bit is passed, so CPU/Mac envs without
bitsandbytes work fine.

Pinned against: torch==2.5.1, transformers==4.46.3, trl==0.12.2, peft==0.13.2,
datasets==3.1.0, accelerate==1.1.1 (see requirements.txt).

Dataset rows are conversational: {"messages": [{"role": ..., "content": ...}, ...]}.
TRL 0.12's SFTTrainer detects the "messages" column and applies the tokenizer's
chat template automatically, so we do not pre-format text ourselves.

Metrics: one JSON line per logging step is appended to --metrics_file, flushed
per write, so a supervising process can tail the stream live.
"""

import argparse
import json
import os
import sys
import time


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def parse_args():
    p = argparse.ArgumentParser(description="LoRA SFT trainer (TRL).")
    p.add_argument("--model_name_or_path", required=True, help="HF id or local path.")
    p.add_argument("--dataset", required=True, help="Path to train jsonl (messages rows).")
    p.add_argument("--eval_dataset", default=None, help="Optional valid jsonl, same shape.")
    p.add_argument("--output_dir", default="output", help="Adapter saved to <output_dir>/adapter.")
    p.add_argument("--metrics_file", default="metrics.jsonl", help="JSONL metrics stream.")

    # LoRA
    p.add_argument("--lora_r", type=int, default=16)
    p.add_argument("--lora_alpha", type=int, default=32)
    p.add_argument("--lora_dropout", type=float, default=0.05)
    p.add_argument(
        "--target_modules",
        default="q_proj,k_proj,v_proj,o_proj",
        help="Comma-separated module names.",
    )

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
    p.add_argument("--load_in_4bit", action="store_true", help="bitsandbytes nf4 (Linux/CUDA).")

    return p.parse_args()


class MetricsCallback:
    """Appends one JSON line per log event to metrics_file, flushed per write.

    Imported lazily below as a TrainerCallback subclass so importing this module
    does not require transformers at parse time.
    """


def build_callback(metrics_path, total_steps):
    from transformers import TrainerCallback

    class _Cb(TrainerCallback):
        def __init__(self):
            self._start = None

        def on_train_begin(self, args, state, control, **kw):
            self._start = time.time()

        def _write(self, obj):
            with open(metrics_path, "a") as f:
                f.write(json.dumps(obj) + "\n")
                f.flush()

        def on_log(self, args, state, control, logs=None, **kw):
            logs = logs or {}
            step = int(state.global_step)
            ts = time.time()
            if "loss" in logs:
                loss = logs.get("loss")
                lr = logs.get("learning_rate")
                epoch = logs.get("epoch")
                self._write({"step": step, "loss": loss, "lr": lr, "epoch": epoch, "ts": ts})
                m = total_steps or state.max_steps or 0
                loss_s = f"{loss:.3f}" if isinstance(loss, (int, float)) else str(loss)
                print(f"step {step}/{m} loss {loss_s}", flush=True)
            if "eval_loss" in logs:
                self._write({"step": step, "eval_loss": logs.get("eval_loss")})
                print(f"step {step} eval_loss {logs.get('eval_loss'):.3f}", flush=True)

    return _Cb()


def main():
    args = parse_args()

    # --- validate ---
    if not os.path.isfile(args.dataset):
        eprint(f"ERROR: --dataset not found: {args.dataset}")
        sys.exit(2)
    if args.eval_dataset and not os.path.isfile(args.eval_dataset):
        eprint(f"ERROR: --eval_dataset not found: {args.eval_dataset}")
        sys.exit(2)
    if args.max_steps < 0 or args.num_epochs <= 0:
        eprint("ERROR: --max_steps must be >=0 and --num_epochs > 0")
        sys.exit(2)

    import torch
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer, set_seed
    from peft import LoraConfig, prepare_model_for_kbit_training
    from trl import SFTConfig, SFTTrainer

    set_seed(args.seed)

    os.makedirs(args.output_dir, exist_ok=True)
    adapter_dir = os.path.join(args.output_dir, "adapter")
    metrics_dir = os.path.dirname(os.path.abspath(args.metrics_file))
    os.makedirs(metrics_dir, exist_ok=True)

    cuda = torch.cuda.is_available()

    # --- datasets ---
    try:
        train_ds = load_dataset("json", data_files=args.dataset, split="train")
    except Exception as e:  # noqa: BLE001
        eprint(f"ERROR: failed to load --dataset {args.dataset}: {e}")
        sys.exit(3)

    if "messages" not in train_ds.column_names:
        eprint(f"ERROR: train rows must have a 'messages' column; got {train_ds.column_names}")
        sys.exit(3)

    if args.subset and args.subset > 0:
        n = min(args.subset, len(train_ds))
        train_ds = train_ds.select(range(n))

    eval_ds = None
    if args.eval_dataset:
        eval_ds = load_dataset("json", data_files=args.eval_dataset, split="train")
        if args.subset and args.subset > 0:
            eval_ds = eval_ds.select(range(min(args.subset, len(eval_ds))))

    print(f"train rows: {len(train_ds)}" + (f" | eval rows: {len(eval_ds)}" if eval_ds else ""), flush=True)

    # --- tokenizer ---
    tokenizer = AutoTokenizer.from_pretrained(args.model_name_or_path)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    # --- model (+ optional 4-bit) ---
    model_kwargs = {}
    quant_config = None
    if args.load_in_4bit:
        # bitsandbytes is Linux/CUDA-only; import lazily so CPU/Mac never needs it.
        try:
            import bitsandbytes  # noqa: F401
        except Exception as e:  # noqa: BLE001
            eprint(f"ERROR: --load_in_4bit requires bitsandbytes (Linux/CUDA): {e}")
            sys.exit(4)
        from transformers import BitsAndBytesConfig

        quant_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=torch.bfloat16 if args.bf16 else torch.float16,
        )
        model_kwargs["quantization_config"] = quant_config
        model_kwargs["device_map"] = "auto"

    if args.bf16:
        model_kwargs["torch_dtype"] = torch.bfloat16
    elif cuda:
        model_kwargs["torch_dtype"] = torch.float16
    else:
        model_kwargs["torch_dtype"] = torch.float32

    model = AutoModelForCausalLM.from_pretrained(args.model_name_or_path, **model_kwargs)
    model.config.use_cache = False
    if quant_config is not None:
        model = prepare_model_for_kbit_training(model)

    # --- LoRA ---
    peft_config = LoraConfig(
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        target_modules=[m.strip() for m in args.target_modules.split(",") if m.strip()],
        bias="none",
        task_type="CAUSAL_LM",
    )

    use_epochs = args.max_steps == 0
    do_eval = eval_ds is not None

    sft_config = SFTConfig(
        output_dir=args.output_dir,
        max_seq_length=args.max_seq_len,
        per_device_train_batch_size=args.per_device_batch_size,
        per_device_eval_batch_size=args.per_device_batch_size,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        num_train_epochs=args.num_epochs if use_epochs else 1.0,
        max_steps=-1 if use_epochs else args.max_steps,
        logging_steps=1,
        logging_strategy="steps",
        eval_strategy="steps" if do_eval else "no",
        eval_steps=args.eval_every if do_eval else None,
        save_strategy="no",
        report_to=[],
        seed=args.seed,
        bf16=bool(args.bf16),
        gradient_checkpointing=False,
        dataset_num_proc=1,
        packing=False,
    )

    total_steps = args.max_steps if not use_epochs else 0

    trainer = SFTTrainer(
        model=model,
        args=sft_config,
        train_dataset=train_ds,
        eval_dataset=eval_ds,
        processing_class=tokenizer,
        peft_config=peft_config,
        callbacks=[build_callback(args.metrics_file, total_steps)],
    )

    print("starting training...", flush=True)
    result = trainer.train()
    runtime = getattr(result, "metrics", {}).get("train_runtime")

    # --- save adapter + tokenizer ---
    trainer.model.save_pretrained(adapter_dir)
    tokenizer.save_pretrained(adapter_dir)

    with open(args.metrics_file, "a") as f:
        f.write(
            json.dumps(
                {"event": "done", "adapter_dir": adapter_dir, "train_runtime_s": runtime}
            )
            + "\n"
        )
        f.flush()

    print(f"done. adapter saved to {adapter_dir}", flush=True)


if __name__ == "__main__":
    main()
