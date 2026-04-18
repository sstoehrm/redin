;; Test app for theme `:line-height`.
;;
;; Two text blocks share the same font, font-size, width, and content but
;; differ in `:line-height`. The tight block (ratio 1.0) should render
;; shorter than the loose block (ratio 2.2). We pin explicit heights so the
;; element rects are stable, but line-height still drives intrinsic height
;; (see :grow-tight / :grow-loose, which omit :height).
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(local wrap-text
  "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")

(theme-mod.set-theme
  {:surface      {:bg [20 20 28] :padding [16 16 16 16]}
   :body         {:font-size 16 :color [236 239 244]}
   :tight        {:font-size 16 :color [236 239 244] :line-height 1.0}
   :loose        {:font-size 16 :color [236 239 244] :line-height 2.2}
   :default-lh   {:font-size 16 :color [236 239 244]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {:aspect :surface}
     ;; Fixed-size cells: line-height influences spacing inside a fixed rect.
     [:text {:id :fixed-tight :aspect :tight :width 180 :height 160} wrap-text]
     [:text {:id :fixed-loose :aspect :loose :width 180 :height 160} wrap-text]
     ;; Intrinsic-height cells: line-height influences the measured height.
     [:text {:id :grow-tight :aspect :tight :width 180} wrap-text]
     [:text {:id :grow-loose :aspect :loose :width 180} wrap-text]
     [:text {:id :grow-default :aspect :default-lh :width 180} wrap-text]]))
