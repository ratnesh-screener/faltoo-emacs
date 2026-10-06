#!/usr/bin/env python3
"""Claude Code core: the shared bridge CLI over `claude -p` stream-json."""
from __future__ import annotations

import argparse
import asyncio
from collections.abc import Callable
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sys
import traceback
from typing import Any
from uuid import uuid4

from bridge_common import _emit_payload, _last_user_turns, _stdin_payload, _tree_one_line, _workspace, run_cli

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


def _compaction_text(trigger: str | None, pre: int, post: int) -> str:
    label = "Context compacted automatically" if trigger == "auto" else "Conversation compacted"
    return f"{label}: {pre:,} → {post:,} tokens"


class ClaudeTurns:
    """Translate Claude's stream of turns into Faltoo events.

    Every turn gets its own id and ends at Claude's result. Emacs sends one
    prompt at a time and shows it when Claude echoes it. A turn that starts
    without a prompt echo was started by Claude itself, e.g. after a background
    task finished, and is headed by that task's notification.
    """

    def __init__(self, workspace: Path, context_warnings: list[int] | tuple[int, ...] = ()) -> None:
        self.workspace = workspace
        # Context sizes to warn at once each; a compaction resets them.
        self.context_warnings = sorted(context_warnings)
        self.warned: set[int] = set()
        self.context = 0
        # The /compact text sent; Claude neither echoes it nor answers in text.
        self.compacting: str | None = None
        self.turn: str | None = None
        self.turns = 0
        self.prompted = False
        # A steer written mid-turn; Claude echoes it where it takes it.
        self.steer: str | None = None
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
        self.compacting = None

    def _open_turn(self) -> None:
        if self.compacting:
            # Stands in for the echo Claude does not send for /compact.
            _emit_payload({"type": "prompt", "text": self.compacting})
        elif not self.prompted:
            _emit_payload({"type": "notification", "text": _background_text(self.notice)})
        self.prompted = False
        self.notice = BACKGROUND_NOTICE
        self.turns += 1
        self.turn = f"turn-{self.turns}"
        self.last_class = None
        _emit_payload({"type": "turn", "id": self.turn})

    def handle(self, message: dict[str, Any]) -> None:
        kind = message.get("type")
        subtype = message.get("subtype")
        if kind == "system" and subtype == "background_tasks_changed":
            self.background_tasks = len(message.get("tasks") or [])
            _emit_payload({"type": "background-tasks", "count": self.background_tasks})
        elif kind == "system" and subtype == "task_notification":
            self.notice = message.get("summary") or BACKGROUND_NOTICE
        elif kind == "system" and subtype == "compact_boundary":
            meta = message["compact_metadata"]
            if self.turn is None:
                self._open_turn()
            self._emit("status", _compaction_text(meta.get("trigger"), meta["pre_tokens"], meta["post_tokens"]))
            self.warned.clear()
            self.context = meta["post_tokens"]
            return
        elif kind == "user" and message.get("isReplay") and self.compacting:
            # Only /compact's own "Compacted" stdout is echoed while compacting.
            return
        elif kind == "user" and message.get("isReplay"):
            text = _content_text(message["message"]["content"]).strip()
            if text.startswith("<task-notification>"):
                # Claude folded a finished task into the running turn.
                summary = re.search(r"<summary>(.*?)</summary>", text, re.S)
                self.notice = summary.group(1) if summary else BACKGROUND_NOTICE
                if self.turn is not None:
                    self._emit("status", self.notice)
            elif self.turn is not None and text == self.steer:
                # Claude took the steer mid-turn: a line in the running answer.
                self.steer = None
                self._emit("status", f"Steer: {text}")
            else:
                if text == self.steer:
                    # Claude finished before taking the steer; it is the next prompt.
                    self.steer = None
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
            # A failed /compact ends with a result and nothing else.
            if kind not in {"stream_event", "assistant"} and not (kind == "result" and self.compacting):
                return
            self._open_turn()

        if kind == "stream_event":
            event = message["event"]
            if event.get("type") == "content_block_start" and event["content_block"].get("type") == "text":
                if self.last_class == "answer":
                    self._emit("answer", "\n\n")
            elif event.get("type") == "content_block_delta" and event["delta"].get("type") == "text_delta":
                self._emit("answer", event["delta"]["text"])
        elif kind == "assistant":
            usage = message["message"].get("usage")
            if usage:
                self.context = sum(
                    usage.get(key, 0)
                    for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
                )
            for block in message["message"]["content"]:
                if block.get("type") == "tool_use":
                    self._emit("tool", _tool_summary(block, self.workspace))
        elif kind == "rate_limit_event":
            text = _rate_limit_text(message.get("rate_limit_info") or {})
            if text:
                self._emit("rate-limit", text)
        else:
            crossed = [level for level in self.context_warnings if self.context >= level and level not in self.warned]
            if crossed:
                self.warned.update(crossed)
                self._emit("status", f"Context is {round(self.context / 1000)}k tokens; consider /compact")
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

    def __init__(
        self, workspace: Path, claude: str, idle_seconds: float, context_warnings: list[int] | tuple[int, ...] = ()
    ) -> None:
        self.workspace = workspace
        self.claude = claude
        self.idle_seconds = idle_seconds
        self.turns = ClaudeTurns(workspace, context_warnings)
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
            _emit_payload({"type": "submitted"})
        elif command == "compact":
            self.turns.compacting = f"/compact {str(payload['text']).strip()}".strip()
            if not self.child:
                await self._start_child()
            self._write({"type": "user", "message": {"role": "user", "content": self.turns.compacting}})
            _emit_payload({"type": "submitted"})
        elif command == "steer":
            # Written now, not queued: Claude takes it at its next step.
            self.turns.steer = str(payload["text"])
            self._write({"type": "user", "message": {"role": "user", "content": self.turns.steer}})
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


async def daemon(workspace: Path, claude: str, idle_seconds: float, context_warnings: list[int]) -> int:
    loop = asyncio.get_running_loop()
    stdin = asyncio.StreamReader(limit=LINE_LIMIT)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(stdin), sys.stdin)
    bridge = ClaudeDaemon(_workspace(workspace), claude, idle_seconds, context_warnings)
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


async def btw(workspace: Path, claude: str, question: str) -> int:
    """Answer QUESTION in a fork of the workspace session that is never saved.
    The fork re-reads the session from Claude's prompt cache, so it stays cheap."""
    workspace = _workspace(workspace)
    child = await asyncio.create_subprocess_exec(
        claude,
        "-p",
        "--resume", _session_id(workspace),
        "--fork-session",
        "--no-session-persistence",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--permission-mode", "bypassPermissions",
        question,
        cwd=workspace,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        limit=LINE_LIMIT,
    )
    turns = ClaudeTurns(workspace)
    # The question is the turn's prompt, so no Background Update heading.
    turns.prompted = True
    while line := await child.stdout.readline():
        turns.handle(json.loads(line))
    return await child.wait()


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    return "\n".join(block["text"] for block in content if block.get("type") == "text")


def _history(path: Path, workspace: Path, sidechain: bool = False) -> list[dict[str, str]]:
    """Render a Claude session file the way the live stream renders it.
    SIDECHAIN selects a sub-agent's records instead of the main conversation's."""
    messages: list[dict[str, str]] = []
    if not path.exists():
        return messages
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            item = json.loads(line)
            attachment = item.get("attachment") or {}
            if item.get("subtype") == "compact_boundary":
                meta = item.get("compactMetadata") or {}
                messages.append({"role": "tool", "class": "tool", "text": _compaction_text(
                    meta.get("trigger"), meta.get("preTokens", 0), meta.get("postTokens", 0))})
                continue
            if attachment.get("commandMode") == "prompt":
                # A steer Claude took mid-turn, shown inline live.
                messages.append({"role": "tool", "class": "tool", "text": f"Steer: {attachment['prompt']}"})
                continue
            if attachment.get("commandMode") == "task-notification":
                # A notification Claude folded into a running turn, shown inline live.
                summary = re.search(r"<summary>(.*?)</summary>", attachment["prompt"], re.S)
                messages.append({"role": "tool", "class": "tool", "text": summary.group(1) if summary else BACKGROUND_NOTICE})
                continue
            if (
                item.get("type") not in {"user", "assistant"}
                or bool(item.get("isSidechain")) != sidechain
                or item.get("isMeta")
                # The compaction line stands in for its long summary.
                or item.get("isCompactSummary")
            ):
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


def _tree_row(item: dict[str, Any], workspace: Path) -> dict[str, Any] | None:
    """Return a record's inspector row in FaltooBot's row shape, or None for bookkeeping."""
    attachment = item.get("attachment") or {}
    if item.get("subtype") == "compact_boundary":
        meta = item.get("compactMetadata") or {}
        return {"role": "assistant", "message_type": "compaction", "kind": "compaction",
                "preview": _compaction_text(meta.get("trigger"), meta.get("preTokens", 0), meta.get("postTokens", 0))}
    if item.get("isCompactSummary"):
        return {"role": "user", "message_type": "message", "kind": "summary",
                "preview": _tree_one_line(_content_text(item["message"]["content"]))}
    if attachment.get("commandMode") == "prompt":
        return {"role": "user", "message_type": "message", "kind": "steer",
                "preview": _tree_one_line(attachment["prompt"])}
    if item.get("type") not in {"user", "assistant"} or item.get("isSidechain") or item.get("isMeta"):
        return None
    content = item["message"]["content"]
    first = next(iter(content), {}) if isinstance(content, list) else {}
    if item["type"] == "user":
        if (item.get("origin") or {}).get("kind") == "task-notification":
            summary = re.search(r"<summary>(.*?)</summary>", _content_text(content), re.S)
            return {"role": "user", "message_type": "message", "kind": "background",
                    "preview": _tree_one_line(summary.group(1) if summary else BACKGROUND_NOTICE)}
        if first.get("type") == "tool_result":
            output = first.get("content") or ""
            text = output if isinstance(output, str) else _content_text(output)
            return {"role": "tool", "message_type": "function_call_output", "kind": "tool output",
                    "preview": "output: " + _tree_one_line(text)}
        return {"role": "user", "message_type": "message", "kind": "message",
                "preview": _tree_one_line(_content_text(content))}
    if first.get("type") == "thinking":
        return {"role": "assistant", "message_type": "reasoning", "kind": "reasoning",
                "preview": ("[reasoning] " + _tree_one_line(first.get("thinking") or "")).strip()}
    if first.get("type") == "tool_use":
        return {"role": "assistant", "message_type": "function_call", "kind": "tool call",
                "preview": _tool_summary(first, workspace)}
    return {"role": "assistant", "message_type": "message", "kind": "answer",
            "preview": _tree_one_line(first.get("text") or "")}


def tree_rows(workspace: Path) -> int:
    """Stream one compact row per Claude record, indexed by its line in the session file."""
    workspace = _workspace(workspace)
    path = _session_path(workspace, _session_id(workspace))
    _emit_payload({"type": "start", "path": str(path)})
    rows: list[dict[str, Any]] = []
    counted: set[str] = set()
    count = 0
    if path.exists():
        with path.open(encoding="utf-8") as handle:
            for count, line in enumerate(handle, 1):
                item = json.loads(line)
                row = _tree_row(item, workspace)
                if row is None:
                    continue
                message = item.get("message") or {}
                usage = message.get("usage")
                # A response split over several records repeats its usage; count it once.
                if usage and message.get("id") not in counted:
                    counted.add(message.get("id"))
                    cached = usage.get("cache_read_input_tokens", 0)
                    prompt = usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0) + cached
                    output = usage.get("output_tokens", 0)
                    row.update(input_tokens=prompt, output_tokens=output, cached_tokens=cached,
                               total_tokens=prompt + output)
                row["index"] = count - 1
                row["preview"] = row["preview"][:200]
                rows.append(row)
    for start in range(0, len(rows), 100):
        _emit_payload({"type": "rows", "rows": rows[start:start + 100]})
    _emit_payload({"type": "done", "count": count})
    return 0


def _subagent_dir(workspace: Path) -> Path:
    return _session_path(workspace, _session_id(workspace)).with_suffix("") / "subagents"


def subagents(workspace: Path) -> int:
    workspace = _workspace(workspace)
    transcripts = [
        meta.with_name(meta.name.removesuffix(".meta.json") + ".jsonl")
        for meta in _subagent_dir(workspace).glob("agent-*.meta.json")
    ]
    agents = []
    for path in sorted((path for path in transcripts if path.exists()), key=lambda path: path.stat().st_mtime, reverse=True):
        meta = json.loads(path.with_suffix(".meta.json").read_text(encoding="utf-8"))
        model = ""
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                # Replies record the model that answered, confirming any model the parent asked for.
                if '"assistant"' in line:
                    model = json.loads(line).get("message", {}).get("model", model)
        agents.append(
            {
                "id": path.stem.removeprefix("agent-"),
                "description": meta.get("description") or path.stem,
                "agent_type": meta.get("agentType", ""),
                "model": model,
                "modified": datetime.fromtimestamp(path.stat().st_mtime).strftime("%-d %b %H:%M"),
            }
        )
    print(json.dumps({"agents": agents}, ensure_ascii=False))
    return 0


def subagent_messages(workspace: Path, agent_id: str) -> int:
    workspace = _workspace(workspace)
    history = _history(_subagent_dir(workspace) / f"agent-{agent_id}.jsonl", workspace, sidechain=True)
    print(json.dumps({"messages": history}, ensure_ascii=False))
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
    # FaltooBot's prompts need FaltooBot; import it only here.
    from faltoo_bridge import _slash_command_payload

    commands = [{**command, "source": "faltoobot"} for command in _slash_command_payload()]
    commands += [_claude_command(path) for path in sorted((CLAUDE_HOME / "commands").glob("*.md"))]
    print(json.dumps({"commands": commands}, ensure_ascii=False))
    return 0


COMMANDS: dict[str, Callable[[argparse.Namespace], int]] = {
    "messages": lambda args: messages(args.workspace, args.limit, args.turns),
    "messages-path": lambda args: messages_path(args.workspace),
    "unstaged-files": lambda args: unstaged_files(args.workspace),
    "reset-session": lambda args: reset_session(args.workspace),
    "name-session": lambda args: name_session(args.workspace, str(_stdin_payload().get("name") or "")),
    "list-sessions": lambda args: sessions_list(args.workspace),
    "resume-session": lambda args: resume_session(
        args.workspace, str(_stdin_payload().get("session_id") or "")
    ),
    "status": lambda args: session_status(args.workspace),
    "tree-rows": lambda args: tree_rows(args.workspace),
    "subagents": lambda args: subagents(args.workspace),
    "subagent-messages": lambda args: subagent_messages(args.workspace, str(_stdin_payload()["agent_id"])),
    # Claude always runs as a persistent daemon so background tasks survive turns.
    "websocket-enabled": lambda _args: _emit_payload({"enabled": True}) or 0,
    "daemon": lambda args: asyncio.run(
        daemon(args.workspace, args.claude, args.idle_seconds,
               [int(level) for level in args.context_warnings.split(",") if level])
    ),
    "btw": lambda args: asyncio.run(btw(args.workspace, args.claude, str(_stdin_payload()["question"]))),
    "slash-commands": lambda _args: slash_commands(),
}


def unstaged_files(workspace: Path) -> int:
    # Review's Git helper comes from FaltooBot; import it only here.
    from faltoo_bridge import unstaged_files as faltoobot_unstaged_files

    return faltoobot_unstaged_files(workspace)


def main() -> int:
    return run_cli(
        "claude_bridge",
        COMMANDS,
        options={
            "--claude": {"default": "claude"},
            "--idle-seconds": {"type": float, "default": 1800},
            "--context-warnings": {"default": ""},
        },
    )


if __name__ == "__main__":
    raise SystemExit(main())
