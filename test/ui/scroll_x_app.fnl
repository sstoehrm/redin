;; Test app for horizontal scroll. An hbox with overflow scroll-x laying
;; out three fixed-width buttons. Total content width (300) exceeds the
;; container width (250) so the scroll-x path engages (scissor + offset
;; map + scrollbar), but initial scroll_x = 0 keeps the first two
;; buttons fully visible for hit testing.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [30 30 40] :padding [8 8 8 8]}
   :pick    {:bg [100 100 140] :color [240 240 240]
             :radius 3 :padding [4 8 4 8] :font-size 14}})

(dataflow.init {:picked 0})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/pick
  (fn [db event]
    (let [which (. event 2)]
      (assoc db :picked which))))

(reg-sub :picked (fn [db] (get db :picked 0)))

(global main_view
  (fn []
    (let [picked (subscribe :picked)]
      [:vbox {:aspect :surface :width 400 :height 200}
       [:hbox {:id :track :aspect :surface :width 250 :height 50
               :overflow :scroll-x}
        [:button {:id :btn-1 :aspect :pick :width 100 :height 30
                  :click [:event/pick 1]} "one"]
        [:button {:id :btn-2 :aspect :pick :width 100 :height 30
                  :click [:event/pick 2]} "two"]
        [:button {:id :btn-3 :aspect :pick :width 100 :height 30
                  :click [:event/pick 3]} "three"]]
       [:text {:id :status :aspect :pick} (.. "picked:" (tostring picked))]])))
