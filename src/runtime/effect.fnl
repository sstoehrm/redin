;; effect.fnl -- Declarative side effects.
;; Registry of effect executors, timer queue, built-in effects.

(local M {})

(var executors {})
(var timer-queue [])
(var pending-http {})
(var next-http-id 0)

;; ===== Registry =====

(fn M.reg-fx [key executor-fn]
  (tset executors key executor-fn))

;; ===== Execution =====

(fn M.execute [fx-map]
  (each [key value (pairs fx-map)]
    (when (~= key :db)
      (let [executor (. executors key)]
        (if executor
          (executor value)
          (print (.. "Warning: no effect executor for: " (tostring key))))))))

;; ===== Timer queue =====

(fn M.poll-timers [now-ms]
  (var fired 0)
  (var i 1)
  (while (<= i (length timer-queue))
    (let [timer (. timer-queue i)]
      (if (<= timer.at now-ms)
        (do
          (let [dispatch-fn (. executors :dispatch)]
            (when dispatch-fn
              (dispatch-fn timer.event)))
          (table.remove timer-queue i)
          (set fired (+ fired 1)))
        (set i (+ i 1)))))
  fired)

(fn M.pending-timers []
  (length timer-queue))

(fn M.clear-timers []
  (set timer-queue []))

;; ===== HTTP response routing =====

(fn M.handle-http-response [response]
  (let [req-info (. pending-http response.id)]
    (when req-info
      (tset pending-http response.id nil)
      (let [dispatch-fn (or _G.dispatch _G.redin_dispatch)]
        (when dispatch-fn
          (if (and (>= response.status 200) (<= response.status 299))
            (dispatch-fn [req-info.on-success response])
            (dispatch-fn [req-info.on-error response])))))))

;; ===== Built-in effects =====

(fn register-builtins []
  (M.reg-fx :log
    (fn [value] (print (tostring value))))
  (M.reg-fx :dispatch
    (fn [event]
      (let [dispatch-fn (or _G.dispatch _G.redin_dispatch)]
        (when dispatch-fn
          (dispatch-fn event)))))
  (M.reg-fx :dispatch-later
    (fn [params]
      (let [now (* (os.clock) 1000)]
        (if (and (= (type params) "table") (. params :ms))
          (table.insert timer-queue {:at (+ now params.ms) :event params.dispatch})
          (each [_ timer-spec (ipairs params)]
            (table.insert timer-queue {:at (+ now timer-spec.ms) :event timer-spec.dispatch}))))))
  (M.reg-fx :http
    (fn [params]
      (set next-http-id (+ next-http-id 1))
      (let [id (tostring next-http-id)
            url (or params.url "")
            method (or params.method :get)
            headers (or params.headers {})
            body (or params.body "")
            timeout (or params.timeout 30000)]
        (tset pending-http id {:on-success params.on-success
                               :on-error params.on-error})
        (when _G.redin_http
          (_G.redin_http id url method headers body timeout))))))

(register-builtins)

;; ===== Reset =====

(fn M.reset []
  (set executors {})
  (set timer-queue [])
  (set pending-http {})
  (set next-http-id 0)
  (register-builtins))

;; ===== Global registration =====

(fn M.register-globals []
  (tset _G "reg-fx" M.reg-fx)
  (set _G.reg_fx M.reg-fx)
  (set _G.redin_poll_timers M.poll-timers)
  (set _G.redin_pending_timers M.pending-timers)
  (set _G.redin_clear_timers M.clear-timers)
  (tset _G "__fnl_global__reg_2dfx" M.reg-fx))

M
