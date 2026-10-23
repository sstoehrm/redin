(require '[redin-test :refer :all])

;; -- Frame structure --

(deftest input-element-exists
  (let [el (find-element {:tag :input :id :test-input})]
    (assert (some? el) "Input element should exist in the frame")))

(deftest input-has-placeholder
  (let [el (find-element {:tag :input :id :test-input})
        attrs (second el)]
    (assert (= "Type here..." (:placeholder attrs)) "Input should have placeholder text")))

(deftest input-has-aspect
  (let [el (find-element {:tag :input :id :test-input})
        attrs (second el)]
    (assert (= "input" (name (:aspect attrs))) "Input should have :input aspect")))

;; -- Change events --

(deftest change-updates-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "hello"}])
  (wait-for (state= "input-value" "hello") {:timeout 2000}))

(deftest change-reflects-in-frame
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "test text"}])
  (wait-ms 200)
  (assert-element {:tag :text :id :current-value :text "value:test text"}))

(deftest change-empty-value
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "something"}])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value ""}])
  (wait-for (state= "input-value" "") {:timeout 2000}))

(deftest change-sequential-updates
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "a"}])
  (wait-ms 100)
  (dispatch ["event/input-change" {:value "ab"}])
  (wait-ms 100)
  (dispatch ["event/input-change" {:value "abc"}])
  (wait-for (state= "input-value" "abc") {:timeout 2000}))

;; -- Key events / submission --

(deftest key-enter-submits
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "item one"}])
  (wait-ms 200)
  (dispatch ["event/input-key" {:key "enter"}])
  (wait-for (state-pred "submitted" #(= (count %) 1) "submitted has 1 item") {:timeout 2000})
  (assert-state "input-value" #(= % "") "Input should clear after submit"))

(deftest key-enter-empty-noop
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-key" {:key "enter"}])
  (wait-ms 200)
  (assert-state "submitted" #(= (count %) 0) "Empty submit should not add item"))

(deftest key-tracks-last-key
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-key" {:key "escape"}])
  (wait-for (state= "last-key" "escape") {:timeout 2000}))

(deftest multiple-submissions
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "first"}])
  (wait-ms 100)
  (dispatch ["event/input-key" {:key "enter"}])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "second"}])
  (wait-ms 100)
  (dispatch ["event/input-key" {:key "enter"}])
  (wait-for (state-pred "submitted" #(= (count %) 2) "submitted has 2 items") {:timeout 2000}))

(deftest submitted-items-in-frame
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "visible item"}])
  (wait-ms 100)
  (dispatch ["event/input-key" {:key "enter"}])
  (wait-ms 200)
  (assert-element {:tag :text :id :item-1 :text "visible item"}))

;; -- Direct set --

(deftest set-input-via-dispatch
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/set-input" "direct value"])
  (wait-for (state= "input-value" "direct value") {:timeout 2000}))

;; -- Multi-line input --
;;
;; The `:multiline-input` has :change but no :key, so Enter inserts a
;; literal \n in the buffer (host/input/input.odin:293) and the
;; resulting value arrives via the :change handler. These tests
;; exercise that path via the dispatch API — no real typing is
;; possible from the dev-server HTTP surface today.

(deftest multiline-change-preserves-newlines
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/multiline-change" {:value "line1\nline2"}])
  (wait-for (state= "multiline-value" "line1\nline2") {:timeout 2000}))

(deftest multiline-change-three-lines
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/multiline-change" {:value "one\ntwo\nthree"}])
  (wait-for (state= "multiline-value" "one\ntwo\nthree") {:timeout 2000}))

(deftest multiline-change-renders-in-frame
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/multiline-change" {:value "alpha\nbeta"}])
  (wait-ms 200)
  (let [el (find-element {:tag :input :id :multiline-input})
        attrs (second el)]
    (assert (= "alpha\nbeta" (:value attrs))
            (str "Frame value should carry the newline, got: "
                 (pr-str (:value attrs))))))

(deftest multiline-change-empty-value
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/multiline-change" {:value "something\nwith\nnewlines"}])
  (wait-ms 200)
  (dispatch ["event/multiline-change" {:value ""}])
  (wait-for (state= "multiline-value" "") {:timeout 2000}))

(deftest multiline-distinct-from-single-line
  ;; Writes to one input must not leak into the other.
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/input-change" {:value "single"}])
  (dispatch ["event/multiline-change" {:value "multi\nline"}])
  (wait-ms 200)
  (assert-state "input-value" #(= % "single"))
  (assert-state "multiline-value" #(= % "multi\nline")))

;; -- Reset --

(deftest reset-clears-all
  (dispatch ["event/input-change" {:value "leftover"}])
  (dispatch ["event/multiline-change" {:value "ml\nleftover"}])
  (wait-ms 100)
  (dispatch ["event/input-key" {:key "enter"}])
  (wait-ms 200)
  (dispatch ["event/reset"])
  (wait-for (state= "input-value" "") {:timeout 2000})
  (assert-state "multiline-value" #(= % "") "Reset should clear multi-line input")
  (assert-state "submitted" #(= (count %) 0) "Reset should clear submitted list")
  (assert-state "last-key" nil? "Reset should clear last-key"))

;; -- Real key path (POST /input/key) --
;;
;; Everything above posts handler events straight to /events, which
;; bypasses the host's Key_Event_Dispatch → Lua wrapper. These tests
;; focus the input with a real click and drive keys through
;; /input/key, so the bridge's dispatch marshalling is exercised
;; end-to-end (review C1: that path was one rawseti short and every
;; `:key` handler on an `:input` silently failed).

(defn- focus-by-click! [id]
  (let [el (find-element {:tag :input :id id})
        {:keys [x y w h]} (rect-of el)]
    (assert (some? x) (str "no rect for " id))
    (click (+ x (/ w 2)) (+ y (/ h 2)))
    (wait-ms 200)))

(deftest real-key-reaches-key-handler
  (dispatch ["event/reset"])
  (wait-ms 200)
  (focus-by-click! :test-input)
  (input-key :escape)
  (wait-for (state= "last-key" "escape") {:timeout 2000}))

(deftest real-key-repeated-presses-all-delivered
  ;; Each delivery used to leak a Lua stack slot; several presses in a
  ;; row must all reach the handler.
  (dispatch ["event/reset"])
  (wait-ms 200)
  (focus-by-click! :test-input)
  (input-key :left)
  (wait-for (state= "last-key" "left") {:timeout 2000})
  (input-key :right)
  (wait-for (state= "last-key" "right") {:timeout 2000})
  (input-key :escape)
  (wait-for (state= "last-key" "escape") {:timeout 2000}))
