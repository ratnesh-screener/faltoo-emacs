;;; faltoo-review.el --- Code-first review mode for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'magit)
(require 'diff-hl)
(require 'faltoo-faces)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-comments)
(require 'faltoo-ask)

(defvar-local faltoo-review--saved-read-only nil)
(defvar-local faltoo-review--saved-header-line-format nil)
(defvar-local faltoo-review--saved-diff-hl-highlight-function nil)

(defvar faltoo-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c f a") #'faltoo-ask)
    (define-key map (kbd "C-c f l") #'faltoo-show-last-response)
    (define-key map (kbd "C-c f c") #'faltoo-comment)
    (define-key map (kbd "C-c f C") #'faltoo-file-comment)
    (define-key map (kbd "C-c f s") #'faltoo-submit-review-comments)
    (define-key map (kbd "C-c f h") #'faltoo-chat)
    (define-key map (kbd "C-c f u") #'faltoo-review-unstaged)
    (define-key map (kbd "C-c f x") #'faltoo-review-stop)
    (define-key map (kbd "C-c f g") #'faltoo-magit-status)
    (define-key map (kbd "C-c f d") #'faltoo-magit-diff-current-file)
    (define-key map (kbd "C-c f ]") #'faltoo-next-change)
    (define-key map (kbd "C-c f [") #'faltoo-prev-change)
    (define-key map (kbd "C-c f =") #'faltoo-show-change)
    (define-key map (kbd "C-c f n") #'faltoo-next-comment)
    (define-key map (kbd "C-c f p") #'faltoo-prev-comment)
    (define-key map (kbd "C-c f N") #'faltoo-review-next-file)
    (define-key map (kbd "C-c f P") #'faltoo-review-prev-file)
    (define-key map (kbd "C-c f S") #'faltoo-stage-current-file)
    (define-key map (kbd "C-c f U") #'faltoo-unstage-current-file)
    (define-key map (kbd "C-c f H s") #'faltoo-stage-current-hunk)
    (define-key map (kbd "C-c f H r") #'faltoo-revert-current-hunk)
    map))

(defun faltoo-diff-hl-highlight-line (overlay type _shape)
  "Highlight the full changed line for diff-hl OVERLAY of TYPE."
  (save-excursion
    (goto-char (overlay-start overlay))
    (move-overlay overlay (line-beginning-position) (line-beginning-position 2))
    (overlay-put overlay 'face
                 (pcase type
                   ('insert 'faltoo-diff-insert-line-face)
                   ('delete 'faltoo-diff-delete-line-face)
                   (_ 'faltoo-diff-change-line-face)))))

(defun faltoo-review-header-line ()
  "Return visible review header text."
  (concat " Faltoo Review " (faltoo-review-lighter)
          "  ·  C-c f a ask  ·  C-c f c comment  ·  C-c f x stop"))

(define-minor-mode faltoo-review-mode
  "Minor mode for Faltoo code review buffers."
  :lighter (:eval (faltoo-review-lighter))
  :keymap faltoo-review-mode-map
  (if faltoo-review-mode
      (progn
        (setq faltoo-review--saved-read-only buffer-read-only
              faltoo-review--saved-header-line-format header-line-format
              faltoo-review--saved-diff-hl-highlight-function diff-hl-highlight-function)
        (setq buffer-read-only t)
        (setq-local header-line-format (faltoo-review-header-line))
        (setq-local diff-hl-highlight-function #'faltoo-diff-hl-highlight-line)
        (diff-hl-mode 1)
        (faltoo-comments-refresh))
    (setq buffer-read-only faltoo-review--saved-read-only
          header-line-format faltoo-review--saved-header-line-format)
    (setq-local diff-hl-highlight-function faltoo-review--saved-diff-hl-highlight-function)))

(defun faltoo-review-file-p (file)
  "Return non-nil when FILE is in current review set."
  (member (file-truename file) faltoo-review-files))


(defun faltoo-review-file-index (file)
  "Return zero-based review index for FILE."
  (cl-position (file-truename file) faltoo-review-files :test #'string=))

(defun faltoo-review-lighter ()
  "Return mode-line lighter for `faltoo-review-mode'."
  (let ((index (and buffer-file-name (faltoo-review-file-index buffer-file-name))))
    (if index
        (format " Faltoo[%d/%d]" (1+ index) (length faltoo-review-files))
      " Faltoo")))

(defun faltoo-review-sync-current-file ()
  "Sync current review index from the active buffer."
  (when (and buffer-file-name (faltoo-review-file-p buffer-file-name))
    (setq faltoo-current-review-index (faltoo-review-file-index buffer-file-name))))

(defun faltoo-review-enable-buffer ()
  "Enable review mode when current file is in review set."
  (when (and buffer-file-name (faltoo-review-file-p buffer-file-name))
    (faltoo-review-sync-current-file)
    (faltoo-review-mode 1)))

(defun faltoo-review-unstaged ()
  "Open unstaged files as full source review buffers."
  (interactive)
  (faltoo-reset-workspace)
  (setq faltoo-review-files (mapcar #'file-truename (faltoo-bridge-unstaged-files))
        faltoo-current-review-index 0)
  (unless faltoo-review-files
    (user-error "No unstaged files"))
  (dolist (file faltoo-review-files)
    (with-current-buffer (find-file-noselect file)
      (faltoo-review-mode 1)))
  (switch-to-buffer (find-file-noselect (car faltoo-review-files)))
  (message "Faltoo reviewing %d unstaged file(s)" (length faltoo-review-files)))

(defun faltoo-review--switch (delta)
  (unless faltoo-review-files
    (user-error "No Faltoo review files"))
  (setq faltoo-current-review-index
        (mod (+ faltoo-current-review-index delta) (length faltoo-review-files)))
  (switch-to-buffer (find-file-noselect (nth faltoo-current-review-index faltoo-review-files)))
  (faltoo-review-mode 1))

(defun faltoo-review-next-file ()
  "Visit next Faltoo review file."
  (interactive)
  (faltoo-review--switch 1))

(defun faltoo-review-prev-file ()
  "Visit previous Faltoo review file."
  (interactive)
  (faltoo-review--switch -1))

(defun faltoo-review-stop ()
  "Stop the current Faltoo review session."
  (interactive)
  (dolist (file faltoo-review-files)
    (let ((buf (find-buffer-visiting file)))
      (when buf
        (with-current-buffer buf
          (faltoo-review-mode -1)))))
  (setq faltoo-review-files nil
        faltoo-current-review-index 0)
  (message "Faltoo review stopped"))

(defun faltoo-vc-refresh ()
  "Refresh diff-hl, Magit, and Faltoo status."
  (dolist (file faltoo-review-files)
    (let ((buf (find-buffer-visiting file)))
      (when buf
        (with-current-buffer buf
          (when (bound-and-true-p diff-hl-mode)
            (diff-hl-update))))))
  (when (fboundp 'magit-refresh)
    (ignore-errors (magit-refresh)))
  (force-mode-line-update t))

(defun faltoo-stage-current-file ()
  "Stage current file through Magit."
  (interactive)
  (magit-stage-file (faltoo-current-file))
  (faltoo-vc-refresh)
  (message "Staged %s" (faltoo-relative-file (faltoo-current-file))))

(defun faltoo-unstage-current-file ()
  "Unstage current file through Magit."
  (interactive)
  (magit-unstage-file (faltoo-current-file))
  (faltoo-vc-refresh)
  (message "Unstaged %s" (faltoo-relative-file (faltoo-current-file))))

(defun faltoo-stage-current-hunk ()
  "Stage current hunk through diff-hl."
  (interactive)
  (call-interactively #'diff-hl-stage-current-hunk)
  (faltoo-vc-refresh))

(defun faltoo-revert-current-hunk ()
  "Revert current hunk through diff-hl."
  (interactive)
  (call-interactively #'diff-hl-revert-hunk)
  (faltoo-vc-refresh))

(defun faltoo-next-change ()
  "Jump to next Git change."
  (interactive)
  (call-interactively #'diff-hl-next-hunk))

(defun faltoo-prev-change ()
  "Jump to previous Git change."
  (interactive)
  (call-interactively #'diff-hl-previous-hunk))

(defun faltoo-show-change ()
  "Show current Git hunk."
  (interactive)
  (call-interactively #'diff-hl-show-hunk))

(defun faltoo-magit-status ()
  "Open Magit status for the Faltoo workspace."
  (interactive)
  (magit-status (faltoo-workspace)))

(defun faltoo-magit-diff-current-file ()
  "Open Magit diff for current file."
  (interactive)
  (magit-diff-working-tree nil (list "--" (faltoo-current-file))))

(add-hook 'find-file-hook #'faltoo-review-enable-buffer)
(add-hook 'buffer-list-update-hook #'faltoo-review-sync-current-file)

(provide 'faltoo-review)
;;; faltoo-review.el ends here
