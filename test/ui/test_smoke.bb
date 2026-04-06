(require '[redin-test :refer :all])

(deftest inspect-frame
  (let [frame (get-frame)]
    (assert (some? frame) "Frame should not be nil")))

(deftest inspect-state
  (let [state (get-state)]
    (assert (some? state) "State should not be nil")))

(deftest inspect-theme
  (let [theme (get-theme)]
    (assert (some? theme) "Theme should not be nil")
    (assert (some? (:heading theme)) "Theme should have :heading aspect")))

(deftest dispatch-and-assert-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (wait-ms 200)
  (assert-state "counter" #(= % 1)))

(deftest dispatch-multiple
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (wait-ms 200)
  (assert-state "counter" #(= % 3)))

(deftest set-message-and-assert
  (dispatch ["event/set-message" "world"])
  (wait-ms 200)
  (assert-state "message" #(= % "world"))
  (dispatch ["event/reset"]))

(deftest state-path-access
  (dispatch ["event/reset"])
  (wait-ms 200)
  (let [counter (get-state "counter")]
    (assert (= counter 0) "Counter should be 0 after reset")))

(deftest wait-for-state-change
  (dispatch ["event/reset"])
  (wait-ms 100)
  (dispatch ["event/inc"])
  (wait-for (state= "counter" 1) {:timeout 2000}))
