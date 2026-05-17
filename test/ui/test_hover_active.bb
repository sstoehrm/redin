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

(defn- assert-bg [expected step]
  (let [[r g b] (sample-bg)]
    (assert (= [r g b] expected)
            (str step ": expected " expected ", got " [r g b]))))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(deftest button-rect-exists
  (assert (some? (btn-rect)) "Button rect should be present in /frames"))

(deftest state-machine-pixel-walk
  ;; Walks one user-interaction cycle through every theme state variant,
  ;; sampling the button's bg pixel at each transition. Collapses what
  ;; was five separate deftests into one to amortise the takeover/release
  ;; + HTTP roundtrip cost — the CI llvmpipe rasterizer was hitting the
  ;; 30s per-suite budget on the split form.
  ;;
  ;; The "resting" baseline sample is intentionally omitted: the fixture
  ;; starts at rest, the rect is already visible in /frames (asserted by
  ;; button-rect-exists), and the four checks below pin down every
  ;; documented transition. Cuts the screenshot count from 5 to 4 — each
  ;; screenshot costs ~6s under CI's xvfb + llvmpipe rasterizer.
  (input-takeover)
  (try
    (let [[cx cy] (center-of)]
      ;; 1. Hover: cursor over the button → #hover overlay.
      (input-mouse-move cx cy)
      (wait-ms 100)
      (assert-bg [100 100 100] "hover")

      ;; 2. Active: press down on the button → #active overlay.
      (input-mouse-down :left)
      (wait-ms 100)
      (assert-bg [200 200 200] "active (mouse down)")

      ;; 3. Active persists while held even when cursor drags off
      ;;    (CSS-like "stays active until mouseup").
      (input-mouse-move 0 0)
      (wait-ms 100)
      (assert-bg [200 200 200] "active (cursor dragged off, still held)")

      ;; 4. Release with cursor off → base returns, no hover, no active.
      (input-mouse-up :left)
      (wait-ms 100)
      (assert-bg [50 50 50] "released with cursor off"))
    (finally
      (input-release))))
