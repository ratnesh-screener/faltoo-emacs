;;; faltoo-tree.el --- Transcript inspector for Faltoo -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'tabulated-list)
(require 'subr-x)
(require 'hl-line)
(require 'faltoo-core)
(require 'faltoo-bridge)
(require 'faltoo-ui)

(declare-function faltoo-chat-refresh "faltoo-chat")

(defconst faltoo-tree-preview-source-limit 2000)

(defvar-local faltoo-tree-workspace nil)
(defvar-local faltoo-tree-path nil)
(defvar-local faltoo-tree-payload nil)
(defvar-local faltoo-tree-messages nil)
(defvar-local faltoo-tree-row-items nil)
(defvar-local faltoo-tree-stream-process nil)
(defvar-local faltoo-tree-pending-rows nil)
(defvar-local faltoo-tree-render-timer nil)
(defvar-local faltoo-tree-detail-index nil)
(defvar-local faltoo-tree-detail-indexes nil)
(defvar-local faltoo-tree-last-search nil)
(defvar-local faltoo-tree-token-view nil)


(defvar faltoo-tree-mode-map nil)
(defvar faltoo-tree-detail-mode-map nil)

(defun faltoo-tree--setup-keymaps ()
  "Build tree keymaps so plugin reloads drop stale bindings."
  (setq faltoo-tree-mode-map
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map tabulated-list-mode-map)
          (define-key map (kbd "RET") #'faltoo-tree-inspect)
          (define-key map (kbd "TAB") #'faltoo-tree-inspect)
          (define-key map (kbd "g") #'faltoo-tree-refresh)
          (define-key map (kbd "o") #'faltoo-tree-open-raw)
          (define-key map (kbd "/") #'faltoo-tree-search)
          (define-key map (kbd "C-c s") #'faltoo-tree-search)
          (define-key map (kbd "u") #'faltoo-tree-previous-user)
          (define-key map (kbd "U") #'faltoo-tree-next-user)
          (define-key map (kbd "a") #'faltoo-tree-previous-answer)
          (define-key map (kbd "A") #'faltoo-tree-next-answer)
          (define-key map (kbd "D") #'faltoo-tree-prune-from-row)
          (define-key map (kbd "T") #'faltoo-tree-toggle-token-view)
          map)
        faltoo-tree-detail-mode-map
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map faltoo-popup-mode-map)
          (define-key map (kbd "p") #'faltoo-tree-detail-previous-item)
          (define-key map (kbd "n") #'faltoo-tree-detail-next-item)
          (define-key map (kbd "o") #'faltoo-tree-open-raw)
          map)))

(faltoo-tree--setup-keymaps)

(define-derived-mode faltoo-tree-detail-mode faltoo-popup-mode "Faltoo-Detail"
  "Mode for inspecting one Faltoo transcript item."
  (setq-local header-line-format "p/n prev/next tree row · o raw JSON · C-c C-k close"))

(define-derived-mode faltoo-tree-mode tabulated-list-mode "Faltoo-Tree"
  "Inspect Faltoo messages.json as structured transcript rows."
  (setq tabulated-list-padding 2
        tabulated-list-sort-key nil
        header-line-format "TAB/RET inspect · / search · o raw JSON · u/a prev user/answer · U/A next · T tokens · g refresh · D prune")
  (faltoo-tree--apply-view-options)
  (hl-line-mode 1)
  (faltoo-tree--set-format)
  (tabulated-list-init-header))

(defun faltoo-tree--apply-view-options ()
  "Apply focused one-row table display options to the current tree buffer."
  (setq-local truncate-lines t)
  (setq-local word-wrap nil)
  (when (bound-and-true-p visual-line-mode)
    (visual-line-mode -1))
  (when (bound-and-true-p display-line-numbers-mode)
    (display-line-numbers-mode -1)))

(defun faltoo-tree--set-format ()
  "Use compact transcript columns."
  (setq tabulated-list-format
        (if faltoo-tree-token-view
            [("#" 6 t) ("Role" 10 t) ("Type" 14 t)
             ("In" 11 t) ("Out" 10 t) ("Cached" 11 t) ("Total" 11 t)
             ("Preview" 20 nil)]
          [("#" 6 t) ("Role" 10 t) ("Type" 14 t) ("Preview" 100 nil)])))

(defun faltoo-tree-toggle-token-view ()
  "Toggle between preview scanning and token bookkeeping columns."
  (interactive)
  (when (timerp faltoo-tree-render-timer)
    (cancel-timer faltoo-tree-render-timer)
    (setq faltoo-tree-render-timer nil))
  (faltoo-tree--flush-pending-rows)
  (setq faltoo-tree-token-view (not faltoo-tree-token-view))
  (faltoo-tree--set-format)
  (setq tabulated-list-entries
        (cl-loop for item in (or faltoo-tree-messages faltoo-tree-row-items)
                 for index from 0
                 collect (faltoo-tree--entry index item)))
  (tabulated-list-init-header)
  (tabulated-list-print t)
  (faltoo-tree--apply-view-options))

(defun faltoo-tree-open (&optional workspace)
  "Open the structured transcript inspector for WORKSPACE."
  (interactive)
  (let* ((workspace (or workspace (faltoo-active-workspace)))
         (path (faltoo-bridge-messages-path workspace))
         (name (file-name-nondirectory (directory-file-name workspace)))
         (buf (get-buffer-create (format "*Faltoo Tree: %s*" name))))
    (with-current-buffer buf
      (faltoo-tree-mode)
      (setq faltoo-tree-workspace workspace
            faltoo-tree-path path)
      (faltoo-tree-refresh-stream))
    (pop-to-buffer buf #'display-buffer-pop-up-window)))

(defun faltoo-tree-refresh ()
  "Reload the current transcript tree synchronously."
  (interactive)
  (faltoo-tree--load-messages)
  (setq faltoo-tree-row-items faltoo-tree-messages
        tabulated-list-entries (cl-loop for item in faltoo-tree-messages
                                        for index from 0
                                        collect (faltoo-tree--entry index item)))
  (tabulated-list-print t)
  (faltoo-tree--apply-view-options))

(defun faltoo-tree-refresh-stream ()
  "Reload the current transcript tree by streaming compact rows."
  (interactive)
  (when (process-live-p faltoo-tree-stream-process)
    (delete-process faltoo-tree-stream-process))
  (when (timerp faltoo-tree-render-timer)
    (cancel-timer faltoo-tree-render-timer))
  (setq faltoo-tree-payload nil
        faltoo-tree-messages nil
        faltoo-tree-row-items nil
        faltoo-tree-pending-rows nil
        faltoo-tree-render-timer nil
        tabulated-list-entries nil)
  (tabulated-list-print t)
  (let ((buffer (current-buffer)))
    (setq faltoo-tree-stream-process
          (faltoo-bridge-tree-rows-stream
           faltoo-tree-workspace
           (lambda (event)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (faltoo-tree--stream-event event))))
           (lambda (_ok)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (faltoo-tree--stream-done))))))))

(defun faltoo-tree--load-messages ()
  "Load full transcript JSON into the current tree/detail buffer."
  (unless faltoo-tree-messages
    (let ((path faltoo-tree-path))
      (setq faltoo-tree-payload (with-temp-buffer
                                  (insert-file-contents path)
                                  (json-parse-buffer :object-type 'alist :array-type 'array))
            faltoo-tree-messages (append (alist-get 'messages faltoo-tree-payload) nil)))))

(defun faltoo-tree--stream-event (event)
  "Apply one streamed tree EVENT."
  (pcase (alist-get 'type event)
    ("start"
     (when-let ((path (alist-get 'path event)))
       (setq faltoo-tree-path path)))
    ("rows"
     (setq faltoo-tree-pending-rows
           (append faltoo-tree-pending-rows (append (alist-get 'rows event) nil)))
     (faltoo-tree--schedule-render))))

(defun faltoo-tree--schedule-render ()
  "Schedule a throttled render for pending streamed rows."
  (unless (timerp faltoo-tree-render-timer)
    (let ((buffer (current-buffer)))
      (setq faltoo-tree-render-timer
            (run-at-time 0.05 nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq faltoo-tree-render-timer nil)
                               (faltoo-tree--flush-pending-rows)))))))))

(defun faltoo-tree--flush-pending-rows ()
  "Append pending streamed rows and refresh the table once."
  (when faltoo-tree-pending-rows
    (let (items entries)
      (dolist (row faltoo-tree-pending-rows)
        (let* ((index (alist-get 'index row))
               (item (faltoo-tree--item-from-row row)))
          (push item items)
          (push (faltoo-tree--entry index item) entries)))
      (setq faltoo-tree-pending-rows nil
            faltoo-tree-row-items (append faltoo-tree-row-items (nreverse items))
            tabulated-list-entries (append tabulated-list-entries (nreverse entries))))
    (tabulated-list-print t)
    (faltoo-tree--apply-view-options)))

(defun faltoo-tree--stream-done ()
  "Finish a streamed tree refresh."
  (when (timerp faltoo-tree-render-timer)
    (cancel-timer faltoo-tree-render-timer)
    (setq faltoo-tree-render-timer nil))
  (faltoo-tree--flush-pending-rows)
  (tabulated-list-print t)
  (goto-char (point-max))
  (faltoo-tree--apply-view-options))

(defun faltoo-tree--entry (index item)
  "Return tabulated row for transcript ITEM at INDEX."
  (let* ((face (faltoo-tree--face item))
         (number (propertize (number-to-string index) 'face face))
         (type (propertize (faltoo-tree--type-label item) 'face face))
         (preview (truncate-string-to-width (faltoo-tree--preview item)
                                            (if faltoo-tree-token-view 18 120) nil nil "…")))
    (list index
          (if faltoo-tree-token-view
              (vector number (faltoo-tree--role-label item) type
                      (faltoo-tree--token-cell item 'input_tokens 'faltoo-tree-input-token-face)
                      (faltoo-tree--token-cell item 'output_tokens 'faltoo-tree-output-token-face)
                      (faltoo-tree--token-cell item 'cached_tokens 'faltoo-tree-cached-token-face)
                      (faltoo-tree--token-cell item 'total_tokens 'faltoo-tree-total-token-face)
                      preview)
            (vector number (faltoo-tree--role-label item) type preview)))))

(defun faltoo-tree--item-from-row (row)
  "Return a small transcript item compatible with navigation predicates from ROW."
  `((type . ,(or (alist-get 'message_type row) (alist-get 'type row)))
    (role . ,(alist-get 'role row))
    (faltoo-tree-kind . ,(alist-get 'kind row))
    (faltoo-tree-preview . ,(alist-get 'preview row))
    (faltoo-tree-input-tokens . ,(alist-get 'input_tokens row))
    (faltoo-tree-output-tokens . ,(alist-get 'output_tokens row))
    (faltoo-tree-cached-tokens . ,(alist-get 'cached_tokens row))
    (faltoo-tree-total-tokens . ,(alist-get 'total_tokens row))))

(defun faltoo-tree--role-label (item)
  "Return the short user-facing role label for ITEM."
  (let ((role (or (alist-get 'role item)
                  (pcase (alist-get 'type item)
                    ("function_call_output" "tool")
                    ((or "reasoning" "function_call" "web_search_call" "compaction") "assistant")
                    (_ "-")))))
    (pcase role
      ("user" "usr")
      ("assistant" "ast")
      ("tool" "tol")
      (_ (truncate-string-to-width role 3 nil nil "")))))

(defun faltoo-tree--type-label (item)
  "Return the user-facing type label for ITEM."
  (or (alist-get 'faltoo-tree-kind item)
      (pcase (alist-get 'type item)
        ("message" (if (equal (alist-get 'role item) "assistant") "answer" "message"))
        ("function_call" (if (string-match-p "image" (or (alist-get 'name item) ""))
                             "image gen"
                           "tool call"))
        ("function_call_output" "tool output")
        ("web_search_call" "web search")
        (type (or type "-")))))

(defun faltoo-tree--face (item)
  "Return the row face for ITEM."
  (pcase (alist-get 'type item)
    ("function_call" 'faltoo-tree-tool-face)
    ("function_call_output" 'faltoo-tree-tool-face)
    ("reasoning" 'faltoo-tree-reasoning-face)
    ("web_search_call" 'faltoo-tree-web-face)
    ("compaction" 'faltoo-tree-compaction-face)
    (_ (if (equal (alist-get 'role item) "user")
           'faltoo-tree-user-face
         'faltoo-tree-assistant-face))))

(defun faltoo-tree--preview (item)
  "Return a compact preview for transcript ITEM."
  (or (alist-get 'faltoo-tree-preview item)
      (pcase (alist-get 'type item)
        ("reasoning" (concat "[reasoning] " (faltoo-tree--content-text (alist-get 'summary item))))
        ("function_call" (concat (or (alist-get 'name item) "function_call") ": "
                                 (faltoo-tree--tool-arguments (alist-get 'arguments item))))
        ("function_call_output" (concat "output: " (faltoo-tree--output-preview (alist-get 'output item))))
        ("web_search_call" (format "web search: %s" (or (alist-get 'status item) "")))
        ("compaction" "[compaction]")
        (_ (faltoo-tree--content-text (alist-get 'content item))))))

(defun faltoo-tree--token-cell (item key face)
  "Return propertized token count for ITEM's KEY using FACE."
  (let ((value (faltoo-tree--token-value item key)))
    (if (numberp value)
        (propertize (faltoo-tree--format-token-count value) 'face face)
      "")))

(defun faltoo-tree--format-token-count (value)
  "Return VALUE as a comma-separated token count."
  (let ((text (number-to-string value)))
    (while (string-match "\\([0-9]+\\)\\([0-9][0-9][0-9]\\)" text)
      (setq text (replace-match "\\1,\\2" nil nil text)))
    text))

(defun faltoo-tree--token-value (item key)
  "Return token count KEY from ITEM usage or compact streamed metadata."
  (or (pcase key
        ('input_tokens (alist-get 'faltoo-tree-input-tokens item))
        ('output_tokens (alist-get 'faltoo-tree-output-tokens item))
        ('cached_tokens (alist-get 'faltoo-tree-cached-tokens item))
        ('total_tokens (alist-get 'faltoo-tree-total-tokens item)))
      (let ((usage (alist-get 'usage item)))
        (pcase key
          ('cached_tokens (alist-get 'cached_tokens (alist-get 'input_tokens_details usage)))
          (_ (alist-get key usage))))))

(defun faltoo-tree--content-text (content)
  "Return readable preview text from CONTENT without expanding binary payloads."
  (cond
   ((stringp content) (faltoo-tree--one-line content))
   ((or (listp content) (vectorp content))
    (faltoo-tree--one-line
     (string-join
      (delq nil (mapcar #'faltoo-tree--content-part-summary (append content nil)))
      " ")))
   (t "")))

(defun faltoo-tree--content-full (content)
  "Return readable detail text from CONTENT without expanding binary payloads."
  (cond
   ((stringp content) (faltoo-tree--redact-inline-data content))
   ((or (listp content) (vectorp content))
    (string-join
     (delq nil (mapcar #'faltoo-tree--content-part-summary (append content nil)))
     "\n\n"))
   (t "")))

(defun faltoo-tree--content-part-summary (part)
  "Return a compact readable summary for one content PART."
  (when (listp part)
    (let ((type (alist-get 'type part)))
      (cond
       ((stringp (alist-get 'text part)) (faltoo-tree--one-line (alist-get 'text part)))
       ((stringp (alist-get 'content part)) (faltoo-tree--one-line (alist-get 'content part)))
       ((alist-get 'image_url part) (format "[image: %s]" (or type "image")))
       (type (format "[%s]" type))))))

(defun faltoo-tree--limit (text)
  "Return TEXT capped for detail views."
  (if (> (length text) 20000)
      (concat (substring text 0 20000) "\n\n[truncated]")
    text))

(defun faltoo-tree--tool-arguments (text)
  "Return compact tool argument summary from JSON TEXT."
  (condition-case nil
      (if (> (length text) faltoo-tree-preview-source-limit)
          (faltoo-tree--one-line text)
        (let* ((args (json-parse-string text :object-type 'alist :array-type 'list))
               (summary (or (alist-get 'command_summary args) (alist-get 'command args) text)))
          (faltoo-tree--one-line summary)))
    (error (faltoo-tree--one-line (or text "")))))

(defun faltoo-tree--output-preview (output)
  "Return compact preview for tool OUTPUT."
  (if (stringp output)
      (faltoo-tree--one-line output)
    "[structured output]"))

(defun faltoo-tree--one-line (text)
  "Return TEXT without noisy whitespace, bounded for cheap tree previews."
  (cond
   ((stringp text)
    (replace-regexp-in-string
     "[[:space:]\n]+" " "
     (string-trim (faltoo-tree--redact-inline-data
                   (substring text 0 (min (length text) faltoo-tree-preview-source-limit))))))
   ((or (listp text) (vectorp text)) "[structured output]")
   (t (format "%s" text))))

(defun faltoo-tree--redact-inline-data (text)
  "Replace inline data URLs in TEXT with a small marker."
  (replace-regexp-in-string "data:image/[^\"[:space:]]+" "[inline image omitted]" text))

(defun faltoo-tree--answer-p (item)
  "Return non-nil when ITEM is an assistant answer row."
  (and (equal (alist-get 'type item) "message")
       (equal (alist-get 'role item) "assistant")))

(defun faltoo-tree--user-p (item)
  "Return non-nil when ITEM is a user message row."
  (and (equal (alist-get 'type item) "message")
       (equal (alist-get 'role item) "user")))

(defun faltoo-tree--visible-ids ()
  "Return currently visible transcript row indexes."
  (mapcar #'car tabulated-list-entries))

(defun faltoo-tree--goto-id (id)
  "Move point to visible transcript row ID."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
    (forward-line 1))
  (beginning-of-line))

(defun faltoo-tree--matching-indexes (predicate indexes)
  "Return transcript INDEXES whose messages match PREDICATE."
  (let ((items (or faltoo-tree-messages faltoo-tree-row-items)))
    (cl-remove-if-not
     (lambda (index)
       (funcall predicate (nth index items)))
     indexes)))

(defun faltoo-tree--find-index (predicate direction current indexes)
  "Return matching transcript index near CURRENT in DIRECTION, wrapping at edges."
  (let* ((sorted (sort (faltoo-tree--matching-indexes predicate indexes) #'<))
         (target (if (> direction 0)
                     (or (and current (cl-find-if (lambda (index) (> index current)) sorted))
                         (car sorted))
                   (or (and current (cl-find-if (lambda (index) (< index current)) (reverse sorted)))
                       (car (last sorted))))))
    (or target (user-error "No matching transcript row"))))

(defun faltoo-tree--jump (predicate direction)
  "Jump to the next visible row matching PREDICATE in DIRECTION, wrapping at edges."
  (faltoo-tree--goto-id
   (faltoo-tree--find-index predicate direction (tabulated-list-get-id)
                            (faltoo-tree--visible-ids))))

(defun faltoo-tree-search (query)
  "Search visible transcript rows by full backing JSON content for QUERY."
  (interactive (list (read-string "Search transcript: " nil nil faltoo-tree-last-search)))
  (setq faltoo-tree-last-search query)
  (faltoo-tree--load-messages)
  (let ((case-fold-search t))
    (faltoo-tree--goto-id
     (faltoo-tree--find-index
      (lambda (item)
        (string-match-p (regexp-quote query) (prin1-to-string item)))
      1 (tabulated-list-get-id) (faltoo-tree--visible-ids))))
  (message "Faltoo tree search: %s" query))

(defun faltoo-tree-previous-user ()
  "Jump to previous visible user message."
  (interactive)
  (faltoo-tree--jump #'faltoo-tree--user-p -1))

(defun faltoo-tree-next-user ()
  "Jump to next visible user message."
  (interactive)
  (faltoo-tree--jump #'faltoo-tree--user-p 1))

(defun faltoo-tree-previous-answer ()
  "Jump to previous visible assistant answer."
  (interactive)
  (faltoo-tree--jump #'faltoo-tree--answer-p -1))

(defun faltoo-tree-next-answer ()
  "Jump to next visible assistant answer."
  (interactive)
  (faltoo-tree--jump #'faltoo-tree--answer-p 1))

(defun faltoo-tree--current-index ()
  "Return transcript index at point."
  (or (tabulated-list-get-id) (user-error "No transcript row here")))

(defun faltoo-tree-inspect ()
  "Inspect selected transcript row."
  (interactive)
  (faltoo-tree--load-messages)
  (let* ((index (faltoo-tree--current-index))
         (path faltoo-tree-path)
         (messages faltoo-tree-messages)
         (visible-indexes (faltoo-tree--visible-ids))
         (buf (get-buffer-create "*Faltoo Tree Detail*")))
    (with-current-buffer buf
      (faltoo-tree-detail-mode)
      (setq faltoo-tree-path path
            faltoo-tree-messages messages
            faltoo-tree-detail-indexes visible-indexes
            faltoo-tree-detail-index index)
      (faltoo-tree-detail-render))
    (pop-to-buffer buf)))

(defun faltoo-tree-detail-render ()
  "Render the current detail transcript item."
  (interactive)
  (let ((item (nth faltoo-tree-detail-index faltoo-tree-messages)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "# Transcript item " (number-to-string faltoo-tree-detail-index) "\n\n")
      (faltoo-tree--insert-detail faltoo-tree-detail-index item)
      (setq buffer-read-only t)
      (goto-char (point-min)))))

(defun faltoo-tree-detail--row-jump (direction)
  "Jump detail view by visible tree row in DIRECTION."
  (setq faltoo-tree-detail-index
        (faltoo-tree--find-index (lambda (_item) t) direction faltoo-tree-detail-index
                                 (or faltoo-tree-detail-indexes
                                     (number-sequence 0 (1- (length faltoo-tree-messages))))))
  (faltoo-tree-detail-render))

(defun faltoo-tree-detail-previous-item ()
  "Show the previous visible tree row detail, wrapping at the start."
  (interactive)
  (faltoo-tree-detail--row-jump -1))

(defun faltoo-tree-detail-next-item ()
  "Show the next visible tree row detail, wrapping at the end."
  (interactive)
  (faltoo-tree-detail--row-jump 1))

(defun faltoo-tree-open-raw ()
  "Open raw messages.json at the current tree or detail item."
  (interactive)
  (let ((path faltoo-tree-path)
        (index (if (derived-mode-p 'faltoo-tree-detail-mode)
                   faltoo-tree-detail-index
                 (faltoo-tree--current-index))))
    (find-file path)
    (faltoo-tree--goto-raw-message-index index)
    (when (get-buffer-window (current-buffer))
      (recenter))))

(defun faltoo-tree--goto-raw-message-index (index)
  "Move point to the start of message object INDEX in raw messages JSON."
  (goto-char (point-min))
  (unless (re-search-forward "\"messages\"[[:space:]

	]*:" nil t)
    (user-error "No messages array found"))
  (unless (search-forward "[" nil t)
    (user-error "No messages array found"))
  (let ((array-depth 1)
        (object-depth 0)
        (count 0)
        (in-string nil)
        (escape nil)
        target)
    (while (and (not target) (not (eobp)) (> array-depth 0))
      (let ((ch (char-after)))
        (cond
         (in-string
          (cond
           (escape (setq escape nil))
           ((eq ch ?\\) (setq escape t))
           ((eq ch ?\") (setq in-string nil))))
         ((eq ch ?\") (setq in-string t))
         ((eq ch ?\[) (cl-incf array-depth))
         ((eq ch ?\]) (cl-decf array-depth))
         ((eq ch ?{)
          (when (and (= array-depth 1) (= object-depth 0))
            (if (= count index)
                (setq target (point))
              (cl-incf count)))
          (cl-incf object-depth))
         ((eq ch ?})
          (when (> object-depth 0)
            (cl-decf object-depth))))
        (unless target
          (forward-char 1))))
    (unless target
      (user-error "No message object at index %s" index))
    (goto-char target)))

(defun faltoo-tree--insert-detail (_index item)
  "Insert readable detail for ITEM."
  (dolist (key '(role type phase status id response_id call_id name))
    (when-let ((value (alist-get key item)))
      (insert (format "- %s: `%s`\n" key value))))
  (when-let ((usage (alist-get 'usage item)))
    (insert "\n## Usage\n\n```json\n" (faltoo-tree--json usage) "\n```\n"))
  (insert "\n## Content\n\n")
  (pcase (alist-get 'type item)
    ("function_call"
     (insert "```json\n" (faltoo-tree--limit (faltoo-tree--pretty-json-string (alist-get 'arguments item))) "\n```\n"))
    ("function_call_output"
     (insert "```json\n" (faltoo-tree--limit (faltoo-tree--pretty-json-string (alist-get 'output item))) "\n```\n"))
    ("reasoning" (insert (or (faltoo-tree--content-text (alist-get 'summary item)) "")
                         "\n\n[encrypted reasoning omitted]\n"))
    (_ (insert (faltoo-tree--limit (faltoo-tree--content-full (alist-get 'content item))) "\n"))))

(defun faltoo-tree--pretty-json-string (text)
  "Pretty print TEXT when it is JSON, otherwise return a redacted readable value."
  (condition-case nil
      (faltoo-tree--redact-inline-data
       (faltoo-tree--json (if (stringp text)
                              (json-parse-string text :object-type 'alist :array-type 'list)
                            text)))
    (error (if (stringp text) (faltoo-tree--redact-inline-data text) "[structured output]"))))

(defun faltoo-tree--json (value)
  "Return pretty JSON for VALUE."
  (with-temp-buffer
    (insert (json-serialize value))
    (json-pretty-print-buffer)
    (string-trim (buffer-string))))

(defun faltoo-tree-prune-from-row ()
  "Delete transcript items from the selected row to the end after backing up JSON."
  (interactive)
  (faltoo-tree--load-messages)
  (let ((index (faltoo-tree--current-index)))
    (when (yes-or-no-p (format "Delete transcript items %s..end? " index))
      (copy-file faltoo-tree-path
                 (format "%s.bak-%s" faltoo-tree-path (format-time-string "%Y%m%d-%H%M%S"))
                 t)
      (setf (alist-get 'messages faltoo-tree-payload) (vconcat (cl-subseq faltoo-tree-messages 0 index)))
      (write-region (concat (faltoo-tree--json faltoo-tree-payload) "\n") nil faltoo-tree-path)
      (faltoo-tree-refresh)
      (when (fboundp 'faltoo-chat-refresh)
        (faltoo-chat-refresh faltoo-tree-workspace)))))

(provide 'faltoo-tree)
;;; faltoo-tree.el ends here
