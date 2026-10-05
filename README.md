# faltoo-emacs

Code-first Emacs client for FaltooBot/FaltooChat and Claude Code. Ask about code in popups, batch review comments, and keep the transcript available as history.

## Setup

Requires Emacs 30.2, `posframe`, `magit`, `markdown-mode`, Git, the system `file` command, and an installed FaltooBot Python environment. This is a personal-use plugin, not a general compatibility layer.

```elisp
(add-to-list 'load-path "/path/to/faltoo-emacs")
(require 'faltoo)
```

Workspaces follow the buffer's Git root, or its folder outside Git. Generic chat uses `faltoo-generic-chat-directory`. Different workspaces can answer independently.

`faltoo-faltoobot-command` defaults to released `faltoobot` on PATH. `C-c f b` selects release/local/custom per workspace; `faltoo-local-faltoobot-command` points to the local venv's `faltoochat`. Use executable paths, not shell aliases. Local answering status is `Faltoo-beta:answering`.

`C-c f b` can also select the Claude Code core, or set `(setq faltoo-faltoobot-command 'claude)` to make it the default. It runs `faltoo-claude-command` (`claude`) headless with `bypassPermissions`, on the released FaltooBot's Python, which still provides the saved prompts and Git helpers. Each workspace continues its most recent Claude session in that directory; `/reset`, `/resume`, and `/name` share sessions and names with the CLI's `claude -r`. `/tree` is not available for Claude yet. `C-c p` also lists `~/.claude/commands`. Switching sessions or core asks first if Claude background tasks are running. The status shows `Faltoo-Claude`. After changing the Python bridge, `C-c f R` restarts the workspace's daemon.

With websocket mode enabled in FaltooBot, each workspace keeps a bridge daemon for requests and notifications. Queue/notification support targets this mode. Claude workspaces always use a daemon. It keeps one `claude` process alive so background tasks survive between turns, and Claude's answers to finished tasks stream in as background updates. Cancelling interrupts the turn without killing background tasks. Claude daemons expire after the idle timeout once no background task is running. Switching core stops that workspace's daemon. `faltoo-reload` reloads Elisp without stopping daemons or restarting Emacs.

## Main bindings

All use the `C-c f` prefix:

| Key | Action |
|---|---|
| `a` / `l` | Ask about selected/current full lines / show last response |
| `c` / `C` | Line/region comment / file comment |
| `s` / `m` / `d` | Queue comments / list comments / delete at point |
| `n` | Next comment |
| `h` / `i` / `o` | Workspace transcript / generic chat / choose folder |
| `j` / `p` | Open queue / pause queue |
| `q` | Cancel this workspace's answer |
| `A` | Open a Claude sub-agent's conversation (the one on an `Agent:` line, or pick one); `g` refreshes |
| `u` / `x` | Start or refresh unstaged review / stop review |
| `g` | Magit status |
| `]` / `[` | Next/previous change |
| `S` / `U` | Stage/unstage file |
| `b` / `r` / `R` | Select core / reload plugin / restart workspace daemon |

Ask/comments also work on transcript selections. Snippets contain full lines; review snippets mark additions/deletions with `+`/`-`. Saving an empty comment deletes it. Comments submit in creation order and remain separate between workspaces.

## Review

`C-c f u` opens cached, read-only full-file buffers with inline deletions and staged hunks. Syntax colors remain intact; backgrounds show green/red changes and muted blue staging. Source buffers stay editable. Comments share source-file identity and survive stopping review. Generated buffers do not provide full source-buffer LSP support.

Non-text files show their path; supported images display inline. Undo is disabled only in generated reviews. Assistant completion does not refresh these buffers.

Single keys in review:

| Key | Action |
|---|---|
| `n` / `p` | Next/previous file |
| `]` / `[` / `=` | Next/previous hunk / recenter hunk |
| `g` / `G` | Top/bottom |
| `a` / `l` | Ask / last response |
| `c` / `C` | Line/region comment / file comment |
| `m` / `d` | Comment list / delete comment |
| `N` / `P` | Next/previous comment |
| `s` / `u` | Stage/unstage current or selected hunks |
| `S` / `U` | Stage/unstage whole file |
| `r` / `R` | Refresh current/all loaded review files |
| `o` | Cycle full → removed → added → full; keep unchanged context |
| `D` / `h` / `x` | Magit file diff / transcript / stop review |

Use **`C-c f s`** to submit comments (`s` alone stages). Magit uses three context lines, so nearby changes may stage/unstage together. Git actions rebuild the current review; `r`/`R` preserve scroll offsets where possible. Faltoo never auto-stages assistant edits.

## Popups, transcript, and queue

Popups are centered, editable Markdown. `C-g` or `C-c C-k` closes them and returns focus. Ask rebuilds from the current selection each time; last-response follow-up drafts survive close/reopen.

| Binding | Where | Action |
|---|---|---|
| `C-c C-c` | Popup/transcript | Send, save comment, or send follow-up |
| `C-c C-f` | Popup/transcript | Insert file reference |
| `C-c /` | Popup/transcript | Run session command |
| `C-c p` | Popup/transcript | Paste saved prompt template |
| `C-c C-r` | Transcript | Reload history |
| `C-c C-l` | Transcript | Double loaded turns; numeric prefix sets count |
| `C-c C-p` / `C-c C-n` | Transcript | Previous/next user message |
| `C-c C-c` | Queue | Resume FIFO consumption |

Ask answers stream in the popup and transcript; comment batches stream only in the transcript. Completed answers show elapsed time and available Codex quota or Claude limits. Only unmodified source buffers in that workspace reload after completion.

The queue is an editable text buffer shared by prompts, finalized comments, and notifications. Opening it does not pause it. User turns enter history when consumed; success starts the next entry, cancellation/error pauses. Finalizing comments clears their highlights and makes queue text the source of truth. Notifications display as `Background Update` sections. Emacs confirms quitting if work remains.

Comment-list keys: `RET` jump, `e` edit, `d` delete, `g` refresh.

## Session commands and tree

Use `C-c /` for `/reset`, `/resume`, `/name`, `/tree`, and `/status`. Use `C-c p` to paste a saved prompt for editing. Typed slash text is sent as ordinary prompt text.

`/tree` opens a compact, no-wrap `messages.json` inspector in another window. Full payloads load for inspection/search; token view shows colored, comma-formatted input/output/cached/total counts.

| Key | Tree | Detail |
|---|---|---|
| `TAB` / `RET` | Inspect row | — |
| `u` / `U` | Previous/next user | Same |
| `a` / `A` | Previous/next assistant answer | Same |
| `p` / `n` | — | Previous/next visible row |
| `/` or `C-c s` | Search backing messages | — |
| `T` | Toggle token view | — |
| `o` | Open raw JSON at selected item | Same |
| `D` | Back up and prune from row onward | — |
| `g` | Refresh | — |
| `C-c C-k` | — | Close |

## Testing

```sh
emacs -Q --batch -l test/faltoo-behavior-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -l test/faltoo-performance-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -l test/faltoo-review-git-test.el -f ert-run-tests-batch-and-exit
python3 test/faltoo-bridge-behavior-test.py
emacs -Q --batch -l test/load-smoke.el
emacs -Q --batch -l test/byte-compile-smoke.el
rm -f *.elc
```

The real-Git suite checks index/worktree contents using installed Magit, not mocked Git success. Architecture is documented in `docs/design-decisions.md`; contributor instructions are in `AGENTS.md`.
