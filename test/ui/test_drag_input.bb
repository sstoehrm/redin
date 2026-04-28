(require '[redin-test :refer :all])

;; ---------------------------------------------------------------------------
;; Helpers to find row positions from the frame tree
;; ---------------------------------------------------------------------------

(defn- find-rows
  "Return all :hbox nodes with :row aspect from the current frame."
  []
  (find-elements {:tag :hbox :aspect :row}))

(defn- row-center-x [row]
  (let [attrs (when (and (vector? row) (> (count row) 1)) (second row))]
    (or (:cx attrs) 300)))

(defn- row-center-y [row]
  (let [attrs (when (and (vector? row) (> (count row) 1)) (second row))]
    (or (:cy attrs) 100)))

;; Approximate positions from the drag_app.fnl layout:
;;   surface padding 24, title ~20px, rows height 42, row padding 4
;;   row 1 top ≈ y=68, center ≈ y=89
;;   The window is 800×600 by default; x center ≈ 400, but rows fill the vbox
;;   We use a fixed x=300 (within any normal window width) for reliability.

(def ROW-X 300)
(def ROW1-Y 89)
(def ROW2-Y 131)
(def ROW3-Y 173)
(def ROW4-Y 215)
;; A move of 10px clearly crosses the 4px threshold from row1 start.
(def MOVE-Y (+ ROW1-Y 10))

;; ---------------------------------------------------------------------------
;; Test: idle state before any input
;; ---------------------------------------------------------------------------

(deftest drag-state-idle-initially
  (dispatch ["event/reset"])
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "idle" (:state ds))
            (str "Expected idle drag state, got: " (pr-str ds)))))

;; ---------------------------------------------------------------------------
;; Test: mouse-down transitions to pending
;; ---------------------------------------------------------------------------

(deftest mouse-down-enters-pending
  (dispatch ["event/reset"])
  (wait-ms 100)
  (mouse-down ROW-X ROW1-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "pending" (:state ds))
            (str "Expected pending after mouse-down, got: " (pr-str ds)))
    (assert (some? (:src_idx ds))
            "Expected src_idx to be set in pending state"))
  ;; Clean up
  (mouse-up)
  (wait-ms 100))

;; ---------------------------------------------------------------------------
;; Test: mouse-up from pending returns to idle
;; ---------------------------------------------------------------------------

(deftest mouse-up-from-pending-returns-idle
  (dispatch ["event/reset"])
  (wait-ms 100)
  (mouse-down ROW-X ROW1-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "pending" (:state ds))
            (str "Expected pending, got: " (pr-str ds))))
  (mouse-up)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "idle" (:state ds))
            (str "Expected idle after mouse-up, got: " (pr-str ds)))))

;; ---------------------------------------------------------------------------
;; Test: full drag flow — pending → active → drop → idle + state updated
;; ---------------------------------------------------------------------------

(deftest full-drag-flow
  (dispatch ["event/reset"])
  (wait-ms 150)
  ;; 1. Mouse down on row 1
  (mouse-down ROW-X ROW1-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "pending" (:state ds))
            (str "Step 1: expected pending, got: " (pr-str ds))))
  ;; 2. Move past the 4px threshold to activate the drag
  (mouse-move ROW-X MOVE-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "active" (:state ds))
            (str "Step 2: expected active after threshold move, got: " (pr-str ds))))
  ;; 3. Move over row 3 (target drop zone)
  (mouse-move ROW-X ROW3-Y)
  (wait-ms 100)
  ;; 4. Release over row 3
  (mouse-up ROW-X ROW3-Y)
  (wait-ms 200)
  ;; 5. State should return to idle
  (let [ds (drag-state)]
    (assert (= "idle" (:state ds))
            (str "Step 4: expected idle after drop, got: " (pr-str ds))))
  ;; 6. last-drop should reflect the drop (from=1, to varies based on hit-test)
  ;;    We just verify the drop handler was called (last-drop is not nil).
  (assert-state "last-drop" some?
                "Expected last-drop to be set after a real drop"))

;; ---------------------------------------------------------------------------
;; Test: Escape cancels in-flight drag
;; ---------------------------------------------------------------------------

(deftest esc-cancels-pending-drag
  (dispatch ["event/reset"])
  (wait-ms 100)
  (mouse-down ROW-X ROW1-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "pending" (:state ds))
            (str "Expected pending before Esc, got: " (pr-str ds))))
  (key-press "escape")
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "idle" (:state ds))
            (str "Expected idle after Esc from pending, got: " (pr-str ds)))))

(deftest esc-cancels-active-drag
  (dispatch ["event/reset"])
  (wait-ms 100)
  ;; Enter active state
  (mouse-down ROW-X ROW1-Y)
  (wait-ms 100)
  (mouse-move ROW-X MOVE-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "active" (:state ds))
            (str "Expected active before Esc, got: " (pr-str ds))))
  ;; Press Escape
  (key-press "escape")
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "idle" (:state ds))
            (str "Expected idle after Esc from active, got: " (pr-str ds))))
  ;; last-drop should NOT have been set (cancel, not drop)
  (assert-state "last-drop" nil?
                "Expected last-drop nil after Esc cancel"))

;; ---------------------------------------------------------------------------
;; Test: /drag-state JSON shape for active state
;; ---------------------------------------------------------------------------

(deftest drag-state-active-has-expected-fields
  (dispatch ["event/reset"])
  (wait-ms 100)
  (mouse-down ROW-X ROW1-Y)
  (wait-ms 100)
  (mouse-move ROW-X MOVE-Y)
  (wait-ms 100)
  (let [ds (drag-state)]
    (assert (= "active" (:state ds))
            (str "Expected active, got: " (pr-str ds)))
    (assert (some? (:src_idx ds))   "src_idx should be present")
    (assert (some? (:src_event ds)) "src_event should be present")
    (assert (some? (:src_mode ds))  "src_mode should be present")
    (assert (some? (:src_tags ds))  "src_tags should be present"))
  ;; Clean up
  (key-press "escape")
  (wait-ms 100))
