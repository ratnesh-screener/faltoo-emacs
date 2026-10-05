;;; faltoo-bridge.el --- Python bridge for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'faltoo-core)

(defconst faltoo-bridge-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Root directory of the Faltoo Emacs package.")

(defcustom faltoo-release-faltoobot-command "faltoobot"
  "FaltooBot command used for the released Faltoo core."
  :type 'string
  :group 'faltoo)

(defcustom faltoo-local-faltoobot-command
  "/Users/ratneshrastogi/screener_dev/FaltooBot/.venv/bin/faltoochat"
  "FaltooBot/FaltooChat command used for local core development."
  :type 'file
  :group 'faltoo)

(defcustom faltoo-faltoobot-command faltoo-release-faltoobot-command
  "Default core used when a workspace has no override.
A FaltooBot/FaltooChat command, or the symbol `claude' for Claude Code."
  :type '(choice string (const claude))
  :group 'faltoo)

(defcustom faltoo-claude-command "claude"
  "Claude Code command used by the Claude core."
  :type 'string
  :group 'faltoo)

(defvar faltoo-faltoobot-workspace-commands (make-hash-table :test #'equal)
  "Per-workspace FaltooBot/FaltooChat command overrides.")

(defcustom faltoo-bridge-daemon-idle-seconds 1800
  "Seconds before an idle persistent Faltoo bridge is stopped."
  :type 'integer
  :group 'faltoo)

(defconst faltoo-bridge--cache-miss (make-symbol "faltoo-cache-miss"))
(defvar faltoo-bridge-websocket-enabled-cache (make-hash-table :test #'equal))
(defvar faltoo-bridge-daemons (make-hash-table :test #'equal))
(defvar faltoo-bridge-daemon-idle-timers (make-hash-table :test #'equal))
(defvar faltoo-bridge-daemon-next-id 0)
(defvar faltoo-bridge-queue-hook nil)
(defvar faltoo-bridge-claude-hook nil
  "Functions called with WORKSPACE, PROCESS and a Claude stream EVENT.
EVENT is a prompt echo, a notification, or a turn start.")
(defvar faltoo-bridge-daemon-exit-hook nil
  "Functions called with WORKSPACE and its stderr text when its daemon exits.")
(defconst faltoo-bridge--daemon-commands '("append-message"))

(defun faltoo-bridge-command-for-workspace (&optional workspace)
  "Return the active Faltoo command for WORKSPACE."
  (or (and workspace (gethash workspace faltoo-faltoobot-workspace-commands))
      faltoo-faltoobot-command))

(defun faltoo-select-faltoobot-command ()
  "Switch the current workspace between released and local Faltoo core commands."
  (interactive)
  (let* ((workspace (faltoo-active-workspace))
         (release (format "release — %s" faltoo-release-faltoobot-command))
         (local (format "local — %s" faltoo-local-faltoobot-command))
         (claude (format "claude — %s" faltoo-claude-command))
         (custom "custom...")
         (choice (completing-read "Faltoo core: " (list release local claude custom) nil t))
         (command (cond
                   ((string= choice release) faltoo-release-faltoobot-command)
                   ((string= choice local) faltoo-local-faltoobot-command)
                   ((string= choice claude) 'claude)
                   (t (read-string "Faltoo command: "
                                   (format "%s" (faltoo-bridge-command-for-workspace
                                                 workspace)))))))
    (faltoo-bridge--command-executable
     (if (eq command 'claude) faltoo-claude-command command))
    ;; Stop first: declining to kill Claude background tasks keeps the old core.
    (faltoo-bridge-stop-daemon workspace)
    (puthash workspace command faltoo-faltoobot-workspace-commands)
    (remhash workspace faltoo-bridge-websocket-enabled-cache)
    (message "Faltoo using for %s: %s"
             (file-name-nondirectory (directory-file-name workspace))
             command)))

(defun faltoo-bridge--script ()
  (expand-file-name "python/faltoo_bridge.py" faltoo-bridge-root))

(defun faltoo-bridge--shebang-python (path)
  (with-temp-buffer
    (insert-file-contents path nil 0 200)
    (goto-char (point-min))
    (let ((line (string-trim (buffer-substring (line-beginning-position) (line-end-position)))))
      (unless (string-prefix-p "#!" line)
        (user-error "Could not resolve Python from faltoobot shebang"))
      (let ((parts (split-string (substring line 2))))
        (if (string= (car parts) "/usr/bin/env")
            (cadr parts)
          (car parts))))))

(defun faltoo-bridge--command-executable (command)
  "Return executable path for Faltoo COMMAND."
  (let ((expanded (substitute-in-file-name command)))
    (if (file-name-absolute-p expanded)
        (if (file-executable-p expanded)
            expanded
          (user-error "Faltoo command is not executable: %s" expanded))
      (or (executable-find command)
          (user-error "Faltoo command not found in PATH: %s" command)))))

(defun faltoo-bridge-python (&optional workspace)
  "Return Python executable from WORKSPACE's active Faltoo command shim."
  (faltoo-bridge--shebang-python
   (faltoo-bridge--command-executable
    (faltoo-bridge-command-for-workspace workspace))))

(defun faltoo-bridge-claude-p (workspace)
  "Return non-nil when WORKSPACE uses the Claude Code core."
  (eq (faltoo-bridge-command-for-workspace workspace) 'claude))

(defun faltoo-bridge--command (args &optional workspace)
  (append
   (if (faltoo-bridge-claude-p workspace)
       ;; The Claude bridge reuses FaltooBot's prompt and Git helpers.
       (list (faltoo-bridge--shebang-python
              (faltoo-bridge--command-executable faltoo-release-faltoobot-command))
             (expand-file-name "python/claude_bridge.py" faltoo-bridge-root)
             "--claude" (faltoo-bridge--command-executable faltoo-claude-command))
     (list (faltoo-bridge-python workspace) (faltoo-bridge--script)))
   args))

(defun faltoo-bridge-call-raw (args &optional input workspace)
  "Run bridge ARGS synchronously with INPUT and return stdout."
  (let* ((cmd (faltoo-bridge--command args workspace))
         (program (car cmd))
         (program-args (cdr cmd))
         (stdin-file (when input (make-temp-file "faltoo-stdin")))
         (stderr-file (make-temp-file "faltoo-stderr"))
         code out err)
    (unwind-protect
        (progn
          (when stdin-file (write-region input nil stdin-file nil 'silent))
          (with-temp-buffer
            (setq code (apply #'process-file program stdin-file (list t stderr-file) nil program-args))
            (setq out (buffer-string)))
          (setq err (with-temp-buffer
                      (insert-file-contents stderr-file)
                      (string-trim (buffer-string))))
          (unless (zerop code)
            (user-error "%s" (if (string-empty-p err) "Faltoo bridge failed" err)))
          out)
      (when stdin-file (delete-file stdin-file))
      (delete-file stderr-file))))

(defun faltoo-bridge-call-json (args &optional input workspace)
  "Run bridge ARGS and parse JSON output."
  (json-parse-string (faltoo-bridge-call-raw args input workspace)
                     :object-type 'alist :array-type 'list))


(defun faltoo-bridge-websocket-enabled-p (workspace)
  "Return non-nil when WORKSPACE should use the persistent websocket bridge."
  (let ((cached (gethash workspace faltoo-bridge-websocket-enabled-cache
                         faltoo-bridge--cache-miss)))
    (if (not (eq cached faltoo-bridge--cache-miss))
        cached
      (let* ((payload (faltoo-bridge-call-json
                       (list "websocket-enabled" "--workspace" workspace)
                       nil workspace))
             (enabled (eq (alist-get 'enabled payload) t)))
        (puthash workspace enabled faltoo-bridge-websocket-enabled-cache)
        enabled))))

(defun faltoo-bridge--daemon-command-p (args)
  (member (car args) faltoo-bridge--daemon-commands))

(defun faltoo-bridge--cancel-daemon-idle-timer (workspace)
  (when-let ((timer (gethash workspace faltoo-bridge-daemon-idle-timers)))
    (cancel-timer timer))
  (remhash workspace faltoo-bridge-daemon-idle-timers))

(defun faltoo-bridge-stop-daemon (workspace)
  "Stop WORKSPACE's persistent bridge daemon."
  (when-let* ((process (gethash workspace faltoo-bridge-daemons))
              (count (process-get process 'faltoo-background-tasks))
              ((> count 0))
              ((not (yes-or-no-p
                     (format "Stopping kills %d Claude background tasks. Continue? " count)))))
    (user-error "Kept Claude running"))
  (faltoo-bridge--cancel-daemon-idle-timer workspace)
  (when-let ((process (gethash workspace faltoo-bridge-daemons)))
    (remhash workspace faltoo-bridge-daemons)
    (delete-process process)))

(defun faltoo-restart-daemon ()
  "Restart the current workspace's bridge daemon to pick up bridge changes.
The next prompt starts a fresh daemon."
  (interactive)
  (let ((workspace (faltoo-active-workspace)))
    (unless (gethash workspace faltoo-bridge-daemons)
      (user-error "No Faltoo daemon running for this workspace"))
    (faltoo-bridge-stop-daemon workspace)
    (message "Faltoo daemon stopped; the next prompt starts a fresh one")))

(defun faltoo-bridge--schedule-daemon-idle-stop (workspace process)
  ;; Claude daemons expire themselves once their background tasks finish.
  (when (and (not (process-get process 'faltoo-claude))
             (= (hash-table-count (process-get process 'faltoo-requests)) 0))
    (faltoo-bridge--cancel-daemon-idle-timer workspace)
    (puthash workspace
             (run-at-time faltoo-bridge-daemon-idle-seconds nil
                          #'faltoo-bridge-stop-daemon workspace)
             faltoo-bridge-daemon-idle-timers)))

(defun faltoo-bridge--daemon-handle-line (workspace process line)
  (let* ((event (json-parse-string line :object-type 'alist :array-type 'list))
         (type (or (alist-get 'type event) "")))
    (cond
     ((string= type "queue")
      (run-hook-with-args 'faltoo-bridge-queue-hook workspace (alist-get 'text event)))
     ((string= type "background-tasks")
      (process-put process 'faltoo-background-tasks (alist-get 'count event)))
     ((member type '("prompt" "notification" "turn"))
      (run-hook-with-args 'faltoo-bridge-claude-hook workspace process event))
     (t
      (let* ((request-id (alist-get 'id event))
             (requests (process-get process 'faltoo-requests))
             (callbacks (gethash request-id requests)))
        (when callbacks
          (let ((on-event (car callbacks))
                (on-done (cdr callbacks)))
            (if (string= type "complete")
                (progn
                  (remhash request-id requests)
                  (funcall on-done (eq (alist-get 'ok event) t))
                  (faltoo-bridge--schedule-daemon-idle-stop workspace process))
              (funcall on-event event)))))))))

(defun faltoo-bridge--daemon-filter (workspace process chunk)
  (process-put process 'faltoo-pending
               (concat (or (process-get process 'faltoo-pending) "") chunk))
  (let ((lines (split-string (process-get process 'faltoo-pending) "\n")))
    (process-put process 'faltoo-pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (faltoo-bridge--daemon-handle-line workspace process line)))))

(defun faltoo-bridge--daemon-sentinel (workspace buffer stderr-buffer process _event)
  (when (memq (process-status process) '(exit signal))
    (let ((requests (process-get process 'faltoo-requests))
          (cancelled (process-get process 'faltoo-cancelled))
          (stderr (string-trim (with-current-buffer stderr-buffer (buffer-string)))))
      (maphash (lambda (_id callbacks)
                 (let ((on-event (car callbacks))
                       (on-done (cdr callbacks)))
                   (if cancelled
                       (funcall on-event '((classes . "status") (text . "Cancelled.")))
                     (funcall on-event `((classes . "error")
                                          (text . ,(if (string-empty-p stderr)
                                                       "Faltoo bridge failed"
                                                     stderr)))))
                   (funcall on-done nil)))
               requests)
      (run-hook-with-args 'faltoo-bridge-daemon-exit-hook workspace stderr))
    (remhash workspace faltoo-bridge-daemons)
    (faltoo-bridge--cancel-daemon-idle-timer workspace)
    (kill-buffer buffer)
    (kill-buffer stderr-buffer)))

(defun faltoo-bridge--ensure-daemon (workspace)
  (or (and-let* ((process (gethash workspace faltoo-bridge-daemons))
                 ((process-live-p process)))
        process)
      (let* ((claude (faltoo-bridge-claude-p workspace))
             (cmd (faltoo-bridge--command
                   (append (list "daemon" "--workspace" workspace)
                           (when claude
                             (list "--idle-seconds"
                                   (number-to-string faltoo-bridge-daemon-idle-seconds))))
                   workspace))
             (buffer (generate-new-buffer " *faltoo-bridge-daemon*"))
             (stderr-buffer (generate-new-buffer " *faltoo-bridge-daemon-stderr*"))
             (process (make-process
                       :name "faltoo-bridge-daemon"
                       :buffer buffer
                       :command cmd
                       :connection-type 'pipe
                       :noquery t
                       :stderr stderr-buffer
                       :filter (lambda (proc chunk)
                                 (faltoo-bridge--daemon-filter workspace proc chunk))
                       :sentinel (lambda (proc event)
                                   (faltoo-bridge--daemon-sentinel
                                    workspace buffer stderr-buffer proc event)))))
        (process-put process 'faltoo-requests (make-hash-table :test #'equal))
        (process-put process 'faltoo-claude claude)
        (puthash workspace process faltoo-bridge-daemons)
        process)))

(defun faltoo-bridge--daemon-stream (args payload on-event on-done)
  "Send append ARGS and PAYLOAD through a persistent bridge daemon."
  (let* ((workspace (alist-get 'workspace payload))
         (process (faltoo-bridge--ensure-daemon workspace))
         (request-id (number-to-string (cl-incf faltoo-bridge-daemon-next-id))))
    (faltoo-bridge--cancel-daemon-idle-timer workspace)
    (faltoo-bridge-attach process request-id on-event on-done)
    (process-send-string
     process
     (concat (json-serialize `((id . ,request-id)
                               (command . ,(car args))
                               (payload . ,payload)))
             "\n"))
    process))

(defun faltoo-bridge-claude-send (workspace text)
  "Write prompt TEXT to WORKSPACE's Claude daemon and return the daemon.
Claude's echo and turns come back through `faltoo-bridge-claude-hook'."
  (let ((process (faltoo-bridge--ensure-daemon workspace)))
    (process-send-string
     process
     (concat (json-serialize `((command . "append-message") (payload . ((text . ,text)))))
             "\n"))
    process))

(defun faltoo-bridge-attach (process request-id on-event on-done)
  "Route daemon PROCESS events for REQUEST-ID to ON-EVENT and ON-DONE."
  (puthash request-id (cons on-event on-done) (process-get process 'faltoo-requests))
  process)

(defun faltoo-bridge-stream (args payload on-event on-done)
  "Run bridge ARGS with PAYLOAD.
Call ON-EVENT for each JSONL event and ON-DONE with t/nil at completion."
  (let ((workspace (alist-get 'workspace payload)))
    (if (and (faltoo-bridge--daemon-command-p args)
             (faltoo-bridge-websocket-enabled-p workspace))
        (faltoo-bridge--daemon-stream args payload on-event on-done)
      (faltoo-bridge--oneshot-stream args payload on-event on-done))))

(defun faltoo-bridge--oneshot-stream (args payload on-event on-done)
  "Run one-shot bridge ARGS with PAYLOAD.
Call ON-EVENT for each JSONL event and ON-DONE with t/nil at exit."
  (let* ((workspace (alist-get 'workspace payload))
         (cmd (faltoo-bridge--command args workspace))
         (buffer (generate-new-buffer " *faltoo-bridge*"))
         (stderr-buffer (generate-new-buffer " *faltoo-bridge-stderr*"))
         (pending "")
         (stderr "")
         (proc (make-process
                :name "faltoo-bridge"
                :buffer buffer
                :command cmd
                :connection-type 'pipe
                :noquery t
                :stderr stderr-buffer
                :filter (lambda (_proc chunk)
                          (setq pending (concat pending chunk))
                          (let ((lines (split-string pending "\n")))
                            (setq pending (car (last lines)))
                            (dolist (line (butlast lines))
                              (unless (string-empty-p line)
                                (funcall on-event
                                         (json-parse-string line :object-type 'alist :array-type 'list))))))
                :sentinel (lambda (proc _event)
                            (when (memq (process-status proc) '(exit signal))
                              (when (not (string-empty-p pending))
                                (funcall on-event
                                         (json-parse-string pending :object-type 'alist :array-type 'list)))
                              (let ((ok (zerop (process-exit-status proc)))
                                    (cancelled (process-get proc 'faltoo-cancelled)))
                                (cond
                                 (cancelled
                                  (funcall on-event '((classes . "status") (text . "Cancelled."))))
                                 ((not ok)
                                  (setq stderr (string-trim
                                                (with-current-buffer stderr-buffer
                                                  (buffer-string))))
                                  (when (string-empty-p stderr)
                                    (setq stderr "Faltoo bridge failed"))
                                  (funcall on-event `((classes . "error") (text . ,stderr)))
                                  (message "%s" stderr)))
                                (kill-buffer buffer)
                                (kill-buffer stderr-buffer)
                                (funcall on-done ok)))))))
    (process-send-string proc (json-serialize payload))
    (process-send-eof proc)
    proc))


(defun faltoo-bridge-tree-rows-stream (workspace on-event on-done)
  "Stream compact transcript tree rows for WORKSPACE as JSONL events."
  (let* ((cmd (faltoo-bridge--command (list "tree-rows" "--workspace" workspace) workspace))
         (buffer (generate-new-buffer " *faltoo-tree-rows*"))
         (stderr-buffer (generate-new-buffer " *faltoo-tree-rows-stderr*"))
         (pending ""))
    (make-process
     :name "faltoo-tree-rows"
     :buffer buffer
     :command cmd
     :connection-type 'pipe
     :noquery t
     :stderr stderr-buffer
     :filter (lambda (_proc chunk)
               (setq pending (concat pending chunk))
               (let ((lines (split-string pending "\n")))
                 (setq pending (car (last lines)))
                 (dolist (line (butlast lines))
                   (unless (string-empty-p line)
                     (funcall on-event
                              (json-parse-string line :object-type 'alist :array-type 'list))))))
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (when (not (string-empty-p pending))
                     (funcall on-event
                              (json-parse-string pending :object-type 'alist :array-type 'list)))
                   (unless (zerop (process-exit-status proc))
                     (let ((stderr (string-trim (with-current-buffer stderr-buffer (buffer-string)))))
                       (funcall on-event `((type . "error") (preview . ,stderr)))
                       (message "%s" stderr)))
                   (kill-buffer buffer)
                   (kill-buffer stderr-buffer)
                   (funcall on-done (zerop (process-exit-status proc))))))))

(defun faltoo-bridge-cancel-stream (process)
  "Cancel a running Faltoo bridge PROCESS."
  (if (process-get process 'faltoo-claude)
      ;; Killing Claude would also kill its background tasks.
      (process-send-string process (concat (json-serialize '((command . "interrupt"))) "\n"))
    (process-put process 'faltoo-cancelled t)
    (delete-process process)))

(defun faltoo-bridge-messages (&optional turns workspace)
  (let* ((workspace (or workspace (faltoo-workspace)))
         (args (list "messages" "--workspace" workspace "--limit" "2000")))
    (when turns
      (setq args (append args (list "--turns" (number-to-string turns)))))
    (alist-get 'messages (faltoo-bridge-call-json args nil workspace))))

(defun faltoo-bridge-unstaged-files (&optional workspace)
  (let* ((workspace (or workspace (faltoo-workspace)))
         (payload (faltoo-bridge-call-json
                   (list "unstaged-files" "--workspace" workspace)
                   nil workspace)))
    (if (eq (alist-get 'ok payload) :false)
        (user-error "%s" (alist-get 'error payload))
      (alist-get 'files payload))))

(defun faltoo-bridge-slash-commands (&optional workspace)
  (let ((workspace (or workspace (faltoo-active-workspace))))
    (alist-get 'commands (faltoo-bridge-call-json (list "slash-commands") nil workspace))))

(defun faltoo-bridge--switch-claude-session (workspace)
  "Stop WORKSPACE's Claude daemon so its next message starts the selected session."
  (when (faltoo-bridge-claude-p workspace)
    (faltoo-bridge-stop-daemon workspace)))

(defun faltoo-bridge-reset-session (&optional workspace)
  "Start a fresh Faltoo session for WORKSPACE and return session info."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-bridge--switch-claude-session workspace)
    (faltoo-bridge-call-json (list "reset-session" "--workspace" workspace) nil workspace)))

(defun faltoo-bridge-name-session (name &optional workspace)
  "Rename current Faltoo session to NAME and return session info."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-bridge-call-json
     (list "name-session" "--workspace" workspace)
     (json-serialize (list (cons 'name name)))
     workspace)))

(defun faltoo-bridge-list-sessions (&optional workspace)
  "Return sessions for WORKSPACE's Faltoo chat key."
  (let ((workspace (or workspace (faltoo-workspace))))
    (alist-get 'sessions
               (faltoo-bridge-call-json
                (list "list-sessions" "--workspace" workspace) nil workspace))))

(defun faltoo-bridge-resume-session (session-id &optional workspace)
  "Resume SESSION-ID for WORKSPACE and return session info."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-bridge--switch-claude-session workspace)
    (faltoo-bridge-call-json
     (list "resume-session" "--workspace" workspace)
     (json-serialize (list (cons 'session_id session-id)))
     workspace)))

(defun faltoo-bridge-status (&optional workspace)
  "Return Faltoo status for WORKSPACE."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-bridge-call-json (list "status" "--workspace" workspace) nil workspace)))

(defun faltoo-bridge-subagents (workspace)
  "Return the sub-agents of WORKSPACE's current Claude session, newest first."
  (alist-get 'agents (faltoo-bridge-call-json (list "subagents" "--workspace" workspace)
                                              nil workspace)))

(defun faltoo-bridge-subagent-messages (agent-id workspace)
  "Return Claude sub-agent AGENT-ID's history messages in WORKSPACE."
  (alist-get 'messages (faltoo-bridge-call-json (list "subagent-messages" "--workspace" workspace)
                                                (json-serialize `((agent_id . ,agent-id)))
                                                workspace)))

(defun faltoo-bridge-messages-path (&optional workspace)
  (let ((workspace (or workspace (faltoo-workspace))))
    (string-trim
     (faltoo-bridge-call-raw (list "messages-path" "--workspace" workspace) nil workspace))))

(provide 'faltoo-bridge)
;;; faltoo-bridge.el ends here
