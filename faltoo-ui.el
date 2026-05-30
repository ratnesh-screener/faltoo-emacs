;;; faltoo-ui.el --- Posframe UI helpers for Faltoo -*- lexical-binding: t; -*-

(require 'posframe)
(require 'subr-x)

(defvar faltoo-popup-buffer "*Faltoo Popup*")
(defvar faltoo-last-response-buffer "*Faltoo Last Response*")

(defvar faltoo-popup-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'faltoo-popup-close)
    (define-key map (kbd "C-g") #'faltoo-popup-close)
    (define-key map (kbd "q") #'faltoo-popup-close)
    map))

(define-derived-mode faltoo-popup-mode text-mode "Faltoo-Popup"
  "Mode for Faltoo popup buffers."
  (setq-local cursor-type 'bar)
  (setq-local mode-line-format nil)
  (setq-local truncate-lines nil))

(defun faltoo-popup-close ()
  "Close the active Faltoo posframe."
  (interactive)
  (posframe-hide (current-buffer)))

(defun faltoo-popup-buffer (name mode)
  "Return popup buffer NAME in MODE."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (funcall mode))
    buf))

(defun faltoo-popup-show (buffer &optional width height)
  "Show BUFFER in a posframe near point."
  (let ((frame (posframe-show buffer
                              :position (point)
                              :width (or width 100)
                              :height (or height 24)
                              :border-width 1
                              :internal-border-width 1
                              :respect-header-line t)))
    (select-frame-set-input-focus frame)))

(defun faltoo-popup-set-lines (buffer lines)
  "Replace BUFFER contents with LINES."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (string-join lines "\n"))
      (goto-char (point-max)))))

(defun faltoo-popup-append (buffer text)
  "Append TEXT to BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert text)
      (goto-char (point-max)))))

(provide 'faltoo-ui)
;;; faltoo-ui.el ends here
