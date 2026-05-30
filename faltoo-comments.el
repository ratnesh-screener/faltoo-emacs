;;; faltoo-comments.el --- Review comments for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)
(require 'faltoo-chat)
(require 'faltoo-ask)

(cl-defstruct faltoo-comment file path start end code text overlay)

(defvar faltoo-comments nil)
(defface faltoo-review-comment-face
  '((t :inherit highlight))
  "Face for pending Faltoo review comments.")

(defvar-local faltoo-comment-target nil)
(defvar-local faltoo-comment-text-marker nil)

(defvar faltoo-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map faltoo-popup-mode-map)
    (define-key map (kbd "C-c C-c") #'faltoo-comment-save)
    (define-key map (kbd "C-c C-f") #'faltoo-insert-file-reference)
    map))

(define-derived-mode faltoo-comment-mode faltoo-popup-mode "Faltoo-Comment"
  "Mode for composing Faltoo review comments.")

(defun faltoo-comments-count ()
  (length faltoo-comments))

(defun faltoo-comments--range ()
  (if (use-region-p)
      (let ((beg (region-beginning)) (end (region-end)))
        (list beg end (line-number-at-pos beg) (line-number-at-pos end)
              (buffer-substring-no-properties beg end)))
    (let ((beg (line-beginning-position)) (end (line-end-position)))
      (list beg end (line-number-at-pos) (line-number-at-pos)
            (buffer-substring-no-properties beg end)))))

(defun faltoo-comments--existing (path start end)
  (cl-find-if (lambda (comment)
                (and (string= path (faltoo-comment-path comment))
                     (<= start (faltoo-comment-end comment))
                     (<= (faltoo-comment-start comment) end)))
              faltoo-comments))

(defun faltoo-comments--mark (comment)
  (let ((buf (find-buffer-visiting (faltoo-comment-path comment))))
    (when buf
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- (faltoo-comment-start comment)))
          (let ((beg (line-beginning-position)))
            (forward-line (1+ (- (faltoo-comment-end comment) (faltoo-comment-start comment))))
            (let ((overlay (make-overlay beg (line-beginning-position))))
              (overlay-put overlay 'face 'faltoo-review-comment-face)
              (overlay-put overlay 'before-string (propertize "●" 'face 'warning))
              (setf (faltoo-comment-overlay comment) overlay))))))))

(defun faltoo-comments-refresh ()
  "Refresh all pending comment overlays."
  (dolist (comment faltoo-comments)
    (when (overlayp (faltoo-comment-overlay comment))
      (delete-overlay (faltoo-comment-overlay comment)))
    (setf (faltoo-comment-overlay comment) nil)
    (faltoo-comments--mark comment))
  (force-mode-line-update t))

(defun faltoo-comment (&optional file-level)
  "Add or edit a pending Faltoo review comment."
  (interactive)
  (let* ((path (faltoo-current-file))
         (file (faltoo-relative-file path))
         (range (if file-level
                    (list (point-min) (point-min) 0 0 "")
                  (faltoo-comments--range)))
         (start (nth 2 range))
         (end (nth 3 range))
         (code (nth 4 range))
         (existing (faltoo-comments--existing path start end))
         (target (or existing (make-faltoo-comment :file file :path path :start start :end end :code code)))
         (buf (faltoo-popup-buffer "*Faltoo Comment*" #'faltoo-comment-mode)))
    (with-current-buffer buf
      (setq faltoo-comment-target target)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "File: %s\n" file))
        (unless file-level
          (insert (if (= start end) (format "Line: %d\n" start) (format "Lines: %d-%d\n" start end)))
          (insert "\nCode:\n```\n" code "\n```\n"))
        (insert "\nComment:\n\n")
        (setq faltoo-comment-text-marker (point-marker))
        (when existing (insert (faltoo-comment-text existing)))))
    (faltoo-popup-show buf 90 24)))

(defun faltoo-file-comment ()
  "Add or edit a file-level Faltoo review comment."
  (interactive)
  (faltoo-comment t))

(defun faltoo-comment-save ()
  "Save the current comment popup."
  (interactive)
  (let ((comment faltoo-comment-target)
        (text (string-trim (buffer-substring-no-properties faltoo-comment-text-marker (point-max)))))
    (if (string-empty-p text)
        (setq faltoo-comments (delq comment faltoo-comments))
      (setf (faltoo-comment-text comment) text)
      (unless (memq comment faltoo-comments)
        (push comment faltoo-comments)))
    (faltoo-comments-refresh)
    (faltoo-popup-close)
    (message "Faltoo: %d pending comment(s)" (length faltoo-comments))))

(defun faltoo-comments--payload (comments)
  (mapcar (lambda (comment)
            `((filename . ,(faltoo-comment-file comment))
              (line_number_start . ,(faltoo-comment-start comment))
              (line_number_end . ,(faltoo-comment-end comment))
              (file_line_number_start . ,(faltoo-comment-start comment))
              (file_line_number_end . ,(faltoo-comment-end comment))
              (code . ,(faltoo-comment-code comment))
              (comment . ,(faltoo-comment-text comment))))
          comments))

(defun faltoo-submit-review-comments ()
  "Submit pending review comments to FaltooBot."
  (interactive)
  (unless faltoo-comments
    (user-error "No pending Faltoo comments"))
  (let ((submitted faltoo-comments))
    (setq faltoo-submitting t
          faltoo-last-assistant-message "")
    (faltoo-set-status "Submitting review comments...")
    (faltoo-chat-start-stream "Assistant · streaming")
    (faltoo-bridge-stream
     (list "append-review")
     `((workspace . ,(faltoo-workspace)) (comments . ,(faltoo-comments--payload submitted)))
     (lambda (event)
       (let ((class (or (alist-get 'classes event) (alist-get 'type event)))
             (text (or (alist-get 'text event) "")))
         (cond
          ((string= class "answer")
           (setq faltoo-last-assistant-message (concat faltoo-last-assistant-message text))
           (faltoo-chat-append-stream text))
          ((string= class "status")
           (when (string-prefix-p "Submitted" text)
             (setq faltoo-comments (cl-set-difference faltoo-comments submitted))
             (faltoo-comments-refresh))
           (faltoo-set-status text)
           (faltoo-chat-append-stream (format "- %s\n" text)))
          ((string= class "done")
           (faltoo-set-status text)))))
     (lambda (ok)
       (setq faltoo-submitting nil)
       (faltoo-set-status (if ok "Review complete" "Review failed"))
       (faltoo-chat-finish-stream)
       (when ok (ding))))))

(defun faltoo-next-comment ()
  "Jump to next pending comment in current buffer."
  (interactive)
  (faltoo-comments--jump 1))

(defun faltoo-prev-comment ()
  "Jump to previous pending comment in current buffer."
  (interactive)
  (faltoo-comments--jump -1))

(defun faltoo-comments--jump (direction)
  (let* ((path (faltoo-current-file))
         (lines (sort (mapcar #'faltoo-comment-start
                              (cl-remove-if-not (lambda (comment)
                                                  (and (string= path (faltoo-comment-path comment))
                                                       (> (faltoo-comment-start comment) 0)))
                                                faltoo-comments))
                      #'<))
         (line (line-number-at-pos))
         (target (if (> direction 0) (car lines) (car (last lines)))))
    (unless lines (user-error "No Faltoo comments in this buffer"))
    (dolist (candidate lines)
      (when (and (> direction 0) (> candidate line) (or (not target) (< candidate target)))
        (setq target candidate))
      (when (and (< direction 0) (< candidate line))
        (setq target candidate)))
    (goto-char (point-min))
    (forward-line (1- target))))

(provide 'faltoo-comments)
;;; faltoo-comments.el ends here
