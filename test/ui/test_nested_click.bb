(require '[redin-test :refer :all])

;; Deepest-wins hit testing: a button (click listener) inside a hbox
;; (drag listener). Clicking the button should fire the inner click.
;; Clicking the draggable background (no inner click) should not fire
;; any user event — the bare drag listener needs movement to dispatch
;; and a single injected click has none.

(deftest elements-exist
  (assert-element {:tag :hbox :id :drag-row})
  (assert-element {:tag :button :id :drag-inner}))

(deftest click-inner-button-fires-click-not-drag
  (dispatch ["event/reset"])
  (wait-ms 100)
  ;; Button occupies x=0..100 y=0..80 inside the full-width draggable hbox.
  (click 50 40)
  (wait-for (state= "last" "drag-inner") {:timeout 1000})
  (assert-state "drag-count" #(= % 0)
                "Click on a button inside a draggable must not dispatch drag"))

(deftest click-draggable-background-no-event
  (dispatch ["event/reset"])
  (wait-ms 100)
  ;; x=500 is inside the draggable hbox but outside the button.
  (click 500 40)
  (wait-ms 300)
  (assert-state "last" nil?
                "Background click on draggable with no movement dispatches nothing")
  (assert-state "drag-count" #(= % 0)))
