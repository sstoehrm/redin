;; Test app for theme `:shadow`.
;;
;; Two themed boxes sit on a solid background: one with a shadow, one
;; without. The shadowed box's footprint should leak outside its bounds
;; into otherwise-background pixels.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface     {:bg [255 255 255] :padding [40 40 40 40]}
   :plain-card  {:bg [60 130 220] :padding [24 24 24 24] :radius 8}
   :shadow-card {:bg [60 130 220] :padding [24 24 24 24] :radius 8
                 :shadow [6 8 12 [0 0 0 200]]}
   :shadow-btn  {:bg [230 90 90] :color [255 255 255] :radius 6
                 :padding [10 18 10 18]
                 :shadow [3 3 6 [0 0 0 180]]}
   :label       {:font-size 16 :color [240 240 240]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

;; `:layout :top_center` makes the outer vbox honor child :width on the
;; cross axis — otherwise children stretch to fill horizontally and we
;; can't sample a pixel next to their trailing edge.
(global main_view
  (fn []
    [:vbox {:aspect :surface :layout :top_center}
     [:vbox {:id :plain-box :aspect :plain-card :width 180 :height 100}
      [:text {:id :plain-label :aspect :label} "no shadow"]]
     [:vbox {:id :shadow-box :aspect :shadow-card :width 180 :height 100}
      [:text {:id :shadow-label :aspect :label} "with shadow"]]
     [:button {:id :shadow-btn :aspect :shadow-btn
               :width 160 :height 40 :click [:event/noop]}
      "shadowed button"]]))
