;;; continuum-review.el --- Hunk-level review of apply_patches batches  -*- lexical-binding: t; -*-

;; Companion to .claude/mcp/patches/server.py.
;;
;; The server invokes:
;;   (continuum-review-start REQUEST-FILE RESPONSE-FILE)
;;
;; REQUEST-FILE is JSON: {"buffer": "<assembled review text>"}.
;; The review text is a sequence of blocks; each begins with
;;   ### edit N · path
;;   ### create N · path
;;   ### delete N · path
;; followed by an optional run of `# comment: …' lines and then a
;; unified-diff body (n=0 context, so hunks are pure +/- lines).
;; A header may carry trailing `[tag]' markers — `[edited]', `[rejected]'.
;;
;; On submit, RESPONSE-FILE is JSON:
;;   {"aborted": bool, "instructions": str,
;;    "blocks": [{kind, index, path, hunk, edited, rejected, comment}, …]}
;; Rejected blocks remain in the response with a comment; the server
;; treats `rejected: true' and missing-from-response equivalently.

(require 'diff-mode)
(require 'json)
(require 'subr-x)
(require 'cl-lib)

(defvar-local continuum-review--response-file nil)
(defvar-local continuum-review--submitted nil
  "Non-nil once submit/abort has written the response file.")
(defvar-local continuum-review--frame nil
  "The dedicated frame created for this review, if any.")
(defvar-local continuum-review--edit-context nil
  "In an edit buffer: plist (:review-buffer :header-pos :old-block
:original-new :at-header) linking it back to its review block.")

(defun continuum-review--maybe-abort-on-kill ()
  "Write an abort response if the buffer is killed without submitting."
  (when (and continuum-review--response-file
             (not continuum-review--submitted))
    (ignore-errors
      (continuum-review--write-response t "(buffer killed)" nil)))
  (continuum-review--dispose-frame))

(defun continuum-review--dispose-frame ()
  "Delete the review's dedicated frame, if it is still live."
  (when (and continuum-review--frame
             (frame-live-p continuum-review--frame))
    (ignore-errors (delete-frame continuum-review--frame)))
  (setq continuum-review--frame nil))

;; Header: kind, index, path, then zero or more `[tag]' markers.
(defconst continuum-review--header-re
  "^### \\(edit\\|create\\|delete\\) \\([0-9]+\\) · \\(.+?\\)\\(\\(?:\\s-+\\[[^]]+\\]\\)*\\)$")

;;; ----- tag helpers -----

(defun continuum-review--has-tag (header-pos tag)
  "Non-nil if `[TAG]' is present on the header at HEADER-POS."
  (save-excursion
    (goto-char header-pos)
    (re-search-forward (format " \\[%s\\]" (regexp-quote tag))
                       (line-end-position) t)))

(defun continuum-review--add-tag (header-pos tag)
  "Append `[TAG]' to the header at HEADER-POS unless already present."
  (unless (continuum-review--has-tag header-pos tag)
    (save-excursion
      (goto-char header-pos)
      (end-of-line)
      (let ((inhibit-read-only t))
        (insert (format " [%s]" tag))))))

(defun continuum-review--remove-tag (header-pos tag)
  "Remove `[TAG]' from the header at HEADER-POS if present."
  (save-excursion
    (goto-char header-pos)
    (when (re-search-forward (format " \\[%s\\]" (regexp-quote tag))
                             (line-end-position) t)
      (let ((inhibit-read-only t))
        (replace-match "")))))

(defun continuum-review--apply-reject-overlay (header-pos)
  (let* ((body-end (continuum-review--block-end header-pos))
         (ov (make-overlay header-pos body-end)))
    (overlay-put ov 'continuum-reject t)
    (overlay-put ov 'face '(:strike-through t :inherit shadow))
    (overlay-put ov 'help-echo "rejected — press k to undo")))

(defun continuum-review--clear-reject-overlay (header-pos)
  (dolist (ov (overlays-in header-pos
                           (continuum-review--block-end header-pos)))
    (when (overlay-get ov 'continuum-reject)
      (delete-overlay ov))))

;;; ----- keymap + mode -----

(defvar continuum-review-mode-map nil
  "Keymap for `continuum-review-mode'. Reset on every load.")
(setq continuum-review-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "n")       #'continuum-review-next)
        (define-key map (kbd "p")       #'continuum-review-prev)
        (define-key map (kbd "k")       #'continuum-review-reject)
        (define-key map (kbd "s")       #'continuum-review-stage)
        (define-key map (kbd "e")       #'continuum-review-edit)
        (define-key map (kbd "c")       #'continuum-review-comment)
        (define-key map (kbd "C-c C-c") #'continuum-review-submit)
        (define-key map (kbd "C-c C-k") #'continuum-review-abort)
        map))

(defun continuum-review--magit-face-remap ()
  "Repaint diff-mode faces in magit's palette, theme-aware."
  (let* ((dark (eq (frame-parameter nil 'background-mode) 'dark))
         (added-bg     (if dark "#335533" "#ddffdd"))
         (added-hi-bg  (if dark "#336633" "#cceecc"))
         (removed-bg   (if dark "#553333" "#ffdddd"))
         (removed-hi-bg(if dark "#663333" "#eecccc"))
         (hunk-bg      (if dark "#404040" "#dddddd"))
         (hunk-fg      (if dark "#cccccc" "#000000"))
         (file-bg      (if dark "#1c1c1c" "#eeeeee"))
         (file-fg      (if dark "#ffffff" "#000000")))
    (setq-local face-remapping-alist
                `((diff-added              (:background ,added-bg    :extend t))
                  (diff-indicator-added    (:background ,added-bg    :foreground ,(if dark "#a0e0a0" "#005500")))
                  (diff-refine-added       (:background ,added-hi-bg :extend t))
                  (diff-removed            (:background ,removed-bg  :extend t))
                  (diff-indicator-removed  (:background ,removed-bg  :foreground ,(if dark "#e0a0a0" "#550000")))
                  (diff-refine-removed     (:background ,removed-hi-bg :extend t))
                  (diff-context            (:foreground ,(if dark "#a0a0a0" "#555555")))
                  (diff-hunk-header        (:background ,hunk-bg :foreground ,hunk-fg :weight bold :extend t))
                  (diff-file-header        (:background ,file-bg :foreground ,file-fg :weight bold :extend t))
                  (diff-header             (:background ,file-bg :foreground ,file-fg :extend t))
                  (diff-function           (:foreground ,(if dark "#87afd7" "#005f87")))))))

(define-derived-mode continuum-review-mode diff-mode "Review"
  "Major mode for reviewing apply_patches batches."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil)
  (continuum-review--magit-face-remap)
  (add-hook 'kill-buffer-hook #'continuum-review--maybe-abort-on-kill nil t))

;;; ----- navigation -----

(defun continuum-review-next ()
  "Move to the next review block header."
  (interactive)
  (let ((start (point)))
    (end-of-line)
    (if (re-search-forward continuum-review--header-re nil t)
        (beginning-of-line)
      (goto-char start)
      (message "No next block."))))

(defun continuum-review-prev ()
  "Move to the previous review block header."
  (interactive)
  (let ((start (point)))
    (beginning-of-line)
    (if (re-search-backward continuum-review--header-re nil t)
        (beginning-of-line)
      (goto-char start)
      (message "No previous block."))))

;;; ----- block addressing -----

(defun continuum-review--header-pos ()
  "Beginning-of-line position of the block header that owns point, or nil."
  (save-excursion
    (end-of-line)
    (when (re-search-backward continuum-review--header-re nil t)
      (line-beginning-position))))

(defun continuum-review--block-end (header-pos)
  "Position where the block at HEADER-POS ends (next header or eob)."
  (save-excursion
    (goto-char header-pos)
    (forward-line 1)
    (if (re-search-forward continuum-review--header-re nil t)
        (match-beginning 0)
      (point-max))))

(defun continuum-review--body-start (header-pos)
  "First diff line after HEADER-POS, past any leading `# comment:' lines."
  (save-excursion
    (goto-char header-pos)
    (forward-line 1)
    (while (looking-at "^# ")
      (forward-line 1))
    (point)))

;;; ----- comment plumbing -----

(defun continuum-review--existing-comment (header-pos)
  "Return the block's current comment as a newline-joined string."
  (save-excursion
    (goto-char header-pos)
    (forward-line 1)
    (let (lines)
      (while (looking-at "^# comment: \\(.*\\)$")
        (push (match-string-no-properties 1) lines)
        (forward-line 1))
      (mapconcat #'identity (nreverse lines) "\n"))))

(defun continuum-review--delete-comment-lines (header-pos)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char header-pos)
      (forward-line 1)
      (while (looking-at "^# comment: ")
        (delete-region (line-beginning-position)
                       (progn (forward-line 1) (point)))))))

(defun continuum-review--insert-comment (header-pos comment)
  "Replace any existing comment on the block at HEADER-POS with COMMENT."
  (continuum-review--delete-comment-lines header-pos)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char header-pos)
      (forward-line 1)
      (dolist (line (split-string comment "\n"))
        (insert "# comment: " line "\n")))))

(defun continuum-review--prompt-and-set-comment (header-pos)
  "Prompt for the block's comment, pre-filling the existing one.
Submitting an empty string clears the comment; an unchanged string
is a no-op; otherwise the new text replaces the old."
  (let* ((existing (continuum-review--existing-comment header-pos))
         (new (read-from-minibuffer "Comment: " existing)))
    (cond
     ((string= new existing) nil)
     ((string-empty-p new)
      (continuum-review--delete-comment-lines header-pos))
     (t (continuum-review--insert-comment header-pos new)))))

(defun continuum-review-comment ()
  "Prompt for and attach a comment to the block at point. The current
comment is pre-filled; clear it by deleting and submitting empty."
  (interactive)
  (let ((pos (continuum-review--header-pos)))
    (unless pos (user-error "Not on a review block"))
    (continuum-review--prompt-and-set-comment pos)))

;;; ----- stage (toggle, advance) -----

(defun continuum-review-stage ()
  "Toggle `[staged]' on the block at point, then advance."
  (interactive)
  (let ((pos (continuum-review--header-pos)))
    (unless pos (user-error "Not on a review block"))
    (if (continuum-review--has-tag pos "staged")
        (continuum-review--remove-tag pos "staged")
      (continuum-review--add-tag pos "staged"))
    (continuum-review-next)))

;;; ----- reject (toggle, prompt, advance) -----

(defun continuum-review-reject ()
  "Toggle rejection of the block at point. On transition to rejected,
prompt for a comment. Advance to the next block in either direction."
  (interactive)
  (let ((pos (continuum-review--header-pos)))
    (unless pos (user-error "Not on a review block"))
    (if (continuum-review--has-tag pos "rejected")
        (progn
          (continuum-review--remove-tag pos "rejected")
          (continuum-review--clear-reject-overlay pos)
          (message "Rejection cleared."))
      (continuum-review--add-tag pos "rejected")
      (continuum-review--apply-reject-overlay pos)
      (continuum-review--prompt-and-set-comment pos))
    (continuum-review-next)))

;;; ----- edit (side buffer) -----
;;
;; `e' pops a *continuum-edit* buffer in `text-mode' showing only the
;; `+'-side of the hunk's first @@ block (prefixes stripped). The user
;; edits real text — no diff-mode keymap shadowing self-insert, no `-'
;; lines they can stomp on. `C-c C-c' regenerates the hunk in the
;; review buffer from the original `-' block plus the edited text and
;; marks the block `[edited]'. `C-c C-k' discards.

(defun continuum-review--extract-pair (hunk-text)
  "Return (OLD . NEW), each a newline-joined string of `-'/`+' lines
from the first @@ block of HUNK-TEXT (prefixes stripped). Unprefixed
lines are read as new-side content."
  (let ((olds nil) (news nil) (seen nil))
    (catch 'done
      (dolist (ln (split-string hunk-text "\n"))
        (cond
         ((string-prefix-p "@@" ln)
          (if seen (throw 'done nil) (setq seen t)))
         ((not seen) nil)
         ((string-prefix-p "-" ln) (push (substring ln 1) olds))
         ((string-prefix-p "+" ln) (push (substring ln 1) news))
         (t (push ln news)))))
    (cons (mapconcat #'identity (nreverse olds) "\n")
          (mapconcat #'identity (nreverse news) "\n"))))

(defun continuum-review--first-at-header (hunk-text)
  "Return the first `@@ … @@' line of HUNK-TEXT, or nil."
  (when (string-match "^@@.*?@@" hunk-text)
    (match-string 0 hunk-text)))

(defvar continuum-review-edit-mode-map nil)
(setq continuum-review-edit-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "C-c C-c") #'continuum-review-edit-finish)
        (define-key map (kbd "C-c C-k") #'continuum-review-edit-cancel)
        map))

(define-minor-mode continuum-review-edit-mode
  "Side-buffer editing of one hunk's new-side."
  :lighter " Edit-Hunk")

(defun continuum-review-edit ()
  "Pop a side buffer with the current block's `+'-side text; edit it
in plain `text-mode'. Finish with C-c C-c, discard with C-c C-k."
  (interactive)
  (let ((pos (continuum-review--header-pos)))
    (unless pos (user-error "Not on a review block"))
    (let* ((body-start (continuum-review--body-start pos))
           (body-end   (continuum-review--block-end pos))
           (hunk-text  (buffer-substring-no-properties body-start body-end))
           (pair       (continuum-review--extract-pair hunk-text))
           (old-block  (car pair))
           (new-block  (cdr pair))
           (at-header  (continuum-review--first-at-header hunk-text))
           (review-buf (current-buffer))
           (edit-buf   (get-buffer-create "*continuum-edit*")))
      (with-current-buffer edit-buf
        (text-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert new-block))
        (goto-char (point-min))
        (setq-local continuum-review--edit-context
                    (list :review-buffer review-buf
                          :header-pos    pos
                          :old-block     old-block
                          :original-new  new-block
                          :at-header     at-header))
        (continuum-review-edit-mode 1))
      (pop-to-buffer edit-buf)
      (message "Edit · C-c C-c finish · C-c C-k cancel"))))

(defun continuum-review-edit-finish ()
  "Apply the side-buffer text as the new `+'-side; mark `[edited]',
clear any prior `[rejected]', prompt for a comment, advance."
  (interactive)
  (let* ((ctx        continuum-review--edit-context)
         (review-buf (plist-get ctx :review-buffer))
         (header-pos (plist-get ctx :header-pos))
         (old-block  (plist-get ctx :old-block))
         (orig-new   (plist-get ctx :original-new))
         (at-header  (plist-get ctx :at-header))
         (new-block  (string-trim-right
                      (buffer-substring-no-properties (point-min) (point-max))))
         (changed    (not (string= orig-new new-block))))
    (kill-buffer (current-buffer))
    (when (buffer-live-p review-buf)
      (pop-to-buffer review-buf)
      (with-current-buffer review-buf
        (when changed
          (let* ((inhibit-read-only t)
                 (body-start (continuum-review--body-start header-pos))
                 (body-end   (continuum-review--block-end header-pos))
                 (old-lines  (if (string-empty-p old-block) nil
                               (split-string old-block "\n")))
                 (new-lines  (if (string-empty-p new-block) nil
                               (split-string new-block "\n")))
                 (regenerated
                  (concat
                   (or at-header
                       (format "@@ -1,%d +1,%d @@"
                               (length old-lines) (length new-lines)))
                   "\n"
                   (mapconcat (lambda (l) (concat "-" l)) old-lines "\n")
                   (if old-lines "\n" "")
                   (mapconcat (lambda (l) (concat "+" l)) new-lines "\n")
                   "\n\n")))
            (save-excursion
              (delete-region body-start body-end)
              (goto-char body-start)
              (insert regenerated)))
          (continuum-review--add-tag header-pos "edited"))
        ;; Editing supersedes any prior rejection.
        (continuum-review--remove-tag header-pos "rejected")
        (continuum-review--clear-reject-overlay header-pos)
        (goto-char header-pos)
        (continuum-review--prompt-and-set-comment header-pos)
        (continuum-review-next)))
    (message (if changed "Edited." "No changes."))))

(defun continuum-review-edit-cancel ()
  "Discard the side-buffer edit."
  (interactive)
  (let ((review-buf (plist-get continuum-review--edit-context :review-buffer)))
    (kill-buffer (current-buffer))
    (when (buffer-live-p review-buf)
      (pop-to-buffer review-buf)))
  (message "Edit cancelled."))

;;; ----- submit / abort -----

(defun continuum-review--collect-blocks ()
  "Walk buffer; return a list of block plists, one per `### …' header.
Each carries :edited and :rejected flags derived from header tags."
  (save-excursion
    (goto-char (point-min))
    (let (blocks)
      (while (re-search-forward continuum-review--header-re nil t)
        (let* ((kind     (match-string 1))
               (index    (string-to-number (match-string 2)))
               (path     (match-string 3))
               (tag-str  (or (match-string 4) ""))
               (edited   (string-match-p "\\[edited\\]" tag-str))
               (rejected (string-match-p "\\[rejected\\]" tag-str))
               (header-pos (line-beginning-position))
               (block-end  (continuum-review--block-end header-pos))
               (comments nil)
               body-start)
          (forward-line 1)
          (while (and (< (point) block-end)
                      (looking-at "^# comment: \\(.*\\)$"))
            (push (match-string 1) comments)
            (forward-line 1))
          (setq body-start (point))
          (push (list :kind     kind
                      :index    index
                      :path     path
                      :edited   (if edited t :json-false)
                      :rejected (if rejected t :json-false)
                      :hunk     (string-trim
                                 (buffer-substring-no-properties
                                  body-start block-end))
                      :comment  (if comments
                                    (mapconcat #'identity
                                               (nreverse comments) "\n")
                                  ""))
                blocks)
          (goto-char block-end)))
      (nreverse blocks))))

(defun continuum-review--write-response (aborted instructions blocks)
  (let* ((data `((aborted      . ,(if aborted t :json-false))
                 (instructions . ,instructions)
                 (blocks       . ,(vconcat
                                   (mapcar
                                    (lambda (b)
                                      `((kind     . ,(plist-get b :kind))
                                        (index    . ,(plist-get b :index))
                                        (path     . ,(plist-get b :path))
                                        (edited   . ,(plist-get b :edited))
                                        (rejected . ,(plist-get b :rejected))
                                        (hunk     . ,(plist-get b :hunk))
                                        (comment  . ,(plist-get b :comment))))
                                    blocks)))))
         (json-encoding-pretty-print nil)
         (json-false :json-false))
    (with-temp-file continuum-review--response-file
      (insert (json-encode data)))))

(defun continuum-review-submit ()
  "Finalize the review; prompt for further instructions, write response."
  (interactive)
  (let ((instructions
         (read-from-minibuffer "Further instructions (M-j newline, RET submit): "))
        (blocks (continuum-review--collect-blocks))
        (resp continuum-review--response-file))
    (continuum-review--write-response nil instructions blocks)
    (setq continuum-review--submitted t)
    (kill-buffer (current-buffer))
    (message "Review submitted → %s" resp)))

(defun continuum-review-abort ()
  "Abort the review; everything is rejected."
  (interactive)
  (let ((instructions (read-from-minibuffer "Abort reason (optional): "))
        (resp continuum-review--response-file))
    (continuum-review--write-response t instructions nil)
    (setq continuum-review--submitted t)
    (kill-buffer (current-buffer))
    (message "Review aborted → %s" resp)))

;;; ----- entry -----

;;;###autoload
(defun continuum-review-start (request-file response-file)
  "Read REQUEST-FILE, present review buffer in a new frame, write
RESPONSE-FILE on submit."
  (let* ((req (with-temp-buffer
                (insert-file-contents request-file)
                (let ((json-object-type 'alist)
                      (json-array-type 'list))
                  (json-read))))
         (body (cdr (assoc 'buffer req)))
         (buf  (get-buffer-create "*continuum-review*"))
         (frame (and (display-graphic-p)
                     (make-frame
                      '((name . "continuum-review")
                        (width . 120) (height . 40)
                        (left . 80) (top . 80)
                        (z-group . above))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body))
      (continuum-review-mode)
      (setq continuum-review--response-file response-file
            continuum-review--frame frame)
      (goto-char (point-min))
      (when (re-search-forward continuum-review--header-re nil t)
        (beginning-of-line)))
    (if frame
        (progn
          (select-frame-set-input-focus frame)
          (set-window-buffer (frame-selected-window frame) buf)
          ;; macOS: pull Emacs.app to the foreground.
          (when (eq window-system 'ns)
            (ignore-errors
              (ns-do-applescript
               "tell application \"Emacs\" to activate"))))
      (pop-to-buffer buf))
    t))

(provide 'continuum-review)
;;; continuum-review.el ends here
