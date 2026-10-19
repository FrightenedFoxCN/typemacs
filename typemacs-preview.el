;;; typemacs-preview.el --- Preview tasks and browsers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Open Tinymist's own HTTP frontend.  Rendering data never passes through Lisp.

;;; Code:

(require 'browse-url)
(require 'typemacs-eglot)

(declare-function xwidget-webkit-browse-url "xwidget" (url &optional new-session))
(declare-function xwidget-webkit-current-session "xwidget" ())
(declare-function xwidget-resize "xwidget.c" (xwidget width height))

(defcustom typemacs-browser 'auto
  "Browser used to display previews.
`auto' uses xwidget in graphical Emacs when available, otherwise the default
external browser.  A function is called with the preview URL."
  :type '(choice (const auto) (const xwidget) (const external) function)
  :group 'typemacs)

(defcustom typemacs-preview-window-width 0.5
  "Fraction of the frame width used by the preview side window."
  :type 'float
  :group 'typemacs)

(defcustom typemacs-invert-colors 'auto
  "Tinymist preview color inversion strategy."
  :type '(choice (const auto) (const never) (const always))
  :group 'typemacs)

(defvar-local typemacs--preview-window nil
  "Window displaying the current embedded preview.")

(defun typemacs-preview--xwidget-available-p ()
  "Return non-nil when this frame supports embedded WebKit."
  (and (display-graphic-p) (featurep 'xwidget-internal)
       (require 'xwidget nil t) (fboundp 'xwidget-webkit-browse-url)))

(defun typemacs-preview--resize (&rest _)
  "Resize the current preview widget to its live window."
  (when (and (window-live-p typemacs--preview-window)
             (fboundp 'xwidget-webkit-current-session))
    (when-let* ((widget (xwidget-webkit-current-session)))
      (xwidget-resize widget
                      (window-body-width typemacs--preview-window t)
                      (window-body-height typemacs--preview-window t)))))

(defun typemacs-preview--killed ()
  "Stop the task when its embedded preview is killed."
  (when typemacs--session
    (let ((session typemacs--session)
          (window typemacs--preview-window))
      (setq typemacs--session nil)
      (setf (typemacs-session-preview-buffer session) nil)
      (typemacs-preview-stop session)
      (when (and (window-live-p window) (window-parent window))
        (delete-window window)))))

(defun typemacs-preview--open-xwidget (session)
  "Display SESSION in a right-hand side window."
  (unless (typemacs-preview--xwidget-available-p)
    (user-error "This Emacs frame has no xwidget WebKit support"))
  (let ((source-window (selected-window))
        (buffer (typemacs-session-preview-buffer session)))
    (unless (buffer-live-p buffer)
      ;; Do not let xwidget replace the source window while creating its buffer.
      (save-window-excursion
        (xwidget-webkit-browse-url (typemacs-session-url session) t)
        (setq buffer (current-buffer)))
      (setf (typemacs-session-preview-buffer session) buffer)
      (with-current-buffer buffer
        (rename-buffer (format "*Typemacs: %s*"
                               (file-name-nondirectory
                                (typemacs-session-main-file session))) t)
        (setq-local typemacs--session session)
        (add-hook 'kill-buffer-hook #'typemacs-preview--killed nil t)
        (add-hook 'window-size-change-functions #'typemacs-preview--resize nil t)))
    (with-current-buffer buffer
      (setq-local header-line-format nil))
    (let ((window (display-buffer-in-side-window
                   buffer `((side . right) (slot . 0)
                            (window-width . ,typemacs-preview-window-width)))))
      (setf (typemacs-session-preview-window session) window)
      (with-current-buffer buffer
        (setq typemacs--preview-window window)
        (typemacs-preview--resize)))
    (when (window-live-p source-window)
      (select-window source-window))))

(defun typemacs-preview-open (session)
  "Open or reveal SESSION using `typemacs-browser'."
  (unless (eq (typemacs-session-state session) 'running)
    (user-error "Preview is not running (%s)" (typemacs-session-state session)))
  (let ((backend (if (eq typemacs-browser 'auto)
                     (if (typemacs-preview--xwidget-available-p) 'xwidget 'external)
                   typemacs-browser)))
    (pcase backend
      ('xwidget (typemacs-preview--open-xwidget session))
      ('external (browse-url-default-browser (typemacs-session-url session)))
      ((pred functionp) (funcall backend (typemacs-session-url session)))
      (_ (user-error "Invalid Typemacs browser: %S" backend)))))

(defun typemacs-preview--kill-task (session)
  "Ask Tinymist to release SESSION's task without shutting down Eglot."
  (when (jsonrpc-running-p (typemacs-session-server session))
    (condition-case error
        (typemacs-eglot-command
         (typemacs-session-server session) "tinymist.doKillPreview"
         (list (typemacs-session-task-id session))
         :error (lambda (data) (message "Typemacs cleanup: %S" data)))
      (error (message "Typemacs cleanup: %s" (error-message-string error))))))

(defun typemacs-preview-stop (session)
  "Stop SESSION and release its local resources."
  (unless (eq (typemacs-session-state session) 'stopped)
    (typemacs--dispose-session session)
    (typemacs-preview--kill-task session)))

(defun typemacs-preview--failed (session data)
  "Record DATA as SESSION's startup failure and clean up its server task."
  (when (typemacs--session-registered-p session)
    (setf (typemacs-session-state session) 'failed
          (typemacs-session-error-message session)
          (format "%s" (or (plist-get data :message) data)))
    (force-mode-line-update t)
    (message "Typemacs preview failed: %s"
             (typemacs-session-error-message session)))
  (typemacs-preview--kill-task session))

(defun typemacs-preview-start (session &optional open-browser)
  "Start SESSION asynchronously, optionally OPEN-BROWSER when ready."
  (let ((arguments (vector "--task-id" (typemacs-session-task-id session)
                           "--data-plane-host" "127.0.0.1:0"
                           "--no-open" "--preview-mode"
                           (symbol-name (typemacs-session-mode session))
                           "--invert-colors" (symbol-name typemacs-invert-colors)
                           (typemacs-session-main-file session))))
    (condition-case error
        (progn
          (typemacs-eglot-flush (typemacs-session-server session))
          (typemacs-eglot-command
           (typemacs-session-server session) "tinymist.doStartPreview"
           (list arguments)
           :success
           (lambda (result)
             (if (not (and (typemacs--session-registered-p session)
                           (eq (typemacs-session-state session) 'starting)))
                 ;; A stop/restart may have overtaken this asynchronous reply.
                 (typemacs-preview--kill-task session)
               (let ((port (plist-get result :staticServerPort)))
                 (if (not (and (integerp port) (< 0 port 65536)))
                     (typemacs-preview--failed
                      session '(:message "Tinymist returned no valid preview port"))
                   (setf (typemacs-session-url session)
                         (format "http://127.0.0.1:%d/" port)
                         (typemacs-session-error-message session) nil
                         (typemacs-session-state session) 'running)
                   (force-mode-line-update t)
                   (message "Typemacs preview: %s" (typemacs-session-url session))
                   (when open-browser
                     (condition-case error
                         (typemacs-preview-open session)
                       (error (message "Typemacs browser: %s"
                                       (error-message-string error)))))))))
           :error (lambda (data) (typemacs-preview--failed session data))))
      (error (typemacs--dispose-session session)
             (signal (car error) (cdr error)))))
  session)

(add-hook 'typemacs-session-orphaned-functions #'typemacs-preview-stop)

(provide 'typemacs-preview)
;;; typemacs-preview.el ends here
