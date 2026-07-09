#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
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
        "faltoobot.faltoochat.git": types.ModuleType("faltoobot.faltoochat.git"),
        "faltoobot.faltoochat.review_api": types.ModuleType("faltoobot.faltoochat.review_api"),
        "faltoobot.faltoochat.slash_commands": types.ModuleType("faltoobot.faltoochat.slash_commands"),
        "faltoobot.faltoochat.messages_rendering": types.ModuleType("faltoobot.faltoochat.messages_rendering"),
        "faltoobot.faltoochat.stream": types.ModuleType("faltoobot.faltoochat.stream"),
        "faltoobot.config": types.ModuleType("faltoobot.config"),
        "faltoobot.sessions": types.ModuleType("faltoobot.sessions"),
    }

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
            yield "chunk"

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

    async def test_append_review_formats_transcript_comments_as_response_comments(self):
        """Scenario: Transcript review comments are submitted as response comments."""
        bridge = load_bridge()
        captured_questions = []

        async def append_user_turn(_session, question):
            captured_questions.append(question)

        async def empty_answer_stream(_session):
            if False:
                yield None

        bridge.append_user_turn = append_user_turn
        bridge.get_answer_streaming = empty_answer_stream

        await bridge.append_review(
            Path("/tmp/faltoo-workspace"),
            [
                {
                    "filename": "Faltoo transcript",
                    "line_number_start": 2291,
                    "line_number_end": 2295,
                    "code": "assistant text",
                    "comment": "follow up",
                }
            ],
        )

        self.assertIn("Your response:\n\n```\nassistant text\n```", captured_questions[0])
        self.assertNotIn("Comments in code review", captured_questions[0])
        self.assertNotIn("File name", captured_questions[0])
        self.assertNotIn("Faltoo transcript", captured_questions[0])
        self.assertNotIn("### Line", captured_questions[0])
        self.assertNotIn("Code:", captured_questions[0])

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

    async def test_answer_stream_preserves_whitespace_only_chunks(self):
        """Scenario: Newline-only assistant chunks keep Markdown code fences intact."""
        bridge = load_bridge()
        emitted = []
        events = ["language", "newline", "body"]

        # Given the model streams a newline as its own answer chunk.
        bridge.get_event_text = lambda event: {
            "language": (False, "answer", "```text"),
            "newline": (False, "answer", "\n"),
            "body": (False, "answer", "M faltoo.el"),
        }[event]
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
                    "content": "## Post-response hook feedback\n\n### Refactor Code\n\nHook notes",
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
        self.assertIn("Refactor Code", payload["messages"][0]["text"])

    async def test_post_response_hook_feedback_gets_distinct_stream_class(self):
        """Scenario: Post-response hook feedback is not emitted as a generic tool block."""
        bridge = load_bridge()
        emitted = []

        # Given FaltooBot streams dedicated hook feedback events.
        event = types.SimpleNamespace(type="faltoobot.post_response_hook.feedback")
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
            yield object()

        bridge.get_answer_streaming = answer_stream

        # When the bridge streams that event to Emacs.
        await bridge._stream_answer({})

        # Then Emacs receives a rate-limit event it can place in the footer.
        self.assertEqual(emitted[0]["classes"], "rate-limit")
        self.assertEqual(emitted[0]["text"], "Remaining limit: 5h = 98%")


if __name__ == "__main__":
    unittest.main()
