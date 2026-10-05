# Faltoo Emacs Agent Guide

## Working rules

- Personal-use plugin: support this user's workflow, not broad compatibility.
- Be brief, direct, and critical. Ask when something is unknown; do not assume.
- Make the smallest useful change. Question every new line and preserve existing logic when refactoring.
- Fix root causes, not symptoms. Avoid defensive checks in controlled call paths, fallback scaffolding, tiny helpers, and deep call chains.
- Keep code primary; transcript is history. Do not build a chat-first TUI clone.
- Target Emacs 30.2 with required `posframe`, `magit`, `markdown-mode`, and the system `file` command.
- Read `docs/design-decisions.md` before changing behavior. `README.md` owns installation and keybindings; do not duplicate them here.

## Code map

| File | Responsibility |
|---|---|
| `faltoo.el` | Entrypoint, command map, reload |
| `faltoo-core.el` | Workspace state, source context, status, source reload |
| `faltoo-bridge.el` | Python processes, JSON/JSONL transport, core selection |
| `python/faltoo_bridge.py` | FaltooBot imports, sessions, stream events, notification polling |
| `python/claude_bridge.py` | Claude Code core: bridge CLI over `claude -p` stream-json, turn translation, sessions |
| `faltoo-request.el` | Shared request and stream routing |
| `faltoo-chat.el` | Workspace transcripts, history rendering, sub-agent views |
| `faltoo-queue.el` | Editable workspace FIFO and consumption |
| `faltoo-ui.el` | Posframe lifecycle and shared Markdown setup |
| `faltoo-compose.el` | Popup layout and stream formatting |
| `faltoo-faces.el` | Theme-aware faces |
| `faltoo-ask.el` | Ask and last-response popups |
| `faltoo-comments.el` | Pending comments, overlays, navigation, batch prompts |
| `faltoo-review.el` | Generated full-file review, Magit integration, navigation |
| `faltoo-tree.el` | Incremental `messages.json` inspector, details, tokens, pruning |
| `faltoo-quit.el` | Quit guard |

Shared UI belongs in UI/compose; shared stream behavior belongs in request. Do not duplicate these in individual popups.

## Invariants

- Workspace is Git root or current folder; generic chat has its own fixed directory. Popups retain the originating workspace.
- Requests, queues, and pending comments are workspace-scoped. Source/review comments share canonical file identity and survive stopping review.
- Ask rebuilds from the current full-line selection. Last-response follow-up drafts survive close/reopen.
- Review buffers are generated and read-only; they do not promise real-file LSP parity. Source buffers remain editable.
- Git colors affect backgrounds only; selection, syntax, and comments stay visible.
- Review owns hidden Magit diff buffers; rendering and staging share their sections. Kill backing buffers with their review.
- Git actions rebuild review state from the index/worktree. Never toggle staged flags or apply stored zero-context patches. Magit hunks use three context lines.
- Review refresh is explicit or follows Git actions, not assistant completion. Completion reloads only unmodified source buffers in that workspace.
- Queue text is its storage. Consumption appends user turns; finalizing comments clears their objects/overlays. Opening the queue does not pause it.
- Queue/notification support targets websocket workspaces only. Claim/ack/requeue stays in Python.
- Reload must not stop running bridge daemons. Switching a workspace's core does stop its daemon.
- Let Markdown mode fontify normally. Do not force synchronous fontification or move the reader while appending streams.
- Never auto-stage assistant edits.

## Verification

First write a failing, descriptive BDD-style ERT test, then fix. Prefer parameterized behavior cases and remove redundant tests after green. Run a short real Emacs check; mocks alone missed UI and Git bugs.

| Test | Purpose |
|---|---|
| `test/faltoo-behavior-test.el` | Behavior specs |
| `test/faltoo-performance-test.el` | Rendering and interaction budgets |
| `test/faltoo-review-git-test.el` | Installed Magit, real Git index/worktree assertions |
| `test/faltoo-bridge-behavior-test.py` | Python bridge behavior |
| `test/load-smoke.el` | Load with dependency stubs |
| `test/byte-compile-smoke.el` | Byte compilation |

Run the commands in README's Testing section before committing. For review changes, check full-file context, inline deletions, source/comment mapping, stage/unstage, refresh, navigation, and buffer cleanup. `dev/faltoo-visual-test.el` supports opt-in local visual testing; do not change regular init for test scaffolding.

## Commits

- Keep commits focused. Preserve unrelated user edits, including the test comment at the end of `faltoo.el`.
- Run configured pre-commit hooks only on changed files; report any hook-driven edits.
- Compare the title with the complete staged diff: cover all major user-visible changes.
- The title says what changed; the body explains why (bug cause or refactor benefit). Prefer bullets, wrapped at 72 columns.
- Use a heredoc or `git commit -F` for multiline messages, never literal `\n` in `-m` strings.
