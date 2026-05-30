;;; faltoo-compose.el --- Compose helpers for Faltoo popups -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-faces)

(defun faltoo-compose-insert-title (title)
  "Insert popup TITLE."
  (insert (propertize title 'face 'faltoo-popup-title-face) "\n"))

(defun faltoo-compose-insert-meta (label value)
  "Insert metadata LABEL with VALUE."
  (insert (propertize (format "%s: " label) 'face 'faltoo-popup-meta-face)
          (propertize (format "%s" value) 'face 'faltoo-popup-meta-face)
          "\n"))

(defun faltoo-compose-insert-section (title)
  "Insert section TITLE."
  (insert "\n" (propertize title 'face 'faltoo-popup-section-face) "\n\n"))

(defun faltoo-compose-insert-code (code)
  "Insert CODE with popup code face."
  (let ((start (point)))
    (insert code)
    (add-text-properties start (point) '(face faltoo-popup-code-face))))

(defun faltoo-compose-insert-help (text)
  "Insert dim help TEXT."
  (insert "\n" (propertize text 'face 'faltoo-popup-meta-face) "\n"))

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

(provide 'faltoo-compose)
;;; faltoo-compose.el ends here
