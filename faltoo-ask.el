;;; faltoo-ask.el --- Code-local Ask UI for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)
(require 'faltoo-chat)
(require 'faltoo-request)

(defvar-local faltoo-ask-context nil)
(defvar-local faltoo-ask-question-marker nil)
(defvar faltoo-ask-last-context nil)

(defvar faltoo-ask-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map faltoo-popup-mode-map)
    (define-key map (kbd "C-c C-c") #'faltoo-ask-send)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    (define-key map (kbd "C-c /") #'faltoo-insert-slash-command)
    map))

(define-derived-mode faltoo-ask-mode faltoo-popup-mode "Faltoo-Ask"
  "Mode for asking Faltoo about code.")

(defun faltoo-ask--context ()
  "Return context from active region or current line."
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (region-end)))
        (list :file (faltoo-relative-file (faltoo-current-file))
              :start (line-number-at-pos beg)
              :end (line-number-at-pos end)
              :code (buffer-substring-no-properties beg end)))
    (list :file (faltoo-relative-file (faltoo-current-file))
          :start (line-number-at-pos)
          :end (line-number-at-pos)
          :code (string-trim-right (thing-at-point 'line t)))))

(defun faltoo-ask--prompt-lines (context)
  (let ((file (plist-get context :file))
        (start (plist-get context :start))
        (end (plist-get context :end))
        (code (plist-get context :code)))
    (append (list (format "File: %s" file)
                  (if (= start end) (format "Line: %d" start) (format "Lines: %d-%d" start end))
                  ""
                  "Code:"
                  "```")
            (split-string code "\n")
            (list "```" "" "Question:" ""))))

(defun faltoo-ask ()
  "Ask Faltoo about active region or current line."
  (interactive)
  (faltoo-workspace)
  (let* ((context (faltoo-ask--context))
         (buf (faltoo-popup-buffer faltoo-popup-buffer #'faltoo-ask-mode)))
    (setq faltoo-ask-last-context context)
    (with-current-buffer buf
      (setq faltoo-ask-context context)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (string-join (faltoo-ask--prompt-lines context) "\n"))
        (setq faltoo-ask-question-marker (point-marker))))
    (faltoo-popup-show buf 100 28)))

(defun faltoo-ask-region ()
  "Ask Faltoo about active region."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (faltoo-ask))

(defun faltoo-ask--question-text ()
  (string-trim (buffer-substring-no-properties faltoo-ask-question-marker (point-max))))

(defun faltoo-ask--message (context question)
  (format "About `%s` lines %d-%d:\n\n```\n%s\n```\n\n%s"
          (plist-get context :file)
          (plist-get context :start)
          (plist-get context :end)
          (plist-get context :code)
          question))

(defun faltoo-ask-send ()
  "Send current Ask popup question."
  (interactive)
  (let* ((context faltoo-ask-context)
         (question (faltoo-ask--question-text))
         (message (faltoo-ask--message context question))
         (buf (current-buffer)))
    (when (string-empty-p question)
      (user-error "Question is empty"))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "

Assistant:

")))
    (faltoo-request-message message buf)))

(defun faltoo-insert-file-reference ()
  "Insert a backtick file reference using Git tracked/untracked files."
  (interactive)
  (let* ((default-directory (faltoo-workspace))
         (files (split-string (shell-command-to-string "git ls-files --cached --others --exclude-standard") "\n" t))
         (file (completing-read "File: " files nil t)))
    (insert "`" file "`")))

(defun faltoo-insert-slash-command ()
  "Insert a saved Faltoo slash command."
  (interactive)
  (let* ((commands (faltoo-bridge-slash-commands))
         (labels (mapcar (lambda (cmd)
                           (let ((name (alist-get 'command cmd))
                                 (preview (or (alist-get 'preview cmd) "")))
                             (if (string-empty-p preview) name (format "%s — %s" name preview))))
                         commands))
         (choice (completing-read "Command: " labels nil t))
         (index (cl-position choice labels :test #'string=)))
    (insert (alist-get 'command (nth index commands)))))

(defun faltoo-show-last-response ()
  "Show latest assistant message in a posframe."
  (interactive)
  (let ((message faltoo-last-assistant-message))
    (when (string-empty-p message)
      (dolist (item (reverse (faltoo-bridge-messages)))
        (when (and (string-empty-p message)
                   (string= (alist-get 'role item) "assistant"))
          (setq message (alist-get 'text item)))))
    (when (string-empty-p message)
      (user-error "No assistant response yet"))
    (let ((buf (faltoo-popup-buffer faltoo-last-response-buffer #'faltoo-popup-mode)))
      (faltoo-popup-set-lines buf (split-string message "\n"))
      (with-current-buffer buf (setq buffer-read-only t))
      (faltoo-popup-show buf 100 28))))

(provide 'faltoo-ask)
;;; faltoo-ask.el ends here
