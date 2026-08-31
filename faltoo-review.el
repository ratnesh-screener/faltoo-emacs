;;; faltoo-review.el --- Full-file Git review buffers for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'color)
(require 'magit)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-comments)
(require 'faltoo-ask)

(declare-function magit-git-insert "magit-git")
(declare-function magit-run-git-with-input "magit-process")

(defvar-local faltoo-review-source-file nil)
(defvar-local faltoo-review-hunk-positions nil)

(cl-defstruct faltoo-review-hunk
  line new-count rows patch old-start old-count staged snapshot)

(defun faltoo-review--patch (relative &optional cached)
  "Return the complete working-tree patch for RELATIVE.
Read the staged patch when CACHED is non-nil."
  (with-temp-buffer
    (apply #'magit-git-insert "diff"
           (append (and cached '("--cached"))
                   (list "--no-ext-diff" "--no-color"
                         "--unified=0" "--" relative)))
    (buffer-string)))

(defvar faltoo-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'faltoo-ask)
    (define-key map (kbd "l") #'faltoo-show-last-response)
    (define-key map (kbd "c") #'faltoo-comment)
    (define-key map (kbd "C") #'faltoo-file-comment)
    (define-key map (kbd "s") #'faltoo-stage-current-hunk)
    (define-key map (kbd "h") #'faltoo-chat)
    (define-key map (kbd "r") #'faltoo-vc-refresh)
    (define-key map (kbd "u") #'faltoo-unstage-current-hunk)
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

(defun faltoo-review--hunks (patch &optional staged)
  "Parse zero-context Git PATCH into review hunks marked STAGED."
  (let (file-header hunks)
    (with-temp-buffer
      (insert patch)
      (goto-char (point-min))
      (while (re-search-forward
              "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? +\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
              nil t)
        (let ((hunk-start (line-beginning-position))
              (old-start (string-to-number (match-string 1)))
              (old-count (if (match-string 2) (string-to-number (match-string 2)) 1))
              (new-start (string-to-number (match-string 3)))
              (new-count (if (match-string 4) (string-to-number (match-string 4)) 1))
              lines)
          (unless file-header
            (setq file-header (buffer-substring-no-properties (point-min) hunk-start)))
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
          (push (make-faltoo-review-hunk
                 :line new-start
                 :new-count new-count
                 :rows (nreverse lines)
                 :patch (concat file-header
                                (buffer-substring-no-properties hunk-start (point)))
                 :old-start old-start
                 :old-count old-count
                 :staged staged)
                hunks))))
    (nreverse hunks)))

(defun faltoo-review--staged-hunk-in-worktree (hunk unstaged-hunks)
  "Return staged HUNK mapped through UNSTAGED-HUNKS into worktree lines."
  (let ((index-line (faltoo-review-hunk-line hunk))
        (index-count (faltoo-review-hunk-new-count hunk))
        (worktree-line (faltoo-review-hunk-line hunk))
        snapshot)
    (dolist (unstaged unstaged-hunks)
      (let ((old-start (faltoo-review-hunk-old-start unstaged))
            (old-count (faltoo-review-hunk-old-count unstaged)))
        (when (< (+ old-start (max 1 old-count) -1) index-line)
          (cl-incf worktree-line
                   (- (faltoo-review-hunk-new-count unstaged) old-count)))
        (when (and (> index-count 0) (> old-count 0)
                   (< index-line (+ old-start old-count))
                   (< old-start (+ index-line index-count)))
          (setq snapshot t))))
    (let ((mapped (copy-faltoo-review-hunk hunk)))
      (setf (faltoo-review-hunk-line mapped) worktree-line
            (faltoo-review-hunk-snapshot mapped) snapshot)
      mapped)))

(defun faltoo-review--line-background-face (type staged)
  "Return the theme-aware background face for a review line."
  (let ((background
         (face-background
          (if staged
              'magit-diff-file-heading-selection
            (if (eq type 'delete)
                'magit-diff-removed
              'magit-diff-added-highlight))
          nil t)))
    (list :background (if staged (color-darken-name background 40) background)
          :extend t)))

(defun faltoo-review-refresh-buffer ()
  "Regenerate the current review buffer from its source file and Git diff."
  (let* ((file faltoo-review-source-file)
         (workspace (faltoo-workspace))
         (relative (file-relative-name file workspace))
         (default-directory workspace)
         (unstaged-hunks (faltoo-review--hunks
                          (faltoo-review--patch relative)))
         (staged-hunks (faltoo-review--hunks
                        (faltoo-review--patch relative t) t))
         (hunks (sort
                 (append unstaged-hunks
                         (mapcar (lambda (hunk)
                                   (faltoo-review--staged-hunk-in-worktree
                                    hunk unstaged-hunks))
                                 staged-hunks))
                 (lambda (left right)
                   (or (< (faltoo-review-hunk-line left)
                          (faltoo-review-hunk-line right))
                       (and (= (faltoo-review-hunk-line left)
                               (faltoo-review-hunk-line right))
                            (faltoo-review-hunk-staged left)
                            (not (faltoo-review-hunk-staged right)))))))
         (inhibit-read-only t)
         markers)
    (remove-overlays (point-min) (point-max) 'faltoo-review-diff t)
    (erase-buffer)
    (insert-file-contents file)
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
          (forward-line
           (if (zerop (faltoo-review-hunk-new-count hunk))
               (faltoo-review-hunk-line hunk)
             (max 0 (1- (faltoo-review-hunk-line hunk)))))
          (unless (bolp) (insert "\n"))
          (push (copy-marker (point)) markers)
          (dolist (row (faltoo-review-hunk-rows hunk))
            (let ((type (car row))
                  (staged (faltoo-review-hunk-staged hunk))
                  (snapshot (faltoo-review-hunk-snapshot hunk))
                  (start (point)))
              (if (or (eq type 'delete) snapshot)
                  (insert (cadr row) "\n")
                (forward-line 1))
              (add-text-properties
               start (point)
               (list 'faltoo-review-line-type type
                     'faltoo-review-file-line
                     (if (or (eq type 'delete) snapshot)
                         (min total-lines (max 1 (faltoo-review-hunk-line hunk)))
                       (get-text-property start 'faltoo-review-file-line))
                     'faltoo-review-hunk hunk-index
                     'faltoo-review-hunk-patch (faltoo-review-hunk-patch hunk)
                     'faltoo-review-hunk-staged staged
                     'rear-nonsticky t))
              (let ((overlay (make-overlay start (point))))
                (overlay-put overlay 'face
                             (faltoo-review--line-background-face type staged))
                (overlay-put overlay 'priority -100)
                (overlay-put overlay 'faltoo-review-diff t)
                (overlay-put overlay 'faltoo-review-hunk hunk-index))))
          (setq hunk-index (1- hunk-index)))))
    (setq faltoo-review-hunk-positions (mapcar #'marker-position markers))
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

(defun faltoo-review--set-hunk-staged (hunk staged)
  "Mark HUNK as STAGED and update its base line faces."
  (let ((inhibit-read-only t))
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (eq (overlay-get overlay 'faltoo-review-hunk) hunk)
        (put-text-property (overlay-start overlay) (overlay-end overlay)
                           'faltoo-review-hunk-staged staged)
        (overlay-put overlay 'face
                     (faltoo-review--line-background-face
                      (get-text-property (overlay-start overlay)
                                         'faltoo-review-line-type)
                      staged))))
    (set-buffer-modified-p nil)))

(defun faltoo-review--apply-hunks (reverse)
  "Apply selected review hunks to the index, reversing when REVERSE."
  (let* ((range (and (use-region-p) (faltoo-current-line-range)))
         (overlays (if range
                       (overlays-in (car range)
                                    (min (point-max) (1+ (cadr range))))
                     (overlays-at (point))))
         hunks)
    (dolist (overlay overlays)
      (when-let ((hunk (overlay-get overlay 'faltoo-review-hunk)))
        (unless (assq hunk hunks)
          (let ((start (overlay-start overlay)))
            (push (list hunk
                        (get-text-property start 'faltoo-review-hunk-staged)
                        (get-text-property start 'faltoo-review-hunk-patch))
                  hunks)))))
    (unless hunks (user-error "No Git hunk at point"))
    (setq hunks
          (sort (cl-remove-if (lambda (entry) (eq (cadr entry) (not reverse)))
                              hunks)
                (lambda (left right) (< (car left) (car right)))))
    (unless hunks
      (user-error (if reverse "Hunk is not staged" "Hunk is already staged")))
    (let ((default-directory (faltoo-workspace)))
      (with-temp-buffer
        (dolist (entry hunks)
          (let ((patch (nth 2 entry)))
            (if (= (point) (point-min))
                (insert patch)
              (string-match "^@@ " patch)
              (insert (substring patch (match-beginning 0))))))
        (unless (zerop
                 (apply #'magit-run-git-with-input "apply" "--cached"
                        (append (and reverse '("--reverse"))
                                '("--unidiff-zero" "-"))))
          (user-error "Could not %s hunks" (if reverse "unstage" "stage")))))
    (dolist (entry hunks)
      (faltoo-review--set-hunk-staged (car entry) (not reverse)))
    (magit-refresh)
    (message "%s %d hunk%s"
             (if reverse "Unstaged" "Staged")
             (length hunks) (if (cdr hunks) "s" ""))))

(defun faltoo-stage-current-hunk ()
  "Stage the hunk at point or every hunk in the active region."
  (interactive)
  (faltoo-review--apply-hunks nil))

(defun faltoo-unstage-current-hunk ()
  "Unstage the hunk at point or every hunk in the active region."
  (interactive)
  (faltoo-review--apply-hunks t))

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
