;; Test app for image component UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :logo    {:bg [59 66 82] :opacity 0.8}
   :banner  {:bg [76 86 106]}})

(dataflow.init
  {:show-image true})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/toggle
  (fn [db event]
    (update db :show-image (fn [v] (not v)))))

(reg-handler :event/reset
  (fn [db event]
    (assoc db :show-image true)))

(reg-sub :show-image (fn [db] (get db :show-image true)))

(global main_view
  (fn []
    (let [show (subscribe :show-image)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :body} "Image Test"]
       (when show
         [:image {:id :logo :aspect :logo :width 120 :height 40}])
       [:image {:id :banner :aspect :banner :width 300 :height 80}]
       [:image {:id :plain :width 60 :height 60}]
       [:button {:id :toggle-btn :aspect :body :width 100 :height 30
                 :click [:event/toggle]} "Toggle"]])))
