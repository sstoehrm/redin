(local view (require :view))
(local dataflow (require :dataflow))
(local effect (require :effect))

(local t {})

(fn setup []
  (dataflow.reset)
  (effect.reset)
  (view.reset)
  (dataflow.register-globals)
  (effect.register-globals)
  (dataflow.set-effect-handler effect.execute)
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

;; --- response event routing ---
;; These tests verify the full delivery path: view.deliver-events routes
;; response events to the correct effect handler, which dispatches to
;; the registered callback. This catches colon-prefix mismatches between
;; the Odin bridge (which sends the event type string) and Fennel
;; (which compares against it).

(fn t.test-deliver-http-response-routes-to-effect []
  (setup)
  (let [effect (require :effect)]
    (effect.reset)
    (dataflow.init {:result nil})
    (dataflow.reg-handler :event/http-done
      (fn [db event]
        (dataflow.assoc db :result (. event 2 :body))))
    ;; Register the http effect and queue a pending request
    (let [calls []]
      (set _G.redin_http (fn [id ...] (table.insert calls {:id id})))
      (effect.execute {:db nil
                       :http {:url "http://test"
                              :on-success :event/http-done
                              :on-error :event/http-fail}})
      (let [id (. (. calls 1) :id)]
        (set _G.redin_http nil)
        ;; Simulate what the Odin bridge sends: event type WITHOUT colon
        (view.deliver-events [[:http-response {:id id :status 200 :body "ok"}]])
        (assert (= (rawget (dataflow._get-raw-db) :result) "ok")
                "http-response routed through deliver-events to effect handler")))))

(fn t.test-deliver-shell-response-routes-to-effect []
  (setup)
  (let [effect (require :effect)]
    (effect.reset)
    (dataflow.init {:output nil})
    (dataflow.reg-handler :event/shell-done
      (fn [db event]
        (dataflow.assoc db :output (. event 2 :stdout))))
    (let [calls []]
      (set _G.redin_shell (fn [id ...] (table.insert calls {:id id})))
      (effect.execute {:db nil
                       :shell {:cmd ["echo" "hello"]
                               :on-success :event/shell-done
                               :on-error :event/shell-fail}})
      (let [id (. (. calls 1) :id)]
        (set _G.redin_shell nil)
        ;; Simulate what the Odin bridge sends
        (view.deliver-events [[:shell-response {:id id :stdout "hello\n" :stderr "" :exit-code 0}]])
        (assert (= (rawget (dataflow._get-raw-db) :output) "hello\n")
                "shell-response routed through deliver-events to effect handler")))))

(fn t.test-deliver-shell-error-routes-to-on-error []
  (setup)
  (let [effect (require :effect)]
    (effect.reset)
    (dataflow.init {:error-code nil})
    (dataflow.reg-handler :event/shell-done
      (fn [db event] db))
    (dataflow.reg-handler :event/shell-fail
      (fn [db event]
        (dataflow.assoc db :error-code (. event 2 :exit-code))))
    (let [calls []]
      (set _G.redin_shell (fn [id ...] (table.insert calls {:id id})))
      (effect.execute {:db nil
                       :shell {:cmd ["false"]
                               :on-success :event/shell-done
                               :on-error :event/shell-fail}})
      (let [id (. (. calls 1) :id)]
        (set _G.redin_shell nil)
        (view.deliver-events [[:shell-response {:id id :stdout "" :stderr "fail" :exit-code 1}]])
        (assert (= (rawget (dataflow._get-raw-db) :error-code) 1)
                "shell error routed to on-error handler")))))

t
