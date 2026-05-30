;;; faltoo-performance-test.el --- Performance behavior specs for faltoo -*- lexical-binding: t; -*-

(require 'ert)
(require 'benchmark)
(add-to-list 'load-path default-directory)

;; Test doubles for required packages.
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
(defun diff-hl-remove-overlays (&rest _args) nil)
(defun diff-hl-stage-current-hunk () nil)
(defun diff-hl-revert-hunk () nil)
(defun diff-hl-next-hunk () nil)
(defun diff-hl-previous-hunk () nil)
(defun diff-hl-show-hunk () nil)
(provide 'diff-hl)

(require 'faltoo)

(defun faltoo-perf--elapsed (body)
  (let ((result (benchmark-run 1 (funcall body))))
    (car result)))

(defun faltoo-perf--should-finish-under (seconds body)
  (let ((elapsed (faltoo-perf--elapsed body)))
    (should (< elapsed seconds))))

(defun faltoo-perf--with-temp-git-file (line-count body)
  "Create a large temporary Git-backed file, then call BODY."
  (let* ((root (file-name-as-directory (make-temp-file "faltoo-perf" t)))
         (default-directory root)
         (file (expand-file-name "large.py" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file file
            (dotimes (index line-count)
              (insert (format "line_%05d = %d\n" index index))))
          (find-file file)
          (setq faltoo-workspace root)
          (funcall body file root))
      (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
      (delete-directory root t))))

(ert-deftest faltoo-performance-ask-context-from-large-current-line-is-instant ()
  "Scenario: Ask context extraction stays fast in large source buffers."
  (faltoo-perf--with-temp-git-file
   10000
   (lambda (_file _root)
     ;; Given point is near the end of a large source file.
     (goto-char (point-min))
     (forward-line 9000)

     ;; When Ask context is extracted repeatedly.
     ;; Then it remains comfortably interactive.
     (faltoo-perf--should-finish-under
      0.1
      (lambda ()
        (dotimes (_ 200)
          (faltoo-ask--context)))))))

(ert-deftest faltoo-performance-comment-refresh-for-many-comments-stays-interactive ()
  "Scenario: Refreshing many pending comment overlays stays interactive."
  (faltoo-perf--with-temp-git-file
   2000
   (lambda (file _root)
     ;; Given many pending line comments in one review buffer.
     (setq faltoo-comments nil)
     (dotimes (index 300)
       (push (make-faltoo-comment :file "large.py"
                                  :path (file-truename file)
                                  :start (+ 1 (* index 3))
                                  :end (+ 1 (* index 3))
                                  :code "line"
                                  :text "comment")
             faltoo-comments))

     ;; When overlays are refreshed.
     ;; Then the operation remains interactive.
     (faltoo-perf--should-finish-under
      0.25
      (lambda ()
        (faltoo-comments-refresh))))))

(ert-deftest faltoo-performance-rendering-large-transcript-stays-interactive ()
  "Scenario: Rendering a large transcript stays interactive."
  ;; Given a long transcript.
  (let ((messages nil))
    (dotimes (index 400)
      (push `((role . ,(if (cl-evenp index) "user" "assistant"))
              (text . ,(format "message %d\n%s" index (make-string 200 ?x))))
            messages))

    ;; When rendering the transcript.
    ;; Then it remains fast enough to use as background history.
    (faltoo-perf--should-finish-under
     0.35
     (lambda ()
       (faltoo-chat-render (nreverse messages))))
    (kill-buffer faltoo-chat-buffer-name)))

(ert-deftest faltoo-performance-routing-many-stream-chunks-stays-interactive ()
  "Scenario: Routing many stream chunks to popup and transcript stays interactive."
  (let ((popup (get-buffer-create "*Faltoo Perf Popup*")))
    (unwind-protect
        (progn
          ;; Given an active popup and transcript stream.
          (with-current-buffer popup (erase-buffer))
          (faltoo-chat-start-stream "Assistant · streaming")

          ;; When many answer chunks arrive.
          ;; Then routing remains interactive.
          (faltoo-perf--should-finish-under
           0.25
           (lambda ()
             (dotimes (_ 1000)
               (faltoo-request--route-event '((classes . "answer") (text . "x")) popup nil)))))
      (when (get-buffer popup) (kill-buffer popup))
      (when (get-buffer faltoo-chat-buffer-name) (kill-buffer faltoo-chat-buffer-name)))))

;;; faltoo-performance-test.el ends here
