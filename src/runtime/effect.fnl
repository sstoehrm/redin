;; effect.fnl -- Declarative side effects.
;; Registry of effect executors, timer queue, built-in effects.

(local M {})

;; F4 (#204): upper bound on outstanding dispatch-later timers. A handler
;; that schedules a timer every frame grows timer-queue without bound and
;; slowly exhausts memory with no useful diagnostic. Not a security boundary
;; — the app author controls their handlers — but an easy footgun. At the cap
;; we drop new timers with a warning rather than grow forever. 10,000 is far
;; above any legitimate fan-out of pending timers.
(local MAX-TIMER-QUEUE 10000)
(set M.MAX_TIMER_QUEUE MAX-TIMER-QUEUE)

(var executors {})
(var timer-queue [])
(var pending-http {})
(var next-http-id 0)
(var pending-shell {})
(var next-shell-id 0)

;; ===== Registry =====

(fn M.reg-fx [key executor-fn]
  (tset executors key executor-fn))

;; Enqueue a timer unless the queue is at its cap, in which case drop it
;; with a warning. Centralised so both the single- and list-form of
;; :dispatch-later share the bound (F4, #204).
(fn enqueue-timer [at event]
  (if (< (length timer-queue) MAX-TIMER-QUEUE)
    (table.insert timer-queue {:at at :event event})
    (print (.. "Warning: timer queue at cap (" MAX-TIMER-QUEUE
               "); dropping dispatch-later event "
               (tostring (and (= (type event) "table") (. event 1)))))))

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

;; ===== Shell response routing =====

(fn M.handle-shell-response [response]
  (let [req-info (. pending-shell response.id)]
    (when req-info
      (tset pending-shell response.id nil)
      (let [dispatch-fn (or _G.dispatch _G.redin_dispatch)]
        (when dispatch-fn
          (if (= (. response :exit-code) 0)
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
      ;; Wall-clock ms when the bridge is present, falling back to
      ;; CPU time for pure-Lua tests. The host polls with wall-clock,
      ;; so the two clocks must agree in production. See issue #146.
      (let [now (if (and _G.redin _G.redin.now)
                  (* (_G.redin.now) 1000)
                  (* (os.clock) 1000))]
        (if (and (= (type params) "table") (. params :ms))
          (enqueue-timer (+ now params.ms) params.dispatch)
          (each [_ timer-spec (ipairs params)]
            (enqueue-timer (+ now timer-spec.ms) timer-spec.dispatch))))))
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
          (_G.redin_http id url method headers body timeout)))))
  (M.reg-fx :shell
    (fn [params]
      (set next-shell-id (+ next-shell-id 1))
      (let [id (tostring next-shell-id)
            cmd (or params.cmd [])
            stdin (or params.stdin "")
            max-output (or params.max-output 16)
            timeout (or params.timeout 30000)]
        (tset pending-shell id {:on-success params.on-success
                                :on-error params.on-error})
        (when _G.redin_shell
          (_G.redin_shell id cmd stdin max-output timeout))))))

(register-builtins)

;; ===== Reset =====

(fn M.reset []
  (set executors {})
  (set timer-queue [])
  (set pending-http {})
  (set next-http-id 0)
  (set pending-shell {})
  (set next-shell-id 0)
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
