;; dataflow.fnl -- Core dataflow engine.
;; State management with path tracking for subscription invalidation.

(local M {})

(var raw-db {})
(var handlers {})
(var subscriptions {})
(var changed-paths [])
(var tracking nil)
(var effect-handler nil)

;; ===== Path utilities =====

(fn paths-overlap? [a b]
  (let [len-a (length a)
        len-b (length b)
        min-len (math.min len-a len-b)]
    (var overlap true)
    (for [i 1 min-len]
      (when (~= (. a i) (. b i))
        (set overlap false)))
    overlap))

;; ===== Tracking =====

(fn track-read [path]
  (when tracking
    (table.insert tracking path)))

(fn record-change [path]
  (table.insert changed-paths path))

;; ===== Public API: init =====

(fn M.init [?initial-db]
  (set raw-db (or ?initial-db {}))
  (set changed-paths [])
  (set tracking nil)
  raw-db)

;; ===== Public API: reads =====

(fn M.get [db key ?default]
  (track-read [key])
  (let [v (rawget db key)]
    (if (= v nil) ?default v)))

(fn M.get-in [db path ?default]
  (track-read path)
  (var v db)
  (var missing false)
  (each [_ k (ipairs path)]
    (if (or missing (= v nil))
      (set missing true)
      (set v (rawget v k))))
  (if (or missing (= v nil)) ?default v))

;; ===== Public API: writes =====

(fn M.assoc [db key value]
  (record-change [key])
  (rawset db key value)
  db)

(fn M.assoc-in [db path value]
  (record-change path)
  (var t db)
  (for [i 1 (- (length path) 1)]
    (let [k (. path i)
          next-val (rawget t k)]
      (if (= next-val nil)
        (let [new-tbl {}]
          (rawset t k new-tbl)
          (set t new-tbl))
        (set t next-val))))
  (rawset t (. path (length path)) value)
  db)

(fn M.update [db key f]
  (record-change [key])
  (rawset db key (f (rawget db key)))
  db)

(fn M.update-in [db path f]
  (record-change path)
  (var t db)
  (for [i 1 (- (length path) 1)]
    (let [k (. path i)
          next-val (rawget t k)]
      (if (= next-val nil)
        (let [new-tbl {}]
          (rawset t k new-tbl)
          (set t new-tbl))
        (set t next-val))))
  (let [k (. path (length path))]
    (rawset t k (f (rawget t k))))
  db)

(fn M.dissoc [db key]
  (record-change [key])
  (rawset db key nil)
  db)

(fn M.dissoc-in [db path]
  (record-change path)
  (var t db)
  (var bail false)
  (for [i 1 (- (length path) 1)]
    (when (not bail)
      (let [k (. path i)
            next-val (rawget t k)]
        (if (= next-val nil)
          (set bail true)
          (set t next-val)))))
  (when (not bail)
    (rawset t (. path (length path)) nil))
  db)

;; ===== Public API: handlers =====

(fn M.reg-handler [key handler-fn]
  (tset handlers key handler-fn))

(fn M.dispatch [event]
  (let [key (. event 1)
        handler-fn (. handlers key)]
    (assert handler-fn (.. "No handler registered for: " (tostring key)))
    (let [saved-tracking tracking]
      (set tracking nil)
      (let [result (handler-fn raw-db event)]
        (set tracking saved-tracking)
        (when (and (~= result nil) (~= result raw-db)
                   (= (type result) "table") (~= (. result :db) nil))
          (when effect-handler
            (effect-handler result)))))))

;; ===== Public API: change detection =====

(fn M.has-changes? []
  (> (length changed-paths) 0))

;; ===== Public API: subscriptions =====

(fn M.reg-sub [key query-fn]
  (tset subscriptions key {:fn query-fn :deps [] :cached nil :dirty true}))

(fn M.subscribe [key]
  (let [sub (. subscriptions key)]
    (if (= sub nil)
      (do
        (print (.. "Warning: no subscription registered for: " (tostring key)))
        nil)
      (do
        (when sub.dirty
          (set tracking [])
          (let [value (sub.fn raw-db)]
            (set sub.deps tracking)
            (set tracking nil)
            (set sub.cached value)
            (set sub.dirty false)))
        sub.cached))))

;; ===== Public API: flush =====

(fn M.flush []
  (when (M.has-changes?)
    (each [_ sub (pairs subscriptions)]
      (when (not sub.dirty)
        (var invalidated false)
        (each [_ dep (ipairs sub.deps)]
          (when (not invalidated)
            (each [_ changed (ipairs changed-paths)]
              (when (and (not invalidated) (paths-overlap? dep changed))
                (set sub.dirty true)
                (set invalidated true)))))))
    (set changed-paths [])))

(fn M.set-effect-handler [handler]
  (set effect-handler handler))

;; ===== Reset =====

(fn M.reset []
  (set raw-db {})
  (set handlers {})
  (set subscriptions {})
  (set changed-paths [])
  (set tracking nil)
  (set effect-handler nil))

;; ===== Global registration =====

(fn M.register-globals []
  (set _G.get M.get)
  (tset _G "get-in" M.get-in)
  (set _G.assoc M.assoc)
  (tset _G "assoc-in" M.assoc-in)
  (set _G.update M.update)
  (tset _G "update-in" M.update-in)
  (set _G.dissoc M.dissoc)
  (tset _G "dissoc-in" M.dissoc-in)
  (tset _G "reg-handler" M.reg-handler)
  (set _G.dispatch M.dispatch)
  (tset _G "reg-sub" M.reg-sub)
  (set _G.subscribe M.subscribe)
  (set _G.get_in M.get-in)
  (set _G.assoc_in M.assoc-in)
  (set _G.update_in M.update-in)
  (set _G.dissoc_in M.dissoc-in)
  (set _G.reg_handler M.reg-handler)
  (set _G.redin_dispatch M.dispatch)
  (set _G.reg_sub M.reg-sub)
  (set _G.redin_subscribe M.subscribe)
  (tset _G "__fnl_global__get_2din" M.get-in)
  (tset _G "__fnl_global__assoc_2din" M.assoc-in)
  (tset _G "__fnl_global__update_2din" M.update-in)
  (tset _G "__fnl_global__dissoc_2din" M.dissoc-in)
  (tset _G "__fnl_global__reg_2dhandler" M.reg-handler)
  (tset _G "__fnl_global__reg_2dsub" M.reg-sub))

(fn M.get-state [] raw-db)

(fn M._get-changed-paths [] changed-paths)
(fn M._get-raw-db [] raw-db)

M
