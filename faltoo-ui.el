;;; faltoo-ui.el --- Posframe UI helpers for Faltoo -*- lexical-binding: t; -*-

(require 'posframe)
(require 'subr-x)
(require 'markdown-mode)

(declare-function posframe-poshandler-frame-center "posframe")

(defvar faltoo-popup-buffer "*Faltoo Popup*")
(defvar faltoo-last-response-buffer "*Faltoo Last Response*")

(defvar-local faltoo-popup-return-window nil)

(defun faltoo-ui-enable-pretty-markdown ()
  "Use Markdown mode as a lightweight rendered view while keeping text editable."
  (setq-local markdown-hide-markup t)
  (setq-local markdown-fontify-code-blocks-natively t)
  (setq-local markdown-fontify-whole-heading-line t)
  (setq-local markdown-header-scaling t))

(defun faltoo-ui-fontify-markdown (&optional start end)
  "Refresh Markdown fontification between START and END."
  (when (derived-mode-p 'markdown-mode)
    (let ((beg (or start (point-min)))
          (fin (or end (point-max))))
      (font-lock-flush beg fin)
      (font-lock-ensure beg fin))))

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
    (with-current-buffer buffer
      (faltoo-ui-fontify-markdown))
    (let ((frame (posframe-show buffer
                                :poshandler #'posframe-poshandler-frame-center
                                :width (or width 100)
                                :height (or height 24)
                                :cursor 'box
                                :tty-non-selected-cursor t
                                :window-point (with-current-buffer buffer (point))
                                :border-width 2
                                :border-color "#888888"
                                :internal-border-width 8
                                :internal-border-color "#222222"
                                :respect-header-line t
                                :accept-focus t)))
      (select-frame-set-input-focus frame)
      (with-selected-frame frame
        (select-window (frame-selected-window frame))
        (switch-to-buffer buffer)))))

(defun faltoo-popup-append (buffer text)
  "Append TEXT to BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (start (point-max)))
      (goto-char (point-max))
      (insert text)
      (faltoo-ui-fontify-markdown start (point))
      (goto-char (point-max)))))

(provide 'faltoo-ui)
;;; faltoo-ui.el ends here
