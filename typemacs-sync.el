;;; typemacs-sync.el --- Source and preview navigation -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Navigation uses Tinymist's source mapping and Eglot's position encoding.

;;; Code:

(require 'pulse)
(require 'typemacs-preview)

(defcustom typemacs-follow-delay 0.15
  "Idle seconds before the preview follows a source cursor movement."
  :type 'number
  :group 'typemacs)

(defcustom typemacs-follow-cursor nil
  "Whether the current source buffer makes its preview follow point."
  :type 'boolean
  :group 'typemacs)
(make-variable-buffer-local 'typemacs-follow-cursor)

(defvar-local typemacs--follow-timer nil)
(defvar-local typemacs--last-position nil)

(defun typemacs-sync-cancel ()
  "Cancel any scheduled forward search in the current buffer."
  (when (timerp typemacs--follow-timer)
    (cancel-timer typemacs--follow-timer))
  (setq typemacs--follow-timer nil
        typemacs--last-position nil))

(defun typemacs-sync-send-position ()
  "Send the current source location to its running preview."
  (unless (and typemacs--session
               (eq (typemacs-session-state typemacs--session) 'running)
               buffer-file-name
               (eq (eglot-current-server)
                   (typemacs-session-server typemacs--session)))
    (user-error "No running preview for this source buffer"))
  (let ((position (typemacs-eglot-position)))
    (typemacs-eglot-flush (typemacs-session-server typemacs--session))
    (typemacs-eglot-command
     (typemacs-session-server typemacs--session) "tinymist.scrollPreview"
     (list (typemacs-session-task-id typemacs--session)
           (list :event "panelScrollTo"
                 :filepath (typemacs--canonical-file buffer-file-name)
                 :line (plist-get position :line)
                 :character (plist-get position :character))))))

(defun typemacs-sync--follow (buffer position)
  "Follow BUFFER's point if it still equals POSITION."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq typemacs--follow-timer nil)
      (when (and typemacs-follow-cursor typemacs--session
                 (eq (typemacs-session-state typemacs--session) 'running)
                 (equal position (cons (point) (buffer-chars-modified-tick))))
        (condition-case error
            (typemacs-sync-send-position)
          (error (message "Typemacs follow: %s" (error-message-string error))))))))

(defun typemacs-sync-post-command ()
  "Schedule a debounced forward search after source movement."
  (when (and typemacs-follow-cursor typemacs--session
             (eq (typemacs-session-state typemacs--session) 'running))
    (let ((position (cons (point) (buffer-chars-modified-tick))))
      (unless (equal position typemacs--last-position)
        (typemacs-sync-cancel)
        (setq typemacs--last-position position
              typemacs--follow-timer
              (run-with-idle-timer typemacs-follow-delay nil
                                   #'typemacs-sync--follow
                                   (current-buffer) position))))))

(defun typemacs-sync--coordinates-p (value)
  "Return non-nil when VALUE contains valid line/character coordinates."
  (and (sequencep value) (= (length value) 2)
       (natnump (elt value 0)) (natnump (elt value 1))))

(defun typemacs-sync-reveal-source (server filepath start end)
  "Reveal SERVER's source range FILEPATH, START, END in a source window."
  (when (and (stringp filepath) (not (file-remote-p filepath))
             (typemacs-sync--coordinates-p start))
    (let* ((file (typemacs--canonical-file filepath))
           (sessions (typemacs--server-sessions server))
           (existing (find-buffer-visiting file))
           (session
            (or (and existing
                     (with-current-buffer existing
                       (and (memq typemacs--session sessions) typemacs--session)))
                (cl-find-if (lambda (candidate)
                              (file-in-directory-p file
                                                   (typemacs-session-root candidate)))
                            sessions))))
      (when (and session (file-readable-p file))
        (let* ((buffer (or existing (find-file-noselect file)))
               (window (typemacs-session-source-window session)))
          (with-current-buffer buffer
            ;; Avoid displaying source attached to a different server/session.
            (when (eq (eglot-current-server) server)
              (typemacs--attach-buffer session)
              (unless (window-live-p window)
                (setq window
                      (display-buffer buffer
                                      '((display-buffer-reuse-window
                                         display-buffer-pop-up-window)
                                        (inhibit-same-window . t)))))
              (set-window-buffer window buffer)
              (setf (typemacs-session-source-window session) window)
              (select-window window)
              (widen)
              (goto-char (typemacs-eglot-point
                          (list :line (elt start 0) :character (elt start 1))))
              (let ((finish (if (typemacs-sync--coordinates-p end)
                                (typemacs-eglot-point
                                 (list :line (elt end 0) :character (elt end 1)))
                              (line-end-position))))
                ;; Suppress the resulting post-command forward search.
                (typemacs-sync-cancel)
                (setq typemacs--last-position
                      (cons (point) (buffer-chars-modified-tick)))
                (pulse-momentary-highlight-region (point) (max (point) finish)))
              (recenter))))))))

(add-hook 'typemacs-scroll-source-functions #'typemacs-sync-reveal-source)

(provide 'typemacs-sync)
;;; typemacs-sync.el ends here
