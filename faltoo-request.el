;;; faltoo-request.el --- Faltoo request/stream orchestration -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-chat)
(require 'faltoo-ui)
(require 'faltoo-faces)

(defun faltoo-request--event-text (event)
  (or (alist-get 'text event) ""))

(defun faltoo-request--event-class (event)
  (or (alist-get 'classes event) (alist-get 'type event) ""))

(defun faltoo-request-ensure-idle ()
  "Signal when another Faltoo request is already running."
  (when faltoo-submitting
    (user-error "Faltoo request already running")))

(defun faltoo-request--route-event (event popup-buffer on-submitted)
  (let ((class (faltoo-request--event-class event))
        (text (faltoo-request--event-text event)))
    (cond
     ((string= class "answer")
      (setq faltoo-last-assistant-message (concat faltoo-last-assistant-message text))
      (when popup-buffer
        (faltoo-popup-append popup-buffer (propertize text 'face 'faltoo-popup-assistant-face)))
      (faltoo-chat-append-stream text))
     ((member class '("status" "tool"))
      (when (and on-submitted (string-prefix-p "Submitted" text))
        (funcall on-submitted))
      (faltoo-set-status text)
      (faltoo-chat-append-stream (format "- %s\n" text)))
     ((string= class "done")
      (faltoo-set-status text)))))

(defun faltoo-request-stream (args payload chat-title &optional popup-buffer on-submitted on-done)
  "Run Faltoo bridge ARGS with PAYLOAD and route stream output."
  (faltoo-request-ensure-idle)
  (setq faltoo-submitting t
        faltoo-last-assistant-message "")
  (faltoo-set-status chat-title)
  (faltoo-chat-start-stream "Assistant · streaming")
  (faltoo-bridge-stream
   args payload
   (lambda (event)
     (faltoo-request--route-event event popup-buffer on-submitted))
   (lambda (ok)
     (setq faltoo-submitting nil)
     (faltoo-set-status (if ok "Faltoo complete" "Faltoo failed"))
     (faltoo-reload-review-buffers)
     (faltoo-chat-finish-stream)
     (when on-done (funcall on-done ok))
     (when ok (ding)))))

(defun faltoo-request-message (text &optional popup-buffer on-done)
  "Send TEXT as a chat message."
  (faltoo-request-stream
   (list "append-message")
   (list (cons 'workspace (faltoo-workspace)) (cons 'text text))
   "Submitting ask..."
   popup-buffer nil on-done))

(defun faltoo-request-review (comments on-submitted &optional on-done)
  "Submit COMMENTS as review comments."
  (faltoo-request-stream
   (list "append-review")
   (list (cons 'workspace (faltoo-workspace)) (cons 'comments (vconcat comments)))
   "Submitting review comments..."
   nil on-submitted on-done))

(provide 'faltoo-request)
;;; faltoo-request.el ends here
