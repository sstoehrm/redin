;; Test app for issue #34: scroll-y on vbox with unsized children.
;; Three "cards" (vboxes without explicit height) inside a scroll-y vbox.
;; Each card holds text plus a button; clicking at distinct Y positions
;; must hit distinct buttons — if cards collapse to the same Y (the bug),
;; all clicks land on the same (last-rendered) card.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [30 30 40] :padding [8 8 8 8]}
   :card    {:bg [60 60 80] :padding [8 8 8 8]}
   :body    {:font-size 14 :color [220 220 220]}
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
      [:vbox {:aspect :surface :width 200 :height 300 :overflow :scroll-y}
       [:vbox {:aspect :card :id :card-1}
        [:text {:aspect :body} "one"]
        [:button {:id :btn-1 :aspect :pick :height 20
                  :click [:event/pick 1]} "pick 1"]]
       [:vbox {:aspect :card :id :card-2}
        [:text {:aspect :body} "two"]
        [:button {:id :btn-2 :aspect :pick :height 20
                  :click [:event/pick 2]} "pick 2"]]
       [:vbox {:aspect :card :id :card-3}
        [:text {:aspect :body} "three"]
        [:button {:id :btn-3 :aspect :pick :height 20
                  :click [:event/pick 3]} "pick 3"]]
       [:text {:aspect :body :id :status} (.. "picked:" (tostring picked))]])))
