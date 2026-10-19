;;; typemacs-eglot.el --- Tinymist protocol adapter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Keep Eglot internals and Tinymist extension commands in this adapter.
;; Eglot remains the sole owner of document synchronization.

;;; Code:

(require 'eglot)
(require 'project)
(require 'typemacs-session)

(declare-function eglot-uri-to-path "eglot" (uri))

(defcustom typemacs-tinymist-command '("tinymist" "lsp")
  "Program and arguments used when Eglot starts Tinymist."
  :type '(repeat string)
  :group 'typemacs)

(defcustom typemacs-request-timeout 15
  "Seconds to wait for a Tinymist command response."
  :type 'natnum
  :group 'typemacs)

(defvar typemacs-scroll-source-functions nil
  "Functions called with SERVER, FILEPATH, START, and END for inverse search.
START and END are two-element vectors of zero-based LSP coordinates.")

(defclass typemacs-eglot-server (eglot-lsp-server) ()
  :documentation "Tinymist connection configured for Typemacs.")

(cl-defmethod eglot-initialization-options ((_server typemacs-eglot-server))
  "Request inverse-search notifications from SERVER."
  (let ((options (cl-call-next-method)))
    ;; Eglot's default empty object is a hash table on some versions.
    (if (hash-table-p options)
        (let ((copy (copy-hash-table options)))
          (puthash "customizedShowDocument" t copy)
          copy)
      (plist-put (copy-sequence options) :customizedShowDocument t))))

(defun typemacs-eglot-contact (_interactive &optional _project)
  "Return the Eglot contact for Tinymist."
  (cons 'typemacs-eglot-server typemacs-tinymist-command))

(defun typemacs-eglot-root (server)
  "Return SERVER's canonical project root."
  (file-name-as-directory
   (typemacs--canonical-file (project-root (eglot--project server)))))

(defun typemacs-eglot-command-supported-p (server command)
  "Return non-nil if SERVER advertises COMMAND."
  (member command
          (append (plist-get (plist-get (eglot--capabilities server)
                                        :executeCommandProvider)
                             :commands)
                  nil)))

(defun typemacs-eglot-flush (server)
  "Flush pending Eglot changes in all buffers belonging to SERVER."
  (dolist (buffer (eglot--managed-buffers server))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eglot-managed-p)
          (eglot--signal-textDocument/didChange))))))

(cl-defun typemacs-eglot-command
    (server command arguments &key success error)
  "Asynchronously execute COMMAND with ARGUMENTS on SERVER.
SUCCESS receives the result.  ERROR receives a JSON-RPC error object."
  (unless (jsonrpc-running-p server)
    (user-error "Tinymist is disconnected; reconnect Eglot first"))
  (unless (typemacs-eglot-command-supported-p server command)
    (user-error "Tinymist does not advertise %s; update Tinymist" command))
  (jsonrpc-async-request
   server :workspace/executeCommand
   (list :command command :arguments (vconcat arguments))
   :timeout typemacs-request-timeout
   :success-fn (or success #'ignore)
   :error-fn (or error (lambda (data)
                        (message "Typemacs: %s" (or (plist-get data :message)
                                                   data))))
   :timeout-fn (lambda ()
                 (funcall (or error #'ignore)
                          (list :message (format "%s timed out" command))))))

(defun typemacs-eglot-position (&optional point)
  "Return the LSP position for POINT without moving the current point."
  (save-excursion (eglot--pos-to-lsp-position point)))

(defun typemacs-eglot-point (position)
  "Convert LSP POSITION to a buffer offset without moving point."
  (save-excursion (eglot--lsp-position-to-point position)))

(defun typemacs-eglot-uri-to-path (uri)
  "Convert file URI to a path across supported Eglot versions."
  (if (fboundp 'eglot-uri-to-path)
      (eglot-uri-to-path uri)
    (with-no-warnings (eglot--uri-to-path uri))))

(cl-defmethod eglot-handle-notification
  ((server eglot-lsp-server) (_method (eql tinymist/preview/scrollSource))
   &key filepath start end &allow-other-keys)
  "Forward SERVER's inverse-search notification to the workbench."
  (when (typemacs--server-sessions server)
    ;; Opening a source buffer can itself issue LSP requests.  Leave the
    ;; JSON-RPC dispatcher before doing that work.
    (run-at-time 0 nil #'run-hook-with-args
                 'typemacs-scroll-source-functions server filepath start end)))

(cl-defmethod eglot-handle-notification
  ((server eglot-lsp-server) (_method (eql tinymist/preview/dispose))
   &key taskId &allow-other-keys)
  "Release the preview identified by SERVER and TASKID."
  (dolist (session (typemacs--server-sessions server))
    (when (equal taskId (typemacs-session-task-id session))
      (typemacs--dispose-session session))))

(cl-defmethod eglot-handle-request :around
  ((server eglot-lsp-server) (_method (eql window/showDocument)) &rest params)
  "Route inverse search from pre-existing Eglot connections to Typemacs.
Other showDocument requests retain Eglot's normal behavior."
  (let* ((uri (plist-get params :uri))
         (selection (plist-get params :selection))
         (filepath (and (stringp uri) (string-prefix-p "file:" uri)
                        (typemacs-eglot-uri-to-path uri))))
    (if (and (not (eq t (plist-get params :external)))
             selection filepath
             (cl-some (lambda (session)
                        (file-in-directory-p filepath
                                             (typemacs-session-root session)))
                      (typemacs--server-sessions server)))
        (progn
          (run-at-time
           0 nil #'run-hook-with-args 'typemacs-scroll-source-functions
           server filepath
           (let ((position (plist-get selection :start)))
             (vector (plist-get position :line) (plist-get position :character)))
           (let ((position (plist-get selection :end)))
             (vector (plist-get position :line) (plist-get position :character))))
          '(:success t))
      (cl-call-next-method))))

(defun typemacs-eglot--managed-changed ()
  "Release sessions if Eglot has lost their server connection."
  (unless (eglot-managed-p)
    (when-let* ((session typemacs--session)
                (server (typemacs-session-server session)))
      (unless (jsonrpc-running-p server)
        (dolist (owned (typemacs--server-sessions server))
          (typemacs--dispose-session owned))))))

(add-hook 'eglot-managed-mode-hook #'typemacs-eglot--managed-changed)

(provide 'typemacs-eglot)
;;; typemacs-eglot.el ends here
