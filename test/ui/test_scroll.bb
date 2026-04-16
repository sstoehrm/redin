(require '[redin-test :refer :all])

;; Issue #34: with overflow scroll-y on a vbox, children without explicit
;; height must still stack vertically. We inject clicks at three Y bands
;; (each well within the expected rect of one card's pick-button) and
;; verify a distinct card is picked for each.
;;
;; Layout at width 200, height 300, content padding 8:
;;   line_height(14) = 18 ; pick button height = 20 ; card padding 8+8
;;   card height ≈ 8 + 18 + 20 + 8 = 54
;;   card 1 y: 8..62 ; button ~38..58
;;   card 2 y: 62..116 ; button ~92..112
;;   card 3 y: 116..170 ; button ~146..166

(deftest cards-exist-in-frame
  (assert-element {:tag :vbox :id :card-1})
  (assert-element {:tag :vbox :id :card-2})
  (assert-element {:tag :vbox :id :card-3}))

(deftest click-hits-card-1
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click 100 50)
  (wait-for (state= "picked" 1) {:timeout 1000}))

(deftest click-hits-card-2
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click 100 100)
  (wait-for (state= "picked" 2) {:timeout 1000}))

(deftest click-hits-card-3
  (dispatch ["event/pick" 0])
  (wait-ms 100)
  (click 100 155)
  (wait-for (state= "picked" 3) {:timeout 1000}))
