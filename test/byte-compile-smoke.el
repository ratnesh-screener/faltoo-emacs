;;; byte-compile-smoke.el -*- lexical-binding: t; -*-
(add-to-list 'load-path default-directory)
(require 'package)
(package-initialize)
(require 'magit)

(define-derived-mode markdown-mode text-mode "Markdown")
(provide 'markdown-mode)

(defun posframe-show (&rest _args))
(defun posframe-hide-all ())
(defun posframe-hide (&rest _args))
(provide 'posframe)
(setq byte-compile-error-on-warn nil)
(dolist (file '("faltoo-core.el" "faltoo-faces.el" "faltoo-ui.el" "faltoo-compose.el" "faltoo-bridge.el" "faltoo-chat.el" "faltoo-request.el" "faltoo-ask.el" "faltoo-comments.el" "faltoo-review.el" "faltoo-quit.el" "faltoo.el"))
  (byte-compile-file file))
(princ "compiled\n")
