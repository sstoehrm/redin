;; Test app for modal component UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :heading {:font-size 24 :color [236 239 244] :weight 1}
   :overlay {:bg [0 0 0] :opacity 0.5}
   :dialog  {:bg [59 66 82] :padding [24 24 24 24]}
   :button  {:bg [76 86 106] :color [236 239 244]
             :radius 6 :padding [6 14 6 14] :font-size 13}
   :button#hover {:bg [94 105 126]}})

(dataflow.init
  {:modal-open false
   :counter 0
   :last-action ""})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/open-modal
  (fn [db event]
    (assoc db :modal-open true)))

(reg-handler :event/close-modal
  (fn [db event]
    (assoc db :modal-open false)))

(reg-handler :event/confirm
  (fn [db event]
    (assoc (assoc db :modal-open false) :last-action "confirmed")))

(reg-handler :event/cancel
  (fn [db event]
    (assoc (assoc db :modal-open false) :last-action "cancelled")))

(reg-handler :event/inc
  (fn [db event]
    (update db :counter (fn [c] (+ c 1)))))

(reg-handler :event/reset
  (fn [db event]
    (assoc (assoc (assoc db :modal-open false) :counter 0) :last-action "")))

(reg-sub :modal-open (fn [db] (get db :modal-open false)))
(reg-sub :counter (fn [db] (get db :counter 0)))
(reg-sub :last-action (fn [db] (get db :last-action "")))

(global main_view
  (fn []
    (let [modal-open (subscribe :modal-open)
          counter (subscribe :counter)
          last-action (subscribe :last-action)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :heading} "Modal Test"]
       [:text {:id :counter :aspect :body} (.. "count:" (tostring counter))]
       [:text {:id :last-action :aspect :body} (.. "action:" last-action)]
       [:button {:id :open-btn :aspect :button :width 120 :height 36
                 :click [:event/open-modal]} "Open Modal"]
       [:button {:id :bg-btn :aspect :button :width 120 :height 36
                 :click [:event/inc]} "+1"]
       (when modal-open
         [:modal {:aspect :overlay}
          [:vbox {:aspect :dialog :width 300 :height 200}
           [:text {:id :modal-title :aspect :heading} "Confirm Action"]
           [:text {:id :modal-body :aspect :body} "Are you sure?"]
           [:hbox {}
            [:button {:id :cancel-btn :aspect :button :width 100 :height 36
                      :click [:event/cancel]} "Cancel"]
            [:button {:id :confirm-btn :aspect :button :width 100 :height 36
                      :click [:event/confirm]} "Confirm"]]]])])))
