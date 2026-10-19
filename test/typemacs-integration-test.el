;;; typemacs-integration-test.el --- Real Tinymist smoke test -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'url-http)
(require 'typemacs)

(defvar typemacs-integration--diagnostics nil)

(cl-defmethod eglot-handle-notification :after
  ((_server typemacs-eglot-server) (_method (eql textDocument/publishDiagnostics))
   &key uri diagnostics &allow-other-keys)
  "Remember real Tinymist diagnostics during the integration test."
  (setf (alist-get uri typemacs-integration--diagnostics nil nil #'equal)
        (append diagnostics nil)))

(defun typemacs-integration--wait (predicate &optional timeout)
  "Wait up to TIMEOUT seconds for PREDICATE, while processing server replies."
  (let ((deadline (+ (float-time) (or timeout 15))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun typemacs-integration--errors-p ()
  "Return non-nil if Tinymist's latest diagnostics contain an error."
  (cl-some (lambda (entry)
             (cl-some (lambda (diagnostic)
                        (= (or (plist-get diagnostic :severity) 1) 1))
                      (cdr entry)))
           typemacs-integration--diagnostics))

(ert-deftest typemacs-integration-preview-unsaved-chapter-and-cleanup ()
  (skip-unless (executable-find (car typemacs-tinymist-command)))
  (let* ((directory (file-name-as-directory
                     (file-truename (make-temp-file "typemacs-live-" t))))
         (main-file (expand-file-name "main.typ" directory))
         (chapter-file (expand-file-name "chapter.typ" directory))
         (default-directory directory)
         (project-find-functions (list (lambda (_) (cons 'transient directory))))
         (project-list-file (expand-file-name "projects" directory))
         (eglot-autoshutdown nil)
         (eglot-sync-connect 10)
         (eglot-connect-timeout 15)
         (eglot-workspace-configuration '(:tinymist (:exportPdf "never")))
         (typemacs--sessions (make-hash-table :test #'equal))
         (typemacs-integration--diagnostics nil)
         main chapter server session)
    (unwind-protect
        (progn
          (write-region "= Integration\n\n#include \"chapter.typ\"\n"
                        nil main-file nil 'silent)
          (write-region "== Saved chapter\n" nil chapter-file nil 'silent)
          (typemacs-setup)
          (setq main (find-file-noselect main-file))
          (with-current-buffer main
            ;; Exercise the exact first-use path, including Eglot's deferred
            ;; connection hook, rather than pre-connecting a test server.
            (should-not (typemacs-start nil t))
            (run-hooks 'post-command-hook))
          (typemacs-integration--wait
           (lambda () (with-current-buffer main
                        (and (eglot-managed-p) (eglot-current-server)))))
          (with-current-buffer main
            (setq server (eglot-current-server))
            (should (object-of-class-p server 'typemacs-eglot-server))
            (typemacs-integration--wait (lambda () typemacs--session))
            (setq session typemacs--session))
          (typemacs-integration--wait
           (lambda () (memq (typemacs-session-state session) '(running failed stopped))))
          (should (eq (typemacs-session-state session) 'running))
          (let* ((url-proxy-services nil)
                 (response (url-retrieve-synchronously
                            (typemacs-session-url session) t t 10)))
            (should (buffer-live-p response))
            (unwind-protect
                (with-current-buffer response
                  (should (= url-http-response-status 200))
                  (should (search-forward "<html" nil t)))
              (kill-buffer response)))
          (setq chapter (find-file-noselect chapter-file))
          (with-current-buffer chapter
            (setq-local typemacs-main-file "main.typ")
            (should (eglot-managed-p))
            ;; A chapter shares the existing main-file preview.
            (should (eq session (typemacs-start nil t)))
            (should (= (hash-table-count typemacs--sessions) 1))
            (erase-buffer)
            (insert "#typemacs_nonexistent_function()\n")
            (typemacs-eglot-flush server))
          (typemacs-integration--wait #'typemacs-integration--errors-p)
          (with-temp-buffer
            (insert-file-contents chapter-file)
            (should (equal (buffer-string) "== Saved chapter\n")))
          ;; Recover from the unsaved syntax/compile error through the same LSP
          ;; document state that supplies the preview compiler.
          (with-current-buffer chapter
            (erase-buffer)
            (insert "== Unsaved chapter\n\nLive editing works.\n")
            (typemacs-eglot-flush server))
          (typemacs-integration--wait
           (lambda () (not (typemacs-integration--errors-p))))
          (let (done failure)
            (typemacs-eglot-command
             server "tinymist.scrollPreview"
             (list (typemacs-session-task-id session)
                   (list :event "panelScrollTo" :filepath chapter-file
                         :line 2 :character 3))
             :success (lambda (_) (setq done t))
             :error (lambda (data) (setq done t failure data)))
            (typemacs-integration--wait (lambda () done))
            (should-not failure))
          (with-current-buffer chapter (typemacs-stop))
          (should (= (hash-table-count typemacs--sessions) 0))
          (should (jsonrpc-running-p server))
          ;; A normal language feature must still work after stopping preview.
          (should (jsonrpc-request
                   server :textDocument/documentSymbol
                   (list :textDocument
                         (list :uri (concat "file://" main-file))) :timeout 10)))
      (when (and server (not (jsonrpc-running-p server)))
        (when-let* ((stderr (jsonrpc-stderr-buffer server)))
          (message "Tinymist stderr:\n%s"
                   (with-current-buffer stderr (buffer-string)))))
      (when (and session (not (eq (typemacs-session-state session) 'stopped)))
        (typemacs-preview-stop session))
      (when (and server (jsonrpc-running-p server))
        (eglot-shutdown server))
      (dolist (buffer (list chapter main))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(provide 'typemacs-integration-test)
;;; typemacs-integration-test.el ends here
