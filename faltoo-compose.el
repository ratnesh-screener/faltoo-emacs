;;; faltoo-compose.el --- Compose helpers for Faltoo popups -*- lexical-binding: t; -*-

(require 'subr-x)
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

(provide 'faltoo-compose)
;;; faltoo-compose.el ends here
