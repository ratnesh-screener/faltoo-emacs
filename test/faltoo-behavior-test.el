;;; faltoo-behavior-test.el --- Behavior specs for faltoo -*- lexical-binding: t; -*-

(require 'ert)
(add-to-list 'load-path default-directory)

;; Test doubles for required packages. The plugin requires these packages in real
;; use; tests stub only the small surface they exercise.
(defun posframe-show (&rest _args) nil)
(defun posframe-hide-all () nil)
(defun posframe-hide (&rest _args) nil)
(provide 'posframe)

(defun magit-stage-file (&rest _args) nil)
(defun magit-unstage-file (&rest _args) nil)
(defun magit-status (&rest _args) nil)
(defun magit-diff-working-tree (&rest _args) nil)
(defun magit-refresh (&rest _args) nil)
(provide 'magit)

(defvar diff-hl-highlight-function nil)
(define-minor-mode diff-hl-mode "")
(defun diff-hl-update () nil)
(defun diff-hl-stage-current-hunk () nil)
(defun diff-hl-revert-hunk () nil)
(defun diff-hl-next-hunk () nil)
(defun diff-hl-previous-hunk () nil)
(defun diff-hl-show-hunk () nil)
(provide 'diff-hl)

(require 'faltoo)

(defun faltoo-test--with-temp-git-file (lines body)
  "Create a temporary Git-backed file containing LINES, then call BODY."
  (let* ((root (file-name-as-directory (make-temp-file "faltoo-test" t)))
         (default-directory root)
         (file (expand-file-name "sample.py" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (write-region (string-join lines "\n") nil file nil 'silent)
          (find-file file)
          (setq faltoo-workspace root)
          (funcall body file root))
      (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
      (delete-directory root t))))

(defun faltoo-test--without-popup-display (body)
  "Run BODY without showing posframes."
  (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil))
            ((symbol-function 'faltoo-popup-close) (lambda () nil)))
    (funcall body)))

;;; Ask specs

(ert-deftest faltoo-ask-uses-current-line-when-region-is-not-active ()
  "Scenario: Ask uses the current line when no region is active."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given point is on line 2 with no active region.
     (goto-char (point-min))
     (forward-line 1)

     ;; When Ask builds context.
     (let ((context (faltoo-ask--context)))

       ;; Then only the current line is included.
       (should (equal (plist-get context :start) 2))
       (should (equal (plist-get context :end) 2))
       (should (equal (plist-get context :code) "two"))))))

(ert-deftest faltoo-ask-uses-active-region-when-present ()
  "Scenario: Ask uses the active region when one is selected."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given lines 1-2 are selected.
     (goto-char (point-min))
     (set-mark (point))
     (forward-line 2)
     (activate-mark)

     ;; When Ask builds context.
     (let ((context (faltoo-ask--context)))

       ;; Then selected code is included instead of the current line.
       (should (equal (plist-get context :start) 1))
       (should (equal (plist-get context :end) 3))
       (should (equal (plist-get context :code) "one\ntwo\n"))))))

(ert-deftest faltoo-ask-empty-question-does-not-capture-help-text ()
  "Scenario: Ask help text is not submitted as the question."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given an Ask popup is opened but no question is typed.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-ask))

     ;; When reading the editable question payload.
     (with-current-buffer "*Faltoo Popup*"

       ;; Then it is empty; footer/help text is outside the payload.
       (should (string-empty-p (faltoo-ask--question-text)))))))

(ert-deftest faltoo-ask-stream-routes-answer-to-popup-and-transcript ()
  "Scenario: Ask responses stream near code and into transcript history."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given a mocked bridge stream that emits status, answer, and done events.
     (setq faltoo-review-files nil
           faltoo-last-assistant-message "")
     (when (get-buffer faltoo-chat-buffer-name) (kill-buffer faltoo-chat-buffer-name))
     (let ((popup (get-buffer-create "*Faltoo Test Popup*")))
       (with-current-buffer popup (erase-buffer))

       ;; When a message is sent.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args _payload on-event on-done)
                    (funcall on-event '((classes . "status") (text . "Submitted message")))
                    (funcall on-event '((classes . "answer") (text . "hello from assistant")))
                    (funcall on-event '((classes . "done") (text . "Assistant response saved.")))
                    (funcall on-done t)))
                 ((symbol-function 'faltoo-bridge-messages)
                  (lambda () '(((role . "assistant") (text . "hello from assistant")))))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))
         (faltoo-request-message "question" popup))

       ;; Then latest response, popup, and transcript all receive the answer.
       (should (equal faltoo-last-assistant-message "hello from assistant"))
       (with-current-buffer popup
         (should (string-match-p "hello from assistant" (buffer-string))))
       (with-current-buffer faltoo-chat-buffer-name
         (should (string-match-p "hello from assistant" (buffer-string))))
       (kill-buffer popup)))))

;;; Popup specs

(ert-deftest faltoo-popup-show-creates-focusable-bordered-posframe ()
  "Scenario: Faltoo popups are focusable and visibly bordered."
  (let (captured-args)
    ;; Given posframe-show is observed instead of displaying a real child frame.
    (cl-letf (((symbol-function 'posframe-show)
               (lambda (&rest args)
                 (setq captured-args args)
                 (selected-frame)))
              ((symbol-function 'select-frame-set-input-focus) (lambda (&rest _args) nil)))

      ;; When showing a Faltoo popup.
      (faltoo-popup-show (get-buffer-create "*Faltoo Popup Test*") 80 20))

    ;; Then the posframe is focusable and has a border.
    (should (plist-get (cdr captured-args) :accept-focus))
    (should (> (plist-get (cdr captured-args) :border-width) 0))
    (should (plist-get (cdr captured-args) :border-color))))

;;; Comment specs

(ert-deftest faltoo-comment-save-marks-line-as-pending-review-comment ()
  "Scenario: Saving a line comment marks the source line."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given point is on line 2 and the comment popup is open.
     (setq faltoo-comments nil)
     (goto-char (point-min))
     (forward-line 1)

     ;; When the user writes and saves a review comment.
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-comment)
        (with-current-buffer "*Faltoo Comment*"
          (goto-char (point-max))
          (insert "please review this")
          (faltoo-comment-save))))

     ;; Then there is one pending comment with a source overlay.
     (should (= (length faltoo-comments) 1))
     (let ((comment (car faltoo-comments)))
       (should (equal (faltoo-comment-start comment) 2))
       (should (overlayp (faltoo-comment-overlay comment)))))))

(ert-deftest faltoo-file-comment-does-not-create-line-overlay ()
  "Scenario: File-level comments are pending but do not mark a line."
  (faltoo-test--with-temp-git-file
   '("one" "two")
   (lambda (_file _root)
     ;; Given no pending comments.
     (setq faltoo-comments nil)

     ;; When saving a file-level review comment.
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-file-comment)
        (with-current-buffer "*Faltoo Comment*"
          (goto-char (point-max))
          (insert "file-level concern")
          (faltoo-comment-save))))

     ;; Then the comment exists but has no line overlay.
     (should (= (length faltoo-comments) 1))
     (should (= (faltoo-comment-start (car faltoo-comments)) 0))
     (should-not (faltoo-comment-overlay (car faltoo-comments))))))

(ert-deftest faltoo-comment-empty-comment-does-not-capture-help-text ()
  "Scenario: Comment help text is not saved as a review comment."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given a comment popup is opened but no comment is typed.
     (setq faltoo-comments nil)

     ;; When saving the empty popup.
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-comment)
        (with-current-buffer "*Faltoo Comment*"
          (faltoo-comment-save))))

     ;; Then no pending review comment is created.
     (should-not faltoo-comments))))

(ert-deftest faltoo-comment-popup-places-cursor-in-editable-comment-area ()
  "Scenario: Comment popup starts with point in the editable area."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given the comment popup is opened.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-comment))

     ;; Then point is exactly where the comment should be typed.
     (with-current-buffer "*Faltoo Comment*"
       (should (= (point) faltoo-comment-text-marker))))))

(ert-deftest faltoo-submit-review-comments-sends-json-object-payload ()
  "Scenario: Review submission serializes a bridge-safe JSON payload."
  (let ((faltoo-comments
         (list (make-faltoo-comment :file "faltoo.el"
                                    :path "/repo/faltoo.el"
                                    :start 1
                                    :end 1
                                    :code "code"
                                    :text "review note")))
        captured-payload)
    ;; Given one pending review comment and a mocked request submitter.
    (cl-letf (((symbol-function 'faltoo-request-review)
               (lambda (comments _on-submitted &optional _on-done)
                 (setq captured-payload
                       (list (cons 'workspace "/repo")
                             (cons 'comments (vconcat comments))))
                 (json-serialize captured-payload))))

      ;; When submitting pending review comments.
      (faltoo-submit-review-comments))

    ;; Then comments are encoded as a JSON array of objects.
    (should (equal (alist-get 'filename (aref (alist-get 'comments captured-payload) 0))
                   "faltoo.el"))))

;;; Review mode specs

(ert-deftest faltoo-review-mode-makes-review-buffer-read-only ()
  "Scenario: Review mode makes source buffers read-only."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; When enabling review mode.
     (faltoo-review-mode 1)

     ;; Then the source buffer is a read-only review buffer.
     (should faltoo-review-mode)
     (should buffer-read-only))))

(ert-deftest faltoo-review-mode-shows-visible-review-header ()
  "Scenario: Review mode shows file index outside the modeline."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     ;; Given the current file is the only review file.
     (setq faltoo-review-files (list (file-truename file)))

     ;; When enabling review mode.
     (faltoo-review-mode 1)

     ;; Then a visible header line shows Faltoo[1/1].
     (should header-line-format)
     (should (string-match-p "Faltoo.*1/1" header-line-format)))))

(ert-deftest faltoo-review-mode-uses-full-line-diff-highlighting ()
  "Scenario: Review mode asks diff-hl for full-line highlights."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; When enabling review mode.
     (faltoo-review-mode 1)

     ;; Then diff-hl uses Faltoo's full-line highlighter, not gutter-only marks.
     (should (eq diff-hl-highlight-function #'faltoo-diff-hl-highlight-line)))))

(ert-deftest faltoo-review-stop-restores-review-buffer-writability ()
  "Scenario: Stopping review mode restores source buffer writability."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     ;; Given a file is under review.
     (setq faltoo-review-files (list (file-truename file)))
     (faltoo-review-mode 1)
     (should buffer-read-only)

     ;; When stopping the review session.
     (faltoo-review-stop)

     ;; Then the source buffer is writable again.
     (should-not faltoo-review-mode)
     (should-not buffer-read-only))))

;;; Quit guard specs

(ert-deftest faltoo-quit-guard-detects-pending-review-comments ()
  "Scenario: Quit guard treats pending comments as unsaved work."
  ;; Given a pending review comment.
  (let ((faltoo-submitting nil)
        (faltoo-comments (list (make-faltoo-comment :file "x" :path "x" :start 1 :end 1 :text "note"))))

    ;; Then Faltoo reports pending work before Emacs quits.
    (should (faltoo-has-pending-work-p))
    (should (equal (faltoo-pending-work-labels) '("1 pending review comment(s)")))))

;;; faltoo-behavior-test.el ends here

(ert-deftest faltoo-reload-review-buffers-refreshes-review-ui-state ()
  "Scenario: Reloading assistant-edited review buffers refreshes overlays and diff highlights."
  (let ((refreshed nil))
    ;; Given a review reload hook is registered.
    (add-hook 'faltoo-after-reload-review-buffers-hook
              (lambda () (setq refreshed t)))

    ;; When review buffers are reloaded after a request.
    (unwind-protect
        (progn
          (faltoo-reload-review-buffers)

          ;; Then review UI refresh hooks run once at the architecture boundary.
          (should refreshed))
      (setq faltoo-after-reload-review-buffers-hook nil))))
