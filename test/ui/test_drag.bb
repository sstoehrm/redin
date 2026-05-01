(require '[redin-test :refer :all]
         '[clojure.java.io :as io])

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

;; -- Drag-over phase events --

(deftest drag-over-enter-fires
  (dispatch ["event/reset"])
  (wait-ms 200)
  ;; Synthesise an :event/over with :phase :enter (the framework would fire
  ;; this when a compatible drag enters the zone; here we test the handler
  ;; receives it correctly)
  (dispatch ["event/over" {:phase "enter"}])
  (wait-for (state= "last-over" "enter") {:timeout 2000}))

(deftest drag-over-leave-fires
  (dispatch ["event/over" {:phase "leave"}])
  (wait-for (state= "last-over" "leave") {:timeout 2000}))

;; -- Tag-aware drop --

(deftest drop-shape-includes-tags-context
  ;; The framework filters drops by tag intersection; here the handler
  ;; just receives :from / :to. This case verifies the handler still gets
  ;; the right shape after the API change.
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/drop" {:from 1 :to 4}])
  (wait-ms 200)
  (assert-state "last-drop.from" #(= % 1) "from preserved")
  (assert-state "last-drop.to"   #(= % 4) "to preserved"))

;; ---------------------------------------------------------------------------
;; End-to-end via input pipeline (real press/move/release through dev server)
;; ---------------------------------------------------------------------------

(defn- ensure-artifacts-dir []
  (let [d (io/file "test/ui/artifacts")]
    (when-not (.exists d) (.mkdirs d))))

(deftest drag-preview-pops-out
  (dispatch ["event/reset"])
  (wait-ms 100)
  (ensure-artifacts-dir)
  (let [src (rect-of (find-element {:id :row-1}))
        dst (rect-of (find-element {:id :row-3}))]
    (assert src "row-1 must have a :rect from /frames")
    (assert dst "row-3 must have a :rect from /frames")
    (let [sx (+ (:x src) 10) sy (+ (:y src) 2)   ; y+2 stays in row top-padding, above the text node
          dx (+ (:x dst) 10) dy (+ (:y dst) 2)]
      (input-takeover)
      (try
        (input-mouse-move sx sy)
        (input-mouse-down :left)
        (input-mouse-move (+ sx 20) sy)           ; cross 4px threshold (stay in same row padding row)
        (wait-for (state= "last-drag" 1) {:timeout 2000})
        (input-mouse-move dx dy)                  ; preview now over drop target
        (wait-ms 100)                             ; let render catch up
        (screenshot "test/ui/artifacts/drag_preview.png")
        (input-mouse-up :left)
        (wait-for (state= "last-drop.from" 1) {:timeout 2000})
        (assert-state "last-drop.to" #(= % 3) "drop target should be row-3")
        (finally
          (input-release))))))

(deftest drag-esc-cancels
  (dispatch ["event/reset"])
  (wait-ms 100)
  (let [src (rect-of (find-element {:id :row-1}))]
    (assert src "row-1 must have a :rect from /frames")
    (let [sx (+ (:x src) 10) sy (+ (:y src) 2)]   ; y+2 stays in row top-padding, above the text node
      (input-takeover)
      (try
        (input-mouse-move sx sy)
        (input-mouse-down :left)
        (input-mouse-move (+ sx 20) sy)
        (wait-for (state= "last-drag" 1) {:timeout 2000})
        (input-key :escape)
        (wait-ms 150)
        (input-mouse-up :left)
        (wait-ms 150)
        (assert-state "last-drop" nil? "Esc should cancel the drag — no drop fires")
        (finally
          (input-release))))))
