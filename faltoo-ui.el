;;; faltoo-ui.el --- Posframe UI helpers for Faltoo -*- lexical-binding: t; -*-

(require 'posframe)
(require 'markdown-mode)

(declare-function posframe-poshandler-frame-center "posframe")

(defvar faltoo-popup-buffer "*Faltoo Popup*")

(defvar-local faltoo-popup-return-window nil)
(defvar-local faltoo-popup-stream-answer-started nil)
(defvar-local faltoo-popup-stream-needs-answer-separator nil)

(defun faltoo-ui-enable-pretty-markdown ()
  "Use Markdown mode as a lightweight rendered view while keeping text editable."
  (setq-local markdown-hide-markup t)
  (setq-local markdown-fontify-code-blocks-natively t)
  (setq-local markdown-fontify-whole-heading-line t)
  (setq-local markdown-header-scaling t)
  (dolist (face-spec '((markdown-header-delimiter-face :inherit shadow)
                       (markdown-header-face-1 :inherit outline-1 :weight bold)
                       (markdown-header-face-2 :inherit outline-2 :weight bold)
                       (markdown-header-face-3 :inherit outline-3 :weight bold)
                       (markdown-blockquote-face :inherit font-lock-doc-face :slant italic)))
    (apply #'face-remap-add-relative face-spec)))

(defvar faltoo-popup-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'faltoo-popup-close)
    (define-key map (kbd "C-g") #'faltoo-popup-close)
    map))

(define-derived-mode faltoo-popup-mode markdown-mode "Faltoo-Popup"
  "Mode for Faltoo popup buffers."
  (faltoo-ui-enable-pretty-markdown)
  (setq-local mode-line-format nil)
  (setq-local truncate-lines nil))

(defun faltoo-popup-close ()
  "Close the active Faltoo posframe and return focus to the source window."
  (interactive)
  (let ((return-window faltoo-popup-return-window))
    (posframe-hide (current-buffer))
    (when (window-live-p return-window)
      (select-frame-set-input-focus (window-frame return-window))
      (select-window return-window))))

(defun faltoo-popup-buffer (name mode)
  "Return popup buffer NAME in MODE."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (funcall mode))
    buf))

(defun faltoo-popup-show (buffer &optional width height)
  "Show BUFFER in a centered, focusable, bordered posframe."
  (let ((return-window (selected-window)))
    (with-current-buffer buffer
      (setq faltoo-popup-return-window return-window))
    (let* ((background (face-attribute 'default :background nil t))
           (frame (posframe-show buffer
                                 :poshandler #'posframe-poshandler-frame-center
                                 :width (or width 100)
                                 :height (or height 24)
                                 :cursor 'box
                                 :tty-non-selected-cursor t
                                 :window-point (with-current-buffer buffer (point))
                                 :border-width 2
                                 :border-color "#888888"
                                 :internal-border-width 16
                                 :internal-border-color background
                                 :background-color background
                                 :left-fringe 16
                                 :right-fringe 16
                                 :override-parameters '((left-fringe . 16)
                                                        (right-fringe . 16))
                                 :respect-header-line t
                                 :accept-focus t)))
      (select-frame-set-input-focus frame)
      (with-selected-frame frame
        (select-window (frame-selected-window frame))
        (switch-to-buffer buffer)))))

(defun faltoo-popup-append (buffer text &optional preserve-reader-position)
  "Append TEXT to BUFFER.
When PRESERVE-READER-POSITION is non-nil, keep existing window scroll and point."
  (let ((window-state (mapcar (lambda (window)
                              (list window (window-point window) (window-start window)))
                            (get-buffer-window-list buffer nil t)))
        (buffer-point nil))
    (with-current-buffer buffer
      (setq buffer-point (point))
      (let ((inhibit-read-only t)
            (start (point-max)))
        (goto-char (point-max))
        (insert text)
        (add-text-properties start (point) '(rear-nonsticky t))
        (if preserve-reader-position
            (goto-char buffer-point)
          (goto-char (point-max)))))
    (when preserve-reader-position
      (dolist (state window-state)
        (pcase-let ((`(,window ,point ,start) state))
          (when (window-live-p window)
            (set-window-point window point)
            (set-window-start window start)))))))

(defun faltoo-popup-start-stream (buffer)
  "Reset popup stream state in BUFFER."
  (with-current-buffer buffer
    (setq faltoo-popup-stream-answer-started nil
          faltoo-popup-stream-needs-answer-separator nil)))

(defun faltoo-popup-append-stream (buffer text)
  "Append assistant answer TEXT to popup BUFFER."
  (let (prefix)
    (with-current-buffer buffer
      (setq prefix (if (and faltoo-popup-stream-needs-answer-separator
                            (not faltoo-popup-stream-answer-started))
                       "\n"
                     ""))
      (setq faltoo-popup-stream-answer-started t
            faltoo-popup-stream-needs-answer-separator nil))
    (faltoo-popup-append buffer (concat prefix text) t)))

(defun faltoo-popup-append-stream-block (buffer text &optional face)
  "Append compact quoted stream block TEXT to popup BUFFER."
  (let ((quoted (concat "> " (mapconcat #'identity (split-string text "\n") "\n> ") "\n")))
    (with-current-buffer buffer
      (setq faltoo-popup-stream-needs-answer-separator t))
    (faltoo-popup-append buffer (if face (propertize quoted 'face face) quoted) t)))

(provide 'faltoo-ui)
;;; faltoo-ui.el ends here
