(require '[redin-test :refer :all])

;; -- Frame structure --

(deftest drag-items-exist
  (let [items (find-elements {:tag :hbox :aspect :row})]
    (assert (= 4 (count items)) (str "Expected 4 row items, got " (count items)))))

(deftest items-have-text
  (assert-element {:tag :text :id :item-1 :text "A"})
  (assert-element {:tag :text :id :item-2 :text "B"})
  (assert-element {:tag :text :id :item-3 :text "C"})
  (assert-element {:tag :text :id :item-4 :text "D"}))

;; -- Drag event --

(deftest drag-event-updates-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/drag" {:value 2}])
  (wait-for (state= "last-drag" 2) {:timeout 2000}))

;; -- Drop event --

(deftest drop-event-updates-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/drop" {:from 1 :to 3}])
  (wait-ms 200)
  (assert-state "last-drop.from" #(= % 1) "drop from should be 1")
  (assert-state "last-drop.to" #(= % 3) "drop to should be 3"))

(deftest drop-reorders-items
  (dispatch ["event/reset"])
  (wait-ms 200)
  ;; Move item 1 (A) to position 3
  (dispatch ["event/drop" {:from 1 :to 3}])
  (wait-ms 300)
  ;; After moving A from 1 to 3: [B, A, C, D]
  (assert-element {:tag :text :id :item-1 :text "B"})
  (assert-element {:tag :text :id :item-2 :text "A"})
  (assert-element {:tag :text :id :item-3 :text "C"})
  (assert-element {:tag :text :id :item-4 :text "D"}))

;; -- Reset --

(deftest reset-clears-drag-state
  (dispatch ["event/drag" {:value 1}])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-for (state= "last-drag" nil) {:timeout 2000})
  (assert-state "last-drop" nil? "Reset should clear last-drop"))

(deftest reset-restores-items
  (dispatch ["event/drop" {:from 1 :to 3}])
  (wait-ms 200)
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-element {:tag :text :id :item-1 :text "A"})
  (assert-element {:tag :text :id :item-2 :text "B"})
  (assert-element {:tag :text :id :item-3 :text "C"})
  (assert-element {:tag :text :id :item-4 :text "D"}))
