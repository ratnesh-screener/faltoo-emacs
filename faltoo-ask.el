;;; faltoo-ask.el --- Code-local Ask UI for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-ui)
(require 'faltoo-chat)
(require 'faltoo-request)
(require 'faltoo-compose)

(defvar-local faltoo-ask-context nil)
(defvar-local faltoo-ask-question-marker nil)
(defvar-local faltoo-ask-sent nil)
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

(defun faltoo-ask--insert-prompt (context)
  "Insert Ask popup content for CONTEXT."
  (let ((file (plist-get context :file))
        (start (plist-get context :start))
        (end (plist-get context :end))
        (code (plist-get context :code)))
    (faltoo-compose-insert-title "Ask Faltoo")
    (faltoo-compose-insert-meta "File" file)
    (faltoo-compose-insert-meta "Range" (if (= start end) (format "line %d" start) (format "lines %d-%d" start end)))
    (faltoo-compose-insert-section "Code")
    (faltoo-compose-insert-code code)
    (faltoo-compose-insert-help "C-c C-c send · C-c C-k/C-g close · C-c C-f file · C-c / command")
    (faltoo-compose-insert-section "Question")
    (setq faltoo-ask-question-marker (point-marker))
    (goto-char faltoo-ask-question-marker)))

(defun faltoo-ask ()
  "Ask Faltoo about active region or current line."
  (interactive)
  (let* ((workspace (faltoo-workspace))
         (context (faltoo-ask--context))
         (buf (faltoo-popup-buffer faltoo-popup-buffer #'faltoo-ask-mode)))
    (setq faltoo-ask-last-context context)
    (with-current-buffer buf
      (setq default-directory workspace
            faltoo-ask-context context
            faltoo-ask-sent nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (faltoo-ask--insert-prompt context)))
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
  (if context
      (format "About `%s` lines %d-%d:\n\n```\n%s\n```\n\n%s"
              (plist-get context :file)
              (plist-get context :start)
              (plist-get context :end)
              (plist-get context :code)
              question)
    question))

(defun faltoo-ask--insert-follow-up ()
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (faltoo-compose-insert-section "Follow-up")
    (setq faltoo-ask-question-marker (point-marker)
          faltoo-ask-sent nil)
    (faltoo-ui-fontify-markdown)
    (goto-char faltoo-ask-question-marker)))

(defun faltoo-ask-send ()
  "Send current Ask popup question."
  (interactive)
  (let* ((context faltoo-ask-context)
         (question (faltoo-ask--question-text))
         (message (faltoo-ask--message context question))
         (buf (current-buffer)))
    (faltoo-request-ensure-idle)
    (when faltoo-ask-sent
      (user-error "This Ask has already been sent"))
    (when (string-empty-p question)
      (user-error "Question is empty"))
    (setq faltoo-ask-sent t)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (faltoo-compose-insert-section "Assistant")
        (faltoo-ui-fontify-markdown)))
    (faltoo-request-message
     message buf
     (lambda (ok)
       (when (and ok (buffer-live-p buf))
         (with-current-buffer buf
           (faltoo-ask--insert-follow-up)))))))

(defun faltoo-show-last-response ()
  "Show latest assistant message in a posframe."
  (interactive)
  (let* ((workspace (faltoo-workspace))
         (message (or (gethash workspace faltoo-last-assistant-messages) "")))
    (when (string-empty-p message)
      (dolist (item (reverse (faltoo-bridge-messages nil workspace)))
        (when (and (string-empty-p message)
                   (string= (alist-get 'role item) "assistant"))
          (setq message (alist-get 'text item)))))
    (when (string-empty-p message)
      (user-error "No assistant response yet"))
    (let ((buf (faltoo-popup-buffer faltoo-last-response-buffer #'faltoo-ask-mode)))
      (with-current-buffer buf
        (setq default-directory workspace
              faltoo-ask-context nil
              faltoo-ask-sent nil)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (faltoo-compose-insert-title "Last Assistant Response")
          (insert "\n" message)
          (faltoo-compose-insert-help "C-c C-c send follow-up · C-c C-k/C-g close · C-c C-f file · C-c / command")
          (faltoo-compose-insert-section "Follow-up")
          (setq faltoo-ask-question-marker (point-marker))
          (faltoo-ui-fontify-markdown)
          (goto-char faltoo-ask-question-marker)))
      (faltoo-popup-show buf 100 28))))

(provide 'faltoo-ask)
;;; faltoo-ask.el ends here
