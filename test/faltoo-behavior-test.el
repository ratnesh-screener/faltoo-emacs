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

(defun faltoo-test--chat-buffer-name ()
  "Return the current workspace transcript buffer name."
  (faltoo-chat-buffer-name-for (faltoo-workspace)))

(defun faltoo-test--kill-chat-buffer ()
  "Kill the current workspace transcript buffer when it exists."
  (let ((name (faltoo-test--chat-buffer-name)))
    (when (get-buffer name)
      (kill-buffer name))))


(defun faltoo-test--tree-row-cells (index item)
  "Return rendered tree row cells for INDEX and ITEM."
  (let ((row (faltoo-tree--row-text index item)))
    (vconcat
     (mapcar (lambda (range)
               (string-trim-right (substring row (car range) (min (cdr range) (length row)))))
             (if faltoo-tree-token-view
                 '((0 . 9) (11 . 24) (26 . 36) (38 . 47) (49 . 59) (61 . 71) (73 . 1000))
               '((0 . 9) (11 . 24) (26 . 1000)))))))

(defun faltoo-test--kill-last-response-buffer (&optional workspace)
  "Kill the last-response popup buffer for WORKSPACE when it exists."
  (let ((buf (get-buffer (faltoo-last-response-buffer-name (or workspace (faltoo-workspace))))))
    (when buf (kill-buffer buf))))

(defun faltoo-test--with-two-temp-git-files (body)
  "Create two temporary Git-backed files, then call BODY with file/root pairs."
  (let* ((root-a (file-name-as-directory (make-temp-file "faltoo-root-a" t)))
         (root-b (file-name-as-directory (make-temp-file "faltoo-root-b" t)))
         (file-a (expand-file-name "a.py" root-a))
         (file-b (expand-file-name "b.py" root-b)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root-a))
          (make-directory (expand-file-name ".git" root-b))
          (write-region "a = 1
" nil file-a nil 'silent)
          (write-region "b = 1
" nil file-b nil 'silent)
          (funcall body file-a root-a file-b root-b))
      (when (get-file-buffer file-a) (kill-buffer (get-file-buffer file-a)))
      (when (get-file-buffer file-b) (kill-buffer (get-file-buffer file-b)))
      (let ((buf-a (get-buffer (faltoo-chat-buffer-name-for root-a)))
            (buf-b (get-buffer (faltoo-chat-buffer-name-for root-b))))
        (when buf-a (kill-buffer buf-a))
        (when buf-b (kill-buffer buf-b)))
      (delete-directory root-a t)
      (delete-directory root-b t))))

;;; Workspace specs

(ert-deftest faltoo-workspace-follows-current-buffer-git-root ()
  "Scenario: Opening files from different repos switches the active Faltoo workspace."
  (faltoo-test--with-two-temp-git-files
   (lambda (file-a root-a file-b root-b)
     ;; Given two files from different Git repositories are open.
     (let ((buf-a (find-file-noselect file-a))
           (buf-b (find-file-noselect file-b)))

       ;; When each buffer asks for its Faltoo workspace.
       ;; Then the workspace follows that buffer's Git root.
       (with-current-buffer buf-a
         (should (equal (faltoo-workspace) (file-truename root-a))))
       (with-current-buffer buf-b
         (should (equal (faltoo-workspace) (file-truename root-b))))))))


(ert-deftest faltoo-workspace-falls-back-to-current-folder-outside-git ()
  "Scenario: Faltoo chat sessions can start from non-Git folders."
  (let ((root (file-name-as-directory (make-temp-file "faltoo-non-git" t))))
    (unwind-protect
        (let ((default-directory root)
              (faltoo-last-non-git-workspace-message nil)
              messages)
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages))))
            ;; When resolving a workspace outside Git.
            ;; Then Faltoo uses the current folder and informs the user once.
            (should (equal (faltoo-workspace) (file-truename root)))
            (should (equal (car messages)
                           "Faltoo: no Git repository found; using current folder"))
            (faltoo-workspace)
            (should (= (length messages) 1))))
      (delete-directory root t))))

(ert-deftest faltoo-chat-targets-current-folder-outside-git ()
  "Scenario: Repo transcript opens from a non-Git folder using that folder as workspace."
  (let ((root (file-name-as-directory (make-temp-file "faltoo-non-git-chat" t)))
        captured-workspace)
    (unwind-protect
        (let ((default-directory root)
              (faltoo-last-non-git-workspace-message nil))
          (cl-letf (((symbol-function 'faltoo-bridge-messages)
                     (lambda (_turns workspace)
                       (setq captured-workspace workspace)
                       nil))
                    ((symbol-function 'pop-to-buffer) (lambda (buf &rest _args) buf))
                    ((symbol-function 'message) (lambda (&rest _args) nil)))
            ;; When the repo transcript is opened outside Git.
            (faltoo-chat)

            ;; Then the bridge receives the current folder as the workspace.
            (should (equal captured-workspace (file-name-as-directory (file-truename root))))))
      (when (get-buffer (faltoo-chat-buffer-name-for root))
        (kill-buffer (faltoo-chat-buffer-name-for root)))
      (delete-directory root t))))

(ert-deftest faltoo-generic-chat-opens-repo-independent-transcript ()
  "Scenario: Generic chat uses a fixed non-Git workspace instead of the current repo."
  (let* ((root (file-name-as-directory (make-temp-file "faltoo-generic" t)))
         (workspace (expand-file-name "quick-chat/" root))
         (faltoo-generic-chat-directory workspace)
         captured-workspace)
    (unwind-protect
        (progn
          ;; Given the generic workspace has no Git metadata.
          (cl-letf (((symbol-function 'faltoo-bridge-messages)
                     (lambda (_turns workspace)
                       (setq captured-workspace workspace)
                       nil))
                    ((symbol-function 'pop-to-buffer) (lambda (buf &rest _args) buf)))

            ;; When generic chat opens.
            (faltoo-generic-chat))

          ;; Then it creates and renders the repo-independent transcript.
          (should (file-directory-p workspace))
          (should (equal captured-workspace (file-name-as-directory (file-truename workspace))))
          (should (get-buffer "*Faltoo Chat*"))
          (with-current-buffer "*Faltoo Chat*"
            (should (equal default-directory (file-name-as-directory (file-truename workspace))))
            (should (equal faltoo-chat-workspace (file-name-as-directory (file-truename workspace))))))
      (when (get-buffer "*Faltoo Chat*")
        (kill-buffer "*Faltoo Chat*"))
      (delete-directory root t))))

(ert-deftest faltoo-generic-chat-send-targets-generic-workspace ()
  "Scenario: Sending from generic chat routes the request to the generic workspace."
  (let* ((root (file-name-as-directory (make-temp-file "faltoo-generic" t)))
         (workspace (expand-file-name "quick-chat/" root))
         (faltoo-generic-chat-directory workspace)
         captured)
    (unwind-protect
        (progn
          ;; Given the generic chat prompt has a quick question.
          (cl-letf (((symbol-function 'faltoo-bridge-messages) (lambda (&rest _args) nil))
                    ((symbol-function 'pop-to-buffer) (lambda (buf &rest _args) buf)))
            (faltoo-generic-chat))
          (with-current-buffer "*Faltoo Chat*"
            (insert "quick question")

            ;; When the prompt is submitted.
            (cl-letf (((symbol-function 'faltoo-request-message)
                       (lambda (text popup on-done skip-transcript-user workspace)
                         (setq captured (list text popup on-done skip-transcript-user workspace)))))
              (faltoo-chat-send)))

          ;; Then the request bypasses Git-root lookup and uses the generic workspace.
          (should (equal (nth 0 captured) "quick question"))
          (should (eq (nth 3 captured) t))
          (should (equal (nth 4 captured) (file-name-as-directory (file-truename workspace)))))
      (when (get-buffer "*Faltoo Chat*")
        (kill-buffer "*Faltoo Chat*"))
      (delete-directory root t))))


(ert-deftest faltoo-chat-buffer-exposes-workspace-path-to-buffer-annotations ()
  "Scenario: Buffer completion annotations can show transcript workspace paths."
  (let ((workspace (file-name-as-directory (make-temp-file "faltoo-annotated-workspace" t))))
    (unwind-protect
        (let ((buf (faltoo-chat-buffer workspace)))
          ;; When a transcript buffer is created.
          ;; Then it exposes the workspace through Emacs' standard buffer directory metadata.
          (with-current-buffer buf
            (should (equal list-buffers-directory (file-name-as-directory (file-truename workspace))))))
      (when (get-buffer (faltoo-chat-buffer-name-for workspace))
        (kill-buffer (faltoo-chat-buffer-name-for workspace)))
      (delete-directory workspace t))))

(ert-deftest faltoo-chat-uses-separate-transcripts-per-workspace ()
  "Scenario: Each Git repo gets its own transcript buffer and default directory."
  (faltoo-test--with-two-temp-git-files
   (lambda (_file-a root-a _file-b root-b)
     ;; Given two workspaces render transcripts.
     (let ((chat-a (faltoo-chat-render '(((role . "assistant") (text . "from a"))) root-a))
           (chat-b (faltoo-chat-render '(((role . "assistant") (text . "from b"))) root-b)))

       ;; Then each transcript is separate and bound to its workspace root.
       (should-not (eq chat-a chat-b))
       (with-current-buffer chat-a
         (should (equal default-directory (file-name-as-directory (file-truename root-a))))
         (should (string-match-p "from a" (buffer-string))))
       (with-current-buffer chat-b
         (should (equal default-directory (file-name-as-directory (file-truename root-b))))
         (should (string-match-p "from b" (buffer-string))))))))

(ert-deftest faltoo-status-shows-answering-only-for-current-workspace ()
  "Scenario: Mode-line answering status follows the current repo session."
  (faltoo-test--with-two-temp-git-files
   (lambda (file-a root-a file-b _root-b)
     (let ((faltoo-submitting nil)
           (faltoo-submitting-workspaces (make-hash-table :test #'equal)))
       ;; Given repo A has a running request and repo B does not.
       (faltoo-set-workspace-submitting (file-truename root-a) t)

       ;; Then repo A shows answering, but repo B is not blocked/status-marked.
       (with-current-buffer (find-file-noselect file-a)
         (should (string-match-p "answering" (faltoo-status-string))))
       (with-current-buffer (find-file-noselect file-b)
         (should-not (string-match-p "answering" (faltoo-status-string))))))))

(ert-deftest faltoo-status-label-shows-beta-for-local-core ()
  "Scenario: Mode-line label changes when the current chat uses local Faltoo core."
  (faltoo-test--with-two-temp-git-files
   (lambda (file-a root-a file-b root-b)
     (let ((faltoo-submitting nil)
           (faltoo-submitting-workspaces (make-hash-table :test #'equal))
           (faltoo-faltoobot-command "faltoobot")
           (faltoo-local-faltoobot-command "/tmp/local-faltoochat")
           (faltoo-faltoobot-workspace-commands (make-hash-table :test #'equal)))
       ;; Given repo A is answering with the local core and repo B uses release.
       (puthash (file-name-as-directory (file-truename root-a))
                "/tmp/local-faltoochat"
                faltoo-faltoobot-workspace-commands)
       (faltoo-set-workspace-submitting (file-truename root-a) t)
       (faltoo-set-workspace-submitting (file-truename root-b) t)

       ;; Then only the local-core workspace advertises Faltoo-beta.
       (with-current-buffer (find-file-noselect file-a)
         (should (string-match-p "Faltoo-beta:answering" (faltoo-status-string))))
       (with-current-buffer (find-file-noselect file-b)
         (should (string-match-p "Faltoo:answering" (faltoo-status-string)))
         (should-not (string-match-p "Faltoo-beta" (faltoo-status-string))))))))

(ert-deftest faltoo-request-message-targets-current-buffer-workspace ()
  "Scenario: Sending from a source buffer targets that file's Git repo session."
  (faltoo-test--with-two-temp-git-files
   (lambda (_file-a _root-a file-b root-b)
     ;; Given point is in a source buffer from the second repository.
     (let ((buf-b (find-file-noselect file-b)) captured-payload)

       ;; When sending a message from that buffer.
       (with-current-buffer buf-b
         (cl-letf (((symbol-function 'faltoo-bridge-stream)
                    (lambda (_args payload _on-event on-done)
                      (setq captured-payload payload)
                      (funcall on-done t))))
           (let ((faltoo-submitting nil))
             (faltoo-request-message "hello from repo b"))))

       ;; Then FaltooBot receives the second repo as workspace.
       (should (equal (alist-get 'workspace captured-payload)
                      (file-truename root-b)))))))

(ert-deftest faltoo-request-completion-records-elapsed-time-in-transcript-footer ()
  "Scenario: Request completion records assistant duration in the transcript footer."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-test--kill-chat-buffer)
     (let ((times '(10.0 30.0))
           (faltoo-request-start-times (make-hash-table :test #'equal)))
       ;; Given request timing is deterministic.
       (cl-letf (((symbol-function 'float-time)
                  (lambda () (or (pop times) 30.0)))
                 ((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args _payload on-event on-done)
                    (funcall on-event '((classes . "answer") (text . "timed answer")))
                    (funcall on-done t)))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))

         ;; When the request completes.
         (faltoo-request-message "time this"))

       ;; Then status stays compact and transcript shows the elapsed time footer.
       (should (equal faltoo-status "Faltoo complete"))
       (with-current-buffer (faltoo-test--chat-buffer-name)
         (should (string-match-p "timed answer\n\n> Assistant took: 20.0s\n\n---\n# User" (buffer-string))))))))

(ert-deftest faltoo-request-completion-records-codex-limit-in-transcript-footer ()
  "Scenario: Codex rate-limit events are shown in the assistant footer."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-test--kill-chat-buffer)
     (let ((times '(10.0 30.0))
           (faltoo-request-start-times (make-hash-table :test #'equal))
           (faltoo-request-rate-limits (make-hash-table :test #'equal))
           (faltoo-last-rate-limits (make-hash-table :test #'equal)))
       ;; Given the bridge emits the Codex remaining limit during streaming.
       (cl-letf (((symbol-function 'float-time)
                  (lambda () (or (pop times) 30.0)))
                 ((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args _payload on-event on-done)
                    (funcall on-event '((classes . "rate-limit") (text . "Remaining limit: 5h = 98%")))
                    (funcall on-event '((classes . "answer") (text . "limited answer")))
                    (funcall on-done t)))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))

         ;; When the request completes.
         (faltoo-request-message "show limit"))

       ;; Then the limit is remembered and appears with the assistant footer, not as an earlier tool quote.
       (should (equal (gethash (faltoo-workspace) faltoo-last-rate-limits)
                      "Remaining limit: 5h = 98%"))
       (with-current-buffer (faltoo-test--chat-buffer-name)
         (should (string-match-p "limited answer\n\n> Assistant took: 20.0s\n> Remaining limit: 5h = 98%\n\n---\n# User" (buffer-string)))
         (should-not (string-match-p "> Remaining limit: 5h = 98%\n\nlimited answer" (buffer-string))))))))

(ert-deftest faltoo-chat-send-targets-transcript-workspace ()
  "Scenario: Sending from a repo transcript keeps using that transcript's Git root."
  (faltoo-test--with-two-temp-git-files
   (lambda (_file-a _root-a _file-b root-b)
     ;; Given a transcript exists for the second repository.
     (let ((chat-b (faltoo-chat-render nil root-b)) captured-workspace)
       (with-current-buffer chat-b
         (insert "continue here")

         ;; When sending from inside that transcript.
         (cl-letf (((symbol-function 'faltoo-request-message)
                    (lambda (_text &optional _popup _on-done _skip-transcript-user workspace)
                      (setq captured-workspace workspace))))
           (faltoo-chat-send)))

       ;; Then the transcript's workspace is used, not some other current buffer.
       (should (equal captured-workspace (file-name-as-directory (file-truename root-b))))))))

;;; Bridge specs

(ert-deftest faltoo-bridge-python-uses-workspace-faltoobot-command ()
  "Scenario: Bridge Python is resolved from the selected workspace command."
  (let ((shim (make-temp-file "faltoo-command"))
        (faltoo-faltoobot-workspace-commands (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          ;; Given one workspace uses a custom Faltoo command shim.
          (write-region "#!/custom/python\n" nil shim nil 'silent)
          (set-file-modes shim #o755)
          (puthash "/repo-a/" shim faltoo-faltoobot-workspace-commands)

          ;; When resolving the bridge Python for that workspace.
          ;; Then the shim's shebang Python is used.
          (should (equal (faltoo-bridge-python "/repo-a/") "/custom/python")))
      (delete-file shim))))

(ert-deftest faltoo-select-faltoobot-command-switches-current-chat-only ()
  "Scenario: Switching Faltoo core is scoped to the current chat workspace."
  (let ((faltoo-release-faltoobot-command "faltoobot")
        (faltoo-local-faltoobot-command "/tmp/local-faltoochat")
        (faltoo-faltoobot-command "faltoobot")
        (faltoo-faltoobot-workspace-commands (make-hash-table :test #'equal))
        validated-command)
    ;; Given local core is selected in one workspace.
    (cl-letf (((symbol-function 'faltoo-active-workspace) (lambda () "/repo-a/"))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _args) (cadr choices)))
              ((symbol-function 'faltoo-bridge--command-executable)
               (lambda (command) (setq validated-command command))))

      ;; When switching Faltoo core.
      (faltoo-select-faltoobot-command))

    ;; Then only that workspace uses the local command.
    (should (equal (gethash "/repo-a/" faltoo-faltoobot-workspace-commands)
                   "/tmp/local-faltoochat"))
    (should (equal (faltoo-bridge-command-for-workspace "/repo-b/") "faltoobot"))
    (should (equal validated-command "/tmp/local-faltoochat"))))


(ert-deftest faltoo-bridge-stream-uses-persistent-daemon-for-websocket-append ()
  "Scenario: Websocket append requests go through the persistent bridge daemon."
  (let (routed-to)
    ;; Given FaltooBot websocket mode is enabled for the workspace.
    (cl-letf (((symbol-function 'faltoo-bridge-websocket-enabled-p) (lambda (_workspace) t))
              ((symbol-function 'faltoo-bridge--daemon-stream)
               (lambda (&rest _args)
                 (setq routed-to 'daemon)
                 'daemon-process))
              ((symbol-function 'faltoo-bridge--oneshot-stream)
               (lambda (&rest _args)
                 (setq routed-to 'oneshot)
                 'oneshot-process))
              ((symbol-function 'faltoo-bridge--command) (lambda (&rest _args) '("cat"))))

      ;; When an append-message stream starts.
      (should (eq (faltoo-bridge-stream
                   '("append-message")
                   '((workspace . "/repo/") (text . "hello"))
                   #'ignore #'ignore)
                  'daemon-process)))

    ;; Then the long-lived daemon path is used.
    (should (eq routed-to 'daemon))))

(ert-deftest faltoo-bridge-stream-keeps-oneshot-when-websocket-disabled ()
  "Scenario: Non-websocket append requests keep the existing one-shot bridge."
  (let (routed-to)
    ;; Given FaltooBot websocket mode is disabled for the workspace.
    (cl-letf (((symbol-function 'faltoo-bridge-websocket-enabled-p) (lambda (_workspace) nil))
              ((symbol-function 'faltoo-bridge--daemon-stream)
               (lambda (&rest _args)
                 (setq routed-to 'daemon)
                 'daemon-process))
              ((symbol-function 'faltoo-bridge--oneshot-stream)
               (lambda (&rest _args)
                 (setq routed-to 'oneshot)
                 'oneshot-process)))

      ;; When an append-review stream starts.
      (should (eq (faltoo-bridge-stream
                   '("append-review")
                   '((workspace . "/repo/") (comments . []))
                   #'ignore #'ignore)
                  'oneshot-process)))

    ;; Then the current one-shot path is used.
    (should (eq routed-to 'oneshot))))


(ert-deftest faltoo-bridge-daemon-complete-finishes-current-request ()
  "Scenario: Daemon complete events finish the matching Emacs request."
  (let ((process (start-process "faltoo-test-daemon" nil "cat"))
        events done)
    (unwind-protect
        (progn
          ;; Given a daemon process has one active request.
          (process-put process 'faltoo-requests (make-hash-table :test #'equal))
          (puthash "req-1"
                   (cons (lambda (event) (push event events))
                         (lambda (ok) (setq done ok)))
                   (process-get process 'faltoo-requests))

          ;; When the daemon emits a stream event and then completes.
          (cl-letf (((symbol-function 'faltoo-bridge--schedule-daemon-idle-stop) #'ignore))
            (faltoo-bridge--daemon-handle-line
             "/repo/" process
             "{\"id\":\"req-1\",\"classes\":\"answer\",\"text\":\"hello\"}")
            (faltoo-bridge--daemon-handle-line
             "/repo/" process
             "{\"id\":\"req-1\",\"type\":\"complete\",\"ok\":true}"))

          ;; Then the event is routed and the request callback is cleared.
          (should (equal (alist-get 'text (car events)) "hello"))
          (should (eq done t))
          (should (= (hash-table-count (process-get process 'faltoo-requests)) 0)))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest faltoo-bridge-messages-passes-turn-limit-to-bridge ()
  "Scenario: Transcript history loading asks the bridge for recent user turns."
  (let ((faltoo-workspace "/tmp/faltoo-test") captured-args)
    ;; Given bridge JSON calls are observed.

    ;; When fetching the last 25 turns.
    (cl-letf (((symbol-function 'faltoo-bridge-call-json)
               (lambda (args &optional _input _workspace)
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


(ert-deftest faltoo-main-prefix-q-cancels-running-request ()
  "Scenario: The main Faltoo prefix exposes request cancellation."
  ;; Then C-c f q cancels the current workspace request.
  (should (eq (lookup-key faltoo-command-map (kbd "q")) #'faltoo-request-cancel)))

(ert-deftest faltoo-main-prefix-i-opens-generic-chat ()
  "Scenario: The main Faltoo prefix opens the repo-independent chat."
  ;; Then C-c f i opens generic chat.
  (should (eq (lookup-key faltoo-command-map (kbd "i")) #'faltoo-generic-chat)))

(ert-deftest faltoo-main-prefix-b-selects-faltoobot-command ()
  "Scenario: The main Faltoo prefix switches between released and local core."
  ;; Then C-c f b opens Faltoo core command selection.
  (should (eq (lookup-key faltoo-command-map (kbd "b")) #'faltoo-select-faltoobot-command)))

(ert-deftest faltoo-command-and-prompt-template-bindings-are-separate ()
  "Scenario: Commands and saved prompt templates use separate keybindings."
  ;; Then command completion is on C-c /, while template insertion is on C-c p.
  (dolist (map (list faltoo-chat-mode-map faltoo-ask-mode-map))
    (should (eq (lookup-key map (kbd "C-c /")) #'faltoo-run-session-command))
    (should (eq (lookup-key map (kbd "C-c p")) #'faltoo-insert-prompt-template))))

(ert-deftest faltoo-run-session-command-runs-built-in-command ()
  "Scenario: Session commands run from their own command picker."
  (with-temp-buffer
    (let (reset-called)
      ;; Given built-in session commands are available in completion.
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) "/reset — start a fresh session"))
                ((symbol-function 'faltoo-session-reset)
                 (lambda () (setq reset-called t))))

        ;; When choosing /reset from the command picker.
        (faltoo-run-session-command))

      ;; Then no prompt text is inserted; the command executes directly.
      (should reset-called)
      (should (string-empty-p (buffer-string))))))

(ert-deftest faltoo-session-resume-preserves-faltoobot-session-order ()
  "Scenario: Resume picker preserves the session order returned by FaltooBot."
  (let (completion-labels resumed-session)
    ;; Given FaltooBot already returns sessions in the right recency order.
    (cl-letf (((symbol-function 'faltoo-session-workspace) (lambda () "/repo/"))
              ((symbol-function 'faltoo-bridge-list-sessions)
               (lambda (_workspace)
                 '(((id . "latest") (name . "latest - 12 Jun"))
                   ((id . "middle") (name . "middle - 8 Jun"))
                   ((id . "older") (name . "older - 1 Jun")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (let* ((metadata (completion-metadata "" collection nil))
                        (sorter (completion-metadata-get metadata 'display-sort-function)))
                   (should (eq sorter #'identity))
                   (setq completion-labels (funcall sorter (all-completions "" collection)))
                   (car completion-labels))))
              ((symbol-function 'faltoo-bridge-resume-session)
               (lambda (session-id _workspace)
                 (setq resumed-session session-id)
                 '((session_id . "latest"))))
              ((symbol-function 'faltoo-chat-refresh) (lambda (&optional _workspace) nil)))

      ;; When opening the resume picker.
      (faltoo-session-resume))

    ;; Then Emacs completion preserves FaltooBot's order instead of sorting labels itself.
    (should (equal completion-labels
                   '("latest - 12 Jun" "middle - 8 Jun" "older - 1 Jun")))
    (should (equal resumed-session "latest"))))

(ert-deftest faltoo-session-tree-opens-transcript-inspector ()
  "Scenario: The /tree command opens the structured transcript inspector."
  (let (opened-workspace)
    ;; Given a current workspace exists.
    (cl-letf (((symbol-function 'faltoo-session-workspace) (lambda () "/repo"))
              ((symbol-function 'faltoo-tree-open)
               (lambda (workspace) (setq opened-workspace workspace))))

      ;; When running the tree command.
      (faltoo-session-tree))

    ;; Then /tree opens the Emacs transcript inspector for that workspace.
    (should (equal opened-workspace "/repo"))))


(ert-deftest faltoo-tree-open-shows-buffer-before-stream-rows-arrive ()
  "Scenario: Large transcript trees open immediately while rows stream later."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")) opened-buffer stream-callback)
    (unwind-protect
        (progn
          ;; Given the bridge row stream has not emitted any row yet.
          (write-region (json-serialize '((messages . []))) nil messages-file nil 'silent)
          (cl-letf (((symbol-function 'faltoo-bridge-messages-path) (lambda (_workspace) messages-file))
                    ((symbol-function 'faltoo-bridge-tree-rows-stream)
                     (lambda (_workspace on-event _on-done)
                       (setq stream-callback on-event)
                       'fake-process))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _args)
                       (setq opened-buffer buffer))))

            ;; When opening the tree.
            (faltoo-tree-open "/repo")

            ;; Then the buffer is already visible and in loading state before rows arrive.
            (with-current-buffer opened-buffer
              (should (derived-mode-p 'faltoo-tree-mode))
              (should (derived-mode-p 'special-mode))
              (should (null faltoo-tree-row-entries)))

            ;; When a streamed batch arrives.
            (funcall stream-callback
                     '((type . "rows")
                       (rows . [((index . 0)
                                 (role . "user")
                                 (message_type . "message")
                                 (kind . "message")
                                 (preview . "hello"))])))

            ;; Then the row is inserted without reparsing the whole transcript.
            (with-current-buffer opened-buffer
              (should (equal (mapcar #'car faltoo-tree-row-entries) '(0)))
              (should (string-match-p "hello" (buffer-string))))))
      (when (buffer-live-p opened-buffer) (kill-buffer opened-buffer))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-open-starts-at-latest-visible-row ()
  "Scenario: Transcript tree opens at the latest visible transcript row."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")) opened-buffer)
    (unwind-protect
        (progn
          ;; Given a transcript has multiple visible rows.
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "first"))
                            ((type . "message") (role . "assistant") (content . [((text . "last"))]))])))
           nil messages-file nil 'silent)
          (cl-letf (((symbol-function 'faltoo-bridge-messages-path) (lambda (_workspace) messages-file))
                    ((symbol-function 'faltoo-bridge-tree-rows-stream)
                     (lambda (_workspace on-event on-done)
                       (funcall on-event
                                '((type . "rows")
                                  (rows . [((index . 0)
                                            (role . "user")
                                            (message_type . "message")
                                            (kind . "message")
                                            (preview . "first"))
                                           ((index . 1)
                                            (role . "assistant")
                                            (message_type . "message")
                                            (kind . "answer")
                                            (preview . "last"))])))
                       (funcall on-done t)
                       'fake-process))
                    ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _args) (setq opened-buffer buffer))))

            ;; When opening the tree and the stream finishes.
            (faltoo-tree-open "/repo"))

          ;; Then point starts near the newest row instead of the oldest row.
          (with-current-buffer opened-buffer
            (should (> (point) (point-min)))))
      (delete-file messages-file))))


(ert-deftest faltoo-tree-open-forces-truncation-after-display ()
  "Scenario: Tree rows stay single-line even after opening in a split window."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")) truncated-buffer truncated-arg)
    (unwind-protect
        (progn
          ;; Given the tree opens through Emacs display rules.
          (write-region (json-serialize '((messages . []))) nil messages-file nil 'silent)
          (cl-letf (((symbol-function 'faltoo-bridge-messages-path) (lambda (_workspace) messages-file))
                    ((symbol-function 'faltoo-bridge-tree-rows-stream) (lambda (&rest _args) 'fake-process))
                    ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _args) buffer))
                    ((symbol-function 'toggle-truncate-lines)
                     (lambda (arg)
                       (setq truncated-buffer (current-buffer)
                             truncated-arg arg))))
            ;; When opening the tree.
            (faltoo-tree-open "/repo"))

          ;; Then truncation is forced after display, the same as manual `toggle-truncate-lines'.
          (should (equal (buffer-name truncated-buffer) "*Faltoo Tree: repo*"))
          (should (= truncated-arg 1)))
      (when (get-buffer "*Faltoo Tree: repo*") (kill-buffer "*Faltoo Tree: repo*"))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-open-displays-in-another-window ()
  "Scenario: The /tree viewer opens beside source buffers instead of replacing them."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")) display-action)
    (unwind-protect
        (progn
          ;; Given a transcript file exists.
          (write-region (json-serialize '((messages . []))) nil messages-file nil 'silent)
          (cl-letf (((symbol-function 'faltoo-bridge-messages-path) (lambda (_workspace) messages-file))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (_buffer &optional action &rest _args)
                       (setq display-action action))))

            ;; When opening the tree.
            (faltoo-tree-open "/repo"))

          ;; Then it uses Emacs display rules to pop a split/other-window buffer.
          (should (eq display-action #'display-buffer-pop-up-window)))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-refresh-uses-the-tree-buffers-messages-path ()
  "Scenario: Transcript tree refresh reads the path stored on the tree buffer."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (with-temp-buffer
          ;; Given the tree buffer has its transcript file path stored locally.
          (write-region (json-serialize '((messages . [((type . "message") (role . "user") (content . "hello"))])))
                        nil messages-file nil 'silent)
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)

          ;; When refreshing the tree.
          (faltoo-tree-refresh)

          ;; Then the path survives internal temp-buffer parsing and rows are rendered.
          (should (= (length faltoo-tree-row-entries) 1))
          (let ((row (faltoo-test--tree-row-cells (caar faltoo-tree-row-entries)
                                      (cdar faltoo-tree-row-entries))))
            (should (equal (substring-no-properties (aref row 2)) "hello"))))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-prune-from-row-writes-valid-messages-json ()
  "Scenario: Pruning from a tree row writes a valid transcript JSON array."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (with-temp-buffer
          ;; Given a transcript tree is loaded at the row to prune from.
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "keep"))
                            ((type . "message") (role . "assistant")
                             (content . [((text . "remove"))]))])))
           nil messages-file nil 'silent)
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)
          (faltoo-tree-refresh)
          (faltoo-tree--goto-id 1)

          ;; When pruning and confirming the deletion.
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                    ((symbol-function 'faltoo-chat-refresh) (lambda (&rest _args) nil)))
            (faltoo-tree-prune-from-row))

          ;; Then the file remains parseable and only earlier messages remain.
          (let* ((payload (with-temp-buffer
                            (insert-file-contents messages-file)
                            (json-parse-buffer :object-type 'alist :array-type 'list)))
                 (messages (alist-get 'messages payload)))
            (should (= (length messages) 1))
            (should (equal (alist-get 'content (car messages)) "keep"))))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-open-raw-from-tree-jumps-to-selected-message ()
  "Scenario: Opening raw transcript from the tree lands on the selected message object."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (progn
          ;; Given a readable transcript file and the second row is selected.
          (write-region
           (concat "{\n"
                   "  \"messages\": [\n"
                   "    {\n"
                   "      \"type\": \"message\",\n"
                   "      \"role\": \"user\",\n"
                   "      \"content\": \"first\"\n"
                   "    },\n"
                   "    {\n"
                   "      \"type\": \"message\",\n"
                   "      \"role\": \"assistant\",\n"
                   "      \"content\": [{\"text\": \"second\"}]\n"
                   "    }\n"
                   "  ]\n"
                   "}\n")
           nil messages-file nil 'silent)
          (with-temp-buffer
            (faltoo-tree-mode)
            (setq faltoo-tree-path messages-file)
            (faltoo-tree-refresh)
            (faltoo-tree--goto-id 1)

            ;; When opening the raw transcript.
            (faltoo-tree-open-raw))

          ;; Then the raw file opens at the selected message object's start.
          (with-current-buffer (get-file-buffer messages-file)
            (should (= (line-number-at-pos) 8))
            (should (looking-at-p "[[:space:]]*{"))))
      (when (get-file-buffer messages-file)
        (kill-buffer (get-file-buffer messages-file)))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-open-raw-from-detail-jumps-to-current-detail-message ()
  "Scenario: Opening raw transcript from row detail lands on that detail's message object."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")) detail-buffer)
    (unwind-protect
        (progn
          ;; Given row detail was opened from the second transcript row.
          (write-region
           (concat "{\n"
                   "  \"messages\": [\n"
                   "    {\n"
                   "      \"type\": \"message\",\n"
                   "      \"role\": \"user\",\n"
                   "      \"content\": \"first\"\n"
                   "    },\n"
                   "    {\n"
                   "      \"type\": \"message\",\n"
                   "      \"role\": \"assistant\",\n"
                   "      \"content\": [{\"text\": \"second\"}]\n"
                   "    }\n"
                   "  ]\n"
                   "}\n")
           nil messages-file nil 'silent)
          (with-temp-buffer
            (faltoo-tree-mode)
            (setq faltoo-tree-path messages-file)
            (faltoo-tree-refresh)
            (faltoo-tree--goto-id 1)
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _args) (setq detail-buffer buffer))))
              (faltoo-tree-inspect)))

          ;; When opening raw transcript from the detail buffer.
          (with-current-buffer detail-buffer
            (faltoo-tree-open-raw))

          ;; Then the raw file opens at the detail message object's start.
          (with-current-buffer (get-file-buffer messages-file)
            (should (= (line-number-at-pos) 8))
            (should (looking-at-p "[[:space:]]*{"))))
      (when (buffer-live-p detail-buffer) (kill-buffer detail-buffer))
      (when (get-file-buffer messages-file)
        (kill-buffer (get-file-buffer messages-file)))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-mode-keeps-previews-to-one-visual-row ()
  "Scenario: Transcript tree previews collapse embedded newlines."
  (with-temp-buffer
    (faltoo-tree-mode)
    (let* ((item '((type . "message")
                   (role . "assistant")
                   (content . [((text . "first\n\nsecond"))])))
           (row (faltoo-test--tree-row-cells 1 item)))
      ;; Then multiline assistant output does not split the table row.
      (should-not (string-match-p "\n" (aref row 2))))))

(ert-deftest faltoo-tree-mode-summarizes-inline-images-without-reading-base64 ()
  "Scenario: Transcript tree previews image payloads without expanding inline base64."
  (with-temp-buffer
    (faltoo-tree-mode)
    (let* ((image-url (concat "data:image/png;base64," (make-string 1000 ?A)))
           (item `((type . "message")
                   (role . "user")
                   (content . [((type . "input_text")
                                (text . "look at this"))
                               ((type . "input_image")
                                (detail . "auto")
                                (image_url . ,image-url))])))
           (row (faltoo-test--tree-row-cells 1 item)))
      ;; Then tree rendering is cheap and only shows a small image marker.
      (should (string-match-p "look at this" (aref row 2)))
      (should (string-match-p "\[image: input_image\]" (aref row 2)))
      (should-not (string-match-p "base64" (aref row 2))))))

(ert-deftest faltoo-tree-mode-summarizes-structured-tool-output-without-errors ()
  "Scenario: Transcript tree previews structured tool output as a short marker."
  (with-temp-buffer
    (faltoo-tree-mode)
    (let* ((item '((type . "function_call_output")
                   (output . (((type . "input_image")
                               (image_url . "data:image/png;base64,abc"))))))
           (row (faltoo-test--tree-row-cells 2 item)))
      ;; Then non-string output does not reach string-trim directly.
      (should (equal (substring-no-properties (aref row 2)) "output: [structured output]")))))

(ert-deftest faltoo-tree-mode-highlights-type-and-mutes-preview ()
  "Scenario: Transcript tree uses compact highlighting instead of painting whole rows."
  (with-temp-buffer
    (faltoo-tree-mode)
    (let* ((item '((type . "message") (role . "user") (content . "hello")))
           (row (faltoo-test--tree-row-cells 12 item)))
      ;; Then role is plain, type is colored, and preview is muted.
      (should-not (get-text-property 0 'face (aref row 0)))
      (should (eq (get-text-property 0 'face (aref row 1)) 'faltoo-tree-user-face))
      (should (eq (get-text-property 0 'face (aref row 2)) 'faltoo-tree-preview-face)))))

(ert-deftest faltoo-tree-mode-uses-short-role-labels-and-focused-view-options ()
  "Scenario: Transcript tree is a focused table, not a wrapped source buffer."
  (with-temp-buffer
    (display-line-numbers-mode 1)
    ;; When entering tree mode.
    (visual-line-mode 1)
    (faltoo-tree-mode)

    ;; Then visual noise is disabled and the current row is highlighted.
    (should truncate-lines)
    (should truncate-partial-width-windows)
    (should-not word-wrap)
    (should-not visual-line-mode)
    (should display-line-numbers-mode)
    (should hl-line-mode)

    ;; And roles use short labels.
    (should (equal (substring-no-properties
                    (aref (faltoo-test--tree-row-cells 1 '((type . "message") (role . "user"))) 0))
                   "USR"))
    (should (equal (substring-no-properties
                    (aref (faltoo-test--tree-row-cells 2 '((type . "message") (role . "assistant"))) 0))
                   "AST"))))


(ert-deftest faltoo-tree-mode-renders-compact-message-rows-by-default ()
  "Scenario: Transcript tree defaults to the small useful column set."
  (with-temp-buffer
    (faltoo-tree-mode)
    (let* ((item '((type . "message")
                   (role . "assistant")
                   (phase . "final_answer")
                   (content . [((text . "Done with the fix") (type . "output_text"))])))
           (row (faltoo-test--tree-row-cells 7 item)))
      ;; Then only role, type, and preview are shown; line numbers provide row numbers.
      (should (= (length row) 3))
      (should (equal (substring-no-properties (aref row 0)) "AST"))
      (should (equal (substring-no-properties (aref row 1)) "answer"))
      (should (equal (substring-no-properties (aref row 2)) "Done with the fix")))))



(ert-deftest faltoo-tree-token-view-hides-json-null-token-values ()
  "Scenario: Token bookkeeping hides null usage values instead of crashing."
  (with-temp-buffer
    ;; Given a compact streamed row has JSON null token values.
    (faltoo-tree-mode)
    (setq faltoo-tree-token-view t)

    ;; When rendering the row in token view.
    (let* ((item '((type . "message")
                   (role . "assistant")
                   (faltoo-tree-kind . "answer")
                   (faltoo-tree-preview . "Done")
                   (faltoo-tree-input-tokens . :null)
                   (faltoo-tree-output-tokens . :null)
                   (faltoo-tree-cached-tokens . :null)
                   (faltoo-tree-total-tokens . :null)))
           (row (faltoo-test--tree-row-cells 1 item)))

      ;; Then token cells are blank, not passed to `number-to-string'.
      (should (equal (aref row 2) ""))
      (should (equal (aref row 3) ""))
      (should (equal (aref row 4) ""))
      (should (equal (aref row 5) "")))))

(ert-deftest faltoo-tree-mode-toggles-token-bookkeeping-view ()
  "Scenario: Transcript tree can switch from preview scanning to token bookkeeping."
  (with-temp-buffer
    ;; Given a row has OpenAI usage details.
    (faltoo-tree-mode)
    (let* ((item '((type . "message")
                   (role . "assistant")
                   (usage . ((input_tokens . 100)
                             (output_tokens . 20)
                             (total_tokens . 120)
                             (input_tokens_details . ((cached_tokens . 80)))))
                   (content . [((text . "Long assistant preview text that is not useful in token view"))])))
           (preview-row (faltoo-test--tree-row-cells 4 item)))

      ;; When token view is toggled on.
      (setq faltoo-tree-row-entries (list (cons 4 item)))
      (faltoo-tree--render-rows)
      (faltoo-tree--goto-id 4)
      (faltoo-tree-toggle-token-view)
      (let ((token-row (faltoo-test--tree-row-cells 4 item)))

        ;; Then preview becomes compact and token columns are shown with distinct faces.
        (should faltoo-tree-token-view)
        (should (= (faltoo-tree--current-index) 4))
        (should (< (length (aref token-row 6)) (length (aref preview-row 2))))
        (should (equal (substring-no-properties (aref token-row 2)) "100"))
        (should (equal (substring-no-properties (aref token-row 3)) "20"))
        (should (equal (substring-no-properties (aref token-row 4)) "80"))
        (should (equal (substring-no-properties (aref token-row 5)) "120"))
        (should (eq (get-text-property 0 'face (aref token-row 2)) 'faltoo-tree-input-token-face))
        (should (eq (get-text-property 0 'face (aref token-row 3)) 'faltoo-tree-output-token-face))
        (should (eq (get-text-property 0 'face (aref token-row 4)) 'faltoo-tree-cached-token-face))
        (should (eq (get-text-property 0 'face (aref token-row 5)) 'faltoo-tree-total-token-face))))))


(ert-deftest faltoo-tree-token-view-formats-large-token-counts-with-commas ()
  "Scenario: Token bookkeeping uses comma-separated numbers for readability."
  (with-temp-buffer
    ;; Given token view is active for a row with large usage counts.
    (faltoo-tree-mode)
    (setq faltoo-tree-token-view t)

    ;; When rendering token cells.
    (let* ((item '((type . "message")
                   (role . "assistant")
                   (usage . ((input_tokens . 1234567)
                             (output_tokens . 98765)
                             (total_tokens . 1333332)
                             (input_tokens_details . ((cached_tokens . 1200000)))))))
           (row (faltoo-test--tree-row-cells 1 item)))

      ;; Then counts are easier to scan in the tree.
      (should (equal (substring-no-properties (aref row 2)) "1,234,567"))
      (should (equal (substring-no-properties (aref row 3)) "98,765"))
      (should (equal (substring-no-properties (aref row 4)) "1,200,000"))
      (should (equal (substring-no-properties (aref row 5)) "1,333,332")))))

(ert-deftest faltoo-tree-streamed-rows-carry-token-bookkeeping ()
  "Scenario: Streamed tree rows can render token columns without full JSON parsing."
  (with-temp-buffer
    ;; Given token view is active before a streamed row arrives.
    (faltoo-tree-mode)
    (setq faltoo-tree-token-view t)
    ;; When a compact row includes token usage.
    (faltoo-tree--stream-event
     '((type . "rows")
       (rows . [((index . 9)
                 (role . "assistant")
                 (message_type . "message")
                 (kind . "answer")
                 (preview . "Done")
                 (input_tokens . 11)
                 (output_tokens . 22)
                 (cached_tokens . 7)
                 (total_tokens . 33))])))

    ;; Then the token values render directly from the stream metadata.
    (let ((row (faltoo-test--tree-row-cells (caar faltoo-tree-row-entries)
                                           (cdar faltoo-tree-row-entries))))
      (should (equal (substring-no-properties (aref row 2)) "11"))
      (should (equal (substring-no-properties (aref row 3)) "22"))
      (should (equal (substring-no-properties (aref row 4)) "7"))
      (should (equal (substring-no-properties (aref row 5)) "33")))))

(ert-deftest faltoo-tree-mode-jumps-between-user-and-answer-rows ()
  "Scenario: Transcript tree has direct jumps to recent user and answer rows."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (with-temp-buffer
          ;; Given a transcript has multiple user and assistant answer rows.
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "first user"))
                            ((type . "message") (role . "assistant") (content . [((text . "first answer"))]))
                            ((type . "message") (role . "user") (content . "last user"))
                            ((type . "message") (role . "assistant") (content . [((text . "last answer"))]))])))
           nil messages-file nil 'silent)
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)
          (faltoo-tree-refresh)
          (goto-char (point-max))

          ;; When jumping through users and answers.
          (faltoo-tree-previous-user)
          (should (= (faltoo-tree--current-index) 2))
          (faltoo-tree-previous-user)
          (should (= (faltoo-tree--current-index) 0))
          (faltoo-tree-previous-user)
          (should (= (faltoo-tree--current-index) 2))
          (faltoo-tree-next-user)
          (should (= (faltoo-tree--current-index) 0))
          (faltoo-tree-next-user)
          (should (= (faltoo-tree--current-index) 2))
          (goto-char (point-max))
          (faltoo-tree-previous-answer)
          (should (= (faltoo-tree--current-index) 3))
          (faltoo-tree-previous-answer)
          (should (= (faltoo-tree--current-index) 1))
          (faltoo-tree-previous-answer)
          (should (= (faltoo-tree--current-index) 3))
          (faltoo-tree-next-answer)
          (should (= (faltoo-tree--current-index) 1)))
      (delete-file messages-file))))


(ert-deftest faltoo-tree-detail-mode-cycles-through-visible-tree-rows ()
  "Scenario: Row detail buffers move by every visible tree row."
  (let ((messages '(((type . "message") (role . "user") (content . "prompt"))
                    ((type . "reasoning") (summary . [((text . "thinking"))]))
                    ((type . "function_call") (name . "run_shell"))
                    ((type . "message") (role . "assistant") (content . [((text . "answer"))])))))
    (with-temp-buffer
      ;; Given a detail buffer is showing the first visible tree row.
      (faltoo-tree-detail-mode)
      (setq faltoo-tree-messages messages
            faltoo-tree-detail-indexes '(0 1 2 3)
            faltoo-tree-detail-index 0)
      (faltoo-tree-detail-render)

      ;; When moving next/previous by visible tree row.
      (faltoo-tree-detail-next-item)
      (should (= faltoo-tree-detail-index 1))
      (should (string-match-p "thinking" (buffer-string)))
      (faltoo-tree-detail-next-item)
      (should (= faltoo-tree-detail-index 2))
      (faltoo-tree-detail-previous-item)
      (should (= faltoo-tree-detail-index 1)))))


(ert-deftest faltoo-tree-detail-mode-jumps-between-user-and-answer-rows ()
  "Scenario: Row detail buffers can jump by user and assistant answer rows."
  (let ((messages '(((type . "message") (role . "user") (content . "first user"))
                    ((type . "reasoning") (summary . [((text . "thinking"))]))
                    ((type . "message") (role . "assistant") (content . [((text . "first answer"))]))
                    ((type . "message") (role . "user") (content . "last user"))
                    ((type . "message") (role . "assistant") (content . [((text . "last answer"))])))))
    (with-temp-buffer
      ;; Given a detail buffer is showing the last assistant answer.
      (faltoo-tree-detail-mode)
      (setq faltoo-tree-messages messages
            faltoo-tree-detail-indexes '(0 1 2 3 4)
            faltoo-tree-detail-index 4)
      (faltoo-tree-detail-render)

      ;; When jumping by user and answer rows from detail.
      (faltoo-tree-previous-user)
      (should (= faltoo-tree-detail-index 3))
      (should (string-match-p "last user" (buffer-string)))
      (faltoo-tree-previous-user)
      (should (= faltoo-tree-detail-index 0))
      (faltoo-tree-next-answer)
      (should (= faltoo-tree-detail-index 2))
      (should (string-match-p "first answer" (buffer-string)))
      (faltoo-tree-next-answer)
      (should (= faltoo-tree-detail-index 4)))))

(ert-deftest faltoo-tree-detail-open-captures-current-tree-rows-for-navigation ()
  "Scenario: Detail p/n follows the rows visible in the originating tree buffer."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")) detail-buffer)
    (unwind-protect
        (with-temp-buffer
          ;; Given a tree shows user, reasoning, tool call, and answer rows.
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "prompt"))
                            ((type . "reasoning") (summary . [((text . "thinking"))]))
                            ((type . "function_call") (name . "run_shell"))
                            ((type . "message") (role . "assistant") (content . [((text . "answer"))]))])))
           nil messages-file nil 'silent)
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)
          (faltoo-tree-refresh)
          (faltoo-tree--goto-id 3)

          ;; When opening row detail and moving to the previous row.
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _args) (setq detail-buffer buffer))))
            (faltoo-tree-inspect))
          (with-current-buffer detail-buffer
            (faltoo-tree-detail-previous-item)

            ;; Then p lands on the immediately previous tree row.
            (should (= faltoo-tree-detail-index 2))
            (should (string-match-p "run_shell" (buffer-string)))))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-mode-searches-backing-messages-not-visible-preview ()
  "Scenario: Transcript tree search lands on a row whose full message contains the query."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (with-temp-buffer
          ;; Given a transcript contains a term only present in the full message block.
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "short prompt"))
                            ((type . "message") (role . "assistant")
                             (content . [((text . "visible prefix"))])
                             (hidden_meta . "needle-from-backing-json"))
                            ((type . "message") (role . "user") (content . "another prompt"))])))
           nil messages-file nil 'silent)
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)
          (faltoo-tree-refresh)
          (goto-char (point-min))

          ;; When searching from the table.
          (faltoo-tree-search "needle-from-backing-json")

          ;; Then point lands on the backing message row, not a current-buffer preview match.
          (should (= (faltoo-tree--current-index) 1)))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-mode-search-wraps-through-visible-message-rows ()
  "Scenario: Transcript tree search wraps through matching rows."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (with-temp-buffer
          ;; Given two visible transcript rows contain the same backing term.
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "needle one"))
                            ((type . "message") (role . "assistant") (content . [((text . "other"))]))
                            ((type . "message") (role . "user") (content . "needle two"))])))
           nil messages-file nil 'silent)
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)
          (faltoo-tree-refresh)
          (faltoo-tree--goto-id 2)

          ;; When searching forward from the last matching row.
          (faltoo-tree-search "needle")

          ;; Then search wraps to the first matching row.
          (should (= (faltoo-tree--current-index) 0)))
      (delete-file messages-file))))

(ert-deftest faltoo-tree-modes-use-only-active-navigation-bindings ()
  "Scenario: Tree buffers expose only the useful current navigation bindings."
  (with-temp-buffer
    ;; Then the tree buffer keeps row inspection/search and direct user/answer jumps.
    (faltoo-tree-mode)
    (should (eq (key-binding (kbd "/")) #'faltoo-tree-search))
    (should (eq (key-binding (kbd "C-c s")) #'faltoo-tree-search))
    (should (eq (key-binding (kbd "u")) #'faltoo-tree-previous-user))
    (should (eq (key-binding (kbd "U")) #'faltoo-tree-next-user))
    (should (eq (key-binding (kbd "a")) #'faltoo-tree-previous-answer))
    (should (eq (key-binding (kbd "A")) #'faltoo-tree-next-answer))
    (should (eq (key-binding (kbd "o")) #'faltoo-tree-open-raw))
    (should (eq (key-binding (kbd "T")) #'faltoo-tree-toggle-token-view))
    (dolist (key '("C-c u p" "C-c u n" "C-c a p" "C-c a n"))
      (should-not (key-binding (kbd key))))
    (dolist (key '("v" "f" "r" "t"))
      (should-not (lookup-key (current-local-map) (kbd key)))))
  (with-temp-buffer
    ;; And the detail buffer keeps row and user/answer jump bindings.
    (faltoo-tree-detail-mode)
    (should (eq (key-binding (kbd "p")) #'faltoo-tree-detail-previous-item))
    (should (eq (key-binding (kbd "n")) #'faltoo-tree-detail-next-item))
    (should (eq (key-binding (kbd "o")) #'faltoo-tree-open-raw))
    (should (eq (key-binding (kbd "u")) #'faltoo-tree-previous-user))
    (should (eq (key-binding (kbd "U")) #'faltoo-tree-next-user))
    (should (eq (key-binding (kbd "a")) #'faltoo-tree-previous-answer))
    (should (eq (key-binding (kbd "A")) #'faltoo-tree-next-answer))))

(ert-deftest faltoo-tree-keymaps-refresh-when-plugin-is-reloaded ()
  "Scenario: Reloading the plugin replaces stale tree keymaps."
  (let ((faltoo-tree-mode-map (let ((map (make-sparse-keymap)))
                                (define-key map (kbd "v") #'ignore)
                                map))
        (faltoo-tree-detail-mode-map (let ((map (make-sparse-keymap)))
                                       (define-key map (kbd "u") #'ignore)
                                       map)))
    ;; When tree keymaps are rebuilt during reload.
    (faltoo-tree--setup-keymaps)

    ;; Then stale removed bindings disappear and detail navigation is available.
    (should-not (lookup-key faltoo-tree-mode-map (kbd "v")))
    (should (eq (lookup-key faltoo-tree-detail-mode-map (kbd "u"))
                #'faltoo-tree-previous-user))
    (should (eq (lookup-key faltoo-tree-detail-mode-map (kbd "p"))
                #'faltoo-tree-detail-previous-item))
    (should (eq (lookup-key faltoo-tree-detail-mode-map (kbd "n"))
                #'faltoo-tree-detail-next-item))))

(ert-deftest faltoo-tree-mode-shows-all-transcript-items-by-default ()
  "Scenario: Transcript tree shows every item while staying focused as a table."
  (let ((messages-file (make-temp-file "faltoo-tree" nil ".json")))
    (unwind-protect
        (with-temp-buffer
          ;; Given line numbers are globally visible and transcript has internal rows.
          (display-line-numbers-mode 1)
          (write-region
           (json-serialize
            '((messages . [((type . "message") (role . "user") (content . "prompt"))
                            ((type . "reasoning") (summary . [((text . "thinking"))]))
                            ((type . "function_call_output") (output . "huge output"))
                            ((type . "message") (role . "assistant") (content . [((text . "answer"))]))])))
           nil messages-file nil 'silent)

          ;; When opening tree mode and refreshing.
          (faltoo-tree-mode)
          (setq faltoo-tree-path messages-file)
          (faltoo-tree-refresh)

          ;; Then line numbers stay visible and no transcript rows are filtered out.
          (should display-line-numbers-mode)
          (should (equal (mapcar #'car faltoo-tree-row-entries) '(0 1 2 3))))
      (delete-file messages-file))))


(ert-deftest faltoo-tree-type-faces-use-doom-palette-when-available ()
  "Scenario: Transcript tree type colors follow the active Doom theme palette."
  (cl-letf (((symbol-function 'doom-color)
             (lambda (name)
               (alist-get name '((green . "green")
                                 (violet . "violet")
                                 (blue . "blue")
                                 (dark-blue . "dark-blue")
                                 (magenta . "magenta")
                                 (grey . "grey")
                                 (cyan . "cyan")
                                 (orange . "orange"))))))
    ;; When applying theme colors.
    (faltoo-tree-apply-theme-faces)

    ;; Then tree type faces use distinct theme palette colors.
    (should (equal (face-attribute 'faltoo-tree-user-face :foreground nil) "green"))
    (should (equal (face-attribute 'faltoo-tree-assistant-face :foreground nil) "violet"))
    (should (equal (face-attribute 'faltoo-tree-tool-call-face :foreground nil) "blue"))
    (should (equal (face-attribute 'faltoo-tree-tool-output-face :foreground nil) "dark-blue"))
    (should (equal (face-attribute 'faltoo-tree-image-face :foreground nil) "magenta"))
    (should (equal (face-attribute 'faltoo-tree-reasoning-face :foreground nil) "grey"))
    (should (equal (face-attribute 'faltoo-tree-web-face :foreground nil) "cyan"))
    (should (equal (face-attribute 'faltoo-tree-compaction-face :foreground nil) "orange"))))

(ert-deftest faltoo-tree-mode-colors-types-and-mutes-previews ()
  "Scenario: Transcript tree colors each row type while keeping previews muted."
  (with-temp-buffer
    (faltoo-tree-mode)
    (dolist (case '(("message" "user" nil faltoo-tree-user-face)
                    ("message" "assistant" nil faltoo-tree-assistant-face)
                    ("function_call" nil nil faltoo-tree-tool-call-face)
                    ("function_call_output" nil nil faltoo-tree-tool-output-face)
                    ("function_call" nil "image gen" faltoo-tree-image-face)
                    ("reasoning" nil nil faltoo-tree-reasoning-face)
                    ("web_search_call" nil nil faltoo-tree-web-face)
                    ("compaction" nil nil faltoo-tree-compaction-face)))
      (let* ((item `((type . ,(nth 0 case)) (role . ,(nth 1 case)) (kind . ,(nth 2 case)) (content . "preview")))
             (row (faltoo-test--tree-row-cells 1 item)))
        ;; Then the type has its own face and preview uses muted styling.
        (should (eq (get-text-property 0 'face (aref row 1)) (nth 3 case)))
        (should (eq (get-text-property 0 'face (aref row 2)) 'faltoo-tree-preview-face))))))

(ert-deftest faltoo-session-status-shows-pretty-popup ()
  "Scenario: The /status command renders Faltoo status in a popup."
  (let (shown-buffer)
    ;; Given the bridge returns FaltooChat's status text.
    (cl-letf (((symbol-function 'faltoo-workspace) (lambda () "/repo"))
              ((symbol-function 'faltoo-bridge-status)
               (lambda (_workspace)
                 '((workspace . "/repo")
                   (text . "Faltoobot status\n\nVersion: test\n\nSession\n• session_id=\"abc\"\n\nConfig status\n• openai_model=\"gpt\"\n\nSession usage\n• last_usage={\"input_tokens\":1}"))))
              ((symbol-function 'faltoo-popup-show)
               (lambda (buffer &rest _args) (setq shown-buffer buffer))))

      ;; When running the status command.
      (faltoo-session-status))

    ;; Then the temporary popup contains Markdown sections and bullets.
    (with-current-buffer shown-buffer
      (should (string-match-p "# Faltoo Status" (buffer-string)))
      (should (string-match-p "## Session" (buffer-string)))
      (should (string-match-p "- session_id=\"abc\"" (buffer-string)))
      (should (string-match-p "## Config status" (buffer-string)))
      (should (string-match-p "- openai_model=\"gpt\"" (buffer-string)))
      (should (string-match-p "```json" (buffer-string)))
      (should (string-match-p "\"input_tokens\": 1" (buffer-string))))))

(ert-deftest faltoo-insert-prompt-template-pastes-selected-template ()
  "Scenario: Picking a saved prompt inserts its contents, not the slash command."
  (with-temp-buffer
    ;; Given saved prompts are available from FaltooBot.
    (cl-letf (((symbol-function 'faltoo-bridge-slash-commands)
               (lambda ()
                 '(((command . "/commit")
                    (preview . "Write a commit")
                    (template . "Please write a focused commit message.")))))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) "/commit — Write a commit")))

      ;; When choosing the prompt template from completion.
      (faltoo-insert-prompt-template))

    ;; Then the reusable prompt text is pasted for review/editing.
    (should (equal (buffer-string) "Please write a focused commit message."))))

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
  (faltoo-test--kill-chat-buffer)
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

(ert-deftest faltoo-chat-jumps-between-persisted-user-messages ()
  "Scenario: Transcript navigation jumps between user turns without stopping on the draft prompt."
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "first question"))
                                   ((role . "assistant") (text . "first answer"))
                                   ((role . "user") (text . "second question"))
                                   ((role . "assistant") (text . "second answer"))))))
    ;; Given a transcript has multiple persisted user turns and an editable draft prompt.
    (with-current-buffer buf
      (goto-char (point-max))

      ;; When jumping backward from the draft prompt.
      (faltoo-chat-prev-user-message)

      ;; Then point lands on the latest persisted user message, not the empty draft prompt.
      (should (looking-at "# User"))
      (should (save-excursion
                (search-forward "second question" nil t)))

      ;; When jumping backward and forward between persisted user messages.
      (faltoo-chat-prev-user-message)
      (should (save-excursion
                (search-forward "first question" nil t)))
      (faltoo-chat-next-user-message)
      (should (save-excursion
                (search-forward "second question" nil t)))

      ;; Then the editable draft prompt is skipped by next-user navigation.
      (should-error (faltoo-chat-next-user-message) :type 'user-error))))

(ert-deftest faltoo-chat-user-message-navigation-has-transcript-bindings ()
  "Scenario: Transcript buffers expose explicit previous/next user-turn bindings."
  ;; Given transcript-mode keybindings are active.

  ;; Then C-c C-p and C-c C-n navigate user messages.
  (should (eq (lookup-key faltoo-chat-mode-map (kbd "C-c C-p"))
              #'faltoo-chat-prev-user-message))
  (should (eq (lookup-key faltoo-chat-mode-map (kbd "C-c C-n"))
              #'faltoo-chat-next-user-message)))

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


(ert-deftest faltoo-chat-render-shows-persisted-hook-feedback-with-dedicated-face ()
  "Scenario: Persisted post-response hook feedback keeps its distinct styling after transcript refresh."
  (let ((buf (faltoo-chat-render '(((role . "hook-feedback")
                                    (text . "## Post-response hook feedback

### Refactor Code

Hook notes"))))))
    ;; Given hook feedback was loaded from messages.json.

    ;; Then it is quoted and highlighted differently from regular tool blocks.
    (with-current-buffer buf
      (should (string-match-p "> ## Post-response hook feedback" (buffer-string)))
      (goto-char (point-min))
      (search-forward "Refactor Code")
      (should (cl-some (lambda (overlay)
                         (eq (overlay-get overlay 'face) 'faltoo-chat-hook-feedback-face))
                       (overlays-at (point)))))))

(ert-deftest faltoo-chat-refresh-loads-configured-number-of-turns ()
  "Scenario: Transcript refresh asks the bridge for the configured turn count."
  (let ((faltoo-chat-turns 12) captured-turns)
    ;; Given a transcript turn limit is configured.

    ;; When refreshing the transcript.
    (cl-letf (((symbol-function 'faltoo-bridge-messages)
               (lambda (&optional turns _workspace)
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
               (lambda (&optional turns _workspace)
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
               (lambda (&optional turns _workspace)
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

(ert-deftest faltoo-chat-send-submits-typed-slash-text-as-prompt ()
  "Scenario: Typed slash text in the transcript is submitted as a normal prompt."
  (let (captured-text reset-called)
    ;; Given the transcript prompt contains text that looks like a command.
    (with-current-buffer (faltoo-chat-render nil)
      (insert "/reset")

      ;; When sending the prompt.
      (cl-letf (((symbol-function 'faltoo-session-reset)
                 (lambda () (setq reset-called t)))
                ((symbol-function 'faltoo-request-ensure-idle)
                 (lambda (&optional _workspace)))
                ((symbol-function 'faltoo-request-message)
                 (lambda (text &rest _args) (setq captured-text text))))
        (faltoo-chat-send)))

    ;; Then submit remains honest: text is sent to the model, not intercepted.
    (should (equal captured-text "/reset"))
    (should-not reset-called)))

(ert-deftest faltoo-chat-send-submits-current-user-prompt ()
  "Scenario: Sending from transcript submits only the current prompt."
  (let (captured-text)
    ;; Given the transcript has history and a typed prompt.
    (with-current-buffer (faltoo-chat-render '(((role . "assistant") (text . "old answer"))))
      (insert "please continue")

      ;; When sending the prompt.
      (cl-letf (((symbol-function 'faltoo-request-message)
                 (lambda (text &rest _args)
                   (setq captured-text text))))
        (faltoo-chat-send)))

    ;; Then only the current prompt is submitted, not transcript history.
    (should (equal captured-text "please continue"))))

(ert-deftest faltoo-chat-stream-highlights-assistant-heading-only ()
  "Scenario: Streaming assistant output keeps heading styling off the answer body."
  (faltoo-test--kill-chat-buffer)
  ;; Given a streaming answer starts.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When answer text arrives.
  (faltoo-chat-append-stream "answer body with `code`")

  ;; Then the assistant face is on the heading, not the body.
  (with-current-buffer (faltoo-test--chat-buffer-name)
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

(ert-deftest faltoo-chat-reloaded-transcript-matches-live-response-grouping ()
  "Scenario: Reloaded responses group every event like the equivalent live stream."
  (let* ((workspace (file-name-as-directory (make-temp-file "faltoo-chat-render" t)))
         (feedback "## Post-response hook feedback

### Refactor Code

Keep the flow minimal.")
         live loaded)
    (unwind-protect
        (progn
          ;; Given one live response contains visible answer, tool, and hook
          ;; events while omitting its reasoning event.
          (with-current-buffer (faltoo-chat-render nil workspace)
            (insert "Inspect this code.

"))
          (faltoo-chat-start-stream "Assistant · answering" workspace)
          (faltoo-request--route-event
           '((classes . "answer") (text . "I will inspect it.

")) workspace nil nil)
          (faltoo-request--route-event
           '((classes . "thinking") (text . "Reasoning summary: check the architecture.

"))
           workspace nil nil)
          (faltoo-request--route-event
           '((classes . "tool") (text . "Shell: inspect repository")) workspace nil nil)
          (faltoo-request--route-event
           '((classes . "tool") (text . "Web search: relevant API")) workspace nil nil)
          (faltoo-request--route-event
           '((classes . "answer") (text . "The tools confirm the current flow."))
           workspace nil nil)
          (faltoo-request--route-event
           `((classes . "hook-feedback") (text . ,feedback)) workspace nil nil)
          (faltoo-request--route-event
           '((classes . "answer") (text . "The implementation looks correct."))
           workspace nil nil)
          (faltoo-request--flush-answer workspace)
          (faltoo-chat-finish-stream workspace)
          (with-current-buffer (faltoo-chat-buffer workspace)
            (setq live (buffer-substring-no-properties (point-min) (point-max))))
          (kill-buffer (faltoo-chat-buffer workspace))

          ;; When the equivalent persisted events are loaded from messages.json.
          (with-current-buffer
              (faltoo-chat-render
               `(((role . "user") (text . "Inspect this code."))
                 ((role . "assistant") (class . "answer") (text . "I will inspect it."))
                 ((role . "assistant") (class . "thinking")
                  (text . "Reasoning summary: check the architecture."))
                 ((role . "tool") (class . "tool") (text . "Shell: inspect repository"))
                 ((role . "tool") (class . "tool") (text . "Web search: relevant API"))
                 ((role . "assistant") (class . "answer")
                  (text . "The tools confirm the current flow."))
                 ((role . "hook-feedback") (class . "hook-feedback") (text . ,feedback))
                 ((role . "assistant") (class . "answer")
                  (text . "The implementation looks correct.")))
               workspace)
            (setq loaded (buffer-substring-no-properties (point-min) (point-max))))

          ;; Then reloading reproduces the minimal live transcript exactly.
          (should (equal loaded live)))
      (faltoo-request--clear-pending-answer workspace)
      (when (get-buffer (faltoo-chat-buffer-name-for workspace))
        (kill-buffer (faltoo-chat-buffer-name-for workspace)))
      (delete-directory workspace t))))


(ert-deftest faltoo-chat-finish-stream-appends-next-prompt-without-refreshing-history ()
  "Scenario: Completed streams stay in-place and add the next user turn."
  (faltoo-test--kill-chat-buffer)
  ;; Given a stream is active in the transcript.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-chat-append-stream "streamed answer")

  ;; When the stream finishes.
  (cl-letf (((symbol-function 'faltoo-bridge-messages)
             (lambda (&rest _args)
               (error "Transcript should not refresh after streaming"))))
    (faltoo-chat-finish-stream))

  ;; Then the assistant heading is finalized and a fresh user prompt is appended.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "# Assistant\n\nstreamed answer\n\n---\n# User\n\n$" (buffer-string)))
    (should-not (string-match-p "Assistant · answering" (buffer-string)))))

(ert-deftest faltoo-chat-finish-stream-preserves-reader-position ()
  "Scenario: Finishing a stream appends footer text without dragging the transcript view."
  (faltoo-test--kill-chat-buffer)
  ;; Given the reader is looking at the top of a visible transcript while a stream is active.
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "old prompt"))
                                   ((role . "assistant")
                                    (text . "old answer\nline 2\nline 3\nline 4"))))))
    (with-current-buffer buf
      (faltoo-chat-start-stream "Assistant · answering")
      (faltoo-chat-append-stream "new answer"))
    (delete-other-windows)
    (switch-to-buffer buf)
    (goto-char (point-min))
    (set-window-start (selected-window) (point-min))

    ;; When the stream finishes.
    (faltoo-chat-finish-stream nil 1.2 nil)

    ;; Then the visible transcript position stays where the reader left it.
    (should (= (point) (point-min)))
    (should (= (window-point) (point-min)))
    (should (= (window-start) (point-min)))))

(ert-deftest faltoo-chat-finish-stream-shows-elapsed-time-in-footer ()
  "Scenario: Completed streams show how long the assistant took in the footer."
  (faltoo-test--kill-chat-buffer)
  ;; Given a stream is active in the transcript.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-chat-append-stream "streamed answer")

  ;; When the stream finishes with elapsed time.
  (faltoo-chat-finish-stream nil 20.0)

  ;; Then the assistant heading stays clean and duration appears before the next prompt.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "# Assistant\n\nstreamed answer\n\n> Assistant took: 20.0s\n\n---\n# User\n\n$" (buffer-string)))
    (should-not (string-match-p "# Assistant · 20.0s" (buffer-string)))))

(ert-deftest faltoo-chat-finish-stream-shows-codex-limit-in-footer ()
  "Scenario: Completed streams can include the latest Codex remaining limit."
  (faltoo-test--kill-chat-buffer)
  ;; Given a stream is active in the transcript.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-chat-append-stream "streamed answer")

  ;; When the stream finishes with a captured rate-limit event.
  (faltoo-chat-finish-stream nil 20.0 "Remaining limit: 5h = 98%")

  ;; Then the duration and usage sit together in the assistant footer.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "streamed answer\n\n> Assistant took: 20.0s\n> Remaining limit: 5h = 98%\n\n---\n# User" (buffer-string)))))

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

(ert-deftest faltoo-current-line-range-includes-bol-endpoint-in-both-directions ()
  "Scenario: A region endpoint at the next line start includes that full line."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     (dolist (direction '(forward reverse))
       ;; Given two lines are selected with point at a line beginning.
       (goto-char (point-min))
       (when (eq direction 'reverse)
         (forward-line 1))
       (set-mark (point))
       (forward-line (if (eq direction 'forward) 1 -1))
       (activate-mark)

       ;; When the shared Ask/comment source range is expanded.
       (let ((range (faltoo-current-line-range)))

         ;; Then both touched lines are included in either selection direction.
         (should (equal (nth 2 range) 1))
         (should (equal (nth 3 range) 2))
         (should (equal (nth 4 range) "one\ntwo")))))))

(ert-deftest faltoo-ask-uses-full-lines-for-active-region ()
  "Scenario: Ask expands a partial active region to complete source lines."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given text inside lines 1-3 is selected, not whole lines.
     (goto-char (point-min))
     (forward-char 1)
     (set-mark (point))
     (forward-line 2)
     (forward-char 2)
     (activate-mark)

     ;; When Ask builds context.
     (let ((context (faltoo-ask--context)))

       ;; Then the snippet contains complete lines 1-3.
       (should (equal (plist-get context :start) 1))
       (should (equal (plist-get context :end) 3))
       (should (equal (plist-get context :code) "one\ntwo\nthree"))))))

(ert-deftest faltoo-comment-uses-full-lines-for-active-region ()
  "Scenario: Review comments expand a partial active region to complete source lines."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given text inside lines 2-3 is selected, not whole lines.
     (goto-char (point-min))
     (forward-line 1)
     (forward-char 1)
     (set-mark (point))
     (forward-line 1)
     (forward-char 2)
     (activate-mark)

     ;; When comment range is built.
     (let ((range (faltoo-comments--range)))

       ;; Then the comment snippet contains complete lines 2-3.
       (should (equal (nth 2 range) 2))
       (should (equal (nth 3 range) 3))
       (should (equal (nth 4 range) "two\nthree"))))))

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

(ert-deftest faltoo-ask-recomputes-current-line-each-time ()
  "Scenario: Ask always starts from the current source context."
  (faltoo-test--with-temp-git-file
   '("one" "two")
   (lambda (_file _root)
     ;; Given Ask is opened on the first line.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (goto-char (point-min))
       (faltoo-ask)
       (with-current-buffer "*Faltoo Popup*"
         (should (string-match-p "```python\none\n```" (buffer-string))))

       ;; When Ask is opened again on another line.
       (goto-char (point-min))
       (forward-line 1)
       (faltoo-ask)

       ;; Then the popup is rebuilt from the new source context.
       (with-current-buffer "*Faltoo Popup*"
         (should (string-match-p "```python\ntwo\n```" (buffer-string)))
         (should-not (string-match-p "```python\none\n```" (buffer-string))))))))

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

(ert-deftest faltoo-ask-send-deactivates-source-selection ()
  "Scenario: Submitting Ask clears the selected source region."
  (faltoo-test--with-temp-git-file
   '("one" "two")
   (lambda (_file _root)
     ;; Given Ask was opened from an active source selection.
     (let ((source (current-buffer))
           (source-window (selected-window)))
       (goto-char (point-min))
       (set-mark (point))
       (forward-line 1)
       (activate-mark)
       (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
         (faltoo-ask))

       ;; When the popup question is submitted.
       (with-current-buffer "*Faltoo Popup*"
         (setq faltoo-popup-return-window source-window)
         (insert "explain this")
         (cl-letf (((symbol-function 'faltoo-request-message)
                    (lambda (_message _popup _on-done) nil)))
           (faltoo-ask-send)))

       ;; Then returning to the source buffer will not leave the region selected.
       (with-current-buffer source
         (should-not mark-active))))))

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
       (should (string-match-p "```python\none\n```" captured-message))
       (should (string-match-p "second question" captured-message))))))

(ert-deftest faltoo-ask-stream-routes-answer-to-popup-and-transcript ()
  "Scenario: Ask responses stream near code and into transcript history."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given a mocked bridge stream that emits status, answer, and done events.
     (setq faltoo-review-files nil
           faltoo-last-assistant-message "")
     (faltoo-test--kill-chat-buffer)
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
                  (lambda (&optional _turns _workspace) '(((role . "assistant") (text . "hello from assistant")))))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))
         (faltoo-request-message "question" popup))

       ;; Then latest response, popup, and transcript all receive the answer.
       (should (equal faltoo-last-assistant-message "hello from assistant"))
       (with-current-buffer popup
         (should (string-match-p "> Submitted message\n\nhello from assistant" (buffer-string)))
         (goto-char (point-min))
         (search-forward "hello from assistant")
         (should-not (eq (get-text-property (match-beginning 0) 'face) 'faltoo-popup-assistant-face)))
       (with-current-buffer (faltoo-test--chat-buffer-name)
         (should (string-match-p "hello from assistant" (buffer-string))))
       (kill-buffer popup)))))

(ert-deftest faltoo-ask-stream-shows-codex-limit-before-follow-up ()
  "Scenario: Ask popups show the latest Codex limit before the next follow-up prompt."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-test--kill-chat-buffer)
     (let ((popup (faltoo-popup-buffer "*Faltoo Test Popup*" #'faltoo-ask-mode))
           (faltoo-request-rate-limits (make-hash-table :test #'equal)))
       (with-current-buffer popup (erase-buffer))

       ;; Given an Ask response receives a rate-limit event.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args _payload on-event on-done)
                    (funcall on-event '((classes . "rate-limit") (text . "Remaining limit: 5h = 98%")))
                    (funcall on-event '((classes . "answer") (text . "popup answer")))
                    (funcall on-done t)))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))

         ;; When the popup request completes and installs its follow-up section.
         (faltoo-request-message
          "question" popup
          (lambda (_ok)
            (with-current-buffer popup
              (faltoo-ask--insert-follow-up)))))

       ;; Then the usage footer is visible before the editable follow-up area.
       (with-current-buffer popup
         (goto-char (point-min))
         (let ((answer (search-forward "popup answer"))
               (limit (search-forward "> Remaining limit: 5h = 98%"))
               (follow-up (search-forward "## Follow-up")))
           (should (< answer limit))
           (should (< limit follow-up))))
       (kill-buffer popup)))))

;;; Request specs

(ert-deftest faltoo-request-message-records-source-prompt-in-transcript ()
  "Scenario: Source-buffer prompts are written to transcript before assistant output."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-test--kill-chat-buffer)
     ;; Given the bridge will immediately stream an assistant answer.
     (cl-letf (((symbol-function 'faltoo-bridge-stream)
                (lambda (_args _payload on-event on-done)
                  (funcall on-event '((classes . "answer") (text . "assistant answer")))
                  (funcall on-done t)))
               ((symbol-function 'ding) (lambda (&rest _args) nil)))

       ;; When a source-buffer request is sent.
       (faltoo-request-message "source question"))

     ;; Then the transcript contains the source prompt before the assistant response.
     (with-current-buffer (faltoo-test--chat-buffer-name)
       (should (string-match-p
                "# User\n\nsource question\n\n---\n# Assistant"
                (buffer-string)))))))


(ert-deftest faltoo-request-review-formats-transcript-comments-as-response-comments ()
  "Scenario: Transcript comments read as direct response comments, not source reviews."
  (let ((prompt (faltoo-request--review-prompt
                 '(((filename . "Faltoo transcript")
                    (line_number_start . 2291)
                    (line_number_end . 2295)
                    (file_line_number_start . 2291)
                    (file_line_number_end . 2295)
                    (code . "assistant text")
                    (comment . "follow up"))))))
    ;; Given a pending comment targets transcript text.

    ;; Then the prompt keeps only the response excerpt and comment.
    (should (string-match-p "Your response:\n\n```\nassistant text\n```" prompt))
    (should-not (string-match-p "Comments in code review" prompt))
    (should-not (string-match-p "File name" prompt))
    (should-not (string-match-p "Faltoo transcript" prompt))
    (should-not (string-match-p "### Line" prompt))
    (should-not (string-match-p "Code:" prompt))))

(ert-deftest faltoo-generic-chat-comments-use-generic-workspace-queue ()
  "Scenario: Generic chat comments remain attached to the generic chat workspace."
  (let* ((parent (file-name-as-directory (make-temp-file "faltoo-generic-comments" t)))
         (workspace (expand-file-name "quick-chat/" parent))
         (faltoo-generic-chat-directory workspace)
         (faltoo-generic-chat-workspace-cache nil)
         (faltoo-comments (make-hash-table :test #'equal))
         (faltoo-submitting-workspaces (make-hash-table :test #'equal))
         (faltoo-submitting nil)
         submitted-workspace)
    (unwind-protect
        (progn
          ;; Given the generic chat directory lives under an unrelated Git repo.
          (make-directory (expand-file-name ".git" parent))
          (faltoo-set-workspace-submitting (file-name-as-directory (file-truename parent)) t)
          (setq workspace (faltoo-generic-chat-workspace))
          (let ((chat (faltoo-chat-buffer workspace)))
            (with-current-buffer chat
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert "assistant response\n"))
              (goto-char (point-min))

              ;; When a transcript comment is saved and submitted.
              (faltoo-test--without-popup-display
               (lambda ()
                 (faltoo-comment)
                 (with-current-buffer "*Faltoo Comment*"
                   (goto-char (point-max))
                   (insert "follow up")
                   (faltoo-comment-save))))
              (cl-letf (((symbol-function 'faltoo-chat-append-user-message) #'ignore)
                        ((symbol-function 'faltoo-request-stream)
                         (lambda (_args payload _title _popup on-submitted _on-done)
                           (setq submitted-workspace (alist-get 'workspace payload))
                           (funcall on-submitted))))
                (faltoo-submit-review-comments)))

            ;; Then it is submitted from the generic queue, not the busy parent repo.
            (should (equal submitted-workspace workspace))
            (should-not (faltoo-comments--list workspace))
            (should-not (faltoo-comments--list parent))))
      (when (get-buffer "*Faltoo Chat*")
        (kill-buffer "*Faltoo Chat*"))
      (when (get-buffer "*Faltoo Comment*")
        (kill-buffer "*Faltoo Comment*"))
      (delete-directory parent t))))

(ert-deftest faltoo-submit-review-comments-uses-current-workspace-queue ()
  "Scenario: Submitting comments sends only the current repo's pending comments."
  (let* ((root-a (file-name-as-directory (make-temp-file "faltoo-comments-a" t)))
         (root-b (file-name-as-directory (make-temp-file "faltoo-comments-b" t)))
         (faltoo-comments (make-hash-table :test #'equal))
         submitted)
    (unwind-protect
        (progn
          ;; Given two workspaces have independent pending comments.
          (make-directory (expand-file-name ".git" root-a))
          (make-directory (expand-file-name ".git" root-b))
          (faltoo-comments--set
           (list (make-faltoo-comment :file "a.py" :path "a.py" :start 1 :end 1 :code "a" :text "from a"))
           root-a)
          (faltoo-comments--set
           (list (make-faltoo-comment :file "b.py" :path "b.py" :start 1 :end 1 :code "b" :text "from b"))
           root-b)

          ;; When comments are submitted from workspace B.
          (let ((default-directory root-b))
            (cl-letf (((symbol-function 'faltoo-request-review)
                       (lambda (comments on-submitted &optional _on-done _workspace)
                         (setq submitted comments)
                         (funcall on-submitted))))
              (faltoo-submit-review-comments)))

          ;; Then only workspace B comments are sent and workspace A remains pending.
          (should (equal (mapcar (lambda (comment) (alist-get 'filename comment)) submitted)
                         '("b.py")))
          (should (= (faltoo-comments-count root-a) 1))
          (should-not (faltoo-comments--list root-b)))
      (delete-directory root-a t)
      (delete-directory root-b t))))

(ert-deftest faltoo-submit-review-comments-preserves-insertion-order ()
  "Scenario: Submitted review comments keep the order they were added."
  (let* ((first (make-faltoo-comment :file "sample.py" :path "sample.py" :start 3 :end 3 :code "three" :text "first"))
         (second (make-faltoo-comment :file "sample.py" :path "sample.py" :start 7 :end 7 :code "seven" :text "second"))
         (third (make-faltoo-comment :file "sample.py" :path "sample.py" :start 1 :end 1 :code "one" :text "third"))
         (faltoo-comments (make-hash-table :test #'equal))
         submitted)
    ;; Given pending comments are stored newest-first internally after line 3, 7, then 1 were added.
    (faltoo-comments--set (list third second first))

    ;; When comments are submitted.
    (cl-letf (((symbol-function 'faltoo-request-review)
               (lambda (comments _on-submitted &optional _on-done _workspace)
                 (setq submitted comments))))
      (faltoo-submit-review-comments))

    ;; Then the payload uses insertion order, not newest-first storage order.
    (should (equal (mapcar (lambda (comment) (alist-get 'line_number_start comment)) submitted)
                   '(3 7 1)))))

(ert-deftest faltoo-request-review-records-review-prompt-in-transcript ()
  "Scenario: Review submissions write the user review prompt to the transcript."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-test--kill-chat-buffer)
     ;; Given the bridge will immediately stream the review answer.
     (cl-letf (((symbol-function 'faltoo-bridge-stream)
                (lambda (_args _payload on-event on-done)
                  (funcall on-event '((classes . "answer") (text . "review answer")))
                  (funcall on-done t)))
               ((symbol-function 'ding) (lambda (&rest _args) nil)))

       ;; When review comments are submitted.
       (faltoo-request-review
        '(((filename . "sample.py")
           (line_number_start . 2)
           (line_number_end . 3)
           (file_line_number_start . 20)
           (file_line_number_end . 21)
           (code . "changed code")
           (comment . "please fix this")))
        (lambda () nil)))

     ;; Then the transcript shows the same user prompt sent to FaltooBot.
     (with-current-buffer (faltoo-test--chat-buffer-name)
       (should (string-match-p "# User\n\n# Comments in code review" (buffer-string)))
       (should (string-match-p "## File name `sample.py`" (buffer-string)))
       (should (string-match-p "### Line `20-21`" (buffer-string)))
       (should (string-match-p "```\nchanged code\n```" (buffer-string)))
       (should (string-match-p "Comment:\nplease fix this" (buffer-string)))
       (should (string-match-p "---\n# Assistant" (buffer-string)))))))

(ert-deftest faltoo-request-rejects-overlapping-streams-in-same-workspace ()
  "Scenario: Faltoo does not start a second request in the same repo session."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file root)
     (let ((faltoo-submitting nil)
           (faltoo-submitting-workspaces (make-hash-table :test #'equal))
           (bridge-called nil))
       ;; Given a Faltoo request is already running for this workspace.
       (puthash (file-truename root) t faltoo-submitting-workspaces)

       ;; When another message is submitted from the same workspace.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (&rest _args) (setq bridge-called t))))
         ;; Then the request is rejected before touching the bridge.
         (should-error (faltoo-request-message "second request") :type 'user-error)
         (should-not bridge-called))))))

(ert-deftest faltoo-request-allows-parallel-streams-in-different-workspaces ()
  "Scenario: Running one repo session does not block prompts in another repo."
  (faltoo-test--with-two-temp-git-files
   (lambda (file-a root-a file-b root-b)
     (let ((faltoo-submitting nil)
           (faltoo-submitting-workspaces (make-hash-table :test #'equal))
           (started-workspaces nil))
       ;; Given bridge streams stay running until the test ends.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args payload _on-event _on-done)
                    (push (alist-get 'workspace payload) started-workspaces))))

         ;; When a request starts in repo A and another starts in repo B.
         (with-current-buffer (find-file-noselect file-a)
           (faltoo-request-message "from repo a"))
         (with-current-buffer (find-file-noselect file-b)
           (faltoo-request-message "from repo b")))

       ;; Then both workspace sessions were allowed to start.
       (should (equal (sort started-workspaces #'string<)
                      (sort (list (file-truename root-a) (file-truename root-b)) #'string<)))))))

(ert-deftest faltoo-request-cancel-stops-current-workspace-process ()
  "Scenario: Cancelling a running request stops the bridge process for this workspace."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file root)
     (let ((faltoo-submitting nil)
           (faltoo-submitting-workspaces (make-hash-table :test #'equal))
           (faltoo-request-processes (make-hash-table :test #'equal))
           (faltoo-request-cancelled (make-hash-table :test #'equal))
           cancelled-process done)
       ;; Given a request is running for the current workspace.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args _payload _on-event on-done)
                    (setq done on-done)
                    'bridge-process))
                 ((symbol-function 'faltoo-bridge-cancel-stream)
                  (lambda (process) (setq cancelled-process process))))
         (faltoo-request-message "question")

         ;; When cancelling it.
         (faltoo-request-cancel (file-truename root))

         ;; Then the bridge process is cancelled and the workspace is marked cancelled.
         (should (eq cancelled-process 'bridge-process))
         (should (gethash (file-truename root) faltoo-request-cancelled))

         ;; When the bridge sentinel reports completion after cancellation.
         (cl-letf (((symbol-function 'ding) (lambda (&rest _args) nil)))
           (funcall done nil))

         ;; Then the workspace is idle and the status reflects cancellation.
         (should-not (faltoo-workspace-submitting-p (file-truename root)))
         (should-not (gethash (file-truename root) faltoo-request-processes))
         (should (equal faltoo-status "Faltoo cancelled")))))))

(ert-deftest faltoo-request-completion-clears-only-that-workspace ()
  "Scenario: Completing one repo stream leaves other repo streams running."
  (faltoo-test--with-two-temp-git-files
   (lambda (file-a root-a file-b root-b)
     (let ((faltoo-submitting nil)
           (faltoo-submitting-workspaces (make-hash-table :test #'equal))
           done-a done-b)
       ;; Given two repo requests are running.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args payload _on-event on-done)
                    (if (string= (alist-get 'workspace payload) (file-truename root-a))
                        (setq done-a on-done)
                      (setq done-b on-done))))
                 ((symbol-function 'ding) (lambda (&rest _args) nil)))
         (with-current-buffer (find-file-noselect file-a)
           (faltoo-request-message "from repo a"))
         (with-current-buffer (find-file-noselect file-b)
           (faltoo-request-message "from repo b"))

         ;; When repo A finishes.
         (funcall done-a t)

         ;; Then repo A is idle and repo B is still marked running.
         (should-not (faltoo-workspace-submitting-p (file-truename root-a)))
         (should (faltoo-workspace-submitting-p (file-truename root-b)))
         (funcall done-b t))))))

(ert-deftest faltoo-request-renders-stream-errors-in-popup-and-transcript ()
  "Scenario: Bridge failures are visible in the UI instead of only the message area."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (faltoo-test--kill-chat-buffer)
     (let ((popup (get-buffer-create "*Faltoo Test Popup*")))
       (with-current-buffer popup (erase-buffer))

       ;; Given the bridge reports a stream error and fails the request.
       (cl-letf (((symbol-function 'faltoo-bridge-stream)
                  (lambda (_args _payload on-event on-done)
                    (funcall on-event '((classes . "error")
                                        (text . "OpenAI websocket closed")))
                    (funcall on-done nil))))

         ;; When a popup-backed request runs.
         (faltoo-request-message "question" popup))

       ;; Then the error is visible near code and in the transcript.
       (should (equal faltoo-status "Faltoo failed"))
       (with-current-buffer popup
         (should (string-match-p "> Error: OpenAI websocket closed" (buffer-string))))
       (with-current-buffer (faltoo-test--chat-buffer-name)
         (should (string-match-p "> Error: OpenAI websocket closed" (buffer-string)))
         (goto-char (point-min))
         (search-forward "OpenAI websocket closed")
         (should (cl-some (lambda (overlay)
                            (eq (overlay-get overlay 'face) 'faltoo-chat-error-face))
                          (overlays-at (point)))))
       (kill-buffer popup)))))

(ert-deftest faltoo-request-batches-answer-stream-appends ()
  "Scenario: Answer chunks are queued and inserted in one UI append."
  (let ((workspace (faltoo-workspace))
        (popup (get-buffer-create "*Faltoo Batch Popup*"))
        chat-appends popup-appends)
    (unwind-protect
        (cl-letf (((symbol-function 'faltoo-chat-append-stream)
                   (lambda (text _workspace) (push text chat-appends)))
                  ((symbol-function 'faltoo-popup-append-stream)
                   (lambda (_buffer text) (push text popup-appends))))

          ;; When several answer chunks arrive before the flush timer runs.
          (faltoo-request--route-event '((classes . "answer") (text . "one")) workspace popup nil)
          (faltoo-request--route-event '((classes . "answer") (text . " two")) workspace popup nil)
          (faltoo-request--route-event '((classes . "answer") (text . " three")) workspace popup nil)

          ;; Then the transcript and popup are not mutated per chunk.
          (should-not chat-appends)
          (should-not popup-appends)

          ;; When the queued stream is flushed.
          (faltoo-request--flush-answer workspace)

          ;; Then each UI gets one combined append.
          (should (equal chat-appends '("one two three")))
          (should (equal popup-appends '("one two three"))))
      (faltoo-request--clear-pending-answer workspace)
      (when (buffer-live-p popup) (kill-buffer popup)))))

(ert-deftest faltoo-request-renders-status-events-as-compact-quotes ()
  "Scenario: Streaming status/tool blocks are compact Markdown quotes."
  (faltoo-test--kill-chat-buffer)
  ;; Given a chat stream is active.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When status events are routed into the transcript.
  (faltoo-request--route-event '((classes . "status") (text . "first block")) (faltoo-workspace) nil nil)
  (faltoo-request--route-event '((classes . "tool") (text . "second block")) (faltoo-workspace) nil nil)

  ;; Then status/tool blocks are quoted without blank lines between them and have a tool face.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "> first block\n> second block\n" (buffer-string)))
    (should-not (string-match-p "> first block\n\n> second block" (buffer-string)))
    (goto-char (point-min))
    (search-forward "first block")
    (should (cl-some (lambda (overlay)
                       (eq (overlay-get overlay 'face) 'faltoo-chat-tool-face))
                     (overlays-at (point))))))


(ert-deftest faltoo-request-separates-answer-text-from-following-tool-quotes ()
  "Scenario: Tool calls after assistant text start on their own quoted line."
  (faltoo-test--kill-chat-buffer)
  ;; Given assistant text has started streaming without a trailing newline.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-request--route-event '((classes . "answer") (text . "I will inspect this.")) (faltoo-workspace) nil nil)

  ;; When a tool call follows that assistant text.
  (faltoo-request--route-event '((classes . "tool") (text . "Shell: inspect files")) (faltoo-workspace) nil nil)

  ;; Then the transcript starts the tool quote on a fresh line.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "I will inspect this\.\n\n> Shell: inspect files" (buffer-string)))
    (should-not (string-match-p "this\.> Shell" (buffer-string)))))

(ert-deftest faltoo-popup-separates-answer-text-from-following-tool-quotes ()
  "Scenario: Popup tool calls after assistant text start on their own quoted line."
  (let ((buf (faltoo-popup-buffer "*Faltoo Popup Tool Spacing Test*" #'faltoo-popup-mode)))
    (unwind-protect
        (progn
          ;; Given assistant text has streamed into a popup without a trailing newline.
          (faltoo-popup-append-stream buf "I will inspect this.")

          ;; When a tool call follows that assistant text.
          (faltoo-popup-append-stream-block buf "Shell: inspect files")

          ;; Then the popup starts the tool quote on a fresh line.
          (with-current-buffer buf
            (should (string-match-p "I will inspect this\.\n\n> Shell: inspect files" (buffer-string)))
            (should-not (string-match-p "this\.> Shell" (buffer-string)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


(ert-deftest faltoo-popup-stream-block-face-uses-priority-overlay ()
  "Scenario: Live popup hook feedback face wins over Markdown quote styling."
  (let ((buf (faltoo-popup-buffer "*Faltoo Popup Hook Face Test*" #'faltoo-popup-mode)))
    (unwind-protect
        (progn
          ;; Given a hook feedback block is appended to a live popup stream.
          (faltoo-popup-append-stream-block buf "Hook feedback body" 'faltoo-chat-hook-feedback-face)

          ;; Then the block has a high-priority face overlay, not only a text property.
          (with-current-buffer buf
            (goto-char (point-min))
            (search-forward "Hook feedback body")
            (let ((hook-overlay (cl-find-if
                                 (lambda (overlay)
                                   (eq (overlay-get overlay 'face) 'faltoo-chat-hook-feedback-face))
                                 (overlays-at (point)))))
              (should hook-overlay)
              (should (> (overlay-get hook-overlay 'priority) 0)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest faltoo-popup-separates-answer-text-after-tool-quotes ()
  "Scenario: Popup assistant text after tool blocks starts after a blank line."
  (let ((buf (faltoo-popup-buffer "*Faltoo Popup Tool Answer Spacing Test*" #'faltoo-popup-mode)))
    (unwind-protect
        (progn
          ;; Given assistant text and a tool block are already in the popup stream.
          (faltoo-popup-append-stream buf "Initial answer.")
          (faltoo-popup-append-stream-block buf "Post-Response Hook Feedback: Refactor Code")

          ;; When assistant text continues after the tool block.
          (faltoo-popup-append-stream buf "Hook fired and returned feedback.")

          ;; Then the next answer starts after a blank line.
          (with-current-buffer buf
            (should (string-match-p "> Post-Response Hook Feedback: Refactor Code\n\nHook fired" (buffer-string)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest faltoo-request-separates-tool-quotes-from-final-answer ()
  "Scenario: Final answer text starts after a blank line following compact tool calls."
  (faltoo-test--kill-chat-buffer)
  ;; Given tool/status blocks are already in the streaming assistant section.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-request--route-event '((classes . "status") (text . "first block")) (faltoo-workspace) nil nil)
  (faltoo-request--route-event '((classes . "tool") (text . "second block")) (faltoo-workspace) nil nil)

  ;; When final answer text starts streaming and the batched answer flushes.
  (faltoo-request--route-event '((classes . "answer") (text . "final answer")) (faltoo-workspace) nil nil)
  (faltoo-request--flush-answer (faltoo-workspace))

  ;; Then the compact tool block is separated from the final answer body.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "> first block\n> second block\n\nfinal answer" (buffer-string)))))

(ert-deftest faltoo-request-renders-only-truncated-tool-summary ()
  "Scenario: Tool streams show FaltooChat-style summaries, not full command bodies."
  (faltoo-test--kill-chat-buffer)
  ;; Given a tool event contains a shell summary and hidden command body.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When the event is routed into the transcript.
  (faltoo-request--route-event
   '((classes . "tool")
     (text . "**Shell:** inspect files\n\n<!-- shell-command -->\n\nsed -n '1,999p' giant-file.el"))
   (faltoo-workspace) nil nil)

  ;; Then only the truncated summary is shown.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "Shell: inspect files" (buffer-string)))
    (should-not (string-match-p "giant-file" (buffer-string)))))



(ert-deftest faltoo-request-renders-legacy-live-hook-feedback-prefix-with-dedicated-face ()
  "Scenario: Live hook feedback status text keeps distinct styling before bridge reload."
  (faltoo-test--kill-chat-buffer)
  ;; Given a chat stream is active.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When an old daemon emits hook feedback as a generic tool block.
  (faltoo-request--route-event
   '((classes . "tool") (text . "Post-Response Hook Feedback: Refactor Code

Hook notes"))
   (faltoo-workspace) nil nil)

  ;; Then it still uses the hook feedback face.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (goto-char (point-min))
    (search-forward "Refactor Code")
    (should (cl-some (lambda (overlay)
                       (eq (overlay-get overlay 'face) 'faltoo-chat-hook-feedback-face))
                     (overlays-at (point))))))

(ert-deftest faltoo-request-renders-hook-feedback-class-with-dedicated-face ()
  "Scenario: Hook feedback stream events use a distinct face without content sniffing."
  (faltoo-test--kill-chat-buffer)
  ;; Given a chat stream is active.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When a hook-feedback event is routed into the transcript.
  (faltoo-request--route-event
   '((classes . "hook-feedback") (text . "Hook feedback body"))
   (faltoo-workspace) nil nil)

  ;; Then it is quoted and highlighted separately from tool calls.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "> Hook feedback body" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Hook feedback body")
    (let ((hook-overlay (cl-find-if
                         (lambda (overlay)
                           (eq (overlay-get overlay 'face) 'faltoo-chat-hook-feedback-face))
                         (overlays-at (point)))))
      (should hook-overlay)
      (should (numberp (overlay-get hook-overlay 'priority)))
      (should (> (overlay-get hook-overlay 'priority) 0)))))

(ert-deftest faltoo-request-renders-full-post-response-hook-feedback ()
  "Scenario: Post-response hook feedback is inserted as full Markdown."
  (faltoo-test--kill-chat-buffer)
  ;; Given full hook feedback has more lines than normal tool summaries keep.
  (faltoo-chat-start-stream "Assistant · answering")

  ;; When the feedback is routed into the transcript.
  (faltoo-request--route-event
   '((classes . "tool")
     (text . "## Post-response hook feedback\n\n### Refactor Code\n\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6"))
   (faltoo-workspace) nil nil)

  ;; Then the full Markdown is quoted, untruncated, and wrapped as its own block.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "> ────────────────\n> ## Post-response hook feedback" (buffer-string)))
    (should (string-match-p "> line 6\n> ────────────────" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Refactor Code")
    (should (cl-some (lambda (overlay)
                       (eq (overlay-get overlay 'face) 'faltoo-chat-hook-feedback-face))
                     (overlays-at (point))))
    (should-not (string-match-p (regexp-quote "...") (buffer-string)))))

(ert-deftest faltoo-request-separates-answer-text-after-post-response-hook-feedback ()
  "Scenario: Assistant text after post-response hook feedback starts after a blank line."
  (faltoo-test--kill-chat-buffer)
  ;; Given assistant text already streamed before hook feedback.
  (faltoo-chat-start-stream "Assistant · answering")
  (faltoo-request--route-event '((classes . "answer") (text . "Previous answer.")) (faltoo-workspace) nil nil)
  (faltoo-request--flush-answer (faltoo-workspace))

  ;; When hook feedback arrives and follow-up assistant text starts.
  (faltoo-request--route-event
   '((classes . "tool")
     (text . "## Post-response hook feedback\n\n### Refactor Code\n\nFull feedback."))
   (faltoo-workspace) nil nil)
  (faltoo-request--route-event '((classes . "answer") (text . "Hook fired and returned feedback.")) (faltoo-workspace) nil nil)
  (faltoo-request--flush-answer (faltoo-workspace))

  ;; Then the hook feedback is separated from both assistant sections.
  (with-current-buffer (faltoo-test--chat-buffer-name)
    (should (string-match-p "Previous answer\.\n\n> ────────────────\n> ## Post-response hook feedback" (buffer-string)))
    (should (string-match-p "> Full feedback\.\n> ────────────────\n\nHook fired" (buffer-string)))))

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
    (should (equal (buffer-string) "---\n## Question\n\n"))))


(ert-deftest faltoo-popup-section-rules-have-markdown-paragraph-boundaries ()
  "Scenario: Popup section rules are separated from preceding body text."
  (with-temp-buffer
    ;; When a section is inserted after typed body text.
    (insert "typed prompt")
    (faltoo-compose-insert-section "Assistant")

    ;; Then Markdown sees the rule as its own block, not part of the prompt.
    (should (equal (buffer-string) "typed prompt\n\n---\n## Assistant\n\n"))))

(ert-deftest faltoo-popup-section-body-starts-after-heading-boundary ()
  "Scenario: Typed popup text starts outside the heading line."
  (with-temp-buffer
    ;; When typing after a compact popup section.
    (faltoo-compose-insert-section "Follow-up")
    (insert "typed prompt")

    ;; Then the body is separated from the heading by one Markdown boundary line.
    (should (string-match-p "## Follow-up\n\ntyped prompt" (buffer-string)))))



(ert-deftest faltoo-ask-follow-up-insertion-preserves-reader-position ()
  "Scenario: Adding a popup follow-up after completion does not scroll the reader."
  (let ((buf (faltoo-popup-buffer "*Faltoo Followup Scroll Test*" #'faltoo-ask-mode)))
    (unwind-protect
        (progn
          ;; Given the reader is looking at the top of an answered popup.
          (with-current-buffer buf
            (insert "# Ask Faltoo\n\nanswer\nline 2\nline 3\nline 4")
            (goto-char (point-min)))
          (let ((window (display-buffer buf)))
            (select-window window)
            (set-window-point window (point-min))
            (set-window-start window (point-min))

            ;; When the follow-up section is added after completion.
            (with-current-buffer buf
              (faltoo-ask--insert-follow-up))

            ;; Then the visible popup position stays where the reader left it.
            (should (= (point) (point-min)))
            (should (= (window-point window) (point-min)))
            (should (= (window-start window) (point-min)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest faltoo-request-popup-completion-preserves-reader-position ()
  "Scenario: Completing a popup response does not drag the popup reader to the bottom."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     (let ((popup (faltoo-popup-buffer "*Faltoo Popup Finish Scroll Test*" #'faltoo-popup-mode)))
       (unwind-protect
           (progn
             ;; Given the reader is looking at the top of a visible popup.
             (with-current-buffer popup
               (insert "# Ask Faltoo\n\nold answer\nline 2\nline 3\nline 4")
               (goto-char (point-min)))
             (let ((window (display-buffer popup)))
               (select-window window)
               (set-window-point window (point-min))
               (set-window-start window (point-min))

               ;; When the answer finishes streaming.
               (cl-letf (((symbol-function 'faltoo-bridge-stream)
                          (lambda (_args _payload on-event on-done)
                            (funcall on-event '((classes . "answer") (text . "\nnew answer")))
                            (funcall on-done t)))
                         ((symbol-function 'ding) (lambda (&rest _args) nil)))
                 (faltoo-request-message "question" popup))

               ;; Then completion leaves the popup reader where it was.
               (should (= (point) (point-min)))
               (should (= (window-point window) (point-min)))
               (should (= (window-start window) (point-min)))))
         (when (buffer-live-p popup)
           (kill-buffer popup)))))))

(ert-deftest faltoo-popup-stream-preserves-reader-position ()
  "Scenario: Streaming popup text does not drag the reader to the bottom."
  (let ((buf (faltoo-popup-buffer "*Faltoo Popup Scroll Test*" #'faltoo-popup-mode)))
    (unwind-protect
        (progn
          ;; Given the reader is looking at the top of a visible popup.
          (with-current-buffer buf
            (insert "# Ask Faltoo\n\nold answer\nline 2\nline 3\nline 4")
            (goto-char (point-min)))
          (let ((window (display-buffer buf)))
            (set-window-point window (point-min))
            (set-window-start window (point-min))

            ;; When answer stream text is appended to the popup.
            (faltoo-popup-append-stream buf "new streamed text")

            ;; Then the reader's point and scroll position stay where they were.
            (should (= (window-point window) (point-min)))
            (should (= (window-start window) (point-min)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest faltoo-last-response-popup-renders-markdown-content ()
  "Scenario: Last response popup uses Markdown headings and an editable follow-up."
  (let ((workspace (faltoo-workspace)))
    (faltoo-test--kill-last-response-buffer workspace)
    ;; Given a latest assistant response exists for the current workspace.
    (puthash workspace "answer body" faltoo-last-assistant-messages)

    ;; When opening it without displaying the real posframe.
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))

    ;; Then the popup uses Markdown mode and starts in the follow-up prompt.
    (with-current-buffer (faltoo-last-response-buffer-name workspace)
      (should (derived-mode-p 'markdown-mode))
      (should (derived-mode-p 'faltoo-ask-mode))
      (should (string-match-p "# Last Assistant Response" (buffer-string)))
      (should (string-match-p "---\n## Assistant\n\nanswer body" (buffer-string)))
      (should (string-match-p "---\n## Follow-up\n\n" (buffer-string)))
      (should (= (point) faltoo-ask-question-marker)))))

(ert-deftest faltoo-last-response-popup-preserves-follow-up-draft-after-close ()
  "Scenario: Last response follow-up drafts survive closing and reopening the posframe."
  (let ((workspace (faltoo-workspace)))
    (faltoo-test--kill-last-response-buffer workspace)
    ;; Given the last response popup has an unsent follow-up draft.
    (puthash workspace "answer body" faltoo-last-assistant-messages)
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))
    (with-current-buffer (faltoo-last-response-buffer-name workspace)
      (insert "long follow-up draft"))

    ;; When opening the last response popup again.
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))

    ;; Then the existing follow-up text is still present.
    (with-current-buffer (faltoo-last-response-buffer-name workspace)
      (should (string-match-p "answer body" (buffer-string)))
      (should (string-match-p "long follow-up draft" (buffer-string)))
      (should (= (point) faltoo-ask-question-marker)))))

(ert-deftest faltoo-last-response-popup-keeps-draft-when-response-updates ()
  "Scenario: Last response popup keeps typed follow-up text when rendering a newer answer."
  (let ((workspace (faltoo-workspace)))
    (faltoo-test--kill-last-response-buffer workspace)
    ;; Given the last response popup has an unsent follow-up draft.
    (puthash workspace "older answer" faltoo-last-assistant-messages)
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))
    (with-current-buffer (faltoo-last-response-buffer-name workspace)
      (insert "long follow-up draft"))

    ;; When a newer answer becomes the latest response and the popup is reopened.
    (puthash workspace "newer answer" faltoo-last-assistant-messages)
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))

    ;; Then the displayed answer updates without dropping the typed follow-up.
    (with-current-buffer (faltoo-last-response-buffer-name workspace)
      (should (string-match-p "newer answer" (buffer-string)))
      (should (string-match-p "long follow-up draft" (buffer-string))))))

(ert-deftest faltoo-last-response-popup-sends-plain-follow-up-question ()
  "Scenario: Last response follow-up sends only the typed question."
  (let ((workspace (faltoo-workspace)) captured-message)
    (faltoo-test--kill-last-response-buffer workspace)
    ;; Given the last response popup is open with a typed follow-up.
    (puthash workspace "answer body" faltoo-last-assistant-messages)
    (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
      (faltoo-show-last-response))
    (with-current-buffer (faltoo-last-response-buffer-name workspace)
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


(ert-deftest faltoo-rendering-leaves-markdown-fontification-to-emacs ()
  "Scenario: Transcript and popup edits do not force synchronous font-lock refreshes."
  (let ((buf (faltoo-chat-render '(((role . "user") (text . "prompt"))
                                   ((role . "assistant") (text . "old answer")))))
        calls)
    ;; Given font-lock refreshes are observable.
    (cl-letf (((symbol-function 'font-lock-flush)
               (lambda (&rest args) (push (cons 'flush args) calls)))
              ((symbol-function 'font-lock-ensure)
               (lambda (&rest args) (push (cons 'ensure args) calls))))

      ;; When streaming text, finishing the stream, and adding popup follow-up UI.
      (with-current-buffer buf
        (faltoo-chat-start-stream "Assistant · answering")
        (faltoo-chat-append-stream "```text
hello
```")
        (faltoo-chat-finish-stream nil 1.2 nil))
      (let ((popup (faltoo-popup-buffer "*Faltoo No Manual Fontify Test*" #'faltoo-popup-mode)))
        (faltoo-popup-append popup "```text
hello
```" t))

      ;; Then rendering leaves Markdown fontification to normal Emacs redisplay.
      (should-not calls)
      (should-not (fboundp 'faltoo-ui-fontify-markdown)))))

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

(ert-deftest faltoo-comment-save-deactivates-source-selection ()
  "Scenario: Saving a review comment clears the selected source region."
  (faltoo-test--with-temp-git-file
   '("one" "two")
   (lambda (_file _root)
     ;; Given a comment popup was opened from an active source selection.
     (setq faltoo-comments (make-hash-table :test #'equal))
     (let ((source (current-buffer))
           (source-window (selected-window)))
       (goto-char (point-min))
       (set-mark (point))
       (forward-line 1)
       (activate-mark)
       (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
         (faltoo-comment))

       ;; When the comment is saved.
       (with-current-buffer "*Faltoo Comment*"
         (setq faltoo-popup-return-window source-window)
         (insert "please review this")
         (cl-letf (((symbol-function 'select-frame-set-input-focus) (lambda (&rest _args) nil)))
           (faltoo-comment-save)))

       ;; Then returning to the source buffer will not leave the region selected.
       (with-current-buffer source
         (should-not mark-active))))))

(ert-deftest faltoo-comment-save-marks-line-as-pending-review-comment ()
  "Scenario: Saving a line comment marks the source line."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given point is on line 2 and the comment popup is open.
     (setq faltoo-comments (make-hash-table :test #'equal))
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
     (should (= (faltoo-comments-count) 1))
     (let ((comment (car (faltoo-comments--list))))
       (should (equal (faltoo-comment-start comment) 2))
       (should (overlayp (faltoo-comment-overlay comment)))
       (should-not (overlay-get (faltoo-comment-overlay comment) 'before-string))))))

(ert-deftest faltoo-comment-cleared-while-editing-removes-source-highlight ()
  "Scenario: Clearing an existing comment removes its pending line highlight."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (_file _root)
     ;; Given line 2 has a saved pending comment and source highlight.
     (setq faltoo-comments (make-hash-table :test #'equal))
     (goto-char (point-min))
     (forward-line 1)
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-comment)
        (with-current-buffer "*Faltoo Comment*"
          (goto-char (point-max))
          (insert "remove this comment")
          (faltoo-comment-save))))
     (let* ((comment (car (faltoo-comments--list)))
            (overlay (faltoo-comment-overlay comment)))
       (should (overlay-buffer overlay))

       ;; When editing the comment, clearing its text, and saving.
       (faltoo-test--without-popup-display
        (lambda ()
          (faltoo-comment)
          (with-current-buffer "*Faltoo Comment*"
            (delete-region faltoo-comment-text-marker (point-max))
            (faltoo-comment-save))))

       ;; Then both the pending comment and its visible highlight are gone.
       (should-not (faltoo-comments--list))
       (should-not (overlay-buffer overlay))))))

(ert-deftest faltoo-file-comment-does-not-create-line-overlay ()
  "Scenario: File-level comments are pending but do not mark a line."
  (faltoo-test--with-temp-git-file
   '("one" "two")
   (lambda (_file _root)
     ;; Given no pending comments.
     (setq faltoo-comments (make-hash-table :test #'equal))

     ;; When saving a file-level review comment.
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-file-comment)
        (with-current-buffer "*Faltoo Comment*"
          (goto-char (point-max))
          (insert "file-level concern")
          (faltoo-comment-save))))

     ;; Then the comment exists but has no line overlay.
     (should (= (faltoo-comments-count) 1))
     (should (= (faltoo-comment-start (car (faltoo-comments--list))) 0))
     (should-not (faltoo-comment-overlay (car (faltoo-comments--list)))))))

(ert-deftest faltoo-comments-summary-renders-pending-comments ()
  "Scenario: Pending comments can be reviewed before submission."
  (let ((faltoo-comments (make-hash-table :test #'equal)))
    ;; Given there is a pending range comment.
    (faltoo-comments--set
     (list (make-faltoo-comment :file "sample.py"
                                :path "/repo/sample.py"
                                :start 2
                                :end 3
                                :text "tighten this up")))

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
     (let ((faltoo-comments (make-hash-table :test #'equal)))
       (faltoo-comments--set
        (list (make-faltoo-comment :file "sample.py"
                                   :path (file-truename file)
                                   :start 2
                                   :end 2
                                   :text "check this")))
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
       (faltoo-comments--set (list comment))
       (faltoo-comments-refresh)
       (goto-char (point-min))
       (forward-line 1)
       (let ((overlay (faltoo-comment-overlay comment)))
         (should (overlayp overlay))

         ;; When deleting the current pending comment.
         (faltoo-delete-current-comment)

         ;; Then the comment and overlay are gone.
         (should-not (faltoo-comments--list))
         (should-not (overlay-buffer overlay)))))))


(ert-deftest faltoo-chat-comment-uses-selected-transcript-lines ()
  "Scenario: Transcript selections can be queued as review comments."
  (let ((workspace (file-name-as-directory (make-temp-file "faltoo-chat-comment" t)))
        (faltoo-comments (make-hash-table :test #'equal)))
    (unwind-protect
        (let ((buf (faltoo-chat-render '(((role . "assistant")
                                          (text . "alpha\nbeta\ncharlie")))
                                        workspace)))
          ;; Given part of two transcript lines is selected.
          (with-current-buffer buf
            (goto-char (point-min))
            (search-forward "eta")
            (set-mark (point))
            (search-forward "char")
            (activate-mark)

            ;; When adding a Faltoo comment from the transcript.
            (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
              (faltoo-comment)))

          ;; Then the popup targets full transcript lines and can save a pending comment.
          (with-current-buffer "*Faltoo Comment*"
            (should (string-match-p "# Faltoo Transcript Comment" (buffer-string)))
            (should (string-match-p "```markdown\nbeta\ncharlie\n```" (buffer-string)))
            (insert "explain this answer")
            (faltoo-comment-save))

          (let ((comment (car (faltoo-comments--list workspace))))
            (should (equal (faltoo-comment-file comment) "Faltoo transcript"))
            (should (equal (faltoo-comment-code comment) "beta\ncharlie"))
            (should (equal (faltoo-comment-text comment) "explain this answer"))
            (should (eq (overlay-buffer (faltoo-comment-overlay comment)) buf))))
      (when (get-buffer (faltoo-chat-buffer-name-for workspace))
        (kill-buffer (faltoo-chat-buffer-name-for workspace)))
      (delete-directory workspace t))))

(ert-deftest faltoo-submit-review-comments-clears-transcript-comment-overlays ()
  "Scenario: Submitted transcript comments remove their transcript highlights."
  (let ((workspace (file-name-as-directory (make-temp-file "faltoo-chat-submit-comment" t)))
        (faltoo-comments (make-hash-table :test #'equal)))
    (unwind-protect
        (let* ((buf (faltoo-chat-render '(((role . "assistant") (text . "answer line"))) workspace))
               (comment (make-faltoo-comment :file "Faltoo transcript"
                                             :path (buffer-name buf)
                                             :start 3
                                             :end 3
                                             :code "answer line"
                                             :text "follow up here"
                                             :source-buffer buf)))
          ;; Given a pending transcript comment has marked its source line.
          (faltoo-comments--set (list comment))
          (faltoo-comments-refresh)
          (let ((overlay (faltoo-comment-overlay comment)))
            (should (overlayp overlay))

            ;; When the bridge accepts the submitted comment batch.
            (cl-letf (((symbol-function 'faltoo-request-review)
                       (lambda (_comments on-submitted &optional _on-done _workspace)
                         (funcall on-submitted))))
              (faltoo-submit-review-comments))

            ;; Then the submitted marker disappears from the transcript.
            (should-not (faltoo-comments--list workspace))
            (should-not (overlay-buffer overlay))))
      (when (get-buffer (faltoo-chat-buffer-name-for workspace))
        (kill-buffer (faltoo-chat-buffer-name-for workspace)))
      (delete-directory workspace t))))

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

(ert-deftest faltoo-comment-popup-uses-source-language-in-code-fence ()
  "Scenario: Comment popup code fences use the source buffer language."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given a Python source buffer.
     (cl-letf (((symbol-function 'faltoo-popup-show) (lambda (&rest _args) nil)))
       (faltoo-comment))

     ;; Then the selected code is shown in a Python Markdown fence.
     (with-current-buffer "*Faltoo Comment*"
       (should (string-match-p "```python\none\n```" (buffer-string)))))))

(ert-deftest faltoo-comment-empty-comment-does-not-capture-help-text ()
  "Scenario: Comment help text is not saved as a review comment."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (_file _root)
     ;; Given a comment popup is opened but no comment is typed.
     (setq faltoo-comments (make-hash-table :test #'equal))

     ;; When saving the empty popup.
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-comment)
        (with-current-buffer "*Faltoo Comment*"
          (faltoo-comment-save))))

     ;; Then no pending review comment is created.
     (should-not (faltoo-comments--list)))))

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

(ert-deftest faltoo-submit-review-comments-clears-submitted-overlays ()
  "Scenario: Submitted review comments remove their source highlights."
  (faltoo-test--with-temp-git-file
   '("one" "two" "three")
   (lambda (file _root)
     ;; Given a pending review comment has marked its source line.
     (let ((comment (make-faltoo-comment :file "sample.py"
                                         :path (file-truename file)
                                         :start 2
                                         :end 2
                                         :code "two"
                                         :text "review note")))
       (faltoo-comments--set (list comment))
       (faltoo-comments-refresh)
       (let ((overlay (faltoo-comment-overlay comment)))
         (should (overlayp overlay))

         ;; When the bridge accepts the submitted comment batch.
         (cl-letf (((symbol-function 'faltoo-request-review)
                    (lambda (_comments on-submitted &optional _on-done _workspace)
                      (funcall on-submitted))))
           (faltoo-submit-review-comments))

         ;; Then the submitted marker disappears from the source buffer.
         (should-not (faltoo-comments--list))
         (should-not (overlay-buffer overlay)))))))

(ert-deftest faltoo-submit-review-comments-sends-json-object-payload ()
  "Scenario: Review submission serializes a bridge-safe JSON payload."
  (let ((faltoo-comments (make-hash-table :test #'equal))
        captured-payload)
    ;; Given one pending review comment and a mocked request submitter.
    (faltoo-comments--set
     (list (make-faltoo-comment :file "faltoo.el"
                                :path "/repo/faltoo.el"
                                :start 1
                                :end 1
                                :code "code"
                                :text "review note")))
    (cl-letf (((symbol-function 'faltoo-request-review)
               (lambda (comments _on-submitted &optional _on-done _workspace)
                 (setq captured-payload
                       (list (cons 'workspace "/repo")
                             (cons 'comments (vconcat comments))))
                 (json-serialize captured-payload))))

      ;; When submitting pending review comments.
      (faltoo-submit-review-comments))

    ;; Then comments are encoded as a JSON array of objects.
    (should (equal (alist-get 'filename (aref (alist-get 'comments captured-payload) 0))
                   "faltoo.el"))))

(ert-deftest faltoo-review-buffer-name-follows-the-reviewed-file-repository ()
  "Scenario: Review buffer identity does not depend on the currently selected repo."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     (let ((default-directory (file-name-as-directory (make-temp-file "faltoo-other" t))))
       (unwind-protect
           (should (equal (faltoo-review-buffer-name file)
                          "*Faltoo Review: sample.py*"))
         (delete-directory default-directory t))))))

(ert-deftest faltoo-review-reads-the-complete-git-patch ()
  "Scenario: Review rendering consumes every line emitted by Git."
  (let ((patch "diff --git a/sample.py b/sample.py
@@ -1 +1 @@
-old
+new
"))
    ;; Given Magit inserts a complete multi-line patch.
    (cl-letf (((symbol-function 'magit-git-insert)
               (lambda (&rest _args)
                 (insert patch)
                 0)))

      ;; Then Faltoo returns the complete patch instead of Git's first line.
      (should (equal (faltoo-review--patch "sample.py") patch)))))

(ert-deftest faltoo-review-buffer-renders-full-file-with-inline-deletions ()
  "Scenario: Review buffers show removed and added rows inside the complete file."
  (faltoo-test--with-temp-git-file
   '("new value" "unchanged")
   (lambda (file _root)
     ;; Given Git reports the first working-tree line as a replacement.
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args)
                  "@@ -1 +1 @@
-old value
+new value")))

       ;; When Faltoo builds the generated review buffer.
       (let ((buf (faltoo-review-buffer file)))

         ;; Then it contains the full file with the removed row inserted.
         (with-current-buffer buf
           (should buffer-read-only)
           (should (equal (buffer-string) "old value
new value
unchanged
"))
           (font-lock-ensure)
           (goto-char (point-min))
           (should (eq (get-text-property (point) 'faltoo-review-line-type) 'delete))
           (should (eq (get-char-property (point) 'face) 'faltoo-diff-delete-line-face))
           (forward-line 1)
           (should (eq (get-text-property (point) 'faltoo-review-line-type) 'insert))
           (should (eq (get-char-property (point) 'face) 'faltoo-diff-insert-line-face))))))))

(ert-deftest faltoo-review-buffer-uses-source-file-for-comment-identity ()
  "Scenario: Generated and ordinary source buffers share one file comment list."
  (faltoo-test--with-temp-git-file
   '("changed")
   (lambda (file _root)
     ;; Given a generated review buffer represents the source file.
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1 +1 @@
-old
+changed")))
       (let ((buf (faltoo-review-buffer file)))

         ;; Then file identity remains the real source path for comment lookup.
         (with-current-buffer buf
           (should (equal (faltoo-current-file) (file-truename file)))))))))

(ert-deftest faltoo-review-comments-survive-generated-buffer-session ()
  "Scenario: Review comments remain attached to the source file after review stops."
  (faltoo-test--with-temp-git-file
   '("changed" "unchanged")
   (lambda (file root)
     ;; Given a generated review buffer contains a replacement row.
     (setq faltoo-comments (make-hash-table :test #'equal)
           faltoo-review-files (list (file-truename file))
           faltoo-current-review-index 0)
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1 +1 @@
-old
+changed")))
       (let ((review (faltoo-review-buffer file)))
        (switch-to-buffer review)
        (goto-char (point-min))
        (forward-line 1)

        ;; When a comment is saved on the added row and review is stopped.
        (faltoo-test--without-popup-display
         (lambda ()
           (faltoo-comment)
           (with-current-buffer "*Faltoo Comment*"
             (goto-char (point-max))
             (insert "keep this comment")
             (faltoo-comment-save))))
        (let ((comment (car (faltoo-comments--list root))))
          (should (equal (faltoo-comment-path comment) (file-truename file)))
          (should (= (faltoo-comment-start comment) 1))
          (faltoo-review-stop)

          ;; Then the same workspace queue and source-file highlight remain.
          (should (eq comment (car (faltoo-comments--list root))))
          (should (eq (faltoo-comment-source-buffer comment) (get-file-buffer file)))
          (should (overlay-buffer (faltoo-comment-overlay comment)))))))))

(ert-deftest faltoo-review-mode-keybindings-use-plain-keys-in-read-only-review-buffers ()
  "Scenario: Generated review buffers use direct single-key commands."
  (should (eq (lookup-key faltoo-review-mode-map (kbd "a")) #'faltoo-ask))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "c")) #'faltoo-comment))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "d")) #'faltoo-delete-current-comment))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "]")) #'faltoo-next-change))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "g")) #'beginning-of-buffer))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "G")) #'end-of-buffer))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "n")) #'faltoo-review-next-file))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "p")) #'faltoo-review-prev-file))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "N")) #'faltoo-next-comment))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "P")) #'faltoo-prev-comment))
  (should (eq (lookup-key faltoo-review-mode-map (kbd "S")) #'faltoo-stage-current-file))
  (should-not (commandp (lookup-key faltoo-review-mode-map (kbd "C-c f d")))))

(ert-deftest faltoo-review-change-navigation-wraps-between-hunks ()
  "Scenario: Change navigation moves between generated hunks and wraps at edges."
  (faltoo-test--with-temp-git-file
   '("first" "context" "second" "context")
   (lambda (file _root)
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args)
                  "@@ -1 +1 @@
-old first
+first
@@ -3 +3 @@
-old second
+second")))
       (with-current-buffer (faltoo-review-buffer file)
         (goto-char (point-min))
         (faltoo-next-change)
         (should (= (line-number-at-pos) 4))
         (faltoo-next-change)
         (should (= (line-number-at-pos) 1))
         (faltoo-prev-change)
         (should (= (line-number-at-pos) 4)))))))


(ert-deftest faltoo-review-buffer-is-read-only-and-shows-file-index ()
  "Scenario: Generated review buffers are read-only and identify their review position."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     (setq faltoo-review-files (list (file-truename file)))
     (cl-letf (((symbol-function 'faltoo-review--patch) (lambda (&rest _args) "")))
       (with-current-buffer (faltoo-review-buffer file)
         (should faltoo-review-mode)
         (should buffer-read-only)
         (should (string-match-p "Faltoo.*1/1" header-line-format)))))))

(ert-deftest faltoo-review-stop-closes-generated-buffer-and-restores-source ()
  "Scenario: Stopping review closes generated UI without changing the source buffer."
  (faltoo-test--with-temp-git-file
   '("one")
   (lambda (file _root)
     (setq faltoo-review-files (list (file-truename file)))
     (cl-letf (((symbol-function 'faltoo-review--patch) (lambda (&rest _args) "")))
       (let ((review (faltoo-review-buffer file)))
         (switch-to-buffer review)
         (faltoo-review-stop)
         (should-not (buffer-live-p review))
         (should (equal buffer-file-name file))
         (should-not buffer-read-only))))))

(ert-deftest faltoo-source-and-review-comments-share-one-file-queue ()
  "Scenario: A source comment is reused when editing the same line in review."
  (faltoo-test--with-temp-git-file
   '("changed")
   (lambda (file root)
     (setq faltoo-comments (make-hash-table :test #'equal)
           faltoo-review-files (list (file-truename file)))
     (faltoo-test--without-popup-display
      (lambda ()
        (faltoo-comment)
        (with-current-buffer "*Faltoo Comment*"
          (goto-char (point-max))
          (insert "source note")
          (faltoo-comment-save))))
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1 +1 @@\n-old\n+changed")))
       (let ((review (faltoo-review-buffer file)))
         (with-current-buffer review
           (let ((overlay (faltoo-comment-overlay (car (faltoo-comments--list root)))))
             (should (= (line-number-at-pos (overlay-start overlay)) 2)))
           (goto-char (point-min))
           (forward-line 1)
           (faltoo-test--without-popup-display
            (lambda ()
              (faltoo-comment)
              (with-current-buffer "*Faltoo Comment*"
                (should (string-match-p "source note" (buffer-string)))))))
         (should (= (faltoo-comments-count root) 1)))))))

(ert-deftest faltoo-review-comments-distinguish-consecutive-deleted-rows ()
  "Scenario: Consecutive deleted rows can hold separate pending comments."
  (faltoo-test--with-temp-git-file
   '("survivor")
   (lambda (file root)
     (setq faltoo-comments (make-hash-table :test #'equal)
           faltoo-review-files (list (file-truename file)))
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1,2 +0,0 @@
-old one
-old two")))
       (with-current-buffer (faltoo-review-buffer file)
         (dotimes (index 2)
           (goto-char (point-min))
           (forward-line index)
           (faltoo-test--without-popup-display
            (lambda ()
              (faltoo-comment)
              (with-current-buffer "*Faltoo Comment*"
                (goto-char (point-max))
                (insert (format "deleted note %d" index))
                (faltoo-comment-save)))))
         (should (= (faltoo-comments-count root) 2)))))))

(ert-deftest faltoo-review-comment-payload-keeps-diff-and-source-line-numbers ()
  "Scenario: Generated review comments submit both visible and source line coordinates."
  (faltoo-test--with-temp-git-file
   '("changed")
   (lambda (file root)
     (setq faltoo-comments (make-hash-table :test #'equal)
           faltoo-review-files (list (file-truename file)))
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1 +1 @@
-old
+changed")))
       (with-current-buffer (faltoo-review-buffer file)
         (goto-char (point-min))
         (forward-line 1)
         (faltoo-test--without-popup-display
          (lambda ()
            (faltoo-comment)
            (with-current-buffer "*Faltoo Comment*"
              (goto-char (point-max))
              (insert "coordinate note")
              (faltoo-comment-save))))
         (let* ((comment (car (faltoo-comments--list root)))
                (payload (car (faltoo-comments--payload (list comment)))))
           (should (= (alist-get 'line_number_start payload) 2))
           (should (= (alist-get 'file_line_number_start payload) 1))))))))

(ert-deftest faltoo-review-comment-can-be-deleted-from-its-generated-row ()
  "Scenario: Comment deletion works at the highlighted generated review row."
  (faltoo-test--with-temp-git-file
   '("changed")
   (lambda (file root)
     (setq faltoo-comments (make-hash-table :test #'equal)
           faltoo-review-files (list (file-truename file)))
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1 +1 @@
-old
+changed")))
       (with-current-buffer (faltoo-review-buffer file)
         (goto-char (point-min))
         (forward-line 1)
         (faltoo-test--without-popup-display
          (lambda ()
            (faltoo-comment)
            (with-current-buffer "*Faltoo Comment*"
              (goto-char (point-max))
              (insert "remove me")
              (faltoo-comment-save))))
         (faltoo-delete-current-comment)
         (should (= (faltoo-comments-count root) 0)))))))

(ert-deftest faltoo-review-comment-highlight-follows-the-selected-generated-row ()
  "Scenario: A comment on an added row highlights that row rather than its deleted neighbour."
  (faltoo-test--with-temp-git-file
   '("changed")
   (lambda (file root)
     (setq faltoo-comments (make-hash-table :test #'equal)
           faltoo-review-files (list (file-truename file)))
     (cl-letf (((symbol-function 'faltoo-review--patch)
                (lambda (&rest _args) "@@ -1 +1 @@\n-old\n+changed")))
       (let ((review (faltoo-review-buffer file)))
         (with-current-buffer review
           (goto-char (point-min))
           (forward-line 1)
           (faltoo-test--without-popup-display
            (lambda ()
              (faltoo-comment)
              (with-current-buffer "*Faltoo Comment*"
                (goto-char (point-max))
                (insert "added row note")
                (faltoo-comment-save))))
           (let ((overlay (faltoo-comment-overlay (car (faltoo-comments--list root)))))
             (should (= (line-number-at-pos (overlay-start overlay)) 2)))))))))

;;; Quit guard specs

(ert-deftest faltoo-quit-guard-detects-pending-review-comments ()
  "Scenario: Quit guard treats pending comments as unsaved work."
  ;; Given a pending review comment.
  (let ((faltoo-submitting nil)
        (faltoo-submitting-workspaces (make-hash-table :test #'equal))
        (faltoo-comments (make-hash-table :test #'equal)))
    (faltoo-comments--set (list (make-faltoo-comment :file "x" :path "x" :start 1 :end 1 :text "note")))

    ;; Then Faltoo reports pending work before Emacs quits.
    (should (faltoo-has-pending-work-p))
    (should (equal (faltoo-pending-work-labels) '("1 pending review comment(s)")))))


;;; Buffer reload specs

(ert-deftest faltoo-reload-workspace-buffers-refreshes-unmodified-stale-buffers ()
  "Scenario: Assistant-edited files refresh in Emacs before the user saves."
  (faltoo-test--with-temp-git-file
   '("old")
   (lambda (file root)
     ;; Given an unmodified source buffer is stale because the file changed on disk.
     (should (equal (buffer-string) "old"))
     (with-temp-file file (insert "new"))

     ;; When Faltoo reloads buffers after the request completes.
     (faltoo-reload-workspace-buffers root)

     ;; Then the buffer is refreshed instead of later triggering a save conflict.
     (should (equal (buffer-string) "new"))
     (should-not (buffer-modified-p)))))

(ert-deftest faltoo-reload-workspace-buffers-preserves-unsaved-local-edits ()
  "Scenario: Reloading assistant edits does not discard unsaved user edits."
  (faltoo-test--with-temp-git-file
   '("old")
   (lambda (file root)
     ;; Given the user has local unsaved edits and the file also changed on disk.
     (erase-buffer)
     (insert "local edit")
     (set-buffer-modified-p t)
     (with-temp-file file (insert "assistant edit"))

     ;; When Faltoo reloads workspace buffers.
     (faltoo-reload-workspace-buffers root)

     ;; Then local unsaved edits are left alone for Emacs' normal conflict handling.
     (should (equal (buffer-string) "local edit"))
     (should (buffer-modified-p)))))

(ert-deftest faltoo-reload-workspace-buffers-refreshes-review-ui-state ()
  "Scenario: Reloading assistant-edited review buffers refreshes overlays and diff highlights."
  (let ((refreshed nil))
    ;; Given a review reload hook is registered.
    (add-hook 'faltoo-after-reload-review-buffers-hook
              (lambda () (setq refreshed t)))

    ;; When workspace buffers are reloaded after a request.
    (unwind-protect
        (progn
          (faltoo-reload-workspace-buffers default-directory)

          ;; Then review UI refresh hooks run once at the architecture boundary.
          (should refreshed))
      (setq faltoo-after-reload-review-buffers-hook nil))))


;;; faltoo-behavior-test.el ends here
