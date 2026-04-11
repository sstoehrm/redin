;; Test app for popout component UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :heading {:font-size 24 :color [236 239 244] :weight 1}
   :tooltip {:bg [59 66 82] :border [76 86 106] :border-width 1
             :radius 4 :padding [8 8 8 8]}
   :menu    {:bg [76 86 106] :padding [4 4 4 4]}
   :button  {:bg [76 86 106] :color [236 239 244]
             :radius 6 :padding [6 14 6 14] :font-size 13}})

(dataflow.init
  {:tooltip-open false
   :menu-open false
   :selected ""})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/toggle-tooltip
  (fn [db event]
    (update db :tooltip-open (fn [v] (not v)))))

(reg-handler :event/toggle-menu
  (fn [db event]
    (update db :menu-open (fn [v] (not v)))))

(reg-handler :event/select
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc (assoc db :selected (or ctx "")) :menu-open false))))

(reg-handler :event/reset
  (fn [db event]
    (assoc (assoc (assoc db :tooltip-open false) :menu-open false) :selected "")))

(reg-sub :tooltip-open (fn [db] (get db :tooltip-open false)))
(reg-sub :menu-open (fn [db] (get db :menu-open false)))
(reg-sub :selected (fn [db] (get db :selected "")))

(global main_view
  (fn []
    (let [tooltip-open (subscribe :tooltip-open)
          menu-open (subscribe :menu-open)
          selected (subscribe :selected)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :heading} "Popout Test"]
       [:text {:id :selected-val :aspect :body} (.. "selected:" selected)]
       [:button {:id :tooltip-btn :aspect :button :width 140 :height 36
                 :click [:event/toggle-tooltip]} "Toggle Tooltip"]
       [:button {:id :menu-btn :aspect :button :width 140 :height 36
                 :click [:event/toggle-menu]} "Toggle Menu"]
       (when tooltip-open
         [:popout {:id :tooltip :aspect :tooltip :width 200 :height 60
                   :mode :fixed :x 50 :y 200}
          [:text {:id :tooltip-text :aspect :body} "This is a tooltip"]])
       (when menu-open
         [:popout {:id :menu :aspect :menu :width 150}
          [:vbox {}
           [:button {:id :menu-item-1 :aspect :button :width 140 :height 30
                     :click [:event/select "alpha"]} "Alpha"]
           [:button {:id :menu-item-2 :aspect :button :width 140 :height 30
                     :click [:event/select "beta"]} "Beta"]
           [:button {:id :menu-item-3 :aspect :button :width 140 :height 30
                     :click [:event/select "gamma"]} "Gamma"]]])])))
