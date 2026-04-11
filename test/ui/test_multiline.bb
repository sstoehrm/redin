(require '[redin-test :refer :all])

;; -- Text display --

(deftest wrap-text-exists
  (assert-element {:tag :text :id :wrap-text}))

(deftest newline-text-exists
  (assert-element {:tag :text :id :newline-text}))

;; -- Input multiline --

(deftest input-has-multiline-value
  (let [state (get-state "input-value")]
    (assert (clojure.string/includes? state "\n")
            "Input value should contain newline")))

(deftest input-change-preserves-newlines
  (dispatch ["event/reset"])
  (wait-ms 200)
  (let [state (get-state "input-value")]
    (assert (= state "Line one\nLine two\nLine three")
            (str "Expected multiline value, got: " state))))

(deftest input-change-with-newline
  (dispatch ["event/input-change" {:value "hello\nworld"}])
  (wait-ms 200)
  (assert-state "input-value" #(= % "hello\nworld") "Value should contain newline"))

;; -- Reset --

(deftest reset-restores-multiline
  (dispatch ["event/input-change" {:value "changed"}])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-for (state= "input-value" "Line one\nLine two\nLine three") {:timeout 2000}))
