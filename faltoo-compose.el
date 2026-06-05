;;; faltoo-compose.el --- Compose helpers for Faltoo popups -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-faces)
(require 'faltoo-ui)

(declare-function faltoo-chat-refresh "faltoo-chat")

(defun faltoo-compose-insert-title (title)
  "Insert Markdown popup TITLE."
  (insert "# " title "\n"))

(defun faltoo-compose-insert-meta (label value)
  "Insert metadata LABEL with VALUE."
  (insert (propertize (format "%s: " label) 'face 'faltoo-popup-meta-face)
          (propertize (format "%s" value) 'face 'faltoo-popup-meta-face)
          "\n"))

(defun faltoo-compose-insert-section (title)
  "Insert Markdown section TITLE with a proper rule boundary."
  (let ((start (point)))
    (unless (bobp)
      (cond
       ((looking-back "\n\n" nil))
       ((looking-back "\n" nil) (insert "\n"))
       (t (insert "\n\n"))))
    (insert "---\n## " title "\n\n")
    (add-text-properties start (point) '(rear-nonsticky t))))

(defun faltoo-compose-insert-code (code)
  "Insert CODE as a Markdown code block."
  (insert "```text\n")
  (let ((start (point)))
    (insert code)
    (add-text-properties start (point) '(face faltoo-popup-code-face)))
  (insert "\n```\n"))

(defun faltoo-compose-insert-help (text)
  "Insert dim help TEXT."
  (insert "\n" (propertize text 'face 'faltoo-popup-meta-face) "\n"))

(defun faltoo-compose-set-message (buffer title text &optional read-only)
  "Replace BUFFER with Markdown TITLE and TEXT."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (setq buffer-read-only nil)
      (erase-buffer)
      (faltoo-compose-insert-title title)
      (insert "\n" text)
      (faltoo-ui-fontify-markdown)
      (goto-char (point-min))
      (when read-only
        (setq buffer-read-only t)))))

(defconst faltoo-session-commands
  '(((command . "/name") (preview . "name the current session"))
    ((command . "/reset") (preview . "start a fresh session"))
    ((command . "/resume") (preview . "resume another session"))
    ((command . "/status") (preview . "show Faltoo status"))
    ((command . "/tree") (preview . "open current session messages.json")))
  "Built-in Faltoo session commands handled by Emacs.")

(defun faltoo-session-reset ()
  "Start a fresh Faltoo session for the current workspace."
  (interactive)
  (let ((info (faltoo-bridge-reset-session (faltoo-workspace))))
    (when (fboundp 'faltoo-chat-refresh)
      (faltoo-chat-refresh))
    (message "Faltoo session reset: %s" (alist-get 'session_id info))))

(defun faltoo-session-name (name)
  "Rename the current Faltoo session to NAME. Empty NAME clears it."
  (interactive (list (read-string "Session name (empty clears): ")))
  (let ((info (faltoo-bridge-name-session name (faltoo-workspace))))
    (when (fboundp 'faltoo-chat-refresh)
      (faltoo-chat-refresh))
    (message "Faltoo session named: %s" (alist-get 'session_id info))))


(defun faltoo-session-tree ()
  "Open the current Faltoo session messages JSON file."
  (interactive)
  (find-file (faltoo-bridge-messages-path (faltoo-workspace))))

(defun faltoo-session-status--pretty-json (text)
  "Return pretty JSON for TEXT, or TEXT when parsing fails."
  (with-temp-buffer
    (insert text)
    (condition-case nil
        (progn
          (json-pretty-print (point-min) (point-max))
          (string-trim (buffer-string)))
      (error text))))

(defun faltoo-session-status--markdown (text)
  "Return pretty Markdown for Faltoo status TEXT."
  (mapconcat
   (lambda (line)
     (cond
      ((string-empty-p line) "")
      ((string= line "Faltoobot status") "")
      ((member line '("Session" "Config status" "Session usage"))
       (format "---\n## %s" line))
      ((string-prefix-p "• last_usage=" line)
       (concat "- last_usage:\n```json\n"
               (faltoo-session-status--pretty-json (substring line 13))
               "\n```"))
      ((string-prefix-p "• " line)
       (concat "- " (substring line 2)))
      (t line)))
   (split-string text "\n")
   "\n"))

(defun faltoo-session-status ()
  "Show current Faltoo status in a temporary popup."
  (interactive)
  (let* ((status (faltoo-bridge-status (faltoo-workspace)))
         (buf (faltoo-popup-buffer "*Faltoo Status*" #'faltoo-popup-mode)))
    (with-current-buffer buf
      (setq default-directory (file-name-as-directory (alist-get 'workspace status)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (faltoo-compose-insert-title "Faltoo Status")
        (insert "\n" (faltoo-session-status--markdown (alist-get 'text status)))
        (faltoo-compose-insert-help "C-c C-k/C-g close")
        (goto-char (point-min))
        (setq buffer-read-only t)))
    (faltoo-popup-show buf 100 30)))

(defun faltoo-session-resume (&optional session-id)
  "Resume Faltoo SESSION-ID for the current workspace."
  (interactive)
  (let* ((sessions (faltoo-bridge-list-sessions (faltoo-workspace)))
         (labels (mapcar (lambda (session)
                           (or (alist-get 'name session) (alist-get 'id session)))
                         sessions))
         (choice (or session-id (completing-read "Resume session: " labels nil t)))
         (selected (or (cl-find choice sessions
                                :key (lambda (session)
                                       (or (alist-get 'name session) (alist-get 'id session)))
                                :test #'string=)
                       (cl-find choice sessions
                                :key (lambda (session) (alist-get 'id session))
                                :test #'string=)))
         (info (faltoo-bridge-resume-session (or (alist-get 'id selected) choice)
                                             (faltoo-workspace))))
    (when (fboundp 'faltoo-chat-refresh)
      (faltoo-chat-refresh))
    (message "Faltoo session resumed: %s" (alist-get 'session_id info))))

(defun faltoo-run-session-command ()
  "Run a built-in Faltoo session command."
  (interactive)
  (let* ((labels (mapcar (lambda (cmd)
                           (format "%s — %s"
                                   (alist-get 'command cmd)
                                   (alist-get 'preview cmd)))
                         faltoo-session-commands))
         (choice (completing-read "Command: " labels nil t))
         (command (alist-get 'command (nth (cl-position choice labels :test #'string=)
                                           faltoo-session-commands))))
    (pcase command
      ("/reset" (faltoo-session-reset))
      ("/name" (call-interactively #'faltoo-session-name))
      ("/resume" (faltoo-session-resume))
      ("/status" (faltoo-session-status))
      ("/tree" (faltoo-session-tree)))))

(defun faltoo-insert-file-reference ()
  "Insert a backtick file reference using Git tracked/untracked files."
  (interactive)
  (let* ((default-directory (faltoo-workspace))
         (files (split-string (shell-command-to-string "git ls-files --cached --others --exclude-standard") "\n" t))
         (file (completing-read "File: " files nil t)))
    (insert "`" file "`")))

(defun faltoo-insert-prompt-template ()
  "Insert the selected saved Faltoo prompt template."
  (interactive)
  (let* ((commands (faltoo-bridge-slash-commands))
         (labels (mapcar (lambda (cmd)
                           (let ((name (alist-get 'command cmd))
                                 (preview (or (alist-get 'preview cmd) "")))
                             (if (string-empty-p preview) name (format "%s — %s" name preview))))
                         commands))
         (choice (completing-read "Command: " labels nil t))
         (index (cl-position choice labels :test #'string=))
         (command (nth index commands)))
    (insert (or (alist-get 'template command)
                (alist-get 'command command)))))

(provide 'faltoo-compose)
;;; faltoo-compose.el ends here
