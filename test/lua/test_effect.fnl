(local effect (require :effect))
(local dataflow (require :dataflow))

(local t {})

(fn setup []
  (effect.reset)
  (dataflow.reset))

;; --- reg-fx + execute ---

(fn t.test-reg-fx-and-execute []
  (setup)
  (let [calls []]
    (effect.reg-fx :test-fx
      (fn [params] (table.insert calls params)))
    (effect.execute {:db nil :test-fx "hello"})
    (assert (= (length calls) 1) "executor called once")
    (assert (= (. calls 1) "hello") "executor received params")))

(fn t.test-execute-skips-db-key []
  (setup)
  (let [calls []]
    (effect.reg-fx :db
      (fn [params] (table.insert calls params)))
    (effect.execute {:db {:counter 1} :log "test"})
    (assert (= (length calls) 0) ":db key skipped")))

(fn t.test-execute-unknown-key-warns []
  (setup)
  (effect.execute {:db nil :nonexistent "val"})
  (assert true "unknown key does not crash"))

(fn t.test-replace-executor []
  (setup)
  (let [calls1 []
        calls2 []]
    (effect.reg-fx :test-fx
      (fn [params] (table.insert calls1 params)))
    (effect.reg-fx :test-fx
      (fn [params] (table.insert calls2 params)))
    (effect.execute {:db nil :test-fx "val"})
    (assert (= (length calls1) 0) "old executor not called")
    (assert (= (length calls2) 1) "new executor called")))

;; --- built-in :log ---

(fn t.test-log-effect []
  (setup)
  (effect.execute {:db nil :log "test message"})
  (assert true ":log doesn't crash"))

;; --- built-in :dispatch ---

(fn t.test-dispatch-effect []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.register-globals)
  (dataflow.reg-handler :event/inc
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (effect.execute {:db nil :dispatch [:event/inc]})
  (assert (= (rawget (dataflow._get-raw-db) :counter) 1) ":dispatch triggers handler"))

;; --- timers ---

(fn t.test-dispatch-later-single []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.register-globals)
  (dataflow.reg-handler :event/tick
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (effect.execute {:db nil :dispatch-later {:ms 100 :dispatch [:event/tick]}})
  (assert (= (effect.pending-timers) 1) "timer queued")
  (assert (= (rawget (dataflow._get-raw-db) :counter) 0) "not fired yet")
  (let [now (* (os.clock) 1000)]
    (effect.poll-timers (+ now 200)))
  (assert (= (rawget (dataflow._get-raw-db) :counter) 1) "timer fired")
  (assert (= (effect.pending-timers) 0) "timer removed"))

(fn t.test-dispatch-later-multiple []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.register-globals)
  (dataflow.reg-handler :event/tick
    (fn [db event]
      (dataflow.update db :counter #(+ $1 1))))
  (effect.execute {:db nil :dispatch-later [{:ms 100 :dispatch [:event/tick]}
                                            {:ms 200 :dispatch [:event/tick]}]})
  (assert (= (effect.pending-timers) 2) "two timers queued")
  (let [now (* (os.clock) 1000)]
    (effect.poll-timers (+ now 150))
    (assert (= (rawget (dataflow._get-raw-db) :counter) 1) "first timer fired")
    (assert (= (effect.pending-timers) 1) "one timer remaining")
    (effect.poll-timers (+ now 300))
    (assert (= (rawget (dataflow._get-raw-db) :counter) 2) "second timer fired")
    (assert (= (effect.pending-timers) 0) "no timers remaining")))

(fn t.test-clear-timers []
  (setup)
  (effect.execute {:db nil :dispatch-later {:ms 100 :dispatch [:event/x]}})
  (assert (= (effect.pending-timers) 1) "timer queued")
  (effect.clear-timers)
  (assert (= (effect.pending-timers) 0) "timers cleared"))

(fn t.test-globals-registered []
  (setup)
  (effect.register-globals)
  (assert (= _G.reg_fx effect.reg-fx) "reg_fx global")
  (assert (= _G.redin_poll_timers effect.poll-timers) "poll_timers global"))

;; --- http effect ---

(fn t.test-http-effect-queues-request []
  (setup)
  (dataflow.init {})
  (dataflow.register-globals)
  (let [captured []]
    (set _G.redin_http
      (fn [id url method headers body timeout]
        (table.insert captured {:id id :url url :method method})))
    (effect.execute {:db nil
                     :http {:url "https://example.com/api"
                            :method :get
                            :on-success :event/loaded
                            :on-error :event/failed}})
    (assert (= (length captured) 1) "host function called")
    (assert (= (. captured 1 :url) "https://example.com/api") "url passed")
    (assert (= (. captured 1 :method) "get") "method passed")
    (set _G.redin_http nil)))

(fn t.test-http-response-success []
  (setup)
  (dataflow.init {:result nil})
  (dataflow.register-globals)
  (var req-id nil)
  (set _G.redin_http
    (fn [id url method headers body timeout]
      (set req-id id)))
  (dataflow.reg-handler :event/loaded
    (fn [db event]
      (dataflow.assoc db :result (. event 2))))
  (effect.execute {:db nil
                   :http {:url "https://example.com"
                          :on-success :event/loaded
                          :on-error :event/failed}})
  (assert req-id "request ID was set")
  (effect.handle-http-response
    {:id req-id :status 200 :headers {} :body "ok" :error ""})
  (assert (= (. (rawget (dataflow._get-raw-db) :result) :status) 200) "success dispatched")
  (set _G.redin_http nil))

(fn t.test-http-response-error []
  (setup)
  (dataflow.init {:error-msg nil})
  (dataflow.register-globals)
  (var req-id nil)
  (set _G.redin_http
    (fn [id url method headers body timeout]
      (set req-id id)))
  (dataflow.reg-handler :event/failed
    (fn [db event]
      (dataflow.assoc db :error-msg (. event 2 :error))))
  (effect.execute {:db nil
                   :http {:url "https://example.com"
                          :on-success :event/ok
                          :on-error :event/failed}})
  (effect.handle-http-response
    {:id req-id :status 0 :headers {} :body "" :error "timeout"})
  (assert (= (rawget (dataflow._get-raw-db) :error-msg) "timeout") "error dispatched")
  (set _G.redin_http nil))

(fn t.test-http-response-http-error []
  (setup)
  (dataflow.init {:status nil})
  (dataflow.register-globals)
  (var req-id nil)
  (set _G.redin_http
    (fn [id url method headers body timeout]
      (set req-id id)))
  (dataflow.reg-handler :event/failed
    (fn [db event]
      (dataflow.assoc db :status (. event 2 :status))))
  (effect.execute {:db nil
                   :http {:url "https://example.com"
                          :on-success :event/ok
                          :on-error :event/failed}})
  (effect.handle-http-response
    {:id req-id :status 500 :headers {} :body "server error" :error ""})
  (assert (= (rawget (dataflow._get-raw-db) :status) 500) "500 routed to on-error")
  (set _G.redin_http nil))

t
