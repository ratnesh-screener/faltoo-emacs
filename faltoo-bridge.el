;;; faltoo-bridge.el --- Python bridge for Faltoo -*- lexical-binding: t; -*-

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
  "Default FaltooBot/FaltooChat command used when a workspace has no override."
  :type 'string
  :group 'faltoo)

(defvar faltoo-faltoobot-workspace-commands (make-hash-table :test #'equal)
  "Per-workspace FaltooBot/FaltooChat command overrides.")

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
         (custom "custom...")
         (choice (completing-read "Faltoo core: " (list release local custom) nil t))
         (command (cond
                   ((string= choice release) faltoo-release-faltoobot-command)
                   ((string= choice local) faltoo-local-faltoobot-command)
                   (t (read-string "Faltoo command: "
                                   (faltoo-bridge-command-for-workspace workspace))))))
    (faltoo-bridge--command-executable command)
    (puthash workspace command faltoo-faltoobot-workspace-commands)
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

(defun faltoo-bridge--command (args &optional workspace)
  (append (list (faltoo-bridge-python workspace) (faltoo-bridge--script)) args))

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

(defun faltoo-bridge-stream (args payload on-event on-done)
  "Run bridge ARGS with PAYLOAD.
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
  (process-put process 'faltoo-cancelled t)
  (delete-process process))

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

(defun faltoo-bridge-session-info (&optional workspace)
  "Return current Faltoo session info for WORKSPACE."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-bridge-call-json (list "session-info" "--workspace" workspace) nil workspace)))

(defun faltoo-bridge-reset-session (&optional workspace)
  "Start a fresh Faltoo session for WORKSPACE and return session info."
  (let ((workspace (or workspace (faltoo-workspace))))
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
    (faltoo-bridge-call-json
     (list "resume-session" "--workspace" workspace)
     (json-serialize (list (cons 'session_id session-id)))
     workspace)))

(defun faltoo-bridge-status (&optional workspace)
  "Return Faltoo status for WORKSPACE."
  (let ((workspace (or workspace (faltoo-workspace))))
    (faltoo-bridge-call-json (list "status" "--workspace" workspace) nil workspace)))

(defun faltoo-bridge-messages-path (&optional workspace)
  (let ((workspace (or workspace (faltoo-workspace))))
    (string-trim
     (faltoo-bridge-call-raw (list "messages-path" "--workspace" workspace) nil workspace))))

(provide 'faltoo-bridge)
;;; faltoo-bridge.el ends here
