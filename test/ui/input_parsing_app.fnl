;; Test app for dev-server input-parsing hardening (#49).
;; - Expose state for /state/<path> tests, including a table with an
;;   __index metatable that would execute Lua if the endpoint still
;;   went through metamethods.
;; - Expose state containing a string with surrogate-pair content so
;;   /state round-tripping through JSON stays correct.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:body {:font-size 14 :color [216 222 233]}})

(dataflow.init {:plain {:leaf "ok"}
                :tripped false})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/install-metatable
  ;; Put an __index metatable on db.plain. If /state/<path> routes
  ;; through lua_getfield, reading plain.absent would call __index
  ;; and set db.tripped=true. Under lua_rawget, it must NOT.
  (fn [db _]
    (let [mt {:__index (fn [t k] (set db.tripped true) "tripped")}]
      (setmetatable db.plain mt))
    db))

(reg-handler :event/reset
  (fn [db _] (setmetatable db.plain nil) (set db.tripped false) db))

(reg-sub :sub/tripped (fn [db] db.tripped))

(global main_view
  (fn []
    [:vbox {}
     [:text {:aspect :body} (.. "tripped=" (tostring (subscribe :sub/tripped)))]]))
