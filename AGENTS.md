# Faltoo Emacs Agent Guide

## User Preferences / Standing Instructions

- User prefers compact responses; avoid lengthy explanations unless specifically asked.
- This plugin is for the user's personal use only. Be opinionated, direct, and fast.
- Optimize for the user's desired workflow, not broad compatibility or fallback support.
- Prefer simple, boring, easy-to-read code that works quickly.
- Always do the smallest change that solves the current problem; question whether every new line is really needed.
- Avoid excessive defensive programming; this codebase controls most call paths.
- Fix root causes with higher-level architecture changes, not localized band-aid handlers.
- Preserve the code-first workflow: source buffers are primary; transcript is secondary/history.
- Dependencies are acceptable and expected. Required packages are `posframe`, `magit`, `diff-hl`, and `markdown-mode`.
- Target the latest stable Emacs in use for this project, currently GNU Emacs 30.2.

## Product Direction

Faltoo Emacs is a code-first Emacs integration for FaltooBot/FaltooChat.

Primary workflow:

1. Open unstaged files as normal source buffers.
2. Enable `faltoo-review-mode` only for review-set files.
3. Keep code at the forefront: normal major mode, xref/LSP/navigation, full-file context.
4. Use `diff-hl` for full-line Git change highlights inside source buffers.
5. Use `posframe` for code-local Ask and review-comment input.
6. Use Magit for staging/unstaging/status/diff operations.
7. Use per-workspace transcript buffers named like `*Faltoo: repo-name*` as history, not the main interaction surface.

Do not turn Faltoo into a chat-first TUI clone. The Nvim plugin exists because the TUI was too chat-centered; keep this Emacs plugin code-centered.

## Design Reference

Authoritative design doc:

```text
docs/design-decisions.md
```

Read this before changing behavior or UX assumptions.

## Code Map

```text
faltoo.el              Main entrypoint, command map, package provide.
faltoo-core.el         Shared state, workspace/git-root helpers, mode-line status, buffer reload.
faltoo-bridge.el       Python bridge process calls and JSON/JSONL stream handling.
faltoo-request.el      Central request/stream routing for Ask and review submissions.
faltoo-ui.el           Posframe popup primitives and popup base mode.
faltoo-compose.el      Shared popup layout helpers: titles, metadata, sections, code, help.
faltoo-faces.el        Faces for popups, review comments, full-line diff highlights.
faltoo-ask.el          Source-buffer Ask UI and last-response popup.
faltoo-comments.el     Pending review-comment model, posframe input, overlays, navigation, submit payload.
faltoo-review.el       Review mode, review set, diff-hl integration, Magit wrappers, review file nav.
faltoo-chat.el         Per-workspace transcript/history rendering.
faltoo-tree.el         Special-mode transcript inspector for messages.json, row details, token summary, pruning.
faltoo-quit.el         Quit guard for running requests / pending comments.
python/faltoo_bridge.py Bridge copied/adapted from faltoo.nvim.
```

## Important Architecture Rules

- Keep stream handling centralized in `faltoo-request.el`. Do not duplicate stream routing in Ask/comments.
- Keep posframe display primitives in `faltoo-ui.el`; keep layout formatting in `faltoo-compose.el`.
- Keep source-buffer review behavior in `faltoo-review.el`.
- Keep pending-comment state and overlays in `faltoo-comments.el`.
- Keep bridge subprocess details in `faltoo-bridge.el`.
- If a UI behavior applies to both Ask and comments, implement it once in `faltoo-ui.el` or `faltoo-compose.el`.
- If a stream behavior applies to both Ask and review submissions, implement it once in `faltoo-request.el`.
- Avoid adding broad fallback paths. Required packages are required.

## Current UX Decisions

- `C-c f` is the main prefix.
- `C-c f u` starts review of unstaged files.
- In normal source buffers, `C-c f a` opens Ask posframe for active region or current line.
- In normal source buffers, `C-c f c` opens review-comment posframe for active region/current line.
- In normal source buffers, `C-c f C` opens file-level comment posframe.
- In normal source buffers, `C-c f s` submits pending review comments.
- In normal source buffers, `C-c f l` shows latest assistant response in posframe.
- `C-c f h` opens the current Git repo's transcript/history.
- `C-c f i` opens generic `*Faltoo Chat*`, anchored at `faltoo-generic-chat-directory`, for quick questions outside the current repo/session.
- `C-c f b` switches the current chat/workspace Faltoo core command between release/local/custom for testing local FaltooBot changes. Local-core answering status is shown as `Faltoo-beta:answering`.
- In normal source buffers, `C-c f x` stops current review session.
- Ask context is only active region or current line. Do not add defun/file/buffer context unless asked.
- Ask/comment snippets always expand to full source lines: current line when no region, or all lines touched by the active region.
- Ask always rebuilds from the active region/current line when invoked; responses stream in the posframe and current repo transcript. Last-response popups preserve follow-up drafts across close/reopen.
- Faltoo workspace/session follows the current buffer's Git root when present; outside Git it falls back to the current folder and informs the user once. Popup and repo transcript buffers set `default-directory` to that workspace so sends continue in the correct session. Generic chat intentionally uses `faltoo-generic-chat-directory` instead of source-buffer workspace detection.
- The Python bridge resolves its Python from the current workspace's command override, falling back to `faltoo-faltoobot-command`; this allows per-chat switching between released FaltooBot and the local venv command.
- Running-request state is per workspace. A request in one Git repo must not block Ask/chat/review submission in another repo.
- Request cancellation is per workspace: `C-c f q` from source/review buffers through the main Faltoo prefix.
- Transcript and popup buffers use `markdown-mode` with local pretty Markdown settings, because model output is Markdown.
- `C-c /` runs built-in session commands (`/reset`, `/resume`, `/name`, `/tree`, `/status`); `C-c p` inserts saved prompt templates. Typed slash text submits as a normal prompt.
- Review-comment submissions stream to the current repo transcript and status/mode-line, not a popup.
- Review buffers are read-only, use direct single-key review bindings, and show a header line with `Faltoo[1/N]`.
- `diff-hl` is configured buffer-locally in review buffers for full-line highlights.
- Faltoo never auto-stages assistant edits.

## Testing

Tests should be behavior-oriented and readable, BDD style.

Main test files:

```text
test/faltoo-behavior-test.el      Behavior/spec tests.
test/faltoo-performance-test.el   Performance behavior tests.
test/faltoo-bridge-behavior-test.py Python bridge behavior tests.
test/byte-compile-smoke.el        Byte compile smoke.
test/load-smoke.el                Load smoke with dependency stubs.
```

Run before committing:

```sh
emacs -Q --batch -l test/faltoo-behavior-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -l test/faltoo-performance-test.el -f ert-run-tests-batch-and-exit
python3 -m unittest test/faltoo-bridge-behavior-test.py
emacs -Q --batch -l test/byte-compile-smoke.el
rm -f *.elc
```

When adding behavior, first add a failing BDD-style test with a descriptive name, then fix.

Good test names:

```elisp
faltoo-ask-uses-active-region-when-present
faltoo-popup-show-creates-focusable-bordered-posframe
faltoo-review-mode-uses-full-line-diff-highlighting
```

## Manual Test Flow

In a Git repo with unstaged changes:

```text
C-c f u   review unstaged files
a         ask about region/current line in review buffers
C-c C-c   send from Ask popup
C-g       close popup
c         add review comment in review buffers
C-c C-c   save comment
s         submit comments in review buffers
h         view current repo transcript in review buffers
C-c C-l   load more transcript turns from the repo transcript
C-c C-p/n jump previous/next user message in the repo transcript
```

Expected visual behavior:

- Review source buffer is read-only.
- Header line shows `Faltoo Review Faltoo[1/N]`.
- Git changes are highlighted as full lines.
- Ask/comment posframes are focusable, editable, and bordered.
- Pending comment lines are highlighted and marked with `●`.

## Git / Commit Notes

- This repo is a Git repo.
- Do not commit unrelated user test edits. Example: user may leave temporary edits in `faltoo.el` to create unstaged changes for UI testing.
- Keep commits focused and small.
- Run tests before committing.
