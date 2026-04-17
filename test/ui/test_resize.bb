(require '[redin-test :refer :all])

;; Scenario from the user: drive the window to both extremes (maximize,
;; then shrink) and confirm viewport-anchored elements stay pinned to
;; their declared anchor at each size. Each step also saves a screenshot
;; to /tmp/ and verifies it programmatically: the framebuffer
;; dimensions must be a consistent scale of the logical window.

;; ---- helpers ----

(defn- expect-pick [x y target]
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click x y)
  (wait-for (state= "picked" target) {:timeout 1000}))

;; Anchor-relative click coordinates for a window of (w, h).
;;   btn-tl  →  (60, 30)               ; top-left fixed offset
;;   btn-c   →  (w/2, h/2)             ; centre
;;   btn-br  →  (w-50, h-20)           ; bottom-right
;;   btn-f   →  (w/4 + 50, 3h/4 + 20)  ; fractional position
(defn- verify-anchors [w h]
  (expect-pick 60 30 1)
  (expect-pick (int (/ w 2)) (int (/ h 2)) 2)
  (expect-pick (- w 50) (- h 20) 3)
  (expect-pick (+ (int (/ w 4)) 50) (+ (int (/ (* 3 h) 4)) 20) 4))

(defn- verify-screenshot [label w h png-path]
  (let [bytes (screenshot png-path)
        [iw ih] (screenshot-dims bytes)
        sx (/ (double iw) w)
        sy (/ (double ih) h)]
    (println (str "  [" label "] window=" w "x" h
                  " image=" iw "x" ih
                  " scale=" (format "%.2f" sx)))
    (when-not (and (pos? iw) (pos? ih))
      (throw (ex-info "empty screenshot" {:label label :dims [iw ih]})))
    (when-not (< (Math/abs (- sx sy)) 0.05)
      (throw (ex-info (str "x/y scale mismatch: " sx " vs " sy)
                      {:label label :sx sx :sy sy})))
    {:scale sx :image-dims [iw ih]}))

;; Stash per-test results so the second test can compare against the
;; first (smaller window must produce a smaller screenshot).
(def ^:private run-state (atom {}))

;; ---- tests ----

(deftest anchors-when-maximized
  (maximize!)
  (wait-ms 400)
  (let [[w h] (window-size)]
    (verify-anchors w h)
    (let [result (verify-screenshot "maximized" w h "/tmp/redin-resize-maximized.png")]
      (swap! run-state assoc :maximized (assoc result :window [w h])))))

(deftest anchors-after-shrinking
  ;; Restore first — SetWindowSize is a no-op on a maximized window
  ;; under some window managers.
  (restore!)
  (resize! 800 600)
  (wait-ms 400)
  (let [[w h] (window-size)]
    (verify-anchors w h)
    (let [result (verify-screenshot "shrunk" w h "/tmp/redin-resize-shrunk.png")]
      (swap! run-state assoc :shrunk (assoc result :window [w h])))))

(deftest screenshots-shrink-with-window
  (let [max-st (:maximized @run-state)
        small-st (:shrunk @run-state)]
    (when-not (and max-st small-st)
      (throw (ex-info "prior tests did not record screenshot state"
                      {:state @run-state})))
    (let [[mw mh] (:image-dims max-st)
          [sw sh] (:image-dims small-st)]
      (when-not (> mw sw)
        (throw (ex-info "maximized screenshot should be wider than shrunk"
                        {:maximized [mw mh] :shrunk [sw sh]})))
      (when-not (> mh sh)
        (throw (ex-info "maximized screenshot should be taller than shrunk"
                        {:maximized [mw mh] :shrunk [sw sh]}))))
    (when-not (< (Math/abs (- (:scale max-st) (:scale small-st))) 0.05)
      (throw (ex-info "HiDPI scale factor differed between window sizes"
                      {:maximized-scale (:scale max-st)
                       :shrunk-scale (:scale small-st)})))))
