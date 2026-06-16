;;; faltoo-faces.el --- Faces for Faltoo -*- lexical-binding: t; -*-

(defface faltoo-popup-meta-face
  '((t :inherit font-lock-comment-face))
  "Face for Faltoo popup metadata.")

(defface faltoo-popup-code-face
  '((t :inherit fixed-pitch))
  "Face for Faltoo popup code context.")

(defface faltoo-popup-assistant-face
  '((t :inherit faltoo-chat-assistant-face))
  "Face for assistant response text.")

(defface faltoo-review-comment-face
  '((t :extend t :background "#3a2f00"))
  "Face for pending Faltoo review comment lines.")

(defface faltoo-chat-user-face
  '((t :inherit region))
  "Theme-aware primary face for user blocks in the Faltoo transcript.")

(defface faltoo-chat-assistant-face
  '((t :inherit secondary-selection))
  "Theme-aware secondary face for assistant blocks in the Faltoo transcript.")

(defface faltoo-chat-tool-face
  '((t :inherit font-lock-comment-face))
  "Theme-aware face for truncated tool blocks in the Faltoo transcript.")

(defface faltoo-chat-error-face
  '((t :inherit error))
  "Theme-aware face for Faltoo stream errors in the transcript.")

(defface faltoo-tree-user-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user rows in the Faltoo transcript inspector.")

(defface faltoo-tree-assistant-face
  '((t :inherit font-lock-string-face))
  "Face for assistant answer rows in the Faltoo transcript inspector.")

(defface faltoo-tree-tool-face
  '((t :inherit font-lock-comment-face))
  "Face for tool rows in the Faltoo transcript inspector.")

(defface faltoo-tree-reasoning-face
  '((t :inherit shadow :slant italic))
  "Face for reasoning rows in the Faltoo transcript inspector.")

(defface faltoo-tree-web-face
  '((t :inherit font-lock-builtin-face))
  "Face for web/search rows in the Faltoo transcript inspector.")

(defface faltoo-tree-compaction-face
  '((t :inherit shadow))
  "Face for compaction rows in the Faltoo transcript inspector.")

(defface faltoo-tree-input-token-face
  '((t :inherit font-lock-variable-name-face))
  "Face for input token counts in the Faltoo transcript inspector.")

(defface faltoo-tree-output-token-face
  '((t :inherit font-lock-function-name-face))
  "Face for output token counts in the Faltoo transcript inspector.")

(defface faltoo-tree-cached-token-face
  '((t :inherit font-lock-constant-face))
  "Face for cached token counts in the Faltoo transcript inspector.")

(defface faltoo-tree-total-token-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for total token counts in the Faltoo transcript inspector.")

(defface faltoo-diff-insert-line-face
  '((t :extend t :background "#12381f"))
  "Face for inserted Git lines in Faltoo review buffers.")

(defface faltoo-diff-change-line-face
  '((t :extend t :background "#39330f"))
  "Face for changed Git lines in Faltoo review buffers.")

(defface faltoo-diff-delete-line-face
  '((t :extend t :background "#3a1717"))
  "Face for deleted Git lines in Faltoo review buffers.")

(provide 'faltoo-faces)
;;; faltoo-faces.el ends here
