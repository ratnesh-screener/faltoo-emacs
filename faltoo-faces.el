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

(defface faltoo-chat-hook-feedback-face
  '((t :inherit font-lock-constant-face :foreground "#a67555"))
  "Muted orange face for post-response hook feedback blocks.")

(set-face-attribute 'faltoo-chat-hook-feedback-face nil
                    :inherit 'font-lock-constant-face
                    :foreground "#a67555")

(defface faltoo-chat-error-face
  '((t :inherit error))
  "Theme-aware face for Faltoo stream errors in the transcript.")

(defface faltoo-tree-user-face
  '((t :inherit success :weight bold))
  "Theme-aware face for user message types in the transcript inspector.")

(defface faltoo-tree-assistant-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Theme-aware face for assistant answer types in the transcript inspector.")

(defface faltoo-tree-tool-call-face
  '((t :inherit font-lock-function-name-face))
  "Theme-aware face for tool-call types in the transcript inspector.")

(defface faltoo-tree-tool-output-face
  '((t :inherit link :slant italic))
  "Theme-aware face for tool-output types in the transcript inspector.")

(defface faltoo-tree-image-face
  '((t :inherit font-lock-string-face :weight bold))
  "Theme-aware face for image-generation types in the transcript inspector.")

(defface faltoo-tree-reasoning-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Theme-aware face for reasoning types in the transcript inspector.")

(defface faltoo-tree-web-face
  '((t :inherit font-lock-builtin-face :weight bold))
  "Theme-aware face for web/search types in the transcript inspector.")

(defface faltoo-tree-compaction-face
  '((t :inherit warning))
  "Theme-aware face for compaction types in the transcript inspector.")

(defun faltoo-tree-apply-theme-faces (&rest _)
  "Use Doom theme palette colors for transcript tree types when available."
  (when (fboundp 'doom-color)
    (set-face-attribute 'faltoo-tree-user-face nil :foreground (doom-color 'green) :weight 'bold)
    (set-face-attribute 'faltoo-tree-assistant-face nil :foreground (doom-color 'violet) :weight 'bold)
    (set-face-attribute 'faltoo-tree-tool-call-face nil :foreground (doom-color 'blue) :slant 'normal)
    (set-face-attribute 'faltoo-tree-tool-output-face nil :foreground (doom-color 'dark-blue) :slant 'italic)
    (set-face-attribute 'faltoo-tree-image-face nil :foreground (doom-color 'magenta) :weight 'bold)
    (set-face-attribute 'faltoo-tree-reasoning-face nil :foreground (doom-color 'grey) :slant 'italic)
    (set-face-attribute 'faltoo-tree-web-face nil :foreground (doom-color 'cyan) :weight 'bold)
    (set-face-attribute 'faltoo-tree-compaction-face nil :foreground (doom-color 'orange))))

(add-hook 'enable-theme-functions #'faltoo-tree-apply-theme-faces)
(faltoo-tree-apply-theme-faces)

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

(defface faltoo-tree-preview-face
  '((t :inherit shadow))
  "Muted face for tree preview text.")

(defface faltoo-diff-insert-line-face
  '((t :inherit magit-diff-added-highlight :extend t))
  "Theme-aware face for inserted Git lines in Faltoo review buffers.")

(defface faltoo-diff-delete-line-face
  '((t :inherit magit-diff-removed-highlight :extend t))
  "Theme-aware face for deleted Git lines in Faltoo review buffers.")

(provide 'faltoo-faces)
;;; faltoo-faces.el ends here
