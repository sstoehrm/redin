;; Regression fixture for #142: scroll-y clipping must hold when a
;; scrollable container has a canvas (or input, or multi-line text)
;; descendant. Each of those calls Begin/End scissor for its own clip,
;; and without a scissor stack, EndScissor inside the descendant tears
;; down the outer container's scissor — letting subsequent rows render
;; over siblings positioned above the list.
;;
;; Layout:
;;   [0..50, sibling]      solid RED background
;;   [50..*, scroll-y vbox] rows of 30px each, each row a green canvas
;;
;; After one scroll tick (SCROLL_SPEED=30 → 30px), the first row's
;; logical y becomes 20 — straddling the boundary. With the bug, the
;; row's green canvas pixels render at y=20..49, covering the sibling.
;; With the fix, scissor clips to y >= 50 and the red sibling stays
;; visible.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(local canvas (require :canvas))

(canvas.register :green-row
                 (fn [ctx]
                   (ctx.rect 0 0 ctx.width ctx.height {:fill [0 200 0]})))

(theme-mod.set-theme {:sibling {:bg [220 0 0] :padding [0 0 0 0]}
                      :list    {:bg [40 40 40] :padding [0 0 0 0]}
                      :row     {:padding [0 0 0 0]}})

(dataflow.init {})

(global main_view
        (fn []
          [:stack {:viewport [[:top_left 0 0 :full :full]]}
           [:vbox {:width :full :height :full}
            ;; Sibling above the list — solid red.
            [:vbox {:aspect :sibling :width :full :height 50}]
            ;; Scrollable list with a tight 100px viewport but enough
            ;; rows (each 30px) to force overflow. Each row contains a
            ;; canvas: without a scissor stack, each row's canvas
            ;; end-scissor wipes the list's own scissor, so a row
            ;; scrolled above the list renders over the red sibling.
            [:vbox {:aspect :list :width :full :height 100
                    :overflow :scroll-y}
             (icollect [i v (ipairs [1 2 3 4 5 6 7 8 9 10
                                     11 12 13 14 15 16 17 18 19 20
                                     21 22 23 24])]
               [:vbox {:aspect :row :width :full :height 30}
                [:canvas {:provider :green-row :width :full :height 30}]])]]]))
