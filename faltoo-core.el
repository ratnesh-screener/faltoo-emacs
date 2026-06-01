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

(defun faltoo-relative-file (file)
  "Return FILE relative to the active workspace."
  (file-relative-name (file-truename file) (faltoo-workspace)))

(defun faltoo-current-file ()
  "Return the current buffer file or signal an error."
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (file-truename buffer-file-name))

(defun faltoo-set-status (status)
  "Set Faltoo STATUS and refresh UI."
  (setq faltoo-status status)
  (force-mode-line-update t))

(defun faltoo-status-string ()
  "Return a compact status string for mode-line use."
  (let ((parts nil)
        (workspace (locate-dominating-file default-directory ".git")))
    (when (and workspace (faltoo-workspace-submitting-p (file-truename workspace)))
      (push "answering" parts))
    (when (and (boundp 'faltoo-comments) faltoo-comments)
      (push (format "%d comment%s" (length faltoo-comments)
                    (if (= (length faltoo-comments) 1) "" "s"))
            parts))
    (if parts
        (concat " Faltoo:" (string-join (nreverse parts) " · "))
      "")))

(unless (member '(:eval (faltoo-status-string)) global-mode-string)
  (add-to-list 'global-mode-string '(:eval (faltoo-status-string)) t))

(defun faltoo-reload-review-buffers ()
  "Reload live Faltoo review buffers from disk and refresh review UI."
  (dolist (file faltoo-review-files)
    (let ((buf (find-buffer-visiting file)))
      (when buf
        (with-current-buffer buf
          (let ((buffer-read-only nil))
            (revert-buffer :ignore-auto :noconfirm))))))
  (run-hooks 'faltoo-after-reload-review-buffers-hook))

(provide 'faltoo-core)
;;; faltoo-core.el ends here
