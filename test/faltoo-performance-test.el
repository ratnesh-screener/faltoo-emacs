;;; faltoo-performance-test.el --- Performance behavior tests for faltoo -*- lexical-binding: t; -*-

(require 'ert)
(require 'benchmark)
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

(define-minor-mode diff-hl-mode "")
(defun diff-hl-update () nil)
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
  "Ask context from a large buffer current line stays interactive."
  (faltoo-perf--with-temp-git-file
   10000
   (lambda (_file _root)
     (goto-char (point-min))
     (forward-line 9000)
     (faltoo-perf--should-finish-under
      0.1
      (lambda ()
        (dotimes (_ 200)
          (faltoo-ask--context)))))))

(ert-deftest faltoo-performance-comment-refresh-for_many_comments_stays_interactive ()
  "Refreshing many pending comment overlays stays interactive."
  (faltoo-perf--with-temp-git-file
   2000
   (lambda (file _root)
     (setq faltoo-comments nil)
     (dotimes (index 300)
       (push (make-faltoo-comment :file "large.py"
                                  :path (file-truename file)
                                  :start (+ 1 (* index 3))
                                  :end (+ 1 (* index 3))
                                  :code "line"
                                  :text "comment")
             faltoo-comments))
     (faltoo-perf--should-finish-under
      0.25
      (lambda ()
        (faltoo-comments-refresh))))))

(ert-deftest faltoo-performance-rendering_large_transcript_stays_interactive ()
  "Rendering a large transcript stays interactive."
  (let ((messages nil))
    (dotimes (index 400)
      (push `((role . ,(if (cl-evenp index) "user" "assistant"))
              (text . ,(format "message %d\n%s" index (make-string 200 ?x))))
            messages))
    (faltoo-perf--should-finish-under
     0.35
     (lambda ()
       (faltoo-chat-render (nreverse messages))))
    (kill-buffer faltoo-chat-buffer-name)))

(ert-deftest faltoo-performance-routing_many_stream_chunks_stays_interactive ()
  "Routing many stream chunks to popup and transcript stays interactive."
  (let ((popup (get-buffer-create "*Faltoo Perf Popup*")))
    (unwind-protect
        (progn
          (with-current-buffer popup (erase-buffer))
          (faltoo-chat-start-stream "Assistant · streaming")
          (faltoo-perf--should-finish-under
           0.25
           (lambda ()
             (dotimes (_ 1000)
               (faltoo-request--route-event '((classes . "answer") (text . "x")) popup nil)))))
      (when (get-buffer popup) (kill-buffer popup))
      (when (get-buffer faltoo-chat-buffer-name) (kill-buffer faltoo-chat-buffer-name)))))

;;; faltoo-performance-test.el ends here
