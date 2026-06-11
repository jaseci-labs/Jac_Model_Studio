"""Build prompts.json: 12 holdout conversions + handwritten idiom/explain/general.

Run from web_app/server/:  .venv/bin/python scripts/build_prompts.py
Reads the holdout from JAC_STUDIO_DATA_ROOT (models repo), writes prompts.json.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config

IDIOMS = [
    "Write a Jac walker named Greeter that visits every node connected to root and prints each node's name.",
    "Define a Jac node type Person with has fields name: str and age: int, plus an ability that prints a greeting when a walker visits.",
    "Write Jac code that creates 5 City nodes, connects them in a chain with ++> edges, then spawns a walker that counts them.",
    "Show idiomatic Jac for a typed edge: define an edge Road with has miles: float and connect two City nodes with it.",
    "Write a Jac object (obj) called Stack with push, pop, and peek methods backed by a list.",
    "Write a Jac walker that does breadth-first traversal from root and collects node names into a list, then reports it on exit.",
    "Use a Jac impl block: declare def fib(n: int) -> int; in one place and implement it in an impl block.",
    "Write Jac with entry code that filters a list of numbers with a comprehension and prints the evens.",
]

EXPLAIN = [
    "Explain what this Jac code does:\n\n```jac\nwalker Counter {\n    has count: int = 0;\n    can count_nodes with `root entry {\n        visit [-->];\n    }\n    can tally with entry {\n        self.count += 1;\n    }\n}\n```",
    "What does the ++> operator do in Jac? Show a small example.",
    "Explain the difference between a node, an edge, and a walker in Jac's object-spatial model.",
    "What does this Jac do?\n\n```jac\nnode Person {\n    has name: str;\n    can greet with Visitor entry {\n        print(f\"hello {self.name}\");\n    }\n}\n```",
    "Explain what an impl block is in Jac and why you would separate declaration from implementation.",
    "What is the root node in Jac and how do walkers start from it?",
]

GENERAL = [
    "Write a Python function that merges two sorted lists into one sorted list without using sort().",
    "Explain the difference between BFS and DFS and when you'd pick each.",
    "Write a Python function to check whether a string is a valid palindrome, ignoring case and punctuation.",
    "What does this regex match: ^\\d{3}-\\d{2}-\\d{4}$ ? Suggest a clearer alternative.",
    "Write a Python generator that yields the running average of a stream of numbers.",
]


def pick_conversions(n=12) -> list[str]:
    holdout = config.data_root() / "dataset/eval_holdout/conversion.jsonl"
    recs = [json.loads(l) for l in holdout.read_text().splitlines() if l.strip()]
    stride = max(1, len(recs) // n)
    picked = recs[::stride][:n]
    return [r["prompt"] for r in picked]


def main():
    out = {"categories": [
        {"id": "py2jac", "label": "Python → Jac", "prompts": pick_conversions()},
        {"id": "idioms", "label": "Jac idioms", "prompts": IDIOMS},
        {"id": "explain", "label": "Explain Jac", "prompts": EXPLAIN},
        {"id": "general", "label": "General code", "prompts": GENERAL},
    ]}
    dest = Path(__file__).resolve().parents[1] / "prompts.json"
    dest.write_text(json.dumps(out, indent=2))
    counts = {c["id"]: len(c["prompts"]) for c in out["categories"]}
    print(f"wrote {dest} — {counts}")


if __name__ == "__main__":
    main()
