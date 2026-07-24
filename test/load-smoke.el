;;; load-smoke.el -*- lexical-binding: t; -*-
(add-to-list 'load-path default-directory)

(define-derived-mode markdown-mode text-mode "Markdown")
(provide 'markdown-mode)

(defun posframe-show (&rest _args))
(defun posframe-hide-all ())
(defun posframe-hide (&rest _args))
(provide 'posframe)
(defun magit-stage-file (&rest _args))
(defun magit-unstage-file (&rest _args))
(defun magit-status (&rest _args))
(defun magit-diff-working-tree (&rest _args))
(defun magit-refresh (&rest _args))
(provide 'magit)
(load-file "faltoo.el")
(princ "loaded\n")
