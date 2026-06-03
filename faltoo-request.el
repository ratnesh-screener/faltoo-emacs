;;; faltoo-request.el --- Faltoo request/stream orchestration -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'seq)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-chat)
(require 'faltoo-ui)
(require 'faltoo-faces)

(defvar faltoo-request-start-times (make-hash-table :test #'equal))
(defvar faltoo-request-rate-limits (make-hash-table :test #'equal))

(defun faltoo-request--event-text (event)
  (or (alist-get 'text event) ""))

(defconst faltoo-request--shell-command-separator "\n\n<!-- shell-command -->\n\n")

(defun faltoo-request--event-class (event)
  (or (alist-get 'classes event) (alist-get 'type event) ""))

(defun faltoo-request--clip-lines (text)
  (let ((lines (split-string text "\n")))
    (if (<= (length lines) 5)
        text
      (string-join (append (seq-take lines 4) '("...")) "\n"))))

(defun faltoo-request--tool-summary (text)
  (let ((summary (car (split-string text faltoo-request--shell-command-separator t))))
    (faltoo-request--clip-lines
     (string-trim
      (replace-regexp-in-string "\\*\\*" "" summary)))))

(defun faltoo-request-ensure-idle (&optional workspace)
  "Signal when another Faltoo request is already running for WORKSPACE."
  (when (faltoo-workspace-submitting-p (or workspace (faltoo-workspace)))
    (user-error "Faltoo request already running for this workspace")))

(defun faltoo-request--route-event (event workspace popup-buffer on-submitted)
  (let ((class (faltoo-request--event-class event))
        (text (faltoo-request--event-text event)))
    (cond
     ((string= class "answer")
      (setq faltoo-last-assistant-message (concat faltoo-last-assistant-message text))
      (puthash workspace (concat (or (gethash workspace faltoo-last-assistant-messages) "") text)
               faltoo-last-assistant-messages)
      (when popup-buffer
        (faltoo-popup-append-stream popup-buffer text))
      (faltoo-chat-append-stream text workspace))
     ((string= class "rate-limit")
      (puthash workspace text faltoo-request-rate-limits)
      (puthash workspace text faltoo-last-rate-limits)
      (faltoo-set-status text))
     ((string= class "error")
      (faltoo-set-status text)
      (when popup-buffer
        (faltoo-popup-append-stream-block popup-buffer (format "Error: %s" (string-trim text))
                                          'faltoo-chat-error-face))
      (faltoo-chat-append-stream-block (format "Error: %s" (string-trim text))
                                       'faltoo-chat-error-face workspace))
     ((member class '("status" "tool"))
      (when (and on-submitted (string-prefix-p "Submitted" text))
        (funcall on-submitted))
      (faltoo-set-status text)
      (when popup-buffer
        (faltoo-popup-append-stream-block popup-buffer (faltoo-request--tool-summary text)
                                          'faltoo-chat-tool-face))
      (faltoo-chat-append-stream-block (faltoo-request--tool-summary text) 'faltoo-chat-tool-face workspace))
     ((string= class "done")
      (faltoo-set-status text)))))

(defun faltoo-request-stream (args payload chat-title &optional popup-buffer on-submitted on-done)
  "Run Faltoo bridge ARGS with PAYLOAD and route stream output."
  (let ((workspace (alist-get 'workspace payload)))
    (faltoo-request-ensure-idle workspace)
    (faltoo-set-workspace-submitting workspace t)
    (puthash workspace (float-time) faltoo-request-start-times)
    (remhash workspace faltoo-request-rate-limits)
    (setq faltoo-last-assistant-message "")
    (puthash workspace "" faltoo-last-assistant-messages)
    (faltoo-set-status chat-title)
    (when popup-buffer
      (faltoo-popup-start-stream popup-buffer))
    (faltoo-chat-start-stream "Assistant · answering" workspace)
    (faltoo-bridge-stream
     args payload
     (lambda (event)
       (faltoo-request--route-event event workspace popup-buffer on-submitted))
     (lambda (ok)
       (let ((elapsed (- (float-time) (gethash workspace faltoo-request-start-times)))
             (rate-limit (gethash workspace faltoo-request-rate-limits)))
         (remhash workspace faltoo-request-start-times)
         (remhash workspace faltoo-request-rate-limits)
         (faltoo-set-workspace-submitting workspace nil)
         (faltoo-set-status (if ok "Faltoo complete" "Faltoo failed"))
         (faltoo-reload-review-buffers)
         (faltoo-chat-finish-stream workspace elapsed rate-limit)
         (when (and ok popup-buffer rate-limit)
           (faltoo-popup-append popup-buffer (format "\n\n> %s\n" rate-limit))))
       (when on-done (funcall on-done ok))
       (when ok (ding))))))

(defun faltoo-request-message (text &optional popup-buffer on-done skip-transcript-user)
  "Send TEXT as a chat message."
  (unless skip-transcript-user
    (faltoo-chat-append-user-message text))
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
