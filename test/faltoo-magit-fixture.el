;;; faltoo-magit-fixture.el --- Magit parser for synthetic review specs -*- lexical-binding: t; -*-
(require 'package)
(package-initialize)
(require 'magit)

(defun faltoo-test--insert-diff (&rest args)
  "Parse the current fixture with Magit, without querying a Git repository."
  (magit-insert-section (file "sample")
    (magit-insert-heading "sample")
    (let ((start (point)))
      (insert (faltoo-test--patch nil (and (member "--cached" args) t)) "\n")
      (goto-char start)
      (while (magit-diff-wash-hunk)))))
