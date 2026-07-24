;;; faltoo-review.el --- Full-file Git review buffers for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'magit)
(require 'faltoo-faces)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-comments)
(require 'faltoo-ask)

(declare-function magit-git-insert "magit-git")

(defvar-local faltoo-review-source-file nil)
(defvar-local faltoo-review-hunk-positions nil)

(defun faltoo-review--patch (relative)
  "Return the complete working-tree patch for RELATIVE."
  (with-temp-buffer
    (magit-git-insert "diff" "--no-ext-diff" "--no-color"
                      "--unified=0" "--" relative)
    (buffer-string)))

(defvar faltoo-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'faltoo-ask)
    (define-key map (kbd "l") #'faltoo-show-last-response)
    (define-key map (kbd "c") #'faltoo-comment)
    (define-key map (kbd "C") #'faltoo-file-comment)
    (define-key map (kbd "s") #'faltoo-submit-review-comments)
    (define-key map (kbd "h") #'faltoo-chat)
    (define-key map (kbd "r") #'faltoo-vc-refresh)
    (define-key map (kbd "u") #'faltoo-review-unstaged)
    (define-key map (kbd "x") #'faltoo-review-stop)
    (define-key map (kbd "g") #'beginning-of-buffer)
    (define-key map (kbd "G") #'end-of-buffer)
    (define-key map (kbd "D") #'faltoo-magit-diff-current-file)
    (define-key map (kbd "d") #'faltoo-delete-current-comment)
    (define-key map (kbd "m") #'faltoo-comments-summary)
    (define-key map (kbd "]") #'faltoo-next-change)
    (define-key map (kbd "[") #'faltoo-prev-change)
    (define-key map (kbd "=") #'faltoo-show-change)
    (define-key map (kbd "n") #'faltoo-review-next-file)
    (define-key map (kbd "p") #'faltoo-review-prev-file)
    (define-key map (kbd "N") #'faltoo-next-comment)
    (define-key map (kbd "P") #'faltoo-prev-comment)
    (define-key map (kbd "S") #'faltoo-stage-current-file)
    (define-key map (kbd "U") #'faltoo-unstage-current-file)
    map))

(defun faltoo-review-header-line ()
  "Return visible review header text."
  (concat " Faltoo Review " (faltoo-review-lighter)
          "  ·  a ask  ·  c comment  ·  x stop"))

(define-minor-mode faltoo-review-mode
  "Minor mode for generated Faltoo review buffers."
  :lighter (:eval (faltoo-review-lighter))
  :keymap faltoo-review-mode-map
  (setq buffer-read-only faltoo-review-mode
        header-line-format (and faltoo-review-mode (faltoo-review-header-line))))

(defun faltoo-review-buffer-name (file)
  "Return the generated review buffer name for FILE."
  (format "*Faltoo Review: %s*"
          (file-relative-name file (locate-dominating-file file ".git"))))

(defun faltoo-review-file-index (file)
  "Return zero-based review index for FILE."
  (cl-position (file-truename file) faltoo-review-files :test #'string=))

(defun faltoo-review-lighter ()
  "Return mode-line lighter for `faltoo-review-mode'."
  (let ((index (and faltoo-review-source-file
                    (faltoo-review-file-index faltoo-review-source-file))))
    (if index
        (format " Faltoo[%d/%d]" (1+ index) (length faltoo-review-files))
      " Faltoo")))

(defun faltoo-review--hunks (patch)
  "Parse zero-context Git PATCH into review hunks."
  (let (hunks)
    (with-temp-buffer
      (insert patch)
      (goto-char (point-min))
      (while (re-search-forward
              "^@@ -[0-9]+\\(?:,[0-9]+\\)? +\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
              nil t)
        (let ((new-start (string-to-number (match-string 1)))
              (new-count (if (match-string 2) (string-to-number (match-string 2)) 1))
              lines)
          (forward-line 1)
          (while (and (not (eobp)) (not (looking-at "^@@ ")))
            (pcase (char-after)
              (?- (push (list 'delete (buffer-substring-no-properties
                                      (1+ (line-beginning-position)) (line-end-position)))
                        lines))
              (?+ (push (list 'insert (buffer-substring-no-properties
                                      (1+ (line-beginning-position)) (line-end-position)))
                        lines)))
            (forward-line 1))
          (push (list new-start new-count (nreverse lines)) hunks))))
    (nreverse hunks)))

(defun faltoo-review-refresh-buffer ()
  "Regenerate the current review buffer from its source file and Git diff."
  (let* ((file faltoo-review-source-file)
         (workspace (faltoo-workspace))
         (relative (file-relative-name file workspace))
         (hunks (let ((default-directory workspace))
                  (faltoo-review--hunks (faltoo-review--patch relative))))
         (inhibit-read-only t)
         markers)
    (remove-overlays (point-min) (point-max) 'faltoo-review-diff t)
    (erase-buffer)
    (when (file-exists-p file)
      (insert-file-contents file))
    (goto-char (point-min))
    (let ((line 1))
      (while (< (point) (point-max))
        (let ((start (point)))
          (forward-line 1)
          (add-text-properties
           start (point)
           (list 'faltoo-review-line-type 'context
                 'faltoo-review-file-line line
                 'rear-nonsticky t)))
        (setq line (1+ line)))
      (let ((total-lines (max 1 (1- line)))
            (hunk-index (1- (length hunks))))
        (dolist (hunk (reverse hunks))
          (goto-char (point-min))
          (forward-line (if (zerop (cadr hunk)) (car hunk) (max 0 (1- (car hunk)))))
          (unless (bolp) (insert "\n"))
          (push (copy-marker (point)) markers)
          (dolist (row (nth 2 hunk))
            (let ((type (car row))
                  (start (point)))
              (if (eq type 'delete)
                  (insert (cadr row) "\n")
                (forward-line 1))
              (add-text-properties
               start (point)
               (list 'faltoo-review-line-type type
                     'faltoo-review-file-line
                     (if (eq type 'delete)
                         (min total-lines (max 1 (car hunk)))
                       (get-text-property start 'faltoo-review-file-line))
                     'faltoo-review-hunk hunk-index
                     'rear-nonsticky t))
              (let ((overlay (make-overlay start (point))))
                (overlay-put overlay 'face
                             (if (eq type 'delete)
                                 'faltoo-diff-delete-line-face
                               'faltoo-diff-insert-line-face))
                (overlay-put overlay 'faltoo-review-diff t))))
          (setq hunk-index (1- hunk-index)))))
    (setq faltoo-review-hunk-positions (mapcar #'marker-position markers))
    (mapc (lambda (marker) (set-marker marker nil)) markers)
    (set-buffer-modified-p nil)
    (goto-char (point-min))))

(defun faltoo-review--attach-comments (file buffer)
  "Attach pending comments for FILE to generated review BUFFER."
  (dolist (comment (faltoo-comments--list (faltoo-comments--workspace)))
    (when (and (string= file (faltoo-comment-path comment))
               (not (eq buffer (faltoo-comment-source-buffer comment))))
      (faltoo-comments--delete-overlays (list comment))
      (setf (faltoo-comment-source-buffer comment) buffer)
      (with-current-buffer buffer
        (faltoo-comments--mark comment)))))

(defun faltoo-review-buffer (file)
  "Return the generated full-file review buffer for FILE."
  (let* ((file (file-truename file))
         (name (faltoo-review-buffer-name file))
         (buf (get-buffer name)))
    (unless (and buf (equal (buffer-local-value 'faltoo-review-source-file buf) file))
      (when buf (kill-buffer buf))
      (let* ((source (find-file-noselect file))
             (mode (buffer-local-value 'major-mode source)))
        (setq buf (get-buffer-create name))
        (with-current-buffer buf
          (funcall mode)
          (setq default-directory (file-name-directory file)
                faltoo-review-source-file file)
          (faltoo-review-refresh-buffer)
          (faltoo-review-mode 1))))
    (faltoo-review--attach-comments file buf)
    buf))


(defun faltoo-review-unstaged ()
  "Open unstaged files as generated full-file review buffers."
  (interactive)
  (let ((workspace (faltoo-reset-workspace)))
    (setq faltoo-review-files (mapcar #'file-truename (faltoo-bridge-unstaged-files workspace))
          faltoo-current-review-index 0))
  (unless faltoo-review-files
    (user-error "No unstaged files"))
  (switch-to-buffer (faltoo-review-buffer (car faltoo-review-files)))
  (message "Faltoo reviewing %d unstaged file(s)" (length faltoo-review-files)))

(defun faltoo-review--switch (delta)
  (unless faltoo-review-files
    (user-error "No Faltoo review files"))
  (setq faltoo-current-review-index
        (mod (+ (or (and faltoo-review-source-file
                         (faltoo-review-file-index faltoo-review-source-file))
                    faltoo-current-review-index)
                delta)
             (length faltoo-review-files)))
  (switch-to-buffer
   (faltoo-review-buffer (nth faltoo-current-review-index faltoo-review-files))))

(defun faltoo-review-next-file ()
  "Visit next Faltoo review file."
  (interactive)
  (faltoo-review--switch 1))

(defun faltoo-review-prev-file ()
  "Visit previous Faltoo review file."
  (interactive)
  (faltoo-review--switch -1))

(defun faltoo-review-stop ()
  "Stop review, close generated buffers, and preserve pending comments."
  (interactive)
  (let ((source (and faltoo-review-source-file (find-file-noselect faltoo-review-source-file)))
        (workspace (faltoo-comments--workspace)))
    (faltoo-comments--delete-overlays (faltoo-comments--list workspace))
    (dolist (comment (faltoo-comments--list workspace))
      (when (member (faltoo-comment-path comment) faltoo-review-files)
        (setf (faltoo-comment-source-buffer comment)
              (find-file-noselect (faltoo-comment-path comment)))))
    (dolist (file faltoo-review-files)
      (when-let ((buf (get-buffer (faltoo-review-buffer-name file))))
        (kill-buffer buf)))
    (setq faltoo-review-files nil
          faltoo-current-review-index 0)
    (when source
      (switch-to-buffer source))
    (faltoo-comments-refresh workspace)
    (message "Faltoo review stopped")))

(defun faltoo-vc-refresh ()
  "Regenerate active review buffers and refresh Magit."
  (interactive)
  (dolist (file faltoo-review-files)
    (when-let ((buf (get-buffer (faltoo-review-buffer-name file))))
      (with-current-buffer buf
        (faltoo-review-refresh-buffer))))
  (magit-refresh)
  (faltoo-comments-refresh)
  (force-mode-line-update t))

(defun faltoo-stage-current-file ()
  "Stage the reviewed source file through Magit."
  (interactive)
  (let ((file (faltoo-current-file)))
    (magit-stage-file file)
    (faltoo-vc-refresh)
    (message "Staged %s" (faltoo-relative-file file))))

(defun faltoo-unstage-current-file ()
  "Unstage the reviewed source file through Magit."
  (interactive)
  (let ((file (faltoo-current-file)))
    (magit-unstage-file file)
    (faltoo-vc-refresh)
    (message "Unstaged %s" (faltoo-relative-file file))))

(defun faltoo-review--move-change (direction)
  "Move to the next changed hunk in DIRECTION, wrapping at the buffer edge."
  (let ((origin (line-beginning-position)))
    (unless faltoo-review-hunk-positions (user-error "No Git changes"))
    (goto-char
     (if (> direction 0)
         (or (cl-find-if (lambda (pos) (> pos origin)) faltoo-review-hunk-positions)
             (car faltoo-review-hunk-positions))
       (or (car (last (cl-remove-if-not
                       (lambda (pos) (< pos origin)) faltoo-review-hunk-positions)))
           (car (last faltoo-review-hunk-positions)))))))

(defun faltoo-next-change ()
  "Jump to the next changed hunk."
  (interactive)
  (faltoo-review--move-change 1))

(defun faltoo-prev-change ()
  "Jump to the previous changed hunk."
  (interactive)
  (faltoo-review--move-change -1))

(defun faltoo-show-change ()
  "Recenter the current changed hunk."
  (interactive)
  (unless (get-text-property (point) 'faltoo-review-hunk)
    (faltoo-next-change))
  (recenter))

(defun faltoo-magit-status ()
  "Open Magit status for the Faltoo workspace."
  (interactive)
  (magit-status (faltoo-workspace)))

(defun faltoo-magit-diff-current-file ()
  "Open Magit diff for the reviewed source file."
  (interactive)
  (magit-diff-working-tree nil (list "--" (faltoo-current-file))))

(add-hook 'faltoo-after-reload-review-buffers-hook #'faltoo-vc-refresh)

(provide 'faltoo-review)
;;; faltoo-review.el ends here
