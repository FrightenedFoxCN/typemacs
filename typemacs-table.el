;;; typemacs-table.el --- Edit Typst tables like Org tables -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Source-based table editing, independent of the major mode and Tinymist.
;; Only literal, sequential tables are edited: computed column counts,
;; spreads, explicit cell placement/spans, and rules need a layout engine.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct typemacs-table--arg beg end text value key value-end)
(cl-defstruct typemacs-table--section kind cells annotations prefix suffix)
(cl-defstruct typemacs-table--model open end columns widths column-arg entries)

(defvar typemacs-table--calls nil
  "Table calls collected by the current lexical scan.")
(defvar-local typemacs-table--cache nil
  "Accessible buffer bounds, modification tick, and scanned table calls.")

(defun typemacs-table--comment (limit)
  "Skip a comment at point, stopping at LIMIT; return non-nil if found."
  (cond
   ((looking-at "//")
    (goto-char (min limit (line-beginning-position 2))) t)
   ((looking-at "/\\*")
    (forward-char 2)
    (let ((depth 1))
      (while (and (> depth 0) (re-search-forward "/\\*\\|\\*/" limit t))
        (cl-incf depth (if (equal (match-string 0) "/*") 1 -1)))
      (unless (zerop depth) (error "Unclosed Typst comment")))
    t)))

(defun typemacs-table--trivia (limit)
  "Skip whitespace and comments up to LIMIT."
  (skip-chars-forward " \t\r\n" limit)
  (while (and (< (point) limit) (typemacs-table--comment limit))
    (skip-chars-forward " \t\r\n" limit)))

(defun typemacs-table--quoted (limit delimiter)
  "Skip an escaped string or math expression up to LIMIT and DELIMITER."
  (forward-char)
  (let (done)
    (while (and (< (point) limit) (not done))
      (cond
       ((eq (char-after) ?\\) (forward-char (min 2 (- limit (point)))))
       ((eq (char-after) delimiter) (forward-char) (setq done t))
       ;; Dollar signs in math comments and strings do not end math.
       ((and (eq delimiter ?$) (typemacs-table--comment limit)))
       ((and (eq delimiter ?$) (eq (char-after) ?\"))
        (typemacs-table--quoted limit ?\"))
       (t (forward-char))))
    (unless done (error "Unclosed Typst string or math expression"))))

(defun typemacs-table--raw (limit)
  "Skip a Typst raw span or fenced block up to LIMIT."
  (let ((start (point)))
    (skip-chars-forward "`" limit)
    (unless (search-forward (make-string (- (point) start) ?`) limit t)
      (error "Unclosed Typst raw block"))))

(defun typemacs-table--scan (limit mode &optional close inline)
  "Scan Typst to LIMIT in MODE, optionally through matching CLOSE.
Return top-level comma positions in code.  INLINE ends at whitespace;
the value `line' ends at a newline instead.  Collect real table calls in
`typemacs-table--calls', including calls nested inside content blocks."
  (let (commas done previous-token)
    (while (and (< (point) limit) (not done))
      (cond
       ((eq (char-after) close) (forward-char) (setq done t))
       ((and inline
             (memq (char-after) (if (eq inline 'line) '(?\n) '(?\s ?\t ?\r ?\n))))
        (setq done t))
       ((looking-at "//")
        (typemacs-table--comment limit)
        (when inline (setq done t)))
       ((typemacs-table--comment limit))
       ((eq (char-after) ?\\) (forward-char (min 2 (- limit (point)))))
       ((eq (char-after) ?`) (typemacs-table--raw limit))
       ((eq (char-after) ?$) (typemacs-table--quoted limit ?$))
       ((and (eq mode 'code) (eq (char-after) ?\"))
        (typemacs-table--quoted limit ?\"))
       ((eq (char-after) ?\[)
        (forward-char) (typemacs-table--scan limit 'markup ?\]))
       ((and (eq mode 'code) (memq (char-after) '(?\( ?\{)))
        (let ((closing (if (eq (char-after) ?\() ?\) ?\})))
          (forward-char) (typemacs-table--scan limit 'code closing)))
       ((and (eq mode 'markup) (eq (char-after) ?#))
        (forward-char)
        (typemacs-table--scan
         limit 'code nil
         (if (looking-at "\\(?:let\\|set\\|show\\|if\\|else\\|for\\|while\\|context\\|import\\|include\\)\\_>")
             'line t)))
       ((and (eq mode 'code)
             (looking-at "\\_<table[ \t\r\n]*(")
             (not (eq (char-before) ?.)))
        (let ((beg (if (eq (char-before) ?#) (1- (point)) (point)))
              (open (1- (match-end 0))))
          (goto-char (1+ open))
          (let ((separators (typemacs-table--scan limit 'code ?\))))
            (push (list beg open (point) separators (equal previous-token "set"))
                  typemacs-table--calls))
          (setq previous-token nil)))
       ((and (eq mode 'code) (eq (char-after) ?,))
        (push (point) commas) (forward-char))
       ((and (eq mode 'code) (looking-at "[[:alpha:]_][[:alnum:]_-]*"))
        (setq previous-token (match-string-no-properties 0))
        (goto-char (match-end 0)))
       ((or (eq (char-after) ?\])
            (and (eq mode 'code) (memq (char-after) '(?\) ?\}))))
        (if close (error "Unbalanced Typst delimiters") (forward-char)))
       (t (forward-char))))
    (when (and close (not done)) (error "Unclosed Typst table or expression"))
    (nreverse commas)))

(defun typemacs-table--call-at-point ()
  "Return the innermost accessible table call containing point."
  (let ((stamp (list (point-min) (point-max) (buffer-chars-modified-tick))))
    (unless (equal stamp (car typemacs-table--cache))
      (let (typemacs-table--calls)
        (save-excursion
          (save-restriction
            ;; Read the surrounding lexical context even when narrowed into a
            ;; string, raw block, or comment.  Only fully accessible calls edit.
            (widen)
            (goto-char (point-min))
            ;; An unfinished expression should not hide earlier complete tables.
            (condition-case nil
                (typemacs-table--scan (point-max) 'markup)
              (error nil))))
        (setq typemacs-table--cache (cons stamp typemacs-table--calls))))
    (let (found)
      (dolist (call (cdr typemacs-table--cache))
        (when (and (not (nth 4 call))
                   (<= (point-min) (car call) (point))
                   (< (point) (nth 2 call)) (<= (nth 2 call) (point-max))
                   (or (not found) (> (cadr call) (cadr found))))
          (setq found call)))
      found)))

(defun typemacs-table--arguments (open end &optional separators)
  "Read argument spans between OPEN and END, using SEPARATORS if supplied.
Keep comments with their argument; a final comment-only span has no value."
  (save-excursion
    (unless separators
      (goto-char (1+ open))
      (let (typemacs-table--calls)
        (setq separators (typemacs-table--scan end 'code ?\)))))
    (let ((beg (1+ open)) args)
      (dolist (boundary (append separators (list (1- end))))
        (goto-char beg)
        (skip-chars-forward " \t\r\n" boundary)
        (let ((start (point)))
          (goto-char boundary)
          (skip-chars-backward " \t\r\n" start)
          (when (< start (point))
            (let* ((finish (point))
                   (text (buffer-substring-no-properties start finish))
                   (newline (string-match-p "\n" (buffer-substring-no-properties
                                                    finish boundary))))
              ;; Retain a newline before the comma after a line comment.
              (when (and newline (string-match-p "//[^\n]*\\'" text))
                (setq text (concat text "\n")))
              (goto-char start)
              (typemacs-table--trivia finish)
              (let ((value (when (< (point) finish) (point))) key)
                (when (and value (looking-at "\\([[:alpha:]_][[:alnum:]_-]*\\)[ \t\r\n]*:"))
                  (setq key (match-string-no-properties 1))
                  (goto-char (match-end 0))
                  (typemacs-table--trivia finish)
                  (setq value (point)))
                (push (make-typemacs-table--arg
                       :beg start :end finish :text text :value value :key key)
                      args)))))
        (setq beg (1+ boundary)))
      (nreverse args))))

(defun typemacs-table--columns (arg)
  "Read a literal column count or track tuple from ARG.
Return (COUNT . TRACKS), recording the value's source end in ARG."
  (save-excursion
    (goto-char (typemacs-table--arg-value arg))
    (let ((limit (typemacs-table--arg-end arg)) count widths)
      (cond
       ((looking-at "[0-9]+")
        (setq count (string-to-number (match-string 0)))
        (goto-char (match-end 0)))
       ((eq (char-after) ?\()
        (let ((open (point)) separators (typemacs-table--calls nil))
          (forward-char)
          (setq separators (typemacs-table--scan limit 'code ?\)))
          (setq widths (typemacs-table--arguments open (point) separators))
          (when (and (cdr widths) (not (typemacs-table--arg-value (car (last widths)))))
            (let ((tail (typemacs-table--arg-text (car (last widths)))))
              (setq widths (butlast widths))
              (setf (typemacs-table--arg-text (car (last widths)))
                    (concat (typemacs-table--arg-text (car (last widths))) "\n" tail "\n"))))
          (setq count (length widths))
          (when (cl-some (lambda (track)
                           (or (not (typemacs-table--arg-value track))
                               (typemacs-table--arg-key track)
                               (save-excursion
                                 (goto-char (typemacs-table--arg-value track))
                                 (looking-at "\\.\\."))))
                         widths)
            (user-error "Computed column tracks cannot be edited"))
          (setq widths (mapcar #'typemacs-table--arg-text widths))))
       (t (user-error "Table columns must be a positive integer or literal track tuple")))
      (setf (typemacs-table--arg-value-end arg) (point))
      (typemacs-table--trivia limit)
      (unless (and (= (point) limit) (> count 0))
        (user-error "Table columns must be a positive integer or literal track tuple"))
      (cons count widths))))

(defun typemacs-table--check-cell (arg)
  "Reject ARG when its layout cannot be inferred from sequential cells."
  (save-excursion
    (goto-char (typemacs-table--arg-value arg))
    (when (looking-at "\\.\\.\\|table\\.\\(?:cell\\|hline\\|vline\\|header\\|footer\\)\\_>")
      (user-error "Spreads, table.cell, and table rules need manual layout editing"))))

(defun typemacs-table--parse (call)
  "Build an editable table model from CALL, or explain unsupported syntax."
  (let* ((open (nth 1 call)) (end (nth 2 call))
         (args (typemacs-table--arguments open end (nth 3 call)))
         (column-args (cl-remove-if-not
                       (lambda (arg) (equal (typemacs-table--arg-key arg) "columns")) args))
         (column-arg (car column-args))
         (columns (if column-arg (typemacs-table--columns column-arg) '(1)))
         entries body)
    (when (cdr column-args) (user-error "Duplicate columns arguments"))
    (unless column-arg
      (save-restriction
        (widen)
        (when (cl-some
               (lambda (setting)
                 (and (nth 4 setting) (< (cadr setting) open)
                      (cl-some (lambda (arg) (equal (typemacs-table--arg-key arg) "columns"))
                               (typemacs-table--arguments (nth 1 setting) (nth 2 setting) (nth 3 setting)))))
               (cdr typemacs-table--cache))
          (user-error "Specify columns explicitly when using set table column defaults"))))
    (dolist (arg args)
      (cond
       ((or (typemacs-table--arg-key arg) (not (typemacs-table--arg-value arg)))
        (if body
            (push (cons (length (typemacs-table--section-cells body)) arg)
                  (typemacs-table--section-annotations body))
          (push arg entries)))
       ((save-excursion
          (goto-char (typemacs-table--arg-value arg))
          (looking-at "table\\.\\(header\\|footer\\)[ \t\r\n]*("))
        (save-excursion
          (goto-char (typemacs-table--arg-value arg))
          (looking-at "table\\.\\(header\\|footer\\)[ \t\r\n]*(")
          (let* ((kind (intern (match-string-no-properties 1)))
                 (group-open (1- (match-end 0)))
                 (typemacs-table--calls nil)
                 separators group-args cells annotations group-end)
            (goto-char (1+ group-open))
            (setq separators (typemacs-table--scan (typemacs-table--arg-end arg) 'code ?\))
                  group-end (point)
                  group-args (typemacs-table--arguments group-open (point) separators))
            (typemacs-table--trivia (typemacs-table--arg-end arg))
            (unless (= (point) (typemacs-table--arg-end arg))
              (user-error "Unsupported table header/footer expression"))
            (dolist (child group-args)
              (if (or (typemacs-table--arg-key child)
                      (not (typemacs-table--arg-value child)))
                  (push (cons (length cells) child) annotations)
                (typemacs-table--check-cell child)
                (push child cells)))
            (push (make-typemacs-table--section
                   :kind kind :cells (nreverse cells) :annotations (nreverse annotations)
                   :prefix (substring (typemacs-table--arg-text arg) 0
                                      (- (typemacs-table--arg-value arg) (typemacs-table--arg-beg arg)))
                   :suffix (substring (typemacs-table--arg-text arg)
                                      (- group-end (typemacs-table--arg-beg arg)))) entries)))
        (setq body nil))
       (t
        (typemacs-table--check-cell arg)
        (unless body
          (setq body (make-typemacs-table--section :kind 'body))
          (push body entries))
        (push arg (typemacs-table--section-cells body)))))
    (setq entries (nreverse entries))
    (dolist (entry entries)
      (when (and (typemacs-table--section-p entry)
                 (eq (typemacs-table--section-kind entry) 'body))
        (setf (typemacs-table--section-cells entry)
              (nreverse (typemacs-table--section-cells entry))
              (typemacs-table--section-annotations entry)
              (nreverse (typemacs-table--section-annotations entry)))))
    (make-typemacs-table--model :open open :end end :columns (car columns)
                               :widths (cdr columns) :column-arg column-arg
                               :entries entries)))

(defun typemacs-table--context (&optional noerror)
  "Return the table model at point, or nil when NOERROR is non-nil."
  (condition-case err
      (let ((call (typemacs-table--call-at-point)))
        (unless call (user-error "Point is not in a complete Typst table"))
        (typemacs-table--parse call))
    (error (unless noerror (user-error "%s" (error-message-string err))))))

(defun typemacs-table--sections (model)
  "Return MODEL's editable cell sections in source order."
  (cl-remove-if-not #'typemacs-table--section-p (typemacs-table--model-entries model)))

(defun typemacs-table--location (model)
  "Return (SECTION INDEX OFFSET) for the cell at point in MODEL."
  (cl-loop for section in (typemacs-table--sections model)
           thereis
           (cl-loop for cell in (typemacs-table--section-cells section)
                    for index from 0
                    for beg = (typemacs-table--arg-value cell)
                    for end = (typemacs-table--arg-end cell)
                    when (and beg (<= beg (point)) (<= (point) (1+ end)))
                    return (list section index
                                 (min (- (point) (typemacs-table--arg-beg cell))
                                      (- end (typemacs-table--arg-beg cell)))))))

(defun typemacs-table--current-cell (model)
  "Return MODEL's cell location, requiring point to be in a cell."
  (or (typemacs-table--location model) (user-error "Place point in a table cell")))

(defun typemacs-table--empty-cell ()
  "Create an empty content cell."
  (make-typemacs-table--arg :text "[]"))

(defun typemacs-table--pad (model)
  "Make each section in MODEL rectangular with explicit empty cells."
  (dolist (section (typemacs-table--sections model))
    (let* ((cells (typemacs-table--section-cells section))
           (missing (mod (- (length cells)) (typemacs-table--model-columns model))))
      (setf (typemacs-table--section-cells section)
            (append cells (cl-loop repeat missing collect (typemacs-table--empty-cell)))))))

(defun typemacs-table--write (model &optional focus)
  "Align MODEL in the buffer, restoring FOCUS as (SECTION INDEX OFFSET).
An absent offset puts point inside an empty/content cell.  Rewrite as a
single undoable change and leave an already aligned buffer unmodified."
  (typemacs-table--pad model)
  (let* ((columns (typemacs-table--model-columns model))
         (widths (make-vector columns 0))
         (indent (save-excursion
                   (goto-char (typemacs-table--model-open model))
                   (current-indentation)))
         (origin (1+ (typemacs-table--model-open model)))
         (end (1- (typemacs-table--model-end model)))
         (old-point (point)) (text "\n") destination)
    (dolist (section (typemacs-table--sections model))
      (cl-loop for cell in (typemacs-table--section-cells section)
               for index from 0 for value = (typemacs-table--arg-text cell)
               unless (string-match-p "\n" value)
               do (aset widths (mod index columns)
                        (max (aref widths (mod index columns)) (string-width value)))))
    (cl-labels
        ((emit (value) (setq text (concat text value)))
         (argument (arg spaces)
           (emit (make-string spaces ?\s))
           (emit (typemacs-table--arg-text arg))
           (emit (if (typemacs-table--arg-value arg) ",\n" "\n")))
         (section (group spaces)
           (let ((cells (typemacs-table--section-cells group))
                 (annotations (typemacs-table--section-annotations group)) (index 0))
             (while cells
               (let* ((row (cl-subseq cells 0 columns))
                      (multiline
                       (or (cl-some (lambda (cell)
                                      (string-match-p "\n" (typemacs-table--arg-text cell))) row)
                           (cl-some (lambda (annotation) (< index (car annotation) (+ index columns)))
                                    annotations))))
                 (while (and annotations (<= (caar annotations) index))
                   (argument (cdar annotations) spaces)
                   (setq annotations (cdr annotations)))
                 (emit (make-string spaces ?\s))
                 (cl-loop for cell in row for column from 0
                          for value = (typemacs-table--arg-text cell)
                          do
                          (when (and (> column 0) multiline)
                            (while (and annotations (<= (caar annotations) index))
                              (argument (cdar annotations) spaces)
                              (setq annotations (cdr annotations)))
                            (emit (make-string spaces ?\s)))
                          (when (and focus (eq group (car focus)) (= index (cadr focus)))
                            (setq destination
                                  (+ origin (length text)
                                     (min (or (nth 2 focus)
                                              (let ((start (if (typemacs-table--arg-beg cell)
                                                               (- (typemacs-table--arg-value cell)
                                                                  (typemacs-table--arg-beg cell))
                                                             0)))
                                                (+ start (if (eq (aref value start) ?\[) 1 0))))
                                          (length value)))))
                          (emit value)
                          (emit ",")
                          (cl-incf index)
                          (unless (= column (1- columns))
                            (emit (if multiline
                                      "\n"
                                    (make-string (+ 2 (- (aref widths column) (string-width value))) ?\s)))))
                 (emit "\n")
                 (setq cells (nthcdr columns cells))))
             (dolist (annotation annotations) (argument (cdr annotation) spaces)))))
      (dolist (entry (typemacs-table--model-entries model))
        (if (typemacs-table--arg-p entry)
            (argument entry (+ indent 2))
          (if (eq (typemacs-table--section-kind entry) 'body)
              (section entry (+ indent 2))
            (emit (format "%s%stable.%s(\n" (make-string (+ indent 2) ?\s)
                          (typemacs-table--section-prefix entry)
                          (typemacs-table--section-kind entry)))
            (section entry (+ indent 4))
            (emit (concat (make-string (+ indent 2) ?\s) ")"
                          (typemacs-table--section-suffix entry) ",\n")))))
      (emit (make-string indent ?\s)))
    (unless (equal text (buffer-substring-no-properties origin end))
      (atomic-change-group
        (goto-char origin)
        (delete-region origin end)
        (insert text)))
    (goto-char (or destination (min (+ origin (length text)) old-point))))
  model)

;;;###autoload
(defun typemacs-table-align ()
  "Align the literal Typst table at point, preserving cell contents."
  (interactive)
  (let ((model (typemacs-table--context)))
    (typemacs-table--write model (typemacs-table--location model))))

(defun typemacs-table--navigate (direction &optional row)
  "Move DIRECTION cells, or rows when ROW is non-nil, aligning first."
  (let* ((model (typemacs-table--context))
         (location (typemacs-table--current-cell model))
         (sections (typemacs-table--sections model))
         (section (car location))
         (columns (typemacs-table--model-columns model))
         (index (+ (cadr location) (* direction (if row columns 1)))))
    (typemacs-table--pad model)
    (cond
     ((< index 0)
      (if-let* ((previous (cadr (memq section (reverse sections)))))
          (setq section previous index (1- (length (typemacs-table--section-cells previous))))
        (setq index 0)))
     ((>= index (length (typemacs-table--section-cells section)))
      (if-let* ((next (cadr (memq section sections))))
          (setq section next index (if row (mod index columns) 0))
        (setf (typemacs-table--section-cells section)
              (append (typemacs-table--section-cells section)
                      (cl-loop repeat columns collect (typemacs-table--empty-cell)))))))
    (typemacs-table--write model (list section index))))

;;;###autoload
(defun typemacs-table-next-field ()
  "Align and move to the next cell, appending a row at the end."
  (interactive)
  (typemacs-table--navigate 1))

;;;###autoload
(defun typemacs-table-previous-field ()
  "Align and move to the previous cell."
  (interactive)
  (typemacs-table--navigate -1))

;;;###autoload
(defun typemacs-table-next-row ()
  "Align and move down in the same column, appending a row if necessary."
  (interactive)
  (typemacs-table--navigate 1 t))

(defun typemacs-table--edit-row (action &optional direction)
  "Apply row ACTION, using DIRECTION for a move."
  (let* ((model (typemacs-table--context))
         (location (typemacs-table--current-cell model))
         (section (car location))
         (columns (typemacs-table--model-columns model))
         (row (/ (cadr location) columns))
         (column (mod (cadr location) columns)))
    (typemacs-table--pad model)
    (let* ((cells (typemacs-table--section-cells section))
           (rows (cl-loop for index from 0 below (length cells) by columns
                          collect (cl-subseq cells index (+ index columns)))))
      (pcase action
        ('insert
         (setq rows (append (cl-subseq rows 0 row)
                            (list (cl-loop repeat columns collect (typemacs-table--empty-cell)))
                            (nthcdr row rows))))
        ('delete
         (when (= (length rows) 1) (user-error "Cannot delete the last row of a table section"))
         (setq rows (append (cl-subseq rows 0 row) (nthcdr (1+ row) rows))
               row (min row (1- (length rows)))))
        ('move
         (let ((target (+ row direction)))
           (unless (< -1 target (length rows)) (user-error "Already at the edge of this table section"))
           (cl-rotatef (nth row rows) (nth target rows))
           (setq row target))))
      (setf (typemacs-table--section-cells section) (apply #'append rows)))
    (typemacs-table--write model (list section (+ (* row columns) column)))))

(defun typemacs-table--set-columns (model count widths)
  "Set MODEL's column COUNT and optional track WIDTHS, preserving options."
  (let* ((arg (typemacs-table--model-column-arg model))
         (value (if widths (concat "(" (string-join widths ", ") ",)")
                  (number-to-string count))))
    (if arg
        (let ((text (typemacs-table--arg-text arg))
              (beg (- (typemacs-table--arg-value arg) (typemacs-table--arg-beg arg)))
              (end (- (typemacs-table--arg-value-end arg) (typemacs-table--arg-beg arg))))
          (setf (typemacs-table--arg-text arg)
                (concat (substring text 0 beg) value (substring text end))))
      (setq arg (make-typemacs-table--arg :text (concat "columns: " value) :value t :key "columns"))
      (push arg (typemacs-table--model-entries model)))
    (setf (typemacs-table--model-columns model) count
          (typemacs-table--model-widths model) widths)))

(defun typemacs-table--edit-column (action &optional direction)
  "Apply column ACTION across all sections, using DIRECTION for a move."
  (let* ((model (typemacs-table--context))
         (location (typemacs-table--current-cell model))
         (columns (typemacs-table--model-columns model))
         (column (mod (cadr location) columns))
         (row (/ (cadr location) columns))
         (target (+ column (or direction 0)))
         (widths (copy-sequence (typemacs-table--model-widths model))))
    (when (and (eq action 'delete) (= columns 1)) (user-error "Cannot delete the last table column"))
    (when (and (eq action 'move) (not (< -1 target columns)))
      (user-error "Already at the edge of the table"))
    (typemacs-table--pad model)
    (cl-labels
        ((edit (items new)
           (pcase action
             ('insert (append (cl-subseq items 0 column) (list new) (nthcdr column items)))
             ('delete (append (cl-subseq items 0 column) (nthcdr (1+ column) items)))
             ('move (cl-rotatef (nth column items) (nth target items)) items))))
      (dolist (section (typemacs-table--sections model))
        (let ((cells (typemacs-table--section-cells section)))
          (setf (typemacs-table--section-cells section)
                (cl-loop for index from 0 below (length cells) by columns
                         append (edit (cl-subseq cells index (+ index columns))
                                      (typemacs-table--empty-cell))))))
      (when widths (setq widths (edit widths "auto"))))
    (setq columns (+ columns (pcase action ('insert 1) ('delete -1) (_ 0)))
          column (if (eq action 'move) target (min column (1- columns))))
    (typemacs-table--set-columns model columns widths)
    (typemacs-table--write model (list (car location) (+ (* row columns) column)))))

;;;###autoload
(defun typemacs-table-insert-row ()
  "Insert an empty row before the current row."
  (interactive) (typemacs-table--edit-row 'insert))

;;;###autoload
(defun typemacs-table-delete-row ()
  "Delete the current row, retaining at least one row per section."
  (interactive) (typemacs-table--edit-row 'delete))

;;;###autoload
(defun typemacs-table-move-row-up ()
  "Move the current row up within its body, header, or footer."
  (interactive) (typemacs-table--edit-row 'move -1))

;;;###autoload
(defun typemacs-table-move-row-down ()
  "Move the current row down within its body, header, or footer."
  (interactive) (typemacs-table--edit-row 'move 1))

;;;###autoload
(defun typemacs-table-insert-column ()
  "Insert an empty column before the current column, adding an auto track."
  (interactive) (typemacs-table--edit-column 'insert))

;;;###autoload
(defun typemacs-table-delete-column ()
  "Delete the current column from every section and its column track."
  (interactive) (typemacs-table--edit-column 'delete))

;;;###autoload
(defun typemacs-table-move-column-left ()
  "Move the current column and its track left in every table section."
  (interactive) (typemacs-table--edit-column 'move -1))

;;;###autoload
(defun typemacs-table-move-column-right ()
  "Move the current column and its track right in every table section."
  (interactive) (typemacs-table--edit-column 'move 1))

;;;###autoload
(defun typemacs-table-insert (columns rows)
  "Insert a new Typst table with COLUMNS columns and ROWS body rows."
  (interactive (list (read-number "Columns: " 2) (read-number "Rows: " 2)))
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (user-error "Rows and columns must be positive integers"))
  (atomic-change-group
    (unless (bolp) (insert "\n"))
    (let ((beg (point)))
      (insert (format "#table(columns: %d, %s)" columns
                      (mapconcat (lambda (_) "[]") (number-sequence 1 (* columns rows)) ", ")))
      (goto-char (+ beg 7))
      (let* ((model (typemacs-table--context))
             (section (car (typemacs-table--sections model))))
        (typemacs-table--write model (list section 0))))))

(defun typemacs-table--key-filter (command)
  "Enable table COMMAND only in an editable table cell."
  (let ((model (typemacs-table--context t)))
    (when (and model (typemacs-table--location model)) command)))

(defun typemacs-table-bind-keys (map)
  "Add context-sensitive Org-style table keys to MAP."
  (dolist (binding '(("TAB" . typemacs-table-next-field)
                     ("<tab>" . typemacs-table-next-field)
                     ("<backtab>" . typemacs-table-previous-field)
                     ("S-TAB" . typemacs-table-previous-field)
                     ("RET" . typemacs-table-next-row)
                     ("<return>" . typemacs-table-next-row)
                     ("C-c C-c" . typemacs-table-align)
                     ("M-<up>" . typemacs-table-move-row-up)
                     ("M-<down>" . typemacs-table-move-row-down)
                     ("M-<left>" . typemacs-table-move-column-left)
                     ("M-<right>" . typemacs-table-move-column-right)
                     ("M-S-<up>" . typemacs-table-delete-row)
                     ("M-S-<down>" . typemacs-table-insert-row)
                     ("M-S-<left>" . typemacs-table-delete-column)
                     ("M-S-<right>" . typemacs-table-insert-column)))
    (define-key map (kbd (car binding))
                `(menu-item "" ,(cdr binding) :filter typemacs-table--key-filter)))
  (define-key map (kbd "C-c |") #'typemacs-table-insert)
  (define-key map (kbd "C-c C-t t") #'typemacs-table-insert)
  (define-key map (kbd "C-c C-t a") #'typemacs-table-align))

(provide 'typemacs-table)
;;; typemacs-table.el ends here
