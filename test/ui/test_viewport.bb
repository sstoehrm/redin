(require '[redin-test :refer :all])

;; -- Frame structure --

(deftest stack-with-viewport-renders
  (let [frame (get-frame)]
    (assert (some? frame) "Frame should not be nil")
    (assert-element {:tag :stack} "Stack element should exist")))

(deftest viewport-children-exist
  (assert-element {:tag :vbox :id :bg-layer} "Background layer should exist")
  (assert-element {:tag :hbox :id :overlay} "Overlay layer should exist"))

(deftest viewport-nested-elements-exist
  (assert-element {:tag :text :id :title :text "Background"} "Title text in bg layer")
  (assert-element {:tag :text :id :counter} "Counter text in overlay")
  (assert-element {:tag :button :id :inc-btn} "Inc button in overlay"))

;; -- State through viewport-positioned elements --

(deftest counter-starts-at-zero
  (dispatch ["event/reset"])
  (wait-for (state= "counter" 0) {:timeout 2000}))

(deftest dispatch-through-viewport-children
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (wait-for (state= "counter" 1) {:timeout 2000}))

(deftest counter-text-reflects-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (wait-ms 200)
  (assert-element {:tag :text :id :counter :text "2"}))
