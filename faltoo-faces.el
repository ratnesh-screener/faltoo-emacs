;;; faltoo-faces.el --- Faces for Faltoo -*- lexical-binding: t; -*-

(defface faltoo-popup-title-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.1))
  "Face for Faltoo popup titles.")

(defface faltoo-popup-meta-face
  '((t :inherit font-lock-comment-face))
  "Face for Faltoo popup metadata.")

(defface faltoo-popup-section-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for Faltoo popup section headings.")

(defface faltoo-popup-code-face
  '((t :inherit fixed-pitch))
  "Face for Faltoo popup code context.")

(defface faltoo-popup-assistant-face
  '((t :inherit default))
  "Face for assistant response text.")

(defface faltoo-review-comment-face
  '((t :extend t :background "#3a2f00"))
  "Face for pending Faltoo review comment lines.")

(defface faltoo-review-comment-marker-face
  '((t :inherit warning :weight bold))
  "Face for pending Faltoo review comment markers.")

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
