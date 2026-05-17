;; Fixture for #143 — draggable scrollbar tests.
;; A 200px-tall scroll-y vbox at known coordinates with 30 rows of
;; 30px each (total content 900px → 700px scrollable). Geometry is
;; pinned so the test can compute thumb position and drag deltas
;; analytically.
;;
;; Layout:
;;   sibling above: y=0..50, red (smoke check that clipping holds)
;;   list:          y=50..250, scroll-y, 200px tall, content 900px
;;   thumb:         visible width 4px at x=1276 (window 1280 - 4)
;;     thumb_h = 200 * (200 / 900) ≈ 44px
;;     gutter is y=50..250 (200px tall)
;;     max_thumb_y = 250 - 44 = 206
;;     each scroll-tick = 30 / (900-200) ≈ 4.3% of gutter

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:sibling {:bg [220 0 0] :padding [0 0 0 0]}
                      :list    {:bg [40 40 40] :padding [0 0 0 0]}
                      :row     {:bg [70 70 70] :padding [0 0 0 0]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
        (fn []
          [:stack {:viewport [[:top_left 0 0 :full :full]]}
           [:vbox {:width :full :height :full}
            [:vbox {:aspect :sibling :width :full :height 50}]
            [:vbox {:aspect :list :width :full :height 200
                    :overflow :scroll-y}
             (icollect [i v (ipairs [1 2 3 4 5 6 7 8 9 10
                                     11 12 13 14 15 16 17 18 19 20
                                     21 22 23 24 25 26 27 28 29 30])]
               [:vbox {:aspect :row :width :full :height 30}])]]]))
