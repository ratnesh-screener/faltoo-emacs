#!/usr/bin/env python3
"""Claude Code core: faltoo_bridge's CLI and JSONL contract over `claude -p`."""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sys
import traceback
from typing import Any
from uuid import uuid4

from faltoo_bridge import _emit_payload, _last_user_turns, _slash_command_payload, _stdin_payload, unstaged_files

CLAUDE_HOME = Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser()
STATE_PATH = (
    Path(os.environ.get("XDG_STATE_HOME", "~/.local/state")).expanduser()
    / "faltoo"
    / "claude-sessions.json"
)
# Claude Code writes whole tool results as single JSON lines.
LINE_LIMIT = 64 * 1024 * 1024
TOOL_DETAIL_KEYS = ("description", "command", "file_path", "pattern", "path", "url", "query", "prompt", "skill")
RATE_LIMIT_WINDOWS = {"five_hour": "5h", "seven_day": "7d"}
# FaltooBot's prompt preview length.
PREVIEW_LIMIT = 48
BACKGROUND_NOTICE = "Claude continued in the background."


def _workspace(workspace: Path) -> Path:
    return workspace.expanduser().resolve()


def _project_dir(workspace: Path) -> Path:
    # Claude Code names project folders after the cwd with non-alphanumerics dashed.
    return CLAUDE_HOME / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(workspace))


def _session_path(workspace: Path, session_id: str) -> Path:
    return _project_dir(workspace) / f"{session_id}.jsonl"


def _load_state() -> dict[str, str]:
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}


def _set_session_id(workspace: Path, session_id: str) -> None:
    state = _load_state()
    state[str(workspace)] = session_id
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")


def _session_id(workspace: Path) -> str:
    """Return the workspace's session, continuing Claude's latest when Faltoo chose none."""
    session_id = _load_state().get(str(workspace))
    if session_id is None:
        sessions = sorted(_project_dir(workspace).glob("*.jsonl"), key=lambda path: path.stat().st_mtime)
        session_id = sessions[-1].stem if sessions else str(uuid4())
        _set_session_id(workspace, session_id)
    return session_id


def _tool_summary(block: dict[str, Any], workspace: Path) -> str:
    tool_input = block.get("input") or {}
    key, detail = next(
        ((key, tool_input[key]) for key in TOOL_DETAIL_KEYS if isinstance(tool_input.get(key), str)),
        (None, ""),
    )
    if key in {"file_path", "path"} and Path(detail).is_relative_to(workspace):
        detail = str(Path(detail).relative_to(workspace))
    detail = " ".join(detail.split())[:200]
    return f"{block['name']}: {detail}" if detail else block["name"]


def _rate_limit_text(info: dict[str, Any]) -> str | None:
    windows = info.get("unifiedWindows") or {}
    parts = [
        f"{RATE_LIMIT_WINDOWS.get(name, name)} = {round(100 - 100 * window['utilization'])}%"
        for name, window in windows.items()
    ]
    return "Remaining limit: " + ", ".join(parts) if parts else None


def _background_text(summary: str) -> str:
    # FaltooBot's notification format, which the transcript renders as a Background Update.
    return f"# Background update\n\nsource: Claude Code\n\n## message\n{summary}"


class ClaudeTurns:
    """Translate Claude's stream of turns into Faltoo events.

    Every turn gets its own id and ends at Claude's result. Emacs sends one
    prompt at a time and shows it when Claude echoes it. A turn that starts
    without a prompt echo was started by Claude itself, e.g. after a background
    task finished, and is headed by that task's notification.
    """

    def __init__(self, workspace: Path) -> None:
        self.workspace = workspace
        self.turn: str | None = None
        self.turns = 0
        self.prompted = False
        self.interrupting = False
        self.background_tasks = 0
        self.notice = BACKGROUND_NOTICE
        self.last_class: str | None = None

    def idle(self) -> bool:
        return self.turn is None and self.background_tasks == 0

    def _emit(self, classes: str, text: str) -> None:
        self.last_class = classes
        _emit_payload({"id": self.turn, "is_new": True, "classes": classes, "text": text})

    def _complete(self, ok: bool) -> None:
        _emit_payload({"id": self.turn, "type": "complete", "ok": ok})
        self.turn = None
        self.interrupting = False

    def handle(self, message: dict[str, Any]) -> None:
        kind = message.get("type")
        subtype = message.get("subtype")
        if kind == "system" and subtype == "background_tasks_changed":
            self.background_tasks = len(message.get("tasks") or [])
            _emit_payload({"type": "background-tasks", "count": self.background_tasks})
        elif kind == "system" and subtype == "task_notification":
            self.notice = message.get("summary") or BACKGROUND_NOTICE
        elif kind == "user" and message.get("isReplay"):
            text = _content_text(message["message"]["content"]).strip()
            if text.startswith("<task-notification>"):
                # Claude folded a finished task into the running turn.
                summary = re.search(r"<summary>(.*?)</summary>", text, re.S)
                self.notice = summary.group(1) if summary else BACKGROUND_NOTICE
                if self.turn is not None:
                    self._emit("status", self.notice)
            else:
                if self.turn is not None:
                    # Claude took the prompt mid-turn; the prompt starts the next turn.
                    self._complete(True)
                self.prompted = True
                _emit_payload({"type": "prompt", "text": text})
            return
        if message.get("parent_tool_use_id") or kind not in {
            "stream_event",
            "assistant",
            "rate_limit_event",
            "result",
        }:
            return
        if self.turn is None:
            if kind not in {"stream_event", "assistant"}:
                return
            if not self.prompted:
                _emit_payload({"type": "notification", "text": _background_text(self.notice)})
            self.prompted = False
            self.notice = BACKGROUND_NOTICE
            self.turns += 1
            self.turn = f"turn-{self.turns}"
            self.last_class = None
            _emit_payload({"type": "turn", "id": self.turn})

        if kind == "stream_event":
            event = message["event"]
            if event.get("type") == "content_block_start" and event["content_block"].get("type") == "text":
                if self.last_class == "answer":
                    self._emit("answer", "\n\n")
            elif event.get("type") == "content_block_delta" and event["delta"].get("type") == "text_delta":
                self._emit("answer", event["delta"]["text"])
        elif kind == "assistant":
            for block in message["message"]["content"]:
                if block.get("type") == "tool_use":
                    self._emit("tool", _tool_summary(block, self.workspace))
        elif kind == "rate_limit_event":
            text = _rate_limit_text(message.get("rate_limit_info") or {})
            if text:
                self._emit("rate-limit", text)
        else:
            ok = not message.get("is_error")
            if ok:
                self._emit("done", "Assistant response saved.")
            elif self.interrupting:
                self._emit("status", "Cancelled.")
            else:
                errors = "\n".join(message.get("errors") or [])
                self._emit("error", message.get("result") or errors or str(subtype))
            self._complete(ok)


class ClaudeDaemon:
    """One long-lived `claude` child per workspace; background tasks live inside it."""

    def __init__(self, workspace: Path, claude: str, idle_seconds: float) -> None:
        self.workspace = workspace
        self.claude = claude
        self.idle_seconds = idle_seconds
        self.turns = ClaudeTurns(workspace)
        self.child: asyncio.subprocess.Process | None = None
        self.idle_timer: asyncio.TimerHandle | None = None
        self.main = asyncio.current_task()

    def schedule_idle_stop(self) -> None:
        if self.idle_timer:
            self.idle_timer.cancel()
            self.idle_timer = None
        if self.turns.idle():
            self.idle_timer = asyncio.get_running_loop().call_later(self.idle_seconds, self.main.cancel)

    async def _start_child(self) -> None:
        # Emacs restarts the daemon when the workspace switches sessions.
        session_id = _session_id(self.workspace)
        exists = _session_path(self.workspace, session_id).exists()
        self.child = child = await asyncio.create_subprocess_exec(
            self.claude,
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages",
            "--permission-mode", "bypassPermissions",
            "--resume" if exists else "--session-id", session_id,
            cwd=self.workspace,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=LINE_LIMIT,
        )
        asyncio.create_task(self._read(child, asyncio.create_task(child.stderr.read())))

    async def _read(self, child: asyncio.subprocess.Process, stderr: asyncio.Task[bytes]) -> None:
        try:
            while line := await child.stdout.readline():
                self.turns.handle(json.loads(line))
                self.schedule_idle_stop()
        except Exception:
            # A dead reader would leave Emacs answering forever; exiting lets
            # its sentinel fail the open turn and prompt with this traceback.
            traceback.print_exc()
            os._exit(1)
        error = (await stderr).decode(errors="replace").strip()
        await child.wait()
        # Shutdown clears self.child first; anything else crashed. Exiting hands
        # the failure to Emacs's sentinel, and the next prompt starts afresh.
        if child is self.child:
            print(error or f"Claude exited with code {child.returncode}", file=sys.stderr, flush=True)
            os._exit(1)

    async def stop_child(self) -> None:
        child, self.child = self.child, None
        if child and child.returncode is None:
            child.terminate()
            await child.wait()

    def _write(self, payload: dict[str, Any]) -> None:
        self.child.stdin.write((json.dumps(payload, ensure_ascii=False) + "\n").encode())

    async def request(self, request: dict[str, Any]) -> bool:
        """Handle one Emacs request; return True when the daemon should exit."""
        request_id = str(request.get("id") or "")
        command = str(request.get("command") or "")
        payload = request.get("payload") if isinstance(request.get("payload"), dict) else {}

        def emit(classes: str, text: str) -> None:
            _emit_payload({"id": request_id, "is_new": True, "classes": classes, "text": text})

        if command == "append-message":
            # Emacs shows the prompt when Claude echoes it at its turn's start.
            if not self.child:
                await self._start_child()
            self._write({"type": "user", "message": {"role": "user", "content": str(payload["text"])}})
        elif command == "interrupt":
            if self.child:
                self.turns.interrupting = True
                self._write(
                    {"type": "control_request", "request_id": str(uuid4()), "request": {"subtype": "interrupt"}}
                )
        elif command == "ping":
            emit("status", "pong")
            _emit_payload({"id": request_id, "type": "complete", "ok": True})
        elif command == "shutdown":
            _emit_payload({"id": request_id, "type": "complete", "ok": True})
            return True
        else:
            emit("error", f"Unknown daemon command: {command}")
            _emit_payload({"id": request_id, "type": "complete", "ok": False})
        self.schedule_idle_stop()
        return False


async def daemon(workspace: Path, claude: str, idle_seconds: float) -> int:
    loop = asyncio.get_running_loop()
    stdin = asyncio.StreamReader(limit=LINE_LIMIT)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(stdin), sys.stdin)
    bridge = ClaudeDaemon(_workspace(workspace), claude, idle_seconds)
    bridge.schedule_idle_stop()
    try:
        while line := await stdin.readline():
            if line.strip() and await bridge.request(json.loads(line)):
                break
    except asyncio.CancelledError:
        pass  # Idle expiry.
    finally:
        await bridge.stop_child()
    return 0


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(block["text"] for block in content if block.get("type") == "text")


def _history(path: Path, workspace: Path) -> list[dict[str, str]]:
    """Render a Claude session file the way the live stream renders it."""
    messages: list[dict[str, str]] = []
    if not path.exists():
        return messages
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            item = json.loads(line)
            attachment = item.get("attachment") or {}
            if attachment.get("commandMode") == "task-notification":
                # A notification Claude folded into a running turn, shown inline live.
                summary = re.search(r"<summary>(.*?)</summary>", attachment["prompt"], re.S)
                messages.append({"role": "tool", "class": "tool", "text": summary.group(1) if summary else BACKGROUND_NOTICE})
                continue
            if item.get("type") not in {"user", "assistant"} or item.get("isSidechain") or item.get("isMeta"):
                continue
            content = item["message"]["content"]
            if item["type"] == "user":
                text = _content_text(content).strip()
                if (item.get("origin") or {}).get("kind") == "task-notification":
                    summary = re.search(r"<summary>(.*?)</summary>", text, re.S)
                    text = _background_text(summary.group(1) if summary else BACKGROUND_NOTICE)
                elif not text or text.startswith("[Request interrupted"):
                    continue
                messages.append({"role": "user", "class": "user", "text": text})
                continue
            for block in content:
                if block.get("type") == "text" and block["text"].strip():
                    messages.append({"role": "assistant", "class": "answer", "text": block["text"].strip()})
                elif block.get("type") == "tool_use":
                    messages.append({"role": "tool", "class": "tool", "text": _tool_summary(block, workspace)})
    return messages


def messages(workspace: Path, limit: int, turns: int | None) -> int:
    workspace = _workspace(workspace)
    history = _history(_session_path(workspace, _session_id(workspace)), workspace)[-limit:]
    print(json.dumps({"messages": _last_user_turns(history, turns)}, ensure_ascii=False))
    return 0


def messages_path(workspace: Path) -> int:
    workspace = _workspace(workspace)
    print(_session_path(workspace, _session_id(workspace)))
    return 0


def _session_payload(workspace: Path, session_id: str) -> dict[str, str]:
    return {
        "session_id": session_id,
        "chat_key": str(workspace),
        "workspace": str(workspace),
        "messages_path": str(_session_path(workspace, session_id)),
    }


def _session_title(path: Path) -> str | None:
    """Return a session's resume title, or None when it has no messages yet."""
    custom = ai = prompt = None
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            # Parse only the few records a label needs; tool results make files large.
            if '-title"' in line:
                item = json.loads(line)
                custom = item.get("customTitle", custom)
                ai = item.get("aiTitle", ai)
            elif prompt is None and '"user"' in line:
                item = json.loads(line)
                if item.get("type") == "user" and not item.get("isMeta"):
                    prompt = _content_text(item["message"]["content"]).strip() or None
    if prompt is None:
        return None
    return " ".join((custom or ai or prompt).split())[:60]


def sessions_list(workspace: Path) -> int:
    workspace = _workspace(workspace)
    paths = sorted(_project_dir(workspace).glob("*.jsonl"), key=lambda path: path.stat().st_mtime, reverse=True)
    sessions = [
        {
            "id": path.stem,
            "name": title,
            "modified": datetime.fromtimestamp(path.stat().st_mtime).strftime("%-d %b %H:%M"),
        }
        for path in paths
        if (title := _session_title(path)) is not None
    ]
    print(json.dumps({"sessions": sessions}, ensure_ascii=False))
    return 0


def reset_session(workspace: Path) -> int:
    return resume_session(workspace, str(uuid4()))


def resume_session(workspace: Path, session_id: str) -> int:
    workspace = _workspace(workspace)
    _set_session_id(workspace, session_id)
    print(json.dumps(_session_payload(workspace, session_id), ensure_ascii=False))
    return 0


def name_session(workspace: Path, name: str) -> int:
    workspace = _workspace(workspace)
    session_id = _session_id(workspace)
    path = _session_path(workspace, session_id)
    # Claude can neither resume nor reuse the id of a file without messages.
    if not path.exists():
        print("Send a message before naming this session.", file=sys.stderr)
        return 1
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "custom-title", "customTitle": name, "sessionId": session_id}) + "\n")
    print(json.dumps(_session_payload(workspace, session_id), ensure_ascii=False))
    return 0


def session_status(workspace: Path) -> int:
    workspace = _workspace(workspace)
    session_id = _session_id(workspace)
    path = _session_path(workspace, session_id)
    assistant = None
    if path.exists():
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                # Keep the raw line; only the last one needs parsing.
                if '"type":"assistant"' in line:
                    assistant = line
    lines = [
        "Session",
        f"• session_id={session_id}",
        f"• name={(path.exists() and _session_title(path)) or ''}",
        f"• workspace={workspace}",
        f"• messages_path={path}",
        "Session usage",
    ]
    if assistant:
        message = json.loads(assistant)["message"]
        usage = message["usage"]
        context = sum(usage.get(key, 0) for key in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
        lines += [
            f"• model={message['model']}",
            f"• context_tokens={context:,}",
            "• last_usage=" + json.dumps(usage),
        ]
    payload = _session_payload(workspace, session_id)
    payload["text"] = "\n".join(lines)
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def _claude_command(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    description = ""
    if text.startswith("---\n") and "\n---\n" in text[4:]:
        frontmatter, text = text[4:].split("\n---\n", 1)
        description = next(
            (line.split(":", 1)[1].strip() for line in frontmatter.splitlines() if line.startswith("description:")),
            "",
        )
    template = text.strip()
    preview = description or " ".join(template.split())
    return {"command": f"/{path.stem}", "preview": preview[:PREVIEW_LIMIT], "template": template, "source": "claude"}


def slash_commands() -> int:
    commands = [{**command, "source": "faltoobot"} for command in _slash_command_payload()]
    commands += [_claude_command(path) for path in sorted((CLAUDE_HOME / "commands").glob("*.md"))]
    print(json.dumps({"commands": commands}, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="claude_bridge")
    parser.add_argument("--claude", default="claude")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in (
        "messages",
        "messages-path",
        "unstaged-files",
        "websocket-enabled",
        "daemon",
        "list-sessions",
        "reset-session",
        "resume-session",
        "name-session",
        "status",
    ):
        sub.add_parser(name).add_argument("--workspace", default=str(Path.cwd()))
    sub.choices["messages"].add_argument("--limit", type=int, default=100)
    sub.choices["messages"].add_argument("--turns", type=int)
    sub.choices["daemon"].add_argument("--idle-seconds", type=float, default=1800)
    sub.add_parser("slash-commands")

    args = parser.parse_args()
    if args.command == "messages":
        return messages(Path(args.workspace), args.limit, args.turns)
    if args.command == "messages-path":
        return messages_path(Path(args.workspace))
    if args.command == "unstaged-files":
        return unstaged_files(Path(args.workspace))
    if args.command == "websocket-enabled":
        # Claude always runs as a persistent daemon so background tasks survive turns.
        _emit_payload({"enabled": True})
        return 0
    if args.command == "daemon":
        return asyncio.run(daemon(Path(args.workspace), args.claude, args.idle_seconds))
    if args.command == "slash-commands":
        return slash_commands()
    if args.command == "status":
        return session_status(Path(args.workspace))
    if args.command == "list-sessions":
        return sessions_list(Path(args.workspace))
    if args.command == "reset-session":
        return reset_session(Path(args.workspace))
    if args.command == "resume-session":
        payload = _stdin_payload()
        return resume_session(Path(args.workspace), str(payload.get("session_id") or ""))
    if args.command == "name-session":
        payload = _stdin_payload()
        return name_session(Path(args.workspace), str(payload.get("name") or ""))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
