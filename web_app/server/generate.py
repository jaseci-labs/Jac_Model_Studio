"""Prompt building + the real mlx token stream.

Mirrors srccurrent/jacgen/eval_probe.jac: full message history through the
tokenizer chat template (no system prompt — training data had none), then
mlx_lm.stream_generate.
"""


def build_prompt(tokenizer, messages: list[dict]):
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def stream_tokens(model, tokenizer, messages, temperature, top_p, max_tokens):
    """Blocking generator yielding (text, generation_tokens, generation_tps)."""
    import mlx_lm
    from mlx_lm.sample_utils import make_sampler

    sampler = make_sampler(temp=temperature, top_p=top_p)
    ptoks = build_prompt(tokenizer, messages)
    for resp in mlx_lm.stream_generate(model, tokenizer, ptoks,
                                       max_tokens=max_tokens, sampler=sampler):
        yield resp.text, resp.generation_tokens, resp.generation_tps
