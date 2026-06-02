#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import types
import unittest


class Prompt:
    preview = "Write a commit"
    template = "Expanded commit prompt"


class SlashCommandStore:
    def __init__(self, excluded_commands=None):
        self.excluded_commands = excluded_commands or frozenset()

    def commands(self):
        return {"/commit": Prompt()}


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
        "faltoobot.sessions": types.ModuleType("faltoobot.sessions"),
    }

    modules["faltoobot.faltoochat.git"].get_unstaged_files = lambda _workspace: []
    modules["faltoobot.faltoochat.git"].is_git_workspace = lambda _workspace: True
    modules["faltoobot.faltoochat.review_api"].Review = dict
    modules["faltoobot.faltoochat.review_api"].reviews_prompt = lambda comments: str(comments)
    modules["faltoobot.faltoochat.slash_commands"].SlashCommandStore = SlashCommandStore
    modules["faltoobot.faltoochat.messages_rendering"].get_item_text = lambda _item: None
    modules["faltoobot.faltoochat.stream"].get_event_text = lambda event: event
    modules["faltoobot.sessions"].Session = object
    modules["faltoobot.sessions"].get_dir_chat_key = lambda workspace: str(workspace)
    modules["faltoobot.sessions"].get_messages = lambda _session: {"messages": []}
    modules["faltoobot.sessions"].get_session = lambda _key, workspace: {"workspace": workspace}

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
