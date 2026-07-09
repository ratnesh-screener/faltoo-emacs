;;; faltoo-quit.el --- Quit guard for Faltoo -*- lexical-binding: t; -*-

(require 'faltoo-core)

(defun faltoo-pending-work-labels ()
  "Return labels for pending Faltoo work."
  (append
   (when (faltoo-any-submitting-p) (list "a running request"))
   (when (fboundp 'faltoo-comments-total-count)
     (let ((count (faltoo-comments-total-count)))
       (when (> count 0)
         (list (format "%d pending review comment(s)" count)))))))

(defun faltoo-has-pending-work-p ()
  "Return non-nil when Faltoo has pending work."
  (not (null (faltoo-pending-work-labels))))

(defun faltoo-confirm-kill-emacs ()
  "Ask before quitting Emacs with pending Faltoo work."
  (or (not (faltoo-has-pending-work-p))
      (yes-or-no-p
       (format "Faltoo has %s. Quit anyway? "
               (string-join (faltoo-pending-work-labels) " and ")))))

(add-hook 'kill-emacs-query-functions #'faltoo-confirm-kill-emacs)

(provide 'faltoo-quit)
;;; faltoo-quit.el ends here
