;;; faltoo-comments.el --- Review comments for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-ui)
(require 'faltoo-chat)
(require 'faltoo-request)
(require 'faltoo-compose)
(require 'faltoo-faces)

(cl-defstruct faltoo-comment file path start end code text overlay source-buffer)

(defvar faltoo-comments nil)
(defvar faltoo-comments-buffer-name "*Faltoo Comments*")

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

(defvar faltoo-comments-summary-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'faltoo-comments-summary-jump)
    (define-key map (kbd "e") #'faltoo-comments-summary-edit)
    (define-key map (kbd "d") #'faltoo-comments-summary-delete)
    (define-key map (kbd "g") #'faltoo-comments-summary-refresh)
    map))

(define-derived-mode faltoo-comments-summary-mode special-mode "Faltoo-Comments"
  "Mode for pending Faltoo review comments.")

(defun faltoo-comments-count ()
  (length faltoo-comments))

(defun faltoo-comments--range ()
  (faltoo-current-line-range))

(defun faltoo-comments--existing (path start end)
  (cl-find-if (lambda (comment)
                (and (string= path (faltoo-comment-path comment))
                     (<= start (faltoo-comment-end comment))
                     (<= (faltoo-comment-start comment) end)))
              faltoo-comments))

(defun faltoo-comments--source-buffer (comment)
  (or (and (buffer-live-p (faltoo-comment-source-buffer comment))
           (faltoo-comment-source-buffer comment))
      (get-buffer (faltoo-comment-path comment))
      (find-buffer-visiting (faltoo-comment-path comment))))

(defun faltoo-comments--mark (comment)
  (when (> (faltoo-comment-start comment) 0)
    (let ((buf (faltoo-comments--source-buffer comment)))
      (when buf
        (with-current-buffer buf
          (save-excursion
            (goto-char (point-min))
            (forward-line (1- (faltoo-comment-start comment)))
            (let ((beg (line-beginning-position)))
              (forward-line (1+ (- (faltoo-comment-end comment) (faltoo-comment-start comment))))
              (let ((overlay (make-overlay beg (line-beginning-position))))
                (overlay-put overlay 'face 'faltoo-review-comment-face)
                (setf (faltoo-comment-overlay comment) overlay)))))))))


(defun faltoo-comments--delete-overlays (comments)
  "Delete source overlays for COMMENTS."
  (dolist (comment comments)
    (when (overlayp (faltoo-comment-overlay comment))
      (delete-overlay (faltoo-comment-overlay comment)))
    (setf (faltoo-comment-overlay comment) nil)))

(defun faltoo-comments-refresh ()
  "Refresh all pending comment overlays."
  (faltoo-comments--delete-overlays faltoo-comments)
  (dolist (comment faltoo-comments)
    (faltoo-comments--mark comment))
  (force-mode-line-update t))

(defun faltoo-comment (&optional file-level)
  "Add or edit a pending Faltoo review comment."
  (interactive)
  (let* ((chat (derived-mode-p 'faltoo-chat-mode))
         (workspace (faltoo-workspace))
         (source-buffer (current-buffer))
         (path (if chat (buffer-name) (faltoo-current-file)))
         (file (if chat "Faltoo transcript" (faltoo-relative-file path)))
         (range (if file-level
                    (list (point-min) (point-min) 0 0 "")
                  (faltoo-comments--range)))
         (start (nth 2 range))
         (end (nth 3 range))
         (code (nth 4 range))
         (language (if chat "markdown" (faltoo-current-language)))
         (existing (faltoo-comments--existing path start end))
         (target (or existing (make-faltoo-comment :file file :path path :start start :end end :code code :source-buffer source-buffer)))
         (buf (faltoo-popup-buffer "*Faltoo Comment*" #'faltoo-comment-mode)))
    (with-current-buffer buf
      (setq default-directory workspace
            faltoo-comment-target target)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (faltoo-compose-insert-title (cond (chat "Faltoo Transcript Comment")
                                           (file-level "Faltoo File Comment")
                                           (t "Faltoo Review Comment")))
        (faltoo-compose-insert-meta (if chat "Transcript" "File") file)
        (unless file-level
          (faltoo-compose-insert-meta "Range" (if (= start end) (format "line %d" start) (format "lines %d-%d" start end)))
          (faltoo-compose-insert-section "Code")
          (faltoo-compose-insert-code code language))
        (faltoo-compose-insert-help "C-c C-c save · C-c C-k/C-g close · C-c C-f file")
        (faltoo-compose-insert-section "Comment")
        (setq faltoo-comment-text-marker (point-marker))
        (when existing (insert (faltoo-comment-text existing)))
        (goto-char faltoo-comment-text-marker)))
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
            (list (cons 'filename (faltoo-comment-file comment))
                  (cons 'line_number_start (faltoo-comment-start comment))
                  (cons 'line_number_end (faltoo-comment-end comment))
                  (cons 'file_line_number_start (faltoo-comment-start comment))
                  (cons 'file_line_number_end (faltoo-comment-end comment))
                  (cons 'code (faltoo-comment-code comment))
                  (cons 'comment (faltoo-comment-text comment))))
          comments))

(defun faltoo-comments--display-range (comment)
  (let ((start (faltoo-comment-start comment))
        (end (faltoo-comment-end comment)))
    (cond
     ((= start 0) "file")
     ((= start end) (format "line %d" start))
     (t (format "lines %d-%d" start end)))))

(defun faltoo-comments-summary-render ()
  "Render pending review comments into `faltoo-comments-buffer-name'."
  (let ((buf (get-buffer-create faltoo-comments-buffer-name)))
    (with-current-buffer buf
      (faltoo-comments-summary-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Pending Faltoo comments\n\n")
        (if faltoo-comments
            (dolist (comment (reverse faltoo-comments))
              (let ((start (point)))
                (insert (format "%s:%s\n"
                                (faltoo-comment-file comment)
                                (faltoo-comments--display-range comment)))
                (insert (string-trim (faltoo-comment-text comment)) "\n")
                (insert "RET jump · e edit · d delete\n\n")
                (add-text-properties start (point) (list 'faltoo-comment comment))))
          (insert "No pending comments.\n"))
        (goto-char (point-min))))
    buf))

(defun faltoo-comments-summary ()
  "Show pending Faltoo review comments."
  (interactive)
  (pop-to-buffer (faltoo-comments-summary-render)))

(defun faltoo-comments-summary-refresh ()
  "Refresh pending Faltoo review comments summary."
  (interactive)
  (faltoo-comments-summary-render))

(defun faltoo-comments--comment-at-point ()
  (or (get-text-property (point) 'faltoo-comment)
      (get-text-property (line-beginning-position) 'faltoo-comment)
      (let ((line (line-number-at-pos)))
        (cond
         (buffer-file-name
          (faltoo-comments--existing (faltoo-current-file) line line))
         ((derived-mode-p 'faltoo-chat-mode)
          (faltoo-comments--existing (buffer-name) line line))))))

(defun faltoo-comments--goto-source (comment)
  (let ((buf (faltoo-comments--source-buffer comment)))
    (if buf
        (switch-to-buffer buf)
      (find-file (faltoo-comment-path comment))))
  (goto-char (point-min))
  (when (> (faltoo-comment-start comment) 0)
    (forward-line (1- (faltoo-comment-start comment)))))

(defun faltoo-comments-summary-jump ()
  "Jump from the summary to the comment source."
  (interactive)
  (let ((comment (faltoo-comments--comment-at-point)))
    (unless comment (user-error "No Faltoo comment at point"))
    (faltoo-comments--goto-source comment)))

(defun faltoo-comments-summary-edit ()
  "Edit the pending comment at point."
  (interactive)
  (let ((comment (faltoo-comments--comment-at-point)))
    (unless comment (user-error "No Faltoo comment at point"))
    (faltoo-comments--goto-source comment)
    (if (= (faltoo-comment-start comment) 0)
        (faltoo-file-comment)
      (faltoo-comment))))

(defun faltoo-delete-current-comment ()
  "Delete the pending Faltoo comment at point."
  (interactive)
  (let ((comment (faltoo-comments--comment-at-point)))
    (unless comment (user-error "No Faltoo comment at point"))
    (when (overlayp (faltoo-comment-overlay comment))
      (delete-overlay (faltoo-comment-overlay comment)))
    (setq faltoo-comments (delq comment faltoo-comments))
    (faltoo-comments-refresh)
    (message "Faltoo: %d pending comment(s)" (length faltoo-comments))))

(defun faltoo-comments-summary-delete ()
  "Delete the pending comment at point and refresh the summary."
  (interactive)
  (faltoo-delete-current-comment)
  (faltoo-comments-summary-render))

(defun faltoo-submit-review-comments ()
  "Submit pending review comments to FaltooBot."
  (interactive)
  (unless faltoo-comments
    (user-error "No pending Faltoo comments"))
  (let ((submitted faltoo-comments))
    (faltoo-request-review
     (faltoo-comments--payload submitted)
     (lambda ()
       (faltoo-comments--delete-overlays submitted)
       (setq faltoo-comments (cl-set-difference faltoo-comments submitted))
       (faltoo-comments-refresh)))))

(defun faltoo-next-comment ()
  "Jump to next pending comment in current buffer."
  (interactive)
  (faltoo-comments--jump 1))

(defun faltoo-prev-comment ()
  "Jump to previous pending comment in current buffer."
  (interactive)
  (faltoo-comments--jump -1))

(defun faltoo-comments--jump (direction)
  (let* ((path (if (derived-mode-p 'faltoo-chat-mode) (buffer-name) (faltoo-current-file)))
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

(add-hook 'faltoo-after-reload-review-buffers-hook #'faltoo-comments-refresh)

(provide 'faltoo-comments)
;;; faltoo-comments.el ends here
