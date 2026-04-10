(require '[redin-test :refer :all])

;; -- Frame structure --

(deftest button-elements-exist
  (assert-element {:tag :button :id :inc-btn} "Inc button should exist")
  (assert-element {:tag :button :id :dec-btn} "Dec button should exist")
  (assert-element {:tag :button :id :reset-btn} "Reset button should exist"))

(deftest counter-starts-at-zero
  (dispatch ["event/reset"])
  (wait-for (state= "counter" 0) {:timeout 2000}))

;; -- Click dispatch via dev server --

(deftest click-inc-updates-counter
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (wait-for (state= "counter" 1) {:timeout 2000})
  (assert-state "last-action" #(= % "inc")))

(deftest click-dec-updates-counter
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/dec"])
  (wait-for (state= "counter" -1) {:timeout 2000})
  (assert-state "last-action" #(= % "dec")))

(deftest click-inc-multiple
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (wait-for (state= "counter" 3) {:timeout 2000}))

(deftest click-reset-clears-counter
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (wait-ms 200)
  (dispatch ["event/reset"])
  (wait-for (state= "counter" 0) {:timeout 2000})
  (assert-state "last-action" #(= % "reset")))

(deftest counter-reflects-in-frame
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (wait-ms 200)
  (assert-element {:tag :text :id :counter :text "2"}))

;; -- Coordinate-based click (tests the actual host click pipeline) --

(deftest host-click-on-button
  (dispatch ["event/reset"])
  (wait-ms 200)
  ;; Buttons are centered in a 1280px-wide vbox, width=100, so x≈590..690.
  ;; Layout: text(h=18), text(h=18), inc-btn(y=36,h=36), dec-btn, reset-btn.
  ;; Click center of inc button.
  (click 640 54)
  (wait-for (state= "counter" 1) {:timeout 3000})
  (assert-state "last-action" #(= % "inc") "Host click should trigger inc"))
