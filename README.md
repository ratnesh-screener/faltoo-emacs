# faltoo-emacs

Code-first Emacs integration for FaltooBot/FaltooChat.

This is a personal-use plugin optimized for the author's workflow. It targets GNU Emacs 30.2 and assumes these packages are installed:

- `posframe`
- `magit`
- `markdown-mode`

## Load

```elisp
(add-to-list 'load-path "/Users/ratneshrastogi/screener_dev/faltoo-emacs")
(require 'faltoo)
```

The author's `~/.emacs.d/init.el` already has a `use-package faltoo` block.

## Main flow

Open a file in a Git repo, then run commands from that source buffer. Faltoo uses that file's Git root as the FaltooBot workspace/session. Outside Git, Faltoo uses the current folder and reports that fallback once. Open files from another repo/folder to talk to that workspace's persisted FaltooChat session.

For review, open a Git repo with unstaged changes, then run:

```text
M-x faltoo-review-unstaged
```

This opens one generated read-only review buffer at a time. Each buffer keeps the file's major mode, shows the complete working-tree file, inserts removed Git rows inline, and includes existing staged hunks in muted blue alongside unstaged green/red rows.

## Keybindings

Normal source buffers use main prefix: `C-c f`

```text
C-c f u   review unstaged files
C-c f x   stop review session
C-c f q   cancel running Faltoo answer stream for this repo
C-c f h   open current repo transcript
C-c f i   open generic repo-independent chat
C-c f j   open and pause this workspace's editable submission queue
C-c f o   choose a folder and open its workspace transcript
C-c f b   switch this chat's Faltoo core: release/local/custom
```

Review buffers are read-only, so review actions use direct keys:

```text
a     ask about active region/current line
l     show last assistant response
c     add review comment on line/region
C     add file-level review comment
m     show pending comments summary
d     delete pending comment at point
s     stage current hunk or selected hunks
u     unstage current hunk or selected hunks
C-c f s   submit pending review comments
h     open transcript
r     refresh current review buffer and Git state
R     refresh every loaded review buffer and Git state
g     top of review buffer
G     bottom of review buffer
D     Magit diff for current file
]     next Git hunk
[     previous Git hunk
=     show Git hunk
n     next review file
p     previous review file
N     next Faltoo comment
P     previous Faltoo comment
S     stage current file
U     unstage current file
```

In Ask/last-response posframes:

```text
C-c C-c   send/save/follow-up
C-c C-k   cancel/close
C-g       close
C-c C-f   insert file reference
C-c /     run session command
C-c p     paste saved prompt template
```

Queued prompts live in one editable buffer per workspace, named like `*Faltoo Queue: repo-name*`:

```text
C-c f j   open the queue and pause automatic consumption
C-c C-c   resume FIFO submission after editing/reordering entries
```

Manual prompts, batched review prompts, and FaltooBot background notifications use the same queue. A user turn appears in the transcript only when its queue entry starts. Successful answers consume the next entry; cancellation or failure pauses the queue.

In workspace transcript buffers, named like `*Faltoo: repo-name*`, and generic chat `*Faltoo Chat*`:

```text
C-c C-c   send current prompt
C-c C-r   refresh transcript
C-c C-l   load more transcript turns; numeric prefix sets exact turn count
C-c C-p   previous user message
C-c C-n   next user message
C-c C-f   insert file reference
C-c f c   add pending comment on selected transcript text/current line
C-c f s   submit pending comments
C-c /     run session command
C-c p     paste saved prompt template
```

In `*Faltoo Comments*`:

```text
RET       jump to source
 e        edit comment
 d        delete comment
 g        refresh summary
```


## Switching FaltooBot core

Faltoo resolves the Python environment per chat/workspace. By default each chat uses `faltoo-faltoobot-command`, which points at the released `faltoobot` command on `PATH`. To test local FaltooBot/FaltooChat changes from Emacs for only the current repo/generic chat, use:

```text
C-c f b   choose release, local, or custom Faltoo command for this chat
```

The local option defaults to:

```text
/Users/ratneshrastogi/screener_dev/FaltooBot/.venv/bin/faltoochat
```

This choice is stored per workspace, so switching one repo/generic chat does not change other chats. It affects new bridge calls for that chat; already-running processes keep the command they started with. Switching also stops that workspace's persistent websocket bridge, if one is running, so the next request uses the selected core. While a local-core chat is answering, the mode-line label changes from `Faltoo:answering` to `Faltoo-beta:answering`.

If FaltooBot config enables OpenAI websocket mode, Faltoo Emacs automatically keeps a persistent bridge process per workspace for chat/review requests. That daemon also polls FaltooBot background notifications into the workspace queue. Otherwise it uses the regular one-shot bridge process; queue and notification support intentionally targets websocket workspaces only.

This is intentionally a command path, not a shell alias; Emacs will not see shell aliases such as `faltoo_codex`.

## Reload while developing

After code changes, use:

```text
C-c f r   reload Faltoo plugin code
M-x faltoo-reload
```

This reloads all Faltoo `.el` files in dependency order, so restarting Emacs should not be necessary.

## Session commands and saved prompts

Commands and prompt templates are deliberately separate:

```text
C-c /     run a built-in FaltooChat session command
C-c p     paste a saved prompt template for editing
```

Built-in commands:

```text
/reset        start a fresh session for the current workspace
/resume       pick another session for the current workspace
/name         rename the current session; empty name clears it
/tree         inspect the current session messages
/status       show Faltoo status in a temporary popup
```

`/tree` opens immediately, then streams compact no-wrap rows with native line numbers and colored type cells.
Inside the tree: `TAB`/`RET` inspect row, `/` or `C-c s` search backing messages,
`u`/`U` previous/next user, `a`/`A` previous/next assistant answer,
`o` open raw messages.json at row, `T` toggle token bookkeeping view, `D` prune from row to end, `g` refresh.
Inside row detail: `p`/`n` previous/next visible tree row, `u`/`U` previous/next user, `a`/`A` previous/next answer, `o` open raw messages.json at current detail row, `C-c C-k` close.
Reasoning/tool-output rows are included, so visible line numbers stay continuous.

Manually typed slash text is sent to the LLM as normal prompt text. Use `C-c /` for session commands.

## Notes

- Source buffers are the primary UI.
- Transcript/history buffers are per Git repo, named like `*Faltoo: repo-name*`, and receive long review streams for that repo. `C-c f i` opens a generic `*Faltoo Chat*` session anchored at `faltoo-generic-chat-directory` for quick questions that should not use the current repo context.
- Ask always rebuilds from the active region/current line and streams responses in the centered posframe and transcript. The last-response popup preserves follow-up drafts after close/reopen.
- Completed assistant transcript footers include elapsed time and the latest streamed Codex limit when available, e.g. `> Assistant took: 20.0s` / `> Remaining limit: 5h = 98%`.
- Pending comments are scoped to the current workspace. Submission converts them into one editable queue entry and clears their source overlays; the queue text then becomes the source of truth. Transcript selections use the same batch flow.
- `C-c f q` cancels the current repo's running answer stream.
- After a Faltoo request finishes, unmodified open buffers in that repo are refreshed from disk so assistant edits do not trigger stale-file save prompts. Buffers with unsaved local edits are left alone.
- Faltoo never auto-stages changes.

## Quit guard

Emacs asks before quitting while a Faltoo request is running, review comments are pending, or queued messages remain.

## Popup UI

Ask and comment popups use centered `posframe` windows in `markdown-mode` with local pretty Markdown settings enabled. The header shows file/range context, code is shown above the editable question/comment area, and the footer lists the important keys.

Pending review-comment lines are highlighted directly.

## Full-file Git review

`faltoo-review-mode` uses generated read-only buffers rather than modifying the real source buffers. The full working-tree file remains visible, removed rows are inserted inline, and added/removed rows use Magit's theme-aware diff backgrounds while retaining normal source syntax colors. Ask and review comments map back to the real source file, so comments created from either buffer share one pending-comment list and survive stopping review.

Review buffers show a header line like `Faltoo Review Faltoo[1/N]` so the active file is always visible. Visited files are reused when navigating; press `r` when you want to regenerate them from disk and Git.
