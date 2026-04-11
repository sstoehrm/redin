(local view (require :view))
(local dataflow (require :dataflow))

(local t {})

(fn setup []
  (dataflow.reset)
  (view.reset)
  (set _G.main_view nil))

;; --- render tick ---

(fn t.test-render-tick-calls-main-view []
  (setup)
  (dataflow.init {:counter 0})
  (var called false)
  (set _G.main_view
    (fn []
      (set called true)
      [:vbox {} [:text {} "hello"]]))
  (view.render-tick)
  (assert called "main_view was called"))

(fn t.test-render-tick-captures-frame []
  (setup)
  (dataflow.init {:counter 0})
  (set _G.main_view
    (fn []
      [:vbox {} [:text {} "hello"]]))
  (view.render-tick)
  (let [state (view.get-last-push)]
    (assert state "push captured")
    (assert (= (. state 1) :vbox) "frame tag correct")))

(fn t.test-render-tick-skips-when-no-changes []
  (setup)
  (dataflow.init {:counter 0})
  (var call-count 0)
  (set _G.main_view
    (fn []
      (set call-count (+ call-count 1))
      [:vbox {} [:text {} "hello"]]))
  (view.render-tick)
  (assert (= call-count 1) "first tick renders")
  (view.render-tick)
  (assert (= call-count 1) "second tick skipped (no changes)"))

(fn t.test-render-tick-rerenders-after-dispatch []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.reg-handler :event/inc
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (var call-count 0)
  (set _G.main_view
    (fn []
      (set call-count (+ call-count 1))
      [:vbox {} [:text {} (tostring (dataflow.subscribe :sub/counter))]]))
  (dataflow.reg-sub :sub/counter
    (fn [db] (dataflow.get db :counter)))
  (view.render-tick)
  (assert (= call-count 1))
  (dataflow.dispatch [:event/inc])
  (view.render-tick)
  (assert (= call-count 2) "rerenders after dispatch"))

(fn t.test-render-tick-flattens-frame []
  (setup)
  (dataflow.init {})
  (set _G.main_view
    (fn []
      [:vbox {} [[:text {} "a"] [:text {} "b"]]]))
  (view.render-tick)
  (let [state (view.get-last-push)]
    (assert (= (length state) 4) "nested list flattened")))

(fn t.test-render-tick-without-main-view []
  (setup)
  (dataflow.init {})
  (view.render-tick)
  (assert true "no crash without main_view"))

;; --- event delivery ---

(fn t.test-deliver-events-dispatches []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.reg-handler :event/inc
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (view.deliver-events [[:event/inc]])
  (assert (= (rawget (dataflow._get-raw-db) :counter) 1) "event dispatched"))

(fn t.test-deliver-events-multiple []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.reg-handler :event/inc
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (view.deliver-events [[:event/inc] [:event/inc] [:event/inc]])
  (assert (= (rawget (dataflow._get-raw-db) :counter) 3) "three events dispatched"))

(fn t.test-deliver-events-with-context []
  (setup)
  (dataflow.init {:last-x 0})
  (dataflow.reg-handler :event/click
    (fn [db event]
      (dataflow.assoc db :last-x (. event 2 :x))))
  (view.deliver-events [[:event/click {:x 42 :y 100}]])
  (assert (= (rawget (dataflow._get-raw-db) :last-x) 42) "context passed through"))

(fn t.test-deliver-dispatch-event []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.reg-handler :event/inc
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (view.deliver-events [[:dispatch [:event/inc]]])
  (assert (= (rawget (dataflow._get-raw-db) :counter) 1) "dispatch event unwrapped"))

(fn t.test-deliver-events-empty []
  (setup)
  (dataflow.init {})
  (view.deliver-events [])
  (assert true "empty events list ok"))

t
