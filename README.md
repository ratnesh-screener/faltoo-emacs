# faltoo-emacs

Code-first Emacs integration for FaltooBot/FaltooChat.

This is a personal-use plugin optimized for the author's workflow. It targets GNU Emacs 30.2 and assumes these packages are installed:

- `posframe`
- `magit`
- `diff-hl`
- `markdown-mode`

## Load

```elisp
(add-to-list 'load-path "/Users/ratneshrastogi/screener_dev/faltoo-emacs")
(require 'faltoo)
```

The author's `~/.emacs.d/init.el` already has a `use-package faltoo` block.

## Main flow

Open a file in a Git repo, then run commands from that source buffer. Faltoo uses that file's Git root as the FaltooBot workspace/session. Open files from another repo to talk to that repo's persisted FaltooChat session.

For review, open a Git repo with unstaged changes, then run:

```text
M-x faltoo-review-unstaged
```

This opens changed files as normal source buffers, enables `faltoo-review-mode`, makes them read-only, and enables `diff-hl` indicators.

## Keybindings

Normal source buffers use main prefix: `C-c f`

```text
C-c f u   review unstaged files
C-c f x   stop review session
```

Review buffers are read-only, so review actions use direct keys:

```text
a     ask about active region/current line
l     show last assistant response
c     add review comment on line/region
C     add file-level review comment
m     show pending comments summary
d     delete pending comment at point
s     submit pending review comments
h     open transcript
r     reload Faltoo plugin code
g     Magit status
D     Magit diff for current file
]     next Git hunk
[     previous Git hunk
=     show Git hunk
n     next Faltoo comment
p     previous Faltoo comment
N     next review file
P     previous review file
S     stage current file
U     unstage current file
H s   stage current hunk
H r   revert current hunk
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

In workspace transcript buffers, named like `*Faltoo: repo-name*`:

```text
C-c C-c   send current prompt
C-c C-r   refresh transcript
C-c C-l   load more transcript turns; numeric prefix sets exact turn count
C-c C-p   previous user message
C-c C-n   next user message
C-c C-f   insert file reference
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
/reset        start a fresh session for the current Git workspace
/resume       pick another session for the current Git workspace
/name         rename the current session; empty name clears it
```

Manually typed slash text is sent to the LLM as normal prompt text. Use `C-c /` for session commands.

## Notes

- Source buffers are the primary UI.
- Transcript/history buffers are per Git repo, named like `*Faltoo: repo-name*`, and receive long review streams for that repo.
- Ask always rebuilds from the active region/current line and streams responses in the centered posframe and transcript. The last-response popup preserves follow-up drafts after close/reopen.
- Completed assistant transcript footers include elapsed time and the latest streamed Codex limit when available, e.g. `> Assistant took: 20.0s` / `> Remaining limit: 5h = 98%`.
- Review-comment submission streams to the current repo transcript and status/mode-line.
- After a Faltoo request finishes, unmodified open buffers in that repo are refreshed from disk so assistant edits do not trigger stale-file save prompts. Buffers with unsaved local edits are left alone.
- Faltoo never auto-stages changes.

## Quit guard

Emacs asks before quitting while a Faltoo request is running or review comments are pending.

## Popup UI

Ask and comment popups use centered `posframe` windows in `markdown-mode` with local pretty Markdown settings enabled. The header shows file/range context, code is shown above the editable question/comment area, and the footer lists the important keys.

Pending review-comment lines are highlighted directly.

## Full-line Git highlights

Inside `faltoo-review-mode`, `diff-hl` is configured buffer-locally and redrawn to highlight full changed lines instead of only the gutter.

Review buffers also show a header line like `Faltoo Review Faltoo[1/N]` so the review state is visible even if the modeline hides minor modes.
