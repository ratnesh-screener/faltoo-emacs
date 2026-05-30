;;; faltoo-chat.el --- Faltoo transcript buffer -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)
(require 'org)
(require 'faltoo-compose)

(declare-function faltoo-request-message "faltoo-request")
(declare-function faltoo-request-ensure-idle "faltoo-request")

(defvar-local faltoo-chat-prompt-marker nil)

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

(defun faltoo-chat--message-lines (message)
  (let ((role (capitalize (or (alist-get 'role message) "message")))
        (text (or (alist-get 'text message) "")))
    (append (list (format "* %s" role) "")
            (split-string text "\n")
            (list ""))))

(defun faltoo-chat--insert-user-prompt ()
  (goto-char (point-max))
  (unless (or (bobp) (bolp)) (insert "\n"))
  (insert "* User\n\n")
  (setq faltoo-chat-prompt-marker (point-marker)))

(defun faltoo-chat-render (messages)
  "Render MESSAGES into `*Faltoo*' with an editable prompt."
  (let ((buf (faltoo-chat-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (message messages)
          (insert (string-join (faltoo-chat--message-lines message) "\n")))
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
        (unless (bolp) (insert "\n"))
        (insert (format "* %s\n\n" title))))
    buf))

(defun faltoo-chat-append-stream (text)
  "Append stream TEXT to transcript."
  (faltoo-popup-append (faltoo-chat-buffer) text))

(defun faltoo-chat-finish-stream ()
  "Refresh transcript after stream completion."
  (when (get-buffer faltoo-chat-buffer-name)
    (faltoo-chat-render (faltoo-bridge-messages))))

(provide 'faltoo-chat)
;;; faltoo-chat.el ends here
