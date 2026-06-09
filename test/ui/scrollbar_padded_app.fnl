;; Fixture for the padded-scrollbar regression: the drawn thumb and the
;; clickable thumb must agree on containers WITH padding. The original
;; bug: render drew the bar inside the content rect (post-padding) while
;; apply_scrollbar hit-tested against the outer node rect, so on a padded
;; container the drawn thumb was not where clicks landed.
;;
;; Same geometry as scrollbar_drag_app.fnl but with 20px padding:
;;   sibling above: y=0..50
;;   list (outer):  y=50..290, 240px tall, padding [20 20 20 20]
;;   list content:  y=70..270 (200px tall), x=20..1260 (1240px wide)
;;   rows:          30 x 30px → total 900, max_scroll = 900-200 = 700
;;   drawn bar:     width 4 at x = 1260-4 = 1256..1260
;;   thumb_h = 200 * (200/900) ≈ 44.4 ; at off=0 thumb y = 70..114

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:sibling {:bg [220 0 0] :padding [0 0 0 0]}
                      :plist   {:bg [40 40 40] :padding [20 20 20 20]}
                      :row     {:bg [70 70 70] :padding [0 0 0 0]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
        (fn []
          [:stack {:viewport [[:top_left 0 0 :full :full]]}
           [:vbox {:width :full :height :full}
            [:vbox {:aspect :sibling :width :full :height 50}]
            [:vbox {:aspect :plist :width :full :height 240
                    :overflow :scroll-y}
             (icollect [i v (ipairs [1 2 3 4 5 6 7 8 9 10
                                     11 12 13 14 15 16 17 18 19 20
                                     21 22 23 24 25 26 27 28 29 30])]
               [:vbox {:aspect :row :width :full :height 30}])]]]))
