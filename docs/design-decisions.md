# Design decisions

Authoritative behavior reference. README covers usage; AGENTS covers code ownership and development rules.

## Direction

Faltoo is a code-first Emacs client for FaltooBot, inspired by `faltoo.nvim`. Borrow plain-buffer interaction from gptel, not its provider architecture: FaltooBot owns sessions, tools, configuration, and history.

Use normal Emacs buffers, local modes, completion, overlays, and process filters. The global mode installs the command prefix only. Do not wrap the TUI, convert Markdown to Org, or build broad compatibility layers. Target this user's Emacs 30.2 setup with Magit, posframe, and markdown-mode.

## Workspace and transport

- Use the current buffer's Git root; outside Git, inform once and use its folder. Directory selection opens that workspace without first visiting a file.
- Generic chat is anchored at `faltoo-generic-chat-directory`, not the current source repo.
- Transcripts and popups retain their workspace in `default-directory`. Running requests, queues, comments, and core overrides are scoped by workspace.
- Resolve Python from the selected FaltooBot command's shebang. Run our bridge with that interpreter and import FaltooBot directly; do not scrape CLI/TUI output.
- Release/local/custom core selection affects one workspace. Local status uses `Faltoo-beta`. Switching core clears capability caching and stops that workspace daemon; plugin reload does not.
- Websocket configuration selects a persistent bridge daemon per workspace. JSONL requests/events carry request IDs and terminal completion events. FaltooBot owns websocket and hook behavior through its public streaming entrypoint.
- Daemons poll notifications and expire after 30 idle minutes. Cancellation stops only the current workspace process. Other workspaces continue independently.
- Other bridge calls use one-shot processes. Queue and notification support need only work with websocket-enabled workspaces.

## Queue

One editable Markdown buffer per workspace stores page-separated entries. Manual prompts, finalized comment batches, and notifications all use it; there is no parallel text queue model.

Opening it does not pause it. An explicit command pauses consumption; resume starts FIFO consumption when idle. Each consumed entry leaves the queue, enters the transcript, and starts one request. Successful completion starts the next entry; cancellation or failure pauses the queue.

Notification claim/ack/requeue remains in Python. Emacs queues formatted notification text. Display uses a `Background Update` heading and quoted metadata, omitting the protocol's `## message` wrapper; FaltooBot still receives the original prompt.

## Ask and comments

- Ask accepts only the current line or region, expanded to full lines. Include both endpoint lines even when point/mark is at the start of a line. Infer fenced-code language from the source mode. Review snippets prefix additions/deletions with `+`/`-`.
- Ask and comments work in source, review, and transcript buffers. Transcript excerpts use `Your response`, not filename/range boilerplate.
- Popups are centered, focusable, editable, padded, and bordered. Closing returns focus to the prior window. No plain `q` binding in editable buffers. Submission deactivates the source selection.
- Ask always rebuilds context on invocation. Its answer streams in the popup and transcript. Follow-ups in that popup retain code context.
- Last-response popups preserve follow-up drafts across close/reopen and send follow-ups as plain chat prompts.
- Comments support line/range/file targets. Source and review buffers share workspace/canonical-path identity. Pending lines have overlays, not diagnostic/fringe markers.
- Reopening an existing comment edits it. Saving empty text or deleting at point removes the comment and its highlight.
- Submit comments in creation order. Finalization builds one queue entry and clears pending comments/overlays immediately; subsequent edits belong to the queue text.
- Batched comment answers stream to the transcript and mode-line, not a popup. Stopping review preserves pending comments.

## Transcript and rendering

Per-workspace `*Faltoo: repo-name*` buffers and generic `*Faltoo Chat*` are editable history views with a final user prompt. Sending uses that prompt, not arbitrary buffer edits. FaltooBot's persisted history remains canonical; refreshing restores it. Load recent user turns first; load-more doubles the count or accepts an exact numeric prefix.

Use shared Markdown styling in transcript and popups: hidden markup and native code fontification. Let font-lock do its work; no synchronous whole-buffer fontification. Batch stream writes and do not force point or scroll to the bottom during append/completion.

Keep one assistant section per response, labeled `answering` while active. Loaded history should match live rendering; reasoning summaries stay hidden. User/assistant headings share the same line background but distinct text colors; background updates have their own heading color.

Tool summaries are consecutive blockquote lines, without individual headings. Separate prose from tool groups with blank lines. Hook feedback is complete quoted Markdown with short separators above/below and its own muted face; route live hooks by event metadata. Persisted hook identification still uses the upstream feedback prefix until upstream stores metadata.

Horizontal rules separate turns. Completed answers append elapsed time and any streamed Codex quota to a quoted footer; quota does not require another LLM call. Errors appear in the transcript.

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

`C-c /` runs `/reset`, `/resume`, `/name`, `/tree`, or `/status`. These have Emacs-specific plumbing; adding upstream TUI commands does not automatically add them here. Resume uses FaltooBot's recency ordering. Status is a temporary popup.

`C-c p` pastes saved prompt text for editing. Typed slash text is an ordinary prompt. File insertion uses completion and inserts a backtick-wrapped relative path.

The tree inspector derives from `special-mode`, not `tabulated-list-mode`. Open it in another window, stream compact rows without redrawing old rows, and load full payloads lazily for detail/search/prune. Include all message types, truncate lines even in split windows, use native line numbers and current-line highlighting, uppercase short roles, colored types, and muted previews.

Token view filters to usage-bearing rows, puts colored/comma-formatted input/output/cached/total columns before a short preview. Detail navigation follows visible rows; user/answer navigation wraps. Search reads backing messages, not previews. Raw-file opening centers on the selected item. Pruning backs up history, removes the selected item onward, and refreshes the transcript at the bottom.

Emacs confirms quitting with active requests, pending comments, or queued entries. Keys and test commands live in README.
