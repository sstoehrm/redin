;; Minimal app for profile endpoint integration test.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:body {:font-size 14 :color [216 222 233]}})

(dataflow.init {})

(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {}
     [:text {:aspect :body} "profile test"]]))
