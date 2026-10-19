;;; typemacs-session.el --- Typemacs session state -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; State shared by the Eglot, preview, and source-buffer adapters.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup typemacs nil
  "A Typst workbench powered by Tinymist."
  :group 'languages
  :prefix "typemacs-")

(defcustom typemacs-main-file nil
  "Main Typst file, relative to the current source file's directory.
When nil, preview the current file.  Set this in directory-local variables
for projects with multiple source files."
  :type '(choice (const :tag "Current file" nil) file)
  :group 'typemacs)
(make-variable-buffer-local 'typemacs-main-file)

(defcustom typemacs-preview-mode 'document
  "Presentation mode for new preview sessions."
  :type '(choice (const document) (const slide))
  :group 'typemacs)
(make-variable-buffer-local 'typemacs-preview-mode)
(put 'typemacs-preview-mode 'safe-local-variable
     (lambda (value) (memq value '(document slide))))

(cl-defstruct (typemacs-session (:constructor typemacs-session-create))
  "A preview task belonging to an existing Eglot SERVER."
  key root main-file mode server task-id
  (state 'starting) request-sent-p url error-message source-buffers source-window
  preview-buffer preview-window)

(defvar typemacs--sessions (make-hash-table :test #'equal)
  "Preview sessions indexed by root, main file, and presentation mode.")

(defvar-local typemacs--session nil
  "Session associated with the current source or preview buffer.")

(defvar typemacs-session-detached-hook nil
  "Buffer-local cleanup hook run when a buffer leaves a session.")

(defvar typemacs-session-disposed-functions nil
  "Functions called with a SESSION after its local resources are released.")

(defvar typemacs-session-orphaned-functions nil
  "Functions called with a SESSION after it loses its last local owner.")

(defun typemacs--canonical-file (file &optional directory)
  "Return FILE's absolute true name relative to DIRECTORY."
  (file-truename (expand-file-name file directory)))

(defun typemacs--session-key (root main-file mode)
  "Construct a session key from ROOT, MAIN-FILE, and MODE."
  (list (file-name-as-directory (typemacs--canonical-file root))
        (typemacs--canonical-file main-file) mode))

(defun typemacs--session-registered-p (session)
  "Return non-nil if SESSION is still the registered task for its key."
  (eq session (gethash (typemacs-session-key session) typemacs--sessions)))

(defun typemacs--server-sessions (server)
  "Return registered sessions owned by SERVER."
  (let (sessions)
    (maphash (lambda (_key session)
               (when (eq server (typemacs-session-server session))
                 (push session sessions)))
             typemacs--sessions)
    sessions))

(defun typemacs--detach-buffer (&optional buffer)
  "Detach BUFFER, or the current buffer, from its session."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* ((session typemacs--session))
      (setf (typemacs-session-source-buffers session)
            (delq (current-buffer)
                  (typemacs-session-source-buffers session)))
      (setq typemacs--session nil)
      (run-hooks 'typemacs-session-detached-hook)
      (when (and (not (eq (typemacs-session-state session) 'stopped))
                 (null (typemacs-session-source-buffers session))
                 (not (buffer-live-p (typemacs-session-preview-buffer session))))
        (run-hook-with-args 'typemacs-session-orphaned-functions session)))))

(defun typemacs--attach-buffer (session &optional buffer)
  "Associate source BUFFER, or the current buffer, with SESSION."
  (with-current-buffer (or buffer (current-buffer))
    (unless (eq typemacs--session session)
      (typemacs--detach-buffer)
      (setq typemacs--session session)
      (cl-pushnew (current-buffer) (typemacs-session-source-buffers session)))))

(defun typemacs--dispose-session (session)
  "Idempotently release SESSION's local resources.
This does not stop the Eglot server or send a command to Tinymist."
  (unless (eq (typemacs-session-state session) 'stopped)
    (setf (typemacs-session-state session) 'stopped)
    (when (typemacs--session-registered-p session)
      (remhash (typemacs-session-key session) typemacs--sessions))
    (dolist (buffer (copy-sequence (typemacs-session-source-buffers session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq typemacs--session session)
            (typemacs--detach-buffer)))))
    (let* ((buffer (typemacs-session-preview-buffer session))
           (window (typemacs-session-preview-window session))
           (close-window (and (window-live-p window)
                              (eq (window-buffer window) buffer))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          ;; Prevent the preview's kill hook from stopping the task again.
          (setq typemacs--session nil))
        (kill-buffer buffer))
      (when (and close-window (window-live-p window) (window-parent window))
        (delete-window window)))
    (setf (typemacs-session-source-buffers session) nil
          (typemacs-session-preview-buffer session) nil
          (typemacs-session-preview-window session) nil)
    (run-hook-with-args 'typemacs-session-disposed-functions session)
    (force-mode-line-update t)))

(provide 'typemacs-session)
;;; typemacs-session.el ends here
