;;; faltoo.el --- Code-first Faltoo integration -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2") (posframe "1.4.4") (magit "4.0.0") (markdown-mode "2.7"))

(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-faces)
(require 'faltoo-ui)
(require 'faltoo-tree)
(require 'faltoo-compose)
(require 'faltoo-chat)
(require 'faltoo-queue)
(require 'faltoo-request)
(require 'faltoo-ask)
(require 'faltoo-comments)
(require 'faltoo-review)
(require 'faltoo-quit)

(defconst faltoo-root (file-name-directory (or load-file-name buffer-file-name)))

(defconst faltoo-reload-files
  '("faltoo-core.el"
    "faltoo-faces.el"
    "faltoo-ui.el"
    "faltoo-tree.el"
    "faltoo-compose.el"
    "faltoo-bridge.el"
    "faltoo-chat.el"
    "faltoo-queue.el"
    "faltoo-request.el"
    "faltoo-ask.el"
    "faltoo-comments.el"
    "faltoo-review.el"
    "faltoo-quit.el"
    "faltoo.el"))

(defun faltoo-reload ()
  "Reload Faltoo Emacs without restarting Emacs."
  (interactive)
  (dolist (file faltoo-reload-files)
    (load-file (expand-file-name file faltoo-root)))
  (message "Faltoo reloaded"))

(defvar faltoo-command-map (make-sparse-keymap)
  "Faltoo command prefix map.")

(setcdr faltoo-command-map nil)
(dolist (binding '(("a" . faltoo-ask)
                   ("l" . faltoo-show-last-response)
                   ("c" . faltoo-comment)
                   ("C" . faltoo-file-comment)
                   ("s" . faltoo-submit-review-comments)
                   ("m" . faltoo-comments-summary)
                   ("d" . faltoo-delete-current-comment)
                   ("h" . faltoo-chat)
                   ("i" . faltoo-generic-chat)
                   ("j" . faltoo-queue-open)
                   ("o" . faltoo-chat-directory)
                   ("b" . faltoo-select-faltoobot-command)
                   ("r" . faltoo-reload)
                   ("q" . faltoo-request-cancel)
                   ("u" . faltoo-review-unstaged)
                   ("x" . faltoo-review-stop)
                   ("g" . faltoo-magit-status)
                   ("]" . faltoo-next-change)
                   ("[" . faltoo-prev-change)
                   ("n" . faltoo-next-comment)
                   ("p" . faltoo-prev-comment)
                   ("S" . faltoo-stage-current-file)
                   ("U" . faltoo-unstage-current-file)))
  (keymap-set faltoo-command-map (car binding) (cdr binding)))

(define-minor-mode faltoo-mode
  "Global Faltoo command keymap."
  :global t
  :group 'faltoo
  :lighter ""
  :keymap `((,(kbd "C-c f") . ,faltoo-command-map)))

(defun faltoo-open-messages-json ()
  "Open the raw Faltoo messages JSON file."
  (interactive)
  (find-file (faltoo-bridge-messages-path)))

(faltoo-mode 1)

(provide 'faltoo)
;;; faltoo.el ends here
