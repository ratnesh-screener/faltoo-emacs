;;; faltoo-chat.el --- Faltoo transcript buffer -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)

(defvar faltoo-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'faltoo-chat-refresh)
    (define-key map (kbd "q") #'quit-window)
    map))

(define-derived-mode faltoo-chat-mode special-mode "Faltoo"
  "Faltoo transcript/history buffer.")

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
    (append (list (format "# %s" role) "")
            (split-string text "\n")
            (list ""))))

(defun faltoo-chat-render (messages)
  "Render MESSAGES into `*Faltoo*'."
  (let ((buf (faltoo-chat-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (message messages)
          (insert (string-join (faltoo-chat--message-lines message) "\n"))))
      (goto-char (point-max)))
    buf))

(defun faltoo-chat-refresh ()
  "Refresh transcript from FaltooBot session."
  (interactive)
  (pop-to-buffer (faltoo-chat-render (faltoo-bridge-messages))))

(defun faltoo-chat ()
  "Open Faltoo transcript."
  (interactive)
  (faltoo-chat-refresh))

(defun faltoo-chat-start-stream (title)
  "Prepare `*Faltoo*' for a streaming message titled TITLE."
  (let ((buf (faltoo-chat-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "# %s\n\n" title))))
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
