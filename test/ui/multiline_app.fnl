;; Test app for multiline text and input
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :input   {:bg [59 66 82] :color [236 239 244]
             :border [76 86 106] :border-width 1
             :radius 4 :padding [8 12 8 12] :font-size 14}
   :input#focus {:border [136 192 208]}})

(dataflow.init
  {:input-value "Line one\nLine two\nLine three"
   :static-text "Word wrap test: The quick brown fox jumps over the lazy dog. This text should wrap at the container boundary."
   :newline-text "First\nSecond\nThird"})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/input-change
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))))

(reg-handler :event/reset
  (fn [db event]
    (assoc db :input-value "Line one\nLine two\nLine three")))

(reg-sub :input-value (fn [db] (get db :input-value "")))
(reg-sub :static-text (fn [db] (get db :static-text "")))
(reg-sub :newline-text (fn [db] (get db :newline-text "")))

(global main_view
  (fn []
    (let [input-val (subscribe :input-value)
          static (subscribe :static-text)
          newline (subscribe :newline-text)]
      [:vbox {:aspect :surface}
       [:text {:id :wrap-text :aspect :body :width 200 :height 80} static]
       [:text {:id :newline-text :aspect :body :width 200 :height 60} newline]
       [:text {:id :scroll-text :aspect :body :width 200 :height 40 :overflow :scroll-y} static]
       [:input {:id :test-input :aspect :input :width 250 :height 80
                :value input-val
                :change [:event/input-change]}]
       [:text {:id :current-value :aspect :body :height 60} (.. "value:" input-val)]])))
