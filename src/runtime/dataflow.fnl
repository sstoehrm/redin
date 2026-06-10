;; dataflow.fnl -- Core dataflow engine.
;; State management with path tracking for subscription invalidation.

(local M {})

(var raw-db {})
(var handlers {})
(var subscriptions {})
(var changed-paths [])
(var tracking nil)
(var effect-handler nil)

;; F4 (#204): cap on synchronous dispatch recursion. A handler that returns
;; {:db db :dispatch [...]} re-enters dispatch through the effect handler; one
;; that self-dispatches unconditionally would otherwise recurse until the Lua
;; stack overflows with no useful diagnostic. Not a security boundary — the
;; app author controls their handlers — but an easy footgun. 64 is far deeper
;; than any legitimate dispatch chain.
(local MAX-DISPATCH-DEPTH 64)
(set M.MAX_DISPATCH_DEPTH MAX-DISPATCH-DEPTH)
(var dispatch-depth 0)

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
    (if (or missing (= v nil) (~= (type v) "table"))
      ;; A non-table intermediate (scalar where the path expects nesting)
      ;; reads as missing, like nil — rawget on it would error.
      (set missing true)
      (set v (rawget v k))))
  (if (or missing (= v nil)) ?default v))

;; ===== Public API: writes =====

(fn M.assoc [db key value]
  (record-change [key])
  (rawset db key value)
  db)

;; Walk to the parent of the last path key, creating intermediate tables
;; for nil slots. A non-table intermediate raises a clear error naming
;; the operation and key (rawset's own "table expected" names neither);
;; Clojure's assoc-in throws on the same shape mismatch. Shared by
;; assoc-in and update-in.
(fn walk-to-parent [op t path]
  (var cur t)
  (for [i 1 (- (length path) 1)]
    (let [k (. path i)
          next-val (rawget cur k)]
      (if (= next-val nil)
        (let [new-tbl {}]
          (rawset cur k new-tbl)
          (set cur new-tbl))
        (= (type next-val) "table")
        (set cur next-val)
        (error (.. op ": path crosses non-table value at key '"
                   (tostring k) "'")))))
  cur)

(fn M.assoc-in [db path value]
  (let [parent (walk-to-parent "assoc-in" db path)]
    (record-change path)
    (rawset parent (. path (length path)) value))
  db)

(fn M.update [db key f]
  (record-change [key])
  (rawset db key (f (rawget db key)))
  db)

(fn M.update-in [db path f]
  (let [parent (walk-to-parent "update-in" db path)
        k (. path (length path))]
    (record-change path)
    (rawset parent k (f (rawget parent k))))
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
        ;; A nil or non-table intermediate means there is nothing at the
        ;; path to remove — deleting from a missing nest is a no-op.
        (if (or (= next-val nil) (~= (type next-val) "table"))
          (set bail true)
          (set t next-val)))))
  (when (not bail)
    (rawset t (. path (length path)) nil))
  db)

;; ===== Public API: handlers =====

(fn M.reg-handler [key handler-fn]
  (tset handlers key handler-fn))

(fn do-dispatch [event]
  (let [key (. event 1)
        handler-fn (. handlers key)]
    (assert handler-fn (.. "No handler registered for: " (tostring key)))
    (let [saved-tracking tracking]
      (set tracking nil)
      (let [result (handler-fn raw-db event)]
        (set tracking saved-tracking)
        ;; A table result that isn't the db accessor is an fx map. :db
        ;; normally holds the accessor (== raw-db, already mutated in
        ;; place); a handler that built a fresh table instead gets it
        ;; installed as the new state, with a root-path change recorded
        ;; so every subscription recomputes. An fx map with no :db at
        ;; all is effects-only (e.g. {:dispatch-later ...}).
        (when (and (~= result nil) (~= result raw-db)
                   (= (type result) "table"))
          (let [new-db (. result :db)]
            (when (and (~= new-db nil) (~= new-db raw-db))
              (if (= (type new-db) "table")
                (do
                  (set raw-db new-db)
                  (record-change []))
                (print (.. "Warning: :db in fx map is not a table; "
                           "ignoring (event " (tostring key) ")")))))
          (when effect-handler
            (effect-handler result)))))))

(fn M.dispatch [event]
  (if (>= dispatch-depth MAX-DISPATCH-DEPTH)
    ;; Runaway synchronous recursion — drop the event with a diagnostic
    ;; instead of overflowing the Lua stack.
    (print (.. "Warning: dispatch depth exceeded " MAX-DISPATCH-DEPTH
               " (runaway :dispatch recursion?); dropping event "
               (tostring (. event 1))))
    (do
      (set dispatch-depth (+ dispatch-depth 1))
      ;; pcall so the depth counter is restored even when a handler errors;
      ;; otherwise one errored dispatch leaves the counter elevated and
      ;; eventually wedges all dispatching. Re-raise with level 0 to preserve
      ;; the original message (e.g. the "No handler" assert) verbatim.
      (let [(ok? err) (pcall do-dispatch event)]
        (set dispatch-depth (- dispatch-depth 1))
        (when (not ok?) (error err 0))))))

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
          ;; #178: save/restore `tracking` (like M.dispatch) so a query fn
          ;; that itself calls subscribe doesn't clobber it to nil, which
          ;; would drop this sub's deps and later (ipairs nil) in flush.
          ;; pcall so the restore also happens when the query fn errors —
          ;; an orphaned tracking table would otherwise collect every
          ;; later top-level read forever. Re-raise with level 0 to keep
          ;; the original message verbatim (matches M.dispatch).
          (let [saved-tracking tracking]
            (set tracking [])
            (let [(ok? value) (pcall sub.fn raw-db)]
              (if ok?
                (do
                  (set sub.deps tracking)
                  (set tracking saved-tracking)
                  (set sub.cached value)
                  (set sub.dirty false))
                (do
                  (set tracking saved-tracking)
                  (error value 0))))))
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
  (set effect-handler nil)
  (set dispatch-depth 0))

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
(fn M._get-tracking [] tracking)

M
