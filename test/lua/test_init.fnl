(local t {})

(fn t.test-init-loads-modules []
  (let [init (require :init)]
    (assert _G.get "get global exists")
    (assert _G.assoc "assoc global exists")
    (assert _G.dispatch "dispatch global exists")
    (assert _G.subscribe "subscribe global exists")
    (assert _G.reg_handler "reg_handler global exists")
    (assert _G.reg_sub "reg_sub global exists")
    (assert _G.reg_fx "reg_fx global exists")
    (assert _G.redin_poll_timers "poll_timers global exists")))

(fn t.test-init-wires-effect-handler []
  (let [init (require :init)]
    (let [calls []]
      (_G.reg_fx "test-init-fx"
        (fn [params] (table.insert calls params)))
      (let [dataflow (require :dataflow)]
        (dataflow.init {:x 0})
        (_G.reg_handler "event/test-fx"
          (fn [db event]
            {:db (_G.assoc db :x 1)
             :test-init-fx "it works"}))
        (_G.dispatch ["event/test-fx"])
        (assert (= (length calls) 1) "effect handler wired by init")
        (assert (= (. calls 1) "it works") "effect received params")))))

(fn t.test-bridge-globals-exist []
  (let [init (require :init)]
    (assert _G.redin_render_tick "redin_render_tick global exists")
    (assert _G.redin_events "redin_events global exists")
    (assert _G.redin_poll_timers "redin_poll_timers global exists")))

t
