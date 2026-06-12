;;; faltoo.el --- Code-first Faltoo integration -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "30.2") (posframe "1.4.4") (magit "4.0.0") (diff-hl "1.9.0") (markdown-mode "2.7"))

(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-faces)
(require 'faltoo-ui)
(require 'faltoo-compose)
(require 'faltoo-chat)
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
    "faltoo-compose.el"
    "faltoo-bridge.el"
    "faltoo-chat.el"
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

(defvar faltoo-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'faltoo-ask)
    (define-key map (kbd "l") #'faltoo-show-last-response)
    (define-key map (kbd "c") #'faltoo-comment)
    (define-key map (kbd "C") #'faltoo-file-comment)
    (define-key map (kbd "s") #'faltoo-submit-review-comments)
    (define-key map (kbd "m") #'faltoo-comments-summary)
    (define-key map (kbd "d") #'faltoo-delete-current-comment)
    (define-key map (kbd "h") #'faltoo-chat)
    (define-key map (kbd "i") #'faltoo-generic-chat)
    (define-key map (kbd "b") #'faltoo-select-faltoobot-command)
    (define-key map (kbd "r") #'faltoo-reload)
    (define-key map (kbd "q") #'faltoo-request-cancel)
    (define-key map (kbd "u") #'faltoo-review-unstaged)
    (define-key map (kbd "x") #'faltoo-review-stop)
    (define-key map (kbd "g") #'faltoo-magit-status)
    (define-key map (kbd "]") #'faltoo-next-change)
    (define-key map (kbd "[") #'faltoo-prev-change)
    (define-key map (kbd "n") #'faltoo-next-comment)
    (define-key map (kbd "p") #'faltoo-prev-comment)
    (define-key map (kbd "S") #'faltoo-stage-current-file)
    (define-key map (kbd "U") #'faltoo-unstage-current-file)
    map)
  "Faltoo command prefix map.")

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
