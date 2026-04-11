;; view.fnl -- View runner.
;; Orchestrates render ticks: flush subs, call view, flatten, push.

(local dataflow (require :dataflow))
(local frame (require :frame))

(local M {})

(var last-push nil)
(var has-rendered false)

;; ===== Render tick =====

(fn M.render-tick []
  (when (or (not has-rendered) (dataflow.has-changes?))
    (dataflow.flush)
    (let [view-fn _G.main_view]
      (when view-fn
        (let [result (view-fn)]
          (when result
            (let [flattened (frame.flatten result)]
              (set last-push flattened)
              (let [redin-tbl (rawget _G :redin)]
                (when (and redin-tbl (rawget redin-tbl :push))
                  ((rawget redin-tbl :push) flattened))))))))
    (set has-rendered true)))

;; ===== Event delivery =====

(fn M.deliver-events [events]
  (each [_ event (ipairs events)]
    (let [event-type (. event 1)]
      (if
        (= event-type :resize) nil
        (or (= event-type :click) (= event-type :hover)
            (= event-type :key) (= event-type :char)) nil

        ;; Dispatch wrapper: unwrap and dispatch inner event
        (= event-type :dispatch)
        (dataflow.dispatch (. event 2))

        ;; HTTP response from host
        (= event-type :http-response)
        (let [effect-mod (require :effect)]
          (effect-mod.handle-http-response (. event 2)))

        ;; Default: resolved event, dispatch directly
        (dataflow.dispatch event)))))

;; ===== Accessors =====

(fn M.get-last-push []
  last-push)

;; ===== Reset =====

(fn M.reset []
  (set last-push nil)
  (set has-rendered false))

M
