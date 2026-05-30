;;; faltoo-bridge.el --- Python bridge for Faltoo -*- lexical-binding: t; -*-

(require 'json)
(require 'subr-x)
(require 'faltoo-core)

(defconst faltoo-bridge-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Root directory of the Faltoo Emacs package.")

(defun faltoo-bridge--script ()
  (expand-file-name "python/faltoo_bridge.py" faltoo-bridge-root))

(defun faltoo-bridge--shebang-python (path)
  (with-temp-buffer
    (insert-file-contents path nil 0 200)
    (goto-char (point-min))
    (let ((line (string-trim (buffer-substring (line-beginning-position) (line-end-position)))))
      (unless (string-prefix-p "#!" line)
        (user-error "Could not resolve Python from faltoobot shebang"))
      (let ((parts (split-string (substring line 2))))
        (if (string= (car parts) "/usr/bin/env")
            (cadr parts)
          (car parts))))))

(defun faltoo-bridge-python ()
  "Return Python executable from the installed faltoobot shim."
  (let ((faltoobot (executable-find "faltoobot")))
    (unless faltoobot
      (user-error "faltoobot command not found in PATH"))
    (faltoo-bridge--shebang-python faltoobot)))

(defun faltoo-bridge--command (args)
  (append (list (faltoo-bridge-python) (faltoo-bridge--script)) args))

(defun faltoo-bridge-call-raw (args &optional input)
  "Run bridge ARGS synchronously with INPUT and return stdout."
  (let* ((cmd (faltoo-bridge--command args))
         (program (car cmd))
         (program-args (cdr cmd))
         (stdin-file (when input (make-temp-file "faltoo-stdin")))
         (stderr-file (make-temp-file "faltoo-stderr"))
         code out err)
    (unwind-protect
        (progn
          (when stdin-file (write-region input nil stdin-file nil 'silent))
          (with-temp-buffer
            (setq code (apply #'process-file program stdin-file (list t stderr-file) nil program-args))
            (setq out (buffer-string)))
          (setq err (with-temp-buffer
                      (insert-file-contents stderr-file)
                      (string-trim (buffer-string))))
          (unless (zerop code)
            (user-error "%s" (if (string-empty-p err) "Faltoo bridge failed" err)))
          out)
      (when stdin-file (delete-file stdin-file))
      (delete-file stderr-file))))

(defun faltoo-bridge-call-json (args &optional input)
  "Run bridge ARGS and parse JSON output."
  (json-parse-string (faltoo-bridge-call-raw args input)
                     :object-type 'alist :array-type 'list))

(defun faltoo-bridge-stream (args payload on-event on-done)
  "Run bridge ARGS with PAYLOAD.
Call ON-EVENT for each JSONL event and ON-DONE with t/nil at exit."
  (let* ((cmd (faltoo-bridge--command args))
         (buffer (generate-new-buffer " *faltoo-bridge*"))
         (pending "")
         (stderr "")
         (proc (make-process
                :name "faltoo-bridge"
                :buffer buffer
                :command cmd
                :connection-type 'pipe
                :noquery t
                :filter (lambda (_proc chunk)
                          (setq pending (concat pending chunk))
                          (let ((lines (split-string pending "\n")))
                            (setq pending (car (last lines)))
                            (dolist (line (butlast lines))
                              (unless (string-empty-p line)
                                (funcall on-event
                                         (json-parse-string line :object-type 'alist :array-type 'list))))))
                :sentinel (lambda (proc _event)
                            (when (memq (process-status proc) '(exit signal))
                              (when (not (string-empty-p pending))
                                (funcall on-event
                                         (json-parse-string pending :object-type 'alist :array-type 'list)))
                              (let ((ok (zerop (process-exit-status proc))))
                                (unless ok
                                  (setq stderr (with-current-buffer buffer (buffer-string)))
                                  (message "%s" (if (string-empty-p stderr) "Faltoo bridge failed" stderr)))
                                (kill-buffer buffer)
                                (funcall on-done ok)))))))
    (process-send-string proc (json-serialize payload))
    (process-send-eof proc)
    proc))

(defun faltoo-bridge-messages ()
  (alist-get 'messages
             (faltoo-bridge-call-json
              (list "messages" "--workspace" (faltoo-workspace) "--limit" "100"))))

(defun faltoo-bridge-unstaged-files ()
  (let ((payload (faltoo-bridge-call-json
                  (list "unstaged-files" "--workspace" (faltoo-workspace)))))
    (if (eq (alist-get 'ok payload) :false)
        (user-error "%s" (alist-get 'error payload))
      (alist-get 'files payload))))

(defun faltoo-bridge-slash-commands ()
  (alist-get 'commands (faltoo-bridge-call-json (list "slash-commands"))))

(defun faltoo-bridge-messages-path ()
  (string-trim (faltoo-bridge-call-raw (list "messages-path" "--workspace" (faltoo-workspace)))))

(provide 'faltoo-bridge)
;;; faltoo-bridge.el ends here
