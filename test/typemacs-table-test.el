;;; typemacs-table-test.el --- Table editing regression tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'typemacs)

(defmacro typemacs-table-test--with (source &rest body)
  "Run BODY in a source buffer containing SOURCE, with point at its ¦ marker."
  (declare (indent 1))
  `(with-temp-buffer
     (typemacs-source-mode)
     (typemacs-mode 1)
     (insert ,source)
     (goto-char (point-min))
     (when (search-forward "¦" nil t) (delete-char -1))
     ,@body))

(defun typemacs-table-test--cells ()
  "Return the current table's section cell texts in source order."
  (mapcar (lambda (section)
            (mapcar #'typemacs-table--arg-text (typemacs-table--section-cells section)))
          (typemacs-table--sections (typemacs-table--context))))

(defun typemacs-table-test--at (text)
  "Place point just inside the first occurrence of TEXT in the buffer."
  (goto-char (point-min))
  (search-forward text)
  (backward-char (1- (length text))))

(ert-deftest typemacs-table-test-insert-and-validate-dimensions ()
  (typemacs-table-test--with ""
    (typemacs-table-insert 2 2)
    (should (equal (buffer-string) "#table(\n  columns: 2,\n  [],  [],\n  [],  [],\n)"))
    (should (eq (char-before) ?\[))
    (should (eq (char-after) ?\]))
    (should (eq (key-binding (kbd "TAB")) #'typemacs-table-next-field)))
  (dolist (dimensions '((0 2) (2 -1) (1.5 2) (2 nil)))
    (with-temp-buffer
      (should-error (apply #'typemacs-table-insert dimensions) :type 'user-error)
      (should (equal (buffer-string) "")))))

(ert-deftest typemacs-table-test-align-and-preserve-point ()
  (typemacs-table-test--with "#table(columns: 2, [a¦bc], [bb], [longer], [d])"
    (typemacs-table-align)
    (should (equal (buffer-string)
                   "#table(\n  columns: 2,\n  [abc],     [bb],\n  [longer],  [d],\n)"))
    (should (eq (char-after) ?b))
    (set-buffer-modified-p nil)
    (let ((tick (buffer-chars-modified-tick)) (position (point)))
      (typemacs-table-align)
      (should (= tick (buffer-chars-modified-tick)))
      (should (= position (point)))
      (should-not (buffer-modified-p)))))

(ert-deftest typemacs-table-test-align-unicode-by-display-width ()
  (typemacs-table-test--with "#table(columns: 2, [¦中文], [😀], [abc], [tail])"
    (typemacs-table-align)
    (let ((first (save-excursion (search-forward "[😀]") (- (current-column) 4)))
          (second (save-excursion (search-forward "[tail]") (- (current-column) 6))))
      (should (= first second)))))

(ert-deftest typemacs-table-test-tab-backtab-and-append ()
  (typemacs-table-test--with "#table(columns: 2, [¦a], [b])"
    (typemacs-table-previous-field)
    (should (eq (char-after) ?a))
    (typemacs-table-next-field)
    (should (eq (char-after) ?b))
    (typemacs-table-next-field)
    (should (eq (char-after) ?\]))
    (should (equal (typemacs-table-test--cells) '(("[a]" "[b]" "[]" "[]"))))
    (typemacs-table-previous-field)
    (should (eq (char-after) ?b))))

(ert-deftest typemacs-table-test-return-keeps-column ()
  (typemacs-table-test--with "#table(columns: 2, [a], [¦b], [c], [d])"
    (typemacs-table-next-row)
    (should (eq (char-after) ?d))
    (typemacs-table-next-row)
    (should (eq (char-after) ?\]))
    (let* ((model (typemacs-table--context)) (location (typemacs-table--location model)))
      (should (= (cadr location) 5)))))

(ert-deftest typemacs-table-test-header-body-footer-navigation ()
  (typemacs-table-test--with
      "#table(columns: 2, table.header([H1], [¦H2]), [a], [b], table.footer([F1], [F2]))"
    (typemacs-table-next-field)
    (should (eq (char-after) ?a))
    (typemacs-table-previous-field)
    (should (looking-at "H2"))
    (typemacs-table-next-row)
    (should (eq (char-after) ?b))
    (typemacs-table-next-row)
    (should (looking-at "F2"))))

(ert-deftest typemacs-table-test-row-insert-delete-and-move ()
  (typemacs-table-test--with "#table(columns: 2, [a], [b], [¦c], [d])"
    (typemacs-table-insert-row)
    (should (equal (typemacs-table-test--cells) '(("[a]" "[b]" "[]" "[]" "[c]" "[d]"))))
    (typemacs-table-delete-row)
    (should (looking-at "c"))
    (typemacs-table-move-row-up)
    (should (equal (typemacs-table-test--cells) '(("[c]" "[d]" "[a]" "[b]"))))
    (should (looking-at "c"))
    (typemacs-table-move-row-down)
    (should (equal (typemacs-table-test--cells) '(("[a]" "[b]" "[c]" "[d]"))))))

(ert-deftest typemacs-table-test-column-operations-cover-all-sections-and-tracks ()
  (typemacs-table-test--with
      "#table(columns: (1fr, 2fr), inset: 4pt, table.header(repeat: true, [H1], [H2]), [a], [¦b], table.footer([F1], [F2]))"
    (typemacs-table-insert-column)
    (should (equal (typemacs-table-test--cells)
                   '(("[H1]" "[]" "[H2]") ("[a]" "[]" "[b]") ("[F1]" "[]" "[F2]"))))
    (should (string-match-p "columns: (1fr, auto, 2fr,)" (buffer-string)))
    (typemacs-table-delete-column)
    (should (looking-at "b"))
    (typemacs-table-move-column-left)
    (should (looking-at "b"))
    (should (equal (typemacs-table-test--cells)
                   '(("[H2]" "[H1]") ("[b]" "[a]") ("[F2]" "[F1]"))))
    (should (string-match-p "columns: (2fr, 1fr,)" (buffer-string)))
    (should (string-match-p "inset: 4pt" (buffer-string)))
    (should (string-match-p "repeat: true" (buffer-string)))
    (typemacs-table-move-column-right)
    (should (equal (typemacs-table-test--cells)
                   '(("[H1]" "[H2]") ("[a]" "[b]") ("[F1]" "[F2]"))))))

(ert-deftest typemacs-table-test-default-columns-and-incomplete-row ()
  (typemacs-table-test--with "#table([¦a], [b])"
    (typemacs-table-insert-column)
    (should (string-match-p "columns: 2" (buffer-string)))
    (should (equal (typemacs-table-test--cells) '(("[]" "[a]" "[]" "[b]")))))
  (typemacs-table-test--with "#table(columns: 2, [a], [b], [¦c])"
    (typemacs-table-move-column-right)
    (should (equal (typemacs-table-test--cells) '(("[b]" "[a]" "[]" "[c]"))))))

(ert-deftest typemacs-table-test-inherited-columns-require-an-explicit-count ()
  (typemacs-table-test--with "#set table(columns: 2)\n#table([¦a], [b])"
    (let ((before (buffer-string)))
      (should-error (typemacs-table-align) :type 'user-error)
      (should (equal before (buffer-string)))))
  (dolist (source '("#set table(columns: 3)\n#table(columns: 2, [¦a], [b])"
                    "#set table(stroke: none)\n#table([¦a])"))
    (typemacs-table-test--with source
      (typemacs-table-align)
      (should (typemacs-table--context t)))))

(ert-deftest typemacs-table-test-nested-content-strings-and-math ()
  (typemacs-table-test--with
      "#table(columns: (auto, calc.max(1pt, 2pt)), [¦A, (B), \"quote [nested]\"], text(\"x,y\"), [$ f(x, y) $], [escaped \\[ bracket])"
    (let ((before (typemacs-table-test--cells)))
      (typemacs-table-align)
      (should (equal before (typemacs-table-test--cells)))
      (should (= (length (car before)) 4)))
    (typemacs-table-next-field)
    (should (looking-at "text("))))

(ert-deftest typemacs-table-test-multiline-cells-keep-content-exactly ()
  (typemacs-table-test--with
      "#table(columns: 2, [¦one\n  two\n\n  three], [right], [last], [end])"
    (let ((before (typemacs-table-test--cells)))
      (typemacs-table-align)
      (should (equal before (typemacs-table-test--cells)))
      (typemacs-table-align)
      (should (equal before (typemacs-table-test--cells))))))

(ert-deftest typemacs-table-test-comments-survive-formatting ()
  (typemacs-table-test--with
      "#table(\n columns: 2, // body comment\n [¦a], [b] // trailing cell comment\n , /* nested /* block */ comment */ [c], [d],\n // final comment\n)"
    (typemacs-table-align)
    (dolist (comment '("// body comment" "// trailing cell comment" "/* nested /* block */ comment */" "// final comment"))
      (should (string-match-p (regexp-quote comment) (buffer-string))))
    (should (= (length (car (typemacs-table-test--cells))) 4))
    (let ((text (buffer-string)))
      (typemacs-table-align)
      (should (equal text (buffer-string))))))

(ert-deftest typemacs-table-test-wrapper-comments-survive-formatting ()
  (typemacs-table-test--with
      "#table(columns: 2, // header comment\n table.header([¦H1], [H2], // header tail\n) /* after header */, [a], [b])"
    (typemacs-table-align)
    (dolist (comment '("// header comment" "// header tail" "/* after header */"))
      (should (string-match-p (regexp-quote comment) (buffer-string))))
    (should (equal (typemacs-table-test--cells) '(("[H1]" "[H2]") ("[a]" "[b]"))))))

(ert-deftest typemacs-table-test-interleaved-options-preserve-row-and-expression-order ()
  (typemacs-table-test--with
      "#table([¦a], columns: 2, [b], table.header([H1], repeat: true, [H2]), [c], inset: 4pt, [d])"
    (typemacs-table-align)
    (should (equal (typemacs-table-test--cells) '(("[a]" "[b]") ("[H1]" "[H2]") ("[c]" "[d]"))))
    (let ((text (buffer-string)))
      (should (string-match-p "\\[a\\],\n  columns: 2,\n  \\[b\\]," text))
      (should (string-match-p "\\[H1\\],\n    repeat: true,\n    \\[H2\\]," text))
      (typemacs-table-align)
      (should (equal text (buffer-string))))))

(ert-deftest typemacs-table-test-tab-skips-leading-comments ()
  (typemacs-table-test--with "#table(columns: 2, [¦a], // next cell\n [b])"
    (typemacs-table-next-field)
    (should (eq (char-after) ?b))))

(ert-deftest typemacs-table-test-column-track-comments-and-spreads ()
  (typemacs-table-test--with "#table(columns: (auto, 1fr, // tracks\n), [¦a], [b])"
    (typemacs-table-insert-column)
    (should (= (typemacs-table--model-columns (typemacs-table--context)) 3))
    (should (string-match-p "// tracks" (buffer-string))))
  (typemacs-table-test--with "#table(columns: (/* computed */ ..tracks), [¦a])"
    (should-error (typemacs-table-align) :type 'user-error)))

(ert-deftest typemacs-table-test-ignore-comments-strings-raw-and-plain-text ()
  (dolist (source '("// #table(columns: 1, [¦fake])\n"
                    "/* #table(columns: 1, [¦fake]) */"
                    "#let x = \"#table(columns: 1, [¦fake])\""
                    "`#table(columns: 1, [¦fake])`"
                    "```typ\n#table(columns: 1, [¦fake])\n```"
                    "Plain table(columns: 1, [¦fake])"))
    (typemacs-table-test--with source
      (should-not (typemacs-table--context t))
      (should-not (eq (key-binding (kbd "TAB")) #'typemacs-table-next-field)))))

(ert-deftest typemacs-table-test-code-expressions-and-markup-quotes ()
  (dolist (source '("#let data = table(columns: 1, [¦a])"
                    "#{ let data = table(columns: 1, [¦a]); data }"
                    "#block[\"Some prose\" #table(columns: 1, [¦a])]"
                    "#let x = 1 // comment\nAn unmatched \"quote\n#table(columns: 1, [¦a])"
                    "#table(columns: 1, [¦a])\n#unfinished("))
    (typemacs-table-test--with source
      (typemacs-table-next-field)
      (should (equal (typemacs-table-test--cells) '(("[a]" "[]")))))))

(ert-deftest typemacs-table-test-nested-tables-edit-the-innermost ()
  (typemacs-table-test--with
      "#table(columns: 1, [outer #table(columns: 2, [¦a], [b])])"
    (typemacs-table-insert-column)
    (should (= (typemacs-table--model-columns (typemacs-table--context)) 3))
    (should (string-prefix-p "#table(columns: 1, [outer #table(" (buffer-string)))
    (should (equal (typemacs-table-test--cells) '(("[]" "[a]" "[b]"))))))

(ert-deftest typemacs-table-test-context-keys-preserve-major-mode-bindings ()
  (typemacs-table-test--with "¦text\n#table(columns: 2, [a], [b])"
    (let ((map (make-sparse-keymap)))
      (dolist (key '("TAB" "<tab>" "<backtab>" "RET" "M-<left>" "C-c C-c"))
        (define-key map (kbd key) #'ignore))
      (use-local-map map)
      (dolist (key '("TAB" "<tab>" "<backtab>" "RET" "M-<left>" "C-c C-c"))
        (should (eq (key-binding (kbd key)) #'ignore)))
      (typemacs-table-test--at "columns")
      (should (eq (key-binding (kbd "TAB")) #'ignore))
      (typemacs-table-test--at "[a]")
      (should (eq (key-binding (kbd "TAB")) #'typemacs-table-next-field))
      (should (eq (key-binding (kbd "RET")) #'typemacs-table-next-row))
      (typemacs-mode -1)
      (should (eq (key-binding (kbd "TAB")) #'ignore)))))

(ert-deftest typemacs-table-test-unsupported-layout-does-not-edit ()
  (dolist (source '("#table(columns: n, [¦a])"
                    "#table(columns: (..tracks), [¦a])"
                    "#table(columns: 0, [¦a])"
                    "#table(columns: 2, ..cells, [¦a])"
                    "#table(columns: 2, table.cell(colspan: 2)[¦a])"
                    "#table(columns: 2, table.hline(), [¦a], [b])"
                    "#table(columns: 2, [¦a]"
                    "#table(columns: 1, columns: 2, [¦a])"))
    (typemacs-table-test--with source
      (let ((before (buffer-string)))
        (should-error (typemacs-table-insert-column) :type 'user-error)
        (should (equal before (buffer-string)))))))

(ert-deftest typemacs-table-test-boundary-errors-do-not-edit ()
  (typemacs-table-test--with "#table(columns: 1, [¦a])"
    (dolist (command '(typemacs-table-delete-column typemacs-table-delete-row
                       typemacs-table-move-row-up typemacs-table-move-row-down
                       typemacs-table-move-column-left typemacs-table-move-column-right))
      (let ((before (buffer-string)))
        (should-error (funcall command) :type 'user-error)
        (should (equal before (buffer-string)))))))

(ert-deftest typemacs-table-test-narrowing-and-cache-invalidation ()
  (typemacs-table-test--with "before\n#table(columns: 2, [¦a], [b])\nafter"
    (should (typemacs-table--context t))
    (save-restriction
      (narrow-to-region (point) (point-max))
      (should-not (typemacs-table--context t)))
    (should (typemacs-table--context t))
    (save-restriction
      (narrow-to-region (line-beginning-position) (line-end-position))
      (typemacs-table-insert-column)
      (should (= (typemacs-table--model-columns (typemacs-table--context)) 3)))
    (should (string-prefix-p "before\n" (buffer-string)))
    (should (string-suffix-p "\nafter" (buffer-string))))
  (typemacs-table-test--with "#table(columns: 1, [¦a])"
    (should (typemacs-table--context t))
    (delete-region (point-min) (+ (point-min) 7))
    (should-not (typemacs-table--context t))))

(ert-deftest typemacs-table-test-narrowing-keeps-surrounding-lexical-context ()
  (dolist (source '("```typ\n#table([¦fake])\n```"
                    "/*\n#table([¦fake])\n*/"
                    "#let x = \"\n#table([¦fake])\n\""))
    (typemacs-table-test--with source
      (narrow-to-region (line-beginning-position) (line-end-position))
      (should-not (typemacs-table--context t)))))

(ert-deftest typemacs-table-test-edit-is-one-undo-step ()
  (typemacs-table-test--with "#table(columns: 2, [¦a], [b], [c], [d])"
    (buffer-enable-undo)
    (let ((before (buffer-string)))
      (undo-boundary)
      (typemacs-table-insert-column)
      (undo-boundary)
      (undo 1)
      (should (equal before (buffer-string))))))

(ert-deftest typemacs-table-test-result-compiles-with-typst ()
  (skip-unless (executable-find "typst"))
  (let* ((directory (make-temp-file "typemacs-table-" t))
         (source (expand-file-name "table.typ" directory))
         (output (expand-file-name "table.pdf" directory)))
    (unwind-protect
        (typemacs-table-test--with
            "#table(columns: (auto, 2fr, // tracks\n), // header\n table.header([H1], [H2]), [¦中文, \"quote\"], inset: 4pt, [two\nlines], [a], [b] // last cell\n , table.footer([F1], [F2]))"
          (dolist (command '(typemacs-table-align typemacs-table-insert-column
                             typemacs-table-move-column-right typemacs-table-delete-column
                             typemacs-table-insert-row typemacs-table-move-row-down
                             typemacs-table-delete-row typemacs-table-next-row))
            (funcall command)
            (write-region (point-min) (point-max) source nil 'silent)
            (with-temp-buffer
              (let ((status (call-process "typst" nil t nil "compile" source output)))
                (ert-info ((format "After %S:\n%s" command (buffer-string)))
                  (should (eq status 0))))))
          (should (file-exists-p output)))
      (delete-directory directory t))))

(provide 'typemacs-table-test)
;;; typemacs-table-test.el ends here
