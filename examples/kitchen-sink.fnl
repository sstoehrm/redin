;; Kitchen-sink example — todo list with themed UI.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

;; ===== Theme =====

(theme-mod.set-theme
  {:surface             {:bg [46 52 64] :padding [24 24 24 24]}
   :heading             {:font-size 24 :color [236 239 244] :weight 1}
   :body                {:font-size 14 :color [216 222 233]}
   :muted               {:font-size 13 :color [76 86 106]}
   :input               {:bg [59 66 82] :color [236 239 244]
                          :border [76 86 106] :border-width 1
                          :radius 4 :padding [8 12 8 12] :font-size 14}
   :input#focus         {:border [136 192 208]}
   :button              {:bg [76 86 106] :color [236 239 244]
                          :radius 6 :padding [6 14 6 14] :font-size 13}
   :button#hover        {:bg [94 105 126]}
   :button#active       {:bg [59 66 82]}})

;; ===== State =====

(dataflow.init
  {:items [{:text "Test 1"} {:text "Test 2"} {:text "Test 3"} {:text "Test 4"}]
   :input-value ""})

;; ===== Handlers =====

(reg-handler :test/input
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))
    db))

(reg-handler :test/add
  (fn [db event]
    (let [val (get db :input-value "")]
      (when (> (string.len val) 0)
        (update db :items (fn [items]
          (table.insert items {:text val})
          items))
        (assoc db :input-value "")))
    db))

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))

;; ===== View =====

(global main_view
  (fn []
    (let [items (subscribe :items)
          input-val (subscribe :input-value)]
      {:frame
        [:vbox {}
         [:stack {}
          [:vbox {:aspect :surface :layout :center}
           [:text {:aspect :heading :layout :center} "Todo List"]
           [:input {:aspect :input :width 250 :height 42
                    :value input-val
                    :change [:test/input] :key [:test/add]}]
           [:button {:width 250 :height 42 :aspect :button
                     :click [:test/add]} "Add"]
           [:vbox {:overflow :scroll-y :aspect :muted}
            (icollect [_ item (ipairs (or items []))]
              [:text {:aspect :body} item.text])]]]]
       :bind {}})))
