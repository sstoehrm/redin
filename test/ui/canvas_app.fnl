;; test/ui/canvas_app.fnl
;; Minimal app exercising the Fennel canvas drawing API.

(local canvas (require :canvas))
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(dataflow.init {:click-count 0 :bad-args false})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :canvas-click
  (fn [db event]
    (update db :click-count (fn [n] (+ (or n 0) 1)))))

;; Review C2: flip the provider into emitting malformed draw commands.
(reg-handler :canvas/bad-args
  (fn [db event]
    (assoc db :bad-args true)))

(reg-sub :sub/click-count
  (fn [db] (or (get db :click-count) 0)))

(reg-sub :sub/bad-args
  (fn [db] (get db :bad-args)))

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
      (ctx.text 20 170 (.. "Clicks: " (tostring count)) {:size 18 :color [0 0 0]}))
    ;; Malformed commands (review C2). The command executor runs outside
    ;; the provider's pcall, so each of these used to abort the process
    ;; (number opts -> LuaJIT PANIC; flat polygon list -> SIGSEGV). They
    ;; must be skipped / treated as {} opts while valid commands draw.
    (when (subscribe :sub/bad-args)
      (ctx.rect 0 0 10 10 5)
      (ctx.circle 50 50 10 "red")
      (ctx.ellipse 50 50 10 5 true)
      (ctx.line 0 0 10 10 7)
      (ctx.text 5 5 "x" 12)
      (ctx.polygon [0 0 10 0 5 10])
      (ctx.polygon [[0 0] :nope [5 10]] {:fill [0 0 0]})
      (ctx.polygon [[0 0] [10 0] [5 10]] 3)
      (ctx.pixels 0 0 1 1 (string.char 255 255 255 255) 9)
      ;; A valid magenta marker drawn after the bad ones.
      (ctx.rect 240 10 40 30 {:fill [200 0 200]}))))

(global main_view
  (fn []
    [:vbox {:width :full :height :full}
      [:text {:id :title} "Canvas Test"]
      [:canvas {:id :test-canvas :provider :test-canvas :width 300 :height 200}]]))
