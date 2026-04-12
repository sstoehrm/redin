(require '[redin-test :refer :all])

;; Test: canvas node appears in frame tree
(deftest canvas-in-frame
  (let [frame (get-frame)]
    (assert (some? frame) "Frame should not be nil")
    (let [canvas-node (find-element {:tag :canvas})]
      (assert (some? canvas-node) "Frame should contain a canvas node"))))

;; Test: canvas has correct provider attribute
(deftest canvas-provider-attr
  (let [canvas-node (find-element {:tag :canvas})]
    (assert (some? canvas-node) "Canvas node exists")
    (let [attrs (second canvas-node)]
      (assert (= (:provider attrs) "test-canvas") "Provider is test-canvas"))))

;; Test: initial click count is 0
(deftest initial-state
  (assert-state "click-count" #(= % 0)))

;; Test: dispatch canvas-click event updates state
(deftest dispatch-updates-state
  (dispatch ["canvas-click"])
  (wait-ms 200)
  (assert-state "click-count" #(= % 1))
  ;; dispatch again
  (dispatch ["canvas-click"])
  (wait-ms 200)
  (assert-state "click-count" #(= % 2)))

;; Test: title text node exists
(deftest title-text-exists
  (let [title (find-element {:tag :text :attrs {:id "title"}})]
    (assert (some? title) "Title text node exists")))
