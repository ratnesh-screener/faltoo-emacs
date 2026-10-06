#!/usr/bin/env python3
"""Bridge helpers shared by both cores, free of FaltooBot imports.
Importing FaltooBot costs about 0.4 s, so the Claude bridge must not pay it for its own commands."""
from __future__ import annotations

import argparse
from collections.abc import Callable
import json
from pathlib import Path
import sys
from typing import Any


def _workspace(workspace: Path) -> Path:
    return workspace.expanduser().resolve()


def _stdin_payload() -> dict[str, Any]:
    payload = json.loads(sys.stdin.read() or "{}")
    if isinstance(payload, dict):
        return payload
    return {}


def _last_user_turns(
    messages_payload: list[dict[str, str]], turns: int | None
) -> list[dict[str, str]]:
    if turns is None:
        return messages_payload

    seen = 0
    start = 0
    for index in range(len(messages_payload) - 1, -1, -1):
        if messages_payload[index]["role"] == "user":
            seen += 1
            if seen == turns:
                start = index
                break
    return messages_payload[start:]


TREE_PREVIEW_SOURCE_LIMIT = 2000


def _tree_one_line(value: Any) -> str:
    if isinstance(value, str):
        text = value[:TREE_PREVIEW_SOURCE_LIMIT].replace("\n", " ").strip()
        if "data:image/" in text:
            text = text.split("data:image/", maxsplit=1)[0] + "[inline image omitted]"
        return " ".join(text.split())
    if isinstance(value, (dict, list)):
        return "[structured output]"
    return str(value)


def _emit_payload(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def run_cli(
    prog: str,
    commands: dict[str, Callable[[argparse.Namespace], int]],
    argv: list[str] | None = None,
    options: dict[str, dict[str, Any]] | None = None,
) -> int:
    """Run the bridge command Emacs named; all commands share one option set."""
    parser = argparse.ArgumentParser(prog=prog)
    parser.add_argument("command", choices=sorted(commands))
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--turns", type=int)
    for flag, kwargs in (options or {}).items():
        parser.add_argument(flag, **kwargs)
    args = parser.parse_args(argv)
    return commands[args.command](args)
