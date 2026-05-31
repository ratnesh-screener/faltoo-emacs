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
(defvar-local faltoo-chat-user-overlays nil)
(defvar-local faltoo-chat-tool-overlays nil)
(defvar-local faltoo-chat-assistant-overlays nil)

(defcustom faltoo-chat-turns 20
  "Number of recent user turns shown in the Faltoo transcript."
  :type 'integer
  :group 'faltoo)

(defvar faltoo-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'faltoo-chat-send)
    (define-key map (kbd "C-c C-r") #'faltoo-chat-refresh)
    (define-key map (kbd "C-c C-l") #'faltoo-chat-load-more)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    (define-key map (kbd "C-c /") #'faltoo-insert-slash-command)
    map))

(define-derived-mode faltoo-chat-mode markdown-mode "Faltoo"
  "Faltoo transcript/history buffer."
  (faltoo-ui-enable-pretty-markdown)
  (setq-local truncate-lines nil))

(defun faltoo-chat-buffer ()
  "Return the Faltoo chat buffer."
  (let ((buf (get-buffer-create faltoo-chat-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'faltoo-chat-mode)
        (faltoo-chat-mode)))
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

(defun faltoo-chat--insert-message (message)
  (let* ((start (point))
         (role-text (or (alist-get 'role message) "message"))
         (role (capitalize role-text))
         (text (or (alist-get 'text message) "")))
    (if (string= (downcase role-text) "tool")
        (progn
          (insert "- " text)
          (let ((content-end (point)))
            (insert "\n\n")
            (faltoo-chat--highlight-tool-block start content-end)))
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
    (insert "# User\n\n")
    (setq faltoo-chat-prompt-marker (point-marker))
    (faltoo-chat--highlight-user-block start (line-end-position 0))))

(defun faltoo-chat-render (messages)
  "Render MESSAGES into `*Faltoo*' with an editable prompt."
  (let ((buf (faltoo-chat-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (mapc #'delete-overlay faltoo-chat-user-overlays)
        (mapc #'delete-overlay faltoo-chat-tool-overlays)
        (mapc #'delete-overlay faltoo-chat-assistant-overlays)
        (setq faltoo-chat-user-overlays nil
              faltoo-chat-tool-overlays nil
              faltoo-chat-assistant-overlays nil)
        (erase-buffer)
        (dolist (message messages)
          (faltoo-chat--insert-message message))
        (faltoo-chat--insert-user-prompt)
        (faltoo-ui-fontify-markdown))
      (goto-char faltoo-chat-prompt-marker))
    buf))

(defun faltoo-chat-refresh ()
  "Refresh transcript from FaltooBot session."
  (interactive)
  (pop-to-buffer (faltoo-chat-render (faltoo-bridge-messages faltoo-chat-turns))))

(defun faltoo-chat ()
  "Open Faltoo transcript."
  (interactive)
  (faltoo-chat-refresh))

(defun faltoo-chat-load-more (arg)
  "Load more transcript turns. With prefix ARG, show exactly that many user turns."
  (interactive "P")
  (setq faltoo-chat-turns
        (if arg
            (prefix-numeric-value arg)
          (* 2 faltoo-chat-turns)))
  (faltoo-chat-refresh)
  (message "Faltoo transcript showing last %s user turn(s)" faltoo-chat-turns))

(defun faltoo-chat--prompt-text ()
  (string-trim (buffer-substring-no-properties faltoo-chat-prompt-marker (point-max))))

(defun faltoo-chat-send ()
  "Send the current `*Faltoo*' prompt."
  (interactive)
  (let ((text (faltoo-chat--prompt-text)))
    (faltoo-request-ensure-idle)
    (when (string-empty-p text)
      (user-error "Prompt is empty"))
    (goto-char (point-max))
    (insert "\n\n")
    (faltoo-request-message text nil)))

(defun faltoo-chat-start-stream (title)
  "Prepare `*Faltoo*' for a streaming message titled TITLE."
  (let ((buf (faltoo-chat-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (or (bobp) (looking-back "\n\n" nil))
          (insert "\n"))
        (let ((start (point)))
          (insert (format "# %s" title))
          (faltoo-chat--highlight-assistant-block start (point))
          (insert "\n\n"))))
    buf))

(defun faltoo-chat-append-stream (text)
  "Append assistant stream TEXT to transcript."
  (faltoo-popup-append (faltoo-chat-buffer) text))

(defun faltoo-chat-append-stream-block (text &optional face)
  "Append stream TEXT as its own transcript block, optionally with FACE."
  (with-current-buffer (faltoo-chat-buffer)
    (let ((start (point)))
      (faltoo-popup-append (current-buffer)
                           (concat (string-trim-right text) "\n\n"))
      (when face
        (faltoo-chat--highlight-block start (point) face 'faltoo-chat-tool-overlays)))))

(defun faltoo-chat-finish-stream ()
  "Refresh transcript after stream completion."
  (when (get-buffer faltoo-chat-buffer-name)
    (faltoo-chat-render (faltoo-bridge-messages faltoo-chat-turns))))

(provide 'faltoo-chat)
;;; faltoo-chat.el ends here
