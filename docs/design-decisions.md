# Faltoo Emacs Design Decisions

This document is the authoritative design reference for the Emacs Faltoo plugin. It captures the product and implementation decisions made before implementation so the plugin can be built consistently, and so future changes can be made deliberately.

## Goals

Build an Emacs integration for Faltoo/FaltooBot inspired by `faltoo.nvim`, but using Emacs-native interaction patterns rather than directly copying Neovim floating modal UI.

Primary goals:

- Provide a good Emacs chat/transcript experience for FaltooBot.
- Support review workflows over unstaged files.
- Allow line/range/file-level review comments.
- Submit review comments to FaltooBot and stream the response.
- Keep source buffers in their normal major modes.
- Use Emacs-native primitives: buffers, minor modes, overlays, `completing-read`, process filters, and standard key conventions.

Non-goals for the first implementation:

- Recreating Neovim floating modals exactly.
- Implementing Faltoo as a generic LLM provider backend.
- Depending on a terminal/vterm wrapper for FaltooBot.
- Building hunk staging, patch accept/reject, or Ediff workflows in the MVP.

## Relationship to Existing Emacs LLM Packages

We considered patterns from existing Emacs LLM/coding-agent packages.

### Borrow from `gptel`

`gptel` remains useful inspiration for plain-buffer transcripts, prompt sending, and Emacs-native completion.

However, Faltoo's primary workflow should be **code-first**, not chat-first. The chat transcript is important for history, but it should not be the main interaction surface during code review.

Decisions borrowed from `gptel`:

- Keep a normal, searchable, copyable transcript buffer for full history.
- Use simple send semantics such as `C-c C-c`.
- Use Emacs completion primitives for file/context insertion.
- Allow interaction from anywhere.

Decisions that intentionally differ from `gptel`:

- The source buffer is the primary UI during review.
- Ask/comment interactions should happen in centered `posframe` popups while keeping source buffers primary.
- The transcript should be available on demand, but should not be required for asking questions or reviewing code.

We will not initially depend on `gptel` or implement Faltoo as a `gptel` backend. FaltooBot owns its own sessions, history, bridge protocol, review prompts, tool events, and workspace behavior, so a custom Faltoo implementation is more appropriate.

### Borrow from `copilot-chat.el`

Useful ideas:

- Side-by-side code and chat workflow.
- Prompt sending with `C-c C-c`.
- Prompt history may be added later.
- A chat buffer should be easy to display next to source code.

### Borrow from `ellama`, `gptel`, Aidermacs

Useful idea:

- A `transient` command menu would be a good discoverability layer later.

Do not make `transient` required for the initial core workflow unless it remains lightweight and optional.

### Borrow from Aidermacs / `aider.el`

Useful future ideas:

- Magit integration.
- Ediff/diff review integration for assistant edits.
- Agent-session commands per project.

For MVP, use a structured process/JSON bridge rather than vterm/comint terminal scraping.

### Borrow from `org-ai`

Useful future idea:

- Optional Org-style transcript export or rendering.

For MVP, do not require Org.

## Architecture Overview

Use small, scoped modes and plain commands rather than one global monolithic “FaltooBot mode”.

Planned components:

```text
faltoo.el              ; public commands, setup, command map
faltoo-core.el         ; workspace/session state
faltoo-bridge.el       ; Python bridge calls and streaming JSONL parser
faltoo-chat.el         ; per-workspace transcript/chat buffers
faltoo-review.el       ; review source-buffer minor mode and unstaged files
faltoo-comments.el     ; pending comment data, overlays, navigation
faltoo-compose.el      ; compose helpers for comments and posframe Ask
faltoo-ui.el           ; shared window/display helpers
python/faltoo_bridge.py
```

This file layout can change if a simpler implementation emerges, but the separation of responsibilities should be preserved.

## Modes

Do not implement a single global `faltoo-mode` that takes over the editor.

Use scoped modes:

### `faltoo-review-mode`

A buffer-local minor mode for source buffers currently under Faltoo review.

Responsibilities:

- Preserve the original major mode of source files.
- Mark review buffers read-only.
- Add review-specific keybindings.
- Display pending comment overlays/fringe markers.
- Support next/previous pending comment navigation.
- Clean up overlays/keybindings/read-only state when disabled.

This is the Emacs-native equivalent of Faltoo review behavior in `faltoo.nvim`.

### `faltoo-chat-mode`

A major mode for per-workspace chat/transcript buffers, named like:

```text
*Faltoo: repo-name*
```

Responsibilities:

- Display persisted FaltooBot messages.
- Provide an editable prompt area / editable transcript workflow.
- Send chat prompts.
- Display live assistant/tool streaming events.
- Provide commands for refresh, reply, open unstaged files, and submit review comments.

### `faltoo-compose-mode`

A mode for compose buffers if/when needed, especially for review comments.

For chat, the initial preferred design is to type directly in the current repo transcript rather than opening a separate Ask modal.

For comments, a compose buffer is still preferred because comment input has target metadata: file, line/range, selected code.

## Chat / Transcript Design

Faltoo should be code-first. The transcript is a background/history surface, not the primary review UI.

Each Git repo should have a persistent transcript buffer:

```text
*Faltoo: repo-name*
```

It is used for viewing full conversation history, jumping between user turns, searching/copying responses, refreshing persisted messages, and continuing a longer chat when desired. During normal code review, users should be able to ask questions and submit comments from source buffers without switching to the transcript.

The transcript buffer `default-directory` is the repo root, so chat sends, file references, slash commands, and refreshes use the same FaltooBot workspace/session as source-buffer commands from that repo. Running-request state is scoped by Git repo: one workspace can be answering while another workspace accepts a new prompt.

When a streamed assistant response completes, the finalized assistant heading stays clean and a quoted footer records elapsed wall-clock time, e.g. `> Assistant took: 20.0s`. If the Codex stream includes a `codex.rate_limits` event, store the latest formatted `Remaining limit: ...` text per workspace and append it to the same assistant footer. This is not a separate LLM call or standalone quota endpoint in the current FaltooBot path; it is metadata delivered by the Codex response stream.

### Transcript Format

Use Markdown formatting in `markdown-mode` because model output is Markdown. Enable local pretty Markdown settings (`markdown-hide-markup`, native code block fontification, whole-heading fontification) rather than maintaining a Markdown-to-Org converter:

```markdown
# User

Can you review the unstaged changes?

---
# Assistant

I will inspect the files.

- read `src/foo.py`
- ran tests

The main issue is...

---
# User

Can you also check `tests/foo_test.py`?
```

Transcript headings after the first turn are separated with Markdown horizontal rules. A streaming response may render as:

```markdown
# Assistant · answering

Submitting message...
```

Tool/status events should be compact by default and must not create their own transcript headings. Codex rate-limit events are special: capture them during the stream and show the latest one in the assistant footer instead of rendering them as ordinary tool quotes:

```markdown
> reading `foo.py`
> running tests

Final response starts here.

> Assistant took: 20.0s
> Remaining limit: 5h = 98%
```

Assistant answer text should be preserved in full. Tool/status bullets may be clipped or summarized.

### Editable Transcript Decision

Start with a `gptel`-style editable transcript.

Reasons:

- It is Emacs-native.
- It is easy to search/copy/edit/save.
- It is simpler than managing a read-only transcript with a separate editable prompt region.
- `C-c C-r` refresh can always restore canonical history from FaltooBot if the local buffer was edited.

Canonical history remains FaltooBot's persisted session. Local edits to transcript buffers are UI edits unless an explicit save/export feature is later added.

### Sending Chat Messages

Chat messages should send immediately.

This intentionally differs from `faltoo.nvim`, where Ask saves a pending question and `submit` sends it later.

Decision:

- Chat/Ask = immediate send from the current repo transcript or source-buffer popup.
- Review comments = prepared/batched and submitted together.

Rationale:

- Immediate send is more natural for chat in Emacs.
- Batch submission is still valuable for review comments.

### Prompt Detection

MVP prompt detection can be heading-based:

- User writes under the latest `# User` heading.
- `C-c C-c` sends the text under the latest user heading that has no following assistant response.

This can later be made more robust with text properties/markers if needed.

### `faltoo-chat-mode` Keybindings

Initial preferred keys:

```text
C-c C-c   send current prompt
C-c C-r   refresh from FaltooBot session
C-c C-p   previous persisted user message
C-c C-n   next persisted user message
C-c C-f   insert file reference
C-c /     run session command
C-c p     paste saved prompt template
```

Because the transcript is editable, avoid overusing plain single-letter keys where they interfere with normal text entry. Plain keys are acceptable only when point is not in editable prompt text or if the mode design makes that safe.

## Ask Behavior

Ask should be source-buffer-first. Users should be able to ask about the current line, active region, defun, or file without switching to the transcript.

Preferred UI:

- Use `posframe` for Ask popups.
- The popup should appear centered and include target context: file, line/range, and selected code when applicable.
- `C-c C-c` sends immediately.
- `C-c C-k`/`C-g` cancels.
- `C-c C-f` inserts a file reference.
- `C-c /` runs built-in session commands. `C-c p` pastes a saved prompt template.

Ask commands:

```elisp
faltoo-ask              ; ask at point/current context
faltoo-ask-region       ; ask about active region
faltoo-ask-defun        ; optional future command
faltoo-ask-file         ; optional future command
```

Streaming response behavior:

- Ask-from-code responses should stream in the posframe popup so the user can stay focused on code.
- General chat started from a repo transcript should stream in that repo's transcript.
- Running streams can be cancelled per workspace; cancellation kills only that repo's bridge process and leaves other repo streams alone.
- Batched review-comment submissions should not stream full responses in a popup by default; they should stream to the current repo transcript and show lightweight progress in the mode-line/minibuffer.
- Background/tool-heavy requests should use the current repo transcript for full stream details and lightweight status near code.
- Every exchange should be appended to/persisted in the current repo's FaltooBot session and visible in that repo's transcript history.
- After a request completes, refresh unmodified file-visiting buffers under that workspace from disk. This avoids Emacs stale-file save prompts when the assistant edits files externally. Leave modified buffers untouched so native conflict handling protects user edits.
- Ask popups add an editable `## Follow-up` section after a successful response. `C-c C-c` sends the follow-up while reusing the original code context. Do not bind plain `q` in editable popups.

Stream location policy:

| Interaction | Stream location |
|---|---|
| Ask from code / region / defun / file | posframe popup |
| Chat from repo transcript | same repo transcript |
| Submit batched review comments | repo transcript + mode-line/minibuffer status |
| Background/tool-heavy request | repo transcript + lightweight status |

The transcript command `faltoo-chat` should open the current repo's `*Faltoo: repo-name*` buffer for reviewing full history. A chat-style prompt inside the repo transcript may exist, but it is secondary to source-buffer Ask.

### Last Assistant Message Popup

Provide a source-buffer command to show the latest assistant message in a `posframe` popup without switching to the transcript:

```elisp
faltoo-show-last-response
```

Behavior:

- Fetch/use the latest assistant message from the current Faltoo session.
- Display it in a centered `posframe` with an editable `## Follow-up` section. The popup buffer is per workspace and preserves typed follow-up text across close/reopen.
- `C-c C-c` sends the typed follow-up as a plain chat message; `C-g`/`C-c C-k` closes. Do not bind plain `q` globally because popup modes share editable text behavior.
- This is for quick recall; full history remains in the repo transcript.

## Commands and Saved Prompts

Commands and prompt templates are separate so prompt submission stays honest:

- `C-c /` opens command completion for built-in session commands: `/reset`, `/resume`, `/name`, `/tree`, `/status`.
- `/tree` opens the current session `messages.json`; `/status` renders FaltooBot config/session/usage status in a temporary popup.
- `C-c p` opens saved prompt completion and pastes the full template text into the active prompt buffer for editing.
- Manually typed slash text is submitted to the model as plain prompt text.

## File References

Use Emacs-native completion.

Command:

```elisp
faltoo-insert-file-reference
```

Behavior:

- List repository/project files.
- Use `completing-read`.
- Insert selected file as code-style file reference:

```org
`relative/path`
```

This should work in:

- Current repo transcript buffer.
- Review comment compose buffers.

Because it uses `completing-read`, it automatically benefits from Vertico, Ivy, Helm, Consult, Icomplete, etc.

## Slash Command Implementation

Bridge commands:

```text
slash-commands
reset-session
resume-session
name-session
list-sessions
session-info
```

Elisp commands:

```elisp
faltoo-run-session-command
faltoo-insert-prompt-template
```

Behavior:

- Add Emacs-local built-ins for `/reset`, `/resume`, `/name`, `/tree`, and `/status`.
- Fetch saved FaltooBot prompt templates through `slash-commands`.
- Use `completing-read` for command/session/template selection.
- Run session commands directly from `C-c /`.
- Paste saved prompt templates from `C-c p`.
- Do not intercept typed slash text during prompt submission.

Initial keys in transcript and Ask/last-response buffers:

```text
C-c /
C-c p
```

Do not overload literal `/` in MVP.

## Review Workflow

Review workflow is separate from ordinary chat.

Commands:

```elisp
faltoo-open-unstaged
faltoo-review-on
faltoo-review-off
faltoo-comment
faltoo-file-comment
faltoo-submit-review-comments
faltoo-comments-summary
faltoo-delete-current-comment
faltoo-next-comment
faltoo-prev-comment
```

Naming can be shortened for public commands, but the workflow should remain explicit.

### Open Unstaged Files

`faltoo-open-unstaged` should:

- Ask the bridge for current unstaged files.
- Open them with `find-file-noselect` / `switch-to-buffer`.
- Enable `faltoo-review-mode` in those buffers.
- Mark them read-only.
- Optionally close/bury unmodified review buffers not in the unstaged set.
- If no unstaged files exist, show the repo transcript instead.

Use the bridge's unstaged-file logic first, to match FaltooBot's workspace/git behavior. A pure-Elisp or Magit fallback can be added later.

### Source Buffer State

Source buffers under review must keep their original major modes. For example:

- Python files stay in Python mode.
- Elisp files stay in Emacs Lisp mode.
- TypeScript files stay in their existing mode.

`faltoo-review-mode` is only additive.

### Buffers Excluded from Review Mode

Do not enable review mode in:

- non-file buffers
- special buffers
- minibuffers
- Magit/status/process buffers
- git commit/rebase message buffers
- files outside the current Faltoo workspace/project

## Review Comments

Pending review comments are Faltoo-specific state and should be implemented by us.

Data model should include:

- filename
- absolute normalized path
- line number start
- line number end
- file line number start
- file line number end
- selected/current code text
- user comment text
- markers/overlays for Emacs-side tracking

### Comment Types

Support:

- line comment on current line
- range comment on active region
- file-level comment

### Comment Input UI

Use a comment compose buffer rather than a floating modal.

Suggested buffer:

```text
*Faltoo Comment*
```

Display target metadata:

- file
- line/range
- selected code block, for line/range comments

Then provide an editable comment area.

Suggested keys:

```text
C-c C-c   save/update comment
C-c C-k   cancel
C-c C-f   insert file reference
```

### Editing Existing Comments

If the user comments an already-commented line or overlapping range, open the existing comment for editing instead of adding a duplicate.

If an existing comment is submitted with empty text, delete it.

If a new comment is submitted with empty text, do nothing.

### Comment Indicators

Use Emacs overlays and/or fringe markers.

Initial decision:

- Implement our own overlays/fringe markers rather than using Flymake.

Rationale:

- Pending comments are not diagnostics.
- We need direct control over editing/deletion/submission state.

### Navigation

Provide:

```elisp
faltoo-next-comment
faltoo-prev-comment
faltoo-comments-summary
faltoo-delete-current-comment
```

These should navigate, inspect, edit, and delete pending comments before submission.

## Submitting

### Chat Submission

Chat messages from a repo transcript send immediately using bridge command:

```text
append-message
```

Behavior:

- Insert/render user prompt in the repo transcript.
- Add an `# Assistant · answering` section.
- Start async bridge process.
- Stream JSONL events into the chat buffer.
- On completion, finalize the assistant heading in-place and append the next user prompt after a horizontal rule.
- Ring bell optionally.
- Reload review buffers if the assistant may have edited files.

### Review Comment Submission

Review comments are submitted in batch using bridge command:

```text
append-review
```

Behavior:

- Convert pending comment structs to bridge payload.
- Start async bridge process.
- Stream response into the repo transcript.
- Remove only the submitted comment objects once the bridge confirms submission.
- Keep comments added after submission started.
- On completion, reload review buffers and refresh comment indicators.

### Overlapping Submissions

Do not allow overlapping Faltoo requests in MVP.

If a request is already running, notify the user.

## History / Persistence

Canonical history is loaded from FaltooBot through the bridge:

```text
messages --workspace <workspace> --limit <n>
```

Each repo transcript should have a refresh command:

```text
g
C-c C-r, optional
```

Refresh should discard local UI edits and rerender from canonical FaltooBot messages plus any active live stream.

## Bridge

Use a Python bridge based on `faltoo.nvim`'s bridge.

Bridge commands needed:

```text
messages
messages-path
unstaged-files
append-review
append-message
slash-commands
```

Emacs side should provide:

- synchronous bridge call helper for commands like `messages`, `unstaged-files`, `slash-commands`
- asynchronous streaming helper for `append-message` and `append-review`
- JSONL process filter with chunk accumulator
- process sentinel for completion/failure

### Python Resolution

Preferred approach:

- Find `faltoobot` using `executable-find`.
- Read its shebang.
- Use that Python executable to run `python/faltoo_bridge.py`.

Rationale:

- This matches the Python environment where FaltooBot is installed.
- This mirrors the Neovim plugin's behavior.

## Status / Mode Line

Expose a status string, e.g.:

```elisp
(faltoo-status-string)
```

Possible status components:

- answering
- N pending comments
- pending request/error status

Use `global-mode-string` or a minor-mode lighter for initial mode-line integration.

Avoid aggressively modifying `frame-title-format` by default. If frame-title updates are added, make them opt-in.

## Quit Guard

Use Emacs-native quit hooks rather than a hidden modified buffer.

Implement with:

```elisp
kill-emacs-query-functions
```

Warn/confirm when there is:

- a running Faltoo request
- pending review comments

Implemented with `kill-emacs-query-functions`.

Since default Ask messages send immediately, there is no pending Ask question in the MVP unless a draft feature is later added.

## Raw Session / Tree Command

Neovim has `:Faltoo tree`, which opens `messages.json` via macOS `open`.

In Emacs, prefer a clearer command:

```elisp
faltoo-open-messages-json
```

Behavior:

- Ask bridge for `messages-path`.
- Open it with `find-file`.

This is portable and more Emacs-native.


## Keybinding Philosophy

Use conservative Emacs bindings by default.

Global/prefix map idea:

```text
C-c f c   faltoo-comment
C-c f C   faltoo-file-comment
C-c f a   faltoo-ask
C-c f h   faltoo-chat
C-c f s   faltoo-submit-review-comments
C-c f m   faltoo-comments-summary
C-c f d   faltoo-delete-current-comment
C-c f D   faltoo-magit-diff-current-file
C-c f u   faltoo-review-unstaged
C-c f n   faltoo-next-comment
C-c f p   faltoo-prev-comment
```

Inside `faltoo-review-mode`, use direct single-key bindings because review buffers are read-only:

```text
a/c/s     ask, comment, submit comments
]/[/=     next hunk, previous hunk, show hunk
n/p       next/previous pending comment
N/P       next/previous review file
S/U       stage/unstage current file
H s/H r   stage/revert current hunk
```

Do not make aggressive single-key bindings global or in editable prompt buffers.

## Suggested Implementation Order

1. Package skeleton and Python bridge.
2. Bridge sync call and async streaming helpers.
3. `faltoo-chat-mode` with per-workspace transcript rendering and refresh.
4. Chat sending from repo transcripts with live streaming.
5. File reference and slash command insertion.
6. Review mode and open-unstaged files.
7. Pending review comments with compose buffer.
8. Comment overlays/fringe markers and navigation.
9. Submit review comments and stream response into the repo transcript.
10. Mode-line status and quit guard.
11. Optional transient menu.
12. Optional Magit/Ediff integrations.

## Open Questions

These are intentionally undecided and can be revisited:

- Should transcript buffers eventually become partially read-only, with only the prompt editable?
- Should we add prompt history with `M-p` / `M-n`?
- Should there be a `transient` menu in MVP or after core behavior works?
- Should Magit integration become a first-class workflow?
- Should review comment display include a separate comments list buffer?
- Should tool/status stream verbosity be user-configurable?

## Review / Stage / Unstage Pipeline

Decision: Faltoo should provide a full-file review experience inside ordinary source buffers, while Magit/Git remains responsible for actual staging and unstaging.

### Core Principle

Separate three concepts:

1. **Faltoo review set**: files currently being reviewed with Faltoo.
2. **Pending Faltoo comments**: line/range/file comments to send to FaltooBot.
3. **Git index state**: what is staged/unstaged for commit.

Faltoo owns the first two. Magit/Git owns the third.

### Full-File Review Experience

The preferred review UI is not a Magit diff buffer as the primary workspace. Instead:

- Open one changed file at a time as a normal source buffer.
- Keep the file's normal major mode and LSP/Eglot/xref/navigation behavior.
- Enable `faltoo-review-mode` in that file.
- Mark the file read-only by default while reviewing.
- Show Git change indicators in the source buffer.
- Let the user jump to definitions, use xref, search, visit related files, and navigate normally.

This matches the important property of the Neovim workflow: the user reviews a real file buffer, not only a patch/diff buffer.

### Diff Display in Source Buffers

Use `diff-hl` as the required integration for in-buffer Git change indicators.

Rationale:

- `diff-hl-mode` highlights uncommitted changes in the fringe/margin of ordinary file buffers.
- It supports navigating between hunks.
- It can show the current hunk.
- In Git buffers, it supports staging/unstaging changes.
- It integrates with Magit via `magit-post-refresh-hook`.
- It preserves normal source-buffer navigation and editing features.

Faltoo requires `diff-hl` for the intended review workflow and enables it in `faltoo-review-mode` buffers.

Potential integration commands:

```elisp
faltoo-next-change       ; delegate to diff-hl-next-hunk through required dependency
faltoo-prev-change       ; delegate to diff-hl-previous-hunk through required dependency
faltoo-show-change       ; delegate to diff-hl-show-hunk through required dependency
faltoo-stage-hunk        ; delegate to diff-hl-stage-current-hunk through required dependency
faltoo-revert-hunk       ; delegate to diff-hl-revert-hunk through required dependency, with confirmation
```

These commands are convenience wrappers. They should not make Faltoo a replacement for Magit.

### Magit Role

Magit remains the preferred staging/unstaging and commit UI.

Faltoo should provide easy jumps to Magit:

```elisp
faltoo-magit-status
faltoo-magit-diff-current-file
faltoo-magit-diff-review-files
```

When in a Magit diff, Magit already supports visiting the corresponding file/worktree location. This is useful as a secondary workflow, but the primary Faltoo review experience should still be source-buffer-first.

### Staging/Unstaging Policy

Faltoo must not auto-stage assistant edits.

Staging/unstaging should be available from the source review buffer, but delegated to existing Git tooling:

- File-level stage: prefer Magit (`magit-stage-file`) through required dependency; otherwise run `git add -- <file>`.
- File-level unstage: prefer Magit (`magit-unstage-file`) through required dependency; otherwise run `git restore --staged -- <file>`, with `git reset -q HEAD -- <file>` as fallback.
- Hunk-level operations: delegate to `diff-hl` commands. If a complex index state does not map cleanly from the source buffer, open Magit diff rather than implementing custom patch application.

Faltoo should provide wrapper commands such as:

```elisp
faltoo-stage-current-file
faltoo-unstage-current-file
faltoo-stage-current-hunk
faltoo-unstage-current-hunk
faltoo-revert-current-hunk
```

After any staging/unstaging/revert operation:

1. Refresh `diff-hl` indicators in review buffers.
2. Refresh Magit buffers if Magit is loaded/open.
3. Refresh Faltoo mode-line/status.
4. Keep the same Faltoo review set unless the user explicitly refreshes it.

After FaltooBot responds and possibly edits files:

1. Reload review buffers from disk.
2. Refresh Git change indicators.
3. Keep review files in the Faltoo review set.
4. Let the user inspect changes in source buffers and/or Magit.
5. Let the user stage/unstage explicitly using Magit, `diff-hl` hunk commands.

### MVP Scope

MVP should implement:

- `faltoo-review-unstaged`: open unstaged files as ordinary source buffers.
- `faltoo-review-mode`: source-buffer review minor mode.
- `diff-hl` cooperation in review buffers.
- Commands to jump between Faltoo comments.
- Commands to jump between Git hunks through `diff-hl`.
- Commands to stage/unstage the current file from the review buffer.
- Hunk-level stage/unstage/revert wrappers via `diff-hl`.
- Command to open Magit status.

MVP should not implement:

- A custom staging UI.
- A custom hunk-staging engine or patch application engine.
- Staged-diff review as the primary workflow.
- Auto-staging assistant edits.

### Future Enhancements

Possible future work:

- Better Magit section integration for Faltoo review files/comments.
- A review-file navigator showing one file at a time.
- `diff-hl` inline hunk preview integration.
- Commands to stage all Faltoo review files, with confirmation.
- Optional Ediff workflow for assistant-generated changes.
- Staged-diff review mode for advanced workflows.

## Personal-Use Implementation Policy

This plugin is for one primary user. Be opinionated and optimize for the desired workflow, not broad compatibility.

Decisions:

- Target the latest stable Emacs available at implementation time.
- Prefer required dependencies over complex fallbacks when they simplify the implementation.
- Do not bend over backwards to support users without the chosen packages.
- Document requirements clearly so others can install the same stack if they want to use the plugin.
- Build the fastest useful version first.

## Concrete Implementation Decisions Before MVP

### Emacs Version

Target latest stable GNU Emacs at implementation time. As of this design pass, use:

```text
GNU Emacs 30.2
```

Do not spend effort supporting older Emacs versions unless the user asks later.

### Required Packages

For the intended workflow, require these packages rather than treating them as optional UX enhancements:

```text
posframe    ; ask/comment/last-response popups
magit       ; staging, unstaging, status, diff workflows
diff-hl     ; in-buffer Git change highlighting and hunk navigation
```

Optional/later:

```text
transient   ; command menu, if useful after core workflow works
```

### Bridge

Copy/adapt the `faltoo.nvim` Python bridge into this repo and modify as needed for Emacs.

Use the same structured command model:

```text
messages
messages-path
unstaged-files
append-review
append-message
slash-commands
```

### Workspace Detection

Workspace is the Git repository root. If no Git repository is present, report an error.

Do not implement complicated fallback workspace detection for MVP.

### Review Set

`faltoo-review-unstaged` opens only unstaged working-tree files.

`faltoo-review-mode` applies only to files in the current review set, not the entire repository.

### Ask Context

Only support:

1. active region, if present
2. current line, otherwise

Do not implement defun/file/buffer context for MVP.

### Ask Popup Lifecycle

Ask uses centered `posframe` input while keeping focus on code.

MVP behavior:

- `C-c C-c` sends immediately.
- Response streams in the same popup and current repo transcript. Opening Ask again rebuilds from the current source region/line instead of restoring old Ask state.
- Popup remains open after completion until closed.
- `C-g`/`C-c C-k` closes and returns focus to the source window.
- Plain `q` is not a close key because it must remain typeable in editable popups.

Follow-up support is implemented for completed Ask and last-response popups. Ask follow-ups reuse the original code context while that popup is open; last-response follow-ups send a plain chat message and preserve typed drafts across close/reopen.

### Comment Input and Marking

Comments also use `posframe` input.

Lines/ranges with pending Faltoo comments must be visibly marked in source buffers.

Future highlight goal:

- added lines
- removed lines
- staged lines
- review-comment lines

Use `diff-hl` as the base Git highlighting package and integrate/extend highlighting later once the working plugin exists.

### Transcript

`*Faltoo: repo-name*` remains the full transcript/history buffer for that repo.

Implemented preference:

- Keep it editable/interactable like `gptel`.
- Render canonical history plus an editable `# User` prompt at the bottom.
- `C-c C-c` submits only the current prompt.

The source-buffer workflow remains primary either way.

Transcript loading defaults to recent user turns. `C-c C-l` inside a repo transcript doubles the number of visible turns; a numeric prefix sets the exact turn count.

### Keybindings

Initial keybindings can be adjusted later. Choose a seamless code-first flow during implementation.

Use `C-c f` as the main prefix unless a better local-map flow emerges.

### Tests

Prefer behavior-oriented ERT tests with descriptive scenario names.

Tests should read like BDD specifications, for example:

```elisp
(ert-deftest faltoo-ask-uses-active-region-when-present () ...)
(ert-deftest faltoo-review-unstaged-enables-review-mode-only-for-review-files () ...)
(ert-deftest faltoo-stream-routes-ask-output-to-popup () ...)
```

Prioritize readability of test intent over exhaustive low-level assertions.

### Package Name

Main package file:

```text
faltoo.el
```

Main feature:

```elisp
(provide 'faltoo)
```
