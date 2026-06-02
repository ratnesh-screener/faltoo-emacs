;;; faltoo-compose.el --- Compose helpers for Faltoo popups -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-faces)
(require 'faltoo-ui)

(defun faltoo-compose-insert-title (title)
  "Insert Markdown popup TITLE."
  (insert "# " title "\n"))

(defun faltoo-compose-insert-meta (label value)
  "Insert metadata LABEL with VALUE."
  (insert (propertize (format "%s: " label) 'face 'faltoo-popup-meta-face)
          (propertize (format "%s" value) 'face 'faltoo-popup-meta-face)
          "\n"))

(defun faltoo-compose-insert-section (title)
  "Insert Markdown section TITLE."
  (insert "\n---\n## " title "\n\n"))

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

(defun faltoo-insert-file-reference ()
  "Insert a backtick file reference using Git tracked/untracked files."
  (interactive)
  (let* ((default-directory (faltoo-workspace))
         (files (split-string (shell-command-to-string "git ls-files --cached --others --exclude-standard") "\n" t))
         (file (completing-read "File: " files nil t)))
    (insert "`" file "`")))

(defun faltoo-insert-slash-command ()
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
