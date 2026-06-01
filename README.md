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

Main prefix: `C-c f`

```text
C-c f u   review unstaged files
C-c f x   stop review session
C-c f a   ask about active region/current line
C-c f l   show last assistant response
C-c f c   add review comment on line/region
C-c f C   add file-level review comment
C-c f m   show pending comments summary
C-c f d   delete pending comment at point
C-c f s   submit pending review comments
C-c f h   open transcript
C-c f r   reload Faltoo plugin code
C-c f g   Magit status
C-c f D   Magit diff for current file
C-c f ]   next Git hunk
C-c f [   previous Git hunk
C-c f =   show Git hunk
C-c f n   next Faltoo comment
C-c f p   previous Faltoo comment
C-c f N   next review file
C-c f P   previous review file
C-c f S   stage current file
C-c f U   unstage current file
C-c f H s stage current hunk
C-c f H r revert current hunk
```

In Ask/comment posframes:

```text
C-c C-c   send/save/follow-up
C-c C-k   cancel/close
C-g       close
C-c C-f   insert file reference
C-c /     insert slash command, Ask/last-response only
```

In workspace transcript buffers, named like `*Faltoo: repo-name*`:

```text
C-c C-c   send current prompt
C-c C-r   refresh transcript
C-c C-l   load more transcript turns; numeric prefix sets exact turn count
C-c C-f   insert file reference
C-c /     insert slash command
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

## Notes

- Source buffers are the primary UI.
- Transcript/history buffers are per Git repo, named like `*Faltoo: repo-name*`, and receive long review streams for that repo.
- Ask responses stream in the centered posframe, including compact status/tool lines.
- Review-comment submission streams to the current repo transcript and status/mode-line.
- Faltoo never auto-stages changes.

## Quit guard

Emacs asks before quitting while a Faltoo request is running or review comments are pending.

## Popup UI

Ask and comment popups use centered `posframe` windows in `markdown-mode` with local pretty Markdown settings enabled. The header shows file/range context, code is shown above the editable question/comment area, and the footer lists the important keys.

Pending review-comment lines are highlighted directly.

## Full-line Git highlights

Inside `faltoo-review-mode`, `diff-hl` is configured buffer-locally and redrawn to highlight full changed lines instead of only the gutter.

Review buffers also show a header line like `Faltoo Review Faltoo[1/N]` so the review state is visible even if the modeline hides minor modes.
