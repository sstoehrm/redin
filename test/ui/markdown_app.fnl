(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface {:bg [30 33 42] :padding [16 16 16 16]}
   :card    {:bg [40 44 52] :padding [16 16 16 16]}})

(dataflow.init {})

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:markdown {:id :md :aspect :card :width :full}
      "# Title

A paragraph with **bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here
on the next line.

- first item
- second item
- third item"]
    ;; A copyable block — renders a Copy button (verified by lowering unit
    ;; tests; included here so markdown-renders-without-error exercises the
    ;; copyable render path).
    [:markdown {:id :md-copy :aspect :card :width :full :copyable true}
      "# Copyable\n\nThis block has a copy button."]
    ;; Sentinel sibling — guards `/frames` rect alignment for nodes
    ;; placed after a [:markdown] (the wrapper lowers to N flat-array
    ;; entries; the walker must skip past all of them).
    [:text {:id :sentinel :width :full :height 40} "AFTER"]])
