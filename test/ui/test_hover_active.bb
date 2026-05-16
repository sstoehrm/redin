(require '[redin-test :refer :all])

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defn- btn-rect []
  (rect-of (find-element {:tag :button :aspect :btn})))

(defn- sample-bg
  "Sample a pixel from the screenshot at a bg-only point inside the button
   (4px in from the top-left corner — clear of any glyph footprint)."
  []
  (let [{:keys [x y]} (btn-rect)
        png (screenshot)]
    (screenshot-pixel png (+ x 4) (+ y 4))))

(defn- center-of
  "Return [cx cy] for the button rect's center."
  []
  (let [{:keys [x y w h]} (btn-rect)]
    [(int (+ x (/ w 2))) (int (+ y (/ h 2)))]))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(deftest button-rect-exists
  (assert (some? (btn-rect)) "Button rect should be present in /frames"))

(deftest base-color-resting
  ;; Cursor at default position (outside the button). Bg should be base.
  (input-takeover)
  (input-mouse-move 0 0)
  (wait-ms 100)
  (let [[r g b] (sample-bg)]
    (assert (= [r g b] [50 50 50])
            (str "Expected base color [50 50 50], got " [r g b])))
  (input-release))

(deftest hover-color-on-cursor-over
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [100 100 100])
              (str "Expected hover color [100 100 100], got " [r g b]))))
  (input-release))

(deftest active-color-on-mouse-down
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (input-mouse-down :left)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [200 200 200])
              (str "Expected active color [200 200 200], got " [r g b])))
    (input-mouse-up :left))
  (input-release))

(deftest active-persists-when-cursor-drags-off
  ;; CSS-like semantics: pressed button stays active until mouseup,
  ;; even when the cursor leaves the rect while still held.
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (input-mouse-down :left)
    (wait-ms 100)
    (input-mouse-move 0 0)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [200 200 200])
              (str "Active should persist while held; got " [r g b])))
    (input-mouse-up :left))
  (input-release))

(deftest base-restored-after-mouseup-off-rect
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (input-mouse-down :left)
    (wait-ms 100)
    (input-mouse-move 0 0)
    (wait-ms 100)
    (input-mouse-up :left)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [50 50 50])
              (str "After release with cursor off, base should return; got " [r g b]))))
  (input-release))
