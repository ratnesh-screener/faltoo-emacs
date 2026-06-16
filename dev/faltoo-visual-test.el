;;; faltoo-visual-test.el --- Local visual export helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'package)
(require 'server)

(defvar htmlize-output-type)
(declare-function htmlize-buffer "htmlize")

(defvar faltoo-dev-export-file "/tmp/faltoo-current-buffer.html"
  "Default HTML export path for visual Faltoo testing.")

(defun faltoo-dev-ensure-htmlize ()
  "Install and load htmlize for local visual testing."
  (unless package--initialized
    (package-initialize))
  (unless (assoc "melpa" package-archives)
    (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t))
  (unless (package-installed-p 'htmlize)
    (package-refresh-contents)
    (package-install 'htmlize))
  (require 'htmlize))

(defun faltoo-dev--tree-buffer ()
  "Return the first Faltoo tree buffer, or the current buffer."
  (or (cl-find-if (lambda (buffer)
                    (string-prefix-p "*Faltoo Tree:" (buffer-name buffer)))
                  (buffer-list))
      (current-buffer)))

(defun faltoo-dev-export-buffer-html (&optional buffer file)
  "Export BUFFER with faces to FILE using htmlize."
  (interactive)
  (faltoo-dev-ensure-htmlize)
  (let* ((source (cond
                  ((bufferp buffer) buffer)
                  ((stringp buffer) (get-buffer buffer))
                  (t (current-buffer))))
         (target (or file faltoo-dev-export-file))
         (htmlize-output-type 'inline-css)
         (html-buffer (with-current-buffer source
                        (htmlize-buffer))))
    (with-current-buffer html-buffer
      (write-region (point-min) (point-max) target nil 'silent))
    (kill-buffer html-buffer)
    (message "Faltoo visual export: %s" target)
    target))

(defun faltoo-dev-export-tree-html (&optional file)
  "Export the first Faltoo tree buffer to FILE."
  (interactive)
  (faltoo-dev-export-buffer-html (faltoo-dev--tree-buffer)
                                 (or file "/tmp/faltoo-tree.html")))

(unless (server-running-p)
  (server-start))

(message "Faltoo visual test helpers loaded. Use M-x faltoo-dev-export-tree-html.")

(provide 'faltoo-visual-test)
;;; faltoo-visual-test.el ends here
