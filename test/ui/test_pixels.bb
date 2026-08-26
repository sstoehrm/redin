(require '[redin-test :refer :all])

;; -- Stability: 58 sprites x 64x96 via ctx.pixels (the #279 scene) --

(deftest canvas-exists-and-survives-sustained-draws
  (assert-element {:tag :canvas :id :film} "filmstrip canvas should exist")
  (wait-ms 1000)
  (assert-element {:tag :canvas :id :film} "app alive after ~60 frames of pixels draws"))

(deftest screenshot-valid-with-pixels
  (let [[w h] (screenshot-dims (screenshot))]
    (assert (pos? w) "screenshot decodes with pixel sprites on screen")))

;; -- Pixel spot-check (#1) --
;; Each sprite's colors are deterministic (see pixels_app.fnl make-sprite):
;; r=(37*i)%256, g=(91*i)%256, b=(53*i)%256. Sprite i=1 -> r=37 g=91 b=53,
;; well clear of the :film canvas bg [30 32 40]. Sample mid-sprite of the
;; first tile (col 0, row 0 of the 10-col grid, local origin (0,0),
;; sprite size 64x96) and assert it differs from the bg -- proof a real
;; texture, not just the background, landed on screen.

(deftest first-sprite-pixel-differs-from-canvas-bg
  (let [film (find-element {:tag :canvas :id :film})
        r    (rect-of film)]
    (assert r (str "filmstrip canvas must have a rect; got " (pr-str (second film))))
    (let [png (screenshot)
          sx  (int (+ (:x r) 32)) ;; mid-width of the first 64px-wide sprite
          sy  (int (+ (:y r) 48)) ;; mid-height of the first 96px-tall sprite
          [pr pg pb] (screenshot-pixel png sx sy)
          bg [30 32 40]
          tol 20
          close? (fn [a b] (< (Math/abs (- a b)) tol))]
      (assert (not (and (close? pr (nth bg 0))
                         (close? pg (nth bg 1))
                         (close? pb (nth bg 2))))
              (str "sprite pixel should differ from :film bg " bg
                   "; got [" pr " " pg " " pb "]")))))

;; -- Perf: render share must be far below the 22.7ms baseline (#279). --
;; Threshold is deliberately loose (8ms) to keep CI machines from flaking;
;; the dev overlay/issue baseline for this scene without ctx.pixels is 22.7ms.

(defn- profile-avg-render-ms
  "Mean of the render-phase samples (µs -> ms) across the current
   /profile ring buffer. `:phases` names each slot in a frame's
   `:phase_us` array; look up the render slot's index once and average
   it across `:frames` (see test_profile.bb for the response shape)."
  [profile]
  (let [render-idx (.indexOf ^java.util.List (:phases profile) "render")
        samples (map #(nth (:phase_us %) render-idx) (:frames profile))]
    (assert (seq samples) "profile ring should have at least one frame")
    (/ (double (reduce + samples)) (count samples) 1000.0)))

(deftest render-time-under-threshold
  (wait-ms 1000) ;; warm the texture cache; steady state is what we measure
  (let [prof (get-profile-json)]
    (assert prof "profile endpoint should respond (REDIN_PROFILE build)")
    (let [render-ms (profile-avg-render-ms prof)]
      (assert (< render-ms 8.0)
              (str "steady-state render should be <8ms, got " render-ms)))))
