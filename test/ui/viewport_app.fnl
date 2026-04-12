;; Minimal app for testing viewport positioning on stack
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [8 8 8 8]}
   :body    {:font-size 14 :color [216 222 233]}
   :button  {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [6 14 6 14]}})

(dataflow.init {:counter 0})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/inc
  (fn [db event]
    (update db :counter #(+ $1 1))))

(reg-handler :event/reset
  (fn [db event]
    (assoc db :counter 0)))

(reg-sub :sub/counter
  (fn [db] (get db :counter)))

(global main_view
  (fn []
    (let [count (subscribe :sub/counter)]
      [:stack {:viewport [[:top_left 0 0 :full :full]
                          [:top_left :1_2 0 :1_2 42]]}
       [:vbox {:id :bg-layer :aspect :surface}
        [:text {:id :title :aspect :body} "Background"]]
       [:hbox {:id :overlay}
        [:text {:id :counter :aspect :body} (tostring count)]
        [:button {:id :inc-btn :aspect :button
                  :click [:event/inc]
                  :width 80 :height 36}
                 "+1"]]])))
