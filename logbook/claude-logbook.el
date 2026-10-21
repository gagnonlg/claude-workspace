;;; claude-logbook.el --- Let a sandboxed Claude write to an org-roam logbook  -*- lexical-binding: t; -*-

;; Load this from your init file on the host, next to (server-start):
;;
;;   (load "/path/to/claude-workspace/logbook/claude-logbook.el")
;;
;; The host-side `logbook-bridge' writes each request as JSON to
;; `claude-logbook-spool-file' and then runs the constant expression
;;
;;   emacsclient --eval "(claude-logbook-dispatch)"
;;
;; Request contents are only ever parsed as JSON data; nothing supplied by
;; Claude reaches the elisp reader, `eval', `funcall', `intern' or org-capture
;; template expansion.

;;; Code:

(require 'org)
(require 'org-id)
(require 'json)
(require 'subr-x)

(defvar org-roam-directory)
(declare-function org-roam-node-from-id "org-roam-node" (id))
(declare-function org-roam-node-file "org-roam-node" (node))
(declare-function org-roam-db-update-file "org-roam-db" (&optional file-path no-require))

(defvar claude-logbook-spool-file
  (expand-file-name "~/.cache/claude-logbook/request.json")
  "File the bridge writes the pending request to.  Must match the bridge's --spool-dir.")

(defconst claude-logbook--id-re "\\`[A-Za-z0-9:._-]\\{1,128\\}\\'"
  "Accepted shape of a logbook ID (org-id with any `org-id-method').")

(defconst claude-logbook--max-title 500)
(defconst claude-logbook--max-text 200000)

;;;; Request handling

(defun claude-logbook--read-request ()
  "Read, delete and return the spooled request as a hash table with string keys."
  (unless (file-regular-p claude-logbook-spool-file)
    (error "claude-logbook: no pending request"))
  (prog1
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents claude-logbook-spool-file))
        (goto-char (point-min))
        (let ((req (if (fboundp 'json-parse-buffer)
                       (json-parse-buffer :object-type 'hash-table)
                     (let ((json-object-type 'hash-table)
                           (json-key-type 'string))
                       (json-read)))))
          (unless (hash-table-p req)
            (error "claude-logbook: malformed request"))
          req))
    (delete-file claude-logbook-spool-file)))

(defun claude-logbook--string-field (req key max)
  "Return field KEY of REQ, which must be a string of at most MAX chars."
  (let ((value (gethash key req)))
    (unless (stringp value)
      (error "claude-logbook: field %s must be a string" key))
    (when (> (length value) max)
      (error "claude-logbook: field %s is too long" key))
    value))

(defun claude-logbook--id-field (req)
  (let ((id (claude-logbook--string-field req "id" 128)))
    (unless (string-match-p claude-logbook--id-re id)
      (error "claude-logbook: malformed id"))
    id))

;;;###autoload
(defun claude-logbook-dispatch ()
  "Process the request spooled by logbook-bridge.  Return the entry ID."
  (let* ((req (claude-logbook--read-request))
         (op (gethash "op" req)))
    (pcase op
      ("create"
       (claude-logbook-create
        (claude-logbook--string-field req "title" claude-logbook--max-title)))
      ("append"
       (claude-logbook-append
        (claude-logbook--id-field req)
        (claude-logbook--string-field req "title" claude-logbook--max-title)
        (claude-logbook--string-field req "text" claude-logbook--max-text)))
      (_ (error "claude-logbook: unknown op")))))

;;;; Text sanitizing

(defun claude-logbook--neutralize (text)
  "Defang file-local variable blocks in TEXT, so visiting the file never evaluates them."
  (let ((case-fold-search t))
    (replace-regexp-in-string "Local\\([ \t]+\\)Variables:" "Local\\1Variables_:" text)))

(defun claude-logbook--clean-title (title)
  (claude-logbook--neutralize
   (string-trim (replace-regexp-in-string "[\r\n]+" " " title))))

(defun claude-logbook--prepare-body (text)
  "Normalize TEXT, demote its org headings one level and ensure a final newline."
  (let ((body (claude-logbook--neutralize
               (replace-regexp-in-string "\r" "" text))))
    (setq body (replace-regexp-in-string "^\\*+\\(?:[ \t]\\|$\\)" "*\\&" body))
    (if (or (string-empty-p body) (string-suffix-p "\n" body))
        body
      (concat body "\n"))))

(defun claude-logbook--slug (title)
  (let ((slug (replace-regexp-in-string "[^[:alnum:]]+" "_" title)))
    (setq slug (truncate-string-to-width slug 60))
    (setq slug (replace-regexp-in-string "\\`_+\\|_+\\'" "" slug))
    (if (string-empty-p slug) "entry" slug)))

;;;; Create

(defun claude-logbook--candidate (dir base n)
  (expand-file-name (if (= n 0) (concat base ".org") (format "%s-%d.org" base n))
                    dir))

;;;###autoload
(defun claude-logbook-create (title)
  "Create a new logbook file in `org-roam-directory' titled TITLE.  Return its ID.
Never overwrites: an existing name gets a -1, -2, ... suffix, and the write
itself fails if the file appeared in the meantime."
  (let* ((title (claude-logbook--clean-title title))
         (dir (file-name-as-directory (expand-file-name org-roam-directory)))
         (base (concat (format-time-string "%y%m%d") "_CLAUDE_"
                       (claude-logbook--slug title)))
         (id (org-id-new))
         (content (with-temp-buffer
                    (insert "#+title: [claude] " title "\n"
                            "#+filetags: :claude:\n"
                            "\n")
                    (delay-mode-hooks (org-mode))
                    (org-entry-put (point-min) "ID" id)
                    (buffer-string)))
         (n 0)
         file)
    (while (not file)
      (let ((candidate (claude-logbook--candidate dir base n)))
        (unless (file-exists-p candidate)
          (condition-case nil
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region content nil candidate nil 'silent nil 'excl)
                (setq file candidate))
            (file-already-exists nil)))
        (setq n (1+ n))
        (when (> n 1000)
          (error "claude-logbook: could not find a free file name for %s" base))))
    (org-id-add-location id file)
    (when (fboundp 'org-roam-db-update-file)
      (org-roam-db-update-file file))
    id))

;;;; Append

(defun claude-logbook--file-for-id (id)
  (or (and (fboundp 'org-roam-node-from-id)
           (when-let ((node (org-roam-node-from-id id)))
             (org-roam-node-file node)))
      ;; May fall back to the current buffer's file; `claude-logbook--check-file'
      ;; rejects that unless it really is this entry.
      (org-id-find-id-file id)))

(defun claude-logbook--check-file (file id)
  "Signal an error unless FILE is a Claude logbook file whose file-level ID is ID.
Return the file's contents."
  (unless (and file (file-regular-p file))
    (error "claude-logbook: no logbook file for this id"))
  (unless (and (string-match-p "_CLAUDE_" (file-name-nondirectory file))
               (file-in-directory-p file org-roam-directory))
    (error "claude-logbook: refusing to write outside Claude logbook files"))
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (delay-mode-hooks (org-mode))
    (unless (equal (org-entry-get (point-min) "ID") id)
      (error "claude-logbook: file-level ID mismatch"))
    (buffer-string)))

;;;###autoload
(defun claude-logbook-append (id title text)
  "Append an entry headed TITLE with org body TEXT to the logbook file with ID.
The file is appended to on disk without visiting it, so no mode hooks or
file-local variables run."
  (let* ((file (claude-logbook--file-for-id id))
         (existing (claude-logbook--check-file file id))
         (buffer (find-buffer-visiting file)))
    (when (and buffer (buffer-modified-p buffer))
      (error "claude-logbook: the logbook file has unsaved edits in Emacs"))
    (let ((entry (concat (if (or (string-empty-p existing)
                                 (string-suffix-p "\n" existing))
                             ""
                           "\n")
                         (string-trim-right
                          (concat "* " (format-time-string "[%Y-%m-%d %a %H:%M]")
                                  " " (claude-logbook--clean-title title)))
                         "\n"
                         (claude-logbook--prepare-body text)))
          (coding-system-for-write 'utf-8-unix))
      (write-region entry nil file 'append 'silent))
    (when buffer
      (with-current-buffer buffer
        (revert-buffer t t t)))
    (when (fboundp 'org-roam-db-update-file)
      (org-roam-db-update-file file))
    id))

(provide 'claude-logbook)
;;; claude-logbook.el ends here
