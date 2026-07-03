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
(defvar faltoo-request-processes (make-hash-table :test #'equal))
(defvar faltoo-request-cancelled (make-hash-table :test #'equal))
(defvar faltoo-request-stream-flush-delay 0.05)
(defvar faltoo-request-pending-answer-chunks (make-hash-table :test #'equal))
(defvar faltoo-request-pending-popup-buffers (make-hash-table :test #'equal))
(defvar faltoo-request-stream-flush-timers (make-hash-table :test #'equal))

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

(defun faltoo-request--clear-pending-answer (workspace)
  "Clear queued answer chunks for WORKSPACE."
  (when-let ((timer (gethash workspace faltoo-request-stream-flush-timers)))
    (cancel-timer timer))
  (remhash workspace faltoo-request-stream-flush-timers)
  (remhash workspace faltoo-request-pending-answer-chunks)
  (remhash workspace faltoo-request-pending-popup-buffers))

(defun faltoo-request--flush-answer (workspace)
  "Flush queued answer chunks for WORKSPACE into visible buffers."
  (when-let ((timer (gethash workspace faltoo-request-stream-flush-timers)))
    (cancel-timer timer))
  (remhash workspace faltoo-request-stream-flush-timers)
  (when-let ((chunks (gethash workspace faltoo-request-pending-answer-chunks)))
    (let ((text (mapconcat #'identity (nreverse chunks) ""))
          (popup-buffer (gethash workspace faltoo-request-pending-popup-buffers)))
      (remhash workspace faltoo-request-pending-answer-chunks)
      (remhash workspace faltoo-request-pending-popup-buffers)
      (setq faltoo-last-assistant-message (concat faltoo-last-assistant-message text))
      (puthash workspace (concat (or (gethash workspace faltoo-last-assistant-messages) "") text)
               faltoo-last-assistant-messages)
      (when (buffer-live-p popup-buffer)
        (faltoo-popup-append-stream popup-buffer text))
      (faltoo-chat-append-stream text workspace))))

(defun faltoo-request--queue-answer (workspace popup-buffer text)
  "Queue answer TEXT for batched UI flushing."
  (puthash workspace
           (cons text (gethash workspace faltoo-request-pending-answer-chunks))
           faltoo-request-pending-answer-chunks)
  (when popup-buffer
    (puthash workspace popup-buffer faltoo-request-pending-popup-buffers))
  (unless (gethash workspace faltoo-request-stream-flush-timers)
    (puthash workspace
             (run-at-time faltoo-request-stream-flush-delay nil
                          #'faltoo-request--flush-answer workspace)
             faltoo-request-stream-flush-timers)))

(defun faltoo-request-cancel (&optional workspace)
  "Cancel the running Faltoo request for WORKSPACE."
  (interactive)
  (let* ((target (or workspace (faltoo-workspace)))
         (process (gethash target faltoo-request-processes)))
    (unless process
      (user-error "No Faltoo request running for this workspace"))
    (puthash target t faltoo-request-cancelled)
    (faltoo-set-status "Cancelling Faltoo request...")
    (faltoo-bridge-cancel-stream process)))

(defun faltoo-request--route-event (event workspace popup-buffer on-submitted)
  (let ((class (faltoo-request--event-class event))
        (text (faltoo-request--event-text event)))
    (cond
     ((string= class "answer")
      (faltoo-request--queue-answer workspace popup-buffer text))
     ((string= class "rate-limit")
      (puthash workspace text faltoo-request-rate-limits)
      (puthash workspace text faltoo-last-rate-limits)
      (faltoo-set-status text))
     ((string= class "error")
      (faltoo-request--flush-answer workspace)
      (faltoo-set-status text)
      (when popup-buffer
        (faltoo-popup-append-stream-block popup-buffer (format "Error: %s" (string-trim text))
                                          'faltoo-chat-error-face))
      (faltoo-chat-append-stream-block (format "Error: %s" (string-trim text))
                                       'faltoo-chat-error-face workspace))
     ((member class '("status" "tool"))
      (faltoo-request--flush-answer workspace)
      (when (and on-submitted (string-prefix-p "Submitted" text))
        (funcall on-submitted))
      (faltoo-set-status text)
      (when popup-buffer
        (faltoo-popup-append-stream-block popup-buffer (faltoo-request--tool-summary text)
                                          'faltoo-chat-tool-face))
      (faltoo-chat-append-stream-block (faltoo-request--tool-summary text) 'faltoo-chat-tool-face workspace))
     ((string= class "done")
      (faltoo-request--flush-answer workspace)
      (faltoo-set-status text)))))

(defun faltoo-request-stream (args payload chat-title &optional popup-buffer on-submitted on-done)
  "Run Faltoo bridge ARGS with PAYLOAD and route stream output."
  (let ((workspace (alist-get 'workspace payload)))
    (faltoo-request-ensure-idle workspace)
    (faltoo-set-workspace-submitting workspace t)
    (puthash workspace (float-time) faltoo-request-start-times)
    (remhash workspace faltoo-request-rate-limits)
    (faltoo-request--clear-pending-answer workspace)
    (setq faltoo-last-assistant-message "")
    (puthash workspace "" faltoo-last-assistant-messages)
    (faltoo-set-status chat-title)
    (when popup-buffer
      (faltoo-popup-start-stream popup-buffer))
    (faltoo-chat-start-stream "Assistant · answering" workspace)
    (puthash
     workspace
     (faltoo-bridge-stream
      args payload
      (lambda (event)
        (faltoo-request--route-event event workspace popup-buffer on-submitted))
      (lambda (ok)
        (let ((elapsed (- (float-time) (gethash workspace faltoo-request-start-times)))
              (rate-limit (gethash workspace faltoo-request-rate-limits))
              (cancelled (gethash workspace faltoo-request-cancelled)))
          (remhash workspace faltoo-request-start-times)
          (remhash workspace faltoo-request-rate-limits)
          (remhash workspace faltoo-request-processes)
          (remhash workspace faltoo-request-cancelled)
          (faltoo-set-workspace-submitting workspace nil)
          (faltoo-set-status (cond (cancelled "Faltoo cancelled")
                                   (ok "Faltoo complete")
                                   (t "Faltoo failed")))
          (faltoo-request--flush-answer workspace)
          (faltoo-reload-workspace-buffers workspace)
          (faltoo-chat-finish-stream workspace elapsed rate-limit)
          (when (and ok popup-buffer rate-limit)
            (faltoo-popup-append popup-buffer (format "\n\n> %s\n" rate-limit) t))
          (when on-done (funcall on-done (and ok (not cancelled))))
          (when (and ok (not cancelled)) (ding)))))
     faltoo-request-processes)))


(defun faltoo-request--group-review-comments (comments)
  "Group review COMMENTS by filename while preserving submission order."
  (let (groups)
    (dolist (comment comments)
      (let* ((filename (alist-get 'filename comment))
             (group (assoc filename groups)))
        (if group
            (setcdr group (append (cdr group) (list comment)))
          (setq groups (append groups (list (cons filename (list comment))))))))
    groups))

(defun faltoo-request--transcript-review-prompt (comments)
  "Return the user prompt for transcript COMMENTS."
  (string-trim
   (string-join
    (mapcar (lambda (comment)
              (string-join
               (list "Your response:"
                     ""
                     "```"
                     (alist-get 'code comment)
                     "```"
                     ""
                     "Comment:"
                     (alist-get 'comment comment))
               "\n"))
            comments)
    "\n\n---\n\n")))

(defun faltoo-request--review-prompt (comments)
  "Return the user prompt FaltooBot receives for review COMMENTS."
  (if (seq-every-p (lambda (comment)
                    (string= (alist-get 'filename comment) "Faltoo transcript"))
                  comments)
      (faltoo-request--transcript-review-prompt comments)
    (let ((groups (faltoo-request--group-review-comments comments))
          (lines '("# Comments in code review" "")))
      (dolist (group groups)
        (let ((filename (car group)))
          (setq lines (append lines (list (format "## File name `%s`" filename) "")))
          (dolist (comment (cdr group))
            (let* ((start (or (alist-get 'file_line_number_start comment)
                              (alist-get 'line_number_start comment)))
                   (end (or (alist-get 'file_line_number_end comment)
                            (alist-get 'line_number_end comment))))
              (cond
               ((string= filename "Faltoo transcript")
                (setq lines (append lines
                                    (list "Your response:"
                                          ""
                                          "```"
                                          (alist-get 'code comment)
                                          "```"
                                          ""))))
               ((and (= start 0) (= end 0))
                (setq lines (append lines '("### File comment" ""))))
               (t
                (setq lines (append lines
                                    (list (format "### Line `%s-%s`" start end)
                                          ""
                                          "Code:"
                                          ""
                                          "```"
                                          (alist-get 'code comment)
                                          "```"
                                          "")))))
              (setq lines (append lines (list "Comment:" (alist-get 'comment comment) ""))))))
        (unless (eq group (car (last groups)))
          (setq lines (append lines '("---" "")))))
      (string-trim (string-join lines "\n")))))

(defun faltoo-request-message (text &optional popup-buffer on-done skip-transcript-user workspace)
  "Send TEXT as a chat message."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-request-ensure-idle workspace)
    (unless skip-transcript-user
      (faltoo-chat-append-user-message text workspace))
    (faltoo-request-stream
     (list "append-message")
     (list (cons 'workspace workspace) (cons 'text text))
     "Submitting ask..."
     popup-buffer nil on-done)))

(defun faltoo-request-review (comments on-submitted &optional on-done)
  "Submit COMMENTS as review comments."
  (let ((workspace (faltoo-workspace)))
    (faltoo-request-ensure-idle workspace)
    (faltoo-chat-append-user-message (faltoo-request--review-prompt comments) workspace)
    (faltoo-request-stream
     (list "append-review")
     (list (cons 'workspace workspace) (cons 'comments (vconcat comments)))
     "Submitting review comments..."
     nil on-submitted on-done)))

(provide 'faltoo-request)
;;; faltoo-request.el ends here
