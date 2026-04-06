;; Minimal app for smoke testing the UI test framework
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:heading {:font-size 24 :color [236 239 244] :weight 1}
   :body    {:font-size 14 :color [216 222 233]}
   :button  {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [6 14 6 14]}
   "button#hover" {:bg [94 105 126]}})

(dataflow.init {:counter 0 :message "hello"})

(reg-handler :event/inc
  (fn [db event]
    (update db :counter #(+ $1 1))))

(reg-handler :event/set-message
  (fn [db event]
    (assoc db :message (. event 2))))

(reg-handler :event/reset
  (fn [db event]
    (assoc (assoc db :counter 0) :message "hello")))

(reg-sub :sub/counter
  (fn [db] (get db :counter)))

(reg-sub :sub/message
  (fn [db] (get db :message)))

(global main_view
  (fn []
    (let [count (subscribe :sub/counter)
          msg (subscribe :sub/message)]
      {:frame
       [:vbox {}
        [:text {:id :counter :aspect :heading} (tostring count)]
        [:text {:id :message :aspect :body} msg]
        [:button {:id :inc-btn :aspect :button
                  :click [:event/inc]}
                 "+1"]]
       :bind {}})))
