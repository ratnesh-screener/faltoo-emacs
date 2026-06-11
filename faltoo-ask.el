;;; faltoo-ask.el --- Code-local Ask UI for Faltoo -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-ui)
(require 'faltoo-request)
(require 'faltoo-compose)

(defvar-local faltoo-ask-context nil)
(defvar-local faltoo-ask-question-marker nil)
(defvar-local faltoo-ask-sent nil)
(defvar-local faltoo-last-response-message nil)

(defvar faltoo-ask-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map faltoo-popup-mode-map)
    (define-key map (kbd "C-c C-c") #'faltoo-ask-send)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    (define-key map (kbd "C-c /") #'faltoo-run-session-command)
    (define-key map (kbd "C-c p") #'faltoo-insert-prompt-template)
    map))

(define-derived-mode faltoo-ask-mode faltoo-popup-mode "Faltoo-Ask"
  "Mode for asking Faltoo about code.")

(defun faltoo-ask--context ()
  "Return full-line context from active region or current line."
  (let ((range (faltoo-current-line-range)))
    (list :file (faltoo-relative-file (faltoo-current-file))
          :start (nth 2 range)
          :end (nth 3 range)
          :code (nth 4 range)
          :language (faltoo-current-language))))

(defun faltoo-ask--insert-prompt (context)
  "Insert Ask popup content for CONTEXT."
  (let ((file (plist-get context :file))
        (start (plist-get context :start))
        (end (plist-get context :end))
        (code (plist-get context :code))
        (language (plist-get context :language)))
    (faltoo-compose-insert-title "Ask Faltoo")
    (faltoo-compose-insert-meta "File" file)
    (faltoo-compose-insert-meta "Range" (if (= start end) (format "line %d" start) (format "lines %d-%d" start end)))
    (faltoo-compose-insert-section "Code")
    (faltoo-compose-insert-code code language)
    (faltoo-compose-insert-help "C-c C-c send · C-c C-k/C-g close · C-c C-f file · C-c / command · C-c p prompt")
    (faltoo-compose-insert-section "Question")
    (setq faltoo-ask-question-marker (point-marker))
    (goto-char faltoo-ask-question-marker)))

(defun faltoo-ask ()
  "Ask Faltoo about active region or current line."
  (interactive)
  (let* ((workspace (faltoo-workspace))
         (context (faltoo-ask--context))
         (buf (faltoo-popup-buffer faltoo-popup-buffer #'faltoo-ask-mode)))
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
      (format "About `%s` lines %d-%d:\n\n```%s\n%s\n```\n\n%s"
              (plist-get context :file)
              (plist-get context :start)
              (plist-get context :end)
              (plist-get context :language)
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

(defun faltoo-last-response-buffer-name (workspace)
  (format "*Faltoo Last Response: %s*"
          (file-name-nondirectory (directory-file-name workspace))))

(defun faltoo-show-last-response--render (buf workspace message follow-up)
  (with-current-buffer buf
    (unless (derived-mode-p 'faltoo-ask-mode)
      (faltoo-ask-mode))
    (setq default-directory workspace
          faltoo-ask-context nil
          faltoo-ask-sent nil
          faltoo-last-response-message message)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (faltoo-compose-insert-title "Last Assistant Response")
      (faltoo-compose-insert-section "Assistant")
      (insert message)
      (when-let ((rate-limit (gethash workspace faltoo-last-rate-limits)))
        (insert "\n\n> " rate-limit "\n"))
      (faltoo-compose-insert-help "C-c C-c send follow-up · C-c C-k/C-g close · C-c C-f file · C-c / command · C-c p prompt")
      (faltoo-compose-insert-section "Follow-up")
      (setq faltoo-ask-question-marker (point-marker))
      (insert follow-up)
      (faltoo-ui-fontify-markdown)
      (goto-char faltoo-ask-question-marker))))

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
    (let* ((buf (get-buffer-create (faltoo-last-response-buffer-name workspace)))
           (follow-up (if (and (buffer-live-p buf)
                               (with-current-buffer buf faltoo-ask-question-marker))
                          (with-current-buffer buf
                            (string-trim-left
                             (buffer-substring-no-properties faltoo-ask-question-marker (point-max))))
                        "")))
      (with-current-buffer buf
        (when (or (not (derived-mode-p 'faltoo-ask-mode))
                  (not (equal faltoo-last-response-message message)))
          (faltoo-show-last-response--render buf workspace message follow-up))
        (goto-char faltoo-ask-question-marker))
      (faltoo-popup-show buf 100 28))))

(provide 'faltoo-ask)
;;; faltoo-ask.el ends here
