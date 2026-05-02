(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface {:bg [30 33 42] :padding [16 16 16 16]}
   :body    {:font-size 24 :color [240 240 240] :line-height 1.5}})

(dataflow.init {})

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text {:id :md :markdown true :aspect :body}
           "**Bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here
on the next line."]])
