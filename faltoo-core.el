;;; faltoo-core.el --- Core state for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defgroup faltoo nil
  "Code-first Faltoo integration."
  :group 'tools)

(defvar faltoo-workspace nil
  "Last Faltoo workspace seen by this Emacs session.
The active workspace is always recomputed from `default-directory'.")
(defvar faltoo-status "idle")
(defvar faltoo-submitting nil)
(defvar faltoo-submitting-workspaces (make-hash-table :test #'equal))
(defvar faltoo-review-files nil)
(defvar faltoo-current-review-index 0)
(defvar faltoo-last-assistant-message "")
(defvar faltoo-last-assistant-messages (make-hash-table :test #'equal))
(defvar faltoo-last-rate-limits (make-hash-table :test #'equal))
(defvar faltoo-after-reload-review-buffers-hook nil
  "Hook run after Faltoo reloads review buffers from disk.")

(defun faltoo-git-root ()
  "Return the current Git root or signal an error."
  (let ((root (locate-dominating-file default-directory ".git")))
    (unless root
      (user-error "Faltoo requires a Git repository"))
    (file-truename root)))

(defun faltoo-workspace ()
  "Return the active Faltoo workspace for `default-directory'."
  (setq faltoo-workspace (faltoo-git-root)))

(defun faltoo-workspace-submitting-p (&optional workspace)
  "Return non-nil when WORKSPACE has a running Faltoo request."
  (gethash (or workspace (faltoo-workspace)) faltoo-submitting-workspaces))

(defun faltoo-any-submitting-p ()
  "Return non-nil when any Faltoo workspace has a running request."
  (or faltoo-submitting (> (hash-table-count faltoo-submitting-workspaces) 0)))

(defun faltoo-set-workspace-submitting (workspace running)
  "Mark WORKSPACE as RUNNING or idle."
  (if running
      (puthash workspace t faltoo-submitting-workspaces)
    (remhash workspace faltoo-submitting-workspaces))
  (setq faltoo-submitting (> (hash-table-count faltoo-submitting-workspaces) 0)))

(defun faltoo-reset-workspace ()
  "Use the Git root of `default-directory' as current workspace."
  (interactive)
  (setq faltoo-workspace (faltoo-git-root)))

(defun faltoo-active-workspace ()
  "Return the workspace attached to the current Faltoo buffer or source buffer."
  (or (and (boundp 'faltoo-chat-workspace) faltoo-chat-workspace)
      (faltoo-workspace)))

(defun faltoo-relative-file (file)
  "Return FILE relative to the active workspace."
  (file-relative-name (file-truename file) (faltoo-workspace)))


(defun faltoo-current-line-range ()
  "Return full-line range for active region or current line.
The result is (BEG END START-LINE END-LINE CODE)."
  (if (use-region-p)
      (let* ((beg (region-beginning))
             (end (region-end))
             (last-pos (if (and (> end beg)
                                (save-excursion (goto-char end) (bolp)))
                           (1- end)
                         end))
             (line-beg (save-excursion (goto-char beg) (line-beginning-position)))
             (line-end (save-excursion (goto-char last-pos) (line-end-position))))
        (list line-beg line-end
              (line-number-at-pos line-beg)
              (line-number-at-pos last-pos)
              (buffer-substring-no-properties line-beg line-end)))
    (let ((beg (line-beginning-position))
          (end (line-end-position)))
      (list beg end (line-number-at-pos) (line-number-at-pos)
            (buffer-substring-no-properties beg end)))))

(defun faltoo-current-file ()
  "Return the current buffer file or signal an error."
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (file-truename buffer-file-name))

(defun faltoo-current-language ()
  "Return the Markdown fence language for the current buffer."
  (let ((name (symbol-name major-mode)))
    (if (string-match "\\`\\(.+?\\)\\(?:-ts\\)?-mode\\'" name)
        (match-string 1 name)
      "text")))

(defun faltoo-set-status (status)
  "Set Faltoo STATUS and refresh UI."
  (setq faltoo-status status)
  (force-mode-line-update t))

(defun faltoo-status--label (workspace)
  "Return the mode-line label for WORKSPACE."
  (let ((command (and (boundp 'faltoo-faltoobot-command) faltoo-faltoobot-command)))
    (when (and workspace
               (boundp 'faltoo-faltoobot-workspace-commands)
               (hash-table-p faltoo-faltoobot-workspace-commands))
      (setq command (or (gethash workspace faltoo-faltoobot-workspace-commands) command)))
    (if (and command
             (boundp 'faltoo-local-faltoobot-command)
             (equal command faltoo-local-faltoobot-command))
        "Faltoo-beta"
      "Faltoo")))

(defun faltoo-status-string ()
  "Return a compact status string for mode-line use."
  (let* ((parts nil)
         (workspace (or (and (boundp 'faltoo-chat-workspace) faltoo-chat-workspace)
                        (when-let ((root (locate-dominating-file default-directory ".git")))
                          (file-truename root)))))
    (when (and workspace (faltoo-workspace-submitting-p workspace))
      (push "answering" parts))
    (when (and (boundp 'faltoo-comments) faltoo-comments)
      (push (format "%d comment%s" (length faltoo-comments)
                    (if (= (length faltoo-comments) 1) "" "s"))
            parts))
    (if parts
        (concat " " (faltoo-status--label workspace) ":"
                (string-join (nreverse parts) " · "))
      "")))

(unless (member '(:eval (faltoo-status-string)) global-mode-string)
  (add-to-list 'global-mode-string '(:eval (faltoo-status-string)) t))

(defun faltoo-reload-workspace-buffers (workspace)
  "Reload unmodified file-visiting buffers under WORKSPACE from disk."
  (let ((root (file-name-as-directory (file-truename workspace))))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and buffer-file-name
                   (file-exists-p buffer-file-name)
                   (string-prefix-p root (file-truename buffer-file-name))
                   (not (buffer-modified-p))
                   (not (verify-visited-file-modtime)))
          (let ((buffer-read-only nil))
            (revert-buffer :ignore-auto :noconfirm))))))
  (run-hooks 'faltoo-after-reload-review-buffers-hook))

(defun faltoo-reload-review-buffers ()
  "Reload live Faltoo review buffers from disk and refresh review UI."
  (faltoo-reload-workspace-buffers (faltoo-workspace)))

(provide 'faltoo-core)
;;; faltoo-core.el ends here
