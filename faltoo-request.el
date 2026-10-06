;;; faltoo-request.el --- Faltoo request/stream orchestration -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'seq)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-chat)
(require 'faltoo-queue)
(require 'faltoo-ui)
(require 'faltoo-faces)
(require 'faltoo-compose)

(defvar faltoo-request-start-times (make-hash-table :test #'equal))
(defvar faltoo-request-rate-limits (make-hash-table :test #'equal))
(defvar faltoo-request-processes (make-hash-table :test #'equal))
(defvar faltoo-request-cancelled (make-hash-table :test #'equal))
(defvar faltoo-request-stream-flush-delay 0.05)
(defvar faltoo-request-pending-answer-chunks (make-hash-table :test #'equal))
(defvar faltoo-request-pending-popup-buffers (make-hash-table :test #'equal))
(defvar faltoo-request-stream-flush-timers (make-hash-table :test #'equal))
(defvar faltoo-request-claude-prompts (make-hash-table :test #'equal)
  "Queue entry each Claude workspace sent whose turn has not started.")

(defun faltoo-request--event-text (event)
  (or (alist-get 'text event) ""))

(defconst faltoo-request--hook-feedback-separator "────────────────")

(defun faltoo-request--event-class (event)
  (or (alist-get 'classes event) (alist-get 'type event) ""))

(defun faltoo-request--hook-feedback-block (text)
  (string-join (list faltoo-request--hook-feedback-separator
                     (string-trim text)
                     faltoo-request--hook-feedback-separator)
               "
"))

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
    (faltoo-queue-pause target)
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
     ((member class '("status" "tool" "hook-feedback"))
      (faltoo-request--flush-answer workspace)
      (when (and on-submitted (string-prefix-p "Submitted" text))
        (funcall on-submitted))
      (if (string= class "hook-feedback")
          (let ((feedback (faltoo-request--hook-feedback-block text)))
            (faltoo-set-status "Post-response hook feedback")
            (when popup-buffer
              (faltoo-popup-append-stream-block popup-buffer feedback 'faltoo-chat-hook-feedback-face))
            (faltoo-chat-append-stream-block feedback 'faltoo-chat-hook-feedback-face workspace))
        (let ((summary (faltoo-compose-tool-summary text)))
          (faltoo-set-status text)
          (when popup-buffer
            (faltoo-popup-append-stream-block popup-buffer summary 'faltoo-chat-tool-face))
          (faltoo-chat-append-stream-block summary 'faltoo-chat-tool-face workspace))))
     ((string= class "done")
      (faltoo-request--flush-answer workspace)
      (faltoo-set-status text)))))

(defun faltoo-request-stream (args payload chat-title &optional popup-buffer on-submitted on-done)
  "Run Faltoo bridge ARGS with PAYLOAD and route stream output."
  (faltoo-request-ensure-idle (alist-get 'workspace payload))
  (faltoo-request--stream
   (alist-get 'workspace payload) chat-title popup-buffer on-submitted on-done
   (lambda (on-event on-finish)
     (faltoo-bridge-stream args payload on-event on-finish))))

(defun faltoo-request--stream (workspace chat-title popup-buffer on-submitted on-done start)
  "Route WORKSPACE stream output from the process START returns.
START is called with the event and completion callbacks."
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
  (let ((process
         (funcall
          start
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
              (if (and ok (not cancelled))
                  (progn
                    (ding)
                    (faltoo-request-consume-queue workspace))
                (faltoo-queue-pause workspace)))))))
    (when (faltoo-workspace-submitting-p workspace)
      (puthash workspace process faltoo-request-processes))))


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

(defun faltoo-request-consume-queue (workspace)
  "Start WORKSPACE's next queued message when it is idle."
  (unless (or (faltoo-workspace-submitting-p workspace)
              (faltoo-queue-paused-p workspace)
              (gethash workspace faltoo-request-claude-prompts))
    (when-let ((entry (faltoo-queue-pop workspace)))
      (let ((text (plist-get entry :text)))
        (if (faltoo-bridge-claude-p workspace)
            (faltoo-request-claude-submit workspace entry)
          (faltoo-chat-append-user-message text workspace)
          (faltoo-request-stream
           (list "append-message")
           (list (cons 'workspace workspace) (cons 'text text))
           "Submitting queued message..."
           (plist-get entry :popup-buffer) nil (plist-get entry :on-done)))))))

(defun faltoo-request-claude-submit (workspace entry &optional command)
  "Show ENTRY's :text and send it to WORKSPACE's Claude daemon as COMMAND.
COMMAND defaults to a prompt; ENTRY's :send, when present, is sent instead
of its text. The section opens now; the turn after Claude echoes it streams
into it."
  (faltoo-chat-append-user-message (plist-get entry :text) workspace)
  (faltoo-request--stream
   workspace "Submitting queued message..."
   (plist-get entry :popup-buffer) nil (plist-get entry :on-done)
   (lambda (on-event on-done)
     (puthash workspace (plist-put entry :callbacks (cons on-event on-done))
              faltoo-request-claude-prompts)
     (faltoo-bridge-claude-send workspace (or (plist-get entry :send) (plist-get entry :text))
                                command))))

(defun faltoo-request--queue-notification (workspace text)
  "Add background notification TEXT to WORKSPACE's submission queue."
  (faltoo-queue-add text workspace)
  (faltoo-request-consume-queue workspace))

(remove-hook 'faltoo-bridge-queue-hook #'faltoo-request--queue-notification)
(add-hook 'faltoo-bridge-queue-hook #'faltoo-request--queue-notification)

(defun faltoo-request--claude-event (workspace process event)
  "Show Claude stream EVENT from daemon PROCESS in WORKSPACE's transcript.
Claude echoes the sent prompt, already shown, at its turn's start; a turn
without a prompt echo was started by Claude and follows its notification."
  (let ((entry (gethash workspace faltoo-request-claude-prompts)))
    (pcase (alist-get 'type event)
      ("submitted"
       (funcall (car (plist-get entry :callbacks))
                '((classes . "status") (text . "Submitted message. Waiting for assistant..."))))
      ("prompt"
       (if entry
           (puthash workspace (plist-put entry :echoed t) faltoo-request-claude-prompts)
         (faltoo-chat-append-user-message (alist-get 'text event) workspace)))
      ("notification"
       ;; A sent prompt's section is already open; its heading would split it.
       (unless (faltoo-workspace-submitting-p workspace)
         (faltoo-chat-append-user-message (alist-get 'text event) workspace)))
      ("turn"
       (let ((id (alist-get 'id event))
             (callbacks (plist-get entry :callbacks)))
         (cond
          ((plist-get entry :echoed)
           (remhash workspace faltoo-request-claude-prompts)
           (faltoo-bridge-attach process id (car callbacks) (cdr callbacks)))
          ((faltoo-workspace-submitting-p workspace)
           ;; Claude's own turn raced a sent prompt: stream into its open section.
           (faltoo-bridge-attach process id
                                 (lambda (event) (faltoo-request--route-event event workspace nil nil))
                                 #'ignore))
          (t
           (faltoo-request--stream
            workspace "Background update" nil nil nil
            (lambda (on-event on-done)
              (faltoo-bridge-attach process id on-event on-done))))))))))

(remove-hook 'faltoo-bridge-claude-hook #'faltoo-request--claude-event)
(add-hook 'faltoo-bridge-claude-hook #'faltoo-request--claude-event)

(defun faltoo-request--claude-exit (workspace error)
  "Requeue WORKSPACE's unanswered Claude prompt, paused, after daemon ERROR."
  (when-let ((entry (gethash workspace faltoo-request-claude-prompts)))
    (remhash workspace faltoo-request-claude-prompts)
    (let ((callbacks (plist-get entry :callbacks)))
      (funcall (car callbacks)
               `((classes . "error")
                 (text . ,(if (string-empty-p error) "Claude stopped" error))))
      ;; Failing the section pauses the queue before the prompt returns to it.
      (funcall (cdr callbacks) nil))
    (faltoo-queue-add (plist-get entry :text) workspace
                      (plist-get entry :popup-buffer) (plist-get entry :on-done))))

(remove-hook 'faltoo-bridge-daemon-exit-hook #'faltoo-request--claude-exit)
(add-hook 'faltoo-bridge-daemon-exit-hook #'faltoo-request--claude-exit)

(defun faltoo-request-message (text &optional popup-buffer on-done skip-transcript-user workspace)
  "Queue TEXT as a chat message."
  (let ((workspace (or workspace (faltoo-workspace))))
    (when skip-transcript-user
      (faltoo-chat-clear-user-prompt workspace))
    (faltoo-queue-add text workspace popup-buffer on-done)
    (faltoo-request-consume-queue workspace)))

(defun faltoo-request-review (comments on-submitted &optional on-done workspace)
  "Queue COMMENTS as review text for WORKSPACE."
  (let ((workspace (or workspace (faltoo-active-workspace))))
    (faltoo-queue-add (faltoo-request--review-prompt comments) workspace nil on-done)
    (funcall on-submitted)
    (faltoo-request-consume-queue workspace)))

(provide 'faltoo-request)
;;; faltoo-request.el ends here
