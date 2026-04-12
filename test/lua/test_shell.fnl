(local effect (require :effect))
(local dataflow (require :dataflow))

(local t {})

(fn setup []
  (effect.reset)
  (dataflow.reset))

;; --- shell effect registration ---

(fn t.test-shell-effect-queues-request []
  (setup)
  (let [calls []]
    (set _G.redin_shell
      (fn [id cmd stdin]
        (table.insert calls {:id id :cmd cmd :stdin stdin})))
    (effect.execute {:db nil
                     :shell {:cmd ["echo" "hello"]
                             :stdin ""
                             :on-success :event/done
                             :on-error :event/fail}})
    (set _G.redin_shell nil)
    (assert (= (length calls) 1) "shell request queued")
    (let [call (. calls 1)]
      (assert (= (type call.id) "string") "id is string")
      (assert (= (. call.cmd 1) "echo") "first cmd arg")
      (assert (= (. call.cmd 2) "hello") "second cmd arg"))))

(fn t.test-shell-effect-with-stdin []
  (setup)
  (let [calls []]
    (set _G.redin_shell
      (fn [id cmd stdin]
        (table.insert calls {:id id :stdin stdin})))
    (effect.execute {:db nil
                     :shell {:cmd ["cat"]
                             :stdin "input data"
                             :on-success :event/done
                             :on-error :event/fail}})
    (set _G.redin_shell nil)
    (assert (= (. (. calls 1) :stdin) "input data") "stdin passed")))

;; --- shell response routing ---

(fn t.test-shell-response-success []
  (setup)
  (let [dispatched []]
    (set _G.dispatch (fn [event] (table.insert dispatched event)))
    ;; Simulate: queue a shell request, then deliver a success response
    (let [calls []]
      (set _G.redin_shell (fn [id cmd stdin] (table.insert calls {:id id})))
      (effect.execute {:db nil
                       :shell {:cmd ["echo"]
                               :on-success :event/done
                               :on-error :event/fail}})
      (let [id (. (. calls 1) :id)]
        (set _G.redin_shell nil)
        (effect.handle-shell-response {:id id :stdout "hello\n" :stderr "" :exit-code 0})
        (assert (= (length dispatched) 1) "one event dispatched")
        (assert (= (. (. dispatched 1) 1) :event/done) "success event")
        (assert (= (. (. dispatched 1) 2 :stdout) "hello\n") "stdout passed")))
    (set _G.dispatch nil)))

(fn t.test-shell-response-error []
  (setup)
  (let [dispatched []]
    (set _G.dispatch (fn [event] (table.insert dispatched event)))
    (let [calls []]
      (set _G.redin_shell (fn [id cmd stdin] (table.insert calls {:id id})))
      (effect.execute {:db nil
                       :shell {:cmd ["false"]
                               :on-success :event/done
                               :on-error :event/fail}})
      (let [id (. (. calls 1) :id)]
        (set _G.redin_shell nil)
        (effect.handle-shell-response {:id id :stdout "" :stderr "error\n" :exit-code 1})
        (assert (= (length dispatched) 1) "one event dispatched")
        (assert (= (. (. dispatched 1) 1) :event/fail) "error event")
        (assert (= (. (. dispatched 1) 2 :exit-code) 1) "exit code passed")))
    (set _G.dispatch nil)))

(fn t.test-shell-response-clears-pending []
  (setup)
  (let [dispatched []]
    (set _G.dispatch (fn [event] (table.insert dispatched event)))
    (let [calls []]
      (set _G.redin_shell (fn [id cmd stdin] (table.insert calls {:id id})))
      (effect.execute {:db nil
                       :shell {:cmd ["echo"]
                               :on-success :event/done
                               :on-error :event/fail}})
      (let [id (. (. calls 1) :id)]
        (set _G.redin_shell nil)
        (effect.handle-shell-response {:id id :stdout "" :stderr "" :exit-code 0})
        ;; Second delivery should be ignored (pending cleared)
        (effect.handle-shell-response {:id id :stdout "" :stderr "" :exit-code 0})
        (assert (= (length dispatched) 1) "only one dispatch, pending cleared")))
    (set _G.dispatch nil)))

t
