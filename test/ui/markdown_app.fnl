(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface {:bg [30 33 42] :padding [16 16 16 16]}
   :body    {:font-size 24 :color [240 240 240] :line-height 1.5
             :bold   {:color [255 255 255]}
             :italic {:color [180 180 220]}
             :code   {:bg [40 40 50] :color [220 220 220]}}
   :h1      {:font-size 40 :weight 1 :color [255 255 255]}
   :h2      {:font-size 32 :weight 1 :color [240 240 240]}})

(dataflow.init {})

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text {:id :md :markdown true :aspect :body}
           "**Bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here
on the next line."]
    [:text {:id :md-extended :markdown true :aspect :body}
           "# Heading 1

## Heading 2

Plain paragraph with **bold _and italic_** plus `code`."]])
