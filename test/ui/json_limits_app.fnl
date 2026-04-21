;; Exercises JSON codec depth + cycle limits from #46.
;; - /state is exposed so the encoder runs on our db.
;; - :event/install-cycle replaces the db with a table that points
;;   back to itself, which would previously blow the host stack.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:body {:font-size 14 :color [216 222 233]}})

(dataflow.init {:counter 0})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/install-cycle
  (fn [db _]
    (set db.self db)
    db))

(reg-handler :event/reset
  (fn [db _] (dataflow.set-db {:counter 0}) {:counter 0}))

(reg-sub :sub/counter (fn [db] (or db.counter 0)))

(global main_view
  (fn []
    [:vbox {}
     [:text {:aspect :body} (.. "counter=" (tostring (subscribe :sub/counter)))]]))
