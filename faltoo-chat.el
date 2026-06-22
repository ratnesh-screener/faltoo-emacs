;;; faltoo-chat.el --- Faltoo transcript buffer -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)
(require 'faltoo-faces)
(require 'markdown-mode)
(require 'faltoo-compose)

(declare-function faltoo-request-message "faltoo-request")
(declare-function faltoo-request-ensure-idle "faltoo-request")

(defvar-local faltoo-chat-prompt-marker nil)
(defvar-local faltoo-chat-prompt-heading-marker nil)
(defvar-local faltoo-chat-user-overlays nil)
(defvar-local faltoo-chat-tool-overlays nil)
(defvar-local faltoo-chat-assistant-overlays nil)
(defvar-local faltoo-chat-stream-heading-marker nil)
(defvar-local faltoo-chat-stream-answer-started nil)
(defvar-local faltoo-chat-workspace nil)

(defcustom faltoo-generic-chat-directory
  (expand-file-name "faltoo-generic-chat/" user-emacs-directory)
  "Directory used for the repo-independent Faltoo chat session."
  :type 'directory
  :group 'faltoo)

(defvar faltoo-generic-chat-workspace-cache nil)

(defcustom faltoo-chat-turns 20
  "Number of recent user turns shown in the Faltoo transcript."
  :type 'integer
  :group 'faltoo)

(defvar faltoo-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'faltoo-chat-send)
    (define-key map (kbd "C-c C-r") #'faltoo-chat-refresh)
    (define-key map (kbd "C-c C-l") #'faltoo-chat-load-more)
    (define-key map (kbd "C-c C-p") #'faltoo-chat-prev-user-message)
    (define-key map (kbd "C-c C-n") #'faltoo-chat-next-user-message)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    (define-key map (kbd "C-c /") #'faltoo-run-session-command)
    (define-key map (kbd "C-c p") #'faltoo-insert-prompt-template)
    map))

(define-derived-mode faltoo-chat-mode markdown-mode "Faltoo"
  "Faltoo transcript/history buffer."
  (faltoo-ui-enable-pretty-markdown)
  (setq-local truncate-lines nil))

(defun faltoo-generic-chat-workspace ()
  "Return the repo-independent Faltoo chat workspace directory."
  (let ((directory (file-name-as-directory (expand-file-name faltoo-generic-chat-directory))))
    (unless (and faltoo-generic-chat-workspace-cache
                 (equal (car faltoo-generic-chat-workspace-cache) directory))
      (make-directory directory t)
      (setq faltoo-generic-chat-workspace-cache
            (cons directory (file-name-as-directory (file-truename directory)))))
    (cdr faltoo-generic-chat-workspace-cache)))

(defun faltoo-generic-chat-workspace-p (workspace)
  "Return non-nil when WORKSPACE is the generic chat workspace."
  (and faltoo-generic-chat-workspace-cache
       (equal (file-name-as-directory (expand-file-name workspace))
              (cdr faltoo-generic-chat-workspace-cache))))

(defun faltoo-chat-buffer-name-for (workspace)
  "Return the transcript buffer name for WORKSPACE."
  (let ((workspace (file-name-as-directory (file-truename workspace))))
    (if (faltoo-generic-chat-workspace-p workspace)
        "*Faltoo Chat*"
      (format "*Faltoo: %s*" (file-name-nondirectory (directory-file-name workspace))))))

(defun faltoo-chat-buffer (&optional workspace)
  "Return the Faltoo chat buffer for WORKSPACE."
  (let* ((workspace (file-name-as-directory (file-truename (or workspace (faltoo-workspace)))))
         (buf (get-buffer-create (faltoo-chat-buffer-name-for workspace))))
    (with-current-buffer buf
      (unless (derived-mode-p 'faltoo-chat-mode)
        (faltoo-chat-mode))
      (setq default-directory workspace
            faltoo-chat-workspace workspace)
      (setq-local list-buffers-directory workspace))
    buf))

(defun faltoo-chat--highlight-block (start end face overlays-var)
  (let ((overlay (make-overlay start end nil nil nil)))
    (overlay-put overlay 'face face)
    (push overlay (symbol-value overlays-var))))

(defun faltoo-chat--highlight-user-block (start end)
  (faltoo-chat--highlight-block start end 'faltoo-chat-user-face 'faltoo-chat-user-overlays))

(defun faltoo-chat--highlight-tool-block (start end)
  (faltoo-chat--highlight-block start end 'faltoo-chat-tool-face 'faltoo-chat-tool-overlays))

(defun faltoo-chat--highlight-assistant-block (start end)
  (faltoo-chat--highlight-block start end 'faltoo-chat-assistant-face 'faltoo-chat-assistant-overlays))

(defun faltoo-chat--insert-rule ()
  (unless (bobp)
    (unless (looking-back "\n" nil)
      (insert "\n"))
    (insert "---\n")))

(defun faltoo-chat--insert-message (message)
  (let* ((start (point))
         (role-text (or (alist-get 'role message) "message"))
         (role (capitalize role-text))
         (text (or (alist-get 'text message) "")))
    (if (string= (downcase role-text) "tool")
        (progn
          (unless (or (bobp) (looking-back "\n" nil))
            (insert "\n"))
          (setq start (point))
          (insert "> " text "\n")
          (faltoo-chat--highlight-tool-block start (point)))
      (faltoo-chat--insert-rule)
      (setq start (point))
      (insert (format "# %s" role))
      (let ((heading-end (point)))
        (insert "\n\n" text "\n\n")
        (cond
         ((string= (downcase role-text) "user")
          (faltoo-chat--highlight-user-block start heading-end))
         ((string= (downcase role-text) "assistant")
          (faltoo-chat--highlight-assistant-block start heading-end)))))))

(defun faltoo-chat--insert-user-prompt ()
  (goto-char (point-max))
  (unless (or (bobp) (bolp)) (insert "\n"))
  (let ((start (point)))
    (faltoo-chat--insert-rule)
    (setq start (point))
    (setq faltoo-chat-prompt-heading-marker (point-marker))
    (insert "# User\n\n")
    (setq faltoo-chat-prompt-marker (point-marker))
    (faltoo-chat--highlight-user-block start (line-end-position 0))))

(defun faltoo-chat-render (messages &optional workspace)
  "Render MESSAGES into the workspace transcript with an editable prompt."
  (let ((buf (faltoo-chat-buffer workspace)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (mapc #'delete-overlay faltoo-chat-user-overlays)
        (mapc #'delete-overlay faltoo-chat-tool-overlays)
        (mapc #'delete-overlay faltoo-chat-assistant-overlays)
        (setq faltoo-chat-user-overlays nil
              faltoo-chat-tool-overlays nil
              faltoo-chat-assistant-overlays nil
              faltoo-chat-stream-heading-marker nil
              faltoo-chat-stream-answer-started nil
              faltoo-chat-prompt-heading-marker nil)
        (erase-buffer)
        (dolist (message messages)
          (faltoo-chat--insert-message message))
        (faltoo-chat--insert-user-prompt))
      (goto-char faltoo-chat-prompt-marker))
    buf))

(defun faltoo-chat-current-workspace ()
  "Return the workspace attached to this chat buffer or the current Git repo."
  (or faltoo-chat-workspace (faltoo-workspace)))

(defun faltoo-chat-refresh (&optional workspace)
  "Refresh transcript from FaltooBot session."
  (interactive)
  (let ((workspace (or workspace (faltoo-chat-current-workspace))))
    (pop-to-buffer (faltoo-chat-render (faltoo-bridge-messages faltoo-chat-turns workspace) workspace))))

(defun faltoo-chat ()
  "Open Faltoo transcript for the current Git repo."
  (interactive)
  (faltoo-chat-refresh (faltoo-workspace)))

(defun faltoo-generic-chat ()
  "Open the repo-independent Faltoo chat transcript."
  (interactive)
  (faltoo-chat-refresh (faltoo-generic-chat-workspace)))

(defun faltoo-chat-prev-user-message ()
  "Jump to the previous persisted user message heading in the transcript."
  (interactive)
  (when (and (markerp faltoo-chat-prompt-heading-marker)
             (>= (point) faltoo-chat-prompt-heading-marker))
    (goto-char faltoo-chat-prompt-heading-marker))
  (beginning-of-line)
  (when (looking-at "^# User$")
    (forward-line -1))
  (let (found)
    (while (and (not found) (re-search-backward "^# User$" nil t))
      (unless (and (markerp faltoo-chat-prompt-heading-marker)
                   (= (match-beginning 0) faltoo-chat-prompt-heading-marker))
        (setq found (match-beginning 0))))
    (unless found
      (user-error "No previous user message"))))

(defun faltoo-chat-next-user-message ()
  "Jump to the next persisted user message heading in the transcript."
  (interactive)
  (beginning-of-line)
  (when (looking-at "^# User$")
    (forward-line 1))
  (let (found)
    (while (and (not found) (re-search-forward "^# User$" nil t))
      (unless (and (markerp faltoo-chat-prompt-heading-marker)
                   (= (match-beginning 0) faltoo-chat-prompt-heading-marker))
        (setq found (match-beginning 0))))
    (if found
        (goto-char found)
      (user-error "No next user message"))))

(defun faltoo-chat-load-more (arg)
  "Load more transcript turns. With prefix ARG, show exactly that many user turns."
  (interactive "P")
  (setq faltoo-chat-turns
        (if arg
            (prefix-numeric-value arg)
          (* 2 faltoo-chat-turns)))
  (faltoo-chat-refresh (faltoo-chat-current-workspace))
  (message "Faltoo transcript showing last %s user turn(s)" faltoo-chat-turns))

(defun faltoo-chat--prompt-text ()
  (string-trim (buffer-substring-no-properties faltoo-chat-prompt-marker (point-max))))

(defun faltoo-chat-append-user-message (text &optional workspace)
  "Append TEXT as a user turn in the workspace transcript."
  (with-current-buffer (faltoo-chat-buffer workspace)
    (let ((inhibit-read-only t)
          (start nil))
      (goto-char (point-max))
      (unless (or (bobp) (bolp))
        (insert "
"))
      (faltoo-chat--insert-rule)
      (setq start (point))
      (insert "# User

" text "

")
      (faltoo-chat--highlight-user-block start (save-excursion
                                                (goto-char start)
                                                (line-end-position))))))

(defun faltoo-chat-send ()
  "Send the current workspace transcript prompt."
  (interactive)
  (let ((text (faltoo-chat--prompt-text)))
    (when (string-empty-p text)
      (user-error "Prompt is empty"))
    (faltoo-request-ensure-idle faltoo-chat-workspace)
    (goto-char (point-max))
    (insert "\n\n")
    (faltoo-request-message text nil nil t faltoo-chat-workspace)))

(defun faltoo-chat-start-stream (title &optional workspace)
  "Prepare the workspace transcript for a streaming message titled TITLE."
  (let ((buf (faltoo-chat-buffer workspace)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (or (bobp) (looking-back "\n\n" nil))
          (insert "\n"))
        (faltoo-chat--insert-rule)
        (let ((start (point)))
          (setq faltoo-chat-stream-heading-marker (copy-marker start)
                faltoo-chat-stream-answer-started nil)
          (insert (format "# %s" title))
          (faltoo-chat--highlight-assistant-block start (point))
          (insert "\n\n"))))
    buf))

(defun faltoo-chat-append-stream (text &optional workspace)
  "Append assistant stream TEXT to transcript without moving the reader."
  (let ((buf (faltoo-chat-buffer workspace))
        (prefix ""))
    (with-current-buffer buf
      (unless faltoo-chat-stream-answer-started
        (setq faltoo-chat-stream-answer-started t)
        (save-excursion
          (goto-char (point-max))
          (unless (looking-back "\n\n" nil)
            (setq prefix "\n")))))
    (faltoo-popup-append buf (concat prefix text) t)))

(defun faltoo-chat-append-stream-block (text &optional face workspace)
  "Append stream TEXT as a quoted transcript block, optionally with FACE."
  (with-current-buffer (faltoo-chat-buffer workspace)
    (let ((inhibit-read-only t)
          (start (point-max)))
      (faltoo-popup-append (current-buffer)
                           (concat "> " (string-trim-right text) "\n")
                           t)
      (when face
        (faltoo-chat--highlight-block start (point-max) face 'faltoo-chat-tool-overlays)))))

(defun faltoo-chat--duration-label (elapsed-seconds)
  (format "%.1fs" elapsed-seconds))

(defun faltoo-chat-finish-stream (&optional workspace elapsed-seconds rate-limit)
  "Finish streaming in-place and append the next editable user prompt."
  (let ((buf (get-buffer (faltoo-chat-buffer-name-for (or workspace (faltoo-workspace))))))
    (when buf
      (with-current-buffer buf
        (save-excursion
          (let ((inhibit-read-only t))
            (when (markerp faltoo-chat-stream-heading-marker)
              (save-excursion
                (goto-char faltoo-chat-stream-heading-marker)
                (when (looking-at "# Assistant · answering")
                  (delete-region (point) (line-end-position))
                  (insert "# Assistant")))
              (setq faltoo-chat-stream-heading-marker nil))
            (goto-char (point-max))
            (cond
             ((looking-back "\n\n" nil))
             ((looking-back "\n" nil) (insert "\n"))
             (t (insert "\n\n")))
            (when elapsed-seconds
              (insert (format "> Assistant took: %s\n"
                              (faltoo-chat--duration-label elapsed-seconds))))
            (when rate-limit
              (insert (format "> %s\n" rate-limit)))
            (when (or elapsed-seconds rate-limit)
              (insert "\n"))
            (faltoo-chat--insert-user-prompt)))))))


(provide 'faltoo-chat)
;;; faltoo-chat.el ends here
