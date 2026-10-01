;;; faltoo-review-git-test.el --- Real Git/Magit review specs -*- lexical-binding: t; -*-

(require 'ert)
(require 'package)
(package-initialize)
(add-to-list 'load-path (file-name-directory (directory-file-name
                                             (file-name-directory load-file-name))))
(require 'faltoo)

(defvar magit-before-change-functions)
(defvar magit-after-apply-functions)

;; Batch frames do not have the GUI theme's diff backgrounds.
(set-face-attribute 'magit-diff-file-heading-selection nil :background "#224466")
(set-face-attribute 'magit-diff-added-highlight nil :background "#224422")
(set-face-attribute 'magit-diff-removed nil :background "#442222")

(defun faltoo-git-test--with-review (base changed body)
  "Run BODY in a real temporary repo reviewing CHANGED against committed BASE."
  (let* ((root (file-name-as-directory (make-temp-file "faltoo-git-spec" t)))
         (default-directory root)
         (file (expand-file-name "sample.txt" root))
         (faltoo-review-workspace root)
         (faltoo-review-files (list file))
         (faltoo-comments (make-hash-table :test #'equal))
         review)
    (unwind-protect
        (progn
          (should (zerop (magit-call-git "init" "-q")))
          (magit-call-git "config" "core.hooksPath" "/dev/null")
          (write-region base nil file nil 'silent)
          (magit-call-git "add" "sample.txt")
          (should (zerop (magit-call-git "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                                        "commit" "-qm" "Base")))
          (write-region changed nil file nil 'silent)
          (setq review (faltoo-review-buffer file))
          (save-window-excursion
            (switch-to-buffer review)
            (funcall body file)
            (should (equal (buffer-local-value 'faltoo-review-source-file (window-buffer))
                           (file-truename file)))))
      (when-let ((buffer (get-buffer (faltoo-review-buffer-name file))))
        (kill-buffer buffer))
      (when-let ((source (find-buffer-visiting file)))
        (with-current-buffer source (set-buffer-modified-p nil))
        (kill-buffer source))
      (dolist (buffer (magit-mode-get-buffers))
        (when (equal (buffer-local-value 'default-directory buffer) root)
          (kill-buffer buffer)))
      (delete-directory root t))))

(defun faltoo-git-test--select (text staged &optional through)
  "Select changed row TEXT with STAGED state, optionally THROUGH another row."
  (goto-char (point-min))
  (while (not (and (equal (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)) text)
                  (eq (get-text-property (point) 'faltoo-review-hunk-staged) staged)))
    (when (eobp) (ert-fail (format "Missing review row %S staged=%S" text staged)))
    (forward-line 1))
  (let ((overlay (seq-find (lambda (overlay) (overlay-get overlay 'faltoo-review-diff))
                           (overlays-at (point)))))
    (should (equal (overlay-get overlay 'face)
                   (faltoo-review--line-background-face
                    (get-text-property (point) 'faltoo-review-line-type) staged))))
  (deactivate-mark)
  (when through
    (set-mark (point))
    (search-forward through)
    (activate-mark)))

(ert-deftest faltoo-git-review-roundtrips-edits-inside-a-staged-block ()
  "Scenario: Nearby edits group into a Magit hunk and repeated s/u uses fresh state."
  (let* ((base "before\nafter\n")
         (staged "before\nblock-0\nblock-1\nblock-2\nblock-3\nblock-4\nblock-5\nafter\n")
         (edited (string-replace "block-4" "EDIT-4"
                                 (string-replace "block-1" "EDIT-1" staged))))
    (faltoo-git-test--with-review
     base staged
     (lambda (file)
       (faltoo-git-test--select "block-0" nil)
       (faltoo-stage-current-hunk)
       (should (equal (magit-git-output "show" ":sample.txt") staged))
       ;; Two non-adjacent line edits inside an already staged block.
       (write-region edited nil file nil 'silent)
       (faltoo-vc-refresh)
       (dotimes (_ 2)
         (faltoo-git-test--select "EDIT-1" nil)
         (faltoo-stage-current-hunk)
         (should (equal (magit-git-output "show" ":sample.txt") edited))
         (faltoo-git-test--select "block-0" t)
         (faltoo-unstage-current-hunk)
         (should (equal (magit-git-output "show" ":sample.txt") base)))
       (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) edited))))))

(ert-deftest faltoo-git-review-stages-separated-insertions-inside-a-staged-block ()
  "Scenario: Staging a later insertion first neither mislabels nor duplicates lines."
  (let* ((base "before\nafter\n")
         (staged (concat "before\n"
                         (mapconcat (lambda (n) (format "block-%02d\n" n))
                                    (number-sequence 0 39) "") "after\n"))
         (later (string-replace "block-30\n" "block-30\nLATER\n" staged))
         (edited (string-replace "block-05\n" "block-05\nEARLIER\n" later)))
    (faltoo-git-test--with-review
     base staged
     (lambda (file)
       (faltoo-git-test--select "block-00" nil)
       (faltoo-stage-current-hunk)
       (write-region edited nil file nil 'silent)
       (faltoo-vc-refresh)
       ;; Both insertions must be visibly unstaged, despite the staged block.
       (faltoo-git-test--select "EARLIER" nil)
       (faltoo-git-test--select "LATER" nil)
       (faltoo-stage-current-hunk)
       (should (equal (magit-git-output "show" ":sample.txt") later))
       (faltoo-git-test--select "EARLIER" nil)
       (faltoo-stage-current-hunk)
       (should (equal (magit-git-output "show" ":sample.txt") edited))
       (faltoo-git-test--select "block-00" t)
       (faltoo-unstage-current-hunk)
       (should (equal (magit-git-output "show" ":sample.txt") base))
       (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) edited))))))

(ert-deftest faltoo-git-review-applies-only-selected-distant-hunks ()
  "Scenario: Selected lower hunks roundtrip without including the earlier change."
  (dolist (operation '(insert delete))
    (let* ((base (mapconcat (lambda (n) (format "line-%02d\n" n))
                           (number-sequence 0 79) ""))
           (changed base)
           selected)
      (dolist (n '(60 35 10))
        (setq changed (string-replace
                       (format "line-%02d\n" n)
                       (if (eq operation 'insert)
                           (format "line-%02d\nADD-%02d\n" n n) "") changed))
        (when (= n 35) (setq selected changed)))
      (faltoo-git-test--with-review
       base changed
       (lambda (file)
         (let ((first (if (eq operation 'insert) "ADD-35" "line-35"))
               (last (if (eq operation 'insert) "ADD-60" "line-60")))
           (faltoo-git-test--select first nil last)
           (faltoo-stage-current-hunk)
           (should (equal (magit-git-output "show" ":sample.txt") selected))
           (faltoo-git-test--select first t last)
           (faltoo-unstage-current-hunk)
           (should (equal (magit-git-output "show" ":sample.txt") base)))
         (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) changed)))))))

(ert-deftest faltoo-git-review-git-actions-run-hooks-and-refresh-once ()
  "Scenario: Hunk and file actions retain native hooks and refresh Magit only once."
  (dolist (scope '(hunk file))
    (faltoo-git-test--with-review
     "before\n" "after\n"
     (lambda (file)
       (let* ((refresh (symbol-function 'magit-refresh))
              (refreshes 0)
              before after
              (magit-before-change-functions (list (lambda (_files task) (push task before))))
              (magit-after-apply-functions (list (lambda (_files task) (push task after)))))
         (cl-letf (((symbol-function 'magit-refresh)
                    (lambda () (cl-incf refreshes) (funcall refresh))))
           (funcall (if (eq scope 'hunk) #'faltoo-stage-current-hunk #'faltoo-stage-current-file))
           (should (equal (magit-git-output "show" ":sample.txt") "after\n"))
           (should (= refreshes 1))
           (faltoo-git-test--select "after" t)
           (funcall (if (eq scope 'hunk) #'faltoo-unstage-current-hunk #'faltoo-unstage-current-file))
           (should (equal (magit-git-output "show" ":sample.txt") "before\n"))
           (should (= refreshes 2)))
         (should (equal before '(" before unstage" " before stage")))
         (should (equal after '(" after unstage" " after stage")))
         (faltoo-git-test--select "after" nil)
         (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "after\n")))))))

(ert-deftest faltoo-git-review-shares-one-mode-free-backing-buffer ()
  "Scenario: Both Git states share one plain buffer, reused on refresh and killed with review."
  (faltoo-git-test--with-review
   "before\nafter\n" "before\nadded\nafter\n"
   (lambda (file)
     (faltoo-git-test--select "added" nil)
     (let* ((section (get-char-property (point) 'faltoo-review-hunk))
            (apply-hunks (symbol-function 'magit-apply-hunks))
            (buffer (marker-buffer (oref section start)))
            applied)
       (should (eq (buffer-local-value 'major-mode buffer) 'fundamental-mode))
       (should (eq (buffer-local-value 'buffer-undo-list buffer) t))
       (should (magit-section-match [hunk file unstaged] section))
       (cl-letf (((symbol-function 'magit-apply-hunks)
                  (lambda (sections &rest args)
                    (should (equal sections (list section)))
                    (should (eq (current-buffer) buffer))
                    (setq applied t)
                    (apply apply-hunks sections args))))
         (faltoo-stage-current-hunk))
       (should applied)
       ;; Both sides must coexist after editing a staged line.
       (write-region "before\nedited\nafter\n" nil file nil 'silent)
       (faltoo-review-refresh-buffer)
       (dolist (staged '(nil t))
         (faltoo-git-test--select (if staged "added" "edited") staged)
         (let ((section (get-char-property (point) 'faltoo-review-hunk)))
           (should (eq (marker-buffer (oref section start)) buffer))
           (should (magit-section-match (if staged [hunk file staged] [hunk file unstaged]) section))))
       (should-not (get-buffer-window buffer t))
       (kill-buffer (current-buffer))
       (should-not (buffer-live-p buffer))
       (with-current-buffer (find-buffer-visiting file) (revert-buffer t t))
       (switch-to-buffer (faltoo-review-buffer file))))))

(ert-deftest faltoo-git-review-maps-staged-lines-through-worktree-edits ()
  "Scenario: Deletions, multiple shifts, and overlaps keep both Git states and source coordinates."
  (pcase-dolist (`(,base ,index ,worktree ,expected)
                '(("head\nremove\ncontext\nold\nend\n"
                   "head\nremove\ncontext\nstaged\nend\n" "context\nstaged\nend\n"
                   ((delete nil "head" 1) (delete nil "remove" 1)
                    (delete t "old" 2) (insert t "staged" 2)))
                  ("a\nold\nz\n" "a\nstaged\nz\n" "first\na\nstaged\nmiddle\nz\nlast\n"
                   ((insert nil "first" 1) (delete t "old" 3) (insert t "staged" 3)
                    (insert nil "middle" 4) (insert nil "last" 6)))
                  ("old\n" "staged\n" "working\n"
                   ((delete t "old" 1) (insert t "staged" 1)
                    (delete nil "staged" 1) (insert nil "working" 1)))
                  ("a\nz\n" "a\nblock1\nblock2\nz\n" "a\nz\n"
                   ((insert t "block1" 2) (delete nil "block1" 2)
                    (insert t "block2" 2) (delete nil "block2" 2)))))
    (faltoo-git-test--with-review
     base index
     (lambda (file)
       (faltoo-stage-current-file)
       (write-region worktree nil file nil 'silent)
       (faltoo-review-refresh-buffer)
       (let (rows)
         (goto-char (point-min))
         (while (not (eobp))
           (let ((type (get-text-property (point) 'faltoo-review-line-type)))
             (unless (eq type 'context)
               ;; Inserting staged snapshots must not expand an existing red
               ;; overlay onto the blue row and give it two staging targets.
               (let* ((overlays (seq-filter (lambda (overlay)
                                             (overlay-get overlay 'faltoo-review-diff))
                                           (overlays-at (point))))
                      (section (overlay-get (car overlays) 'faltoo-review-hunk)))
                 (should (= (length overlays) 1))
                 (should (eq (get-text-property (point) 'faltoo-review-hunk-staged)
                             (magit-section-match [hunk file staged] section))))
               (push (list type (get-text-property (point) 'faltoo-review-hunk-staged)
                           (buffer-substring-no-properties (point) (line-end-position))
                           (get-text-property (point) 'faltoo-review-file-line)) rows)))
           (forward-line 1))
         (should (equal (nreverse rows) expected)))
       (should (equal (magit-git-output "show" ":sample.txt") index))))))

(ert-deftest faltoo-git-review-roundtrips-empty-files-and-missing-final-newlines ()
  "Scenario: Boundary rows remain selectable without treating diff metadata as code."
  (pcase-dolist (`(,base ,changed ,row)
                '(("" "added\n" "added")
                  ("gone\n" "" "gone")
                  ("before" "after" "after")
                  ("first\nlast" "first\n" "last")))
    (faltoo-git-test--with-review
     base changed
     (lambda (_file)
       (faltoo-git-test--select row nil)
       (should-not (string-match-p "No newline at end" (buffer-string)))
       (faltoo-stage-current-hunk)
       (should (equal (magit-git-output "show" ":sample.txt") changed))
       (faltoo-git-test--select row t)
       (faltoo-unstage-current-hunk)
       (should (equal (magit-git-output "show" ":sample.txt") base))))))

(ert-deftest faltoo-git-review-large-file-load-and-cached-navigation-stay-interactive ()
  "Scenario: A 20,000-line file uses real Git on load, not on cached navigation."
  (let* ((base (mapconcat (lambda (n) (format "line-%05d\n" n))
                         (number-sequence 1 20000) ""))
         (changed base))
    (dolist (n '(100 4000 8000 12000 16000 19900))
      (setq changed (string-replace (format "line-%05d" n)
                                    (format "EDIT-%05d" n) changed)))
    (faltoo-git-test--with-review
     base changed
     (lambda (file)
       (kill-buffer (current-buffer))
       (garbage-collect)
       (let* ((start (float-time))
              (buffer (faltoo-review-buffer file))
              (elapsed (- (float-time) start)))
         (should (< elapsed 0.3))
         (switch-to-buffer buffer)
         (should (eq buffer-undo-list t))
         (should (= (length faltoo-review-hunk-positions) 6))
         (let ((start (float-time)))
           (cl-letf (((symbol-function 'magit--insert-diff)
                      (lambda () (ert-fail "Cached navigation rebuilt the diff"))))
             (dotimes (_ 100) (should (eq (faltoo-review-buffer file) buffer))))
           (should (< (- (float-time) start) 0.1)))
         (message "Real Git review: load %.3fs; 100 cached visits %.3fs"
                  elapsed (- (float-time) start elapsed)))))))

;;; faltoo-review-git-test.el ends here
