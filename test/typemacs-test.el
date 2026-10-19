;;; typemacs-test.el --- Workbench regression tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'typemacs)

(defvar typst-ts-mode-hook nil)
(defvar typst-mode-hook nil)

(defmacro typemacs-test--isolated (&rest body)
  "Run BODY without real server or browser side effects."
  (declare (indent 0))
  `(let ((typemacs--sessions (make-hash-table :test #'equal))
         (typemacs-session-disposed-functions nil)
         (typemacs-session-orphaned-functions nil))
     ,@body))

(defun typemacs-test--session (&rest properties)
  "Create and register a test session with PROPERTIES."
  (let ((arguments (list :key '("/project/" "/project/main.typ" document)
                         :root "/project/" :main-file "/project/main.typ"
                         :mode 'document :server 'test-server :task-id "test-task")))
    (while properties
      (setq arguments (plist-put arguments (pop properties) (pop properties))))
    (let ((session (apply #'typemacs-session-create arguments)))
    (puthash (typemacs-session-key session) session typemacs--sessions)
      session)))

(ert-deftest typemacs-test-position-roundtrip-unicode-tab-and-narrowing ()
  (with-temp-buffer
    (insert "first\n中😀\tZ\nlast\n")
    (setq-local eglot-current-linepos-function #'eglot-utf-16-linepos
                eglot-move-to-linepos-function #'eglot-move-to-utf-16-linepos)
    (goto-char (point-min))
    (forward-line)
    (forward-char 3)
    (let ((point (point)))
      (narrow-to-region (line-beginning-position) (line-end-position))
      (should (equal (typemacs-eglot-position) '(:line 1 :character 4)))
      (should (= (typemacs-eglot-point '(:line 1 :character 4)) point))
      (should (= (point) point))
      (should (= (point-min) 7)))))

(ert-deftest typemacs-test-position-respects-eglot-negotiated-encoding ()
  (with-temp-buffer
    (insert "中😀Z")
    (goto-char 3)
    (setq-local eglot-current-linepos-function #'eglot-utf-8-linepos
                eglot-move-to-linepos-function #'eglot-move-to-utf-8-linepos)
    (should (equal (typemacs-eglot-position) '(:line 0 :character 7)))
    (should (= (typemacs-eglot-point '(:line 0 :character 7)) 3))))

(ert-deftest typemacs-test-startup-cancel-late-reply-kills-task ()
  (typemacs-test--isolated
    (let ((session (typemacs-test--session)) success calls opened)
      (cl-letf (((symbol-function 'typemacs-eglot-flush) #'ignore)
                ((symbol-function 'jsonrpc-running-p) (lambda (_) t))
                ((symbol-function 'typemacs-eglot-command)
                 (lambda (_server command _arguments &rest callbacks)
                   (push command calls)
                   (when (equal command "tinymist.doStartPreview")
                     (setq success (plist-get callbacks :success)))))
                ((symbol-function 'typemacs-preview-open)
                 (lambda (_) (setq opened t))))
        (typemacs-preview-start session t)
        (typemacs-preview-stop session)
        (funcall success '(:staticServerPort 12345))
        (should-not opened)
        (should (= (hash-table-count typemacs--sessions) 0))
        ;; Kill both at cancellation and after an overtaken start response.
        (should (= (cl-count "tinymist.doKillPreview" calls :test #'equal) 2))
        (should (eq (typemacs-session-state session) 'stopped))))))

(ert-deftest typemacs-test-preview-failure-and-invalid-port-cleanup ()
  (typemacs-test--isolated
    (let ((session (typemacs-test--session)) success killed)
      (cl-letf (((symbol-function 'typemacs-eglot-flush) #'ignore)
                ((symbol-function 'jsonrpc-running-p) (lambda (_) t))
                ((symbol-function 'typemacs-eglot-command)
                 (lambda (_server command _arguments &rest callbacks)
                   (if (equal command "tinymist.doStartPreview")
                       (setq success (plist-get callbacks :success))
                     (setq killed t)))))
        (typemacs-preview-start session)
        (funcall success '(:staticServerPort 0))
        (should (eq (typemacs-session-state session) 'failed))
        (should (string-match-p "port" (typemacs-session-error-message session)))
        (should killed)))))

(ert-deftest typemacs-test-stale-disposal-does-not-remove-new-session ()
  (typemacs-test--isolated
    (let* ((old (typemacs-test--session))
           (new (typemacs-test--session :task-id "replacement")))
      (typemacs--dispose-session old)
      (should (eq (gethash (typemacs-session-key new) typemacs--sessions) new))
      (should (eq (typemacs-session-state new) 'starting)))))

(ert-deftest typemacs-test-dispose-detaches-buffers-and-cancels-timers ()
  (typemacs-test--isolated
    (let ((session (typemacs-test--session)) disposed)
      (with-temp-buffer
        (typemacs-mode 1)
        (typemacs--attach-buffer session)
        (setq typemacs--follow-timer (run-at-time 3600 nil #'ignore))
        (add-hook 'typemacs-session-disposed-functions
                  (lambda (_) (push t disposed)))
        (typemacs--dispose-session session)
        (typemacs--dispose-session session)
        (should-not typemacs--session)
        (should-not typemacs--follow-timer)
        (should (= (length disposed) 1))))))

(ert-deftest typemacs-test-detaching-one-chapter-retains-shared-session ()
  (typemacs-test--isolated
    (let ((session (typemacs-test--session))
          (chapter (generate-new-buffer " chapter")) orphaned)
      (unwind-protect
          (with-temp-buffer
            (typemacs--attach-buffer session)
            (typemacs--attach-buffer session chapter)
            (add-hook 'typemacs-session-orphaned-functions
                      (lambda (_) (setq orphaned t)))
            (typemacs--detach-buffer chapter)
            (should-not orphaned)
            (should (eq typemacs--session session))
            (typemacs--detach-buffer)
            (should orphaned))
        (kill-buffer chapter)))))

(ert-deftest typemacs-test-dispose-notification-is-server-and-task-scoped ()
  (typemacs-test--isolated
    (let* ((process (make-pipe-process :name "typemacs-test" :noquery t))
           (server (make-instance 'eglot-lsp-server :name "test" :process process))
           (session (typemacs-test--session :server server)))
      (unwind-protect
          (progn
            (eglot-handle-notification server 'tinymist/preview/dispose
                                      :taskId "different-task")
            (should (typemacs--session-registered-p session))
            (eglot-handle-notification server 'tinymist/preview/dispose
                                      :taskId "test-task")
            (should (eq (typemacs-session-state session) 'stopped)))
        (delete-process process)))))

(ert-deftest typemacs-test-start-reuses-pending-task ()
  (typemacs-test--isolated
    (let* ((directory (make-temp-file "typemacs-test-" t))
           (file (expand-file-name "main.typ" directory))
           (server 'test-server) (requests 0))
      (unwind-protect
          (progn
            (write-region "= Test\n" nil file nil 'silent)
            (with-temp-buffer
              (setq buffer-file-name file default-directory directory)
              (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                        ((symbol-function 'eglot-managed-p) (lambda () t))
                        ((symbol-function 'jsonrpc-running-p) (lambda (_) t))
                        ((symbol-function 'typemacs-eglot-root)
                         (lambda (_) (file-name-as-directory directory)))
                        ((symbol-function 'typemacs-eglot-command-supported-p)
                         (lambda (&rest _) t))
                        ((symbol-function 'typemacs--attach-related-buffers) #'ignore)
                        ((symbol-function 'typemacs-preview-start)
                         (lambda (_session &optional _open)
                           (cl-incf requests))))
                (let ((session (typemacs-start nil t)))
                  (should (eq session (typemacs-start nil t)))
                  (should (= requests 1))
                  (should (= (hash-table-count typemacs--sessions) 1))
                  (typemacs--dispose-session session)))))
        (delete-directory directory t)))))

(ert-deftest typemacs-test-main-file-relative-to-source-directory ()
  (with-temp-buffer
    (setq buffer-file-name "/project/chapters/intro.typ"
          default-directory "/elsewhere/"
          typemacs-main-file "../main.typ")
    (should (equal (typemacs--main-file) "/project/main.typ"))))

(ert-deftest typemacs-test-inverse-search-preserves-preview-and-source-window ()
  (typemacs-test--isolated
    (let* ((directory (file-name-as-directory
                       (file-truename (make-temp-file "typemacs-jump-" t))))
           (file (expand-file-name "chapter.typ" directory))
           (preview (generate-new-buffer " preview"))
           source session)
      (unwind-protect
          (save-window-excursion
            (write-region "first\n中😀\tZ\n" nil file nil 'silent)
            (setq source (find-file-noselect file)
                  session (typemacs-test--session :root directory
                                                 :main-file file :state 'running))
            (set-window-buffer (selected-window) source)
            (setf (typemacs-session-source-window session) (selected-window)
                  (typemacs-session-preview-buffer session) preview
                  (typemacs-session-preview-window session) (split-window-right))
            (set-window-buffer (typemacs-session-preview-window session) preview)
            (with-current-buffer source (typemacs--attach-buffer session))
            (select-window (typemacs-session-preview-window session))
            (cl-letf (((symbol-function 'eglot-current-server)
                       (lambda () 'test-server)))
              (typemacs-sync-reveal-source 'test-server file [1 4] [1 5]))
            (should (eq (selected-window) (typemacs-session-source-window session)))
            (should (eq (window-buffer (typemacs-session-preview-window session))
                        preview))
            (with-current-buffer source
              (should (eq (char-after) ?Z))
              (should (equal typemacs--last-position
                             (cons (point) (buffer-chars-modified-tick))))))
        (when session (typemacs--dispose-session session))
        (when (buffer-live-p source) (kill-buffer source))
        (when (buffer-live-p preview) (kill-buffer preview))
        (delete-directory directory t)))))

(ert-deftest typemacs-test-cancel-before-eglot-connect-does-not-start-preview ()
  (with-temp-buffer
    (let (started)
      (setq typemacs--pending-start '("/project/main.typ" t))
      (typemacs-stop)
      (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
                ((symbol-function 'typemacs-start)
                 (lambda (&rest _) (setq started t))))
        (typemacs--start-when-ready (current-buffer)))
      (should-not started))))

(ert-deftest typemacs-test-follow-does-not-queue-after-disposal ()
  (typemacs-test--isolated
    (with-temp-buffer
      (let ((session (typemacs-test--session :state 'running)) sent)
        (typemacs-mode 1)
        (typemacs--attach-buffer session)
        (setq typemacs-follow-cursor t)
        (typemacs-sync-post-command)
        (should (timerp typemacs--follow-timer))
        (typemacs--dispose-session session)
        (cl-letf (((symbol-function 'typemacs-sync-send-position)
                   (lambda () (setq sent t))))
          (typemacs-sync--follow (current-buffer)
                                 (cons (point) (buffer-chars-modified-tick))))
        (should-not sent)))))

(ert-deftest typemacs-test-major-mode-change-releases-source-and-timer ()
  (typemacs-test--isolated
    (with-temp-buffer
      (let ((session (typemacs-test--session :state 'running)) orphaned)
        (typemacs-mode 1)
        (typemacs--attach-buffer session)
        (setq typemacs--follow-timer (run-at-time 3600 nil #'ignore))
        (add-hook 'typemacs-session-orphaned-functions
                  (lambda (_) (setq orphaned t)))
        (cl-letf (((symbol-function 'jsonrpc-running-p) (lambda (_) nil)))
          (fundamental-mode))
        (should orphaned)
        (should-not (typemacs-session-source-buffers session))
        (should-not typemacs--follow-timer)))))

(ert-deftest typemacs-test-auto-browser-fallback-and-custom-function ()
  (typemacs-test--isolated
    (let ((session (typemacs-test--session :state 'running :url "http://127.0.0.1:1/"))
          (typemacs-browser 'auto) opened)
      (cl-letf (((symbol-function 'typemacs-preview--xwidget-available-p)
                 (lambda () nil))
                ((symbol-function 'browse-url-default-browser)
                 (lambda (url &rest _) (setq opened url))))
        (typemacs-preview-open session)
        (should (equal opened (typemacs-session-url session))))
      (let ((typemacs-browser (lambda (url) (setq opened (concat url "custom")))))
        (typemacs-preview-open session)
        (should (equal opened "http://127.0.0.1:1/custom"))))))

(ert-deftest typemacs-test-forward-search-flushes-before-command ()
  (typemacs-test--isolated
    (with-temp-buffer
      (insert "中😀\tZ")
      (setq buffer-file-name "/project/chapter.typ"
            typemacs--session (typemacs-test--session :state 'running))
      (let (events arguments)
        (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'test-server))
                  ((symbol-function 'typemacs-eglot-flush)
                   (lambda (_) (push 'flush events)))
                  ((symbol-function 'typemacs-eglot-command)
                   (lambda (_server command args &rest _)
                     (push command events) (setq arguments args))))
          (typemacs-sync-send-position)
          (should (equal (reverse events) '(flush "tinymist.scrollPreview")))
          (should (equal (car arguments) "test-task"))
          (should (= (plist-get (cadr arguments) :character) 5)))))))

(ert-deftest typemacs-test-invalid-source-does-not-start-a-server ()
  (with-temp-buffer
    (should-error (typemacs-start) :type 'user-error)
    (setq buffer-file-name "/ssh:host:/project/main.typ")
    (should-error (typemacs-start) :type 'user-error)))

(ert-deftest typemacs-test-setup-is-idempotent-and-preserves-mode-choice ()
  (let ((eglot-server-programs nil)
        (auto-mode-alist '(("\\.typ\\'" . typst-ts-mode)))
        (typst-ts-mode-hook nil) (typst-mode-hook nil)
        (typemacs-source-mode-hook nil) (eglot-managed-mode-hook nil))
    (typemacs-setup)
    (typemacs-setup)
    (should (= (length eglot-server-programs) 1))
    (should (eq (assoc-default "example.typ" auto-mode-alist #'string-match)
                'typst-ts-mode))
    (should (= (cl-count #'typemacs-mode typst-ts-mode-hook) 1))))

(provide 'typemacs-test)
;;; typemacs-test.el ends here
