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

;; Review C2: malformed draw-command arguments must not kill the process.
;; Kept LAST in this file: pre-fix, flipping :bad-args aborts the app.
(deftest bad-draw-args-do-not-crash-and-valid-commands-still-draw
  (dispatch ["canvas/bad-args"])
  (wait-for (state= "bad-args" true) {:timeout 2000})
  ;; Let several frames run the malformed commands.
  (wait-ms 500)
  (assert-state "click-count" some? "app must still answer /state")
  (let [cv (find-element {:tag :canvas})
        {:keys [x y]} (rect-of cv)
        _ (assert (some? x) "canvas has a rect")
        png (screenshot)
        ;; magenta marker at canvas-local (240,10,40,30); red rect at (20,20,100,60)
        [marker red] (screenshot-pixels png [[(int (+ x 260)) (int (+ y 25))]
                                             [(int (+ x 70)) (int (+ y 50))]])]
    (assert (= marker [200 0 200]) (str "valid command after bad ones should draw magenta, got " marker))
    (assert (= red [220 50 50]) (str "pre-existing red rect should still draw, got " red))))
