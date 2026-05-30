;;; faltoo-faces.el --- Faces for Faltoo -*- lexical-binding: t; -*-

(defface faltoo-popup-meta-face
  '((t :inherit font-lock-comment-face))
  "Face for Faltoo popup metadata.")

(defface faltoo-popup-code-face
  '((t :inherit fixed-pitch))
  "Face for Faltoo popup code context.")

(defface faltoo-popup-assistant-face
  '((t :inherit default))
  "Face for assistant response text.")

(defface faltoo-review-comment-face
  '((t :extend t :background "#3a2f00"))
  "Face for pending Faltoo review comment lines.")

(defface faltoo-chat-user-face
  '((t :inherit secondary-selection))
  "Theme-aware face for user blocks in the Faltoo transcript.")

(defface faltoo-chat-tool-face
  '((t :inherit font-lock-comment-face))
  "Theme-aware face for truncated tool blocks in the Faltoo transcript.")

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
