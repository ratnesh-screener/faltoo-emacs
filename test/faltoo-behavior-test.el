;;; faltoo-behavior-test.el --- Behavior tests for faltoo -*- lexical-binding: t; -*-

(require 'ert)
(add-to-list 'load-path default-directory)

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

(ert-deftest faltoo-ask-uses-current-line-when-region-is-not-active ()
  "Given point on a line, Ask context is that line only."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     (goto-char (point-min))
     (forward-line 1)
     (let ((context (faltoo-ask--context)))
       (should (equal (plist-get context :start) 2))
       (should (equal (plist-get context :end) 2))
       (should (equal (plist-get context :code) "two"))))))

(ert-deftest faltoo-ask-uses-active-region-when-present ()
  "Given an active region, Ask context is the selected code block."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     (goto-char (point-min))
     (set-mark (point))
     (forward-line 2)
     (activate-mark)
     (let ((context (faltoo-ask--context)))
       (should (equal (plist-get context :start) 1))
       (should (equal (plist-get context :end) 3))
       (should (equal (plist-get context :code) "one\ntwo\n"))))))

(ert-deftest faltoo-comment-save-marks-line-as-pending-review-comment ()
  "Saving a line comment creates one pending comment and marks the source line."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     (setq faltoo-comments nil)
     (goto-char (point-min))
     (forward-line 1)
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil))
               ((symbol-function 'faltoo-popup-close) (lambda () nil)))
       (faltoo-comment)
       (with-current-buffer "*Faltoo Comment*"
         (goto-char (point-max))
         (insert "please review this")
         (faltoo-comment-save)))
     (should (= (length faltoo-comments) 1))
     (let ((comment (car faltoo-comments)))
       (should (equal (faltoo-comment-start comment) 2))
       (should (overlayp (faltoo-comment-overlay comment)))))))

(ert-deftest faltoo-review-mode-makes-review-buffer-read-only ()
  "Enabling review mode makes the source buffer read-only and enables diff-hl."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-review-mode 1)
     (should faltoo-review-mode)
     (should buffer-read-only))))

;;; faltoo-behavior-test.el ends here

(ert-deftest faltoo-file-comment-does-not-create-line-overlay ()
  "File-level comments are pending review comments without line overlays."
  (faltoo-test--with-temp-git-file
   '("one" "two")
   (lambda (_file _root)
     (setq faltoo-comments nil)
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil))
               ((symbol-function 'faltoo-popup-close) (lambda () nil)))
       (faltoo-file-comment)
       (with-current-buffer "*Faltoo Comment*"
         (goto-char (point-max))
         (insert "file-level concern")
         (faltoo-comment-save)))
     (should (= (length faltoo-comments) 1))
     (should (= (faltoo-comment-start (car faltoo-comments)) 0))
     (should-not (faltoo-comment-overlay (car faltoo-comments))))))

(ert-deftest faltoo-ask-stream-routes-answer-to-popup-and-transcript ()
  "Ask responses stream near code and into the background transcript."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (setq faltoo-review-files nil
           faltoo-last-assistant-message "")
     (when (get-buffer faltoo-chat-buffer-name) (kill-buffer faltoo-chat-buffer-name))
     (let ((popup (get-buffer-create "*Faltoo Test Popup*")))
       (with-current-buffer popup (erase-buffer))
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
       (should (equal faltoo-last-assistant-message "hello from assistant"))
       (with-current-buffer popup
         (should (string-match-p "hello from assistant" (buffer-string))))
       (with-current-buffer faltoo-chat-buffer-name
         (should (string-match-p "hello from assistant" (buffer-string))))
       (kill-buffer popup)))))

(ert-deftest faltoo-review-stop-restores-review-buffer-writability ()
  "Stopping review mode restores the reviewed source buffer's read-only state."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     (setq faltoo-review-files (list (file-truename file)))
     (faltoo-review-mode 1)
     (should buffer-read-only)
     (faltoo-review-stop)
     (should-not faltoo-review-mode)
     (should-not buffer-read-only))))

(ert-deftest faltoo-quit-guard-detects-pending-review-comments ()
  "Quit guard sees pending review comments as work that should not be lost."
  (let ((faltoo-submitting nil)
        (faltoo-comments (list (make-faltoo-comment :file "x" :path "x" :start 1 :end 1 :text "note"))))
    (should (faltoo-has-pending-work-p))
    (should (equal (faltoo-pending-work-labels) '("1 pending review comment(s)")))))

(ert-deftest faltoo-popup-show-creates-focusable-bordered-posframe ()
  "Faltoo input popups are focusable and have a visible border."
  (let (captured-args)
    (cl-letf (((symbol-function 'posframe-show)
               (lambda (&rest args)
                 (setq captured-args args)
                 (selected-frame)))
              ((symbol-function 'select-frame-set-input-focus) (lambda (&rest _args) nil)))
      (faltoo-popup-show (get-buffer-create "*Faltoo Popup Test*") 80 20))
    (should (plist-get (cdr captured-args) :accept-focus))
    (should (> (plist-get (cdr captured-args) :border-width) 0))
    (should (plist-get (cdr captured-args) :border-color))))

(ert-deftest faltoo-review-mode-shows-visible-review-header ()
  "Review buffers show a visible Faltoo file index even when modeline hides minor modes."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     (setq faltoo-review-files (list (file-truename file)))
     (faltoo-review-mode 1)
     (should header-line-format)
     (should (string-match-p "Faltoo.*1/1" header-line-format)))))

(ert-deftest faltoo-review-mode-uses-full-line-diff-highlighting ()
  "Review buffers ask diff-hl to highlight full changed lines, not only the gutter."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-review-mode 1)
     (should (eq diff-hl-highlight-function #'faltoo-diff-hl-highlight-line)))))

(ert-deftest faltoo-ask-empty-question-does-not-capture-help-text ()
  "Ask popup help text is not part of the editable question payload."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-ask))
     (with-current-buffer "*Faltoo Popup*"
       (should (string-empty-p (faltoo-ask--question-text)))))))

(ert-deftest faltoo-comment-empty-comment-does-not-capture-help-text ()
  "Comment popup help text is not saved as a review comment."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (setq faltoo-comments nil)
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil))
               ((symbol-function 'faltoo-popup-close) (lambda () nil)))
       (faltoo-comment)
       (with-current-buffer "*Faltoo Comment*"
         (faltoo-comment-save)))
     (should-not faltoo-comments))))
