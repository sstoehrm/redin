(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 16 :color [236 239 244]
             :selection [255 220 0 120]}
   :locked  {:font-size 16 :color [180 180 180]}
   :input   {:bg [59 66 82] :color [236 239 244]
             :border [76 86 106] :border-width 1
             :radius 4 :padding [8 12 8 12] :font-size 14}})

(dataflow.init {:input-value "preset"})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/input-change
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))))

(global main_view
  (fn []
    [:vbox {:aspect :surface :layout :top_left}
     [:text {:aspect :body :id :para}
      "the quick brown fox jumps over the lazy dog"]
     [:text {:aspect :locked :id :locked-text :selectable false}
      "this paragraph is not selectable"]
     [:input {:aspect :input :id :probe-input :value (subscribe :input-value)
              :change [:event/input-change]}]]))
