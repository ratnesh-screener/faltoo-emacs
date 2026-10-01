;;; faltoo-review.el --- Full-file Git review buffers for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'eieio)
(require 'color)
(require 'image)
(require 'magit)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-comments)
(require 'faltoo-ask)

(declare-function magit-apply-hunks "magit-apply")
(defvar magit-root-section)

(defvar-local faltoo-review-source-file nil)
(defvar-local faltoo-review-file-type 'text
  "Either text, an Emacs image type, or nil for a path-only binary review.")
(defvar-local faltoo-review-eof-line nil
  "Source line of the trailing empty EOF row, which has no text properties.")
(defvar-local faltoo-review-hunk-positions nil)
(defvar-local faltoo-review-hidden-type nil
  "Diff row type hidden in this review buffer, or nil for the full view.")

(defvar-local faltoo-review-diff-buffer nil
  "Plain backing buffer for this file's staged and unstaged Magit sections.")

(defun faltoo-review--kill-diff ()
  "Release the backing buffer owned by this review."
  (kill-buffer faltoo-review-diff-buffer)
  (setq faltoo-review-diff-buffer nil))

(defun faltoo-review--diff-sections ()
  "Refresh and return this file's unstaged and staged Magit section groups."
  (let ((file faltoo-review-source-file)
        (workspace (faltoo-workspace)))
    (unless faltoo-review-diff-buffer
      (setq faltoo-review-diff-buffer (generate-new-buffer " *Faltoo diff*"))
      (add-hook 'kill-buffer-hook #'faltoo-review--kill-diff nil t))
    (with-current-buffer faltoo-review-diff-buffer
      (setq default-directory workspace)
      (setq-local magit-buffer-diff-args '("-U3" "--no-ext-diff")
                  magit-buffer-diff-files (list (file-relative-name file workspace)))
      (erase-buffer)
      (remove-overlays)
      (magit-insert-section (diffbuf)
        (magit-insert-unstaged-changes)
        (magit-insert-staged-changes))
      (set-buffer-modified-p nil)
      (oref magit-root-section children))))

(defvar faltoo-review-mode-map (make-sparse-keymap))

(setcdr faltoo-review-mode-map nil)
(dolist (binding '(("a" . faltoo-ask)
                   ("l" . faltoo-show-last-response)
                   ("c" . faltoo-comment)
                   ("C" . faltoo-file-comment)
                   ("s" . faltoo-stage-current-hunk)
                   ("h" . faltoo-chat)
                   ("o" . faltoo-review-cycle-view)
                   ("r" . faltoo-vc-refresh)
                   ("R" . faltoo-review-refresh-all)
                   ("u" . faltoo-unstage-current-hunk)
                   ("x" . faltoo-review-stop)
                   ("g" . beginning-of-buffer)
                   ("G" . end-of-buffer)
                   ("D" . faltoo-magit-diff-current-file)
                   ("d" . faltoo-delete-current-comment)
                   ("m" . faltoo-comments-summary)
                   ("]" . faltoo-next-change)
                   ("[" . faltoo-prev-change)
                   ("=" . faltoo-show-change)
                   ("n" . faltoo-review-next-file)
                   ("p" . faltoo-review-prev-file)
                   ("N" . faltoo-next-comment)
                   ("P" . faltoo-prev-comment)
                   ("S" . faltoo-stage-current-file)
                   ("U" . faltoo-unstage-current-file)))
  (keymap-set faltoo-review-mode-map (car binding) (cdr binding)))

(defun faltoo-review-cycle-view ()
  "Cycle full, removed-only, and added-only views, retaining unchanged context."
  (interactive)
  (setq faltoo-review-hidden-type
        (pcase faltoo-review-hidden-type ('insert 'delete) ('delete nil) (_ 'insert)))
  (dolist (overlay (overlays-in (point-min) (point-max)))
    (when (overlay-get overlay 'faltoo-review-diff)
      (overlay-put overlay 'invisible
                   (eq faltoo-review-hidden-type
                       (get-text-property (overlay-start overlay) 'faltoo-review-line-type)))))
  (message "Faltoo review: %s"
           (pcase faltoo-review-hidden-type ('insert "removed") ('delete "added") (_ "full"))))

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

(defun faltoo-review--file-type (file)
  "Classify FILE by content before opening it in a source buffer."
  (let ((mime (with-temp-buffer
                (call-process "file" nil t nil "--brief" "--mime-type" "--" file)
                (string-trim (buffer-string)))))
    (cond ((string-prefix-p "image/" mime) (image-type-from-file-header file))
          ((or (string-prefix-p "text/" mime)
               (member mime '("application/json" "application/xml"
                              "application/javascript" "application/x-empty" "inode/x-empty"))
               (string-suffix-p "+json" mime)
               (string-suffix-p "+xml" mime))
           'text))))

(defun faltoo-review-refresh-buffer ()
  "Refresh review contents, preserving reader offsets within the new bounds."
  (buffer-disable-undo)
  (let ((position (point))
        (windows (mapcar (lambda (window)
                           (list window (window-point window) (window-start window)))
                         (get-buffer-window-list (current-buffer) nil t))))
    (if (eq faltoo-review-file-type 'text)
        (faltoo-review--refresh-text-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert faltoo-review-source-file "\n")
        (when (and faltoo-review-file-type
                   (image-type-available-p faltoo-review-file-type))
          (clear-image-cache faltoo-review-source-file)
          (insert-image (create-image faltoo-review-source-file faltoo-review-file-type)))
        (set-buffer-modified-p nil)))
    (goto-char (min position (point-max)))
    (pcase-dolist (`(,window ,point ,start) windows)
      (set-window-point window (min point (point-max)))
      (set-window-start window (min start (point-max))))))

(defun faltoo-review--render-diff (group positions)
  "Render GROUP against new-side POSITIONS and return old-side positions.
Each position pairs an insertion-following marker with a canonical source line.
The unstaged pass maps worktree to index; the staged pass uses that same map."
  (let ((line 1)
        (staged (eq (oref group type) 'staged))
        (sections (cl-loop for file in (oref group children)
                           append (oref file children)))
        previous)
    (dolist (section sections)
      (pcase-let* ((`(,start ,count) (oref section to-range))
                   (rows (with-current-buffer (marker-buffer (oref section start))
                           (split-string (buffer-substring-no-properties
                                          (oref section content) (oref section end)) "\n" t)))
                   (first-change t))
        (dotimes (_ (- (if (zerop count) (1+ start) start) line))
          (push (pop positions) previous)
          (cl-incf line))
        (dolist (row rows)
          (pcase (aref row 0)
            (?\s (push (pop positions) previous) (cl-incf line))
            ((or ?+ ?-)
             (goto-char (caar positions))
             ;; Keep a blue snapshot when a staged addition was later deleted.
             (let* ((type (if (= (aref row 0) ?+) 'insert 'delete))
                    (source-line (cdar positions))
                    (insert-row (or (eq type 'delete)
                                    (and staged (eq (get-text-property
                                                     (point) 'faltoo-review-line-type)
                                                    'delete)))))
               (when (and insert-row (not (bolp))) (insert "\n"))
               (let ((beg (point)))
                 (if insert-row (insert (substring row 1) "\n") (forward-line 1))
                 (add-text-properties
                  beg (point) (list 'faltoo-review-line-type type
                                    'faltoo-review-file-line source-line
                                    'faltoo-review-hunk-staged staged
                                    'rear-nonsticky t))
                 (let ((overlay (make-overlay beg (point) nil t)))
                   (overlay-put overlay 'face (faltoo-review--line-background-face type staged))
                   (overlay-put overlay 'invisible (eq type faltoo-review-hidden-type))
                   (overlay-put overlay 'priority -100)
                   (overlay-put overlay 'faltoo-review-diff t)
                   (overlay-put overlay 'faltoo-review-hunk section))
                 (when first-change
                   (push (copy-marker beg t) faltoo-review-hunk-positions)
                   (setq first-change nil))
                 (if (eq type 'delete)
                     (push (cons (copy-marker beg t) source-line) previous)
                   (pop positions)
                   (cl-incf line)))))))))
    (nconc (nreverse previous) positions)))

(defun faltoo-review--refresh-text-buffer ()
  "Regenerate the full file using the same Magit sections used for staging."
  ;; Reuse Magit's repository queries across both sides of this refresh.
  (let* ((magit--refresh-cache (list (cons 0 0)))
         (groups (faltoo-review--diff-sections))
         (inhibit-read-only t)
         (line 1)
         positions)
    (remove-overlays (point-min) (point-max) 'faltoo-review-diff t)
    (erase-buffer)
    (insert-file-contents faltoo-review-source-file)
    (goto-char (point-max))
    (setq faltoo-review-eof-line (and (bolp) (line-number-at-pos))
          faltoo-review-hunk-positions nil)
    (goto-char (point-min))
    (while (< (point) (point-max))
      (let ((start (point)))
        (push (cons (copy-marker start t) line) positions)
        (forward-line 1)
        (add-text-properties start (point)
                             (list 'faltoo-review-line-type 'context
                                   'faltoo-review-file-line line 'rear-nonsticky t)))
      (cl-incf line))
    ;; The sentinel anchors deletions at EOF, including empty files.
    (push (cons (copy-marker (point-max) t) (max 1 (1- line))) positions)
    (setq positions (nreverse positions))
    (dolist (group groups)
      (setq positions (faltoo-review--render-diff group positions)))
    (setq faltoo-review-hunk-positions
          (sort (mapcar #'marker-position faltoo-review-hunk-positions) #'<))
    (set-buffer-modified-p nil)))

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
      (let* ((type (faltoo-review--file-type file))
             (mode (if (eq type 'text)
                       (buffer-local-value 'major-mode (find-file-noselect file))
                     #'fundamental-mode)))
        (setq buf (get-buffer-create name))
        (with-current-buffer buf
          (funcall mode)
          (setq default-directory (file-name-directory file)
                faltoo-review-source-file file
                faltoo-review-file-type type)
          (faltoo-review-refresh-buffer)
          (faltoo-review-mode 1))))
    (faltoo-review--attach-comments file buf)
    buf))

(defun faltoo-review--close-files (files workspace)
  "Close generated review buffers for FILES while preserving WORKSPACE comments."
  (dolist (comment (faltoo-comments--list workspace))
    (when (member (faltoo-comment-path comment) files)
      (faltoo-comments--delete-overlays (list comment))
      (setf (faltoo-comment-source-buffer comment)
            (find-file-noselect (faltoo-comment-path comment)))))
  (dolist (file files)
    (when-let ((buffer (get-buffer (faltoo-review-buffer-name file))))
      (kill-buffer buffer))))

(defun faltoo-review-unstaged ()
  "Open unstaged files as generated full-file review buffers."
  (interactive)
  (let* ((old-files faltoo-review-files)
         (old-workspace faltoo-review-workspace)
         (workspace (faltoo-reset-workspace))
         (new-files (mapcar #'file-truename
                            (faltoo-bridge-unstaged-files workspace)))
         (removed-files (if (equal old-workspace workspace)
                            (cl-set-difference old-files new-files :test #'string=)
                          old-files)))
    (setq faltoo-review-files new-files
          faltoo-review-workspace (and new-files workspace)
          faltoo-current-review-index 0)
    (when removed-files
      (faltoo-review--close-files removed-files old-workspace))
    (unless faltoo-review-files
      (when removed-files
        (faltoo-comments-refresh old-workspace))
      (user-error "No unstaged files"))
    (when (and removed-files (not (equal old-workspace workspace)))
      (faltoo-comments-refresh old-workspace))
    (faltoo-review-refresh-all)
    (let ((buffer (faltoo-review-buffer (car faltoo-review-files))))
      (if (derived-mode-p 'faltoo-chat-mode)
          (pop-to-buffer buffer #'display-buffer-pop-up-window)
        (switch-to-buffer buffer)))
    (message "Faltoo reviewing %d unstaged file(s)" (length faltoo-review-files))))

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
        (workspace faltoo-review-workspace))
    (faltoo-review--close-files faltoo-review-files workspace)
    (setq faltoo-review-files nil
          faltoo-review-workspace nil
          faltoo-current-review-index 0)
    (when source
      (switch-to-buffer source))
    (faltoo-comments-refresh workspace)
    (message "Faltoo review stopped")))

(defun faltoo-vc-refresh ()
  "Regenerate the current review buffer and refresh Magit."
  (interactive)
  (faltoo-review-refresh-buffer)
  (magit-refresh)
  (faltoo-comments-refresh faltoo-review-workspace)
  (force-mode-line-update t))

(defun faltoo-review-refresh-all ()
  "Regenerate every loaded buffer in the current review set."
  (interactive)
  (dolist (file faltoo-review-files)
    (when-let ((buf (get-buffer (faltoo-review-buffer-name file))))
      (with-current-buffer buf
        (faltoo-review-refresh-buffer))))
  (magit-refresh)
  (faltoo-comments-refresh faltoo-review-workspace)
  (force-mode-line-update t))

(defun faltoo-review--apply-hunks (reverse)
  "Apply the selected Magit sections, unstaging when REVERSE."
  (let* ((range (and (use-region-p) (faltoo-current-line-range)))
         (overlays (if range
                       (overlays-in (car range) (min (point-max) (1+ (cadr range))))
                     (overlays-at (point))))
         (sections (delete-dups
                    (cl-loop for overlay in overlays
                             for section = (overlay-get overlay 'faltoo-review-hunk)
                             when (and section
                                       (magit-section-match
                                        (if reverse [hunk file staged] [hunk file unstaged])
                                        section))
                             collect section))))
    (unless sections (user-error "No %s hunk selected" (if reverse "staged" "unstaged")))
    (setq sections (sort sections (lambda (a b) (< (oref a start) (oref b start)))))
    (with-current-buffer faltoo-review-diff-buffer
      (let ((this-command (if reverse 'magit-unstage 'magit-stage)))
        (apply #'magit-apply-hunks sections "--cached" (and reverse '("--reverse")))))
    (faltoo-review-refresh-buffer)
    (faltoo-comments-refresh (faltoo-workspace))
    (deactivate-mark)))

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
    (magit-stage-files (list file))
    (faltoo-review-refresh-buffer)
    (faltoo-comments-refresh (faltoo-workspace))
    (message "Staged %s" (faltoo-relative-file file))))

(defun faltoo-unstage-current-file ()
  "Unstage the reviewed source file through Magit."
  (interactive)
  (let ((file (faltoo-current-file)))
    (magit-unstage-files (list file))
    (faltoo-review-refresh-buffer)
    (faltoo-comments-refresh (faltoo-workspace))
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
  (unless (get-char-property (point) 'faltoo-review-hunk)
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


(provide 'faltoo-review)
;;; faltoo-review.el ends here
