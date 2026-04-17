(require '[redin-test :refer :all])

;; Window resize: viewport-anchored children must re-resolve to the new
;; window dimensions each frame. We drive the window to two sizes and
;; verify that a click at the anchor-relative coordinate still lands on
;; the expected button.

(defn- expect-pick [x y target]
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click x y)
  (wait-for (state= "picked" target) {:timeout 1000}))

;; btn-f rect origin is (W/4, 3H/4), size 100×40; its center is (W/4+50, 3H/4+20).
(defn- fraction-center [w h]
  [(+ (int (/ w 4)) 50)
   (+ (int (/ (* 3 h) 4)) 20)])

(deftest anchors-at-800x600
  (resize! 800 600)
  (wait-ms 200)
  (expect-pick 50 30 1)
  (expect-pick 400 300 2)
  (expect-pick 750 580 3)
  (let [[fx fy] (fraction-center 800 600)] (expect-pick fx fy 4)))

(deftest anchors-at-1000x700
  (resize! 1000 700)
  (wait-ms 200)
  (expect-pick 50 30 1)
  (expect-pick 500 350 2)
  (expect-pick 950 680 3)
  (let [[fx fy] (fraction-center 1000 700)] (expect-pick fx fy 4)))

(deftest anchors-at-1200x900
  (resize! 1200 900)
  (wait-ms 200)
  (expect-pick 50 30 1)
  (expect-pick 600 450 2)
  (expect-pick 1150 880 3)
  (let [[fx fy] (fraction-center 1200 900)] (expect-pick fx fy 4)))
