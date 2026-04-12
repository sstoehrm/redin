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

t
