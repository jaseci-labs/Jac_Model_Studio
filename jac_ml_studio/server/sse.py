import json


def sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"
