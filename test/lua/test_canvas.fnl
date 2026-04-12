;; test/lua/test_canvas.fnl
(local canvas (require :canvas))

(local t {})

(fn setup []
  (canvas._reset))

;; --- ctx drawing primitives ---

(fn t.test-ctx-rect-appends-to-buffer []
  (setup)
  (canvas.register :test-draw
    (fn [ctx]
      (ctx.rect 10 20 100 50 {:fill [255 0 0]})))
  (let [buf (canvas._draw :test-draw 400 300 {})]
    (assert buf "buffer returned")
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :rect) "tag is rect")
      (assert (= (. cmd 2) 10) "x")
      (assert (= (. cmd 3) 20) "y")
      (assert (= (. cmd 4) 100) "w")
      (assert (= (. cmd 5) 50) "h")
      (assert (= (. (. cmd 6) :fill 1) 255) "fill r"))))

(fn t.test-ctx-circle-appends-to-buffer []
  (setup)
  (canvas.register :test-circle
    (fn [ctx]
      (ctx.circle 50 60 25 {:fill [0 255 0]})))
  (let [buf (canvas._draw :test-circle 400 300 {})]
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :circle) "tag is circle")
      (assert (= (. cmd 2) 50) "cx")
      (assert (= (. cmd 3) 60) "cy")
      (assert (= (. cmd 4) 25) "r"))))

(fn t.test-ctx-line-appends-to-buffer []
  (setup)
  (canvas.register :test-line
    (fn [ctx]
      (ctx.line 0 0 100 100 {:stroke [0 0 0] :width 2})))
  (let [buf (canvas._draw :test-line 400 300 {})]
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :line) "tag is line")
      (assert (= (. cmd 5) 100) "y2"))))

(fn t.test-ctx-text-appends-to-buffer []
  (setup)
  (canvas.register :test-text
    (fn [ctx]
      (ctx.text 10 20 "hello" {:size 16 :color [0 0 0]})))
  (let [buf (canvas._draw :test-text 400 300 {})]
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :text) "tag is text")
      (assert (= (. cmd 4) "hello") "text content"))))

(fn t.test-ctx-ellipse-appends-to-buffer []
  (setup)
  (canvas.register :test-ellipse
    (fn [ctx]
      (ctx.ellipse 100 100 40 20 {:fill [0 0 255]})))
  (let [buf (canvas._draw :test-ellipse 400 300 {})]
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :ellipse) "tag is ellipse")
      (assert (= (. cmd 4) 40) "rx")
      (assert (= (. cmd 5) 20) "ry"))))

(fn t.test-ctx-polygon-appends-to-buffer []
  (setup)
  (canvas.register :test-polygon
    (fn [ctx]
      (ctx.polygon [[0 0] [100 0] [50 80]] {:fill [255 255 0]})))
  (let [buf (canvas._draw :test-polygon 400 300 {})]
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :polygon) "tag is polygon")
      (assert (= (length (. cmd 2)) 3) "3 points"))))

(fn t.test-ctx-image-appends-to-buffer []
  (setup)
  (canvas.register :test-image
    (fn [ctx]
      (ctx.image 10 10 64 64 "icon")))
  (let [buf (canvas._draw :test-image 400 300 {})]
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :image) "tag is image")
      (assert (= (. cmd 6) "icon") "asset name"))))

(fn t.test-ctx-multiple-commands []
  (setup)
  (canvas.register :test-multi
    (fn [ctx]
      (ctx.rect 0 0 10 10 {})
      (ctx.circle 50 50 5 {})
      (ctx.line 0 0 100 100 {})))
  (let [buf (canvas._draw :test-multi 400 300 {})]
    (assert (= (length buf) 3) "three commands")
    (assert (= (. (. buf 1) 1) :rect) "first is rect")
    (assert (= (. (. buf 2) 1) :circle) "second is circle")
    (assert (= (. (. buf 3) 1) :line) "third is line")))

(fn t.test-ctx-width-height []
  (setup)
  (var captured-w nil)
  (var captured-h nil)
  (canvas.register :test-dims
    (fn [ctx]
      (set captured-w ctx.width)
      (set captured-h ctx.height)))
  (canvas._draw :test-dims 800 600 {})
  (assert (= captured-w 800) "width passed")
  (assert (= captured-h 600) "height passed"))

;; --- registry ---

(fn t.test-register-stores-draw-fn []
  (setup)
  (var called false)
  (canvas.register :test-reg (fn [ctx] (set called true)))
  (canvas._draw :test-reg 100 100 {})
  (assert called "draw fn was called"))

(fn t.test-unregister-removes-draw-fn []
  (setup)
  (var called false)
  (canvas.register :test-unreg (fn [ctx] (set called true)))
  (canvas.unregister :test-unreg)
  (let [buf (canvas._draw :test-unreg 100 100 {})]
    (assert (= buf nil) "returns nil after unregister")
    (assert (not called) "draw fn not called")))

(fn t.test-draw-unknown-name-returns-nil []
  (setup)
  (let [buf (canvas._draw :nonexistent 100 100 {})]
    (assert (= buf nil) "nil for unknown")))

(fn t.test-fresh-buffer-per-call []
  (setup)
  (canvas.register :test-fresh
    (fn [ctx] (ctx.rect 0 0 10 10 {})))
  (let [buf1 (canvas._draw :test-fresh 100 100 {})
        buf2 (canvas._draw :test-fresh 100 100 {})]
    (assert (= (length buf1) 1) "first call has 1")
    (assert (= (length buf2) 1) "second call has 1")
    (assert (~= buf1 buf2) "different buffer objects")))

;; --- input queries ---

(fn t.test-ctx-mouse-position []
  (setup)
  (var mx nil)
  (var my nil)
  (canvas.register :test-mouse
    (fn [ctx]
      (set mx (ctx.mouse-x))
      (set my (ctx.mouse-y))))
  (canvas._draw :test-mouse 400 300
    {:mouse-x 150 :mouse-y 200})
  (assert (= mx 150) "mouse-x")
  (assert (= my 200) "mouse-y"))

(fn t.test-ctx-mouse-defaults-to-zero []
  (setup)
  (var mx nil)
  (canvas.register :test-mouse-default
    (fn [ctx] (set mx (ctx.mouse-x))))
  (canvas._draw :test-mouse-default 400 300 {})
  (assert (= mx 0) "defaults to 0"))

(fn t.test-ctx-mouse-in []
  (setup)
  (var inside nil)
  (canvas.register :test-mouse-in
    (fn [ctx] (set inside (ctx.mouse-in?))))
  (canvas._draw :test-mouse-in 400 300 {:mouse-in true})
  (assert (= inside true) "mouse is in"))

(fn t.test-ctx-mouse-buttons []
  (setup)
  (var down nil)
  (var pressed nil)
  (var released nil)
  (canvas.register :test-buttons
    (fn [ctx]
      (set down (ctx.mouse-down?))
      (set pressed (ctx.mouse-pressed?))
      (set released (ctx.mouse-released?))))
  (canvas._draw :test-buttons 400 300
    {:mouse-down {:left true :right false :middle false}
     :mouse-pressed {:left false :right false :middle false}
     :mouse-released {:left false :right false :middle false}})
  (assert (= down true) "left down")
  (assert (= pressed false) "not pressed")
  (assert (= released false) "not released"))

(fn t.test-ctx-mouse-button-right []
  (setup)
  (var right-down nil)
  (canvas.register :test-right
    (fn [ctx]
      (set right-down (ctx.mouse-down? :right))))
  (canvas._draw :test-right 400 300
    {:mouse-down {:left false :right true :middle false}})
  (assert (= right-down true) "right down"))

;; --- dispatch ---

(fn t.test-ctx-dispatch []
  (setup)
  (let [dispatched []]
    (set _G.dispatch (fn [event] (table.insert dispatched event)))
    (canvas.register :test-dispatch
      (fn [ctx]
        (ctx.dispatch [:test-event {:x 10}])))
    (canvas._draw :test-dispatch 400 300 {})
    (set _G.dispatch nil)
    (assert (= (length dispatched) 1) "one event dispatched")
    (assert (= (. (. dispatched 1) 1) :test-event) "event name")))

;; --- init wiring ---

(fn t.test-canvas-global-set-after-register-globals []
  (setup)
  (canvas.register-globals)
  (assert _G.redin_canvas_draw "redin_canvas_draw global exists")
  (set _G.redin_canvas_draw nil))

t
