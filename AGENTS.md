# Faltoo Emacs Agent Guide

## User Preferences / Standing Instructions

- User prefers compact responses; avoid lengthy explanations unless specifically asked.
- This plugin is for the user's personal use only. Be opinionated, direct, and fast.
- Optimize for the user's desired workflow, not broad compatibility or fallback support.
- Prefer simple, boring, easy-to-read code that works quickly.
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
7. Use `*Faltoo*` as transcript/history, not the main interaction surface.

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
faltoo-chat.el         `*Faltoo*` transcript/history rendering.
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
- `C-c f a` opens Ask posframe for active region or current line.
- `C-c f c` opens review-comment posframe for active region/current line.
- `C-c f C` opens file-level comment posframe.
- `C-c f s` submits pending review comments.
- `C-c f l` shows latest assistant response in posframe.
- `C-c f h` opens transcript/history.
- `C-c f x` stops current review session.
- Ask context is only active region or current line. Do not add defun/file/buffer context unless asked.
- Ask responses stream in the posframe and transcript.
- Transcript and popup buffers use `markdown-mode` with local pretty Markdown settings, because model output is Markdown.
- Review-comment submissions stream to `*Faltoo*` and status/mode-line, not a popup.
- Review buffers are read-only and show a header line with `Faltoo[1/N]`.
- `diff-hl` is configured buffer-locally in review buffers for full-line highlights.
- Faltoo never auto-stages assistant edits.

## Testing

Tests should be behavior-oriented and readable, BDD style.

Main test files:

```text
test/faltoo-behavior-test.el      Behavior/spec tests.
test/faltoo-performance-test.el   Performance behavior tests.
test/byte-compile-smoke.el        Byte compile smoke.
test/load-smoke.el                Load smoke with dependency stubs.
```

Run before committing:

```sh
emacs -Q --batch -l test/faltoo-behavior-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -l test/faltoo-performance-test.el -f ert-run-tests-batch-and-exit
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
C-c f a   ask about region/current line
C-c C-c   send from Ask popup
C-g       close popup
C-c f c   add review comment
C-c C-c   save comment
C-c f s   submit comments
C-c f h   view transcript
C-c C-l   load more transcript turns from `*Faltoo*`
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
