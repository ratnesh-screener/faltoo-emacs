;;; faltoo-compose.el --- Compose helpers for Faltoo popups -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-faces)
(require 'faltoo-ui)
(require 'faltoo-tree)

(declare-function faltoo-chat-refresh "faltoo-chat")

(defun faltoo-compose-tool-summary (text)
  "Return the compact transcript summary for tool TEXT."
  (let* ((summary (string-trim
                   (replace-regexp-in-string
                    "\\*\\*" ""
                    (car (split-string text "\n\n<!-- shell-command -->\n\n" t)))))
         (lines (split-string summary "\n"))
         (spec (pcase (car lines)
                 ("load_skill" '("Load Skill" skill_name))
                 ("load_image" '("Load Image" image_path)))))
    (cond
     (spec
      (format "%s: %s" (car spec)
              (alist-get (cadr spec)
                         (json-parse-string (string-join (cdr lines) "\n")
                                            :object-type 'alist))))
     ((> (length lines) 5)
      (string-join (append (cl-subseq lines 0 4) '("...")) "\n"))
     (t summary))))

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

(defun faltoo-compose-insert-code (code &optional language)
  "Insert CODE as a Markdown code block for LANGUAGE."
  (insert "```" (or language "text") "\n")
  (let ((start (point)))
    (insert code)
    (add-text-properties start (point) '(face faltoo-popup-code-face)))
  (insert "\n```\n"))

(defun faltoo-compose-insert-help (text)
  "Insert dim help TEXT."
  (insert "\n" (propertize text 'face 'faltoo-popup-meta-face) "\n"))

(defun faltoo-session-workspace ()
  "Return the workspace for commands run from source, popup, or transcript buffers."
  (faltoo-active-workspace))

(defconst faltoo-session-commands
  '(((command . "/name") (preview . "name the current session"))
    ((command . "/reset") (preview . "start a fresh session"))
    ((command . "/resume") (preview . "resume another session"))
    ((command . "/status") (preview . "show Faltoo status"))
    ((command . "/steer") (preview . "nudge the running Claude answer"))
    ((command . "/btw") (preview . "ask Claude a side question, kept out of the session"))
    ((command . "/compact") (preview . "summarize the Claude conversation to free context"))
    ((command . "/tree") (preview . "inspect current session messages")))
  "Built-in Faltoo session commands handled by Emacs.")

(defun faltoo-session-reset ()
  "Start a fresh Faltoo session for the current workspace."
  (interactive)
  (let ((info (faltoo-bridge-reset-session (faltoo-session-workspace))))
    (when (fboundp 'faltoo-chat-refresh)
      (faltoo-chat-refresh))
    (message "Faltoo session reset: %s" (alist-get 'session_id info))))

(defun faltoo-session-name (name)
  "Rename the current Faltoo session to NAME. Empty NAME clears it."
  (interactive (list (read-string "Session name (empty clears): ")))
  (let ((info (faltoo-bridge-name-session name (faltoo-session-workspace))))
    (when (fboundp 'faltoo-chat-refresh)
      (faltoo-chat-refresh))
    (message "Faltoo session named: %s" (alist-get 'session_id info))))


(defvar faltoo-request-processes)

(declare-function faltoo-request-message "faltoo-request")

(defvar-local faltoo-input-text-marker nil)
(defvar-local faltoo-input-on-submit nil)
(defvar-local faltoo-input-allow-empty nil)

(defvar faltoo-input-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map faltoo-popup-mode-map)
    (define-key map (kbd "C-c C-c") #'faltoo-input-submit)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    map))

(define-derived-mode faltoo-input-mode faltoo-popup-mode "Faltoo-Input"
  "Editable popup that hands its text to a callback on submit.")

(defun faltoo-popup-read (title workspace on-submit &optional allow-empty)
  "Read text for WORKSPACE in a popup titled TITLE.
\\[faltoo-input-submit] closes it and calls ON-SUBMIT with the trimmed text;
empty text is refused unless ALLOW-EMPTY."
  (let ((buf (faltoo-popup-buffer "*Faltoo Input*" #'faltoo-input-mode)))
    (with-current-buffer buf
      (setq default-directory workspace
            faltoo-input-on-submit on-submit
            faltoo-input-allow-empty allow-empty)
      (faltoo-compose-insert-title title)
      (faltoo-compose-insert-help "C-c C-c send · C-c C-k/C-g close · C-c C-f file")
      (insert "\n")
      (setq faltoo-input-text-marker (point-marker)))
    (faltoo-popup-show buf 80 12)))

(defun faltoo-input-submit ()
  "Close the input popup and hand its text to its callback."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties faltoo-input-text-marker (point-max))))
        (on-submit faltoo-input-on-submit))
    (when (and (string-empty-p text) (not faltoo-input-allow-empty))
      (user-error "Nothing to send"))
    (faltoo-popup-close)
    (funcall on-submit text)))

(defun faltoo-session-steer ()
  "Steer the running Claude answer; Claude takes the text at its next step."
  (interactive)
  (let ((workspace (faltoo-session-workspace)))
    (unless (and (faltoo-bridge-claude-p workspace)
                 (gethash workspace faltoo-request-processes))
      (user-error "No running Claude answer to steer"))
    (faltoo-popup-read
     "Steer the running answer" workspace
     (lambda (text)
       (if (gethash workspace faltoo-request-processes)
           (progn
             (faltoo-bridge-claude-send workspace text "steer")
             (message "Steer sent; Claude takes it at its next step"))
         ;; The answer finished while typing; Claude would take it as the next prompt too.
         (faltoo-request-message text nil nil nil workspace))))))

(declare-function faltoo-request-claude-submit "faltoo-request")

(defun faltoo-session-compact ()
  "Compact the Claude conversation; an optional focus says what the summary keeps."
  (interactive)
  (let ((workspace (faltoo-session-workspace)))
    (unless (faltoo-bridge-claude-p workspace)
      (user-error "Compacting needs the Claude core"))
    (when (faltoo-workspace-submitting-p workspace)
      (user-error "Wait for the running answer to finish"))
    (faltoo-popup-read
     "Compact the conversation (optional focus)" workspace
     (lambda (focus)
       (faltoo-request-claude-submit
        workspace (list :text (string-trim (concat "/compact " focus)) :send focus) "compact"))
     t)))

(defvar-local faltoo-btw-question nil
  "Side question this buffer shows; streams for older ones are ignored.")

(define-derived-mode faltoo-btw-mode markdown-mode "Faltoo-BTW"
  "Read-only answer to the latest side question."
  (faltoo-ui-enable-pretty-markdown)
  (setq-local truncate-lines nil)
  (setq buffer-read-only t))

(defun faltoo-session-btw ()
  "Ask Claude a side question, answered from an unsaved fork of the session.
The answer streams into a reusable buffer shown without taking focus."
  (interactive)
  (let ((workspace (faltoo-session-workspace)))
    (unless (faltoo-bridge-claude-p workspace)
      (user-error "Side questions need the Claude core"))
    (faltoo-popup-read "Side question" workspace
                       (lambda (question) (faltoo-session--btw-ask workspace question)))))

(defun faltoo-session--btw-ask (workspace question)
  "Stream the answer to side QUESTION for WORKSPACE into its reusable buffer."
  (let* (;; A fresh string per ask identifies its stream even for equal text.
         (token (copy-sequence question))
         (buf (get-buffer-create
               (format "*Faltoo BTW: %s*" (file-name-nondirectory (directory-file-name workspace))))))
    (with-current-buffer buf
      (faltoo-btw-mode)
      (setq default-directory workspace
            faltoo-btw-question token)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# Side question\n\n" question "\n\n---\n# Answer\n\n"))
      (faltoo-popup-start-stream buf))
    (faltoo-bridge-btw
     workspace question
     (lambda (event)
       (when (and (buffer-live-p buf)
                  (eq token (buffer-local-value 'faltoo-btw-question buf)))
         (let ((text (or (alist-get 'text event) "")))
           (pcase (or (alist-get 'classes event) (alist-get 'type event))
             ("answer" (faltoo-popup-append-stream buf text))
             ((or "tool" "status")
              (faltoo-popup-append-stream-block buf (faltoo-compose-tool-summary text)
                                                'faltoo-chat-tool-face))
             ("error"
              (faltoo-popup-append-stream-block buf (format "Error: %s" (string-trim text))
                                                'faltoo-chat-error-face))))))
     (lambda (ok)
       (when (and (buffer-live-p buf)
                  (eq token (buffer-local-value 'faltoo-btw-question buf)))
         (message (if ok "Side question answered" "Side question failed")))))
    (display-buffer buf)))

(defun faltoo-session-tree ()
  "Open the current Faltoo session transcript inspector."
  (interactive)
  (faltoo-tree-open (faltoo-session-workspace)))

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
  (let* ((status (faltoo-bridge-status (faltoo-session-workspace)))
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

(defun faltoo-session-completion-table (labels &optional annotate)
  "Return a completion table that preserves FaltooBot's LABELS order.
ANNOTATE, when non-nil, returns the annotation for a label."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata
          (display-sort-function . identity)
          (cycle-sort-function . identity)
          (annotation-function . ,annotate))
      (complete-with-action action labels string pred))))

(defun faltoo-session-resume (&optional session-id)
  "Resume Faltoo SESSION-ID for the current workspace."
  (interactive)
  (let* ((sessions (faltoo-bridge-list-sessions (faltoo-session-workspace)))
         (labeled (let (seen)
                    (mapcar (lambda (session)
                              (let* ((id (alist-get 'id session))
                                     (name (or (alist-get 'name session) id))
                                     ;; Repeated titles keep their short id to stay selectable.
                                     (label (if (member name seen)
                                                (format "%s · %s" name (string-limit id 8))
                                              name)))
                                (push name seen)
                                (cons label session)))
                            sessions)))
         (choice (or session-id
                     (completing-read
                      "Resume session: "
                      (faltoo-session-completion-table
                       (mapcar #'car labeled)
                       (lambda (label)
                         (let ((session (cdr (assoc label labeled))))
                           (when-let ((modified (alist-get 'modified session)))
                             (propertize (format "  %s · %s" modified
                                                 (string-limit (alist-get 'id session) 8))
                                         'face 'completions-annotations)))))
                      nil t)))
         (selected (or (cdr (assoc choice labeled))
                       (cl-find choice sessions
                                :key (lambda (session) (alist-get 'id session))
                                :test #'string=)))
         (info (faltoo-bridge-resume-session (or (alist-get 'id selected) choice)
                                             (faltoo-session-workspace))))
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
      ("/steer" (faltoo-session-steer))
      ("/btw" (faltoo-session-btw))
      ("/compact" (faltoo-session-compact))
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
         (labels (let (seen)
                   (mapcar (lambda (cmd)
                             (let* ((name (alist-get 'command cmd))
                                    (preview (or (alist-get 'preview cmd) ""))
                                    (label (if (string-empty-p preview)
                                               name
                                             (format "%s — %s" name preview))))
                               (push label seen)
                               ;; A prompt copied between sources stays selectable.
                               (if (member label (cdr seen))
                                   (format "%s · %s" label (alist-get 'source cmd))
                                 label)))
                           commands)))
         (choice (completing-read
                  "Command: "
                  (faltoo-session-completion-table
                   labels
                   (lambda (label)
                     (when-let ((source (alist-get 'source
                                                   (nth (cl-position label labels :test #'string=)
                                                        commands))))
                       (propertize (concat "  " source) 'face 'completions-annotations))))
                  nil t))
         (index (cl-position choice labels :test #'string=))
         (command (nth index commands)))
    (insert (or (alist-get 'template command)
                (alist-get 'command command)))))

(provide 'faltoo-compose)
;;; faltoo-compose.el ends here
