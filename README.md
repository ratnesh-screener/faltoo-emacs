# faltoo-emacs

Code-first Emacs integration for FaltooBot/FaltooChat.

This is a personal-use plugin optimized for the author's workflow. It targets GNU Emacs 30.2 and assumes these packages are installed:

- `posframe`
- `magit`
- `diff-hl`

## Load

```elisp
(add-to-list 'load-path "/Users/ratneshrastogi/screener_dev/faltoo-emacs")
(require 'faltoo)
```

The author's `~/.emacs.d/init.el` already has a `use-package faltoo` block.

## Main flow

Open a Git repo with unstaged changes, then run:

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
C-c f s   submit pending review comments
C-c f h   open transcript
C-c f g   Magit status
C-c f ]   next Git hunk
C-c f [   previous Git hunk
C-c f =   show Git hunk
C-c f n   next Faltoo comment
C-c f p   previous Faltoo comment
C-c f N   next review file
C-c f P   previous review file
C-c f S   stage current file
C-c f U   unstage current file
```

In Ask/comment posframes:

```text
C-c C-c   send/save
C-c C-k   cancel/close
C-g       close
q         close
C-c C-f   insert file reference
C-c /     insert slash command, Ask only
```

## Notes

- Source buffers are the primary UI.
- `*Faltoo*` is transcript/history and receives long review streams.
- Ask responses stream in the posframe near code, including compact status/tool lines.
- Review-comment submission streams to `*Faltoo*` and status/mode-line.
- Faltoo never auto-stages changes.

## Quit guard

Emacs asks before quitting while a Faltoo request is running or review comments are pending.

## Popup UI

Ask and comment popups use `posframe`. The header shows file/range context, code is shown above the editable question/comment area, and the footer lists the important keys.

Pending review-comment lines are highlighted and marked with `●`.
