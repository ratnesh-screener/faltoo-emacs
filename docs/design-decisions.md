# Design decisions

Authoritative behavior reference. README covers usage; AGENTS covers code ownership and development rules.

## Direction

Faltoo is a code-first Emacs client for FaltooBot and Claude Code, inspired by `faltoo.nvim`. Borrow plain-buffer interaction from gptel, not its provider architecture: the selected core (FaltooBot or Claude Code) owns sessions, tools, configuration, and history.

Use normal Emacs buffers, local modes, completion, overlays, and process filters. The global mode installs the command prefix only. Do not wrap the TUI, convert Markdown to Org, or build broad compatibility layers. Target this user's Emacs 30.2 setup with Magit, posframe, and markdown-mode.

## Workspace and transport

- Use the current buffer's Git root; outside Git, inform once and use its folder. Directory selection opens that workspace without first visiting a file.
- Generic chat is anchored at `faltoo-generic-chat-directory`, not the current source repo.
- Transcripts and popups retain their workspace in `default-directory`. Running requests, queues, comments, and core overrides are scoped by workspace.
- Resolve Python from the selected FaltooBot command's shebang. Run our bridge with that interpreter and import FaltooBot directly; do not scrape CLI/TUI output.
- Release/local/custom core selection affects one workspace. The global status names only the core (`FaltooBot`, local `beta`, or `Claude`); the transcript's mode name already says Faltoo. Switching core clears capability caching and stops that workspace daemon; plugin reload does not.
- Websocket configuration selects a persistent bridge daemon per workspace. JSONL requests/events carry request IDs and terminal completion events. FaltooBot owns websocket and hook behavior through its public streaming entrypoint.
- FaltooBot daemons poll notifications and expire after 30 idle minutes. Cancellation stops only the current workspace process. Other workspaces continue independently. `C-c f R` stops the current workspace's daemon so the next prompt starts one with fresh bridge code.
- Other bridge calls use one-shot processes. Queue and notification support need only work with websocket-enabled workspaces.

## Claude Code core

- `claude_bridge.py` keeps `faltoo_bridge.py`'s commands and turn events (answer, tool, done, complete); only its daemon's prompt, notification, and turn announcements are Claude-specific, handled in the request layer. It runs on the released FaltooBot's Python and reuses its saved prompts and Git helpers, importing FaltooBot only for those: helpers both bridges share live in FaltooBot-free `bridge_common.py`, because importing FaltooBot costs about 0.4 s per call. Do not scrape the TUI: drive `claude -p` with stream-json input and output.
- One long-lived `claude` child per workspace daemon. Background tasks live inside it, so cancel sends a stream-json interrupt instead of killing it, and the daemon owns its idle expiry, waiting for running background tasks. Background updates come from Claude itself; the Claude daemon does not poll FaltooBot notifications.
- Claude workspaces are stream-shaped: the bridge translates Claude's turns without tracking requests. Emacs keeps its editable queue but has one prompt in flight, sent when no turn is open. As for FaltooBot, submitting shows the `User` block and opens the answering section; the turn after Claude echoes that prompt streams into it, its popup, and its callback. A turn Claude starts before that echo also streams into the open section (rare; accepted). Otherwise each turn opens one Assistant section. A turn starting without a prompt echo was started by Claude, e.g. after a background task finished, and is headed by a `Background Update`. A notification folded into a running turn is an inline line, live and in history; a prompt taken mid-turn ends that turn. If the daemon exits with a prompt in flight, the prompt returns to the paused queue; if Claude or the bridge's reader fails, the daemon exits so Emacs reports it instead of answering forever.
- Claude's session files are canonical history. The bridge remembers the selected session per workspace and otherwise continues Claude's most recent session for that directory. Runs use `bypassPermissions` until Emacs has a permission prompt.
- `/reset`, `/resume`, and `/name` work on Claude's files: names are appended `custom-title` records, so Emacs and the CLI's `/resume` share them. Labels prefer the custom title, then Claude's AI title, then the first prompt. A session cannot be named before its first message because Claude can neither resume nor reuse an id whose file has no conversation. `/status` shows the session, model, context size, and last usage from the session file; it omits cost because Claude writes it only when a process exits. `/tree` reads Claude's JSONL: the bridge streams one row per record, keyed by line and mapped onto FaltooBot's row types, skipping bookkeeping records and counting a response's usage once (input includes cache reads, shown as cached). Full records load lazily one line each; open-raw jumps to the line; pruning backs up, keeps earlier lines verbatim, and stops the workspace daemon first because its `claude` process holds the session. Claude resumes cleanly after an interrupted tool call, so pruning mainly serves amending a prompt.
- `/reset`, `/resume`, and core switches stop the workspace's Claude daemon so the next message starts the selected session. When background tasks are running, stopping asks first; declining changes nothing.
- `C-c p` lists FaltooBot's saved prompts, then `~/.claude/commands/*.md` (frontmatter stripped), with the source as a completion annotation.
- Tool summaries show repo files relative to the workspace and other paths in full.
- `/steer` bypasses the queue: the daemon writes it at once as a `steer` command, and Claude takes it at its next step. The bridge shows its mid-turn echo as an inline `Steer:` line instead of ending the turn (Claude stores it as a `queued_command` prompt attachment, rendered the same in history); taken after the turn ended, it is an ordinary next turn.
- `/btw` runs a one-shot `claude -p --resume --fork-session --no-session-persistence`, so the side answer sees the saved session but is never written back; it re-reads the context from Claude's prompt cache, keeping it cheap while the cache is warm. Its reusable buffer is shown without focus, and a newer question replaces it and ignores older streams.
- Sub-agents are inspected from Claude's saved `subagents/agent-*.jsonl` files, not the live stream: `C-c f A` opens the one on a transcript `Agent:` line or one picked by description, rendered like history in a read-only buffer that `g` re-reads while it runs. The transcript itself shows only the `Agent:` line and the outcome.

## Queue

One editable Markdown buffer per workspace stores page-separated entries. Manual prompts, finalized comment batches, and notifications all use it; there is no parallel text queue model.

Opening it does not pause it. An explicit command pauses consumption; resume starts FIFO consumption when idle. Each consumed entry leaves the queue, enters the transcript, and starts one request. Successful completion starts the next entry; cancellation or failure pauses the queue.

FaltooBot notification claim/ack/requeue remains in Python. Emacs queues formatted notification text. Display uses a `Background Update` heading and quoted metadata, omitting the protocol's `## message` wrapper; FaltooBot still receives the original prompt.

## Ask and comments

- Ask accepts only the current line or region, expanded to full lines. Include both endpoint lines even when point/mark is at the start of a line. Infer fenced-code language from the source mode. Review snippets prefix additions/deletions with `+`/`-`.
- Ask and comments work in source, review, and transcript buffers. Transcript excerpts use `Your response`, not filename/range boilerplate.
- Popups are centered, focusable, editable, padded, and bordered. Closing returns focus to the prior window. No plain `q` binding in editable buffers. Submission deactivates the source selection.
- Short command inputs (`/steer`, `/btw`) use one shared input popup, `faltoo-popup-read`, instead of the minibuffer: it keeps the workspace, refuses empty text unless the caller allows it, and hands the trimmed text to a callback. A steer submitted after its answer finished goes in as the next prompt.
- Ask always rebuilds context on invocation. Its answer streams in the popup and transcript. Follow-ups in that popup retain code context.
- Last-response popups preserve follow-up drafts across close/reopen and send follow-ups as plain chat prompts.
- Comments support line/range/file targets. Source and review buffers share workspace/canonical-path identity. Pending lines have overlays, not diagnostic/fringe markers.
- Reopening an existing comment edits it. Saving empty text or deleting at point removes the comment and its highlight.
- Submit comments in creation order. Finalization builds one queue entry and clears pending comments/overlays immediately; subsequent edits belong to the queue text.
- Batched comment answers stream to the transcript and mode-line, not a popup. Stopping review preserves pending comments.

## Transcript and rendering

Per-workspace `*Faltoo: repo-name*` buffers and generic `*Faltoo Chat*` are editable history views with a final user prompt. Sending uses that prompt, not arbitrary buffer edits. The core's persisted history remains canonical; refreshing restores it. Load recent user turns first; load-more doubles the count or accepts an exact numeric prefix.

Use shared Markdown styling in transcript and popups: hidden markup and native code fontification. Let font-lock do its work; no synchronous whole-buffer fontification. Batch stream writes and do not force point or scroll to the bottom during append/completion.

Keep one assistant section per response, labeled `answering` while active. Loaded history should match live rendering; reasoning summaries stay hidden. User/assistant headings share the same line background but distinct text colors; background updates have their own heading color.

Tool summaries are consecutive blockquote lines, without individual headings. Separate prose from tool groups with blank lines. Hook feedback is complete quoted Markdown with short separators above/below and its own muted face; route live hooks by event metadata. Persisted hook identification still uses the upstream feedback prefix until upstream stores metadata.

Horizontal rules separate turns. Completed answers append elapsed time and any streamed rate limits (Codex quota or Claude's 5h/7d limits) to a quoted footer; they do not require another LLM call. Errors appear in the transcript.

Completion reloads only unmodified source buffers in that workspace. Leave unsaved edits to Emacs conflict handling. Do not refresh generated reviews automatically.

## Review

Review opens unstaged files one at a time in cached, generated read-only buffers. Keep the source major mode and full worktree context; insert removed rows inline and include already staged hunks. Generated buffers do not promise real-file xref/LSP support.

- Green/red backgrounds mark added/removed lines; muted blue marks staged rows. Low-priority background-only overlays preserve syntax colors, selection, and comments.
- The `file` command classifies content before visiting sources. Non-text files show their path; supported images also display inline. Cache type for the buffer's lifetime.
- Disable undo only in generated reviews. Navigation reuses buffers without rerendering.
- View cycling hides added or removed diff rows while keeping unchanged context. Preserve the view across refresh.
- Current/all-file refresh preserves numeric point/window offsets as a best effort. Restarting review reconciles the file set and closes stale buffers using the old workspace's ownership.
- Closing review returns comments to source buffers and releases generated buffers. Starting from a transcript uses another window.

Magit owns index changes. Hunk operations use its real diff sections with three context lines; nearby edits may stage/unstage together. Regions apply all selected hunks; whole-file operations remain separate. After Git actions, rebuild the current review from index/worktree state rather than toggling flags. Never auto-stage assistant edits.

Each review owns one hidden plain buffer containing staged and unstaged Magit section groups. Both rendering and staging use their actual hunk sections; section ancestry identifies the Git state without running a Magit major mode. A rendering pass maps worktree line markers back to index lines; the staged pass uses those markers, keeping separate snapshots where staged additions were later deleted. There is no separate hunk-header parser, custom hunk structure, or staging translation. Refresh reuses the backing buffer; closing review kills it.

## Commands and inspection

`C-c /` runs `/reset`, `/resume`, `/name`, `/tree`, or `/status`. These have Emacs-specific plumbing; adding upstream TUI commands does not automatically add them here. Resume uses the core's recency ordering. Status is a temporary popup.

`C-c p` pastes saved prompt text for editing. Typed slash text is an ordinary prompt. File insertion uses completion and inserts a backtick-wrapped relative path.

The tree inspector derives from `special-mode`, not `tabulated-list-mode`. Open it in another window, stream compact rows without redrawing old rows, and load full payloads lazily for detail/search/prune. Include all message types, truncate lines even in split windows, use native line numbers and current-line highlighting, uppercase short roles, colored types, and muted previews.

Token view filters to usage-bearing rows, puts colored/comma-formatted input/output/cached/total columns before a short preview. Detail navigation follows visible rows; user/answer navigation wraps. Search reads backing messages, not previews. Raw-file opening centers on the selected item. Pruning backs up history, removes the selected item onward, and refreshes the transcript at the bottom.

Emacs confirms quitting with active requests, pending comments, or queued entries. Keys and test commands live in README.
