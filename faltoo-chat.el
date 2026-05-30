;;; faltoo-chat.el --- Faltoo transcript buffer -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)
(require 'faltoo-faces)
(require 'org)
(require 'faltoo-compose)

(declare-function faltoo-request-message "faltoo-request")
(declare-function faltoo-request-ensure-idle "faltoo-request")

(defvar-local faltoo-chat-prompt-marker nil)
(defvar-local faltoo-chat-user-overlays nil)

(defvar faltoo-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'faltoo-chat-send)
    (define-key map (kbd "C-c C-r") #'faltoo-chat-refresh)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    (define-key map (kbd "C-c /") #'faltoo-insert-slash-command)
    map))

(define-derived-mode faltoo-chat-mode org-mode "Faltoo"
  "Faltoo transcript/history buffer."
  (setq-local truncate-lines nil))

(defun faltoo-chat-buffer ()
  "Return the Faltoo chat buffer."
  (let ((buf (get-buffer-create faltoo-chat-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'faltoo-chat-mode)
        (faltoo-chat-mode)))
    buf))

(defun faltoo-chat--highlight-user-block (start end)
  (let ((overlay (make-overlay start end nil nil t)))
    (overlay-put overlay 'face 'faltoo-chat-user-face)
    (push overlay faltoo-chat-user-overlays)))

(defun faltoo-chat--insert-message (message)
  (let ((start (point))
        (role (capitalize (or (alist-get 'role message) "message")))
        (text (or (alist-get 'text message) "")))
    (insert (format "* %s\n\n%s\n\n" role text))
    (when (string= (downcase role) "user")
      (faltoo-chat--highlight-user-block start (point)))))

(defun faltoo-chat--insert-user-prompt ()
  (goto-char (point-max))
  (unless (or (bobp) (bolp)) (insert "\n"))
  (let ((start (point)))
    (insert "* User\n\n")
    (setq faltoo-chat-prompt-marker (point-marker))
    (faltoo-chat--highlight-user-block start (point))))

(defun faltoo-chat-render (messages)
  "Render MESSAGES into `*Faltoo*' with an editable prompt."
  (let ((buf (faltoo-chat-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (mapc #'delete-overlay faltoo-chat-user-overlays)
        (setq faltoo-chat-user-overlays nil)
        (erase-buffer)
        (dolist (message messages)
          (faltoo-chat--insert-message message))
        (faltoo-chat--insert-user-prompt))
      (goto-char faltoo-chat-prompt-marker))
    buf))

(defun faltoo-chat-refresh ()
  "Refresh transcript from FaltooBot session."
  (interactive)
  (pop-to-buffer (faltoo-chat-render (faltoo-bridge-messages))))

(defun faltoo-chat ()
  "Open Faltoo transcript."
  (interactive)
  (faltoo-chat-refresh))

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
        (insert (format "* %s\n\n" title))))
    buf))

(defun faltoo-chat-append-stream (text)
  "Append stream TEXT to transcript."
  (faltoo-popup-append (faltoo-chat-buffer) text))

(defun faltoo-chat-append-stream-block (text)
  "Append stream TEXT as its own transcript block."
  (faltoo-popup-append (faltoo-chat-buffer)
                       (concat (string-trim-right text) "\n\n")))

(defun faltoo-chat-finish-stream ()
  "Refresh transcript after stream completion."
  (when (get-buffer faltoo-chat-buffer-name)
    (faltoo-chat-render (faltoo-bridge-messages))))

(provide 'faltoo-chat)
;;; faltoo-chat.el ends here
