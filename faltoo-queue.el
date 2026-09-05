;;; faltoo-queue.el --- Editable workspace submission queues -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-ui)
(require 'markdown-mode)

(declare-function faltoo-request-consume-queue "faltoo-request")

(defvar faltoo-queue-paused-workspaces (make-hash-table :test #'equal))
(defvar-local faltoo-queue-workspace nil)
(defconst faltoo-queue-separator "\f\n")

(defvar faltoo-queue-mode-map (make-sparse-keymap))
(set-keymap-parent faltoo-queue-mode-map markdown-mode-map)
(keymap-set faltoo-queue-mode-map "C-c C-c" #'faltoo-queue-resume)

(define-derived-mode faltoo-queue-mode markdown-mode "Faltoo-Queue"
  "Editable queue of Faltoo messages for one workspace."
  (faltoo-ui-enable-pretty-markdown)
  (setq-local header-line-format
              '(:eval (format " Faltoo Queue%s · %d queued"
                              (if (faltoo-queue-paused-p faltoo-queue-workspace)
                                  " [paused]"
                                "")
                              (faltoo-queue-count faltoo-queue-workspace))))
  (add-hook 'kill-buffer-query-functions #'faltoo-queue-confirm-kill nil t))

(defun faltoo-queue-buffer-name-for (workspace)
  "Return the queue buffer name for WORKSPACE."
  (format "*Faltoo Queue: %s*"
          (file-name-nondirectory
           (directory-file-name (file-name-as-directory (file-truename workspace))))))

(defun faltoo-queue-buffer (&optional workspace)
  "Return the editable queue buffer for WORKSPACE."
  (let* ((workspace (file-name-as-directory
                     (file-truename (or workspace (faltoo-active-workspace)))))
         (buffer (get-buffer-create (faltoo-queue-buffer-name-for workspace))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'faltoo-queue-mode)
        (faltoo-queue-mode))
      (setq default-directory workspace
            faltoo-queue-workspace workspace)
      (setq-local list-buffers-directory workspace))
    buffer))

(defun faltoo-queue-count (&optional workspace)
  "Return the number of queued messages for WORKSPACE."
  (if-let ((buffer (get-buffer
                    (faltoo-queue-buffer-name-for
                     (or workspace faltoo-queue-workspace (faltoo-active-workspace))))))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (let ((count 0))
            (while (search-forward "\f" nil t)
              (setq count (1+ count)))
            count)))
    0))

(defun faltoo-queue-total-count ()
  "Return the number of queued messages across all workspaces."
  (let ((count 0))
    (dolist (buffer (buffer-list) count)
      (with-current-buffer buffer
        (when (derived-mode-p 'faltoo-queue-mode)
          (setq count (+ count (faltoo-queue-count faltoo-queue-workspace))))))))

(defun faltoo-queue-add (text workspace &optional popup-buffer on-done)
  "Append TEXT to WORKSPACE's editable queue."
  (with-current-buffer (faltoo-queue-buffer workspace)
    (goto-char (point-max))
    (unless (or (bobp) (bolp))
      (insert "\n"))
    (let ((start (point)))
      (insert faltoo-queue-separator)
      (add-text-properties start (1+ start)
                           (list 'faltoo-queue-popup-buffer popup-buffer
                                 'faltoo-queue-on-done on-done
                                 'display "────────────────\n")))
    (insert (string-trim text) "\n"))
  (force-mode-line-update t))

(defun faltoo-queue-pop (workspace)
  "Remove and return the first queued message for WORKSPACE."
  (with-current-buffer (faltoo-queue-buffer workspace)
    (save-excursion
      (goto-char (point-min))
      (when (search-forward "\f" nil t)
        (let* ((start (1- (point)))
               (popup-buffer (get-text-property start 'faltoo-queue-popup-buffer))
               (on-done (get-text-property start 'faltoo-queue-on-done))
               (text-start (progn (forward-line 1) (point)))
               (next (and (search-forward "\f" nil t) (1- (point))))
               (end (or next (point-max)))
               (text (string-trim
                      (buffer-substring-no-properties text-start end))))
          (delete-region start end)
          (force-mode-line-update t)
          (list :text text :popup-buffer popup-buffer :on-done on-done))))))

(defun faltoo-queue-paused-p (workspace)
  "Return non-nil when WORKSPACE's queue is paused."
  (gethash (file-name-as-directory (file-truename workspace))
           faltoo-queue-paused-workspaces))

(defun faltoo-queue-pause (workspace)
  "Pause automatic queue consumption for WORKSPACE."
  (puthash (file-name-as-directory (file-truename workspace)) t
           faltoo-queue-paused-workspaces)
  (force-mode-line-update t))

(defun faltoo-queue-resume ()
  "Resume the queue attached to the current buffer."
  (interactive)
  (remhash faltoo-queue-workspace faltoo-queue-paused-workspaces)
  (force-mode-line-update t)
  (faltoo-request-consume-queue faltoo-queue-workspace))

(defun faltoo-queue-open ()
  "Open and pause the current workspace's editable queue."
  (interactive)
  (let ((workspace (faltoo-active-workspace)))
    (faltoo-queue-pause workspace)
    (pop-to-buffer (faltoo-queue-buffer workspace))))

(defun faltoo-queue-confirm-kill ()
  "Confirm before discarding queued messages."
  (or (= (faltoo-queue-count faltoo-queue-workspace) 0)
      (yes-or-no-p "Discard queued Faltoo messages? ")))

(provide 'faltoo-queue)
;;; faltoo-queue.el ends here
