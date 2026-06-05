#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from uuid import uuid4
import sys
from typing import Any

SHELL_COMMAND_SEPARATOR = "\n\n<!-- shell-command -->\n\n"

from faltoobot.faltoochat.git import get_unstaged_files, is_git_workspace  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.review_api import Review, reviews_prompt  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.slash_commands import SlashCommandStore  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.messages_rendering import get_item_text  # ty: ignore[unresolved-import]
from faltoobot.faltoochat.stream import get_event_text  # ty: ignore[unresolved-import]
from faltoobot.config import build_config, config_status_text  # ty: ignore[unresolved-import]
from faltoobot.sessions import (  # ty: ignore[unresolved-import]
    Session,
    append_user_turn,
    get_answer_streaming,
    get_dir_chat_key,
    get_last_usage,
    get_messages,
    get_session,
    list_sessions,
    set_session_name,
)


def _workspace(workspace: Path) -> Path:
    return workspace.expanduser().resolve()


def _chat_key(workspace: Path) -> str:
    return get_dir_chat_key(_workspace(workspace))


def _session(workspace: Path) -> Session:
    workspace = _workspace(workspace)
    return get_session(_chat_key(workspace), workspace=workspace)


def _session_payload(session: Session) -> dict[str, str]:
    messages = get_messages(session)
    return {
        "session_id": session.session_id,
        "chat_key": session.chat_key,
        "workspace": str(messages["workspace"]),
        "messages_path": str(session.messages_path),
    }


def _tool_summary(text: str) -> str:
    return text.split(SHELL_COMMAND_SEPARATOR, maxsplit=1)[0].strip()


def _stdin_payload() -> dict[str, Any]:
    payload = json.loads(sys.stdin.read() or "{}")
    if isinstance(payload, dict):
        return payload
    return {}


def _payload_comments(payload: dict[str, Any]) -> list[dict[str, Any]]:
    comments = payload.get("comments")
    if not isinstance(comments, list):
        return []
    return [item for item in comments if isinstance(item, dict)]


def messages_path(workspace: Path) -> int:
    session = _session(workspace)
    print(session.messages_path)
    return 0


def unstaged_files(workspace: Path) -> int:
    workspace = workspace.expanduser().resolve()
    if not is_git_workspace(workspace):
        print(
            json.dumps(
                {"ok": False, "error": "Not inside a git repository"},
                ensure_ascii=False,
            )
        )
        return 0

    files = []
    for path in get_unstaged_files(workspace):
        full_path = workspace / path
        if full_path.is_file():
            # Deleted files can appear in git diff but cannot be opened as buffers.
            files.append(str(full_path.resolve()))

    print(json.dumps({"ok": True, "files": files}, ensure_ascii=False))
    return 0


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


def messages(workspace: Path, limit: int, turns: int | None) -> int:
    items = get_messages(_session(workspace))["messages"][-limit:]
    messages_payload: list[dict[str, str]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        rendering = get_item_text(item)
        if not rendering:
            continue
        text, classes = rendering
        role = "assistant" if classes in {"answer", "thinking"} else classes
        messages_payload.append({"role": role, "text": _tool_summary(text) if classes == "tool" else text.strip()})

    print(json.dumps({"messages": _last_user_turns(messages_payload, turns)}, ensure_ascii=False))
    return 0


def _normalize_comments(items: list[dict[str, Any]]) -> list[Review]:
    comments: list[Review] = []
    for item in items:
        line = int(item.get("line_number_start") or 0)
        end = int(item.get("line_number_end") or line)
        comments.append(
            {
                "filename": Path(str(item.get("filename") or "[No Name]")),
                "line_number_start": line,
                "line_number_end": end,
                "file_line_number_start": int(
                    item.get("file_line_number_start") or line
                ),
                "file_line_number_end": int(item.get("file_line_number_end") or end),
                "code": str(item.get("code") or ""),
                "comment": str(item.get("comment") or ""),
            }
        )
    return comments


BUILTIN_SLASH_COMMANDS = frozenset(
    {"/compact", "/name", "/reset", "/resume", "/status", "/tree"}
)


def session_info(workspace: Path) -> int:
    print(json.dumps(_session_payload(_session(workspace)), ensure_ascii=False))
    return 0


def reset_session(workspace: Path) -> int:
    workspace = _workspace(workspace)
    session = get_session(_chat_key(workspace), session_id=str(uuid4()), workspace=workspace)
    print(json.dumps(_session_payload(session), ensure_ascii=False))
    return 0


def name_session(workspace: Path, name: str) -> int:
    session = _session(workspace)
    set_session_name(session, name)
    print(json.dumps(_session_payload(session), ensure_ascii=False))
    return 0


def sessions_list(workspace: Path) -> int:
    print(json.dumps({"sessions": list_sessions(_chat_key(workspace))}, ensure_ascii=False))
    return 0


def resume_session(workspace: Path, session_id: str) -> int:
    session = get_session(_chat_key(workspace), session_id=session_id)
    print(json.dumps(_session_payload(session), ensure_ascii=False))
    return 0


def session_status(workspace: Path) -> int:
    session = _session(workspace)
    payload = _session_payload(session)
    payload["text"] = config_status_text(
        build_config(),
        get_last_usage(session),
        session_id=session.session_id,
        workspace=payload["workspace"],
    )
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def slash_commands() -> int:
    commands = SlashCommandStore(excluded_commands=BUILTIN_SLASH_COMMANDS).commands()
    payload = [
        {
            "command": command,
            "preview": prompt.preview,
            "template": prompt.template,
        }
        for command, prompt in sorted(commands.items())
    ]
    print(json.dumps({"commands": payload}, ensure_ascii=False))
    return 0


def _emit(is_new: bool, classes: str, text: str) -> None:
    print(
        json.dumps(
            {"is_new": is_new, "classes": classes, "text": text},
            ensure_ascii=False,
        ),
        flush=True,
    )


async def _stream_answer(session: Session) -> None:
    async for event in get_answer_streaming(session):
        is_new, classes, text = get_event_text(event)
        # Some stream events only update state and have no visible text.
        # Newline-only answer chunks are visible and keep Markdown fences intact.
        if text == "":
            continue
        if classes == "tool" and text.startswith("Remaining limit"):
            classes = "rate-limit"
        _emit(is_new, classes, text)

    _emit(True, "done", "Assistant response saved.")


async def append_review(workspace: Path, items: list[dict[str, Any]]) -> int:
    comments = _normalize_comments(items)
    # The UI can submit with a stale empty queue after comments were cleared.
    if not comments:
        _emit(True, "done", "No review comments to submit.")
        return 0

    session = _session(workspace)
    await append_user_turn(session, question=reviews_prompt(comments))
    _emit(
        True,
        "status",
        f"Submitted {len(comments)} review comment(s). Waiting for assistant...",
    )
    await _stream_answer(session)
    return 0


async def append_message(workspace: Path, text: str) -> int:
    text = text.strip()
    # FaltooBot requires a non-empty user turn.
    if not text:
        _emit(True, "done", "No message to submit.")
        return 0

    session = _session(workspace)
    await append_user_turn(session, question=text)
    _emit(True, "status", "Submitted message. Waiting for assistant...")
    await _stream_answer(session)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="faltoo_bridge")
    sub = parser.add_subparsers(dest="command", required=True)

    messages_parser = sub.add_parser("messages")
    messages_parser.add_argument("--workspace", default=str(Path.cwd()))
    messages_parser.add_argument("--limit", type=int, default=100)
    messages_parser.add_argument("--turns", type=int)

    messages_path_parser = sub.add_parser("messages-path")
    messages_path_parser.add_argument("--workspace", default=str(Path.cwd()))

    unstaged_parser = sub.add_parser("unstaged-files")
    unstaged_parser.add_argument("--workspace", default=str(Path.cwd()))

    session_info_parser = sub.add_parser("session-info")
    session_info_parser.add_argument("--workspace", default=str(Path.cwd()))

    reset_session_parser = sub.add_parser("reset-session")
    reset_session_parser.add_argument("--workspace", default=str(Path.cwd()))

    name_session_parser = sub.add_parser("name-session")
    name_session_parser.add_argument("--workspace", default=str(Path.cwd()))

    list_sessions_parser = sub.add_parser("list-sessions")
    list_sessions_parser.add_argument("--workspace", default=str(Path.cwd()))

    resume_session_parser = sub.add_parser("resume-session")
    resume_session_parser.add_argument("--workspace", default=str(Path.cwd()))

    status_parser = sub.add_parser("status")
    status_parser.add_argument("--workspace", default=str(Path.cwd()))

    sub.add_parser("append-review")
    sub.add_parser("append-message")
    sub.add_parser("slash-commands")

    args = parser.parse_args()
    if args.command == "messages":
        return messages(Path(args.workspace), args.limit, args.turns)
    if args.command == "messages-path":
        return messages_path(Path(args.workspace))
    if args.command == "unstaged-files":
        return unstaged_files(Path(args.workspace))
    if args.command == "session-info":
        return session_info(Path(args.workspace))
    if args.command == "reset-session":
        return reset_session(Path(args.workspace))
    if args.command == "name-session":
        payload = _stdin_payload()
        return name_session(Path(args.workspace), str(payload.get("name") or ""))
    if args.command == "list-sessions":
        return sessions_list(Path(args.workspace))
    if args.command == "resume-session":
        payload = _stdin_payload()
        return resume_session(Path(args.workspace), str(payload.get("session_id") or ""))
    if args.command == "status":
        return session_status(Path(args.workspace))
    if args.command == "append-review":
        payload = _stdin_payload()
        workspace = Path(str(payload.get("workspace") or Path.cwd()))
        return asyncio.run(append_review(workspace, _payload_comments(payload)))
    if args.command == "append-message":
        payload = _stdin_payload()
        workspace = Path(str(payload.get("workspace") or Path.cwd()))
        return asyncio.run(append_message(workspace, str(payload.get("text") or "")))
    if args.command == "slash-commands":
        return slash_commands()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
