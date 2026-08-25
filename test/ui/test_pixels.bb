(require '[redin-test :refer :all])

;; -- Stability: 58 sprites x 64x96 via ctx.pixels (the #279 scene) --

(deftest canvas-exists-and-survives-sustained-draws
  (assert-element {:tag :canvas :id :film} "filmstrip canvas should exist")
  (wait-ms 1000)
  (assert-element {:tag :canvas :id :film} "app alive after ~60 frames of pixels draws"))

(deftest screenshot-valid-with-pixels
  (let [[w h] (screenshot-dims (screenshot))]
    (assert (pos? w) "screenshot decodes with pixel sprites on screen")))

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
  (let [prof (get-profile)]
    (assert prof "profile endpoint should respond (REDIN_PROFILE build)")
    (let [render-ms (profile-avg-render-ms prof)]
      (assert (< render-ms 8.0)
              (str "steady-state render should be <8ms, got " render-ms)))))
