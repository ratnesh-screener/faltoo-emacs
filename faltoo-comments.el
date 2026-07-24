;;; faltoo-comments.el --- Review comments for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'faltoo-core)
(require 'faltoo-ui)
(require 'faltoo-chat)
(require 'faltoo-request)
(require 'faltoo-compose)
(require 'faltoo-faces)

(cl-defstruct faltoo-comment
  file path start end code text overlay source-buffer display-start display-end display-type)

(defvar faltoo-comments (make-hash-table :test #'equal))
(when (listp faltoo-comments)
  (let ((comments faltoo-comments))
    (setq faltoo-comments (make-hash-table :test #'equal))
    (when comments
      (puthash (faltoo-workspace) comments faltoo-comments))))
(defvar faltoo-comments-buffer-name "*Faltoo Comments*")

(defvar-local faltoo-comment-target nil)
(defvar-local faltoo-comment-workspace nil)
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

(defun faltoo-comments--workspace (&optional workspace)
  "Return normalized comment WORKSPACE."
  (file-name-as-directory
   (file-truename (or workspace
                     (and (boundp 'faltoo-chat-workspace) faltoo-chat-workspace)
                     (faltoo-workspace)))))

(defun faltoo-comments--list (&optional workspace)
  "Return pending comments for WORKSPACE."
  (gethash (faltoo-comments--workspace workspace) faltoo-comments))

(defun faltoo-comments--set (comments &optional workspace)
  "Set pending COMMENTS for WORKSPACE."
  (let ((workspace (faltoo-comments--workspace workspace)))
    (if comments
        (puthash workspace comments faltoo-comments)
      (remhash workspace faltoo-comments))))

(defun faltoo-comments--all ()
  "Return all pending comments across workspaces."
  (cl-loop for comments being the hash-values of faltoo-comments append comments))

(defun faltoo-comments-total-count ()
  "Return pending comment count across all workspaces."
  (cl-loop for comments being the hash-values of faltoo-comments sum (length comments)))

(defun faltoo-comments-count (&optional workspace)
  (length (faltoo-comments--list workspace)))

(defun faltoo-comments--range ()
  (faltoo-current-line-range))

(defun faltoo-comments--existing (path start end &optional workspace display-start display-end display-type)
  (cl-find-if
   (lambda (comment)
     (and (string= path (faltoo-comment-path comment))
          (if (eq display-type 'delete)
              (and (eq (faltoo-comment-display-type comment) 'delete)
                   (<= display-start (faltoo-comment-display-end comment))
                   (<= (faltoo-comment-display-start comment) display-end))
            (and (not (eq (faltoo-comment-display-type comment) 'delete))
                 (<= start (faltoo-comment-end comment))
                 (<= (faltoo-comment-start comment) end)))))
   (faltoo-comments--list workspace)))

(defun faltoo-comments--source-buffer (comment)
  (or (and (buffer-live-p (faltoo-comment-source-buffer comment))
           (faltoo-comment-source-buffer comment))
      (get-buffer (faltoo-comment-path comment))
      (find-buffer-visiting (faltoo-comment-path comment))))

(defun faltoo-comments--review-line-position (line &optional display-line)
  "Return the generated review position for source LINE."
  (or (and display-line
           (save-excursion
             (goto-char (point-min))
             (forward-line (1- display-line))
             (and (= (or (get-text-property (point) 'faltoo-review-file-line) -1) line)
                  (point))))
      (save-excursion
        (goto-char (point-min))
        (let (fallback found)
          (while (and (< (point) (point-max)) (not found))
            (when (= (or (get-text-property (point) 'faltoo-review-file-line) -1) line)
              (setq fallback (or fallback (point)))
              (unless (eq (get-text-property (point) 'faltoo-review-line-type) 'delete)
                (setq found (point))))
            (forward-line 1))
          (or found fallback)))))

(defun faltoo-comments--position (comment end)
  "Return COMMENT's start or END position in the current source/review buffer."
  (let ((line (if end (faltoo-comment-end comment) (faltoo-comment-start comment)))
        (display-line (if end
                          (faltoo-comment-display-end comment)
                        (faltoo-comment-display-start comment))))
    (if (bound-and-true-p faltoo-review-source-file)
        (faltoo-comments--review-line-position line display-line)
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (point)))))

(defun faltoo-comments--mark (comment)
  (when (> (faltoo-comment-start comment) 0)
    (when-let ((buf (faltoo-comments--source-buffer comment)))
      (with-current-buffer buf
        (save-excursion
          (let ((beg (faltoo-comments--position comment nil)))
            (goto-char (faltoo-comments--position comment t))
            (forward-line 1)
            (let ((overlay (make-overlay beg (point))))
              (overlay-put overlay 'face 'faltoo-review-comment-face)
              (setf (faltoo-comment-overlay comment) overlay))))))))


(defun faltoo-comments--delete-overlays (comments)
  "Delete source overlays for COMMENTS."
  (dolist (comment comments)
    (when (overlayp (faltoo-comment-overlay comment))
      (delete-overlay (faltoo-comment-overlay comment)))
    (setf (faltoo-comment-overlay comment) nil)))

(defun faltoo-comments-refresh (&optional workspace)
  "Refresh pending comment overlays for WORKSPACE, or all workspaces."
  (let ((comments (if workspace
                      (faltoo-comments--list workspace)
                    (faltoo-comments--all))))
    (faltoo-comments--delete-overlays comments)
    (dolist (comment comments)
      (faltoo-comments--mark comment)))
  (force-mode-line-update t))

(defun faltoo-comment (&optional file-level)
  "Add or edit a pending Faltoo review comment."
  (interactive)
  (let* ((chat (derived-mode-p 'faltoo-chat-mode))
         (workspace (faltoo-comments--workspace))
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
         (display-start (and (bound-and-true-p faltoo-review-source-file)
                             (line-number-at-pos (nth 0 range))))
         (display-end (and (bound-and-true-p faltoo-review-source-file)
                           (line-number-at-pos (nth 1 range))))
         (display-type (and display-start
                            (get-text-property (nth 0 range) 'faltoo-review-line-type)))
         (existing (faltoo-comments--existing path start end nil
                                              display-start display-end display-type))
         (target (or existing (make-faltoo-comment :file file :path path :start start :end end :code code)))
         (buf (faltoo-popup-buffer "*Faltoo Comment*" #'faltoo-comment-mode)))
    (setf (faltoo-comment-source-buffer target) source-buffer
          (faltoo-comment-display-start target) display-start
          (faltoo-comment-display-end target) display-end
          (faltoo-comment-display-type target) display-type)
    (with-current-buffer buf
      (setq default-directory workspace
            faltoo-comment-target target
            faltoo-comment-workspace workspace)
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
  (let* ((comment faltoo-comment-target)
         (text (string-trim (buffer-substring-no-properties faltoo-comment-text-marker (point-max))))
         (workspace faltoo-comment-workspace)
         (comments (faltoo-comments--list workspace)))
    (if (string-empty-p text)
        (progn
          (faltoo-comments--delete-overlays (list comment))
          (faltoo-comments--set (delq comment comments) workspace))
      (setf (faltoo-comment-text comment) text)
      (unless (memq comment comments)
        (push comment comments))
      (faltoo-comments--set comments workspace))
    (faltoo-comments-refresh workspace)
    (faltoo-popup-deactivate-return-mark)
    (faltoo-popup-close)
    (message "Faltoo: %d pending comment(s)" (faltoo-comments-count workspace))))

(defun faltoo-comments--payload (comments)
  (mapcar (lambda (comment)
            (list (cons 'filename (faltoo-comment-file comment))
                  (cons 'line_number_start (or (faltoo-comment-display-start comment)
                                               (faltoo-comment-start comment)))
                  (cons 'line_number_end (or (faltoo-comment-display-end comment)
                                             (faltoo-comment-end comment)))
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
  (let ((workspace (faltoo-comments--workspace))
        (buf (get-buffer-create faltoo-comments-buffer-name)))
    (with-current-buffer buf
      (faltoo-comments-summary-mode)
      (setq default-directory workspace)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Pending Faltoo comments\n\n")
        (if-let ((comments (faltoo-comments--list workspace)))
            (dolist (comment (reverse comments))
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
      (let ((line (or (get-text-property (line-beginning-position) 'faltoo-review-file-line)
                      (line-number-at-pos))))
        (cond
         ((bound-and-true-p faltoo-review-source-file)
          (let ((display-line (line-number-at-pos))
                (type (get-text-property (line-beginning-position) 'faltoo-review-line-type)))
            (faltoo-comments--existing (faltoo-current-file) line line nil
                                       display-line display-line type)))
         (buffer-file-name
          (faltoo-comments--existing (faltoo-current-file) line line))
         ((derived-mode-p 'faltoo-chat-mode)
          (faltoo-comments--existing (buffer-name) line line))))))

(defun faltoo-comments--goto-source (comment)
  (let ((buf (faltoo-comments--source-buffer comment)))
    (if buf
        (switch-to-buffer buf)
      (find-file (faltoo-comment-path comment))))
  (when (> (faltoo-comment-start comment) 0)
    (goto-char (faltoo-comments--position comment nil))))

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
    (faltoo-comments--set (delq comment (faltoo-comments--list)))
    (faltoo-comments-refresh (faltoo-comments--workspace))
    (message "Faltoo: %d pending comment(s)" (faltoo-comments-count))))

(defun faltoo-comments-summary-delete ()
  "Delete the pending comment at point and refresh the summary."
  (interactive)
  (faltoo-delete-current-comment)
  (faltoo-comments-summary-render))

(defun faltoo-submit-review-comments ()
  "Submit pending review comments to FaltooBot."
  (interactive)
  (unless (faltoo-comments--list)
    (user-error "No pending Faltoo comments"))
  (let* ((workspace (faltoo-comments--workspace))
         (submitted (reverse (faltoo-comments--list workspace))))
    (faltoo-request-review
     (faltoo-comments--payload submitted)
     (lambda ()
       (faltoo-comments--delete-overlays submitted)
       (faltoo-comments--set (cl-set-difference (faltoo-comments--list workspace) submitted) workspace)
       (faltoo-comments-refresh workspace))
     nil workspace)))

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
         (comments (sort (cl-remove-if-not
                          (lambda (comment)
                            (and (string= path (faltoo-comment-path comment))
                                 (> (faltoo-comment-start comment) 0)))
                          (copy-sequence (faltoo-comments--list)))
                         (lambda (a b) (< (faltoo-comment-start a) (faltoo-comment-start b)))))
         (line (or (get-text-property (line-beginning-position) 'faltoo-review-file-line)
                   (line-number-at-pos)))
         (target (if (> direction 0) (car comments) (car (last comments)))))
    (unless comments (user-error "No Faltoo comments in this buffer"))
    (dolist (comment comments)
      (let ((candidate (faltoo-comment-start comment)))
        (when (and (> direction 0) (> candidate line)
                   (< candidate (faltoo-comment-start target)))
          (setq target comment))
        (when (and (< direction 0) (< candidate line))
          (setq target comment))))
    (goto-char (faltoo-comments--position target nil))))

(add-hook 'faltoo-after-reload-review-buffers-hook #'faltoo-comments-refresh)

(provide 'faltoo-comments)
;;; faltoo-comments.el ends here
