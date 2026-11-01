#set page(paper: "a5", margin: 18mm)
#set text(size: 11pt)

= Typemacs

Edit this document in Emacs and run `M-x typemacs-start`.
Changes appear in the preview before you save the buffer.

== Equations

$ integral_0^1 x^2 dif x = 1/3 $

== Editable table

Place the cursor in a cell. Use Tab to advance, Return for the next row,
and Alt + arrow keys to move rows or columns.

#table(
  columns: (auto, 1fr),
  table.header(
    [Name],   [Value],
  ),
  [Alpha],  [10],
  [Beta],   [20],
)

#include "chapters/intro.typ"
