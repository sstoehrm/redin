;; src/runtime/canvas.fnl
(local M {})

(var registry {})

(fn build-ctx [w h input]
  (let [buf []]
    {:width w
     :height h
     :_buffer buf
     ;; Drawing primitives
     :rect (fn [x y w h ?opts]
             (table.insert buf [:rect x y w h (or ?opts {})]))
     :circle (fn [cx cy r ?opts]
               (table.insert buf [:circle cx cy r (or ?opts {})]))
     :ellipse (fn [cx cy rx ry ?opts]
                (table.insert buf [:ellipse cx cy rx ry (or ?opts {})]))
     :line (fn [x1 y1 x2 y2 ?opts]
             (table.insert buf [:line x1 y1 x2 y2 (or ?opts {})]))
     :text (fn [x y str ?opts]
             (table.insert buf [:text x y str (or ?opts {})]))
     :polygon (fn [points ?opts]
                (table.insert buf [:polygon points (or ?opts {})]))
     :image (fn [x y w h name ?opts]
              (table.insert buf [:image x y w h name (or ?opts {})]))
     ;; Input queries
     :mouse-x (fn [] (or (. input :mouse-x) 0))
     :mouse-y (fn [] (or (. input :mouse-y) 0))
     :mouse-in? (fn [] (or (. input :mouse-in) false))
     :mouse-down? (fn [?btn]
                    (let [tbl (. input :mouse-down)]
                      (if tbl (. tbl (or ?btn :left)) false)))
     :mouse-pressed? (fn [?btn]
                       (let [tbl (. input :mouse-pressed)]
                         (if tbl (. tbl (or ?btn :left)) false)))
     :mouse-released? (fn [?btn]
                        (let [tbl (. input :mouse-released)]
                          (if tbl (. tbl (or ?btn :left)) false)))
     :key-down? (fn [key]
                  (let [redin-tbl (rawget _G :redin)]
                    (if (and redin-tbl (rawget redin-tbl :key_down))
                      ((rawget redin-tbl :key_down) key)
                      false)))
     :key-pressed? (fn [key]
                     (let [redin-tbl (rawget _G :redin)]
                       (if (and redin-tbl (rawget redin-tbl :key_pressed))
                         ((rawget redin-tbl :key_pressed) key)
                         false)))
     ;; Dispatch
     :dispatch (fn [event]
                 (let [dispatch-fn (or _G.dispatch _G.redin_dispatch)]
                   (when dispatch-fn (dispatch-fn event))))}))

;; Register a draw function under a name
(fn M.register [name draw-fn]
  (tset registry name draw-fn)
  (let [redin-tbl (rawget _G :redin)]
    (when (and redin-tbl (rawget redin-tbl :canvas_register))
      ((rawget redin-tbl :canvas_register) name))))

;; Unregister a draw function
(fn M.unregister [name]
  (tset registry name nil)
  (let [redin-tbl (rawget _G :redin)]
    (when (and redin-tbl (rawget redin-tbl :canvas_unregister))
      ((rawget redin-tbl :canvas_unregister) name))))

;; Called by Odin during render phase. Returns command buffer.
(fn M._draw [name w h input]
  (let [draw-fn (. registry name)]
    (if draw-fn
      (let [ctx (build-ctx w h (or input {}))]
        (draw-fn ctx)
        ctx._buffer)
      (do
        (print (.. "Warning: no canvas draw fn registered for: " (tostring name)))
        nil))))

;; Reset (for testing)
(fn M._reset []
  (set registry {}))

;; Global registration (called by init.fnl)
(fn M.register-globals []
  (set _G.redin_canvas_draw M._draw))

M
