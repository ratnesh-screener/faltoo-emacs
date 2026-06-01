;;; faltoo-behavior-test.el --- Behavior specs for faltoo -*- lexical-binding: t; -*-

(require 'ert)
(add-to-list 'load-path default-directory)

(define-derived-mode markdown-mode text-mode "Markdown")
(defface markdown-header-delimiter-face '((t)) "")
(defface markdown-header-face-1 '((t)) "")
(defface markdown-header-face-2 '((t)) "")
(defface markdown-header-face-3 '((t)) "")
(defface markdown-blockquote-face '((t)) "")
(provide 'markdown-mode)


;; Test doubles for required packages. The plugin requires these packages in real
;; use; tests stub only the small surface they exercise.
(defun posframe-show (&rest _args) nil)
(defun posframe-hide-all () nil)
(defun posframe-hide (&rest _args) nil)
(defun posframe-poshandler-frame-center (&rest _args) nil)
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

;;; Bridge specs

(ert-deftest faltoo-bridge-messages-passes-turn-limit-to-bridge ()
  "Scenario: Transcript history loading asks the bridge for recent user turns."
  (let ((faltoo-workspace "/tmp/faltoo-test") captured-args)
    ;; Given bridge JSON calls are observed.

    ;; When fetching the last 25 turns.
    (cl-letf (((symbol-function 'faltoo-bridge-call-json)
               (lambda (args &optional _input)
                 (setq captured-args args)
                 '((messages . nil)))))
      (faltoo-bridge-messages 25))

    ;; Then the bridge receives a turns argument.
    (should (member "--turns" captured-args))
    (should (member "25" captured-args))))

;;; Chat specs

(ert-deftest faltoo-chat-opens-editable-user-prompt ()
  "Scenario: Transcript opens with an editable user prompt."
  (let ((messages '(((role . "assistant") (text . "hello")))))
    ;; Given persisted Faltoo messages exist.

    ;; When rendering the transcript.
    (let ((buf (faltoo-chat-render messages)))

      ;; Then the buffer is editable and point starts in the user prompt.
      (with-current-buffer buf
        (should (derived-mode-p 'faltoo-chat-mode))
        (should-not buffer-read-only)
        (should (markerp faltoo-chat-prompt-marker))
        (should (= (point) faltoo-chat-prompt-marker))
        (should (string-match-p "# User" (buffer-string)))))))

(ert-deftest faltoo-chat-mode-uses-markdown-mode-for-transcript-styling ()
  "Scenario: Transcript uses Markdown mode styling."
  ;; Given the transcript buffer is rendered.
  (let ((buf (faltoo-chat-render nil)))

    ;; Then it derives from Markdown mode and uses Markdown headings.
    (with-current-buffer buf
      (should (derived-mode-p 'markdown-mode))
      (should (string-match-p "# User" (buffer-string))))))

(ert-deftest faltoo-chat-render-separates-message-blocks-with-blank-lines ()
  "Scenario: Transcript message blocks have breathing room between them."
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "question"))
                                   ((role . "assistant") (text . "answer"))))))
    ;; Given user and assistant messages are rendered.

    ;; Then there is an empty line between message blocks.
    (with-current-buffer buf
      (should (string-match-p "question\n\n---\n# Assistant" (buffer-string))))))

(ert-deftest faltoo-chat-render-separates-transcript-headings-with-horizontal-rules ()
  "Scenario: Transcript turns are visually separated like popups."
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "question"))
                                   ((role . "assistant") (text . "answer"))))))
    ;; Given multiple transcript turns are rendered.

    ;; Then later headings are preceded by Markdown horizontal rules.
    (with-current-buffer buf
      (should (string-match-p "---\n# Assistant" (buffer-string)))
      (should (string-match-p "---\n# User\n\n$" (buffer-string))))))

(ert-deftest faltoo-chat-render-highlights-user-heading-only ()
  "Scenario: User transcript headings are visually distinct without covering content."
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "question"))))))
    ;; Given a user message is rendered.

    ;; Then the heading has Faltoo's user face overlay, but the body does not.
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "User")
      (backward-char 1)
      (should (cl-some (lambda (overlay)
                         (eq (overlay-get overlay 'face) 'faltoo-chat-user-face))
                       (overlays-at (point))))
      (search-forward "question")
      (backward-char 1)
      (should-not (cl-some (lambda (overlay)
                             (eq (overlay-get overlay 'face) 'faltoo-chat-user-face))
                           (overlays-at (point)))))))

(ert-deftest faltoo-chat-render-keeps-user-highlights-inside-user-blocks ()
  "Scenario: User highlighting does not leak into the rest of the transcript."
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "question"))
                                   ((role . "assistant") (text . "answer"))))))
    ;; Given user and assistant messages are rendered.

    ;; Then assistant text is not covered by the user block face.
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "answer")
      (backward-char 1)
      (should-not (cl-some (lambda (overlay)
                             (eq (overlay-get overlay 'face) 'faltoo-chat-user-face))
                           (overlays-at (point)))))))

(ert-deftest faltoo-chat-render-highlights-assistant-heading-only ()
  "Scenario: Assistant transcript headings are visually distinct without covering content."
  (let ((buf (faltoo-chat-render '(((role . "assistant") (text . "answer"))))))
    ;; Given an assistant message is rendered.

    ;; Then the heading has Faltoo's assistant face overlay, but the body does not.
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "Assistant")
      (backward-char 1)
      (should (cl-some (lambda (overlay)
                         (eq (overlay-get overlay 'face) 'faltoo-chat-assistant-face))
                       (overlays-at (point))))
      (search-forward "answer")
      (backward-char 1)
      (should-not (cl-some (lambda (overlay)
                             (eq (overlay-get overlay 'face) 'faltoo-chat-assistant-face))
                           (overlays-at (point)))))))

(ert-deftest faltoo-markdown-modes-enable-pretty-rendering ()
  "Scenario: Transcript and popup buffers hide Markdown noise where possible."
  ;; Given a transcript and popup buffer are created.
  (let ((chat (faltoo-chat-render nil))
        (popup (faltoo-popup-buffer "*Faltoo Pretty Markdown Test*" #'faltoo-popup-mode)))

    ;; Then both use markdown-mode with local pretty-rendering settings enabled.
    (dolist (buf (list chat popup))
      (with-current-buffer buf
        (should (derived-mode-p 'markdown-mode))
        (should markdown-hide-markup)
        (should markdown-fontify-code-blocks-natively)
        (should markdown-fontify-whole-heading-line)
        (should markdown-header-scaling)))))

(ert-deftest faltoo-markdown-append-refreshes-fontification ()
  "Scenario: Newly streamed Markdown gets fontified for inline and fenced code."
  (let ((buf (faltoo-chat-render nil)) ensured)
    ;; Given Markdown fontification calls are observed.

    ;; When Markdown containing inline and fenced code is appended.
    (cl-letf (((symbol-function 'font-lock-ensure)
               (lambda (&optional start end)
                 (setq ensured (cons start end)))))
      (faltoo-popup-append buf "`inline`\n\n```elisp\n(message \"x\")\n```"))

    ;; Then the appended region is explicitly fontified.
    (should ensured)))

(ert-deftest faltoo-markdown-modes-remap-heading-and-quote-faces-without-resizing-text ()
  "Scenario: Pretty Markdown keeps heading sizes from fighting the user's theme."
  ;; Given a transcript buffer is rendered.
  (let ((buf (faltoo-chat-render nil)))

    ;; Then headings and blockquotes have local pretty Markdown face remaps,
    ;; while inline/fenced code and heading size keep the user's markdown-mode styling.
    (with-current-buffer buf
      (let ((heading-face (assoc 'markdown-header-face-1 face-remapping-alist)))
        (should heading-face)
        (should-not (plist-member (cdr heading-face) :height)))
      (should (assoc 'markdown-blockquote-face face-remapping-alist))
      (should-not (assoc 'markdown-code-face face-remapping-alist))
      (should-not (assoc 'markdown-pre-face face-remapping-alist)))))

(ert-deftest faltoo-chat-stream-preserves-reader-position ()
  "Scenario: Streaming transcript text does not drag the reader to the bottom."
  (when (get-buffer faltoo-chat-buffer-name)
    (kill-buffer faltoo-chat-buffer-name))
  ;; Given the reader is looking at the top of a visible transcript.
  (let ((buf (faltoo-chat-render '(((role . "assistant")
                                    (text . "old answer\nline 2\nline 3\nline 4"))))))
    (with-current-buffer buf
      (goto-char (point-min)))
    (let ((window (display-buffer buf)))
      (set-window-point window (point-min))
      (set-window-start window (point-min))

      ;; When new stream text is appended.
      (faltoo-chat-append-stream "new streamed text")

      ;; Then the reader's point and scroll position stay where they were.
      (should (= (window-point window) (point-min)))
      (should (= (window-start window) (point-min))))))

(ert-deftest faltoo-chat-render-shows-persisted-tool-summaries-without-headings ()
  "Scenario: Persisted tool summaries do not inflate the heading list."
  (let ((buf (faltoo-chat-render '(((role . "tool") (text . "Shell: inspect files"))))))
    ;; Given a persisted tool message is rendered.

    ;; Then it is a one-line summary, not its own Tool heading.
    (with-current-buffer buf
      (should (string-match-p "> Shell: inspect files" (buffer-string)))
      (should-not (string-match-p "\* Tool" (buffer-string)))
      (goto-char (point-min))
      (search-forward "inspect files")
      (backward-char 1)
      (should (cl-some (lambda (overlay)
                         (eq (overlay-get overlay 'face) 'faltoo-chat-tool-face))
                       (overlays-at (point)))))))

(ert-deftest faltoo-chat-refresh-loads-configured-number-of-turns ()
  "Scenario: Transcript refresh asks the bridge for the configured turn count."
  (let ((faltoo-chat-turns 12) captured-turns)
    ;; Given a transcript turn limit is configured.

    ;; When refreshing the transcript.
    (cl-letf (((symbol-function 'faltoo-bridge-messages)
               (lambda (&optional turns)
                 (setq captured-turns turns)
                 nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
      (faltoo-chat-refresh))

    ;; Then the bridge receives that turn count.
    (should (= captured-turns 12))))

(ert-deftest faltoo-chat-load-more-doubles-visible-turn-count ()
  "Scenario: Loading more transcript history expands the visible turn count."
  (let ((faltoo-chat-turns 10) captured-turns)
    ;; Given the transcript is showing a small recent window.

    ;; When loading more without a prefix.
    (cl-letf (((symbol-function 'faltoo-bridge-messages)
               (lambda (&optional turns)
                 (setq captured-turns turns)
                 nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
      (faltoo-chat-load-more nil))

    ;; Then the visible turn count doubles and refresh uses it.
    (should (= faltoo-chat-turns 20))
    (should (= captured-turns 20))))

(ert-deftest faltoo-chat-load-more-prefix-sets-visible-turn-count ()
  "Scenario: Loading more with a prefix chooses an exact turn count."
  (let ((faltoo-chat-turns 10) captured-turns)
    ;; Given the transcript is showing a small recent window.

    ;; When loading exactly 50 turns.
    (cl-letf (((symbol-function 'faltoo-bridge-messages)
               (lambda (&optional turns)
                 (setq captured-turns turns)
                 nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
      (faltoo-chat-load-more 50))

    ;; Then the exact prefix count is used.
    (should (= faltoo-chat-turns 50))
    (should (= captured-turns 50))))

(ert-deftest faltoo-chat-faces-are-theme-aware ()
  "Scenario: Transcript block faces inherit from theme faces."
  ;; Then Faltoo uses theme-provided primary, secondary, and comment faces.
  (should (eq (face-attribute 'faltoo-chat-user-face :inherit nil)
              'region))
  (should (eq (face-attribute 'faltoo-chat-assistant-face :inherit nil)
              'secondary-selection))
  (should (eq (face-attribute 'faltoo-chat-tool-face :inherit nil)
              'font-lock-comment-face)))

(ert-deftest faltoo-chat-send-submits-current-user-prompt ()
  "Scenario: Sending from transcript submits only the current prompt."
  (let (captured-text)
    ;; Given the transcript has history and a typed prompt.
    (with-current-buffer (faltoo-chat-render '(((role . "assistant") (text . "old answer"))))
      (insert "please continue")

      ;; When sending the prompt.
      (cl-letf (((symbol-function 'faltoo-request-message)
                 (lambda (text &optional _popup _on-done)
                   (setq captured-text text))))
        (faltoo-chat-send)))

    ;; Then only the current prompt is submitted, not transcript history.
    (should (equal captured-text "please continue"))))

(ert-deftest faltoo-chat-stream-highlights-assistant-heading-only ()
  "Scenario: Streaming assistant output keeps heading styling off the answer body."
  (when (get-buffer faltoo-chat-buffer-name)
    (kill-buffer faltoo-chat-buffer-name))
  ;; Given a streaming answer starts.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When answer text arrives.
  (faltoo-chat-append-stream "answer body with `code`")

  ;; Then the assistant face is on the heading, not the body.
  (with-current-buffer faltoo-chat-buffer-name
    (goto-char (point-min))
    (search-forward "Assistant")
    (backward-char 1)
    (should (cl-some (lambda (overlay)
                       (eq (overlay-get overlay 'face) 'faltoo-chat-assistant-face))
                     (overlays-at (point))))
    (search-forward "answer body")
    (backward-char 1)
    (should-not (cl-some (lambda (overlay)
                           (eq (overlay-get overlay 'face) 'faltoo-chat-assistant-face))
                         (overlays-at (point))))))

(ert-deftest faltoo-chat-finish-stream-appends-next-prompt-without-refreshing-history ()
  "Scenario: Completed streams stay in-place and add the next user turn."
  (when (get-buffer faltoo-chat-buffer-name)
    (kill-buffer faltoo-chat-buffer-name))
  ;; Given a stream is active in the transcript.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-chat-append-stream "streamed answer")

  ;; When the stream finishes.
  (cl-letf (((symbol-function 'faltoo-bridge-messages)
             (lambda (&rest _args)
               (error "Transcript should not refresh after streaming"))))
    (faltoo-chat-finish-stream))

  ;; Then the assistant heading is finalized and a fresh user prompt is appended.
  (with-current-buffer faltoo-chat-buffer-name
    (should (string-match-p "# Assistant\n\nstreamed answer\n\n---\n# User\n\n$" (buffer-string)))
    (should-not (string-match-p "Assistant · answering" (buffer-string)))
    (should (= (point) faltoo-chat-prompt-marker))))

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

(ert-deftest faltoo-ask-popup-separates-sections-with-horizontal-rules ()
  "Scenario: Ask popup sections are visually separated."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given the Ask popup is opened.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-ask))

     ;; Then major sections have Markdown horizontal rules between them.
     (with-current-buffer "*Faltoo Popup*"
       (should (string-match-p "---\n## Code\n\n" (buffer-string)))
       (should (string-match-p "---\n## Question\n\n" (buffer-string)))))))

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

(ert-deftest faltoo-ask-adds-editable-follow-up-after-response ()
  "Scenario: Ask popup becomes reusable after an assistant response finishes."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given an Ask popup has a typed question.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-ask))
     (with-current-buffer "*Faltoo Popup*"
       (insert "first question")

       ;; When the request completes successfully.
       (cl-letf (((symbol-function 'faltoo-request-message)
                  (lambda (_message _popup on-done)
                    (funcall on-done t))))
         (faltoo-ask-send))

       ;; Then a fresh follow-up prompt is ready for input.
       (should-not faltoo-ask-sent)
       (should (string-match-p "## Follow-up" (buffer-string)))
       (should (= (point) faltoo-ask-question-marker))))))

(ert-deftest faltoo-ask-follow-up-keeps-original-code-context ()
  "Scenario: Ask follow-ups reuse the original source context."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (let (captured-message)
       ;; Given a completed Ask popup has a follow-up prompt.
       (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
         (faltoo-ask))
       (with-current-buffer "*Faltoo Popup*"
         (insert "first question")
         (cl-letf (((symbol-function 'faltoo-request-message)
                    (lambda (_message _popup on-done)
                      (funcall on-done t))))
           (faltoo-ask-send))
         (insert "second question")

         ;; When sending the follow-up.
         (cl-letf (((symbol-function 'faltoo-request-message)
                    (lambda (message _popup _on-done)
                      (setq captured-message message))))
           (faltoo-ask-send)))

       ;; Then the second request still includes the same code context.
       (should (string-match-p "lines 1-1" captured-message))
       (should (string-match-p "```\none\n```" captured-message))
       (should (string-match-p "second question" captured-message))))))

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
                  (lambda (&optional _turns) '(((role . "assistant") (text . "hello from assistant")))))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))
         (faltoo-request-message "question" popup))

       ;; Then latest response, popup, and transcript all receive the answer.
       (should (equal faltoo-last-assistant-message "hello from assistant"))
       (with-current-buffer popup
         (should (string-match-p "hello from assistant" (buffer-string))))
       (with-current-buffer faltoo-chat-buffer-name
         (should (string-match-p "hello from assistant" (buffer-string))))
       (kill-buffer popup)))))

;;; Request specs

(ert-deftest faltoo-request-rejects-overlapping-streams ()
  "Scenario: Faltoo does not start a second request while one is running."
  (let ((faltoo-submitting t)
        (bridge-called nil))
    ;; Given a Faltoo request is already running.

    ;; When another message is submitted.
    (cl-letf (((symbol-function 'faltoo-bridge-stream)
               (lambda (&rest _args) (setq bridge-called t))))
      ;; Then the request is rejected before touching the bridge.
      (should-error (faltoo-request-message "second request") :type 'user-error)
      (should-not bridge-called))))

(ert-deftest faltoo-request-renders-status-events-as-compact-quotes ()
  "Scenario: Streaming status/tool blocks are compact Markdown quotes."
  (when (get-buffer faltoo-chat-buffer-name)
    (kill-buffer faltoo-chat-buffer-name))
  ;; Given a chat stream is active.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When status events are routed into the transcript.
  (faltoo-request--route-event '((classes . "status") (text . "first block")) nil nil)
  (faltoo-request--route-event '((classes . "tool") (text . "second block")) nil nil)

  ;; Then status/tool blocks are quoted without blank lines between them and have a tool face.
  (with-current-buffer faltoo-chat-buffer-name
    (should (string-match-p "> first block\n> second block\n" (buffer-string)))
    (should-not (string-match-p "> first block\n\n> second block" (buffer-string)))
    (goto-char (point-min))
    (search-forward "first block")
    (should (cl-some (lambda (overlay)
                       (eq (overlay-get overlay 'face) 'faltoo-chat-tool-face))
                     (overlays-at (point))))))

(ert-deftest faltoo-request-separates-tool-quotes-from-final-answer ()
  "Scenario: Final answer text starts after a blank line following compact tool calls."
  (when (get-buffer faltoo-chat-buffer-name)
    (kill-buffer faltoo-chat-buffer-name))
  ;; Given tool/status blocks are already in the streaming assistant section.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-request--route-event '((classes . "status") (text . "first block")) nil nil)
  (faltoo-request--route-event '((classes . "tool") (text . "second block")) nil nil)

  ;; When final answer text starts streaming.
  (faltoo-request--route-event '((classes . "answer") (text . "final answer")) nil nil)

  ;; Then the compact tool block is separated from the final answer body.
  (with-current-buffer faltoo-chat-buffer-name
    (should (string-match-p "> first block\n> second block\n\nfinal answer" (buffer-string)))))

(ert-deftest faltoo-request-renders-only-truncated-tool-summary ()
  "Scenario: Tool streams show FaltooChat-style summaries, not full command bodies."
  (when (get-buffer faltoo-chat-buffer-name)
    (kill-buffer faltoo-chat-buffer-name))
  ;; Given a tool event contains a shell summary and hidden command body.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When the event is routed into the transcript.
  (faltoo-request--route-event
   '((classes . "tool")
     (text . "**Shell:** inspect files\n\n<!-- shell-command -->\n\nsed -n '1,999p' giant-file.el"))
   nil nil)

  ;; Then only the truncated summary is shown.
  (with-current-buffer faltoo-chat-buffer-name
    (should (string-match-p "Shell: inspect files" (buffer-string)))
    (should-not (string-match-p "giant-file" (buffer-string)))))

;;; Reload specs

(ert-deftest faltoo-reload-loads-plugin-files-in-place ()
  "Scenario: Faltoo code can be reloaded without restarting Emacs."
  (let (loaded)
    ;; Given load-file is observed.
    (cl-letf (((symbol-function 'load-file)
               (lambda (file) (push (file-name-nondirectory file) loaded))))

      ;; When reloading Faltoo.
      (faltoo-reload))

    ;; Then core modules and the entrypoint are loaded in dependency order.
    (setq loaded (nreverse loaded))
    (should (equal (car loaded) "faltoo-core.el"))
    (should (member "faltoo-chat.el" loaded))
    (should (equal (car (last loaded)) "faltoo.el"))))

;;; Popup specs

(ert-deftest faltoo-popup-mode-uses-markdown-mode-for-popup-styling ()
  "Scenario: Faltoo posframes use Markdown mode styling."
  (with-current-buffer (faltoo-popup-buffer "*Faltoo Markdown Popup Test*" #'faltoo-popup-mode)
    ;; Then popups inherit the the user's Markdown styling.
    (should (derived-mode-p 'markdown-mode))))

(ert-deftest faltoo-all-popup-types-share-markdown-popup-base ()
  "Scenario: Ask, comment, and response popups share Markdown popup styling."
  ;; Given each popup type has a mode.
  (dolist (mode '(faltoo-popup-mode faltoo-ask-mode faltoo-comment-mode))

    ;; Then each one derives from the same Markdown popup base.
    (with-current-buffer (faltoo-popup-buffer (format "*Faltoo %s Test*" mode) mode)
      (should (derived-mode-p 'faltoo-popup-mode))
      (should (derived-mode-p 'markdown-mode)))))

(ert-deftest faltoo-popup-sections-are-compact-after-horizontal-rules ()
  "Scenario: Popup section separators do not waste vertical space."
  (with-temp-buffer
    ;; When a section is inserted.
    (faltoo-compose-insert-section "Question")

    ;; Then the rule, heading, and editable body are adjacent.
    (should (equal (buffer-string) "\n---\n## Question\n\n"))))

(ert-deftest faltoo-popup-section-body-starts-after-heading-boundary ()
  "Scenario: Typed popup text starts outside the heading line."
  (with-temp-buffer
    ;; When typing after a compact popup section.
    (faltoo-compose-insert-section "Follow-up")
    (insert "typed prompt")

    ;; Then the body is separated from the heading by one Markdown boundary line.
    (should (string-match-p "## Follow-up\n\ntyped prompt" (buffer-string)))))

(ert-deftest faltoo-last-response-popup-renders-markdown-content ()
  "Scenario: Last response popup uses Markdown headings and an editable follow-up."
  (let ((faltoo-last-assistant-message "answer body"))
    ;; Given a latest assistant response exists.

    ;; When opening it without displaying the real posframe.
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))

    ;; Then the popup uses Markdown mode and starts in the follow-up prompt.
    (with-current-buffer faltoo-last-response-buffer
      (should (derived-mode-p 'markdown-mode))
      (should (derived-mode-p 'faltoo-ask-mode))
      (should (string-match-p "# Last Assistant Response" (buffer-string)))
      (should (string-match-p "answer body" (buffer-string)))
      (should (string-match-p "## Follow-up" (buffer-string)))
      (should (= (point) faltoo-ask-question-marker)))))

(ert-deftest faltoo-last-response-popup-sends-plain-follow-up-question ()
  "Scenario: Last response follow-up sends only the typed question."
  (let ((faltoo-last-assistant-message "answer body") captured-message)
    ;; Given the last response popup is open with a typed follow-up.
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))
    (with-current-buffer faltoo-last-response-buffer
      (insert "please explain")

      ;; When sending from that popup.
      (cl-letf (((symbol-function 'faltoo-request-message)
                 (lambda (message _popup _on-done)
                   (setq captured-message message))))
        (faltoo-ask-send)))

    ;; Then no stale code context is added.
    (should (equal captured-message "please explain"))))

(ert-deftest faltoo-popup-mode-does-not-bind-q ()
  "Scenario: Popup text editing keeps q available for typing."
  ;; Given Faltoo popup keybindings are active.

  ;; Then q is not a close shortcut; it remains normal text input.
  (should-not (lookup-key faltoo-popup-mode-map (kbd "q"))))

(ert-deftest faltoo-popup-show-makes-cursor-visible-in-popup ()
  "Scenario: Faltoo popups show a visible cursor in the editable posframe."
  (let ((popup (faltoo-popup-buffer "*Faltoo Cursor Popup Test*" #'faltoo-popup-mode))
        captured-args)
    ;; Given posframe-show is observed instead of displaying a real child frame.
    (cl-letf (((symbol-function 'posframe-show)
               (lambda (&rest args)
                 (setq captured-args args)
                 (selected-frame)))
              ((symbol-function 'select-frame-set-input-focus) (lambda (&rest _args) nil)))

      ;; When showing a Faltoo popup.
      (faltoo-popup-show popup 80 20))

    ;; Then posframe is explicitly told to render the cursor at buffer point.
    (should (eq (plist-get (cdr captured-args) :cursor) 'box))
    (should (plist-get (cdr captured-args) :tty-non-selected-cursor))
    (with-current-buffer popup
      (should (eq (plist-get (cdr captured-args) :window-point) (point))))))

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

    ;; Then the posframe is focusable, bordered, and padded inside the box.
    (should (plist-get (cdr captured-args) :accept-focus))
    (should (> (plist-get (cdr captured-args) :border-width) 0))
    (should (plist-get (cdr captured-args) :border-color))
    (should (>= (plist-get (cdr captured-args) :internal-border-width) 16))
    (should (equal (plist-get (cdr captured-args) :internal-border-color)
                   (plist-get (cdr captured-args) :background-color)))
    (should (>= (plist-get (cdr captured-args) :left-fringe) 16))
    (should (>= (plist-get (cdr captured-args) :right-fringe) 16))
    (should (member '(left-fringe . 16)
                    (plist-get (cdr captured-args) :override-parameters)))
    (should (member '(right-fringe . 16)
                    (plist-get (cdr captured-args) :override-parameters)))))

(ert-deftest faltoo-popup-show-opens-centered-and-remembers-return-window ()
  "Scenario: Faltoo popups open centered and remember where focus came from."
  (let ((popup (get-buffer-create "*Faltoo Centered Popup Test*"))
        (source-window (selected-window))
        captured-args)
    ;; Given posframe-show is observed and window switching is suppressed.
    (cl-letf (((symbol-function 'posframe-show)
               (lambda (&rest args)
                 (setq captured-args args)
                 (selected-frame)))
              ((symbol-function 'select-frame-set-input-focus) (lambda (&rest _args) nil))
              ((symbol-function 'select-window) (lambda (&rest _args) nil))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _args) nil)))

      ;; When showing a Faltoo popup.
      (faltoo-popup-show popup 80 20))

    ;; Then it uses the frame-center poshandler and stores the source window.
    (should (eq (plist-get (cdr captured-args) :poshandler)
                #'posframe-poshandler-frame-center))
    (should-not (plist-member (cdr captured-args) :position))
    (with-current-buffer popup
      (should (eq faltoo-popup-return-window source-window)))))

(ert-deftest faltoo-popup-close-restores-previous-source-window ()
  "Scenario: Closing a popup returns focus to the buffer that opened it."
  (let ((source (get-buffer-create "*Faltoo Popup Source Test*"))
        (popup (get-buffer-create "*Faltoo Popup Close Test*")))
    ;; Given a source window opened a popup in another window.
    (delete-other-windows)
    (switch-to-buffer source)
    (let ((source-window (selected-window))
          (popup-window (split-window-right)))
      (with-current-buffer popup
        (setq faltoo-popup-return-window source-window))
      (select-window popup-window)
      (switch-to-buffer popup)

      ;; When closing the popup.
      (cl-letf (((symbol-function 'posframe-hide) (lambda (&rest _args) nil))
                ((symbol-function 'select-frame-set-input-focus) (lambda (&rest _args) nil)))
        (faltoo-popup-close))

      ;; Then focus returns to the original source buffer.
      (should (eq (selected-window) source-window))
      (should (eq (current-buffer) source)))
    (delete-other-windows)
    (kill-buffer source)
    (kill-buffer popup)))

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
       (should (overlayp (faltoo-comment-overlay comment)))
       (should-not (overlay-get (faltoo-comment-overlay comment) 'before-string))))))

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

(ert-deftest faltoo-comments-summary-renders-pending-comments ()
  "Scenario: Pending comments can be reviewed before submission."
  (let ((faltoo-comments
         (list (make-faltoo-comment :file "sample.py"
                                    :path "/repo/sample.py"
                                    :start 2
                                    :end 3
                                    :text "tighten this up"))))
    ;; Given there is a pending range comment.

    ;; When rendering the comments summary.
    (let ((buf (faltoo-comments-summary-render)))

      ;; Then the summary shows target, range, text, and actions.
      (with-current-buffer buf
        (should (string-match-p "sample.py:lines 2-3" (buffer-string)))
        (should (string-match-p "tighten this up" (buffer-string)))
        (should (string-match-p "RET jump" (buffer-string)))))))

(ert-deftest faltoo-comments-summary-jumps-to-comment-source ()
  "Scenario: Comments summary jumps back to the source line."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (file _root)
     ;; Given the summary is showing a pending comment on line 2.
     (let ((faltoo-comments
            (list (make-faltoo-comment :file "sample.py"
                                       :path (file-truename file)
                                       :start 2
                                       :end 2
                                       :text "check this"))))
       (with-current-buffer (faltoo-comments-summary-render)
         (search-forward "sample.py")

         ;; When jumping from the summary.
         (faltoo-comments-summary-jump))

       ;; Then the source file is selected at the comment line.
       (should (equal (file-truename buffer-file-name) (file-truename file)))
       (should (= (line-number-at-pos) 2))))))

(ert-deftest faltoo-delete-current-comment-removes-pending-comment-and-overlay ()
  "Scenario: Deleting the current pending comment clears its source marker."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (file _root)
     ;; Given line 2 has a pending comment marker.
     (let ((comment (make-faltoo-comment :file "sample.py"
                                         :path (file-truename file)
                                         :start 2
                                         :end 2
                                         :text "remove me")))
       (setq faltoo-comments (list comment))
       (faltoo-comments-refresh)
       (goto-char (point-min))
       (forward-line 1)
       (let ((overlay (faltoo-comment-overlay comment)))
         (should (overlayp overlay))

         ;; When deleting the current pending comment.
         (faltoo-delete-current-comment)

         ;; Then the comment and overlay are gone.
         (should-not faltoo-comments)
         (should-not (overlay-buffer overlay)))))))

(ert-deftest faltoo-comment-popup-separates-sections-with-horizontal-rules ()
  "Scenario: Comment popup sections are visually separated."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given the comment popup is opened.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-comment))

     ;; Then major sections have Markdown horizontal rules between them.
     (with-current-buffer "*Faltoo Comment*"
       (should (string-match-p "---\n## Code\n\n" (buffer-string)))
       (should (string-match-p "---\n## Comment\n\n" (buffer-string)))))))

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

(ert-deftest faltoo-diff-hl-highlight-line-removes-gutter-marker-and-extends-line ()
  "Scenario: Git change highlights are rendered as full source lines."
  (with-temp-buffer
    ;; Given diff-hl hands Faltoo a gutter-style overlay.
    (insert "changed line\nnext line\n")
    (let ((overlay (make-overlay (point-min) (point-min))))
      (overlay-put overlay 'before-string "gutter")

      ;; When Faltoo applies its diff highlighter.
      (faltoo-diff-hl-highlight-line overlay 'insert nil)

      ;; Then the gutter marker is removed and the whole line is highlighted.
      (should-not (overlay-get overlay 'before-string))
      (should (= (overlay-start overlay) (point-min)))
      (should (= (overlay-end overlay) (save-excursion (goto-char (point-min)) (line-beginning-position 2))))
      (should (eq (overlay-get overlay 'face) 'faltoo-diff-insert-line-face)))))

(ert-deftest faltoo-review-mode-refreshes-diff-hl-after-installing-full-line-highlighter ()
  "Scenario: Entering review mode redraws existing gutter highlights as full lines."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (let (removed updated)
       ;; Given diff-hl may already have gutter overlays from global diff-hl-mode.
       (cl-letf (((symbol-function 'diff-hl-remove-overlays)
                  (lambda (&rest _args) (setq removed t)))
                 ((symbol-function 'diff-hl-update)
                  (lambda () (setq updated t))))

         ;; When enabling review mode.
         (faltoo-review-mode 1))

       ;; Then Faltoo redraws diff-hl after installing its full-line highlighter.
       (should (eq diff-hl-highlight-function #'faltoo-diff-hl-highlight-line))
       (should removed)
       (should updated)))))

(ert-deftest faltoo-review-mode-keybindings-keep-comment-management-on-prefix ()
  "Scenario: Review buffers keep comment management on the Faltoo prefix."
  ;; Given review-mode keybindings are active.

  ;; Then C-c f d deletes a pending comment and C-c f m shows pending comments.
  (should (eq (lookup-key faltoo-review-mode-map (kbd "C-c f d"))
              #'faltoo-delete-current-comment))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "C-c f m"))
              #'faltoo-comments-summary)))

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
