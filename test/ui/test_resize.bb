(require '[redin-test :refer :all])

;; Scenario from the user: resize the window through the extremes
;; (maximize, then shrink) and confirm viewport-anchored elements stay
;; at their declared anchor point in both regimes. resize_app.fnl
;; contains four buttons, each pinned by a different anchor style.

(defn- expect-pick [x y target]
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click x y)
  (wait-for (state= "picked" target) {:timeout 1000}))

;; Anchor-relative click coordinates for a given window (w, h).
;;   btn-tl rect  = (10, 10, 100, 40)                → centre (60, 30)
;;   btn-c  rect  = (w/2-50, h/2-20, 100, 40)        → centre (w/2, h/2)
;;   btn-br rect  = (w-100, h-40, 100, 40)           → centre (w-50, h-20)
;;   btn-f  rect  = (w/4, 3h/4, 100, 40)             → centre (w/4+50, 3h/4+20)
(defn- verify-anchors [w h]
  (expect-pick 60 30 1)
  (expect-pick (int (/ w 2)) (int (/ h 2)) 2)
  (expect-pick (- w 50) (- h 20) 3)
  (expect-pick (+ (int (/ w 4)) 50) (+ (int (/ (* 3 h) 4)) 20) 4))

(deftest anchors-when-maximized
  (maximize!)
  (wait-ms 300)
  (let [[w h] (window-size)]
    (println (str "  (maximized to " w "x" h ")"))
    (verify-anchors w h)))

(deftest anchors-after-shrinking
  ;; Restore first, otherwise SetWindowSize is a no-op on a maximized
  ;; window under some window managers.
  (restore!)
  (resize! 800 600)
  (wait-ms 300)
  (let [[w h] (window-size)]
    (println (str "  (shrunk to " w "x" h ")"))
    (verify-anchors w h)))
