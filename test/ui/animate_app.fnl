;; test/ui/animate_app.fnl
;; Fixture for the :animate attribute. A button hosts a canvas provider
;; that increments :tick-count every time it's drawn. Production code
;; reads /state/tick-count to verify frame-rate dispatch, and POSTs
;; /click at the host's center to verify click-through.

(local canvas (require :canvas))
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:button {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16 8 16]}})

(dataflow.init {:tick-count 0 :host-clicks 0})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :ev/host-click
  (fn [db event] (update db :host-clicks #(+ (or $1 0) 1))))

(reg-handler :ev/tick
  (fn [db event] (update db :tick-count #(+ (or $1 0) 1))))

(reg-sub :sub/tick-count (fn [db] (or (get db :tick-count) 0)))
(reg-sub :sub/host-clicks (fn [db] (or (get db :host-clicks) 0)))

(canvas.register :tick-counter
  (fn [ctx]
    ;; Increment a counter on every frame. The provider runs at frame
    ;; rate; dispatch enqueues into redin_events, which the runtime
    ;; drains once per tick.
    (ctx.dispatch [:ev/tick])
    (ctx.rect 0 0 ctx.width ctx.height {:fill [255 200 50]})))

(global main_view
  (fn []
    [:vbox {:layout :center}
     [:button {:id :host
               :click [:ev/host-click]
               :animate {:provider :tick-counter
                         :rect [:top_left -4 -4 16 16]
                         :z :above}}
              "Host"]]))
