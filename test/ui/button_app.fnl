;; Minimal app for testing button click dispatch
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:button {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [6 14 6 14]}
   :body   {:font-size 14 :color [216 222 233]}})

(dataflow.init {:counter 0 :last-action "none"})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/inc
  (fn [db event]
    (-> db
        (update :counter #(+ $1 1))
        (assoc :last-action "inc"))))

(reg-handler :event/dec
  (fn [db event]
    (-> db
        (update :counter #(- $1 1))
        (assoc :last-action "dec"))))

(reg-handler :event/reset
  (fn [db event]
    (assoc (assoc db :counter 0) :last-action "reset")))

(reg-sub :sub/counter
  (fn [db] (get db :counter)))

(reg-sub :sub/last-action
  (fn [db] (get db :last-action)))

(global main_view
  (fn []
    (let [count (subscribe :sub/counter)
          action (subscribe :sub/last-action)]
      {:frame
       [:vbox {}
        [:text {:id :counter :aspect :body} (tostring count)]
        [:text {:id :last-action :aspect :body} action]
        [:button {:id :inc-btn :aspect :button
                  :click [:event/inc]
                  :width 100 :height 36}
                 "+1"]
        [:button {:id :dec-btn :aspect :button
                  :click [:event/dec]
                  :width 100 :height 36}
                 "-1"]
        [:button {:id :reset-btn :aspect :button
                  :click [:event/reset]
                  :width 100 :height 36}
                 "Reset"]]
       :bind {}})))
