;; test/ui/canvas_app.fnl
;; Minimal app exercising the Fennel canvas drawing API.

(local canvas (require :canvas))
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(dataflow.init {:click-count 0})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :canvas-click
  (fn [db event]
    (update db :click-count (fn [n] (+ (or n 0) 1)))))

(reg-sub :sub/click-count
  (fn [db] (or (get db :click-count) 0)))

(canvas.register :test-canvas
  (fn [ctx]
    ;; Background
    (ctx.rect 0 0 ctx.width ctx.height {:fill [240 240 245]})
    ;; A red rectangle
    (ctx.rect 20 20 100 60 {:fill [220 50 50]})
    ;; A blue circle
    (ctx.circle 200 80 30 {:fill [50 80 220]})
    ;; A green line
    (ctx.line 10 150 290 150 {:stroke [50 180 50] :width 2})
    ;; Text showing click count from app-db
    (let [count (subscribe :sub/click-count)]
      (ctx.text 20 170 (.. "Clicks: " (tostring count)) {:size 18 :color [0 0 0]}))))

(global main_view
  (fn []
    [:vbox {:width :full :height :full}
      [:text {:id :title} "Canvas Test"]
      [:canvas {:provider :test-canvas :width 300 :height 200}]]))
