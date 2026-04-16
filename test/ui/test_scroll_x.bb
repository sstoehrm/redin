(require '[redin-test :refer :all])

;; Hbox scroll-x lays children left-to-right at their explicit widths.
;; track is at x=8 (surface padding), width 250, with three 100-wide
;; buttons inside (total 300, overflows). At scroll_x=0, buttons 1 and 2
;; are fully within the visible band and hit testing must resolve them
;; by x-coordinate; button 3 starts at x=208 within the track, still
;; hit-testable before it gets clipped by the scissor.

(deftest track-and-buttons-exist
  (assert-element {:tag :hbox :id :track})
  (assert-element {:tag :button :id :btn-1})
  (assert-element {:tag :button :id :btn-2})
  (assert-element {:tag :button :id :btn-3}))

(deftest click-hits-button-1
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click 50 25)
  (wait-for (state= "picked" 1) {:timeout 1000}))

(deftest click-hits-button-2
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click 150 25)
  (wait-for (state= "picked" 2) {:timeout 1000}))
