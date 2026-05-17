;; Canvas-and-button fixture for the override-input press regression.
;;
;; Tests that pressing a button via /input/mouse/down + /input/mouse/up
;; fires the click handler even when the app contains a canvas. Without
;; the fix, push_canvas_input_state's eager poll of is_mouse_button_pressed
;; consumes the override's one-shot pending_press flag before
;; apply_listeners can see the MouseEvent — so the click silently drops.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(local canvas (require :canvas))

(canvas.register :backdrop
                 (fn [ctx]
                   (ctx.rect 0 0 ctx.width ctx.height {:fill [20 20 20]})))

(theme-mod.set-theme {:bg  {:bg [0 0 0]}
                      :btn {:bg [80 80 80] :color [255 255 255]
                            :radius 0 :padding [0 0 0 0]}})

(dataflow.init {:clicks 0})

;; Expose state to the dev server so /state and /state/clicks work.
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :test/click
             (fn [db _]
               (update db :clicks #(+ $ 1))))

(reg-sub :clicks (fn [db] (get db :clicks 0)))

(global main_view
        (fn []
          [:stack {:viewport [[:top_left 0 0 :full :full]
                              [:top_left 0 0 :full :full]]}
           ;; Background canvas — the bug trigger. Any canvas (including
           ;; :animate decorations on the button) would do. Stacked
           ;; behind the button via two full-window viewport entries.
           [:canvas {:provider :backdrop :width :full :height :full}]
           [:vbox {:aspect :bg :width :full :height :full :layout :center}
            [:button {:aspect :btn :width 100 :height 40
                      :click [:test/click]}
             ""]]]))
