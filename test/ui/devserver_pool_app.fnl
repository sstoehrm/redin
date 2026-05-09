;; Minimal app for the dev-server handler-pool test (#129 H8).
;; The test only exercises HTTP behaviour, so the app just needs a
;; valid frame and a non-empty state.
(local dataflow (require :dataflow))

(dataflow.init {:counter 0})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-sub :sub/counter
  (fn [db] (get db :counter)))

(global main_view
  (fn []
    [:vbox {}
      [:text {} "devserver-pool app"]]))
