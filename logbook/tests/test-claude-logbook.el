;;; test-claude-logbook.el --- ERT tests for claude-logbook.el  -*- lexical-binding: t; -*-

;; Run: emacs --batch -Q -l logbook/tests/test-claude-logbook.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)

(load (expand-file-name "../claude-logbook.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defvar org-roam-directory nil)

(defmacro claude-logbook-test--with-env (&rest body)
  "Run BODY with a temporary `org-roam-directory', spool file and org-id store."
  (declare (indent 0))
  `(let* ((root (make-temp-file "claude-logbook-test" t))
          (org-roam-directory (file-name-as-directory (expand-file-name "roam" root)))
          (claude-logbook-spool-file (expand-file-name "spool/request.json" root))
          (org-id-locations (make-hash-table :test #'equal))
          (org-id-locations-file (expand-file-name "org-id-locations" root))
          (org-id-track-globally t)
          (db-updates nil))
     (make-directory org-roam-directory t)
     (make-directory (file-name-directory claude-logbook-spool-file) t)
     (cl-letf (((symbol-function 'org-roam-db-update-file)
                (lambda (&optional file &rest _) (push file db-updates)))
               ((symbol-function 'format-time-string)
                (let ((orig (symbol-function 'format-time-string)))
                  (lambda (fmt &rest _)
                    (funcall orig fmt (encode-time '(0 59 11 21 10 2026 nil -1 nil)))))))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

(defun claude-logbook-test--spool (alist)
  (with-temp-file claude-logbook-spool-file
    (insert (json-encode alist))))

(defun claude-logbook-test--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun claude-logbook-test--files ()
  (sort (directory-files org-roam-directory nil "\\.org\\'") #'string<))

(ert-deftest claude-logbook-example ()
  "Reproduces the example from the design: create + one append."
  (claude-logbook-test--with-env
    (claude-logbook-test--spool '(("op" . "create") ("title" . "logbook test")))
    (let* ((id (claude-logbook-dispatch))
           (file (expand-file-name "261021_CLAUDE_logbook_test.org" org-roam-directory)))
      (should (string-match-p claude-logbook--id-re id))
      (should-not (file-exists-p claude-logbook-spool-file))
      (should (equal (claude-logbook-test--files) '("261021_CLAUDE_logbook_test.org")))
      (claude-logbook-test--spool `(("op" . "append") ("id" . ,id)
                                    ("title" . "test") ("text" . "test 1 2 3")))
      (should (equal (claude-logbook-dispatch) id))
      (should (equal (claude-logbook-test--read file)
                     (concat ":PROPERTIES:\n"
                             ":ID:       " id "\n"
                             ":END:\n"
                             "#+title: [claude] logbook test\n"
                             "#+filetags: :claude:\n"
                             "\n"
                             "* " (format-time-string "[%Y-%m-%d %a %H:%M]") " test\n"
                             "test 1 2 3\n")))
      (should (equal db-updates (list file file))))))

(ert-deftest claude-logbook-never-overwrites ()
  (claude-logbook-test--with-env
    (with-temp-file (expand-file-name "261021_CLAUDE_same.org" org-roam-directory)
      (insert "precious\n"))
    (let ((id1 (claude-logbook-create "same"))
          (id2 (claude-logbook-create "same")))
      (should-not (equal id1 id2))
      (should (equal (claude-logbook-test--files)
                     '("261021_CLAUDE_same-1.org" "261021_CLAUDE_same-2.org"
                       "261021_CLAUDE_same.org")))
      (should (equal (claude-logbook-test--read
                      (expand-file-name "261021_CLAUDE_same.org" org-roam-directory))
                     "precious\n")))))

(ert-deftest claude-logbook-body-headings-are-demoted ()
  (claude-logbook-test--with-env
    (let* ((id (claude-logbook-create "headings"))
           (file (gethash id org-id-locations)))
      (claude-logbook-append id "entry"
                             "intro\n* Section\n** Sub\n*bold* stays\n*\n  * indented list\n")
      (should (string-suffix-p
               (concat "* [2026-10-21 " (format-time-string "%a") " 11:59] entry\n"
                       "intro\n** Section\n*** Sub\n*bold* stays\n**\n  * indented list\n")
               (claude-logbook-test--read file))))))

(ert-deftest claude-logbook-local-variables-neutralized ()
  (claude-logbook-test--with-env
    (let* ((id (claude-logbook-create "Local Variables: in title"))
           (file (gethash id org-id-locations)))
      (claude-logbook-append id "x" "# Local Variables:\n# eval: (delete-file \"x\")\n# End:\n")
      (let ((content (claude-logbook-test--read file)))
        (should-not (let ((case-fold-search t))
                      (string-match-p "Local[ \t]+Variables:" content)))
        (should (string-match-p "# Local Variables_:" content))))))

(ert-deftest claude-logbook-hostile-text-is-inert ()
  "Elisp-looking input must end up as plain text and never run."
  (claude-logbook-test--with-env
    (let* ((canary (expand-file-name "canary" root))
           (payload (format "%%(make-empty-file %S) \"); (make-empty-file %S) ${title}"
                            canary canary))
           id file)
      (claude-logbook-test--spool `(("op" . "create") ("title" . ,payload)))
      (setq id (claude-logbook-dispatch)
            file (gethash id org-id-locations))
      (claude-logbook-test--spool
       `(("op" . "append") ("id" . ,id) ("title" . ,payload)
         ("text" . ,(concat payload "\n#+begin_src emacs-lisp :eval yes\n"
                            (format "(make-empty-file %S)\n" canary)
                            "#+end_src\n"))))
      (claude-logbook-dispatch)
      (should-not (file-exists-p canary))
      (let ((content (claude-logbook-test--read file)))
        (should (string-match-p (regexp-quote (concat "#+title: [claude] " payload)) content))
        (should (string-match-p (regexp-quote (concat "11:59] " payload "\n" payload)) content))))))

(ert-deftest claude-logbook-refuses-non-claude-files ()
  (claude-logbook-test--with-env
    (let ((file (expand-file-name "my-notes.org" org-roam-directory)))
      (with-temp-file file
        (insert ":PROPERTIES:\n:ID:       mine\n:END:\n#+title: mine\n"))
      (puthash "mine" file org-id-locations)
      (should-error (claude-logbook-append "mine" "x" "y"))
      (should (equal (claude-logbook-test--read file)
                     ":PROPERTIES:\n:ID:       mine\n:END:\n#+title: mine\n")))))

(ert-deftest claude-logbook-refuses-outside-roam-directory ()
  (claude-logbook-test--with-env
    (let ((file (expand-file-name "261021_CLAUDE_elsewhere.org" root)))
      (with-temp-file file
        (insert ":PROPERTIES:\n:ID:       away\n:END:\n"))
      (puthash "away" file org-id-locations)
      (should-error (claude-logbook-append "away" "x" "y")))))

(ert-deftest claude-logbook-refuses-id-mismatch ()
  (claude-logbook-test--with-env
    (let* ((id (claude-logbook-create "real"))
           (file (gethash id org-id-locations)))
      (puthash "other-id" file org-id-locations)
      (should-error (claude-logbook-append "other-id" "x" "y")))))

(ert-deftest claude-logbook-refuses-unsaved-buffer ()
  (claude-logbook-test--with-env
    (let* ((id (claude-logbook-create "busy"))
           (file (gethash id org-id-locations))
           (buf (let ((enable-local-variables nil)) (find-file-noselect file))))
      (unwind-protect
          (progn
            (with-current-buffer buf (goto-char (point-max)) (insert "edit"))
            (should-error (claude-logbook-append id "x" "y")))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest claude-logbook-rejects-bad-requests ()
  (claude-logbook-test--with-env
    (dolist (req '((("op" . "eval") ("title" . "x"))
                   (("op" . "create") ("title" . 42))
                   (("op" . "create"))
                   (("op" . "append") ("id" . "../../etc") ("title" . "x") ("text" . "y"))))
      (claude-logbook-test--spool req)
      (should-error (claude-logbook-dispatch)))
    (should (null (claude-logbook-test--files)))))

;;; test-claude-logbook.el ends here
