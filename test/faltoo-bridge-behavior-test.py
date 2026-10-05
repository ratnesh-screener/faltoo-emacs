#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import contextlib
from contextlib import redirect_stdout
import sys
import types
import tempfile
import unittest


class Prompt:
    preview = "Write a commit"
    template = "Expanded commit prompt"


class SlashCommandStore:
    def __init__(self, excluded_commands=None):
        self.excluded_commands = excluded_commands or frozenset()

    def commands(self):
        return {"/commit": Prompt()}


class Session:
    def __init__(self, chat_key="chat", session_id="current", workspace=Path("/tmp/workspace")):
        self.chat_key = chat_key
        self.session_id = session_id
        self.workspace = workspace
        self.messages_path = workspace / session_id / "messages.json"


def install_faltoobot_stubs() -> None:
    """Given FaltooBot dependencies are represented by lightweight test doubles."""
    modules = {
        "faltoobot": types.ModuleType("faltoobot"),
        "faltoobot.faltoochat": types.ModuleType("faltoobot.faltoochat"),
        "faltoobot.notify_queue": types.ModuleType("faltoobot.notify_queue"),
        "faltoobot.faltoochat.git": types.ModuleType("faltoobot.faltoochat.git"),
        "faltoobot.faltoochat.review_api": types.ModuleType("faltoobot.faltoochat.review_api"),
        "faltoobot.faltoochat.slash_commands": types.ModuleType("faltoobot.faltoochat.slash_commands"),
        "faltoobot.faltoochat.messages_rendering": types.ModuleType("faltoobot.faltoochat.messages_rendering"),
        "faltoobot.faltoochat.stream": types.ModuleType("faltoobot.faltoochat.stream"),
        "faltoobot.config": types.ModuleType("faltoobot.config"),
        "faltoobot.sessions": types.ModuleType("faltoobot.sessions"),
    }

    modules["faltoobot"].notify_queue = modules["faltoobot.notify_queue"]
    modules["faltoobot.notify_queue"].claim_notifications = lambda _matches: []
    modules["faltoobot.notify_queue"].format_notification_message = lambda item: item["message"]
    modules["faltoobot.notify_queue"].ack_notification = lambda _path: None
    modules["faltoobot.notify_queue"].requeue_notification = lambda _path: None
    modules["faltoobot.notify_queue"].recover_processing_notifications = lambda: 0
    modules["faltoobot.faltoochat.git"].get_unstaged_files = lambda _workspace: []
    modules["faltoobot.faltoochat.git"].is_git_workspace = lambda _workspace: True
    modules["faltoobot.faltoochat.review_api"].Review = dict
    modules["faltoobot.faltoochat.review_api"].reviews_prompt = lambda comments: str(comments)
    modules["faltoobot.faltoochat.slash_commands"].SlashCommandStore = SlashCommandStore
    modules["faltoobot.faltoochat.messages_rendering"].get_item_text = lambda _item: None
    modules["faltoobot.faltoochat.stream"].get_event_text = lambda event: event
    modules["faltoobot.config"].build_config = lambda: {"config": "ok"}
    modules["faltoobot.config"].config_status_text = (
        lambda _config, last_usage, *, session_id=None, workspace=None:
        f"Faltoobot status\n\nSession\n• session_id={session_id}\n• workspace={workspace}\n\nSession usage\n• last_usage={last_usage}"
    )
    modules["faltoobot.sessions"].Session = Session
    modules["faltoobot.sessions"].get_dir_chat_key = lambda workspace: str(workspace)
    modules["faltoobot.sessions"].get_messages = lambda session: {
        "messages": [],
        "workspace": str(getattr(session, "workspace", Path("/tmp/workspace"))),
    }
    modules["faltoobot.sessions"].get_session = lambda key, session_id=None, workspace=None: Session(
        key, session_id or "current", workspace or Path("/tmp/workspace")
    )
    modules["faltoobot.sessions"].get_last_usage = lambda _session: {"input_tokens": 1}
    modules["faltoobot.sessions"].list_sessions = lambda _key: [
        {"id": "current", "name": "current - 1 Jan"},
        {"id": "older", "name": "older - 1 Jan"},
    ]
    modules["faltoobot.sessions"].set_session_name = lambda session, name: setattr(
        session, "session_id", name or "generated"
    )

    async def append_user_turn(_session, question):
        return None

    async def get_answer_streaming(_session):
        if False:
            yield None

    modules["faltoobot.sessions"].append_user_turn = append_user_turn
    modules["faltoobot.sessions"].get_answer_streaming = get_answer_streaming
    sys.modules.update(modules)


def load_bridge():
    install_faltoobot_stubs()
    path = Path(__file__).resolve().parents[1] / "python" / "faltoo_bridge.py"
    spec = importlib.util.spec_from_file_location("faltoo_bridge_under_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FaltooBridgeBehaviorTest(unittest.IsolatedAsyncioTestCase):

    def test_session_commands_use_workspace_chat_key(self):
        """Scenario: Session commands operate on the current workspace chat key."""
        bridge = load_bridge()
        renamed = []

        # Given the bridge is pointed at a Git workspace.
        bridge.set_session_name = lambda session, name: (renamed.append((session.chat_key, name)), setattr(session, "session_id", name))

        # When listing, naming, resetting, and resuming sessions.
        with redirect_stdout(io.StringIO()):
            sessions_result = bridge.sessions_list(Path("/tmp/project"))
            name_result = bridge.name_session(Path("/tmp/project"), "Focused")
            reset_result = bridge.reset_session(Path("/tmp/project"))
            resume_result = bridge.resume_session(Path("/tmp/project"), "older")
            status_result = bridge.session_status(Path("/tmp/project"))

        # Then each command stays under the workspace-derived chat key.
        self.assertEqual(sessions_result, 0)
        self.assertEqual(renamed, [("/private/tmp/project", "Focused")])
        self.assertEqual(name_result, 0)
        self.assertEqual(reset_result, 0)
        self.assertEqual(resume_result, 0)
        self.assertEqual(status_result, 0)



    def test_websocket_enabled_reports_faltoobot_config(self):
        """Scenario: The bridge reports whether FaltooBot websocket mode is configured."""
        bridge = load_bridge()

        # Given FaltooBot config has websocket enabled with auth.
        bridge.build_config = lambda: types.SimpleNamespace(
            openai_websocket=True,
            openai_api_key="key",
            openai_oauth=None,
        )

        # When Emacs asks whether websocket mode should use a persistent bridge.
        out = io.StringIO()
        with redirect_stdout(out):
            result = bridge.websocket_enabled(Path("/tmp/project"))

        # Then the bridge returns a small JSON capability response.
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(out.getvalue()), {"enabled": True})

    async def test_daemon_streams_append_message_events_with_request_id(self):
        """Scenario: The persistent daemon tags stream events with the request id."""
        bridge = load_bridge()
        captured_questions = []

        async def append_user_turn(_session, question):
            captured_questions.append(question)

        async def answer_stream(_session):
            yield types.SimpleNamespace(type="response.output_text.delta")

        bridge.append_user_turn = append_user_turn
        bridge.get_answer_streaming = answer_stream
        bridge.get_event_text = lambda _event: (False, "answer", "hello")

        # When the daemon handles an append-message request.
        out = io.StringIO()
        with redirect_stdout(out):
            result = await bridge.daemon_handle_request(
                Path("/tmp/project"),
                {"id": "req-1", "command": "append-message", "payload": {"text": "Hi"}},
            )

        # Then every emitted event belongs to that request and the daemon stays alive.
        events = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual(result, 0)
        self.assertEqual(captured_questions, ["Hi"])
        self.assertTrue(all(event["id"] == "req-1" for event in events))
        self.assertEqual(events[-1], {"id": "req-1", "type": "complete", "ok": True})
        self.assertEqual(events[1]["classes"], "answer")
        self.assertEqual(events[1]["text"], "hello")

    def test_tree_rows_streams_compact_rows_without_expanding_large_payloads(self):
        """Scenario: Tree rows stream as compact JSONL batches for large transcripts."""
        bridge = load_bridge()
        with tempfile.TemporaryDirectory() as tmpdir:
            workspace = Path(tmpdir)
            messages_dir = workspace / "current"
            messages_dir.mkdir()
            image = "data:image/png;base64," + "A" * 1000
            (messages_dir / "messages.json").write_text(
                json.dumps(
                    {
                        "messages": [
                            {"type": "message", "role": "user", "content": "hello"},
                            {
                                "type": "message",
                                "role": "user",
                                "content": [
                                    {"type": "input_text", "text": "see image"},
                                    {"type": "input_image", "image_url": image},
                                ],
                                "usage": {
                                    "input_tokens": 10,
                                    "output_tokens": 2,
                                    "total_tokens": 12,
                                    "input_tokens_details": {"cached_tokens": 8},
                                },
                            },
                        ]
                    }
                )
            )

            # When compact tree rows are streamed.
            out = io.StringIO()
            with redirect_stdout(out):
                result = bridge.tree_rows(workspace)

        # Then Emacs receives lightweight row events instead of raw image payloads.
        events = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual(result, 0)
        self.assertEqual(events[0]["type"], "start")
        self.assertEqual(events[-1], {"type": "done", "count": 2})
        self.assertEqual(events[1]["rows"][0]["preview"], "hello")
        self.assertIn("[image: input_image]", events[1]["rows"][1]["preview"])
        self.assertNotIn("base64", events[1]["rows"][1]["preview"])
        self.assertEqual(events[1]["rows"][1]["input_tokens"], 10)
        self.assertEqual(events[1]["rows"][1]["output_tokens"], 2)
        self.assertEqual(events[1]["rows"][1]["cached_tokens"], 8)
        self.assertEqual(events[1]["rows"][1]["total_tokens"], 12)

    async def test_manual_slash_command_is_submitted_as_plain_text(self):
        """Scenario: Manually typed slash commands are not expanded by the bridge."""
        bridge = load_bridge()
        captured_questions = []

        # Given a saved /commit prompt exists in FaltooBot.
        async def append_user_turn(_session, question):
            captured_questions.append(question)

        async def empty_answer_stream(_session):
            if False:
                yield None

        bridge.append_user_turn = append_user_turn
        bridge.get_answer_streaming = empty_answer_stream

        # When the user manually submits /commit instead of choosing C-c /.
        await bridge.append_message(Path("/tmp/faltoo-workspace"), " /commit ")

        # Then the bridge sends the literal prompt text.
        self.assertEqual(captured_questions, ["/commit"])

    async def test_answer_stream_delegates_stream_policy_to_faltoobot(self):
        """Scenario: The bridge consumes FaltooBot's configured answer stream."""
        bridge = load_bridge()
        calls = []

        async def answer_stream(session):
            calls.append(session)
            if False:
                yield None

        bridge.get_answer_streaming = answer_stream

        await bridge._stream_answer("session", lambda *_args: None)

        self.assertEqual(calls, ["session"])

    async def test_answer_stream_preserves_whitespace_only_chunks(self):
        """Scenario: Newline-only assistant chunks keep Markdown code fences intact."""
        bridge = load_bridge()
        emitted = []
        events = [
            types.SimpleNamespace(type="response.output_text.delta", name=name)
            for name in ("language", "newline", "body")
        ]

        # Given the model streams a newline as its own answer chunk.
        bridge.get_event_text = lambda event: {
            "language": (False, "answer", "```text"),
            "newline": (False, "answer", "\n"),
            "body": (False, "answer", "M faltoo.el"),
        }[event.name]
        bridge._emit = lambda _is_new, classes, text: emitted.append(
            {"classes": classes, "text": text}
        )

        async def answer_stream(_session):
            for event in events:
                yield event

        bridge.get_answer_streaming = answer_stream

        # When the bridge streams the answer.
        await bridge._stream_answer({})

        # Then the newline-only chunk is not discarded.
        self.assertEqual(
            [item for item in emitted if item["classes"] == "answer"],
            [
                {"classes": "answer", "text": "```text"},
                {"classes": "answer", "text": "\n"},
                {"classes": "answer", "text": "M faltoo.el"},
            ],
        )



    def test_messages_preserve_raw_skill_and_image_tools_for_emacs_rendering(self):
        """Scenario: Reloaded tools reach the shared Emacs formatter unchanged."""
        bridge = load_bridge()
        cases = (
            'load_skill\n{"skill_name": "browser-use"}',
            'load_image\n{"image_path": "workspace-inbox-first.png"}',
        )

        for tool_text in cases:
            with self.subTest(tool_text=tool_text):
                bridge.get_item_text = lambda _item, text=tool_text: (text, "tool")
                bridge.get_messages = lambda _session: {
                    "messages": [{"type": "function_call"}],
                    "workspace": "/tmp/project",
                }
                out = io.StringIO()

                with redirect_stdout(out):
                    result = bridge.messages(Path("/tmp/project"), 100, None)

                self.assertEqual(result, 0)
                payload = json.loads(out.getvalue())
                self.assertEqual(payload["messages"][0]["text"], tool_text)

    def test_messages_preserve_raw_tool_text_for_emacs_rendering(self):
        """Scenario: Reloaded tool text reaches the shared Emacs formatter unchanged."""
        bridge = load_bridge()

        # Given a persisted tool call uses FaltooBot's bold Markdown label.
        bridge.get_item_text = lambda _item: (
            "**Shell:** Collect final code references and status",
            "tool",
        )
        bridge.get_messages = lambda _session: {
            "messages": [{"type": "function_call"}],
            "workspace": "/tmp/project",
        }

        # When Emacs asks the bridge for transcript messages.
        out = io.StringIO()
        with redirect_stdout(out):
            result = bridge.messages(Path("/tmp/project"), 100, None)

        # Then Emacs receives the original text and applies the shared formatter.
        self.assertEqual(result, 0)
        payload = json.loads(out.getvalue())
        self.assertEqual(
            payload["messages"][0]["text"],
            "**Shell:** Collect final code references and status",
        )

    def test_messages_marks_persisted_hook_feedback_with_distinct_role(self):
        """Scenario: Persisted hook feedback can be styled after transcript refresh."""
        bridge = load_bridge()

        # Given messages.json contains a persisted post-response hook feedback item.
        bridge.get_item_text = lambda item: (item["content"], "answer")
        bridge.get_messages = lambda _session: {
            "messages": [
                {
                    "type": "message",
                    "role": "developer",
                    "content": 'This is the post-response hook feedback from "Refactor Code" agent.\n\nHook notes',
                }
            ],
            "workspace": "/tmp/project",
        }

        # When Emacs asks for transcript messages.
        out = io.StringIO()
        with redirect_stdout(out):
            result = bridge.messages(Path("/tmp/project"), 100, None)

        # Then the message carries a hook-feedback role, not a generic assistant role.
        self.assertEqual(result, 0)
        payload = json.loads(out.getvalue())
        self.assertEqual(payload["messages"][0]["role"], "hook-feedback")
        self.assertEqual(payload["messages"][0]["class"], "answer")
        self.assertIn("Refactor Code", payload["messages"][0]["text"])

    async def test_post_response_hook_feedback_gets_distinct_stream_class(self):
        """Scenario: Post-response hook feedback is not emitted as a generic tool block."""
        bridge = load_bridge()
        emitted = []

        # Given FaltooBot streams dedicated hook feedback events.
        event = types.SimpleNamespace(
            type="faltoobot.post_response_hook", status="feedback"
        )
        bridge.get_event_text = lambda _event: (True, "tool", "Hook feedback body")
        bridge._emit = lambda is_new, classes, text: emitted.append(
            {"is_new": is_new, "classes": classes, "text": text}
        )

        async def answer_stream(_session):
            yield event

        bridge.get_answer_streaming = answer_stream

        # When the bridge streams the event to Emacs.
        await bridge._stream_answer({})

        # Then Emacs can style it separately from normal tool calls.
        self.assertEqual(emitted[0]["classes"], "hook-feedback")
        self.assertEqual(emitted[0]["text"], "Hook feedback body")

    async def test_non_feedback_hook_event_remains_a_compact_tool_event(self):
        """Scenario: Hook lifecycle events keep normal compact tool rendering."""
        bridge = load_bridge()
        emitted = []
        event = types.SimpleNamespace(
            type="faltoobot.post_response_hook", status="running"
        )
        bridge.get_event_text = lambda _event: (
            True,
            "tool",
            "Running post-response hook: Refactor Code",
        )
        bridge._emit = lambda is_new, classes, text: emitted.append(
            {"is_new": is_new, "classes": classes, "text": text}
        )

        async def answer_stream(_session):
            yield event

        bridge.get_answer_streaming = answer_stream

        await bridge._stream_answer({})

        self.assertEqual(emitted[0]["classes"], "tool")

    async def test_codex_rate_limit_event_gets_distinct_stream_class(self):
        """Scenario: Codex remaining-limit events are distinguishable from tool calls."""
        bridge = load_bridge()
        emitted = []

        # Given FaltooChat renders Codex limits as tool text.
        bridge.get_event_text = lambda _event: (
            True,
            "tool",
            "Remaining limit: 5h = 98%",
        )
        bridge._emit = lambda is_new, classes, text: emitted.append(
            {"is_new": is_new, "classes": classes, "text": text}
        )

        async def answer_stream(_session):
            yield types.SimpleNamespace(type="codex.rate_limits")

        bridge.get_answer_streaming = answer_stream

        # When the bridge streams that event to Emacs.
        await bridge._stream_answer({})

        # Then Emacs receives a rate-limit event it can place in the footer.
        self.assertEqual(emitted[0]["classes"], "rate-limit")
        self.assertEqual(emitted[0]["text"], "Remaining limit: 5h = 98%")


    async def test_daemon_recovers_and_polls_notifications_while_open(self):
        """Scenario: A persistent workspace daemon owns notification polling."""
        bridge = load_bridge()
        poll_started = asyncio.Event()
        poll_cancelled = False
        recovered = []

        async def poll_notifications(workspace):
            nonlocal poll_cancelled
            self.assertEqual(workspace, Path("/tmp/project"))
            poll_started.set()
            try:
                await asyncio.Future()
            finally:
                poll_cancelled = True

        async def no_requests():
            await poll_started.wait()
            if False:
                yield ""

        bridge.notify_queue.recover_processing_notifications = lambda: recovered.append(True)
        bridge._poll_notifications = poll_notifications
        bridge._stdin_lines = no_requests

        result = await bridge.daemon(Path("/tmp/project"))

        self.assertEqual(result, 0)
        self.assertEqual(recovered, [True])
        self.assertTrue(poll_cancelled)


    def test_notification_drain_emits_matching_workspace_text_and_acknowledges(self):
        """Scenario: The daemon transfers matching notifications into the Emacs queue."""
        bridge = load_bridge()
        notification = {"chat_key": "/private/tmp/project", "message": "Task finished"}
        claimed_path = Path("/tmp/notify.json")
        emitted = []
        acknowledged = []

        bridge.notify_queue.claim_notifications = lambda matches: (
            [(claimed_path, notification)] if matches(notification) else []
        )
        bridge.notify_queue.format_notification_message = (
            lambda item: f"# Background update\n\n{item['message']}"
        )
        bridge.notify_queue.ack_notification = acknowledged.append
        bridge._emit_payload = emitted.append

        bridge._drain_notifications(Path("/tmp/project"))

        self.assertEqual(
            emitted,
            [{"type": "queue", "text": "# Background update\n\nTask finished"}],
        )
        self.assertEqual(acknowledged, [claimed_path])


def emacs_bridge_commands() -> set[str]:
    """Bridge command names the Elisp sends, read from its `(list "command" ...)` calls."""
    root = Path(__file__).resolve().parents[1]
    source = "".join((root / name).read_text() for name in ("faltoo-bridge.el", "faltoo-request.el"))
    return set(re.findall(r'\(list "([a-z][a-z-]*)"', source))


class BridgeCliBehaviorTest(unittest.TestCase):

    def test_both_bridges_accept_every_command_emacs_sends(self):
        """Scenario: Neither core rejects a bridge command Emacs can send it."""
        commands = emacs_bridge_commands()
        self.assertIn("messages", commands)

        # Emacs checks for the Claude core before asking for sub-agents.
        self.assertLessEqual(commands - {"subagents", "subagent-messages"}, set(load_bridge().COMMANDS))
        # Claude has no /tree yet and always sends prompts through its daemon.
        self.assertLessEqual(commands - {"tree-rows", "append-message"}, set(load_claude_bridge().COMMANDS))

    def test_shared_cli_parses_emacs_argument_shapes(self):
        """Scenario: One table-driven CLI handles workspace, limit, and core-specific options."""
        bridge = load_bridge()
        seen = []
        commands = {"messages": lambda args: seen.append(args) or 0}

        result = bridge.run_cli(
            "test",
            commands,
            ["--claude", "/bin/claude", "messages", "--workspace", "/tmp/p", "--limit", "5", "--turns", "2"],
            options={"--claude": {"default": "claude"}},
        )

        self.assertEqual(result, 0)
        self.assertEqual(
            (seen[0].workspace, seen[0].limit, seen[0].turns, seen[0].claude),
            (Path("/tmp/p"), 5, 2, "/bin/claude"),
        )
        with redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                bridge.run_cli("test", commands, ["session-info"])


def load_claude_bridge():
    install_faltoobot_stubs()
    python_dir = Path(__file__).resolve().parents[1] / "python"
    sys.path.insert(0, str(python_dir))
    sys.modules.pop("faltoo_bridge", None)
    try:
        spec = importlib.util.spec_from_file_location(
            "claude_bridge_under_test", python_dir / "claude_bridge.py"
        )
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(python_dir))
    return module


def text_delta(text):
    return {
        "type": "stream_event",
        "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}},
    }


def text_block_start():
    return {
        "type": "stream_event",
        "event": {"type": "content_block_start", "content_block": {"type": "text"}},
    }


def tool_use(name, tool_input, parent=None):
    return {
        "type": "assistant",
        "parent_tool_use_id": parent,
        "message": {"content": [{"type": "tool_use", "name": name, "input": tool_input}]},
    }


def replay(text):
    return {"type": "user", "isReplay": True, "message": {"role": "user", "content": text}}


SYSTEM_INIT = {"type": "system", "subtype": "init"}
RESULT_OK = {"type": "result", "subtype": "success", "is_error": False, "result": "ok"}


class ClaudeBridgeBehaviorTest(unittest.TestCase):

    def run_turns(self, bridge, messages, interrupting=False):
        emitted = []
        bridge._emit_payload = emitted.append
        turns = bridge.ClaudeTurns(Path("/repo"))
        turns.interrupting = interrupting
        for message in messages:
            turns.handle(message)
        return turns, emitted

    def outline(self, emitted):
        """Compact (id, kind) pairs: event type, or the class of stream text."""
        return [(event.get("id"), event.get("classes") or event["type"]) for event in emitted]

    def test_prompted_claude_turn_streams_as_faltoo_events(self):
        """Scenario: A prompt's echo and its turn reach Emacs as prompt, turn, and turn events."""
        bridge = load_claude_bridge()

        # Given Claude echoes a prompt, streams text and a tool, and reports limits.
        turns, emitted = self.run_turns(
            bridge,
            [
                SYSTEM_INIT,
                replay("Fix it"),
                text_block_start(),
                text_delta("Look"),
                text_delta("ing."),
                tool_use("Bash", {"command": "git status", "description": "Show  status"}),
                tool_use("Read", {"file_path": "/x"}, parent="toolu_subagent"),
                text_block_start(),
                text_delta("Done."),
                {
                    "type": "rate_limit_event",
                    "rate_limit_info": {
                        "unifiedWindows": {
                            "five_hour": {"utilization": 0.08},
                            "seven_day": {"utilization": 0.04},
                        }
                    },
                },
                RESULT_OK,
            ],
        )

        # Then Emacs shows the echoed prompt, opens one turn, and streams into it,
        # with sub-agent internals hidden.
        self.assertEqual(emitted[0], {"type": "prompt", "text": "Fix it"})
        self.assertEqual(emitted[1], {"type": "turn", "id": "turn-1"})
        self.assertEqual(
            [(event["classes"], event["text"]) for event in emitted[2:-1]],
            [
                ("answer", "Look"),
                ("answer", "ing."),
                ("tool", "Bash: Show status"),
                ("answer", "Done."),
                ("rate-limit", "Remaining limit: 5h = 92%, 7d = 96%"),
                ("done", "Assistant response saved."),
            ],
        )
        self.assertTrue(all(event["id"] == "turn-1" for event in emitted[1:]))
        self.assertEqual(emitted[-1], {"id": "turn-1", "type": "complete", "ok": True})
        self.assertTrue(turns.idle())

    def test_consecutive_text_blocks_are_separated_by_a_paragraph(self):
        """Scenario: Text blocks split by hidden thinking do not run together."""
        bridge = load_claude_bridge()

        _turns, emitted = self.run_turns(
            bridge,
            [replay("Hi"), text_block_start(), text_delta("One."), text_block_start(), text_delta("Two.")],
        )

        self.assertEqual("".join(event.get("text", "") for event in emitted[2:]), "One.\n\nTwo.")

    def test_turn_claude_starts_itself_is_headed_by_its_notification(self):
        """Scenario: Claude answering a finished background task gets a Background Update heading."""
        bridge = load_claude_bridge()

        # Given Claude is idle when a background task notification starts a turn.
        turns, emitted = self.run_turns(
            bridge,
            [
                {
                    "type": "system",
                    "subtype": "task_notification",
                    "summary": 'Background command "Sleep" completed (exit code 0)',
                },
                SYSTEM_INIT,
                text_block_start(),
                text_delta("finished-marker"),
                RESULT_OK,
            ],
        )

        # Then the notification heads the turn instead of a prompt.
        self.assertEqual(
            emitted[0],
            {
                "type": "notification",
                "text": "# Background update\n\nsource: Claude Code\n\n## message\n"
                'Background command "Sleep" completed (exit code 0)',
            },
        )
        self.assertEqual(
            self.outline(emitted[1:]),
            [("turn-1", "turn"), ("turn-1", "answer"), ("turn-1", "done"), ("turn-1", "complete")],
        )
        self.assertTrue(turns.idle())

    def test_notification_folded_into_a_running_turn_stays_inline(self):
        """Scenario: A background task finishing mid-turn is a line inside that turn."""
        bridge = load_claude_bridge()

        # Given Claude folds a task notification into the running turn and echoes it.
        _turns, emitted = self.run_turns(
            bridge,
            [
                replay("Fix it"),
                tool_use("Bash", {"description": "Wait"}),
                {"type": "system", "subtype": "task_notification", "summary": "Task done"},
                replay("<task-notification>\n<summary>Task done</summary>\n</task-notification>"),
                text_delta("Done."),
                RESULT_OK,
            ],
        )

        # Then the answer stays one turn, with the notification as a status line.
        self.assertEqual(
            self.outline(emitted),
            [
                (None, "prompt"),
                ("turn-1", "turn"),
                ("turn-1", "tool"),
                ("turn-1", "status"),
                ("turn-1", "answer"),
                ("turn-1", "done"),
                ("turn-1", "complete"),
            ],
        )
        self.assertEqual(emitted[3]["text"], "Task done")

    def test_prompt_folded_into_a_running_turn_starts_the_next_turn(self):
        """Scenario: A prompt Claude takes mid-turn ends that turn and starts its own."""
        bridge = load_claude_bridge()

        # Given Emacs sent a prompt while Claude's background turn was using tools.
        _turns, emitted = self.run_turns(
            bridge,
            [
                SYSTEM_INIT,
                tool_use("Bash", {"description": "Read output"}),
                replay("Question"),
                text_delta("Answer."),
                RESULT_OK,
            ],
        )

        # Then the transcript shows the prompt where Claude took it.
        self.assertEqual(
            self.outline(emitted),
            [
                (None, "notification"),
                ("turn-1", "turn"),
                ("turn-1", "tool"),
                ("turn-1", "complete"),
                (None, "prompt"),
                ("turn-2", "turn"),
                ("turn-2", "answer"),
                ("turn-2", "done"),
                ("turn-2", "complete"),
            ],
        )

    def test_failed_claude_turns_report_cancel_or_error(self):
        """Scenario: Interrupted turns read as cancelled; other failures show their error."""
        bridge = load_claude_bridge()
        cases = (
            (True, {"type": "result", "subtype": "error_during_execution", "is_error": True},
             ("status", "Cancelled.")),
            (False, {"type": "result", "subtype": "success", "is_error": True, "result": "Prompt is too long"},
             ("error", "Prompt is too long")),
        )

        for interrupting, result, expected in cases:
            with self.subTest(expected=expected):
                turns, emitted = self.run_turns(
                    bridge, [replay("Hi"), text_delta("Partial"), result], interrupting=interrupting
                )

                self.assertEqual((emitted[-2]["classes"], emitted[-2]["text"]), expected)
                self.assertEqual(emitted[-1], {"id": "turn-1", "type": "complete", "ok": False})
                self.assertFalse(turns.interrupting)

    def test_running_background_tasks_keep_the_daemon_busy(self):
        """Scenario: Idle expiry waits for Claude's background tasks to finish."""
        bridge = load_claude_bridge()

        turns, emitted = self.run_turns(
            bridge,
            [{"type": "system", "subtype": "background_tasks_changed", "tasks": [{"task_id": "b1"}]}],
        )

        self.assertFalse(turns.idle())
        # Emacs uses the count to confirm before stopping the daemon.
        self.assertEqual(emitted, [{"type": "background-tasks", "count": 1}])

    def test_workspace_session_prefers_faltoo_choice_then_latest_claude_session(self):
        """Scenario: Each workspace continues its selected or most recent Claude session."""
        bridge = load_claude_bridge()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir).resolve()
            workspace = root / "repo"
            bridge.CLAUDE_HOME = root / "claude"
            bridge.STATE_PATH = root / "state.json"
            project = bridge._project_dir(workspace)
            project.mkdir(parents=True)
            self.assertEqual(
                bridge._project_dir(Path("/Users/me/screener_dev/faltoo-emacs")).name,
                "-Users-me-screener-dev-faltoo-emacs",
            )

            # Given no session yet, a new one is created and remembered.
            created = bridge._session_id(workspace)
            self.assertEqual(bridge._session_id(workspace), created)

            # Given Claude sessions exist but Faltoo has no choice, the latest continues.
            bridge.STATE_PATH.unlink()
            (project / "old.jsonl").write_text("")
            (project / "new.jsonl").write_text("")
            os.utime(project / "old.jsonl", (1, 1))
            self.assertEqual(bridge._session_id(workspace), "new")

            # Given Faltoo chose a session, that choice wins.
            bridge._set_session_id(workspace, "old")
            self.assertEqual(bridge._session_id(workspace), "old")

    def test_claude_history_renders_like_the_live_stream(self):
        """Scenario: Reloaded Claude transcripts match live Faltoo rendering."""
        bridge = load_claude_bridge()
        records = [
            {"type": "queue-operation", "content": "Fix it"},
            {"type": "user", "message": {"content": "Fix it"}},
            {"type": "user", "isMeta": True, "message": {"content": "<local-command-caveat>"}},
            {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": "hmm"}]}},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "a"}]}},
            {"type": "attachment", "attachment": {"type": "queued_command", "commandMode": "task-notification",
                                                  "prompt": "<task-notification>\n<summary>Folded done</summary>\n</task-notification>"}},
            {"type": "attachment", "attachment": {"type": "total_tokens_reminder"}},
            {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "sub"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Fixed.\n"}]}},
            {"type": "user", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}},
            {"type": "user", "origin": {"kind": "task-notification"}, "message": {
                "content": "<task-notification>\n<summary>Task done</summary>\n</task-notification>"}},
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "session.jsonl"
            path.write_text("".join(json.dumps(record) + "\n" for record in records))

            history = bridge._history(path, Path("/repo"))

        self.assertEqual(
            [(item["role"], item["text"]) for item in history],
            [
                ("user", "Fix it"),
                ("tool", "Bash: ls"),
                ("tool", "Folded done"),
                ("assistant", "Fixed."),
                ("user", "# Background update\n\nsource: Claude Code\n\n## message\nTask done"),
            ],
        )

    def test_tool_summaries_show_repo_paths_relative_to_the_workspace(self):
        """Scenario: Tool summaries name repo files by repo path and others in full."""
        bridge = load_claude_bridge()
        cases = (
            ({"name": "Read", "input": {"file_path": "/repo/docs/guide.md"}}, "Read: docs/guide.md"),
            ({"name": "Grep", "input": {"pattern": "defun", "path": "/repo/python"}}, "Grep: defun"),
            ({"name": "Glob", "input": {"path": "/repo/test"}}, "Glob: test"),
            ({"name": "Read", "input": {"file_path": "/tmp/task.output"}}, "Read: /tmp/task.output"),
            ({"name": "Read", "input": {"file_path": "/repository/x.el"}}, "Read: /repository/x.el"),
            ({"name": "TodoWrite", "input": {"todos": []}}, "TodoWrite"),
        )

        for block, expected in cases:
            with self.subTest(expected=expected):
                self.assertEqual(bridge._tool_summary(block, Path("/repo")), expected)

    def test_session_commands_reset_resume_name_and_list_claude_sessions(self):
        """Scenario: /reset, /resume, /name, and the resume list use Claude's session files."""
        bridge = load_claude_bridge()

        def record(**fields):
            return json.dumps(fields, separators=(",", ":")) + "\n"

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir).resolve()
            workspace = root / "repo"
            bridge.CLAUDE_HOME = root / "claude"
            bridge.STATE_PATH = root / "state.json"
            project = bridge._project_dir(workspace)
            project.mkdir(parents=True)

            # Given sessions titled by the user, by Claude, by their prompt, and one empty.
            (project / "named.jsonl").write_text(
                record(type="ai-title", aiTitle="Auto title")
                + record(type="user", message={"content": "First prompt"})
                + record(type="custom-title", customTitle="Old name")
                + record(type="custom-title", customTitle="Chosen\nname")
            )
            (project / "auto.jsonl").write_text(
                record(type="user", isMeta=True, message={"content": "<caveat>"})
                + record(type="user", message={"content": [{"type": "text", "text": "Prompt"}]})
                + record(type="ai-title", aiTitle="Auto title")
            )
            (project / "plain.jsonl").write_text(
                record(type="user", message={"content": "Fix   the\nbridge " + "x" * 80})
            )
            (project / "empty.jsonl").write_text(record(type="custom-title", customTitle="No messages"))
            for age, name in enumerate(("plain", "auto", "named")):
                os.utime(project / f"{name}.jsonl", (age + 1, age + 1))

            def run(command, *args):
                out = io.StringIO()
                with redirect_stdout(out):
                    result = command(workspace, *args)
                self.assertEqual(result, 0)
                return json.loads(out.getvalue())

            # When listing sessions for /resume.
            sessions = run(bridge.sessions_list)["sessions"]

            # Then sessions with messages are listed newest first under their best title,
            # with the modification time kept separate for completion annotations.
            self.assertEqual(
                [(session["id"], session["name"]) for session in sessions],
                [("named", "Chosen name"), ("auto", "Auto title"), ("plain", "Fix the bridge " + "x" * 45)],
            )
            self.assertRegex(sessions[0]["modified"], r"^\d{1,2} [A-Z][a-z]{2} \d\d:\d\d$")

            # When resuming one, naming it, and resetting.
            self.assertEqual(run(bridge.resume_session, "plain")["session_id"], "plain")
            self.assertEqual(bridge._session_id(workspace), "plain")
            run(bridge.name_session, "Bridge fix")
            names = {session["id"]: session["name"] for session in run(bridge.sessions_list)["sessions"]}
            self.assertEqual(names["plain"], "Bridge fix")
            reset = run(bridge.reset_session)["session_id"]

            # Then reset selects a new session, which cannot be named before its first message.
            self.assertNotIn(reset, {"named", "auto", "plain"})
            self.assertEqual(bridge._session_id(workspace), reset)
            with redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(bridge.name_session(workspace, "Too early"), 1)
            self.assertIn("Send a message before naming", err.getvalue())

    def claude_home(self, tmpdir):
        bridge = load_claude_bridge()
        root = Path(tmpdir).resolve()
        bridge.CLAUDE_HOME = root / "claude"
        bridge.STATE_PATH = root / "state.json"
        return bridge, root / "repo"

    def test_status_reports_claude_session_model_and_context(self):
        """Scenario: /status summarizes the current Claude session from its file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            bridge, workspace = self.claude_home(tmpdir)
            bridge._set_session_id(workspace, "s1")
            path = bridge._session_path(workspace, "s1")
            path.parent.mkdir(parents=True)
            usage = {"input_tokens": 2, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 300, "output_tokens": 50}
            path.write_text("".join(json.dumps(record, separators=(",", ":")) + "\n" for record in [
                {"type": "user", "message": {"content": "Hi"}},
                {"type": "assistant", "message": {"model": "old-model", "usage": {"input_tokens": 1}}},
                {"type": "custom-title", "customTitle": "Status check"},
                {"type": "assistant", "message": {"model": "claude-opus-5-5", "usage": usage}},
                # Written only when a claude process exits, so stale for a live daemon.
                {"type": "cost-state", "totalCostUSD": 4.4721},
            ]))

            out = io.StringIO()
            with redirect_stdout(out):
                result = bridge.session_status(workspace)

        payload = json.loads(out.getvalue())
        self.assertEqual(result, 0)
        self.assertEqual(payload["workspace"], str(workspace))
        self.assertEqual(
            payload["text"],
            "\n".join([
                "Session",
                "• session_id=s1",
                "• name=Status check",
                f"• workspace={workspace}",
                f"• messages_path={path}",
                "Session usage",
                "• model=claude-opus-5-5",
                "• context_tokens=1,302",
                "• last_usage=" + json.dumps(usage),
            ]),
        )

    def test_prompt_picker_lists_faltoobot_then_claude_commands_with_source(self):
        """Scenario: C-c p offers FaltooBot prompts and Claude commands, tagged by source."""
        with tempfile.TemporaryDirectory() as tmpdir:
            bridge, _workspace = self.claude_home(tmpdir)
            commands = bridge.CLAUDE_HOME / "commands"
            commands.mkdir(parents=True)
            (commands / "review.md").write_text(
                "---\ndescription: Review the diff\nallowed-tools: Bash\n---\nReview $ARGUMENTS carefully.\n"
            )
            (commands / "plain.md").write_text("\n  Summarize the change in one line, please, with care.\n")
            (commands / "notes.txt").write_text("ignored")

            out = io.StringIO()
            with redirect_stdout(out):
                result = bridge.slash_commands()

        self.assertEqual(result, 0)
        self.assertEqual(
            json.loads(out.getvalue())["commands"],
            [
                {"command": "/commit", "preview": "Write a commit", "template": "Expanded commit prompt", "source": "faltoobot"},
                {"command": "/plain", "preview": "Summarize the change in one line, please, with c",
                 "template": "Summarize the change in one line, please, with care.", "source": "claude"},
                {"command": "/review", "preview": "Review the diff", "template": "Review $ARGUMENTS carefully.", "source": "claude"},
            ],
        )

    def test_subagents_list_newest_first_and_render_their_conversation(self):
        """Scenario: A session's sub-agents are listed from Claude's files and render like history."""
        with tempfile.TemporaryDirectory() as tmpdir:
            bridge, workspace = self.claude_home(tmpdir)
            bridge._set_session_id(workspace, "s1")
            agents = bridge._session_path(workspace, "s1").with_suffix("") / "subagents"
            agents.mkdir(parents=True)

            def agent(agent_id, description, age, records):
                (agents / f"agent-{agent_id}.meta.json").write_text(
                    json.dumps({"agentType": "general-purpose", "description": description})
                )
                path = agents / f"agent-{agent_id}.jsonl"
                path.write_text("".join(json.dumps(record) + "\n" for record in records))
                os.utime(path, (age, age))

            # Given two sub-agents, one with a tool call and answer, and an orphan meta file.
            agent("old", "Count entries", 1, [
                {"type": "user", "isSidechain": True, "message": {"content": "Run ls /"}},
                {"type": "assistant", "isSidechain": True, "message": {"model": "claude-haiku-4-5", "content": [
                    {"type": "tool_use", "name": "Read", "input": {"file_path": str(workspace / "a.txt")}}]}},
                {"type": "assistant", "isSidechain": True, "message": {"model": "claude-haiku-4-5", "content": [
                    {"type": "text", "text": "17"}]}},
            ])
            agent("new", "Review diff", 2, [])
            (agents / "agent-gone.meta.json").write_text(json.dumps({"description": "Gone"}))

            def run(command, *args):
                out = io.StringIO()
                with redirect_stdout(out):
                    self.assertEqual(command(workspace, *args), 0)
                return json.loads(out.getvalue())

            listed = run(bridge.subagents)["agents"]
            history = run(bridge.subagent_messages, "old")["messages"]

        # Then they are listed newest first with their type, the model that answered, and time.
        self.assertEqual(
            [(item["id"], item["description"], item["agent_type"], item["model"]) for item in listed],
            [("new", "Review diff", "general-purpose", ""), ("old", "Count entries", "general-purpose", "claude-haiku-4-5")],
        )
        self.assertRegex(listed[0]["modified"], r"^\d{1,2} [A-Z][a-z]{2} \d\d:\d\d$")
        # And a sub-agent's task, tools, and answer render like the transcript.
        self.assertEqual(
            [(item["role"], item["text"]) for item in history],
            [("user", "Run ls /"), ("tool", "Read: a.txt"), ("assistant", "17")],
        )


if __name__ == "__main__":
    unittest.main()
