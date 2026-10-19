;;; typemacs.el --- A Typst workbench for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Typemacs contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, tools, multimedia

;;; Commentary:
;; Run `typemacs-setup', open a .typ file, and run `typemacs-start'.
;; Tinymist supplies language features and its own live web preview.
;; Existing typst-ts-mode/typst-mode installations are supported; the small
;; `typemacs-source-mode' is a fallback that needs no tree-sitter grammar.

;;; Code:

(require 'typemacs-sync)

(defvar-local typemacs--pending-start nil
  "Main file and browser preference awaiting an Eglot connection.")

(defvar typemacs-source-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124b" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\" "\"" table)
    table)
  "Syntax table for the minimal Typst fallback mode.")

;;;###autoload
(define-derived-mode typemacs-source-mode prog-mode "Typst"
  "Minimal Typst source mode for trying Typemacs.
For full syntax highlighting and indentation, install `typst-ts-mode'."
  :syntax-table typemacs-source-mode-syntax-table
  (setq-local comment-start "// "
              comment-end ""
              font-lock-defaults
              '((("^=+ .*" . font-lock-function-name-face)
                 ("#[[:alpha:]_][[:alnum:]_-]*" . font-lock-keyword-face)))))

(defvar typemacs-mode-map
  (let ((map (make-sparse-keymap))
        (prefix (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") prefix)
    (dolist (binding '(("p" . typemacs-start) ("q" . typemacs-stop)
                       ("r" . typemacs-restart) ("o" . typemacs-open-preview)
                       ("j" . typemacs-forward-search)
                       ("f" . typemacs-toggle-follow)
                       ("m" . typemacs-set-main-file) ("s" . typemacs-status)
                       ("w" . typemacs-switch-window)))
      (define-key prefix (kbd (car binding)) (cdr binding)))
    map)
  "Keymap for `typemacs-mode'.")

(defun typemacs--source-killed ()
  "Detach the current source and stop a session with no remaining owner."
  (setq typemacs--pending-start nil)
  (typemacs-sync-cancel)
  (when-let* ((session typemacs--session))
    (typemacs--detach-buffer)
    (unless (or (typemacs-session-source-buffers session)
                (buffer-live-p (typemacs-session-preview-buffer session)))
      (typemacs-preview-stop session))))

;;;###autoload
(define-minor-mode typemacs-mode
  "Enable Typemacs workbench commands in the current source buffer.
Enabling this mode alone does not start a language server or preview."
  :lighter " TypeM"
  :keymap typemacs-mode-map
  (if typemacs-mode
      (progn
        (add-hook 'post-command-hook #'typemacs-sync-post-command nil t)
        (add-hook 'kill-buffer-hook #'typemacs--source-killed nil t)
        (add-hook 'change-major-mode-hook #'typemacs--source-killed nil t)
        (add-hook 'typemacs-session-detached-hook #'typemacs-sync-cancel nil t))
    (typemacs--source-killed)
    (remove-hook 'post-command-hook #'typemacs-sync-post-command t)
    (remove-hook 'kill-buffer-hook #'typemacs--source-killed t)
    (remove-hook 'change-major-mode-hook #'typemacs--source-killed t)
    (remove-hook 'typemacs-session-detached-hook #'typemacs-sync-cancel t)))

;;;###autoload
(defun typemacs-setup ()
  "Register Typst modes with Eglot and enable workbench commands.
Existing servers are reused; their connections are never restarted here.
An existing .typ auto-mode association takes precedence over the fallback."
  (interactive)
  (add-to-list 'eglot-server-programs
               '(((typst-ts-mode :language-id "typst")
                  (typst-mode :language-id "typst")
                  (typemacs-source-mode :language-id "typst"))
                 . typemacs-eglot-contact))
  (add-to-list 'auto-mode-alist '("\\.typ\\'" . typemacs-source-mode) t)
  (dolist (hook '(typst-ts-mode-hook typst-mode-hook typemacs-source-mode-hook))
    (add-hook hook #'typemacs-mode))
  (add-hook 'eglot-managed-mode-hook #'typemacs--managed-changed))

(defun typemacs--check-source ()
  "Check that the current buffer visits a local Typst file."
  (unless (and buffer-file-name
               (string-equal (file-name-extension buffer-file-name) "typ"))
    (user-error "Open a .typ source file first"))
  (when (file-remote-p buffer-file-name)
    (user-error "Remote Typst previews are not supported yet")))

(defun typemacs--main-file (&optional file)
  "Resolve FILE or the buffer's configured main file."
  (typemacs--canonical-file (or file typemacs-main-file buffer-file-name)
                           (file-name-directory buffer-file-name)))

(defun typemacs--managed-changed ()
  "Complete a requested start once Eglot begins managing this buffer."
  (when (and (eglot-managed-p) typemacs--pending-start)
    ;; Finish Eglot's initialize/configuration dispatch before issuing commands.
    (run-at-time 0 nil #'typemacs--start-when-ready (current-buffer))))

(defun typemacs--start-when-ready (buffer)
  "Finish BUFFER's pending start outside the JSON-RPC dispatcher."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (eglot-managed-p) typemacs--pending-start)
        (let ((pending typemacs--pending-start))
          (setq typemacs--pending-start nil)
          (condition-case error
              (typemacs-start (car pending) (cadr pending))
            (error (message "Typemacs: %s" (error-message-string error)))))))))

(defun typemacs--attach-related-buffers (session)
  "Attach managed buffers explicitly configured for SESSION's main file."
  (dolist (buffer (eglot--managed-buffers (typemacs-session-server session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and buffer-file-name
                   (equal (file-name-extension buffer-file-name) "typ")
                   (equal (typemacs--main-file)
                          (typemacs-session-main-file session)))
          (typemacs-mode 1)
          (typemacs--attach-buffer session))))))

;;;###autoload
(defun typemacs-start (&optional main-file no-browser)
  "Start or reveal a preview for MAIN-FILE using the existing Eglot server.
Default to `typemacs-main-file', then the current file.  With a prefix
argument, prompt for the main file.  NO-BROWSER starts the task headlessly.
Return the session, or nil while waiting for the Eglot connection."
  (interactive (list (when current-prefix-arg
                       (read-file-name "Main Typst file: " nil nil t)) nil))
  (typemacs--check-source)
  (when (file-remote-p (or main-file typemacs-main-file ""))
    (user-error "Remote main files are not supported yet"))
  (typemacs-setup)
  (typemacs-mode 1)
  (let* ((main (typemacs--main-file main-file))
         (server (eglot-current-server)))
    (unless (and (file-readable-p main) (not (file-directory-p main)))
      (user-error "Save the main Typst file before starting its first preview"))
    (unless (memq typemacs-preview-mode '(document slide))
      (user-error "Invalid preview mode: %S" typemacs-preview-mode))
    (when main-file (setq-local typemacs-main-file main))
    (if (not (and server (eglot-managed-p) (jsonrpc-running-p server)))
        (progn
          (unless (executable-find (car typemacs-tinymist-command))
            (user-error "Cannot find %s in exec-path"
                        (car typemacs-tinymist-command)))
          (setq typemacs--pending-start (list main no-browser))
          (eglot-ensure)
          (message "Typemacs: connecting to Tinymist…")
          nil)
      (setq typemacs--pending-start nil)
      (let* ((root (typemacs-eglot-root server))
             (key (typemacs--session-key root main typemacs-preview-mode))
             (session (gethash key typemacs--sessions)))
        (unless (file-in-directory-p main root)
          (user-error "Main file must be inside the Eglot project: %s" root))
        (unless (typemacs-eglot-command-supported-p server "tinymist.doStartPreview")
          (user-error "The Eglot server has no Tinymist preview support"))
        (when (and session
                   (or (not (eq server (typemacs-session-server session)))
                       (memq (typemacs-session-state session) '(failed stopped))))
          (typemacs-preview-stop session)
          (setq session nil))
        (unless session
          (setq session
                (typemacs-session-create
                 :key key :root root :main-file main :mode typemacs-preview-mode
                 :server server :task-id
                 (format "typemacs-%s" (md5 (format "%s:%s:%s" key (float-time)
                                                     (random))))))
          (puthash key session typemacs--sessions))
        (typemacs--attach-buffer session)
        (typemacs--attach-related-buffers session)
        (when-let* ((window (get-buffer-window (current-buffer) t)))
          (setf (typemacs-session-source-window session) window))
        (cond
         ((eq (typemacs-session-state session) 'running)
          (unless no-browser (typemacs-preview-open session)))
         ((not (typemacs-session-url session))
          ;; Mark the request as sent so another start during startup reuses it.
          (unless (typemacs-session-request-sent-p session)
            (setf (typemacs-session-request-sent-p session) t)
            (typemacs-preview-start session (not no-browser)))))
        session))))

(defun typemacs--current-session ()
  "Return this buffer's registered session, or raise a user error."
  (unless (and typemacs--session
               (typemacs--session-registered-p typemacs--session))
    (user-error "No Typemacs session; run M-x typemacs-start"))
  typemacs--session)

;;;###autoload
(defun typemacs-stop ()
  "Stop this buffer's preview task without shutting down Eglot."
  (interactive)
  (if typemacs--pending-start
      (setq typemacs--pending-start nil)
    (typemacs-preview-stop (typemacs--current-session)))
  (message "Typemacs preview stopped"))

;;;###autoload
(defun typemacs-restart ()
  "Restart the current session's preview, retaining its main file and mode."
  (interactive)
  (let* ((session (typemacs--current-session))
         (main (typemacs-session-main-file session))
         (mode (typemacs-session-mode session))
         (source (if (memq (current-buffer)
                           (typemacs-session-source-buffers session))
                     (current-buffer)
                   (car (typemacs-session-source-buffers session)))))
    (unless (buffer-live-p source)
      (setq source (find-file-noselect main)))
    (typemacs-preview-stop session)
    (with-current-buffer source
      (setq-local typemacs-preview-mode mode)
      (typemacs-start main))))

;;;###autoload
(defun typemacs-open-preview ()
  "Open or reveal the current session's preview."
  (interactive)
  (typemacs-preview-open (typemacs--current-session)))

;;;###autoload
(defun typemacs-forward-search ()
  "Reveal the current source location in its preview."
  (interactive)
  (typemacs-sync-send-position))

;;;###autoload
(defun typemacs-toggle-follow ()
  "Toggle preview cursor following for the current source buffer."
  (interactive)
  (setq typemacs-follow-cursor (not typemacs-follow-cursor))
  (typemacs-sync-cancel)
  (when typemacs-follow-cursor (typemacs-sync-post-command))
  (message "Typemacs cursor following %s" (if typemacs-follow-cursor "on" "off")))

;;;###autoload
(defun typemacs-set-main-file (file)
  "Set FILE as this buffer's main file and start its preview."
  (interactive (list (read-file-name "Main Typst file: " nil nil t)))
  (typemacs-start file))

;;;###autoload
(defun typemacs-switch-window ()
  "Switch focus between this session's source and embedded preview windows."
  (interactive)
  (let* ((session (typemacs--current-session))
         (target (if (eq (current-buffer)
                         (typemacs-session-preview-buffer session))
                     (typemacs-session-source-window session)
                   (typemacs-session-preview-window session))))
    (unless (window-live-p target)
      (user-error "No matching source/embedded preview window is visible"))
    (select-window target)))

;;;###autoload
(defun typemacs-status ()
  "Show the current preview's state, main file, and address."
  (interactive)
  (if typemacs--pending-start
      (message "Typemacs: waiting for Eglot (%s)" (car typemacs--pending-start))
    (let ((session (typemacs--current-session)))
      (message "Typemacs: %s | %s%s"
               (typemacs-session-state session)
               (typemacs-session-main-file session)
               (if (eq (typemacs-session-state session) 'failed)
                   (format " | %s" (typemacs-session-error-message session))
                 (if (typemacs-session-url session)
                     (format " | %s" (typemacs-session-url session)) ""))))))

(provide 'typemacs)
;;; typemacs.el ends here
